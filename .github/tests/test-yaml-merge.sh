#!/usr/bin/env bash
set -e

# Test script for validating YAML merge functionality in golangci-lint/run.sh
#
# These tests drive the real `run.sh` through its `GOLANGCI_LINT_MERGE_ONLY` hook rather than
# keeping a second copy of the merge. The copy is what allowed the defect these tests now cover:
# it merged project settings into the v1 `linters-settings` key while `run.sh` merged into the v2
# `linters.settings`, so every assertion below passed against a shape production never emitted.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPTS_DIR
RUN_SH="$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/run.sh"
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

# Runs the production merge in an isolated working directory and copies the result out.
# `extra_path` is prepended to PATH when given, so a test can control which `yq` is found first.
merge_yaml() {
  local repo_file="$1"
  local output_file="$2"
  local extra_path="${3:-}"

  local workdir
  workdir="$(mktemp -d)"
  if [[ -f "$repo_file" ]]; then
    cp "$repo_file" "$workdir/.golangci.yml"
  fi

  # The script's own output is kept and echoed when it fails. Discarding it is how a merge that
  # aborted (an undownloadable yq, an unreadable config) became indistinguishable from a merge
  # that silently produced the wrong result -- the assertions fail identically, and the reason
  # only exists in the output that was thrown away.
  local log="$workdir/run.log"
  if ! (
    cd "$workdir" || exit 1
    if [[ -n "$extra_path" ]]; then
      export PATH="$extra_path:$PATH"
    fi
    GOLANGCI_LINT_MERGE_ONLY=1 sh "$RUN_SH"
  ) > "$log" 2>&1; then
    echo "    (run.sh exited non-zero; output follows)"
    sed 's/^/    | /' "$log"
  fi

  cp "$workdir/merged.yml" "$output_file"
  rm -rf "$workdir"
}

# =============================================================================
# Test 1: No custom config - should use default as-is
# =============================================================================
echo "TEST 1: No custom config (default fallback)"
merge_yaml "$TEST_DIR/does-not-exist.yml" "$TEST_DIR/merged.yml"
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
merge_yaml "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
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
merge_yaml "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
assert_true "staticcheck removed" \
  "! yq eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx staticcheck"
assert_true "cyclop removed" \
  "! yq eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx cyclop"
assert_true "other linters preserved" \
  "yq eval '.linters.enable | contains([\"errcheck\", \"govet\"])' '$TEST_DIR/merged.yml' | grep -q true"

# =============================================================================
# Test 4: Custom linter settings
#
# Asserted against the v2 `linters.settings` key, which is what golangci-lint v2 reads and what
# run.sh writes. The previous suite asserted the v1 `linters-settings` key and so proved nothing.
# =============================================================================
echo "TEST 4: Linter settings merge"
cat > "$TEST_DIR/repo.yml" << 'YAML'
linters-settings:
  errcheck:
    check-blank: true
  custom-linter:
    option-a: hello
YAML
merge_yaml "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
assert_true "custom setting merged" \
  "yq eval '.linters.settings.errcheck.check-blank' '$TEST_DIR/merged.yml' | grep -qx true"
assert_true "new linter settings added" \
  "yq eval '.linters.settings.custom-linter.option-a' '$TEST_DIR/merged.yml' | grep -qx hello"
assert_true "existing default settings preserved" \
  "yq eval '.linters.settings.cyclop.max-complexity' '$TEST_DIR/merged.yml' | grep -qx 30"

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
merge_yaml "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
assert_true "exhaustruct enabled" \
  "yq eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx exhaustruct"
assert_true "staticcheck disabled" \
  "! yq eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx staticcheck"
assert_true "exhaustruct settings applied" \
  "yq eval '.linters.settings.exhaustruct.exclude | length' '$TEST_DIR/merged.yml' | grep -q '[0-9]'"

# =============================================================================
# Test 6: Empty custom config
# =============================================================================
echo "TEST 6: Empty custom config"
touch "$TEST_DIR/empty.yml"
merge_yaml "$TEST_DIR/empty.yml" "$TEST_DIR/merged.yml"
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
merge_yaml "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
expected_count=$((default_count + 1))
actual_count=$(yq eval '.linters.enable | length' "$TEST_DIR/merged.yml")
assert_true "only 1 new linter added (no dupes)" "[ '$actual_count' = '$expected_count' ]"

# =============================================================================
# Test 8: The wrong `yq` on PATH must not silently void the project config
#
# `yq` is two programs: mikefarah/yq (Go) speaks `yq eval '<expr>' <file>`, while kislyuk/yq
# (a jq wrapper, shipped by pip and several distributions) treats the expression as a filename
# and exits non-zero. run.sh used to swallow that with `2>/dev/null || true`, silently dropping
# every project override and reporting the shared defaults as violations of the project's code.
# The shim below impersonates kislyuk/yq; run.sh must notice and fetch a usable binary.
# =============================================================================
echo "TEST 8: Wrong yq flavour on PATH"
mkdir -p "$TEST_DIR/fakebin"
cat > "$TEST_DIR/fakebin/yq" << 'SHIM'
#!/usr/bin/env sh
# Impersonates kislyuk/yq: a bare version banner, and no support for `eval`.
if [ "$1" = "--version" ]; then
  echo "yq 3.4.3"
  exit 0
fi
echo "yq: error: argument files: can't open '$2'" >&2
exit 2
SHIM
chmod +x "$TEST_DIR/fakebin/yq"

cat > "$TEST_DIR/repo.yml" << 'YAML'
linters:
  disable:
    - recvcheck

linters-settings:
  dupl:
    threshold: 300
YAML
merge_yaml "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml" "$TEST_DIR/fakebin"
assert_true "recvcheck still disabled despite wrong yq on PATH" \
  "! yq eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx recvcheck"
assert_true "settings still merged despite wrong yq on PATH" \
  "yq eval '.linters.settings.dupl.threshold' '$TEST_DIR/merged.yml' | grep -qx 300"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
