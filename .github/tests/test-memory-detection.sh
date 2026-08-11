#!/usr/bin/env bash
set -e

# Test script validating `global/scripts/shared/memory.sh`, the cgroup-aware
# memory-ceiling detection that `global/scripts/tools/codeql/run.sh` uses to
# size CodeQL's `--ram` budget.
#
# The function under test is SOURCED from the shipped script (not mirrored), so
# these assertions fail if the real detection regresses. Its three input paths
# are overridable precisely so this can run against fixtures on any host.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEMORY_SH="$SCRIPTS_DIR/global/scripts/shared/memory.sh"
TEST_DIR="$(mktemp -d)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_equals() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (expected '$expected', got '$actual')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

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

# Run the real function in a clean subshell with the given fixture paths, so no
# case leaks state (or a cached `MEMORY_UNLIMITED_THRESHOLD`) into the next.
detect_with() {
  local v2="$1"
  local v1="$2"
  local meminfo="$3"
  (
    # Exported separately rather than as an assignment prefix on `.`: a prefix
    # on the source builtin is not visible to the sourced script.
    export CGROUP_V2_MEMORY_MAX="$v2"
    export CGROUP_V1_MEMORY_LIMIT="$v1"
    export PROC_MEMINFO="$meminfo"
    # shellcheck disable=SC1090
    . "$MEMORY_SH"
    detect_memory_limit_mb
  )
}

echo "Testing memory ceiling detection..."
echo ""

MISSING="$TEST_DIR/does-not-exist"
printf 'MemTotal:       65809868 kB\nMemFree:         1234 kB\n' > "$TEST_DIR/meminfo"

echo "cgroup v2:"
echo '8589934592' > "$TEST_DIR/v2-8gib"
assert_equals "reads a numeric cgroup v2 limit as MB (8 GiB -> 8192)" \
  "8192" "$(detect_with "$TEST_DIR/v2-8gib" "$MISSING" "$TEST_DIR/meminfo")"

echo 'max' > "$TEST_DIR/v2-max"
echo '4294967296' > "$TEST_DIR/v1-4gib"
assert_equals "treats the literal 'max' as unlimited and falls through to v1" \
  "4096" "$(detect_with "$TEST_DIR/v2-max" "$TEST_DIR/v1-4gib" "$TEST_DIR/meminfo")"

echo ""
echo "cgroup v1:"
assert_equals "reads a numeric cgroup v1 limit when v2 is absent" \
  "4096" "$(detect_with "$MISSING" "$TEST_DIR/v1-4gib" "$TEST_DIR/meminfo")"

# An unconstrained cgroup v1 reports a sentinel near 2^63 instead of a real
# ceiling. Mistaking it for a limit would hand the tool an ~8 EiB budget.
echo '9223372036854771712' > "$TEST_DIR/v1-unlimited"
assert_equals "rejects the cgroup v1 'unlimited' sentinel and falls back to MemTotal" \
  "64267" "$(detect_with "$MISSING" "$TEST_DIR/v1-unlimited" "$TEST_DIR/meminfo")"

echo ""
echo "fallbacks:"
assert_equals "falls back to /proc/meminfo MemTotal when no cgroup file is readable" \
  "64267" "$(detect_with "$MISSING" "$MISSING" "$TEST_DIR/meminfo")"

printf 'garbage\n' > "$TEST_DIR/v2-garbage"
assert_equals "ignores a non-numeric cgroup value and falls back to MemTotal" \
  "64267" "$(detect_with "$TEST_DIR/v2-garbage" "$MISSING" "$TEST_DIR/meminfo")"

: > "$TEST_DIR/v2-empty"
assert_equals "ignores an empty cgroup file and falls back to MemTotal" \
  "64267" "$(detect_with "$TEST_DIR/v2-empty" "$MISSING" "$TEST_DIR/meminfo")"

assert_equals "prints nothing when no source is readable" \
  "" "$(detect_with "$MISSING" "$MISSING" "$MISSING" || true)"

assert_true "returns non-zero when no source is readable" \
  "! detect_with '$MISSING' '$MISSING' '$MISSING' > /dev/null 2>&1"

printf 'MemFree:         1234 kB\n' > "$TEST_DIR/meminfo-no-total"
assert_true "returns non-zero when /proc/meminfo carries no MemTotal" \
  "! detect_with '$MISSING' '$MISSING' '$TEST_DIR/meminfo-no-total' > /dev/null 2>&1"

echo ""
echo "CodeQL RAM budget (arithmetic mirrored from global/scripts/tools/codeql/run.sh):"

# The consumer takes 75% of the ceiling and only sets `--ram` when that clears a
# 2048 MB floor -- below which an explicit budget would be tighter than what
# CodeQL picks unaided, making things worse rather than better.
codeql_budget_for() {
  local ceiling_mb="$1"
  local candidate=$((ceiling_mb * 75 / 100))
  if [ "$candidate" -ge 2048 ]; then
    echo "$candidate"
  fi
}

assert_equals "an 8 GiB pod yields a 6144 MB budget (comfortably above the 660 MiB that OOM'd)" \
  "6144" "$(codeql_budget_for 8192)"
assert_equals "a 4 GiB pod yields a 3072 MB budget" \
  "3072" "$(codeql_budget_for 4096)"
assert_equals "a 2 GiB pod stays under the floor and leaves --ram unset" \
  "" "$(codeql_budget_for 2048)"
assert_equals "a 1 GiB pod stays under the floor and leaves --ram unset" \
  "" "$(codeql_budget_for 1024)"

echo ""
echo "==================================="
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All memory detection tests passed."
