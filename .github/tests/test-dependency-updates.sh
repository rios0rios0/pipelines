#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted `${...}` and backticks are the expected TEXT, never expansions
set -e

# Validate the dependency-update tool's wiring.
#
# WHY THIS EXISTS
#
# The tool's BEHAVIOUR -- discovery, the security policy, `--apply`, `verify`,
# `guard` -- is covered by the Go tests beside the code (`make
# test-go-helpers`), which drive the real command line against fixture
# upstreams and in-memory doubles. What those tests cannot see is how the tool
# is reached and wired, and every way THAT goes wrong is silent:
#
#   - a `run.sh` that no longer builds or runs the tool from a checkout leaves
#     the scheduled job failing as "lookup error" rather than as a broken script;
#   - a mode that cleans the wrong report directory deletes the pull request
#     body the next workflow step opens the pull request from;
#   - a workflow step that drops a security property -- credentials persisted
#     for the updater, a verification that no longer fails the check, a guard
#     that no longer runs -- keeps every job green while the gate is gone.
#
# Nothing here needs the network or Python: fixtures are static JSON, and the
# tool is built by `run.sh` exactly as a runner builds it.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$SCRIPTS_DIR/global/scripts/tools/dependency-updates/run.sh"
WORKFLOW="$SCRIPTS_DIR/.github/workflows/dependency-updates.yaml"
VERIFY_WORKFLOW="$SCRIPTS_DIR/.github/workflows/dependency-updates-verify.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}  PASS: $1${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}  FAIL: $1${NC}"; [[ -n "${2:-}" ]] && echo "        $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$description"
  else fail "$description" "expected '$expected', got '$actual'"; fi
}

assert_contains() {
  local description="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$description"
  else fail "$description" "missing '$needle'"; fi
}

assert_not_contains() {
  local description="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$description"
  else fail "$description" "unexpectedly found '$needle'"; fi
}

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT
# The tool confines `--report` and `--fixture` to the working directory, so the
# suite runs from inside its sandbox, as a job runs from its workspace.
cd "$WORK" || exit 1

DIGEST_A="$(printf 'a%.0s' $(seq 64))"
mkdir -p repo/global/scripts/shared repo/.github/workflows
cat > repo/global/scripts/shared/pinned-versions.sh <<'EOS'
# upstream: pypi examplepkg
EXAMPLEPKG_SPEC="${EXAMPLEPKG_SPEC:-examplepkg==2.0.0}"
EOS
cat > repo/.github/workflows/ci.yaml <<EOS
jobs:
  build:
    container:
      image: 'someimage:1.0@sha256:${DIGEST_A}'
EOS
cat > fixture.json <<EOS
{
  "osv:*": [],
  "pypi:examplepkg": "2.0.0",
  "image:someimage:1.0@sha256:${DIGEST_A}": "sha256:${DIGEST_A}"
}
EOS

echo "=========================================="
echo "Dependency update tool wiring"
echo "=========================================="
echo ""

# --------------------------------------------------------------------------- #
echo "1. run.sh builds the tool from its checkout and runs it"
# --------------------------------------------------------------------------- #
set +e
OUT="$("$RUN" --repo-dir repo --fixture fixture.json 2>&1)"; STATUS=$?
set -e
assert_eq "a repository whose pins are current exits 0" "0" "$STATUS"
assert_contains "and says so" "$OUT" "Every pinned dependency is current"
assert_contains "after checking both pins" "$OUT" "Checking 2 pinned dependencies"
if [[ -f build/reports/dependency-updates/dependency-updates.json ]]; then
  pass "the reports land under build/reports/dependency-updates"
else
  fail "the reports land under build/reports/dependency-updates"
fi
if [[ -x "$RUN" ]]; then pass "run.sh is executable"; else fail "run.sh is executable"; fi
echo ""

# --------------------------------------------------------------------------- #
echo "2. Each mode keeps to its own reports"
# --------------------------------------------------------------------------- #
# The workflow opens the pull request from the check's reports in the step
# AFTER the guard runs; a guard that cleaned them would open nothing.
set +e
"$RUN" guard --repository 'owner/repo' > /dev/null 2>&1
set -e
if [[ -f build/reports/dependency-updates/dependency-updates.json ]]; then
  pass "the guard leaves the check's reports alone"
else
  fail "the guard leaves the check's reports alone"
fi
cp -R repo base
set +e
OUT="$("$RUN" verify --base-dir base --repo-dir repo --fixture fixture.json 2>&1)"; STATUS=$?
set -e
assert_eq "verifying a pull request that moves no pin exits 0" "0" "$STATUS"
assert_contains "and says there was nothing to verify" "$OUT" "nothing to verify"
assert_not_contains "a fixture run installs no scanner -- the fixture answers the scans" "$OUT" "OSV-Scanner"
assert_contains "while a real run hands the command the pinned installer" "$(cat "$RUN")" "osv-scanner/install.sh"
assert_eq "verify writes into its own report directory" "0" \
  "$(cat build/reports/dependency-updates-verify/changes.txt 2>/dev/null || echo missing)"
