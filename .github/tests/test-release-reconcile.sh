#!/usr/bin/env bash
# Regression test for global/scripts/shared/reconcile-releases.sh.
#
# Builds a throwaway git repository whose CHANGELOG.md is deliberately ahead of
# its tags (the exact "release cut-off" this guards against) and asserts the
# script reports precisely the missing versions, each mapped to its own bump
# commit. Pins: both bump-message formats, "v"-prefix exclusion, and the
# version boundary: "1.0.1" must not match a "1.0.10" bump, nor "3.8.0" a fork's
# "3.8.0.5" or "3.9.0" a "3.9.0-2" bump, whose next character used to pass it.
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

FIXTURE="$(mktemp -d)" || exit 1
FORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$FIXTURE" "$FORK"' EXIT
cd "$FIXTURE" || exit 1

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
echo "=== A fork's four-segment bump is not the bump of the version it extends ==="
# given: a fork whose 3.8.0 and 3.9.0 bumps merged but were never tagged, each followed by a
# tagged four-segment bump of the same version (3.8.0.5 as a pull request merge, 3.9.0-2 as a
# conventional commit), and an untagged 4.0.0 bump whose message ends in a period
cd "$FORK" || exit 1
git init -q
git config user.email "test@example.com"
git config user.name "Test"
git config commit.gpgsign false
git config core.hooksPath "$FORK/.git/no-hooks"
printf '# Changelog\n\n## [Unreleased]\n' > CHANGELOG.md
git add CHANGELOG.md && git commit -q -m "chore: initial"
C_380="$(commit_changelog "Merge pull request #10 from org/chore/bump-3.8.0" "## [3.8.0] - 2026-02-01" "- fix c")"
commit_changelog "Merge pull request #11 from org/chore/bump-3.8.0.5" "## [3.8.0.5] - 2026-02-02" "- fix d" > /dev/null
git tag 3.8.0.5
C_390="$(commit_changelog "chore(bump): bumped version to 3.9.0" "## [3.9.0] - 2026-02-03" "- feature b")"
commit_changelog "chore(bump): bumped version to 3.9.0-2" "## [3.9.0-2] - 2026-02-04" "- fix e" > /dev/null
git tag v3.9.0-2
C_400="$(commit_changelog "chore(bump): bumped version to 4.0.0." "## [4.0.0] - 2026-02-05" "- feature c")"

# when: the script resolves each untagged version to its bump commit
OUTPUT="$(sh "$RECONCILE" "$FORK")"
echo "--- reconcile output (fork) ---"
echo "$OUTPUT"
echo "-------------------------------"

# then: each version maps to the commit that bumped to it as a whole, and nothing tagged is reported
assert_eq "reports exactly the 3 untagged versions" "3" "$(printf '%s\n' "$OUTPUT" | grep -c .)"
assert_eq "3.8.0 maps to its own bump, not the later 3.8.0.5 pull request merge" \
  "3.8.0	${C_380}	recoverable" "$(echo "$OUTPUT" | awk -F'\t' '$1=="3.8.0"')"
assert_eq "3.9.0 maps to its own bump, not the later 3.9.0-2 conventional commit" \
  "3.9.0	${C_390}	recoverable" "$(echo "$OUTPUT" | awk -F'\t' '$1=="3.9.0"')"
assert_eq "4.0.0 maps to its bump, though a period follows the version" \
  "4.0.0	${C_400}	recoverable" "$(echo "$OUTPUT" | awk -F'\t' '$1=="4.0.0"')"

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
