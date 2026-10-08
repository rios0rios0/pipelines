#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted `${...}` and backticks are the expected TEXT, never expansions
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
# `--apply` raises the stakes, because its output is a pull request a person is
# asked to trust. Every way IT can go wrong is a supply-chain change that reads
# correctly in review:
#
#   - a digest carried forward to a new version, or taken from the wrong file,
#     which `verify-download.sh` then refuses on every consumer's runner;
#   - an annotated tag's own object pinned instead of the commit it names;
#   - an inline copy left behind on the version the manifest just left;
#   - an upstream "version" with a quote or `$` in it, written into a file that
#     every installer SOURCES;
#   - a rerun that rewrites identical content, which force-pushes the pull
#     request and dismisses its approvals for nothing.
#
# The suite therefore drives the real script against FIXTURE upstreams, so it
# runs offline with no token and no network, and asserts on exit codes, report
# contents and the rewritten files rather than on the source reading plausibly.
# That is the same technique `test-deploy-providers.sh` and
# `test-dependency-check.sh` use. The fixture answers `--apply`'s lookups by the
# URL they would fetch (`GET <url>`, `SHA256 <url>`), so URL construction is
# exercised too.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$SCRIPTS_DIR/global/scripts/tools/dependency-updates/check_updates.py"
GUARD="$SCRIPTS_DIR/global/scripts/tools/dependency-updates/pull_request_guard.py"
# The snippets below import the checker as a module; none of them should leave
# bytecode behind in this repository.
export PYTHONDONTWRITEBYTECODE=1

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
# The checker confines `--report` and `--fixture` to the working directory, so
# the suite runs from inside its sandbox and addresses both relatively. That is
# also how the tool is really used: `cleanup.sh` hands it `build/reports/...`
# relative to wherever the job runs.
cd "$WORK" || exit 1

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
# Without one, `--apply` cannot re-derive that digest, so the pin it belongs to
# could never be bumped -- and would go on reading as covered.
assert_not_contains "every digest in this repo carries an asset annotation" "$REAL" "no '# asset:' annotation"
assert_not_contains "no inline copy has drifted from the manifest" "$REAL" "DRIFT"

# Each inline-copy row must still match the copy it was written for. A row whose
# pattern stopped matching -- a template reworded, a URL reshaped -- reports no
# drift because it finds nothing, which is exactly how the Azure DevOps ProGuard
# and Terragrunt copies drifted unseen. GOVULNCHECK is the one row with no copy
# today; it exists so a copy is caught the day one is written.
UNMATCHED_ROWS="$(python3 - "$SCRIPTS_DIR" <<'EOS'
import re
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1] + "/global/scripts/tools/dependency-updates")
import check_updates as cu
ws = cu.Workspace(Path(sys.argv[1]))
NO_COPY_YET = {"GOVULNCHECK_PINNED_VERSION"}
for var, pattern in cu.INLINE_COPIES:
    compiled = re.compile(pattern)
    found = sum(len(compiled.findall(ws.text(path))) for path in cu.inline_files(ws))
    if not found and var not in NO_COPY_YET:
        print("%s: %s" % (var, pattern))
EOS
)"
assert_eq "every inline-copy pattern still finds the copy it was written for" "" "$UNMATCHED_ROWS"
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

# The workflow used to check THIS repository out into `.pipelines` inside the
# scanned one, and a consumer running the checker by hand may still do that, so
# the directory must stay invisible to the scan -- otherwise a consumer's report
# lists this library's pins as if they were theirs, and `--apply` would rewrite
# a checkout it does not own.
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

# --------------------------------------------------------------------------- #
# A repository with one pin of every shape `--apply` rewrites, and the fixture
# that moves each of them.
# --------------------------------------------------------------------------- #
repeat() { printf "%0.s$1" $(seq 1 "$2"); }
OLD_AMD64="$(repeat 1 64)"; OLD_ARM64="$(repeat 2 64)"; OLD_TG="$(repeat 3 64)"
NEW_AMD64="$(repeat 4 64)"; NEW_ARM64="$(repeat 5 64)"; NEW_TG="$(repeat 6 64)"
IMG_OLD="$(repeat a 64)"; IMG_STILL="$(repeat b 64)"; IMG_NEW="$(repeat c 64)"
ACTION_OLD="$(repeat 1 40)"; OTHER_SHA="$(repeat 2 40)"; TAG_OBJECT="$(repeat 7 40)"; COMMIT="$(repeat 8 40)"
export OLD_AMD64 OLD_ARM64 OLD_TG NEW_AMD64 NEW_ARM64 NEW_TG IMG_OLD IMG_STILL IMG_NEW ACTION_OLD OTHER_SHA TAG_OBJECT COMMIT