if [[ -f build/reports/dependency-updates/dependency-updates.json ]]; then
  pass "and leaves the check's reports alone"
else
  fail "and leaves the check's reports alone"
fi
# The verification is a required check on EVERY pull request, so one that
# moves no pin must not depend on anything outside the runner: a lookup there
# would block every pull request while the advisory database is down. This run
# is live -- no fixture -- with every connection sent to a proxy that refuses
# it and a HOME with no scanner in it, so any lookup fails the run and any
# install leaves a binary behind. The build itself needs no network.
mkdir -p offline-home
set +e
OUT="$(env -u NO_PROXY -u no_proxy HOME="$WORK/offline-home" \
  GOCACHE="$(go env GOCACHE)" GOMODCACHE="$(go env GOMODCACHE)" GOPATH="$(go env GOPATH)" \
  HTTPS_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
  "$RUN" verify --base-dir base --repo-dir repo 2>&1)"; STATUS=$?
set -e
assert_eq "a live verify of a pull request that moves no pin passes with the network refused" "0" "$STATUS"
assert_contains "and says there was nothing to verify" "$OUT" "nothing to verify"
if [[ -e "$WORK/offline-home/.local/bin/osv-scanner" ]]; then
  fail "and installs no scanner -- one is installed only when an image needs scanning"
else
  pass "and installs no scanner -- one is installed only when an image needs scanning"
fi
echo ""

# --------------------------------------------------------------------------- #
echo "3. No Python is left in the tool"
# --------------------------------------------------------------------------- #
PYTHON_FILES="$(find "$SCRIPTS_DIR/global/scripts/tools/dependency-updates" -name '*.py' 2>/dev/null)"
assert_eq "the tool ships no Python" "" "$PYTHON_FILES"
assert_not_contains "the scheduled workflow runs no Python" "$(cat "$WORKFLOW")" "python3"
assert_not_contains "the verification workflow runs no Python" "$(cat "$VERIFY_WORKFLOW")" "python3"
echo ""

# --------------------------------------------------------------------------- #
echo "4. The scheduled workflow opens a pull request, safely"
# --------------------------------------------------------------------------- #
SCHEDULED="$(cat "$WORKFLOW")"
assert_eq "it runs twice a week" "2" "$(grep -c "cron:" "$WORKFLOW")"
assert_contains "it applies the updates" "$SCHEDULED" "args='--apply'"
assert_contains "it provisions Go to build the tool" "$SCHEDULED" "actions/setup-go@"
assert_contains "the job may push the update branch" "$SCHEDULED" "contents: 'write'"
assert_contains "and open the pull request" "$SCHEDULED" "pull-requests: 'write'"
assert_contains "through a SHA-pinned create-pull-request" "$SCHEDULED" "peter-evans/create-pull-request@"
assert_contains "with verified commits" "$SCHEDULED" "sign-commits: true"
assert_contains "built only from the scanned repository's own checkout" "$SCHEDULED" "path: 'repository'"
assert_contains "after the guard has had its say" "$SCHEDULED" "run.sh\" guard"
assert_eq "neither checkout leaves credentials behind for the updater" "2" \
  "$(grep -c "persist-credentials: false" <<< "$SCHEDULED")"
assert_contains "a failed lookup leaves the pull request alone" "$SCHEDULED" \
  "steps.check.outputs.status != '2' && steps.guard.outputs.proceed == 'true'"
assert_contains "and still fails the job" "$SCHEDULED" "advisory database could not be reached"
assert_contains "a known vulnerability in a pin in use keeps the job red" "$SCHEDULED" "has a known vulnerability"
assert_contains "the optional token is a declared secret" "$SCHEDULED" "dependency_updates_token:"
echo ""

# --------------------------------------------------------------------------- #
echo "5. The verification workflow is a gate on every pull request"
# --------------------------------------------------------------------------- #
VERIFY="$(cat "$VERIFY_WORKFLOW")"
assert_contains "it runs on pull requests" "$VERIFY" "pull_request:"
assert_not_contains "with no path filter, so a required check always reports" "$VERIFY" "paths:"
assert_contains "and can be called by a consumer" "$VERIFY" "workflow_call:"
assert_contains "it checks out the pull request's base" "$VERIFY" "github.event.pull_request.base.sha"
assert_contains "and proves the diff between the two" "$VERIFY" "run.sh\" verify"
assert_eq "no checkout leaves credentials behind" "3" "$(grep -c "persist-credentials: false" <<< "$VERIFY")"
assert_contains "it reads the repository and nothing more" "$VERIFY" "contents: 'read'"
assert_contains "it fails the check when verification fails" "$VERIFY" "steps.verify.outputs.status != '0'"
assert_contains "the proof is posted where the reviewer reads" "$VERIFY" "marocchino/sticky-pull-request-comment@"
assert_contains "only on a pull request that moves a pin" "$VERIFY" "steps.verify.outputs.changes != '0'"
echo ""

echo "=========================================="
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
echo "=========================================="
[[ "$TESTS_FAILED" -gt 0 ]] && exit 1
echo -e "${GREEN}Dependency update tool wiring validated${NC}"
