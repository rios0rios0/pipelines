#!/usr/bin/env bash
# Regression test for phase 2 package narrowing in
# global/scripts/languages/golang/test/run.sh.
#
# Phase 1 runs `-tags test,unit` and phase 2 runs `-tags integration`. When both
# phases were handed the same package list, any consumer whose unit tests carry
# no build tag ran its whole unit suite twice -- serially, under `-p 1` -- and
# saw every test counted twice in the merged junit.xml. Phase 2 now runs only
# the packages whose test file list actually changes under the tag.
#
# Every case below drives the real run.sh rather than a copy of its selection
# logic, so the test cannot drift away from the script it is pinning. The
# assertions are on observable output: the package list the runner logs for
# phase 2, the per-test counts in junit.xml, and the coverage artefacts.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_SH="$SCRIPT_DIR/global/scripts/languages/golang/test/run.sh"
EXIT_CODE=0
PASSED=0

echo "[test-go-integration-scope] testing phase 2 package narrowing..." >&2

if [ ! -f "$RUN_SH" ]; then
    echo "[test-go-integration-scope] FAIL: runner not found at $RUN_SH" >&2
    exit 1
fi

if ! command -v go > /dev/null 2>&1; then
    echo "[test-go-integration-scope] SKIP: go is not on PATH." >&2
    exit 0
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass() { PASSED=$((PASSED + 1)); echo "[test-go-integration-scope] PASS: $1" >&2; }
fail() { EXIT_CODE=1; echo "[test-go-integration-scope] FAIL: $1" >&2; }

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

# Extracts the package list the runner logged for phase 2. The runner prints the
# header below and then one two-space-indented import path per selected package,
# so the block ends at the first line that is not indented that way.
selected_packages() {
    awk '
        /^Testing integration code in the following packages:$/ { grab = 1; next }
        grab && /^  [^ ]/ { sub(/^  /, ""); print; next }
        grab { exit }
    ' "$1"
}

# Writes a module whose five packages cover every branch of the selection.
write_fixture_module() {
    local dir="$1" module="$2"

    mkdir -p "$dir/internal/tagged" "$dir/internal/untagged" \
             "$dir/internal/swap" "$dir/internal/plain" \
             "$dir/internal/shrink"

    cat > "$dir/go.mod" << EOF
module $module

go 1.25
EOF

    # (a) gains a test file under the tag -- must be selected.
    cat > "$dir/internal/tagged/tagged.go" << 'EOF'
package tagged

func Tagged() int { return 1 }
EOF
    cat > "$dir/internal/tagged/tagged_integration_test.go" << 'EOF'
//go:build integration

package tagged

import "testing"

func TestTaggedIntegration(t *testing.T) {
	if Tagged() != 1 {
		t.Fatal("unexpected value")
	}
}
EOF

    # (b) same test files with and without the tag -- must NOT be selected, or it
    # runs a second time here after already running in phase 1.
    cat > "$dir/internal/untagged/untagged.go" << 'EOF'
package untagged

func Untagged() int { return 2 }
EOF
    cat > "$dir/internal/untagged/untagged_test.go" << 'EOF'
package untagged

import "testing"

func TestUntaggedOnly(t *testing.T) {
	if Untagged() != 2 {
		t.Fatal("unexpected value")
	}
}
EOF

    # (c) swaps one !integration file for one integration file. The file COUNT is
    # identical in both listings, so only comparing lists catches this.
    cat > "$dir/internal/swap/swap.go" << 'EOF'
package swap

func Swap() int { return 3 }
EOF
    cat > "$dir/internal/swap/swap_unit_test.go" << 'EOF'
//go:build !integration

package swap

import "testing"

func TestSwapUnit(t *testing.T) {
	if Swap() != 3 {
		t.Fatal("unexpected value")
	}
}
EOF
    cat > "$dir/internal/swap/swap_integration_test.go" << 'EOF'
//go:build integration

package swap

import "testing"

func TestSwapIntegration(t *testing.T) {
	if Swap() != 3 {
		t.Fatal("unexpected value")
	}
}
EOF

    # (d) no test files at all. Selecting it would fail the run outright with
    # "build constraints exclude all Go files".
    cat > "$dir/internal/plain/plain.go" << 'EOF'
package plain

func Plain() int { return 4 }
EOF

    # (e) SHRINKS under the tag: it keeps an untagged test and drops an
    # `!integration` one, so its file list differs while gaining nothing. Merely
    # comparing the two lists for inequality selects it, and the untagged test it
    # still carries then runs a second time in phase 2 -- the duplication this
    # whole block removes. Only a set difference excludes it.
    cat > "$dir/internal/shrink/shrink.go" << 'EOF'
package shrink

func Shrink() int { return 6 }
EOF
    cat > "$dir/internal/shrink/shrink_test.go" << 'EOF'
package shrink

import "testing"

func TestShrinkUntagged(t *testing.T) {
	if Shrink() != 6 {
		t.Fatal("unexpected value")
	}
}
EOF
    cat > "$dir/internal/shrink/shrink_unit_test.go" << 'EOF'
//go:build !integration

package shrink

import "testing"

func TestShrinkExcludedByTheTag(t *testing.T) {
	if Shrink() != 6 {
		t.Fatal("unexpected value")
	}
}
EOF
}

