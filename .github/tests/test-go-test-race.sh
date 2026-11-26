#!/usr/bin/env bash
# The race detector of global/scripts/languages/golang/test/run.sh (`GO_TEST_RACE`).
#
# The shared Go test run never ran `-race`, so a real data race in a consumer's code was visible
# only on a developer's machine. `GO_TEST_RACE` turns the detector on, and it is opt-in: `off` by
# default, `unit` (or `true`) for the unit phase, `all` for both phases. `-race` needs cgo and a C
# compiler and refuses `-covermode=count`, so the run fails with the reason when either is missing,
# and records `atomic` coverage while the detector is on.
#
# Every case drives the real run.sh against a fixture module whose tests race on purpose: each
# test passes without the detector and fails under it, so the verdict pins which phases actually
# ran `-race`, not the script's text. The last cases pin the `race` input that carries the switch
# on GitHub Actions.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_SH="$SCRIPT_DIR/global/scripts/languages/golang/test/run.sh"
EXIT_CODE=0
PASSED=0

echo "[test-go-test-race] testing GO_TEST_RACE..." >&2

if [ ! -f "$RUN_SH" ]; then
    echo "[test-go-test-race] FAIL: runner not found at $RUN_SH" >&2
    exit 1
fi

if ! command -v go > /dev/null 2>&1; then
    echo "[test-go-test-race] SKIP: go is not on PATH." >&2
    exit 0
fi

SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

pass() { PASSED=$((PASSED + 1)); echo "[test-go-test-race] PASS: $1" >&2; }
fail() { EXIT_CODE=1; echo "[test-go-test-race] FAIL: $1" >&2; }

check() {
    local description="$1" actual="$2" expected="$3"

    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description"
        echo "    expected: [$expected]" >&2
        echo "    actual:   [$actual]" >&2
    fi
}

# A module with two packages, each racing on purpose: two goroutines increment one counter with
# nothing ordering them. `counter` races in an untagged unit test, `store` in an integration-tagged
# one, which only the integration phase selects.
RACY="$SANDBOX/racy"
mkdir -p "$RACY/internal/counter" "$RACY/internal/store" || exit 1
cat > "$RACY/go.mod" << 'EOF'
module example.com/race/racy

go 1.25
EOF
for package in counter store; do
    cat > "$RACY/internal/$package/$package.go" << EOF
package $package

// Count increments one counter from two goroutines with nothing ordering the increments.
func Count() int {
	n := 0
	done := make(chan struct{})
	go func() {
		n++
		close(done)
	}()
	n++
	<-done
	return n
}
EOF
done
cat > "$RACY/internal/counter/counter_test.go" << 'EOF'
package counter

import "testing"

func TestCountInTheUnitPhase(t *testing.T) {
	if Count() < 1 {
		t.Fatal("no increment")
	}
}
EOF
cat > "$RACY/internal/store/store_integration_test.go" << 'EOF'
//go:build integration

package store

import "testing"

func TestCountInTheIntegrationPhase(t *testing.T) {
	if Count() < 1 {
		t.Fatal("no increment")
	}
}
EOF

# A module whose only test is free of races.
CLEAN="$SANDBOX/clean"
mkdir -p "$CLEAN/internal/clean" || exit 1
cat > "$CLEAN/go.mod" << 'EOF'
module example.com/race/clean

go 1.25
EOF
cat > "$CLEAN/internal/clean/clean.go" << 'EOF'
package clean

// Double has no goroutines to race.
func Double(n int) int { return 2 * n }
EOF
cat > "$CLEAN/internal/clean/clean_test.go" << 'EOF'
package clean

import "testing"

func TestDouble(t *testing.T) {
	if Double(2) != 4 {
		t.Fatal("unexpected value")
	}
}
EOF

# run_runner <module> <case> [NAME=value ...]: runs run.sh in the module with the variables given
# and GO_TEST_RACE otherwise unset; sets RC and LOG (the path of its output).
run_runner() {
    local module="$1" name="$2"
    shift 2
    LOG="$SANDBOX/$name.log"
    (cd "$module" || exit 1; env -u GO_TEST_RACE "$@" "$RUN_SH") > "$LOG" 2>&1
    RC=$?
}
# plain_log: the run's output without colour. gotestsum colours its summary when it detects a CI
# runner, which puts an escape sequence between `FAIL` and the colon after it.
plain_log() { sed 's/\x1b\[[0-9;]*m//g' "$LOG"; }
# failed_test <test name>: "yes" when the runner reported that test failing.
failed_test() { plain_log | grep -qE "FAIL:? .*$1" && echo yes || echo no; }
said() { plain_log | grep -qF -- "$1" && echo yes || echo no; }
mode_of() { head -1 "$1/coverage.txt" 2>/dev/null || echo 'no coverage.txt'; }

