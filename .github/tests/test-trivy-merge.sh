#!/usr/bin/env bash
set -e

# Test script validating the global + repo `.trivyignore` merge used by
# global/scripts/tools/trivy/run.sh and run-sca.sh. Both build a merged ignore
# file (the shipped global ignore, always applied, with the project's own
# `.trivyignore` appended) and hand it to Trivy via `--ignorefile`.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GLOBAL_IGNORE="$SCRIPTS_DIR/global/scripts/tools/trivy/.trivyignore"
TEST_DIR="$(mktemp -d)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_true() {
  local description="$1"
  local condition="$2"
  if eval "$condition"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# --- Merge logic mirrored from run.sh / run-sca.sh for isolated testing ---
merge_trivyignore() {
  local global_file="$1"
  local repo_file="$2"
  local output_file="$3"

  : > "$output_file"
  if [ -f "$global_file" ]; then
    cat "$global_file" >> "$output_file"
  fi
  if [ -f "$repo_file" ]; then
    printf '\n# --- project .trivyignore (appended) ---\n' >> "$output_file"
    cat "$repo_file" >> "$output_file"
  fi
}

# =============================================================================
# Test 1: the global ignore ships and curates only justified entries
# =============================================================================
echo "TEST 1: global .trivyignore content"
assert_true "global .trivyignore exists" "[ -f '$GLOBAL_IGNORE' ]"
assert_true "global suppresses GO-2026-5932 (x/crypto/openpgp false positive)" \
  "grep -qx 'GO-2026-5932' '$GLOBAL_IGNORE'"
# Guard against unjustified drift: exactly one active (non-comment, non-blank) entry.
# Match content lines directly — first non-space character is neither whitespace nor
# '#' — which avoids the fragile end-of-line anchor inside the nested shell quoting.
assert_true "exactly one active ignore id in the global file" \
  "[ \"\$(grep -cE '^[[:space:]]*[^[:space:]#]' '$GLOBAL_IGNORE')\" = '1' ]"

# =============================================================================
# Test 2: project entries are appended, global entries preserved
# =============================================================================
echo "TEST 2: merge global + project"
cat > "$TEST_DIR/repo.trivyignore" << 'EOF'
# project-specific: accepted risk for a vendored fixture
CVE-2099-99999
EOF
merge_trivyignore "$GLOBAL_IGNORE" "$TEST_DIR/repo.trivyignore" "$TEST_DIR/merged"
assert_true "global entry preserved" "grep -qx 'GO-2026-5932' '$TEST_DIR/merged'"
assert_true "project entry appended" "grep -qx 'CVE-2099-99999' '$TEST_DIR/merged'"
assert_true "append marker present" "grep -q 'project .trivyignore (appended)' '$TEST_DIR/merged'"

# =============================================================================
# Test 3: no project .trivyignore -> global only
# =============================================================================
echo "TEST 3: no project .trivyignore"
merge_trivyignore "$GLOBAL_IGNORE" "$TEST_DIR/does-not-exist" "$TEST_DIR/merged"
assert_true "global entry present" "grep -qx 'GO-2026-5932' '$TEST_DIR/merged'"
assert_true "no append marker when project file absent" \
  "! grep -q 'project .trivyignore (appended)' '$TEST_DIR/merged'"

# =============================================================================
# Test 4: an ID present in both global and project still lands in the merge
# =============================================================================
echo "TEST 4: overlapping ID"
printf 'GO-2026-5932\n' > "$TEST_DIR/repo2.trivyignore"
merge_trivyignore "$GLOBAL_IGNORE" "$TEST_DIR/repo2.trivyignore" "$TEST_DIR/merged"
assert_true "GO-2026-5932 present in merge (Trivy dedupes finding ids itself)" \
  "[ \"\$(grep -cx 'GO-2026-5932' '$TEST_DIR/merged')\" -ge 1 ]"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
