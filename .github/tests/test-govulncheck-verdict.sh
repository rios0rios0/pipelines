#!/usr/bin/env bash
# Validation script for the govulncheck verdict.
#
# The pipelines document `sca:govulncheck` as blocking on every platform, yet for as long as the
# script ran `govulncheck -json` and passed its exit code on, no Go pipeline ever failed on a
# vulnerability: with `-json` govulncheck exits 0 whatever it finds. The verdict now comes from
# replaying the report through `govulncheck -mode convert`, which exits 3 when the code calls a
# vulnerable symbol. This pins that decision, and that the report stays parseable JSON.
#
# `go` and `govulncheck` are stubbed so the decision can be exercised for every outcome without
# the network, the vulnerability database or a module that is really vulnerable.

set -euo pipefail

echo "=== Testing the govulncheck verdict ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCAN_SCRIPT="$REPO_ROOT/global/scripts/languages/golang/govulncheck/run.sh"

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

TEST_DIR="$(mktemp -d)" || exit 1
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

mkdir -p "$TEST_DIR/shim" "$TEST_DIR/gobin" "$TEST_DIR/home"

# The pinned version, read the way the script reads it, so the stubbed binary passes the
# staleness check and nothing is installed.
PINNED_VERSION="$(sh -c ". '$REPO_ROOT/global/scripts/shared/pinned-versions.sh' && echo \"\$GOVULNCHECK_VERSION\"")"

# `go` answers what the script asks: where binaries go, which Go it is, and the build info of the
# cached govulncheck. An attempt to install fails the run, because nothing should need one.
cat > "$TEST_DIR/shim/go" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "env GOBIN") echo "$FAKE_GOBIN" ;;
  "env GOPATH") echo "$FAKE_GOBIN" ;;
  "env GOVERSION") echo "go1.99.0" ;;
  "version -m")
    printf '%s: go1.99.0\n\tpath\tgolang.org/x/vuln/cmd/govulncheck\n\tmod\tgolang.org/x/vuln\t%s\th1:stub=\n' \
      "${3:-}" "$FAKE_GOVULNCHECK_VERSION"
    ;;
  "install "*) echo "unexpected go install" >&2; exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TEST_DIR/shim/go"

# `govulncheck -json` writes a one-line report, says FAKE_SCAN_STDERR on stderr and exits with
# FAKE_SCAN_EXIT; `-mode convert` checks the report it is handed is JSON and exits with
# FAKE_CONVERT_EXIT, the way the real one exits 3 for a vulnerability the code calls.
cat > "$TEST_DIR/gobin/govulncheck" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-json" ]; then
  printf '%s\n' '{"config":{"scanner_name":"govulncheck"}}'
  [ -n "${FAKE_SCAN_STDERR:-}" ] && printf '%s\n' "$FAKE_SCAN_STDERR" >&2
  exit "${FAKE_SCAN_EXIT:-0}"
fi
if [ "${1:-} ${2:-}" = "-mode convert" ]; then
  report="$(cat)"
  case "$report" in
    "{"*) ;;
    *) echo "convert: the report is not JSON" >&2; exit 1 ;;
  esac
  echo "Vulnerability #1: GO-0000-0000 (stub)"
  exit "${FAKE_CONVERT_EXIT:-0}"
fi
echo "unexpected govulncheck call: $*" >&2
exit 99
STUB
chmod +x "$TEST_DIR/gobin/govulncheck"

# run_scan <scan-exit> <convert-exit> [scan-stderr]
# Runs the real script in a fresh project directory. Sets OUTPUT and STATUS, and REPORT to the
# report it wrote.
run_scan() {
  local project="$TEST_DIR/project-$RANDOM"
  mkdir -p "$project"
  STATUS=0
  OUTPUT="$(cd "$project" && env -i PATH="$TEST_DIR/shim:$PATH" HOME="$TEST_DIR/home" \
    SCRIPTS_DIR="$REPO_ROOT" FAKE_GOBIN="$TEST_DIR/gobin" FAKE_GOVULNCHECK_VERSION="$PINNED_VERSION" \
    FAKE_SCAN_EXIT="$1" FAKE_CONVERT_EXIT="$2" FAKE_SCAN_STDERR="${3:-}" \
    sh "$SCAN_SCRIPT" 2>&1)" || STATUS=$?
  REPORT="$project/build/reports/govulncheck/govulncheck.json"
}

# =============================================================================
# Test 1: a vulnerability the code calls fails the job
# =============================================================================
echo "TEST 1: a vulnerability the code calls fails the job"
run_scan 0 3
[ "$STATUS" -eq 3 ] \
  && print_result 0 "a reached vulnerability exits 3 although the -json run exited 0" \
  || print_result 1 "a reached vulnerability should exit 3, exited $STATUS: $OUTPUT"
echo "$OUTPUT" | grep -q "GO-0000-0000" \
  && print_result 0 "the findings are printed into the log" \
  || print_result 1 "the findings should be in the log: $OUTPUT"

# =============================================================================
# Test 2: nothing reached passes the job
# =============================================================================
echo "TEST 2: nothing reached passes the job"
run_scan 0 0
[ "$STATUS" -eq 0 ] \
  && print_result 0 "no reached vulnerability exits 0" \
  || print_result 1 "no reached vulnerability should exit 0, exited $STATUS: $OUTPUT"

# =============================================================================
# Test 3: a scan that could not run fails with its reason in the log
# =============================================================================
echo "TEST 3: a scan that could not run fails with its reason in the log"
run_scan 1 0 "loading packages failed: stub reason"
[ "$STATUS" -eq 1 ] \
  && print_result 0 "a failed scan keeps its exit code" \
  || print_result 1 "a failed scan should exit 1, exited $STATUS: $OUTPUT"
echo "$OUTPUT" | grep -q "loading packages failed: stub reason" \
  && print_result 0 "the scan's own error reaches the log" \
  || print_result 1 "the scan's error should be in the log: $OUTPUT"

# =============================================================================
# Test 4: stderr never lands in the report
# =============================================================================
echo "TEST 4: stderr never lands in the report"
run_scan 0 0 "warning: stub progress line"
if [ -f "$REPORT" ] && ! grep -q "stub progress line" "$REPORT"; then
  print_result 0 "the report holds only the JSON govulncheck wrote on stdout"
else
  print_result 1 "the report should not contain stderr: $(cat "$REPORT" 2> /dev/null)"
fi
[ "$STATUS" -eq 0 ] \
  && print_result 0 "a scan that warned still reaches its verdict" \
  || print_result 1 "a warning on stderr should not change the verdict, exited $STATUS: $OUTPUT"

# =============================================================================
# Test 5: an unreadable report fails rather than passes
# =============================================================================
echo "TEST 5: an unreadable report fails rather than passes"
run_scan 0 1
[ "$STATUS" -ne 0 ] \
  && print_result 0 "no verdict is not a pass" \
  || print_result 1 "a report convert cannot read should fail the job: $OUTPUT"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
