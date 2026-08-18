#!/usr/bin/env bash
set -e

# Validate the dependency-update checker.
#
# WHY THIS EXISTS
#
# The checker's whole value is its EXIT CODE: a scheduled job goes red when a
# pin is stale and green when it is not. Every way that can go wrong is silent:
#
#   - a discovery regex that stops matching reports "everything is current"
#     while inspecting nothing, which is the failure mode that makes a security
#     check worse than useless;
#   - a version comparison that mis-orders reports an update from a version to
#     itself, forever, until people mute the job;
#   - a lookup failure treated as "up to date" turns a rate-limited API into a
#     green light.
#
# The suite therefore drives the real script against FIXTURE upstreams, so it
# runs offline with no token and no network, and asserts on exit codes and
# report contents rather than on the source reading plausibly. That is the same
# technique `test-deploy-providers.sh` and `test-dependency-check.sh` use.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$SCRIPTS_DIR/global/scripts/tools/dependency-updates/check_updates.py"

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The checker confines `--report` and `--fixture` to the working directory, so
# the suite runs from inside its sandbox and addresses both relatively. That is
# also how the tool is really used: `cleanup.sh` hands it `build/reports/...`
# relative to wherever the job runs.
cd "$WORK"

# --------------------------------------------------------------------------- #
# A miniature repository with one pin of every shape the checker understands.
# --------------------------------------------------------------------------- #
build_repo() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/global/scripts/shared" "$root/.github/workflows" "$root/containers"

  cat > "$root/global/scripts/shared/pinned-versions.sh" <<'EOS'
#!/usr/bin/env sh
# upstream: github-release example/binary
BINARY_PINNED_VERSION="1.2.3"
BINARY_VERSION="${BINARY_VERSION:-${BINARY_PINNED_VERSION}}"
BINARY_SHA256_AMD64="aa"

# upstream: pypi examplepkg
EXAMPLEPKG_SPEC="${EXAMPLEPKG_SPEC:-examplepkg==2.0.0}"

# upstream: npm examplecli
EXAMPLECLI_SPEC="${EXAMPLECLI_SPEC:-examplecli@4}"

# upstream: github-release example/held track=1
HELD_PINNED_VERSION="1.5.0"
HELD_VERSION="${HELD_VERSION:-${HELD_PINNED_VERSION}}"

UNTRACKED_PINNED_VERSION="9.9.9"
UNTRACKED_VERSION="${UNTRACKED_VERSION:-${UNTRACKED_PINNED_VERSION}}"
EOS

  cat > "$root/.github/workflows/sample.yaml" <<'EOS'
jobs:
  build:
    steps:
      - uses: 'someorg/someaction@1111111111111111111111111111111111111111' # v3.1.0
      - uses: 'rios0rios0/pipelines/github/global/abstracts/scripts-repo@main'
    container:
      image: 'someimage:1.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
EOS

  cat > "$root/containers/Dockerfile" <<'EOS'
FROM otherimage:2.0@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOS
}

# Fixture where every upstream matches what is pinned.
CURRENT_FIXTURE="current.json"
cat > "$CURRENT_FIXTURE" <<'EOS'
{
  "github-release:example/binary": "v1.2.3",
  "pypi:examplepkg": "2.0.0",
  "npm:examplecli": "4.99.1",
  "github-release:example/held": "v1.5.0",
  "github-release:someorg/someaction": "v3.1.0",
  "image:someimage:1.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "image:otherimage:2.0@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}
EOS

REPO="$WORK/repo"
build_repo "$REPO"

run_checker() {
  local fixture="$1"; shift
  python3 "$CHECKER" --repo-dir "$REPO" --report "out" --fixture "$fixture" "$@" 2>&1
}

echo "=========================================="
echo "Dependency update checker"
echo "=========================================="
echo ""

# --------------------------------------------------------------------------- #
echo "1. A repository whose pins are all current exits 0"
# --------------------------------------------------------------------------- #
# The untracked pin is removed first so this measures only the version logic.
sed -i '/UNTRACKED/d' "$REPO/global/scripts/shared/pinned-versions.sh"
set +e
OUT="$(run_checker "$CURRENT_FIXTURE")"; STATUS=$?
set -e
assert_eq "exit code is 0 when nothing is stale" "0" "$STATUS"
assert_contains "says so explicitly" "$OUT" "Every pinned dependency is current"
assert_contains "reports having checked all seven pins" "$OUT" "Checking 7 pinned dependencies"

# A major-only pin (`examplecli@4`) must NOT report an update for 4.99.1.
assert_not_contains "a major-only pin is current within its major" "$OUT" "EXAMPLECLI"
# `track=1` must not report the 2.x that exists upstream.
assert_not_contains "a version held inside a major ignores the next major" "$OUT" "HELD"
echo ""

