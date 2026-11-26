#!/usr/bin/env bash
# Test script for what a Go CodeQL scan's build does to the pipelines checkout (KI-03).
#
# CodeQL's Go autobuilder runs a bare `make` in the source root before it builds the module, and
# in a project that includes `makefiles/common.mk` before its own targets a bare `make` is `setup`:
# it clones this repository into PIPELINES_HOME or fast-forwards the clone already there. Every Go
# scan run by `global/scripts/tools/codeql/run.sh` -- GitLab CI, Azure DevOps and `make codeql` /
# `make sast` -- did that: a clone into the runner's home on every CI scan, and a `git pull
# --ff-only` of a developer's own checkout in the middle of a local scan.
#
# Asserts, with `codeql` replaced by a stub whose `database create` runs a bare `make` in the
# source root the way the autobuilder does:
#   * outside a scan, a bare `make` in such a project is still `setup` and fast-forwards
#     PIPELINES_HOME -- the default goal KI-03 decided to keep
#   * inside a scan the same `make` leaves PIPELINES_HOME where it was, says why, and succeeds
#   * inside a scan nothing is cloned where no checkout exists
#   * only the database build sees PIPELINES_SETUP_SKIP, never the analysis after it

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
RUN_SH="$SCRIPTS_DIR/global/scripts/tools/codeql/run.sh"
TEST_DIR="$(mktemp -d)" || exit 1

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

assert_equals() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (expected '$expected', got '$actual')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_contains() {
  local description="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (no '$needle' in: $haystack)${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# The stub CodeQL. `database create` runs a bare `make` in the source root, as the Go autobuilder
# does before it builds the module, and records its output, its exit status and whether it saw
# PIPELINES_SETUP_SKIP; `database analyze` records whether it saw the variable and writes a report
# with no finding beside the lines-of-code metric run.sh reads to know the database held code.
STUB_BIN="$TEST_DIR/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/codeql" << 'STUB'
#!/usr/bin/env sh
record="$CODEQL_STUB_RECORD"
command="$1 $2"
shift 2
case "$command" in
  'database create')
    for argument in "$@"; do
      case "$argument" in
        --source-root=*) root="${argument#--source-root=}" ;;
      esac
      database="$argument"
    done
    echo "${PIPELINES_SETUP_SKIP:-unset}" > "$record/create-skip"
    status=0
    ( cd "$root" || exit 1; make ) > "$record/make-output" 2>&1 || status=$?
    echo "$status" > "$record/make-status"
    mkdir -p "$database"
    ;;
  'database analyze')
    for argument in "$@"; do
      case "$argument" in
        --output=*) output="${argument#--output=}" ;;
      esac
    done
    echo "${PIPELINES_SETUP_SKIP:-unset}" > "$record/analyze-skip"
    printf '%s\n' '{"runs":[{"results":[],"properties":{"metricResults":[{"ruleId":"go/summary/lines-of-code","value":1}]}}]}' > "$output"
    ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/codeql"

# Fixture commits run no hook: a developer's global core.hooksPath (a secret scanner, say) is not
# part of what this suite tests, and it has no business reading the fixtures.
mkdir -p "$TEST_DIR/no-hooks" "$TEST_DIR/home"
fixture_git() {
  git -c user.name='fixture' -c user.email='fixture@example.invalid' -c init.defaultBranch='main' \
    -c core.hooksPath="$TEST_DIR/no-hooks" -c commit.gpgSign=false "$@"
}

# A remote standing in for this repository, a PIPELINES_HOME clone of it, and one more commit on
# the remote: the clone is one fast-forward behind, which is exactly what `setup` would take.
REMOTE="$TEST_DIR/remote.git"
PUBLISHER="$TEST_DIR/publisher"
PIPELINES_CLONE="$TEST_DIR/pipelines-home"
mkdir -p "$PUBLISHER" || exit 1
fixture_git -C "$PUBLISHER" init -q || exit 1
echo 'first' > "$PUBLISHER/README.md"
fixture_git -C "$PUBLISHER" add README.md || exit 1
fixture_git -C "$PUBLISHER" commit -q -m 'first' || exit 1
fixture_git clone -q --bare "$PUBLISHER" "$REMOTE" || exit 1
fixture_git clone -q "$REMOTE" "$PIPELINES_CLONE" || exit 1
echo 'second' >> "$PUBLISHER/README.md"
fixture_git -C "$PUBLISHER" commit -q -am 'second' || exit 1
fixture_git -C "$PUBLISHER" push -q "$REMOTE" HEAD:main || exit 1
BEHIND="$(git -C "$PIPELINES_CLONE" rev-parse HEAD)"

