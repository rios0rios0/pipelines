#!/usr/bin/env bash
# Validation script for the PHPMD runner.
#
# PHPMD 3 replaced the positional `phpmd <paths> <format> <ruleset>` command line with an `analyze`
# command that takes the format and the rule set as options, and reads the PHPMD 2 form's `.` as a
# command name: `Command "." is not defined.`, exit 1, nothing analysed. setup-php installs the
# latest release, so `quality:phpmd` failed on every PHP repository once 3.0.0 shipped, while the
# error itself sat in the report file the job never prints. This pins the form each major is
# called with, that the verdict is PHPMD's own exit code, and that the report holds only what
# PHPMD wrote on stdout.
#
# `phpmd` and `composer` are stubbed. The `phpmd` stub accepts only the form its major accepts, so
# the suite needs neither PHP nor the network.

set -euo pipefail

echo "=== Testing the PHPMD runner ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PHPMD_SCRIPT="$REPO_ROOT/global/scripts/languages/php/phpmd/run.sh"

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

mkdir -p "$TEST_DIR/shim" "$TEST_DIR/home"

# `phpmd --version` prints FAKE_PHPMD_VERSION the way the real one does; every other call is
# recorded in FAKE_PHPMD_CALLS and then parsed the way that major parses it. PHPMD 3 accepts only
# `analyze` and rejects anything else with the real error, and PHPMD 2 reads every argument as a
# positional one, so `analyze` is a path that does not exist. An accepted call writes a JSON
# report to stdout, says FAKE_PHPMD_STDERR on stderr and exits with FAKE_PHPMD_EXIT.
cat > "$TEST_DIR/shim/phpmd" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "PHPMD $FAKE_PHPMD_VERSION"
  exit 0
fi
printf '%s\n' "$*" >> "$FAKE_PHPMD_CALLS"
case "$FAKE_PHPMD_VERSION" in
  3.*)
    if [ "${1:-}" != "analyze" ]; then
      printf '\n  Command "%s" is not defined.\n\n' "${1:-}" >&2
      exit 1
    fi
    ;;
  *)
    if [ "${1:-}" = "analyze" ]; then
      echo 'The given file "analyze" does not exist.' >&2
      exit 1
    fi
    ;;
esac
printf '{"version":"%s","package":"phpmd","files":[]}\n' "$FAKE_PHPMD_VERSION"
[ -n "${FAKE_PHPMD_STDERR:-}" ] && printf '%s\n' "$FAKE_PHPMD_STDERR" >&2
exit "${FAKE_PHPMD_EXIT:-0}"
STUB
chmod +x "$TEST_DIR/shim/phpmd"

# A hosted runner has composer installed, and the script self-updates an installed PHPMD through
# it; the stub keeps that off the network.
cat > "$TEST_DIR/shim/composer" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TEST_DIR/shim/composer"

RUN=0

# run_phpmd <version> <exit> [stderr]
# Runs the real script in a fresh project directory against a `phpmd` of that version. Sets
# OUTPUT and STATUS, CALL to the analysis call phpmd received, and REPORT to the report it wrote.
run_phpmd() {
  RUN=$((RUN + 1))
  local project="$TEST_DIR/project-$RUN"
  local calls="$TEST_DIR/calls-$RUN"
  mkdir -p "$project"
  : > "$calls"
  STATUS=0
  OUTPUT="$(cd "$project" && env -i PATH="$TEST_DIR/shim:$PATH" HOME="$TEST_DIR/home" \
    SCRIPTS_DIR="$REPO_ROOT" FAKE_PHPMD_CALLS="$calls" FAKE_PHPMD_VERSION="$1" \
    FAKE_PHPMD_EXIT="$2" FAKE_PHPMD_STDERR="${3:-}" \
    sh "$PHPMD_SCRIPT" 2>&1)" || STATUS=$?
  CALL="$(cat "$calls")"
  REPORT="$project/build/reports/phpmd/phpmd.json"
}

# =============================================================================
# Test 1: PHPMD 3 is called through its `analyze` command
# =============================================================================
echo "TEST 1: PHPMD 3 is called through its analyze command"
run_phpmd 3.0.0 0
[ "$CALL" = "analyze --format json --ruleset unusedcode --no-progress ." ] \
  && print_result 0 "the format and the rule set are passed as options" \
  || print_result 1 "PHPMD 3 should be called through analyze, was called with: $CALL"
[ "$STATUS" -eq 0 ] \
  && print_result 0 "a clean PHPMD 3 run exits 0" \
  || print_result 1 "a clean PHPMD 3 run should exit 0, exited $STATUS: $OUTPUT"

# =============================================================================
# Test 2: PHPMD 2 keeps the positional form it has no alternative to
# =============================================================================
echo "TEST 2: PHPMD 2 keeps the positional form"
# The build string the 2.15.0 phar really reports, so the version probe is tested on it.
run_phpmd 2.15.0snapshot202312110823 0
[ "$CALL" = ". json unusedcode" ] \
  && print_result 0 "a persistent agent on PHPMD 2 still gets the positional form" \
  || print_result 1 "PHPMD 2 should get the positional form, was called with: $CALL"
[ "$STATUS" -eq 0 ] \
  && print_result 0 "a clean PHPMD 2 run exits 0" \
  || print_result 1 "a clean PHPMD 2 run should exit 0, exited $STATUS: $OUTPUT"

# =============================================================================
# Test 3: the verdict is PHPMD's own exit code, on either major
# =============================================================================
echo "TEST 3: the verdict is PHPMD's own exit code, on either major"
# 2 is "violations found" and 3 is "a file could not be processed" on both majors.
for version in 3.0.0 2.15.0; do
  for verdict in 2 3; do
    run_phpmd "$version" "$verdict"
    [ "$STATUS" -eq "$verdict" ] \
      && print_result 0 "PHPMD $version exiting $verdict fails the job with $verdict" \
      || print_result 1 "PHPMD $version exiting $verdict should exit $verdict, exited $STATUS: $OUTPUT"
  done
done

# =============================================================================
# Test 4: a run that stopped says why in the log, never in the report
# =============================================================================
echo "TEST 4: a run that stopped says why in the log, never in the report"
run_phpmd 3.0.0 1 "stub: the rule set could not be loaded"
[ "$STATUS" -eq 1 ] \
  && print_result 0 "an error keeps its exit code" \
  || print_result 1 "an error should exit 1, exited $STATUS: $OUTPUT"
echo "$OUTPUT" | grep -q "stub: the rule set could not be loaded" \
  && print_result 0 "PHPMD's own error reaches the log" \
  || print_result 1 "PHPMD's error should be in the log: $OUTPUT"
if [ -f "$REPORT" ] && ! grep -q "stub: the rule set" "$REPORT"; then
  print_result 0 "the report holds only what PHPMD wrote on stdout"
else
  print_result 1 "the report should not contain stderr: $(cat "$REPORT" 2> /dev/null)"
fi
case "$(head -c 1 "$REPORT" 2> /dev/null)" in
  "{") print_result 0 "the report is the JSON document PHPMD wrote" ;;
  *) print_result 1 "the report should start as JSON: $(cat "$REPORT" 2> /dev/null)" ;;
esac

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
