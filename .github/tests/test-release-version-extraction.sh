#!/usr/bin/env bash
# Regression test for the `Extract Release Version` step in
# github/global/stages/40-delivery/release/action.yaml.
#
# The action derives the version to release from two sources: the tag ref (when
# triggered by a version-tag push — the recovery / reconciliation path) and the
# bump commit message (the normal main-branch delivery path). This test pins
# that precedence and the accepted formats so a future edit that breaks tag-push
# recovery — or the four-segment fork variant — is caught at CI time instead of
# silently dropping releases across every consumer of the shared template.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# Mirror of the extraction logic in action.yaml. Keep these in sync — if the
# behaviour changes, this function must change with it.
#   $1 = GITHUB_REF        (e.g. "refs/tags/v1.2.3" or "refs/heads/main")
#   $2 = GITHUB_REF_NAME   (e.g. "v1.2.3" or "main")
#   $3 = HEAD commit message
extract_version() {
  local ref="$1" ref_name="$2" msg="$3" version=""

  case "$ref" in
    refs/tags/*)
      version="$(printf '%s' "$ref_name" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([.-][0-9]+)?' | head -n 1)"
      ;;
  esac

  if [[ -z "$version" ]]; then
    if echo "$msg" | grep -Eq "chore/bump-[0-9]+\.[0-9]+\.[0-9]+"; then
      version=$(echo "$msg" | grep -oE "chore/bump-[0-9]+\.[0-9]+\.[0-9]+" | head -n 1 | sed 's/chore\/bump-//')
    elif echo "$msg" | grep -Eq "chore\(bump\):.*version to [0-9]+\.[0-9]+\.[0-9]+"; then
      version=$(echo "$msg" | grep -oE "version to [0-9]+\.[0-9]+\.[0-9]+" | head -n 1 | sed 's/version to //')
    fi
  fi

  printf '%s' "$version"
}

assert_version() {
  local description="$1" ref="$2" ref_name="$3" msg="$4" expected="$5"
  local actual
  actual="$(extract_version "$ref" "$ref_name" "$msg")"
  if [[ "$actual" == "$expected" ]]; then
    echo -e "${GREEN}PASS${NC} $description"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}FAIL${NC} $description (expected='$expected', actual='$actual')"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo "=== Release version extraction ==="

# Tag-push recovery path
assert_version "plain semver tag"            "refs/tags/1.0.0"    "1.0.0"    "" "1.0.0"
assert_version "v-prefixed tag strips v"     "refs/tags/v1.0.0"   "v1.0.0"   "" "1.0.0"
assert_version "real backfilled tag"         "refs/tags/2.33.0"   "2.33.0"   "" "2.33.0"
assert_version "fork dot four-segment tag"   "refs/tags/1.0.0.1"  "1.0.0.1"  "" "1.0.0.1"
assert_version "fork dash four-segment tag"  "refs/tags/v1.0.1-2" "v1.0.1-2" "" "1.0.1-2"
assert_version "non-version tag is skipped"  "refs/tags/latest"   "latest"   "" ""

# Main-branch delivery path
assert_version "PR merge bump message" \
  "refs/heads/main" "main" "Merge pull request #256 from rios0rios0/chore/bump-2.32.14" "2.32.14"
assert_version "conventional bump message" \
  "refs/heads/main" "main" "chore(bump): bumped version to 0.2.4" "0.2.4"
assert_version "non-bump commit is skipped" \
  "refs/heads/main" "main" "fix(core): corrected an edge case" ""

# Tag ref wins over the commit message when both are present
assert_version "tag ref takes precedence over commit message" \
  "refs/tags/3.3.1" "3.3.1" "chore/bump-9.9.9" "3.3.1"

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