# A Go project that includes the shared makefiles the way README.md tells consumers to, before its
# own targets, so its default goal is `setup`.
PROJECT="$TEST_DIR/project"
mkdir -p "$PROJECT" || exit 1
printf 'module example.com/fixture\n\ngo 1.24\n' > "$PROJECT/go.mod"
printf 'package main\n\nfunc main() {}\n' > "$PROJECT/main.go"
printf 'build/\n.codeql-db/\n' > "$PROJECT/.gitignore"
cat > "$PROJECT/Makefile" << 'MAKEFILE'
SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
-include $(SCRIPTS_DIR)/makefiles/common.mk
-include $(SCRIPTS_DIR)/makefiles/golang.mk

build:
	go build ./...
MAKEFILE
fixture_git -C "$PROJECT" init -q || exit 1
fixture_git -C "$PROJECT" add -A || exit 1
fixture_git -C "$PROJECT" commit -q -m 'fixture' || exit 1

# Runs run.sh in the project with PIPELINES_HOME at $1, recording into a fresh directory whose path
# it prints; the exit status goes to "$record/status" and the output to "$record/output".
# PIPELINES_REPO is the fixture remote, so even a regression that clones never leaves the machine.
run_scan() {
  local pipelines_home="$1" record status=0
  record="$(mktemp -d "$TEST_DIR/record.XXXXXX")" || exit 1
  (
    cd "$PROJECT" || exit 1
    env -u CI -u TF_BUILD -u CODEQL_THREADS -u CODEQL_SOURCE_SCOPE -u CODEQL_RAM -u PIPELINES_SETUP_SKIP \
      HOME="$TEST_DIR/home" PATH="$STUB_BIN:$PATH" SCRIPTS_DIR="$SCRIPTS_DIR" \
      PIPELINES_HOME="$pipelines_home" PIPELINES_REPO="$REMOTE" GIT_CONFIG_GLOBAL=/dev/null \
      CODEQL_STUB_RECORD="$record" "$RUN_SH" go
  ) > "$record/output" 2>&1 || status=$?
  echo "$status" > "$record/status"
  echo "$record"
}

record_of() { cat "$1/$2" 2>/dev/null; }

echo "Testing what a Go CodeQL scan's build does to the pipelines checkout..."
echo ""

echo "Test 1: inside a scan, the autobuilder's bare 'make' leaves PIPELINES_HOME where it was"
RECORD="$(run_scan "$PIPELINES_CLONE")"
assert_equals "the scan succeeds" "0" "$(record_of "$RECORD" status)"
assert_equals "the autobuilder's 'make' succeeds" "0" "$(record_of "$RECORD" make-status)"
assert_contains "'make' runs setup, which says why it changes nothing" \
  "Skipping setup inside the CodeQL build: $PIPELINES_CLONE is left as it is." "$(record_of "$RECORD" make-output)"
assert_equals "PIPELINES_HOME is not fast-forwarded" "$BEHIND" "$(git -C "$PIPELINES_CLONE" rev-parse HEAD)"
assert_equals "the database build is told it runs inside the scan" "the CodeQL build" "$(record_of "$RECORD" create-skip)"
assert_equals "the analysis after it is not" "unset" "$(record_of "$RECORD" analyze-skip)"

echo "Test 2: inside a scan, nothing is cloned where no checkout exists"
MISSING="$TEST_DIR/no-checkout/pipelines"
RECORD="$(run_scan "$MISSING")"
assert_equals "the scan succeeds" "0" "$(record_of "$RECORD" status)"
assert_true "no checkout is cloned" "[ ! -e '$MISSING' ]"

echo "Test 3: outside a scan, a bare 'make' is still 'setup' and fast-forwards PIPELINES_HOME"
status=0
(
  cd "$PROJECT" || exit 1
  env -u PIPELINES_SETUP_SKIP HOME="$TEST_DIR/home" SCRIPTS_DIR="$SCRIPTS_DIR" \
    PIPELINES_HOME="$PIPELINES_CLONE" PIPELINES_REPO="$REMOTE" GIT_CONFIG_GLOBAL=/dev/null make
) > "$TEST_DIR/make-outside.log" 2>&1 || status=$?
assert_equals "the bare 'make' succeeds" "0" "$status"
assert_contains "it updates the pipelines checkout" "Updating pipelines repository at $PIPELINES_CLONE" \
  "$(cat "$TEST_DIR/make-outside.log")"
assert_true "PIPELINES_HOME is fast-forwarded to the remote" \
  "[ \"\$(git -C '$PIPELINES_CLONE' rev-parse HEAD)\" = \"\$(git -C '$REMOTE' rev-parse main)\" ]"
assert_true "and moved from where it was" "[ \"\$(git -C '$PIPELINES_CLONE' rev-parse HEAD)\" != '$BEHIND' ]"

echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
