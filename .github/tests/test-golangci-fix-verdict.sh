#!/usr/bin/env bash
# The verdict of `golangci-lint/run.sh --fix`, the run `make lint` makes, against the one CI makes.
#
# CI lints the commit without `--fix` and fails on every finding. `make lint` runs with `--fix`,
# which rewrites what a fixer can fix -- every formatter finding (goimports, golines) and the
# linters' suggested fixes -- and golangci-lint then reports only what is left. A run that fixed
# everything therefore printed `0 issues` and passed, while CI failed the same code: a golines
# finding reached a default branch that way. The runner now compares the Go sources before and
# after a `--fix` run and fails when it rewrote any, naming each file, so both runs reach the same
# verdict and the fixes stay in the working tree to be committed.
#
# The suite runs the real script and the pinned golangci-lint (downloaded and verified once, then
# reused from PATH) on throwaway modules:
#   1. without `--fix`, an unformatted file fails the run and is left as it is, as on CI
#   2. with `--fix`, the same file is rewritten, the run fails, and it names the file
#   3. a second `--fix` run, with nothing left to fix, passes and rewrites nothing
#   4. in a git work tree, uncommitted changes the fix does not touch are not named
#   5. outside a git work tree a rewrite fails the run too
#   6. a run that fails on a finding no fixer can fix keeps failing, and still names what it fixed

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
export SCRIPTS_DIR
RUN_SH="$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/run.sh"
TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_true() {
  local description="$1" condition="$2"
  if eval "$condition"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# Fixture commits run no hook: a developer's global core.hooksPath is not part of what this suite
# tests, and it has no business reading the fixtures.
mkdir -p "$TEST_DIR/no-hooks"
fixture_git() {
  git -c user.name='fixture' -c user.email='fixture@example.invalid' -c init.defaultBranch='main' \
    -c core.hooksPath="$TEST_DIR/no-hooks" "$@"
}

# write_unformatted <dir>: the one fault the shared configuration finds in a fixture module, the
# indentation and spacing of `verdict.go`, which goimports fixes.
write_unformatted() {
  printf '%s\n' \
    '// Package verdict holds one function the lint has to format.' \
    'package verdict' \
    '' \
    '// Sum returns the sum of its two arguments.' \
    'func Sum(first, second int) int {' \
    '    return first+second' \
    '}' > "$1/verdict.go"
}

# make_module <dir>: a module whose only fault is that one.
make_module() {
  mkdir -p "$1" || return 1
  printf 'module example.com/verdict\n\ngo 1.27\n' > "$1/go.mod"
  write_unformatted "$1"
}

# run_lint <dir> [--fix]: runs the script in <dir>; its output goes to <dir>.log, without the colour
# codes golangci-lint writes (`--color always`), and its exit status is printed.
ESCAPE="$(printf '\033')"
run_lint() {
  local dir="$1" status=0
  shift
  (cd "$dir" && "$RUN_SH" "$@") > "$dir.raw.log" 2>&1 || status=$?
  sed "s/${ESCAPE}\[[0-9;]*m//g" "$dir.raw.log" > "$dir.log"
  echo "$status"
}

checksum() { cksum < "$1"; }

echo "Testing the verdict of golangci-lint/run.sh --fix..."

echo ""
echo "Test 1: without --fix, as on CI, an unformatted file fails the run and stays as it is"
# given
CI_MODULE="$TEST_DIR/ci"
make_module "$CI_MODULE" || exit 1
BEFORE="$(checksum "$CI_MODULE/verdict.go")"

# when
STATUS="$(run_lint "$CI_MODULE")"

# then
[ "$STATUS" -ne 0 ] || cat "$CI_MODULE.log"
assert_true "the run fails" "[ '$STATUS' -ne 0 ]"
assert_true "it reports the formatting finding" "grep -q 'verdict.go:6:1: File is not properly formatted (goimports)' '$CI_MODULE.log'"
assert_true "the file is left as it was" "[ '$BEFORE' = '$(checksum "$CI_MODULE/verdict.go")' ]"

# Every later run reuses the binary the first one installed and verified, instead of downloading it
# into each module's ./bin again.
if [ -x "$CI_MODULE/bin/golangci-lint" ]; then
  export PATH="$CI_MODULE/bin:$PATH"
fi

echo ""
echo "Test 2: with --fix, the file is rewritten, and the run fails naming it"
# given
FIX_MODULE="$TEST_DIR/fix"
make_module "$FIX_MODULE" || exit 1
fixture_git -C "$FIX_MODULE" init -q || exit 1
fixture_git -C "$FIX_MODULE" add -A || exit 1
fixture_git -C "$FIX_MODULE" commit -q -m 'fixture' || exit 1

# when
STATUS="$(run_lint "$FIX_MODULE" --fix .)"

# then
assert_true "the run fails" "[ '$STATUS' -ne 0 ]"
assert_true "golangci-lint itself found nothing left to report" "grep -q '0 issues' '$FIX_MODULE.log'"
assert_true "the run says it rewrote one file, and why it fails" \
  "grep -q 'golangci-lint --fix rewrote 1 file(s) in place. CI lints without --fix' '$FIX_MODULE.log'"
assert_true "it names the file" "grep -qx '  fixed: verdict.go' '$FIX_MODULE.log'"
assert_true "the file is fixed in place" "grep -qx '	return first + second' '$FIX_MODULE/verdict.go'"

echo ""
echo "Test 3: a second --fix run, with nothing left to fix, passes and rewrites nothing"
# given
BEFORE="$(checksum "$FIX_MODULE/verdict.go")"

# when
STATUS="$(run_lint "$FIX_MODULE" --fix .)"

# then
[ "$STATUS" -eq 0 ] || cat "$FIX_MODULE.log"
assert_true "the run passes" "[ '$STATUS' -eq 0 ]"
assert_true "it names no file" "! grep -q 'fixed:' '$FIX_MODULE.log'"
assert_true "the file is unchanged" "[ '$BEFORE' = '$(checksum "$FIX_MODULE/verdict.go")' ]"

echo ""
echo "Test 4: in a git work tree, uncommitted changes the fix does not touch are not named"
# given: the fixed module committed, a clean file changed but not committed, a clean untracked file,
# and the fault back in verdict.go.
fixture_git -C "$FIX_MODULE" commit -q -am 'fixed' || exit 1
printf '%s\n' 'package verdict' '' \
  '// Twice returns twice its argument.' 'func Twice(value int) int {' '	return Sum(value, value)' '}' \
  > "$FIX_MODULE/twice.go"
fixture_git -C "$FIX_MODULE" add twice.go || exit 1
fixture_git -C "$FIX_MODULE" commit -q -m 'twice' || exit 1
printf '%s\n' '' '// Thrice returns three times its argument.' 'func Thrice(value int) int {' \
  '	return Sum(value, Twice(value))' '}' >> "$FIX_MODULE/twice.go"
printf '%s\n' 'package verdict' '' \
  '// Zero returns zero.' 'func Zero() int {' '	return Sum(0, 0)' '}' > "$FIX_MODULE/zero.go"
write_unformatted "$FIX_MODULE"

# when
STATUS="$(run_lint "$FIX_MODULE" --fix .)"

# then
assert_true "the run fails" "[ '$STATUS' -ne 0 ]"
assert_true "it names the file it rewrote" "grep -qx '  fixed: verdict.go' '$FIX_MODULE.log'"
assert_true "it names nothing else" "[ \"\$(grep -c 'fixed:' '$FIX_MODULE.log')\" -eq 1 ]"

echo ""
echo "Test 5: outside a git work tree a rewrite fails the run too"
# given
PLAIN_MODULE="$TEST_DIR/plain"
make_module "$PLAIN_MODULE" || exit 1

# when
STATUS="$(run_lint "$PLAIN_MODULE" --fix .)"

# then
assert_true "the run fails" "[ '$STATUS' -ne 0 ]"
assert_true "it names the file" "grep -qx '  fixed: ./verdict.go' '$PLAIN_MODULE.log'"

echo ""
echo "Test 6: a finding no fixer can fix still fails the run, which also names what it fixed"
# given: the formatting fault, and an error nobody checks, which no fixer can fix.
MIXED_MODULE="$TEST_DIR/mixed"
make_module "$MIXED_MODULE" || exit 1
printf '%s\n' 'package verdict' '' \
  'import "os"' '' '// Clean removes a file it never checks.' 'func Clean() {' '	os.Remove("fixture")' '}' \
  > "$MIXED_MODULE/clean.go"

# when
STATUS="$(run_lint "$MIXED_MODULE" --fix .)"

# then
assert_true "the run fails" "[ '$STATUS' -ne 0 ]"
assert_true "it reports the finding it could not fix" "grep -q '^clean.go:7:2: ' '$MIXED_MODULE.log'"
assert_true "it names the file it rewrote" "grep -qx '  fixed: ./verdict.go' '$MIXED_MODULE.log'"

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
