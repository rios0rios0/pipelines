#!/usr/bin/env bash
# Regression test for global/scripts/languages/golang/cross-compile/run.sh.
#
# The Go pipeline checks its six targets in ONE job now, so the runner's all-targets mode is what CI
# runs, and three of its properties decide whether that job can be trusted: every target is checked,
# no more of them run at once than CROSS_COMPILE_JOBS allows (each `go vet` holds a type-checked copy
# of the module, and a private repository's hosted runner has two CPUs and 7 GB), and a failing
# target fails the job and is named, while the others still run. `go` is stubbed, so the cases are
# about the runner rather than about any module.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$SCRIPT_DIR/global/scripts/languages/golang/cross-compile/run.sh"
EXIT_CODE=0
PASSED=0

echo "[test-go-cross-compile] testing the Go cross-compile runner..." >&2

if [ ! -x "$RUNNER" ]; then
    echo "[test-go-cross-compile] FAIL: runner not found or not executable at $RUNNER" >&2
    exit 1
fi

SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

pass() { PASSED=$((PASSED + 1)); echo "[test-go-cross-compile] PASS: $1" >&2; }
fail() { EXIT_CODE=1; echo "[test-go-cross-compile] FAIL: $1" >&2; }

# A `go` that records each `go vet` it is asked for, holds it open for a moment so overlapping runs
# are visible, tracks how many run at once, and fails for the target named in FAIL_TARGET.
BIN="$SANDBOX/bin"
mkdir -p "$BIN"
cat > "$BIN/go" <<'STUB'
#!/usr/bin/env bash
state="$STUB_STATE"
target="${GOOS}/${GOARCH}"
echo "$target" >> "$state/called"
mkdir "$state/running.$GOOS.$GOARCH"
now="$(find "$state" -maxdepth 1 -name 'running.*' | wc -l)"
echo "$now" >> "$state/concurrency"
echo "vet output for $target"
sleep 0.3
rmdir "$state/running.$GOOS.$GOARCH"
if [ "$target" = "${FAIL_TARGET:-}" ]; then
    echo "type error on $target" >&2
    exit 1
fi
exit 0
STUB
chmod +x "$BIN/go"

# Runs the runner from a scratch module directory with the stub first on PATH.
run_case() {
    local name="$1" jobs="$2" failing="$3"
    local state="$SANDBOX/$name"
    mkdir -p "$state/module"
    (
        cd "$state/module" || exit 1
        env PATH="$BIN:$PATH" STUB_STATE="$state" FAIL_TARGET="$failing" CROSS_COMPILE_JOBS="$jobs" \
            "$RUNNER" > "$state/out" 2>&1
    )
    echo $? > "$state/status"
}

peak() { sort -n "$1/concurrency" | tail -n 1; }

# --- every target passes, two at a time ------------------------------------------
run_case all-pass 2 ''
state="$SANDBOX/all-pass"
[ "$(cat "$state/status")" = 0 ] && pass "exits 0 when every target passes" || fail "exits non-zero though every target passes"
[ "$(sort -u "$state/called" | wc -l)" = 6 ] && pass "checks all six targets" || fail "checked $(sort -u "$state/called" | wc -l) targets, not six"
[ "$(peak "$state")" -le 2 ] && pass "never runs more than CROSS_COMPILE_JOBS=2 at once" || fail "ran $(peak "$state") at once with CROSS_COMPILE_JOBS=2"
[ "$(peak "$state")" -eq 2 ] && pass "runs targets in parallel up to the limit" || fail "never ran two at once with CROSS_COMPILE_JOBS=2"
grep -q 'Cross-compilation check passed for all targets' "$state/out" && pass "reports the pass" || fail "does not report the pass"

# --- one target fails: the job fails, names it, and still checks the rest --------
run_case one-fails 3 'windows/arm64'
state="$SANDBOX/one-fails"
[ "$(cat "$state/status")" != 0 ] && pass "exits non-zero when a target fails" || fail "exits 0 though windows/arm64 failed"
grep -q '^FAIL: windows/arm64$' "$state/out" && pass "names the failing target" || fail "does not name the failing target"
grep -q 'Cross-compilation check failed for: windows/arm64$' "$state/out" && pass "lists only the failing target at the end" || fail "the closing line does not list exactly the failing target"
[ "$(sort -u "$state/called" | wc -l)" = 6 ] && pass "still checks every other target" || fail "stopped after the failure"

# --- each target's output is printed whole, in target order ----------------------
run_case blocks 6 ''
state="$SANDBOX/blocks"
order="$(grep -o '^=== Type-checking for [a-z0-9/]*' "$state/out" | sed 's/^=== Type-checking for //' | tr '\n' ' ')"
[ "$order" = 'linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64 windows/arm64 ' ] \
    && pass "prints each target's block in target order" || fail "prints the blocks as '$order'"
interleaved="$(awk '/^=== Type-checking for / { if (open) bad = 1; open = 1 } /^PASS: / { open = 0 } END { exit !bad }' "$state/out" && echo yes)"
[ -z "$interleaved" ] && pass "never interleaves one target's output with another's" || fail "interleaves target output"

# --- a limit that is not a positive integer runs one at a time -------------------
run_case bad-limit 'x' ''
state="$SANDBOX/bad-limit"
[ "$(cat "$state/status")" = 0 ] && [ "$(peak "$state")" -eq 1 ] \
    && pass "reads an unusable CROSS_COMPILE_JOBS as 1" || fail "an unusable CROSS_COMPILE_JOBS ran $(peak "$state") at once"

# --- single-target mode is unchanged --------------------------------------------
state="$SANDBOX/single"
mkdir -p "$state/module"
(
    cd "$state/module" || exit 1
    env PATH="$BIN:$PATH" STUB_STATE="$state" CROSS_GOOS=darwin CROSS_GOARCH=arm64 "$RUNNER" > "$state/out" 2>&1
)
[ "$(cat "$state/called")" = 'darwin/arm64' ] && pass "single-target mode checks only that target" || fail "single-target mode checked '$(tr '\n' ' ' < "$state/called")'"

echo "[test-go-cross-compile] $PASSED passed" >&2
if [ "$EXIT_CODE" -ne 0 ]; then
    echo "[test-go-cross-compile] FAILED" >&2
    exit 1
fi
echo "[test-go-cross-compile] all checks passed" >&2