echo "== off by default: the racing tests pass ==" >&2
run_runner "$RACY" default
check "the run passes" "$RC" "0"
check "without announcing the detector" "$(said 'Race detector: on')" "no"
check "and coverage stays in count mode" "$(mode_of "$RACY")" "mode: count"

echo "== unit: the unit phase runs -race, the integration phase does not ==" >&2
run_runner "$RACY" unit GO_TEST_RACE=unit
check "the run fails" "$([ "$RC" -ne 0 ] && echo failed || echo passed)" "failed"
check "saying so before the tests" "$(said 'Race detector: on in the unit phase (GO_TEST_RACE=unit).')" "yes"
check "on the race the detector reported" "$(said 'WARNING: DATA RACE')" "yes"
check "in the unit test" "$(failed_test TestCountInTheUnitPhase)" "yes"
check "while the integration test passes without the detector" "$(failed_test TestCountInTheIntegrationPhase)" "no"
check "with both profiles in atomic mode" "$(mode_of "$RACY")" "mode: atomic"

echo "== true: the same as unit ==" >&2
run_runner "$RACY" true GO_TEST_RACE=true
check "the run fails on the unit test alone" \
    "$(failed_test TestCountInTheUnitPhase)/$(failed_test TestCountInTheIntegrationPhase)" "yes/no"
check "announced as the unit phase" "$(said 'Race detector: on in the unit phase (GO_TEST_RACE=unit).')" "yes"

echo "== all: both phases run -race ==" >&2
run_runner "$RACY" all GO_TEST_RACE=all
check "the run fails" "$([ "$RC" -ne 0 ] && echo failed || echo passed)" "failed"
check "announced for both phases" "$(said 'Race detector: on in the unit and integration phases (GO_TEST_RACE=all).')" "yes"
check "on the unit test and the integration test" \
    "$(failed_test TestCountInTheUnitPhase)/$(failed_test TestCountInTheIntegrationPhase)" "yes/yes"

echo "== a race-free module passes under the detector ==" >&2
run_runner "$CLEAN" clean-all GO_TEST_RACE=all
check "the run passes" "$RC" "0"
check "with coverage in atomic mode" "$(mode_of "$CLEAN")" "mode: atomic"

echo "== an unknown value leaves the detector off, saying so ==" >&2
run_runner "$RACY" unknown GO_TEST_RACE=sometimes
check "the run passes" "$RC" "0"
check "with a warning naming the value" "$(said "GO_TEST_RACE='sometimes' is none of off, unit, all")" "yes"

echo "== no C compiler, or cgo off, fails before any test runs ==" >&2
run_runner "$CLEAN" no-compiler GO_TEST_RACE=unit CC="$SANDBOX/no-such-compiler"
check "a missing compiler fails the run" "$([ "$RC" -ne 0 ] && echo failed || echo passed)" "failed"
check "naming the compiler it could not find" "$(said "the compiler '$SANDBOX/no-such-compiler' (go env CC) is not on PATH")" "yes"
check "before the unit phase starts" "$(said 'PHASE 1: RUNNING UNIT TESTS')" "no"
run_runner "$CLEAN" no-cgo GO_TEST_RACE=unit CGO_ENABLED=0
check "cgo turned off fails the run" "$([ "$RC" -ne 0 ] && echo failed || echo passed)" "failed"
check "saying cgo is off" "$(said '(CGO_ENABLED=0). Unset CGO_ENABLED or set it to 1')" "yes"
check "before the unit phase starts" "$(said 'PHASE 1: RUNNING UNIT TESTS')" "no"

# ── the GitHub path carries the switch as an input ────────────────────────────
# A reusable workflow receives only `inputs` and `secrets`, so a caller's `env:` never reaches
# run.sh. Every Go workflow that runs the tests therefore declares `race` and forwards it, and the
# test action maps it onto GO_TEST_RACE.
echo "== the GitHub path threads race into GO_TEST_RACE ==" >&2

ACTION="$SCRIPT_DIR/github/golang/stages/30-tests/all/action.yaml"
# shellcheck disable=SC2016  # the single-quoted `${{ }}` is the action's expected TEXT, never an expansion
check "the test action maps race onto GO_TEST_RACE" \
    "$(grep -cF 'GO_TEST_RACE: "${{ inputs.race }}"' "$ACTION")" "1"
for workflow in go go-docker go-flyio go-render; do
    file="$SCRIPT_DIR/.github/workflows/$workflow.yaml"
    check "$workflow.yaml declares race, off by default" \
        "$(grep -A3 '^      race:$' "$file" | grep -c "default: 'off'")" "1"
    check "$workflow.yaml forwards race" \
        "$(grep -cE '^ +race: "?\$\{\{ inputs\.race \}\}"?$' "$file")" "1"
done

echo "[test-go-test-race] $PASSED passed" >&2
exit "$EXIT_CODE"