# --------------------------------------------------------------------------- #
echo "2. Each kind of staleness is detected, and fails the run"
# --------------------------------------------------------------------------- #
STALE_FIXTURE="stale.json"
python3 - "$CURRENT_FIXTURE" "$STALE_FIXTURE" <<'EOS'
import json, sys
data = json.load(open(sys.argv[1]))
data["github-release:example/binary"] = "v1.3.0"
data["pypi:examplepkg"] = "2.1.0"
data["npm:examplecli"] = "5.0.0"
data["github-release:example/held"] = "v2.0.0"
data["github-release:someorg/someaction"] = "v4.0.0"
for key in list(data):
    if key.startswith("image:"):
        data[key] = "sha256:" + "c" * 64
json.dump(data, open(sys.argv[2], "w"))
EOS
set +e
OUT="$(run_checker "$STALE_FIXTURE")"; STATUS=$?
set -e
assert_eq "exit code is 1 when something is stale" "1" "$STATUS"
assert_contains "a newer binary release is reported"  "$OUT" "BINARY"
assert_contains "a newer PyPI release is reported"    "$OUT" "EXAMPLEPKG"
assert_contains "a new npm MAJOR is reported"         "$OUT" "EXAMPLECLI"
assert_contains "a newer action release is reported"  "$OUT" "someorg/someaction"
assert_contains "a moved image digest is reported"    "$OUT" "digest moved"
assert_contains "the old and new versions are shown"  "$OUT" "1.2.3 -> v1.3.0"
# `track=1` still holds: 2.0.0 is a migration, not an update.
assert_not_contains "a held major still ignores the next major" "$OUT" "HELD"
echo ""

# --------------------------------------------------------------------------- #
echo "3. A pin with no upstream annotation is reported, not skipped silently"
# --------------------------------------------------------------------------- #
# This is the regression that would quietly shrink coverage: adding a pin and
# forgetting the annotation must be visible, or the checker slowly stops
# checking things while continuing to pass.
build_repo "$REPO"
set +e
OUT="$(run_checker "$CURRENT_FIXTURE")"; STATUS=$?
set -e
assert_eq "an unannotated pin fails the run" "1" "$STATUS"
assert_contains "and names the variable" "$OUT" "UNTRACKED"
assert_contains "and says what is missing" "$OUT" "no '# upstream:' annotation"
echo ""

# --------------------------------------------------------------------------- #
echo "4. A lookup that cannot be completed never reads as 'up to date'"
# --------------------------------------------------------------------------- #
sed -i '/UNTRACKED/d' "$REPO/global/scripts/shared/pinned-versions.sh"
echo '{}' > empty.json
set +e
OUT="$(run_checker "empty.json")"; STATUS=$?
set -e
assert_eq "an unresolvable upstream exits 2, not 0" "2" "$STATUS"
assert_contains "and refuses to claim a clean result" "$OUT" "refusing to report a clean result"
echo ""

# --------------------------------------------------------------------------- #
echo "5. --report-only reports without failing"
# --------------------------------------------------------------------------- #
set +e
OUT="$(run_checker "$STALE_FIXTURE" --report-only)"; STATUS=$?
set -e
assert_eq "exit code is 0 under --report-only" "0" "$STATUS"
assert_contains "but the updates are still listed" "$OUT" "UPDATE"
echo ""

# --------------------------------------------------------------------------- #
echo "6. Reports are written in both machine and human form"
# --------------------------------------------------------------------------- #
set +e
run_checker "$STALE_FIXTURE" > /dev/null 2>&1
set -e
if [[ -f "out/dependency-updates.json" ]]; then pass "a JSON report is written"
else fail "a JSON report is written"; fi
if [[ -f "out/dependency-updates.md" ]]; then pass "a Markdown report is written"
else fail "a Markdown report is written"; fi
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "out/dependency-updates.json" 2>/dev/null; then
  pass "the JSON report parses"
else
  fail "the JSON report parses"
fi
MD="$(cat "out/dependency-updates.md")"
assert_contains "the Markdown says how to apply a binary bump" "$MD" "_PINNED_VERSION"
assert_contains "the Markdown says how to apply an action bump" "$MD" "commit SHA"
echo ""

# --------------------------------------------------------------------------- #
echo "7. An ignore entry silences one reference and nothing else"
# --------------------------------------------------------------------------- #
# Rolling tags (`alpine:edge`) would otherwise report an update on nearly every
# run; a check that is always red stops being read.
cat > "$REPO/.dependency-updates.json" <<'EOS'
{ "ignore": ["someimage*"] }
EOS
set +e
OUT="$(run_checker "$STALE_FIXTURE")"; STATUS=$?
set -e
assert_not_contains "the ignored reference is gone" "$OUT" "someimage"
# Both images are stale in this fixture, so this proves the ignore is scoped to
# the pattern rather than switching image checking off wholesale.
assert_contains "the other stale image is still reported" "$OUT" "otherimage"
assert_contains "non-image checks are untouched by an image ignore" "$OUT" "BINARY"
rm -f "$REPO/.dependency-updates.json"
echo ""