# Writes a module whose only tests are untagged, so phase 2 selects nothing.
write_no_integration_module() {
    local dir="$1" module="$2"

    mkdir -p "$dir/internal/only"

    cat > "$dir/go.mod" << EOF
module $module

go 1.25
EOF

    cat > "$dir/internal/only/only.go" << 'EOF'
package only

func Only() int { return 5 }
EOF
    cat > "$dir/internal/only/only_test.go" << 'EOF'
package only

import "testing"

func TestOnly(t *testing.T) {
	if Only() != 5 {
		t.Fatal("unexpected value")
	}
}
EOF
}

# ── the selection keeps only packages that gain files under the tag ───────────
echo "== phase 2 selects only the packages the tag changes ==" >&2

MIXED="$SANDBOX/mixed"
write_fixture_module "$MIXED" "example.com/scope/mixed"
MIXED_LOG="$SANDBOX/mixed.log"

(cd "$MIXED" && "$RUN_SH") > "$MIXED_LOG" 2>&1
MIXED_RC=$?

if [ "$MIXED_RC" -ne 0 ]; then
    fail "the runner completed on the mixed module (rc=$MIXED_RC)"
    tail -40 "$MIXED_LOG" >&2
else
    pass "the runner completed on the mixed module"
fi

check "only the tag-affected packages are selected" \
    "$(selected_packages "$MIXED_LOG")" \
    "example.com/scope/mixed/internal/swap
example.com/scope/mixed/internal/tagged"

# The selection is printed sorted, which the assertion above already pins: awk
# iterates its associative array in an unspecified order, so without the sort
# this comparison would be flaky rather than wrong.
pass "the selected packages are logged in a deterministic order"

# The actual bug. An untagged test compiled into both phases is reported twice.
UNTAGGED_COUNT="$(grep -c 'name="TestUntaggedOnly"' "$MIXED/junit.xml" 2>/dev/null || true)"
check "an untagged test is reported exactly once in junit.xml" \
    "$UNTAGGED_COUNT" "1"

# The tagged test only exists in phase 2, so it must still be there.
TAGGED_COUNT="$(grep -c 'name="TestTaggedIntegration"' "$MIXED/junit.xml" 2>/dev/null || true)"
check "the integration-tagged test still runs" "$TAGGED_COUNT" "1"

# The swapped package proves the comparison is on file lists, not counts.
SWAP_COUNT="$(grep -c 'name="TestSwapIntegration"' "$MIXED/junit.xml" 2>/dev/null || true)"
check "a package that swaps one tagged file for one untagged file still runs" \
    "$SWAP_COUNT" "1"

# The shrinking package proves the comparison is a set difference, not an
# inequality. Its file list differs under the tag but gains nothing, so selecting
# it would run the untagged test it still carries a second time. The assertion
# above on the selected package list already excludes it; this pins the symptom
# that would reach a consumer's junit.xml.
SHRINK_COUNT="$(grep -c 'name="TestShrinkUntagged"' "$MIXED/junit.xml" 2>/dev/null || true)"
check "a package that only loses files under the tag is reported exactly once" \
    "$SHRINK_COUNT" "1"

# ── an empty selection skips the phase and leaves coverage intact ─────────────
echo "== a module with no integration tests skips phase 2 ==" >&2

