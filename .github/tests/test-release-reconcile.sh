#!/usr/bin/env bash
# Regression test for global/scripts/shared/reconcile-releases.sh.
#
# Builds a throwaway git repository whose CHANGELOG.md is deliberately ahead of
# its tags (the exact "release cut-off" this guards against) and asserts the
# script reports precisely the missing versions, each mapped to its own bump
# commit. Pins: both bump-message formats, "v"-prefix exclusion, and the
# "1.0.1 must not match a 1.0.10 bump" version boundary.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RECONCILE="${SCRIPT_DIR}/global/scripts/shared/reconcile-releases.sh"

pass() { echo -e "${GREEN}PASS${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$description"
  else
    fail "$description (expected='$expected', actual='$actual')"
  fi
}

FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
cd "$FIXTURE"

git init -q
git config user.email "test@example.com"
git config user.name "Test"

commit_changelog() {
  # $1 = commit message, $2... = CHANGELOG body appended
  local msg="$1"; shift
  printf '%s\n' "$@" >> CHANGELOG.md
  git add CHANGELOG.md
  git commit -q -m "$msg"
  git rev-parse HEAD
}

# 1.0.0 — released and tagged.
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n- initial\n' > CHANGELOG.md
git add CHANGELOG.md && git commit -q -m "chore: initial"
git tag 1.0.0

# 1.0.1 — bump merged (PR-merge format) but NEVER tagged -> gap.
C_101="$(commit_changelog "Merge pull request #2 from org/chore/bump-1.0.1" "## [1.0.1] - 2026-01-02" "- fix a")"

# 1.0.10 — bump merged (conventional format), never tagged -> gap. Guards the
# boundary: 1.0.1 must not match this commit.
C_1010="$(commit_changelog "chore(bump): bumped version to 1.0.10" "## [1.0.10] - 2026-01-03" "- fix b")"

# 1.1.0 — bump merged AND tagged with a "v" prefix -> NOT a gap.
commit_changelog "Merge pull request #4 from org/chore/bump-1.1.0" "## [1.1.0] - 2026-01-04" "- feature" >/dev/null
git tag v1.1.0

OUTPUT="$(sh "$RECONCILE" "$FIXTURE")"

echo "--- reconcile output ---"
echo "$OUTPUT"
echo "------------------------"

# Exactly two gaps.
assert_eq "reports exactly 2 gaps" "2" "$(printf '%s\n' "$OUTPUT" | grep -c .)"
# 1.0.1 -> its own bump commit, recoverable.
assert_eq "1.0.1 maps to its bump commit" "1.0.1	${C_101}	recoverable" "$(echo "$OUTPUT" | awk -F'\t' '$1=="1.0.1"')"
# 1.0.10 -> its own bump commit (boundary honoured).
assert_eq "1.0.10 maps to its bump commit" "1.0.10	${C_1010}	recoverable" "$(echo "$OUTPUT" | awk -F'\t' '$1=="1.0.10"')"
# tagged versions are excluded (bare and v-prefixed).
assert_eq "1.0.0 (tagged) is not reported" "" "$(echo "$OUTPUT" | awk -F'\t' '$1=="1.0.0"')"
assert_eq "1.1.0 (v-tagged) is not reported" "" "$(echo "$OUTPUT" | awk -F'\t' '$1=="1.1.0"')"

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