build_apply_repo() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/global/scripts/shared" "$root/.github/workflows" "$root/azure" "$root/containers" \
    "$root/.changes/unreleased"
  : > "$root/.changes/unreleased/.gitkeep"

  cat > "$root/global/scripts/shared/pinned-versions.sh" <<EOS
#!/usr/bin/env sh
# upstream: github-release example/tool
# checksums: https://github.com/example/tool/releases/download/v{version}/checksums.txt
TOOL_PINNED_VERSION="1.2.3"
TOOL_VERSION="\${TOOL_VERSION:-\${TOOL_PINNED_VERSION}}"
# asset: https://github.com/example/tool/releases/download/v{version}/tool_{version}_linux_amd64.tar.gz
TOOL_SHA256_AMD64="$OLD_AMD64"
# asset: https://github.com/example/tool/releases/download/v{version}/tool_{version}_linux_arm64.tar.gz
TOOL_SHA256_ARM64="$OLD_ARM64"

# upstream: github-release gruntwork-io/terragrunt
TERRAGRUNT_PINNED_VERSION="1.1.4"
TERRAGRUNT_VERSION="\${TERRAGRUNT_VERSION:-\${TERRAGRUNT_PINNED_VERSION}}"
# asset: https://github.com/gruntwork-io/terragrunt/releases/download/v{version}/terragrunt_linux_amd64
TERRAGRUNT_SHA256_AMD64="$OLD_TG"

# upstream: pypi pdm
PDM_SPEC="\${PDM_SPEC:-pdm==2.29.0}"

# upstream: npm wrangler
WRANGLER_CLI_SPEC="\${WRANGLER_CLI_SPEC:-wrangler@4}"

# upstream: goproxy golang.org/x/vuln
GOVULNCHECK_PINNED_VERSION="v1.8.0"
GOVULNCHECK_VERSION="\${GOVULNCHECK_VERSION:-\${GOVULNCHECK_PINNED_VERSION}}"
EOS

  cat > "$root/.github/workflows/ci.yaml" <<EOS
jobs:
  build:
    steps:
      - uses: 'someorg/someaction@$ACTION_OLD' # v3.1.0
      - uses: 'someorg/someaction/sub@$ACTION_OLD' # v3.1.0
      - uses: 'other/untouched@$OTHER_SHA' # v1.0.0
      - run: 'pip install --only-binary :all: "pdm==2.29.0"'
      - run: 'go install golang.org/x/vuln/cmd/govulncheck@v1.8.0'
    container:
      image: 'someimage:1.0@sha256:$IMG_OLD'
EOS

  cat > "$root/azure/terragrunt.yaml" <<EOS
steps:
  - script: |
      TERRAGRUNT_VERSION="1.1.4"
      TERRAGRUNT_SHA256="$OLD_TG"
EOS

  cat > "$root/containers/Dockerfile" <<EOS
FROM otherimage:2.0@sha256:$IMG_STILL
RUN pip install --only-binary :all: "pdm==2.29.0"
EOS
}

python3 - "apply.json" <<'EOS'
import json
import os
import sys
e = os.environ
api, gh = "https://api.github.com/repos", "https://github.com"
fixture = {
    "github-release:example/tool": "v1.3.0",
    "github-release:gruntwork-io/terragrunt": "v1.1.6",
    "pypi:pdm": "2.29.2",
    "npm:wrangler": "5.1.0",
    "goproxy:golang.org/x/vuln": "v1.9.0",
    "github-release:someorg/someaction": "v4.0.0",
    "github-release:other/untouched": "v1.0.0",
    "image:someimage:1.0@sha256:" + e["IMG_OLD"]: "sha256:" + e["IMG_NEW"],
    "image:otherimage:2.0@sha256:" + e["IMG_STILL"]: "sha256:" + e["IMG_STILL"],
    # An ANNOTATED tag: its ref names a tag object, which names the commit.
    "GET %s/someorg/someaction/git/ref/tags/v4.0.0" % api: {"object": {"type": "tag", "sha": e["TAG_OBJECT"]}},
    "GET %s/someorg/someaction/git/tags/%s" % (api, e["TAG_OBJECT"]): {"object": {"type": "commit", "sha": e["COMMIT"]}},
    "GET %s/example/tool/releases/tags/v1.2.3" % api: {"assets": [
        {"name": "tool_1.2.3_linux_amd64.tar.gz", "digest": "sha256:" + e["OLD_AMD64"]},
        {"name": "tool_1.2.3_linux_arm64.tar.gz", "digest": "sha256:" + e["OLD_ARM64"]}]},
    "GET %s/example/tool/releases/tags/v1.3.0" % api: {"assets": [
        {"name": "tool_1.3.0_linux_amd64.tar.gz", "digest": "sha256:" + e["NEW_AMD64"]},
        # Recorded no digest, as a release published before GitHub did: hashed from the download.
        {"name": "tool_1.3.0_linux_arm64.tar.gz", "digest": None}]},
    "SHA256 %s/example/tool/releases/download/v1.3.0/tool_1.3.0_linux_arm64.tar.gz" % gh: e["NEW_ARM64"],
    "GET %s/example/tool/releases/download/v1.3.0/checksums.txt" % gh:
        "%s  tool_1.3.0_linux_amd64.tar.gz\n%s *tool_1.3.0_linux_arm64.tar.gz\n" % (e["NEW_AMD64"], e["NEW_ARM64"]),
    "GET %s/gruntwork-io/terragrunt/releases/tags/v1.1.4" % api: {"assets": [
        {"name": "terragrunt_linux_amd64", "digest": "sha256:" + e["OLD_TG"]}]},
    "GET %s/gruntwork-io/terragrunt/releases/tags/v1.1.6" % api: {"assets": [
        {"name": "terragrunt_linux_amd64", "digest": "sha256:" + e["NEW_TG"]}]},
}
json.dump(fixture, open(sys.argv[1], "w"), indent=1)
EOS

