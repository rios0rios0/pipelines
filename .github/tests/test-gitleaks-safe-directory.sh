#!/usr/bin/env bash
# Regression test for the safe.directory step of global/scripts/tools/gitleaks/run.sh.
#
# The runner marks the working tree as trusted in the global Git config. `git config --add` appends a
# line on every run, so a machine that scans many checkouts, or one checkout many times, grew its
# global config by one entry per scan. The step must add the directory once, and leave the other
# entries alone.
#
# The test runs the runner's own block (from `SAFE_DIRECTORY=` to its `fi`), extracted from the
# script, against a throwaway global config (GIT_CONFIG_GLOBAL), never the machine's.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$ROOT/global/scripts/tools/gitleaks/run.sh"
WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

BLOCK="$WORK/block.sh"
awk '/^SAFE_DIRECTORY=/{f=1} f{print} f&&/^fi$/{exit}' "$RUNNER" > "$BLOCK"

export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
CHECKOUT="$WORK/checkout"
mkdir -p "$CHECKOUT"

run_block() { (cd "$CHECKOUT" && sh "$BLOCK"); }
entries() { git config --global --get-all safe.directory 2>/dev/null | grep -Fcx -- "$1" || true; }
total() { git config --global --get-all safe.directory 2>/dev/null | wc -l | tr -d ' '; }

check() {
  local description="$1"; local expected="$2"; local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo -e "${GREEN}PASS${NC} $description"
    TESTS_PASSED=$((TESTS_PASSED+1))
  else
    echo -e "${RED}FAIL${NC} $description (expected=$expected, actual=$actual)"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi
}

echo "=== Gitleaks safe.directory ==="
check "the runner's block is found in run.sh" "yes" "$(grep -q 'safe.directory' "$BLOCK" && echo yes || echo no)"

: > "$GIT_CONFIG_GLOBAL"
run_block
check "the first scan trusts the checkout" "1" "$(entries "$CHECKOUT")"
run_block
run_block
check "later scans of the same checkout add nothing" "1" "$(entries "$CHECKOUT")"

: > "$GIT_CONFIG_GLOBAL"
git config --global --add safe.directory /some/other/checkout
run_block
run_block
check "another trusted directory is kept" "1" "$(entries /some/other/checkout)"
check "and the checkout is added beside it once" "2" "$(total)"

echo ""
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]]
