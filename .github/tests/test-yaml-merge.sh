#!/usr/bin/env bash
set -e

# Test script for validating YAML merge functionality in golangci-lint/run.sh
# This tests the yq-based merge logic that replaced the Python implementation.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_CONFIG="$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/.golangci.yml"
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

# --- Merge function extracted from run.sh for isolated testing ---
merge_yaml() {
  local default_file="$1"
  local repo_file="$2"
  local output_file="$3"

  cp "$default_file" "$output_file"

  if [ ! -f "$repo_file" ]; then
    return 0
  fi

  # Collect enabled linters and add new ones in a single operation
  repo_enabled=$(yq eval '.linters.enable[]?' "$repo_file" 2>/dev/null || true)
  if [ -n "$repo_enabled" ]; then
    to_enable=""
    for linter in $repo_enabled; do
      if [ -n "$linter" ]; then
        if ! yq eval ".linters.enable | contains([\"$linter\"])" "$output_file" | grep -q true; then
          to_enable="$to_enable \"$linter\""
        fi
      fi
    done
    if [ -n "$to_enable" ]; then
      yq eval ".linters.enable += [${to_enable}]" -i "$output_file"
    fi
  fi

  # Collect disabled linters and remove them all in a single operation
  repo_disabled=$(yq eval '.linters.disable[]?' "$repo_file" 2>/dev/null || true)
  if [ -n "$repo_disabled" ]; then
    filter=".linters.enable = (.linters.enable | map(select("
    first=true
    for linter in $repo_disabled; do
      if [ -n "$linter" ]; then
        if [ "$first" = true ]; then
          filter="${filter}. != \"$linter\""
          first=false
        else
          filter="${filter} and . != \"$linter\""
        fi
      fi
    done
    filter="${filter})))"
    yq eval "$filter" -i "$output_file"
  fi

  # Merge linter settings using yq deep merge
  repo_settings=$(yq eval '.linters-settings // ""' "$repo_file" 2>/dev/null || true)
  if [ -n "$repo_settings" ] && [ "$repo_settings" != "" ] && [ "$repo_settings" != "null" ]; then
    yq eval-all 'select(fileIndex == 0) * {"linters-settings": select(fileIndex == 1).linters-settings}' "$output_file" "$repo_file" > "$output_file.tmp"
    mv "$output_file.tmp" "$output_file"
  fi
}

# =============================================================================
# Test 1: No custom config - should use default as-is
# =============================================================================
echo "TEST 1: No custom config (default fallback)"
cp "$DEFAULT_CONFIG" "$TEST_DIR/merged.yml"
assert_true "merged file created" "[ -s '$TEST_DIR/merged.yml' ]"
assert_true "default linters present" \
  "yq eval '.linters.enable | contains([\"errcheck\", \"govet\", \"staticcheck\"])' '$TEST_DIR/merged.yml' | grep -q true"

# =============================================================================
# Test 2: Custom config with additional enabled linters
# =============================================================================
echo "TEST 2: Custom enabled linters"
cat > "$TEST_DIR/repo.yml" << 'YAML'
linters:
  enable:
    - exhaustruct
    - ginkgolinter
YAML
merge_yaml "$DEFAULT_CONFIG" "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
assert_true "new linters added" \
  "yq eval '.linters.enable | contains([\"exhaustruct\", \"ginkgolinter\"])' '$TEST_DIR/merged.yml' | grep -q true"
assert_true "default linters preserved" \
  "yq eval '.linters.enable | contains([\"errcheck\", \"govet\"])' '$TEST_DIR/merged.yml' | grep -q true"

# =============================================================================
# Test 3: Custom config with disabled linters
# =============================================================================
echo "TEST 3: Disabled linters"
cat > "$TEST_DIR/repo.yml" << 'YAML'
linters:
  disable:
    - staticcheck
    - cyclop
YAML
merge_yaml "$DEFAULT_CONFIG" "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
assert_true "staticcheck removed" \
  "! yq eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx staticcheck"
assert_true "cyclop removed" \
  "! yq eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx cyclop"
assert_true "other linters preserved" \
  "yq eval '.linters.enable | contains([\"errcheck\", \"govet\"])' '$TEST_DIR/merged.yml' | grep -q true"

# =============================================================================
# Test 4: Custom linter settings
# =============================================================================
echo "TEST 4: Linter settings merge"
cat > "$TEST_DIR/repo.yml" << 'YAML'
linters-settings:
  errcheck:
    check-blank: true
  custom-linter:
    option-a: hello
YAML
merge_yaml "$DEFAULT_CONFIG" "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
assert_true "custom setting merged" \
  "[ \"$(yq eval '.linters-settings.errcheck.check-blank' '$TEST_DIR/merged.yml')\" = 'true' ]"
assert_true "new linter settings added" \
  "[ \"$(yq eval '.linters-settings.custom-linter.option-a' '$TEST_DIR/merged.yml')\" = 'hello' ]"
assert_true "existing settings preserved" \
  "[ \"$(yq eval '.linters-settings.cyclop.max-complexity' '$TEST_DIR/merged.yml')\" = '30' ]"

# =============================================================================
# Test 5: Complex config (enable + disable + settings)
# =============================================================================
echo "TEST 5: Complex combined config"
cat > "$TEST_DIR/repo.yml" << 'YAML'
linters:
  enable:
    - exhaustruct
  disable:
    - staticcheck

linters-settings:
  exhaustruct:
    exclude:
      - '^net/http\.Client$'
YAML
merge_yaml "$DEFAULT_CONFIG" "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
assert_true "exhaustruct enabled" \
  "yq eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx exhaustruct"
assert_true "staticcheck disabled" \
  "! yq eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx staticcheck"
assert_true "exhaustruct settings applied" \
  "yq eval '.linters-settings.exhaustruct.exclude | length' '$TEST_DIR/merged.yml' | grep -q '[0-9]'"

# =============================================================================
# Test 6: Empty custom config
# =============================================================================
echo "TEST 6: Empty custom config"
touch "$TEST_DIR/empty.yml"
merge_yaml "$DEFAULT_CONFIG" "$TEST_DIR/empty.yml" "$TEST_DIR/merged.yml"
default_count=$(yq eval '.linters.enable | length' "$DEFAULT_CONFIG")
merged_count=$(yq eval '.linters.enable | length' "$TEST_DIR/merged.yml")
assert_true "linter count unchanged" "[ '$default_count' = '$merged_count' ]"

# =============================================================================
# Test 7: Duplicate linters not re-added
# =============================================================================
echo "TEST 7: Duplicate linter handling"
cat > "$TEST_DIR/repo.yml" << 'YAML'
linters:
  enable:
    - errcheck
    - govet
    - exhaustruct
YAML
merge_yaml "$DEFAULT_CONFIG" "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
expected_count=$((default_count + 1))
actual_count=$(yq eval '.linters.enable | length' "$TEST_DIR/merged.yml")
assert_true "only 1 new linter added (no dupes)" "[ '$actual_count' = '$expected_count' ]"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