APPLY_REPO="$WORK/apply-repo"
run_apply() {
  local fixture="$1"; shift
  python3 "$CHECKER" --repo-dir "$APPLY_REPO" --report "apply-out" --fixture "$fixture" --apply \
    --timestamp '2026-10-08T06:00:00Z' "$@" 2>&1
}
tree_digest() { (cd "$APPLY_REPO" || exit 1; find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum); }

# --------------------------------------------------------------------------- #
echo "10. --apply rewrites every kind of pin it found stale, and nothing else"
# --------------------------------------------------------------------------- #
build_apply_repo "$APPLY_REPO"
set +e
OUT="$(run_apply apply.json)"; STATUS=$?
set -e
assert_eq "--apply exits 0 when every update could be applied" "0" "$STATUS"

CI="$(cat "$APPLY_REPO/.github/workflows/ci.yaml")"
assert_contains "an action is re-pinned to the commit its release tag points at" "$CI" \
  "someorg/someaction@$COMMIT' # v4.0.0"
assert_contains "a sub-path action is re-pinned with it" "$CI" "someorg/someaction/sub@$COMMIT' # v4.0.0"
assert_not_contains "an annotated tag's own object is never what gets pinned" "$CI" "$TAG_OBJECT"
assert_contains "an action that is current is left alone" "$CI" "other/untouched@$OTHER_SHA' # v1.0.0"
assert_contains "an image is re-pinned to the digest its tag resolves to now" "$CI" "someimage:1.0@sha256:$IMG_NEW"
assert_contains "an inline pip copy follows its pin" "$CI" '"pdm==2.29.2"'
assert_contains "an inline go install copy follows its pin, keeping its own v" "$CI" "govulncheck@v1.9.0"

MANIFEST_TEXT="$(cat "$APPLY_REPO/global/scripts/shared/pinned-versions.sh")"
assert_contains "a binary's version is bumped" "$MANIFEST_TEXT" 'TOOL_PINNED_VERSION="1.3.0"'
assert_contains "with the digest GitHub recorded for the new asset" "$MANIFEST_TEXT" "TOOL_SHA256_AMD64=\"$NEW_AMD64\""
assert_contains "and the downloaded hash where GitHub recorded none" "$MANIFEST_TEXT" "TOOL_SHA256_ARM64=\"$NEW_ARM64\""
assert_not_contains "no digest of the old version is carried forward" "$MANIFEST_TEXT" "$OLD_AMD64"
assert_contains "a package spec keeps its own shape" "$MANIFEST_TEXT" 'pdm==2.29.2}'
assert_contains "a major-only spec stays major-only" "$MANIFEST_TEXT" 'wrangler@5}'
assert_contains "a goproxy pin keeps its v prefix" "$MANIFEST_TEXT" 'GOVULNCHECK_PINNED_VERSION="v1.9.0"'
assert_contains "the overridable default around a pin is untouched" "$MANIFEST_TEXT" \
  'TOOL_VERSION="${TOOL_VERSION:-${TOOL_PINNED_VERSION}}"'

AZURE="$(cat "$APPLY_REPO/azure/terragrunt.yaml")"
assert_contains "an inline version copy in a template follows its pin" "$AZURE" 'TERRAGRUNT_VERSION="1.1.6"'
assert_contains "and so does the inline digest copy beside it" "$AZURE" "TERRAGRUNT_SHA256=\"$NEW_TG\""
DOCKERFILE="$(cat "$APPLY_REPO/containers/Dockerfile")"
assert_contains "a Dockerfile's inline copy follows its pin" "$DOCKERFILE" '"pdm==2.29.2"'
assert_contains "an image that is still current keeps its digest" "$DOCKERFILE" "otherimage:2.0@sha256:$IMG_STILL"

