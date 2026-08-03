#!/usr/bin/env bash
# Validation script for the Go build-cache disk guard.
#
# The guard drops the build cache only when the agent is already low on disk, so the module
# cache can still be saved. Its whole value is in firing at the right moment, which makes the
# threshold parsing the part worth pinning: an unsanitised `85%` aborts the numeric comparison,
# the trim never runs, and the guard silently stops guarding.
#
# `df` and `go` are stubbed on PATH so the decision can be exercised at any disk level without
# needing a full agent.

set -euo pipefail

echo "=== Testing the Go build-cache disk guard ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIM_SCRIPT="$SCRIPT_DIR/../../global/scripts/languages/golang/cache-trim/run.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
  local result=$1
  local message=$2
  if [ "$result" -eq 0 ]; then
    echo -e "${GREEN}  PASS: $message${NC}"
    ((TESTS_PASSED++)) || true
  else
    echo -e "${RED}  FAIL: $message${NC}"
    ((TESTS_FAILED++)) || true
  fi
}

TEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

mkdir -p "$TEST_DIR/shim"

# `df` reports whatever percentage the caller asks for; `go` records that it was told to clean.
cat > "$TEST_DIR/shim/df" <<'STUB'
#!/usr/bin/env bash
# `-h` is the human-readable report printed after a trim; anything else is the percent query.
if [ "${1:-}" = "-h" ]; then
  echo "Filesystem Size Used Avail Use% Mounted on"
  echo "/dev/stub   100G  ${FAKE_DISK_USED}G   1G ${FAKE_DISK_USED}% /"
  exit 0
fi
echo "Use%"
echo " ${FAKE_DISK_USED}%"
STUB
chmod +x "$TEST_DIR/shim/df"

cat > "$TEST_DIR/shim/go" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "clean" ]; then echo "CLEANED" >> "$TRIM_LOG"; fi
exit 0
STUB
chmod +x "$TEST_DIR/shim/go"

# run_guard <disk-used-percent> [DISK_TRIM_THRESHOLD]
# Echoes "trimmed" or "kept"; anything else means the script itself failed.
run_guard() {
  local used="$1"
  local threshold="${2-__unset__}"

  export TRIM_LOG="$TEST_DIR/trim.log"
  : > "$TRIM_LOG"

  local output
  if [ "$threshold" = "__unset__" ]; then
    output="$(PATH="$TEST_DIR/shim:$PATH" FAKE_DISK_USED="$used" \
      sh "$TRIM_SCRIPT" 2>&1)" || { echo "script-failed: $output"; return; }
  else
    output="$(PATH="$TEST_DIR/shim:$PATH" FAKE_DISK_USED="$used" DISK_TRIM_THRESHOLD="$threshold" \
      sh "$TRIM_SCRIPT" 2>&1)" || { echo "script-failed: $output"; return; }
  fi

  if grep -q CLEANED "$TRIM_LOG"; then echo "trimmed"; else echo "kept"; fi
}

# =============================================================================
# Test 1: the default threshold
# =============================================================================
echo "TEST 1: the default threshold (85%)"
[ "$(run_guard 95)" = "trimmed" ] \
  && print_result 0 "95% used trims the build cache" \
  || print_result 1 "95% used should have trimmed"

[ "$(run_guard 50)" = "kept" ] \
  && print_result 0 "50% used keeps both caches" \
  || print_result 1 "50% used should have kept both caches"

[ "$(run_guard 85)" = "trimmed" ] \
  && print_result 0 "exactly at the threshold trims (>=, not >)" \
  || print_result 1 "85% used should have trimmed"

# =============================================================================
# Test 2: a percent-suffixed threshold -- the reported regression
# =============================================================================
echo "TEST 2: a threshold written as a percentage"
# `85%` is the expected mistake, since the option is documented as a percent. Unsanitised it
# aborts the comparison, so the guard silently never fires.
[ "$(run_guard 95 '85%')" = "trimmed" ] \
  && print_result 0 "'85%' is read as 85 and still trims at 95%" \
  || print_result 1 "'85%' silently disabled the guard"

[ "$(run_guard 50 '85%')" = "kept" ] \
  && print_result 0 "'85%' still keeps both caches below the threshold" \
  || print_result 1 "'85%' trimmed when it should not have"

# =============================================================================
# Test 3: thresholds that carry no usable number
# =============================================================================
echo "TEST 3: unusable thresholds fall back to the default"
[ "$(run_guard 95 '')" = "trimmed" ] \
  && print_result 0 "an empty threshold falls back to 85 and trims at 95%" \
  || print_result 1 "an empty threshold disabled the guard"

[ "$(run_guard 95 'high')" = "trimmed" ] \
  && print_result 0 "a non-numeric threshold falls back to 85 and trims at 95%" \
  || print_result 1 "a non-numeric threshold disabled the guard"

[ "$(run_guard 50 'high')" = "kept" ] \
  && print_result 0 "the fallback still respects the low-usage case" \
  || print_result 1 "the fallback trimmed when it should not have"

# =============================================================================
# Test 4: an explicit threshold is honoured
# =============================================================================
echo "TEST 4: an explicit threshold is honoured"
[ "$(run_guard 70 60)" = "trimmed" ] \
  && print_result 0 "a lower threshold trims earlier" \
  || print_result 1 "threshold 60 should have trimmed at 70%"

[ "$(run_guard 95 99)" = "kept" ] \
  && print_result 0 "a higher threshold defers the trim" \
  || print_result 1 "threshold 99 should not have trimmed at 95%"

# =============================================================================
# Test 5: an unreadable filesystem is not fatal
# =============================================================================
echo "TEST 5: an unreadable filesystem leaves both caches alone"
: > "$TEST_DIR/trim.log"
if output="$(PATH="$TEST_DIR/shim:$PATH" FAKE_DISK_USED="" TRIM_LOG="$TEST_DIR/trim.log" \
    sh "$TRIM_SCRIPT" 2>&1)"; then
  if ! grep -q CLEANED "$TEST_DIR/trim.log" && echo "$output" | grep -q "leaving both caches alone"; then
    print_result 0 "an unreadable percentage exits cleanly without trimming"
  else
    print_result 1 "expected a clean no-op, got: $output"
  fi
else
  print_result 1 "the script exited non-zero on an unreadable percentage: $output"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