NONE="$SANDBOX/none"
write_no_integration_module "$NONE" "example.com/scope/none"
NONE_LOG="$SANDBOX/none.log"

(cd "$NONE" && "$RUN_SH") > "$NONE_LOG" 2>&1
NONE_RC=$?

if [ "$NONE_RC" -ne 0 ]; then
    fail "the runner completed on a module with no integration tests (rc=$NONE_RC)"
    tail -40 "$NONE_LOG" >&2
else
    pass "the runner completed on a module with no integration tests"
fi

if grep -q "skipping this phase" "$NONE_LOG"; then
    pass "the runner reported that phase 2 was skipped"
else
    fail "the runner did not report that phase 2 was skipped"
fi

# Nothing may be selected, so the header is never printed at all.
check "no package list is logged for phase 2" \
    "$(selected_packages "$NONE_LOG")" ""

# The skip writes a lone mode line so the merge step has a file to read. If that
# were missing or malformed, gocovmerge would drop the unit profile on the floor.
if [ -s "$NONE/coverage.txt" ] && [ "$(head -n 1 "$NONE/coverage.txt")" = "mode: count" ]; then
    pass "a well-formed coverage profile is still produced"
else
    fail "a well-formed coverage profile is still produced"
    head -5 "$NONE/coverage.txt" >&2
fi

if grep -q "internal/only/only.go" "$NONE/coverage.txt" 2>/dev/null; then
    pass "the unit coverage survived the empty integration profile"
else
    fail "the unit coverage survived the empty integration profile"
fi

# Run from inside the module: `go tool cover` resolves the profile's paths as
# import paths, so it needs the go.mod to be discoverable.
if (cd "$NONE" && go tool cover -func coverage.txt) > /dev/null 2>&1; then
    pass "the coverage profile parses with the Go toolchain"
else
    fail "the coverage profile parses with the Go toolchain"
fi

# The narrowing must not move coverage. The unit phase already emitted a block
# for every statement, and `-coverpkg` still spans the full package set, so the
# reported total is whatever phase 1 measured.
NONE_TOTAL="$( (cd "$NONE" && go tool cover -func coverage.txt) 2>/dev/null \
    | awk '$1 == "total:" { print $NF }')"
check "the coverage total is unchanged by the skipped phase" "$NONE_TOTAL" "100.0%"

if [ -s "$NONE/cobertura.xml" ] && [ -s "$NONE/junit.xml" ]; then
    pass "the cobertura and junit reports are still generated"
else
    fail "the cobertura and junit reports are still generated"
fi

# ── a package that fails to load must not disable the narrowing ───────────────
# This is the case that makes `go list -e` mandatory. Each element of a pipeline
# runs in a subshell that inherits `set -e`, so a `go list` exiting non-zero
# kills the brace group before the second listing runs. The pipeline still
# reports the exit status of `sort`, so nothing fails loudly -- the "without the
# tag" side is simply empty, every tagged package compares as unique, and the
# narrowing silently reverts to running everything. One unresolved import
# anywhere in the module is enough to trigger it.
echo "== an unloadable package does not disable the narrowing ==" >&2

BROKEN="$SANDBOX/broken"
write_fixture_module "$BROKEN" "example.com/scope/broken"
mkdir -p "$BROKEN/internal/unresolved"
cat > "$BROKEN/internal/unresolved/unresolved.go" << 'EOF'
package unresolved

import "example.com/scope/broken/internal/absent"

func Unresolved() int { return absent.Missing() }
EOF

BROKEN_LOG="$SANDBOX/broken.log"
# The runner is expected to fail here -- the module genuinely does not build.
# The assertion is about what phase 2 selected, not about the exit code.
(cd "$BROKEN" && "$RUN_SH") > "$BROKEN_LOG" 2>&1 || true

check "the narrowing still holds when a package cannot be loaded" \
    "$(selected_packages "$BROKEN_LOG")" \
    "example.com/scope/broken/internal/swap
example.com/scope/broken/internal/tagged"

echo "" >&2
if [ "$EXIT_CODE" -eq 0 ]; then
    echo "[test-go-integration-scope] all $PASSED checks passed" >&2
else
    echo "[test-go-integration-scope] failures detected ($PASSED checks passed)" >&2
fi

exit "$EXIT_CODE"