EPOCH="$(python3 -c 'import datetime; print(int(datetime.datetime(2026, 10, 8, 6, tzinfo=datetime.timezone.utc).timestamp()))')"
FRAGMENT="$(find "$APPLY_REPO/.changes/unreleased" -name '*.yaml')"
assert_eq "one changelog fragment is written" "1" "$(printf '%s\n' "$FRAGMENT" | grep -c .)"
assert_contains "named the way chlog names its fragments" "$FRAGMENT" "/${EPOCH}000000000-"
FRAGMENT_TEXT="$(cat "$FRAGMENT")"
assert_contains "the fragment is a Changed entry" "$FRAGMENT_TEXT" "kind: 'Changed'"
assert_contains "dated by --timestamp, not by the clock" "$FRAGMENT_TEXT" "time: '2026-10-08T06:00:00.000000000Z'"
assert_contains "naming what it bumped" "$FRAGMENT_TEXT" '`someorg/someaction` `v4.0.0`'

FINGERPRINT="$(cat apply-out/fingerprint.txt)"
BODY="$(cat apply-out/pull-request.md)"
assert_contains "the body carries the fingerprint the guard looks for" "$BODY" \
  "<!-- dependency-updates-fingerprint: $FINGERPRINT -->"
assert_contains "the body links the release" "$BODY" "https://github.com/someorg/someaction/releases/tag/v4.0.0"
assert_contains "a major bump is flagged for the reviewer" "$BODY" "**major**"
assert_contains "it says where each digest came from" "$BODY" "SHA-256 of the downloaded asset"
assert_contains "including the checksum manifest it matched" "$BODY" 'matching `checksums.txt`'
assert_contains "it says how to decline" "$BODY" "Close"
assert_contains "the title counts what is proposed" "$(cat apply-out/pull-request-title.txt)" \
  "bumped 7 pinned dependencies"
assert_contains "the commit carries the trailer the guard recognises" "$(cat apply-out/commit-message.txt)" \
  "Dependency-Updates-Fingerprint: $FINGERPRINT"

# The same starting point must produce byte-identical output. A rerun that
# differed -- a fragment named by the clock, say -- would force-push the pull
# request twice a week, and the default branch's rules dismiss approvals on
# every push.
FIRST_TREE="$(tree_digest)"
FIRST_BODY="$BODY"
build_apply_repo "$APPLY_REPO"
run_apply apply.json > /dev/null
assert_eq "applying the same updates twice produces the same tree" "$FIRST_TREE" "$(tree_digest)"
assert_eq "and the same pull request" "$FIRST_BODY" "$(cat apply-out/pull-request.md)"

# Once applied, nothing is left to do: a run against the updated tree must find
# every pin current and write nothing at all -- no second fragment either.
python3 - apply.json after.json <<'EOS'
import json
import os
import sys
fixture = json.load(open(sys.argv[1]))
fixture["image:someimage:1.0@sha256:" + os.environ["IMG_NEW"]] = "sha256:" + os.environ["IMG_NEW"]
json.dump(fixture, open(sys.argv[2], "w"))
EOS
set +e
OUT="$(run_apply after.json)"; STATUS=$?
set -e
assert_eq "a second run exits 0" "0" "$STATUS"
assert_contains "and finds every pin current" "$OUT" "Every pinned dependency is current"
assert_eq "and changes nothing" "$FIRST_TREE" "$(tree_digest)"
echo ""

# --------------------------------------------------------------------------- #
echo "11. --apply refuses what it cannot do safely, and leaves it untouched"
# --------------------------------------------------------------------------- #
# Each case breaks one link of the chain that makes a digest trustworthy. The
# broken pin must stay exactly as it was -- never half-updated -- while the
# rest of the run still lands, and the exit code must say a person is needed.
refusal_case() {
  build_apply_repo "$APPLY_REPO"
  python3 - apply.json case.json "$1" <<'EOS'
import json
import os
import sys
e = os.environ
f = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(f, open(sys.argv[2], "w"))
EOS
  set +e
  CASE_OUT="$(run_apply case.json)"; CASE_STATUS=$?
  set -e
  CASE_MANIFEST="$(cat "$APPLY_REPO/global/scripts/shared/pinned-versions.sh")"
  CASE_CI="$(cat "$APPLY_REPO/.github/workflows/ci.yaml")"
}
TOOL_RELEASE_NOW='f["GET https://api.github.com/repos/example/tool/releases/tags/v1.2.3"]'
TOOL_RELEASE_NEW='f["GET https://api.github.com/repos/example/tool/releases/tags/v1.3.0"]'