# --------------------------------------------------------------------------- #
echo "8. The real repository is wired up and fully annotated"
# --------------------------------------------------------------------------- #
# Against THIS repository, offline. Every discovered coordinate becomes a
# lookup error under an empty fixture, which is exactly what makes it a
# coverage assertion: the count is the number of pins being tracked.
set +e
REAL="$(python3 "$CHECKER" --repo-dir "$SCRIPTS_DIR" --report "real" --fixture "empty.json" 2>&1)"
set -e
assert_not_contains "every pin in this repo carries an upstream annotation" "$REAL" "no '# upstream:' annotation"
assert_not_contains "no inline copy has drifted from the manifest" "$REAL" "DRIFT"
DISCOVERED="$(python3 -c "
import json
print(len(json.load(open('real/dependency-updates.json'))['errors']))
")"
if [[ "$DISCOVERED" -ge 60 ]]; then
  pass "discovers the repository's pins (found $DISCOVERED)"
else
  fail "discovers the repository's pins" "only found $DISCOVERED; a discovery regex has stopped matching"
fi

if [[ -x "$SCRIPTS_DIR/global/scripts/tools/dependency-updates/run.sh" ]]; then
  pass "run.sh is executable"
else
  fail "run.sh is executable"
fi
CRON_COUNT="$(grep -c "cron:" "$SCRIPTS_DIR/.github/workflows/dependency-updates.yaml")"
assert_eq "the workflow is scheduled twice a week" "2" "$CRON_COUNT"
echo ""

# --------------------------------------------------------------------------- #
echo "9. It works on a repository that is not the one holding the script"
# --------------------------------------------------------------------------- #
# The `workflow_call` case, and a real bug caught in review: the workflow ran
# `./global/scripts/...` from `$GITHUB_WORKSPACE`, which under `workflow_call`
# is the CONSUMER's checkout -- a repository with no reason to contain the
# script. The script now comes from `$SCRIPTS_DIR` and the scanned tree from
# `--repo-dir`, and those two being separable is what this asserts.
CONSUMER="$WORK/consumer"
mkdir -p "$CONSUMER/.github/workflows"
cat > "$CONSUMER/.github/workflows/ci.yaml" <<'EOS'
jobs:
  build:
    steps:
      - uses: 'someorg/someaction@1111111111111111111111111111111111111111' # v3.1.0
    container:
      image: 'someimage:1.0@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
EOS
set +e
OUT="$(python3 "$CHECKER" --repo-dir "$CONSUMER" --report "consumer-out" \
  --fixture "$CURRENT_FIXTURE" 2>&1)"; STATUS=$?
set -e
assert_eq "a consumer repo with no manifest exits 0 when current" "0" "$STATUS"
assert_contains "and still discovers its action and image" "$OUT" "Checking 2 pinned dependencies"
assert_not_contains "a missing pinned-versions.sh is not an error" "$OUT" "no such file"

set +e
OUT="$(python3 "$CHECKER" --repo-dir "$CONSUMER" --report "consumer-out" \
  --fixture "$STALE_FIXTURE" 2>&1)"; STATUS=$?
set -e
assert_eq "and still fails when the consumer's pins are stale" "1" "$STATUS"
assert_contains "naming the consumer's own action" "$OUT" "someorg/someaction"

# The workflow checks THIS repository out into `.pipelines` inside the scanned
# workspace, so that directory must be invisible to the scan -- otherwise a
# consumer's report lists this library's pins as if they were theirs, and this
# repository's own scheduled run counts every pin twice.
mkdir -p "$CONSUMER/.pipelines/.github/workflows"
cat > "$CONSUMER/.pipelines/.github/workflows/library.yaml" <<'EOS'
jobs:
  build:
    steps:
      - uses: 'libraryorg/libraryaction@2222222222222222222222222222222222222222' # v9.9.9
EOS
set +e
OUT="$(python3 "$CHECKER" --repo-dir "$CONSUMER" --report "consumer-out" \
  --fixture "$CURRENT_FIXTURE" 2>&1)"; STATUS=$?
set -e
assert_not_contains "a nested .pipelines checkout is not scanned" "$OUT" "libraryorg/libraryaction"
assert_contains "and the consumer's own pins are still the only ones counted" "$OUT" "Checking 2 pinned dependencies"
echo ""

echo "=========================================="
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
echo "=========================================="
[[ "$TESTS_FAILED" -gt 0 ]] && exit 1
echo -e "${GREEN}Dependency update checker validated${NC}"
