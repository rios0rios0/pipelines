#!/usr/bin/env bash
# Regression test for fixture isolation in `.github/tests/*.sh`.
#
# These suites build throwaway git repositories and project trees and then run the real scripts
# against them. Two habits decide whether a suite that CANNOT build its fixture fails, or quietly
# runs against the repository it was launched from:
#
#   1. **Scratch space comes from `mktemp`**, never from a hardcoded `/tmp/...`. `/tmp` is not
#      guaranteed to exist and, where it does, is not guaranteed to be writable by whoever runs
#      `make test` -- on Termux/Android it is owned by another user with mode 771. `mktemp` honours
#      `TMPDIR`, which is the one place every platform agrees a process may write.
#
#   2. **Every `cd` is guarded.** None of these suites sets `-e`, by design: they count failures
#      rather than abort on the first one. That makes an unchecked `cd` the most dangerous line in
#      the file, because the *next* command runs somewhere unintended rather than not at all.
#
# Both were violated at once on 2026-09-08, and the two compounded exactly as you would fear.
# `test-basic-checks.sh` built its fixtures in `/tmp/basic-checks-test-<name>`; on a host where
# that path could not be created, `setup_repo`'s `cd "$work_dir"` failed inside a command
# substitution and the subshell carried on in the repository under test. The `git init`,
# `git config` and `git commit` calls meant for the fixture ran against `rios0rios0/pipelines`
# itself: `CHANGELOG.md` was truncated from 1332 lines to a 9-line stub in a commit authored by
# `test <test@test>`, the clone's `user.name` and `user.email` were rewritten to match, and every
# commit made afterwards inherited that identity. Recovering it took a rebase, an amend and a
# force-push.
#
# So the fix is asserted rather than remembered. A suite that reintroduces either habit fails here.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_empty() {
  local description="$1" findings="$2"
  if [[ -z "$findings" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    printf '%s\n' "$findings" | sed 's/^/        /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

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

# A literal `/tmp/...` is allowed only where nothing creates, enters or deletes it -- a string
# handed to a stub and read back out of its recorded argv, or a payload a security test proves
# never reaches its target. Each entry is `<file>|<literal>|<why>`, and an unlisted one fails:
# that is the point, so adding a new `/tmp` path is a decision somebody makes on purpose.
TMP_ALLOWLIST=(
  "test-dependency-check.sh|DEPENDENCY_CHECK_DATA_DIR='/tmp/custom-nvd'|a value passed to a stubbed build tool; nothing creates it"
  "test-dependency-check.sh|-DdataDirectory=/tmp/custom-nvd|the same value, grepped back out of the stub's recorded argv"
  "test-dependency-track.sh|/tmp/pwned|a curl-config injection payload this test proves never reaches curl; nothing writes it"
  "test-fixture-isolation.sh|grep -n '/tmp/'|this scanner's own pattern"
  "test-fixture-isolation.sh|rm -rf /tmp/basic-checks-test-|the assertion below that the old shared-glob cleanup is gone"
  "test-fixture-isolation.sh|test-dependency-check.sh|this allowlist's own rows"
  "test-fixture-isolation.sh|test-dependency-track.sh|this allowlist's own rows"
)

allowed() {
  local file="$1" line="$2" entry allow_file allow_literal
  for entry in "${TMP_ALLOWLIST[@]}"; do
    allow_file="${entry%%|*}"
    allow_literal="${entry#*|}"
    allow_literal="${allow_literal%%|*}"
    [[ "$file" == "$allow_file" && "$line" == *"$allow_literal"* ]] && return 0
  done
  return 1
}

echo "=== Fixture isolation ==="
echo ""
echo "Test 1: scratch space comes from mktemp, not a hardcoded /tmp"

FINDINGS=''
for script in "$TESTS_DIR"/*.sh; do
  name="$(basename "$script")"
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    number="${hit%%:*}"
    text="${hit#*:}"
    # A comment cannot create a directory.
    [[ "$text" =~ ^[[:space:]]*# ]] && continue
    allowed "$name" "$text" && continue
    FINDINGS="${FINDINGS}${name}:${number}: hardcodes /tmp -- use \"\$(mktemp -d)\" so it follows TMPDIR"$'\n'
  done < <(grep -n '/tmp/' "$script" || true)
done
assert_empty "no suite builds its fixtures in a hardcoded /tmp" "$FINDINGS"

echo ""
echo "Test 2: every cd is guarded"

FINDINGS=''
for script in "$TESTS_DIR"/*.sh; do
  name="$(basename "$script")"
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    number="${hit%%:*}"
    text="${hit#*:}"
    # A continued command carries its guard on the next physical line.
    while [[ "$text" == *\\ ]]; do
      number_next=$((number + 1))
      text="${text%\\}$(sed -n "${number_next}p" "$script")"
      number=$number_next
    done
    [[ "$text" == *'||'* || "$text" == *'&&'* ]] && continue
    FINDINGS="${FINDINGS}${name}:${number}: unguarded cd -- add '|| exit 1', so a missing directory stops the suite instead of redirecting it at the repository"$'\n'
  done < <(grep -nE '^[[:space:]]*cd[[:space:]]' "$script" || true)
done
assert_empty "no suite continues in the wrong directory after a failed cd" "$FINDINGS"

echo ""
echo "Test 3: the suite that caused the incident carries both fixes"

BASIC="$TESTS_DIR/test-basic-checks.sh"
assert_true "test-basic-checks.sh roots its fixtures in mktemp -d" \
  "grep -q 'TEST_TMPDIR=\"\$(mktemp -d)\"' '$BASIC'"
assert_true "...cleans up only what it created, not a shared glob" \
  "grep -q 'rm -rf \"\$TEST_TMPDIR\"' '$BASIC' && ! grep -v '^[[:space:]]*#' '$BASIC' | grep -q 'rm -rf /tmp/basic-checks-test-'"
assert_true "...refuses an empty fixture path, which a bare cd would accept" \
  "grep -q 'WORK_DIR:?' '$BASIC'"
assert_true "...checks the git calls that build the fixture" \
  "grep -q 'setup_repo: could not create the bare fixture' '$BASIC' && grep -q 'setup_repo: could not clone the fixture' '$BASIC'"

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