refusal_case "${TOOL_RELEASE_NOW}[\"assets\"][0][\"digest\"] = \"sha256:\" + \"9\" * 64"
assert_eq "a template that no longer locates the committed file exits 1" "1" "$CASE_STATUS"
assert_contains "and says the template cannot be trusted" "$CASE_OUT" "is not the committed one"
assert_contains "and leaves the pin as it was" "$CASE_MANIFEST" 'TOOL_PINNED_VERSION="1.2.3"'
assert_contains "and its digests too" "$CASE_MANIFEST" "TOOL_SHA256_AMD64=\"$OLD_AMD64\""
assert_contains "while every other update still lands" "$CASE_CI" "someorg/someaction@$COMMIT"

refusal_case "${TOOL_RELEASE_NEW}[\"assets\"][0][\"name\"] = \"tool-1.3.0-linux-amd64.tar.gz\""
assert_eq "a release that renamed its asset exits 1" "1" "$CASE_STATUS"
assert_contains "and names the asset it could not find" "$CASE_OUT" "has no asset named tool_1.3.0_linux_amd64.tar.gz"
assert_contains "and says the installer has to follow" "$CASE_OUT" "renamed its assets"
assert_contains "and the pin is untouched" "$CASE_MANIFEST" 'TOOL_PINNED_VERSION="1.2.3"'

# The manifest lists BOTH assets, one of them wrongly, so the mismatch is the
# only thing standing between this release and the pull request.
refusal_case 'f["GET https://github.com/example/tool/releases/download/v1.3.0/checksums.txt"] = "e" * 64 + "  tool_1.3.0_linux_amd64.tar.gz\n" + e["NEW_ARM64"] + " *tool_1.3.0_linux_arm64.tar.gz\n"'
assert_eq "a release that disagrees with its own checksums exits 1" "1" "$CASE_STATUS"
assert_contains "and reports the disagreement" "$CASE_OUT" "but the asset itself is"
assert_contains "and writes neither digest" "$CASE_MANIFEST" "TOOL_SHA256_AMD64=\"$OLD_AMD64\""
assert_contains "nor the version" "$CASE_MANIFEST" 'TOOL_PINNED_VERSION="1.2.3"'

refusal_case 'f["github-release:example/tool"] = "v1.3.0\";touch_pwned;\""'
assert_eq "a version unsafe to write into a sourced shell file exits 1" "1" "$CASE_STATUS"
assert_contains "and is refused by name" "$CASE_OUT" "not safe to write into a sourced shell file"
assert_not_contains "and never reaches the manifest" "$CASE_MANIFEST" "touch_pwned"

# The tag resolves -- upstream really did publish it -- so refusing its NAME is
# the only thing keeping it out of the workflow.
refusal_case 'f["github-release:someorg/someaction"] = "v4.0.0 #injected"; f["GET https://api.github.com/repos/someorg/someaction/git/ref/tags/v4.0.0%20%23injected"] = {"object": {"type": "commit", "sha": e["COMMIT"]}}'
assert_eq "a tag unsafe to write into a workflow exits 1" "1" "$CASE_STATUS"
assert_not_contains "and never reaches the workflow" "$CASE_CI" "injected"
assert_contains "which keeps its old pin" "$CASE_CI" "someorg/someaction@$ACTION_OLD' # v3.1.0"

refusal_case 'del f["GET https://api.github.com/repos/someorg/someaction/git/ref/tags/v4.0.0"]'
assert_eq "a lookup that cannot be completed while applying exits 2" "2" "$CASE_STATUS"
assert_contains "and that action keeps its old pin" "$CASE_CI" "someorg/someaction@$ACTION_OLD' # v3.1.0"

build_apply_repo "$APPLY_REPO"
sed -i '/tool_{version}_linux_arm64/d' "$APPLY_REPO/global/scripts/shared/pinned-versions.sh"
set +e
CASE_OUT="$(run_apply apply.json)"; CASE_STATUS=$?
set -e
assert_eq "a digest with no asset annotation exits 1" "1" "$CASE_STATUS"
assert_contains "and is reported as untracked" "$CASE_OUT" "no '# asset:' annotation"
assert_contains "and its pin is not bumped half-way" "$(cat "$APPLY_REPO/global/scripts/shared/pinned-versions.sh")" \
  'TOOL_PINNED_VERSION="1.2.3"'
echo ""

# --------------------------------------------------------------------------- #
echo "12. Releases are compared within their own release line"
# --------------------------------------------------------------------------- #
# `github/codeql-action` releases the action (`v4.x`) and the CodeQL bundle
# (`codeql-bundle-v2.x`) from one repository, and marks whichever shipped last
# as latest. Read naively, the bundle's tag made the action look current at
# v4.37.7 while v4.38.3 was out.
FAMILY_RESULT="$(python3 - "$SCRIPTS_DIR" <<'EOS'
import sys
sys.path.insert(0, sys.argv[1] + "/global/scripts/tools/dependency-updates")
import check_updates as cu

