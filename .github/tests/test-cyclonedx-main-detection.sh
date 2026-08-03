#!/usr/bin/env bash
# Validation script for the Go CycloneDX generator's entry-point detection.
#
# The script under test picks between `cyclonedx-gomod app` (one binary) and
# `cyclonedx-gomod mod` (the whole module). `app -main` accepts exactly ONE path, so a module
# with two entry points used to hand it a newline-separated list and abort with
# `invalid options: - main: "..." does not exist`, producing no BOM at all.
#
# `cyclonedx-gomod` itself is not invoked here: the decision, not the tool, is what regressed.
# A stub on PATH records the command line the script would have run.

set -euo pipefail

echo "=== Testing Go CycloneDX entry-point detection ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CYCLONEDX_SCRIPT="$SCRIPT_DIR/../../global/scripts/languages/golang/cyclonedx/run.sh"

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

# A fake GOPATH whose bin/ holds a cyclonedx-gomod that only records its arguments, plus a `go`
# that answers `go env GOPATH` and swallows `go install` so nothing is downloaded.
FAKE_GOPATH="$TEST_DIR/gopath"
mkdir -p "$FAKE_GOPATH/bin" "$TEST_DIR/shim"

cat > "$FAKE_GOPATH/bin/cyclonedx-gomod" <<'STUB'
#!/usr/bin/env bash
# Record the invocation, then write a placeholder BOM at the -output path.
echo "$@" > "$INVOCATION_LOG"
previous=""
for arg in "$@"; do
  if [ "$previous" = "-output" ]; then
    mkdir -p "$(dirname "$arg")"
    echo '{}' > "$arg"
  fi
  previous="$arg"
done
STUB
chmod +x "$FAKE_GOPATH/bin/cyclonedx-gomod"

cat > "$TEST_DIR/shim/go" <<STUB
#!/usr/bin/env bash
case "\$1 \${2:-}" in
  "env GOPATH") echo "$FAKE_GOPATH" ;;
  "install "*) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TEST_DIR/shim/go"

# Run the generator inside a throwaway module laid out by the caller.
# Usage: run_generator <workdir>
run_generator() {
  local workdir="$1"
  export INVOCATION_LOG="$workdir/invocation.log"
  : > "$INVOCATION_LOG"

  (
    cd "$workdir" || exit 1
    PATH="$TEST_DIR/shim:$PATH" \
    GOPATH="$FAKE_GOPATH" \
    REPORT_PATH="build/reports" \
    PREFIX="" \
      sh "$CYCLONEDX_SCRIPT" > "$workdir/stdout.log" 2>&1
  )
}

new_module() {
  local workdir
  workdir="$(mktemp -d "$TEST_DIR/module-XXXXXX")"
  printf 'module example.test\n\ngo 1.24\n' > "$workdir/go.mod"
  echo "$workdir"
}

# =============================================================================
# Test 1: one entry point -> `app` mode, with that single path
# =============================================================================
echo "TEST 1: a module with ONE main package uses 'app' mode"
workdir="$(new_module)"
mkdir -p "$workdir/cmd"
echo 'package main' > "$workdir/cmd/main.go"
run_generator "$workdir"
invocation="$(cat "$workdir/invocation.log")"
if [[ "$invocation" == app\ * ]] && [[ "$invocation" == *"-main ./cmd"* ]]; then
  print_result 0 "single main package resolves to 'app -main ./cmd'"
else
  print_result 1 "expected 'app ... -main ./cmd', got: $invocation"
fi

# =============================================================================
# Test 2: two entry points -> `mod` mode, and never a multi-line -main
# =============================================================================
echo "TEST 2: a module with TWO main packages falls back to 'mod' mode"
workdir="$(new_module)"
mkdir -p "$workdir/cmd" "$workdir/cmd/worker"
echo 'package main' > "$workdir/cmd/main.go"
echo 'package main' > "$workdir/cmd/worker/main.go"
run_generator "$workdir"
invocation="$(cat "$workdir/invocation.log")"
if [[ "$invocation" == mod\ * ]]; then
  print_result 0 "two main packages resolve to 'mod' mode"
else
  print_result 1 "expected 'mod ...', got: $invocation"
fi

if [[ "$invocation" != *"-main"* ]]; then
  print_result 0 "'mod' mode passes no -main flag"
else
  print_result 1 "-main must not be passed in 'mod' mode: $invocation"
fi

# The regression itself: a newline-separated list reaching -main.
if [ "$(wc -l < "$workdir/invocation.log")" -eq 1 ]; then
  print_result 0 "the invocation is a single line (no multi-line -main value)"
else
  print_result 1 "the invocation spans several lines: $invocation"
fi

# =============================================================================
# Test 3: two entry points still produce a BOM
# =============================================================================
echo "TEST 3: a module with two main packages still writes a BOM"
if [ -f "$workdir/build/reports/bom.json" ]; then
  print_result 0 "bom.json exists for a multi-entry-point module"
else
  print_result 1 "no bom.json was written: $(cat "$workdir/stdout.log")"
fi

# =============================================================================
# Test 4: a pkg/ directory keeps taking `mod` mode, unchanged
# =============================================================================
echo "TEST 4: a module with a pkg/ directory uses 'mod' mode"
workdir="$(new_module)"
mkdir -p "$workdir/pkg" "$workdir/cmd"
echo 'package example' > "$workdir/pkg/example.go"
echo 'package main' > "$workdir/cmd/main.go"
run_generator "$workdir"
invocation="$(cat "$workdir/invocation.log")"
if [[ "$invocation" == mod\ * ]]; then
  print_result 0 "pkg/ takes precedence and resolves to 'mod' mode"
else
  print_result 1 "expected 'mod ...', got: $invocation"
fi

# =============================================================================
# Test 5: no entry point at all -> a clear failure, not a silent empty BOM
# =============================================================================
echo "TEST 5: a module with NO main package fails loudly"
workdir="$(new_module)"
mkdir -p "$workdir/internal"
echo 'package internal' > "$workdir/internal/example.go"
if run_generator "$workdir"; then
  print_result 1 "expected a non-zero exit when no main package exists"
else
  print_result 0 "a module with no main package exits non-zero"
fi

if grep -q "Could not find a directory containing Go files" "$workdir/stdout.log"; then
  print_result 0 "the failure names the missing entry point"
else
  print_result 1 "the failure message is missing: $(cat "$workdir/stdout.log")"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