releases = [{"tag_name": tag} for tag in
            ("v4.38.3", "v3.38.3", "codeql-bundle-v2.27.2", "v4.38.2", "codeql-bundle-v2.27.1")]
latest = {"tag": "codeql-bundle-v2.27.2"}

def fake_get_json(url, headers=None):
    if url.endswith("/releases/latest"):
        return {"tag_name": latest["tag"]}
    if "/releases?per_page=100" in url:
        return releases
    raise AssertionError(url)

cu.get_json = fake_get_json
checks = {
    "action_from_bundle_latest": cu.latest_github_release("github/codeql-action", None, cu.tag_family("v4.37.7")),
    "bundle_from_bundle_latest": cu.latest_github_release("github/codeql-action", None,
                                                          cu.tag_family("codeql-bundle-v2.26.4")),
}
latest["tag"] = "v4.38.3"
checks["bundle_from_action_latest"] = cu.latest_github_release("github/codeql-action", None,
                                                               cu.tag_family("codeql-bundle-v2.26.4"))
checks["restyle_drops_the_v"] = cu.restyle("8.30.1", "v8.31.0")
checks["restyle_keeps_the_line"] = cu.restyle("codeql-bundle-v2.26.4", "codeql-bundle-v2.27.2")
checks["restyle_keeps_a_major_pin"] = cu.restyle("4", "5.2.0")
checks["restyle_keeps_the_v"] = cu.restyle("v1.8.0", "v1.9.0")
for name, value in checks.items():
    print("%s=%s" % (name, value))
EOS
)"
assert_contains "the action finds its own newest release" "$FAMILY_RESULT" "action_from_bundle_latest=v4.38.3"
assert_contains "the bundle finds its own" "$FAMILY_RESULT" "bundle_from_bundle_latest=codeql-bundle-v2.27.2"
assert_contains "even when an action release is the latest" "$FAMILY_RESULT" \
  "bundle_from_action_latest=codeql-bundle-v2.27.2"
assert_contains "a pin written without v stays without" "$FAMILY_RESULT" "restyle_drops_the_v=8.31.0"
assert_contains "a tag that IS the pin stays whole" "$FAMILY_RESULT" "restyle_keeps_the_line=codeql-bundle-v2.27.2"
assert_contains "a major-only pin stays major-only" "$FAMILY_RESULT" "restyle_keeps_a_major_pin=5"
assert_contains "a pin written with v keeps it" "$FAMILY_RESULT" "restyle_keeps_the_v=v1.9.0"

# The same rule holds for an answer that did cross lines -- here, a fixture
# answering both pins with the action's release.
LINES_REPO="$WORK/lines-repo"
mkdir -p "$LINES_REPO/global/scripts/shared" "$LINES_REPO/.github/workflows"
cat > "$LINES_REPO/global/scripts/shared/pinned-versions.sh" <<'EOS'
# upstream: github-release github/codeql-action
CODEQL_BUNDLE_PINNED_VERSION="codeql-bundle-v2.26.4"
EOS
cat > "$LINES_REPO/.github/workflows/ci.yaml" <<'EOS'
jobs:
  build:
    steps:
      - uses: 'github/codeql-action/init@3333333333333333333333333333333333333333' # v4.37.7
EOS
echo '{ "github-release:github/codeql-action": "v4.38.3" }' > lines.json
set +e
OUT="$(python3 "$CHECKER" --repo-dir "$LINES_REPO" --report "lines-out" --fixture "lines.json" 2>&1)"
set -e
assert_contains "the action's release is an update for the action" "$OUT" "github/codeql-action"
assert_not_contains "and never for the bundle" "$OUT" "CODEQL_BUNDLE"
echo ""

# --------------------------------------------------------------------------- #
echo "13. Checksum manifests are read in both formats publishers use"
# --------------------------------------------------------------------------- #
CHECKSUM_RESULT="$(python3 - "$SCRIPTS_DIR" <<'EOS'
import sys
sys.path.insert(0, sys.argv[1] + "/global/scripts/tools/dependency-updates")
import check_updates as cu
a, b, c = "a" * 64, "b" * 64, "c" * 64
print("gnu=%s" % cu.published_checksum("%s  tool_linux_amd64.tar.gz\n%s  other\n" % (a, b), "tool_linux_amd64.tar.gz"))
print("binary_mode=%s" % cu.published_checksum("%s *hadolint-linux-x86_64\n" % b, "hadolint-linux-x86_64"))
# yq's checksums-bsd lists thirty algorithms per asset; SHA3-256 must never be read as SHA-256.
print("bsd=%s" % cu.published_checksum("SHA3-256 (yq_linux_amd64) = %s\nSHA256 (yq_linux_amd64) = %s\n" % (a, c),
                                       "yq_linux_amd64"))
print("bare=%s" % cu.published_checksum(c + "\n", "codeql-bundle-linux64.tar.gz"))
print("absent=%s" % cu.published_checksum("%s  something_else\n" % a, "tool_linux_amd64.tar.gz"))
EOS
)"
assert_contains "the GNU format is read" "$CHECKSUM_RESULT" "gnu=$(repeat a 64)"
assert_contains "including binary mode" "$CHECKSUM_RESULT" "binary_mode=$(repeat b 64)"
assert_contains "the BSD format is read, by its exact algorithm name" "$CHECKSUM_RESULT" "bsd=$(repeat c 64)"
assert_contains "a bare per-asset digest is read" "$CHECKSUM_RESULT" "bare=$(repeat c 64)"
assert_contains "an asset the manifest does not list is not invented" "$CHECKSUM_RESULT" "absent=None"

# The two pin annotations in either order: a `# checksums:` line dropped for
# sitting above `# upstream:` would take its cross-check with it, silently.
ORDER_RESULT="$(python3 - "$SCRIPTS_DIR" "$WORK/order-repo" <<'EOS'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1] + "/global/scripts/tools/dependency-updates")
import check_updates as cu
root = Path(sys.argv[2])
(root / cu.MANIFEST).parent.mkdir(parents=True, exist_ok=True)
(root / cu.MANIFEST).write_text(
    "# checksums: https://example.test/v{version}/sums\n"
    "# upstream: github-release owner/before\n"
    'BEFORE_PINNED_VERSION="1.0.0"\n'
    "\n"
    "# upstream: github-release owner/after\n"
    "# checksums: https://example.test/v{version}/sums\n"
    'AFTER_PINNED_VERSION="1.0.0"\n'
    'AFTER_VERSION="${AFTER_VERSION:-${AFTER_PINNED_VERSION}}"\n'
    "\n"
    "# upstream: github-release owner/plain\n"
    'PLAIN_PINNED_VERSION="1.0.0"\n', encoding="utf-8")
for entry in cu.discover_manifest(root):
    print("%s=%s" % (entry["name"], entry["checksums"]))
EOS
)"
assert_contains "a checksums annotation above upstream is kept" "$ORDER_RESULT" "BEFORE=https://example.test/v{version}/sums"
assert_contains "and so is one below it" "$ORDER_RESULT" "AFTER=https://example.test/v{version}/sums"
assert_contains "and neither leaks onto the next pin" "$ORDER_RESULT" "PLAIN=None"
echo ""

# --------------------------------------------------------------------------- #
echo "14. The pull-request guard protects a decline and a hand-made commit"
# --------------------------------------------------------------------------- #
GUARD_FP="$(repeat d 64)"
export GUARD_FP
write_guard_fixture() {
  python3 - "guard.json" "$1" <<'EOS'
import json
import os
import sys
api = "https://api.github.com/repos/owner/repo"
pulls = "GET %s/pulls?state=closed&head=owner%%3Achore%%2Fdependency-updates&per_page=100" % api
compare = "GET %s/compare/main...chore/dependency-updates" % api
marker = "<!-- dependency-updates-fingerprint: %s -->" % os.environ["GUARD_FP"]
bot = {"sha": "a" * 40, "parents": [{}], "commit": {"message": "chore(deps): bumped\n\nDependency-Updates-Fingerprint: x"}}
merge = {"sha": "b" * 40, "parents": [{}, {}], "commit": {"message": "Merge branch 'main'"}}
person = {"sha": "c" * 40, "parents": [{}], "commit": {"message": "fix: reverted the yq bump"}}
cases = {
    "declined": {pulls: [{"number": 12, "merged_at": None, "body": marker}], compare: {"commits": [bot]}},
    "merged": {pulls: [{"number": 13, "merged_at": "2026-10-01T00:00:00Z", "body": marker}], compare: None},
    "edited": {pulls: [], compare: {"commits": [bot, person]}},
    "updated": {pulls: [], compare: {"commits": [bot, merge]}},
    "unreachable": {pulls: []},
}
json.dump(cases[sys.argv[2]], open(sys.argv[1], "w"))
EOS
}
run_guard() {
  GITHUB_API_URL='https://api.github.com' python3 "$GUARD" --repository 'owner/repo' \
    --branch 'chore/dependency-updates' --base 'main' --fingerprint "${1:-$GUARD_FP}" --fixture 'guard.json' 2>&1
}

write_guard_fixture declined
set +e; OUT="$(run_guard)"; STATUS=$?; set -e
assert_contains "a declined set is not proposed again" "$OUT" "proceed=false"
assert_contains "naming the pull request that declined it" "$OUT" "declined in #12"

write_guard_fixture merged
set +e; OUT="$(run_guard)"; STATUS=$?; set -e
assert_contains "a MERGED pull request with the same set declines nothing" "$OUT" "proceed=true"

write_guard_fixture edited
set +e; OUT="$(run_guard)"; STATUS=$?; set -e
assert_contains "a branch carrying a person's commit is not overwritten" "$OUT" "proceed=false"
assert_contains "naming the commit" "$OUT" "cccccccccccc"

write_guard_fixture updated
set +e; OUT="$(run_guard)"; STATUS=$?; set -e
assert_contains "an 'Update branch' merge commit is not a person's work" "$OUT" "proceed=true"

write_guard_fixture unreachable
set +e; OUT="$(run_guard)"; STATUS=$?; set -e
assert_eq "a lookup that fails decides nothing" "2" "$STATUS"
assert_not_contains "and never says proceed" "$OUT" "proceed=true"

set +e; OUT="$(run_guard 'not-a-fingerprint')"; STATUS=$?; set -e
assert_eq "a malformed fingerprint is refused" "2" "$STATUS"
echo ""

# --------------------------------------------------------------------------- #
echo "15. A repository with a hand-written CHANGELOG.md gets its entry there"
# --------------------------------------------------------------------------- #
build_apply_repo "$APPLY_REPO"
rm -rf "$APPLY_REPO/.changes"
cat > "$APPLY_REPO/CHANGELOG.md" <<'EOS'
# Changelog

## [Unreleased]

### Added

- added something earlier

## [1.0.0] - 2026-01-15

### Changed

- changed something released
EOS
set +e
run_apply apply.json > /dev/null; STATUS=$?
set -e
CHANGELOG_TEXT="$(cat "$APPLY_REPO/CHANGELOG.md")"
assert_eq "the run still exits 0" "0" "$STATUS"
UNRELEASED_SECTION="$(sed -n '/^## \[Unreleased\]/,/^## \[1.0.0\]/p' "$APPLY_REPO/CHANGELOG.md")"
assert_contains "a Changed subsection is added under Unreleased" "$UNRELEASED_SECTION" "### Changed"
assert_contains "carrying the entry" "$UNRELEASED_SECTION" "- bumped the pinned dependencies"
assert_contains "without disturbing what was pending" "$UNRELEASED_SECTION" "- added something earlier"
assert_contains "or what was released" "$CHANGELOG_TEXT" "- changed something released"
assert_eq "and the released section gains nothing" "1" \
  "$(sed -n '/^## \[1.0.0\]/,$p' "$APPLY_REPO/CHANGELOG.md" | grep -c '^- ')"

build_apply_repo "$APPLY_REPO"
run_apply apply.json --changelog none > /dev/null || true
assert_eq "--changelog none writes no fragment" "0" \
  "$(find "$APPLY_REPO/.changes/unreleased" -name '*.yaml' | grep -c . || true)"
echo ""

# --------------------------------------------------------------------------- #
echo "16. The workflow opens a pull request instead of failing on updates"
# --------------------------------------------------------------------------- #
WORKFLOW="$(cat "$SCRIPTS_DIR/.github/workflows/dependency-updates.yaml")"
assert_contains "the run applies the updates" "$WORKFLOW" "args='--apply'"
assert_contains "the job may push the update branch" "$WORKFLOW" "contents: 'write'"
assert_contains "and open the pull request" "$WORKFLOW" "pull-requests: 'write'"
assert_contains "through a SHA-pinned create-pull-request" "$WORKFLOW" \
  "peter-evans/create-pull-request@"
assert_contains "with verified commits" "$WORKFLOW" "sign-commits: true"
assert_contains "built only from the scanned repository's own checkout" "$WORKFLOW" "path: 'repository'"
assert_contains "after the guard has had its say" "$WORKFLOW" "pull_request_guard.py"
assert_eq "neither checkout leaves credentials behind for the updater" "2" \
  "$(grep -c "persist-credentials: false" <<< "$WORKFLOW")"
assert_contains "a failed lookup leaves the pull request alone" "$WORKFLOW" \
  "steps.check.outputs.status != '2' && steps.guard.outputs.proceed == 'true'"
assert_contains "and still fails the job" "$WORKFLOW" "An upstream could not be reached"
assert_contains "the optional token is a declared secret" "$WORKFLOW" "dependency_updates_token:"
echo ""

echo "=========================================="
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
echo "=========================================="
[[ "$TESTS_FAILED" -gt 0 ]] && exit 1
echo -e "${GREEN}Dependency update checker validated${NC}"
