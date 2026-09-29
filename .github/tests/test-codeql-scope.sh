#!/usr/bin/env bash
# Test script for the source scope and thread defaults of `global/scripts/tools/codeql/run.sh`.
#
# A developer's working tree holds more than the repository ships: agent worktrees under
# `.claude/worktrees`, vendored builds, old databases -- all of it kept out by `.gitignore` and
# all of it taken by the extractor, since the Go autobuilder builds every `go.mod` under the
# source root. On 2026-09-29 thirty stale worktrees turned one module into 31, a 93 GB database
# and a scan still importing on one thread after 77 minutes; a clean checkout scanned in six.
#
# Asserts, with `codeql` replaced by a stub that records what it was handed:
#   * a local run builds from a copy of the files git would ship: the tracked ones still on disk
#     and untracked ones no ignore rule excludes -- never an ignored directory, an untracked
#     nested repository or a tracked file deleted from the working tree
#   * the copy keeps every path relative to the project root, odd names included, and is removed
#     afterwards, on success and on failure alike
#   * a false-positive fingerprint still suppresses its finding when the scan ran on the copy
#   * a local run takes every core (`--threads=0`); a CI run keeps one thread and scans the
#     checkout as it is, on GitHub Actions and GitLab CI (`CI`) and Azure DevOps (`TF_BUILD`)
#   * `CODEQL_SOURCE_SCOPE` and `CODEQL_THREADS` override either default, and a bad scope stops
#     the run before CodeQL is invoked
#   * outside a git work tree the directory is scanned as it is, as it always was
#   * run from a subdirectory of a repository, the copy is that subdirectory

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
  if printf '%s\n' "$haystack" | grep -qxF -- "$needle"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (no line '$needle')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_not_contains() {
  local description="$1" needle="$2" haystack="$3"
  if printf '%s\n' "$haystack" | grep -qxF -- "$needle"; then
    echo -e "${RED}  FAIL: $description (unexpected line '$needle')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

assert_output() {
  local description="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (no match for '$needle')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# The stub CodeQL. `database create` records the source root, the thread count and every file
# under the root, and makes the database directory; `database analyze` records its threads and
# writes one finding whose fingerprint the fixture lists as a false positive. CODEQL_STUB_RECORD
# names where the records go; CODEQL_STUB_CREATE_EXIT scripts a failing build.
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
        --threads=*) echo "${argument#--threads=}" > "$record/create-threads" ;;
      esac
      database="$argument"
    done
    echo "$root" > "$record/source-root"
    ( cd "$root" || exit 1; find . -type f ) | sed 's|^\./||' | sort > "$record/files"
    mkdir -p "$database"
    exit "${CODEQL_STUB_CREATE_EXIT:-0}"
    ;;
  'database analyze')
    for argument in "$@"; do
      case "$argument" in
        --output=*) output="${argument#--output=}" ;;
        --threads=*) echo "${argument#--threads=}" > "$record/analyze-threads" ;;
      esac
    done
    printf '%s\n' '{"runs":[{"results":[{"ruleId":"go/fixture","message":{"text":"fixture"},"partialFingerprints":{"primaryLocationLineHash":"fixture-fingerprint:1"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"main.go"},"region":{"startLine":1}}}]}]}]}' > "$output"
    ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/codeql"

# Fixture commits run no hook: a developer's global core.hooksPath (a secret scanner, say) is not
# part of what this suite tests, and it has no business reading the fixtures.
mkdir -p "$TEST_DIR/no-hooks"
fixture_git() {
  git -c user.name='fixture' -c user.email='fixture@example.invalid' -c init.defaultBranch='main' \
    -c core.hooksPath="$TEST_DIR/no-hooks" "$@"
}

# Builds a git repository at $1 shaped like a developer's working tree: tracked sources, one
# tracked file deleted from disk, an untracked source, an ignored agent worktree carrying its own
# go.mod, an untracked nested repository, and a tracked file with a space and a leading dash.
make_repo() {
  local repo="$1"
  mkdir -p "$repo/dir with space" "$repo/.claude/worktrees/agent" "$repo/nested" || return 1
  printf 'module example.com/fixture\n' > "$repo/go.mod"
  printf 'package main\n' > "$repo/main.go"
  printf 'package main\n' > "$repo/gone.go"
  printf 'package main\n' > "$repo/dir with space/-odd name.go"
  printf '.claude/worktrees/\nbuild/\n.codeql-db/\n' > "$repo/.gitignore"
  printf 'fixture-fingerprint:1\n' > "$repo/.codeql-false-positives"
  fixture_git -C "$repo" init -q || return 1
  fixture_git -C "$repo" add -A || return 1
  fixture_git -C "$repo" commit -q -m 'fixture' || return 1
  rm "$repo/gone.go"
  printf 'package main\n' > "$repo/new.go"
  printf 'module example.com/agent\n' > "$repo/.claude/worktrees/agent/go.mod"
  fixture_git -C "$repo/nested" init -q || return 1
  printf 'module example.com/nested\n' > "$repo/nested/go.mod"
}

# Runs run.sh in project $1 with the environment assignments in $2... (`-u NAME` removes one),
# recording into a fresh directory whose path it prints on stdout's last line; the exit status
# goes to "$record/status" and the output to "$record/output".
run_scan() {
  local project="$1" record
  shift
  record="$(mktemp -d "$TEST_DIR/record.XXXXXX")" || exit 1
  local status=0
  (
    cd "$project" || exit 1
    env -u CI -u TF_BUILD -u CODEQL_THREADS -u CODEQL_SOURCE_SCOPE -u CODEQL_RAM \
      HOME="$TEST_DIR/home" PATH="$STUB_BIN:$PATH" SCRIPTS_DIR="$SCRIPTS_DIR" \
      CODEQL_STUB_RECORD="$record" "$@" "$RUN_SH" go
  ) > "$record/output" 2>&1 || status=$?
  echo "$status" > "$record/status"
  echo "$record"
}

record_of() { cat "$1/$2" 2>/dev/null; }

echo "Testing the source scope and threads of global/scripts/tools/codeql/run.sh..."
echo ""

echo "Test 1: a local run scans a copy of the files git would ship, on every core"
REPO="$TEST_DIR/local"
make_repo "$REPO" || exit 1
RECORD="$(run_scan "$REPO")"
FILES="$(record_of "$RECORD" files)"
ROOT="$(record_of "$RECORD" source-root)"
assert_equals "the run succeeds" "0" "$(record_of "$RECORD" status)"
assert_true "the database is built from a copy, not the working tree" "[ -n '$ROOT' ] && [ '$ROOT' != '$REPO' ]"
assert_contains "a tracked source is copied" "main.go" "$FILES"
assert_contains "the module file is copied" "go.mod" "$FILES"
assert_contains "an untracked, unignored source is copied" "new.go" "$FILES"
assert_contains "a name with a space and a leading dash keeps its path" "dir with space/-odd name.go" "$FILES"
assert_not_contains "an ignored agent worktree is left out" ".claude/worktrees/agent/go.mod" "$FILES"
assert_not_contains "an untracked nested repository is left out" "nested/go.mod" "$FILES"
assert_not_contains "a tracked file deleted from disk is left out" "gone.go" "$FILES"
assert_equals "the database is created on every core" "0" "$(record_of "$RECORD" create-threads)"
assert_equals "the analysis runs on every core" "0" "$(record_of "$RECORD" analyze-threads)"
assert_true "the copy is removed after the run" "[ ! -e '$ROOT' ]"
assert_output "the fingerprint still suppresses its finding" "1 suppressed as false positive(s), 0 remaining" "$(record_of "$RECORD" output)"
assert_output "the run says what it scanned" "CODEQL_SOURCE_SCOPE=git" "$(record_of "$RECORD" output)"
assert_true "the database is cleaned up" "[ ! -e '$REPO/.codeql-db' ]"

echo ""
echo "Test 2: a CI run scans the checkout as it is, on one thread"
for marker in CI=true TF_BUILD=True; do
  REPO="$TEST_DIR/ci-${marker%%=*}"
  make_repo "$REPO" || exit 1
  RECORD="$(run_scan "$REPO" "$marker")"
  assert_equals "$marker: the run succeeds" "0" "$(record_of "$RECORD" status)"
  assert_equals "$marker: the database is built from the checkout" "$REPO" "$(record_of "$RECORD" source-root)"
  assert_equals "$marker: the database is created on one thread" "1" "$(record_of "$RECORD" create-threads)"
  assert_equals "$marker: the analysis runs on one thread" "1" "$(record_of "$RECORD" analyze-threads)"
done

echo ""
echo "Test 3: CODEQL_SOURCE_SCOPE and CODEQL_THREADS override either default"
REPO="$TEST_DIR/override-tree"
make_repo "$REPO" || exit 1
RECORD="$(run_scan "$REPO" CODEQL_SOURCE_SCOPE=tree)"
assert_equals "a local run told 'tree' scans the working tree" "$REPO" "$(record_of "$RECORD" source-root)"
assert_contains "...ignored directories included, as before" ".claude/worktrees/agent/go.mod" "$(record_of "$RECORD" files)"

REPO="$TEST_DIR/override-git"
make_repo "$REPO" || exit 1
RECORD="$(run_scan "$REPO" CI=true CODEQL_SOURCE_SCOPE=git)"
ROOT="$(record_of "$RECORD" source-root)"
assert_true "a CI run told 'git' scans the copy" "[ -n '$ROOT' ] && [ '$ROOT' != '$REPO' ]"
assert_not_contains "...without the ignored directory" ".claude/worktrees/agent/go.mod" "$(record_of "$RECORD" files)"
assert_equals "...on the CI thread count" "1" "$(record_of "$RECORD" create-threads)"

REPO="$TEST_DIR/override-threads"
make_repo "$REPO" || exit 1
RECORD="$(run_scan "$REPO" CODEQL_THREADS=3)"
assert_equals "an explicit CODEQL_THREADS wins over the local default" "3" "$(record_of "$RECORD" create-threads)"

echo ""
echo "Test 4: a bad scope stops the run before CodeQL"
REPO="$TEST_DIR/bad-scope"
make_repo "$REPO" || exit 1
RECORD="$(run_scan "$REPO" CODEQL_SOURCE_SCOPE=everything)"
assert_true "the run fails" "[ '$(record_of "$RECORD" status)' != '0' ]"
assert_output "...naming the valid values" "CODEQL_SOURCE_SCOPE must be 'git' or 'tree'" "$(record_of "$RECORD" output)"
assert_true "...and CodeQL is never invoked" "[ ! -e '$RECORD/source-root' ]"

echo ""
echo "Test 5: a failed build still removes the copy, and says how to build from the tree"
REPO="$TEST_DIR/failed-build"
make_repo "$REPO" || exit 1
RECORD="$(run_scan "$REPO" CODEQL_STUB_CREATE_EXIT=1)"
ROOT="$(record_of "$RECORD" source-root)"
assert_true "the run fails" "[ '$(record_of "$RECORD" status)' != '0' ]"
assert_true "the copy is removed" "[ -n '$ROOT' ] && [ ! -e '$ROOT' ]"
assert_output "the error points at CODEQL_SOURCE_SCOPE=tree" "set CODEQL_SOURCE_SCOPE=tree" "$(record_of "$RECORD" output)"

echo ""
echo "Test 6: outside a git work tree the directory is scanned as it is"
PLAIN="$TEST_DIR/plain"
mkdir -p "$PLAIN/.claude/worktrees/agent" || exit 1
printf 'package main\n' > "$PLAIN/main.go"
printf 'module example.com/agent\n' > "$PLAIN/.claude/worktrees/agent/go.mod"
printf 'fixture-fingerprint:1\n' > "$PLAIN/.codeql-false-positives"
RECORD="$(run_scan "$PLAIN" GIT_CEILING_DIRECTORIES="$TEST_DIR")"
assert_equals "the run succeeds" "0" "$(record_of "$RECORD" status)"
assert_equals "the database is built from the directory itself" "$PLAIN" "$(record_of "$RECORD" source-root)"

echo ""
echo "Test 7: from a subdirectory of a repository, the copy is that subdirectory"
MONO="$TEST_DIR/mono"
mkdir -p "$MONO/service" "$MONO/other" || exit 1
printf 'module example.com/service\n' > "$MONO/service/go.mod"
printf 'package main\n' > "$MONO/service/main.go"
printf 'module example.com/other\n' > "$MONO/other/go.mod"
printf 'build/\n.codeql-db/\n' > "$MONO/.gitignore"
printf 'fixture-fingerprint:1\n' > "$MONO/service/.codeql-false-positives"
fixture_git -C "$MONO" init -q || exit 1
fixture_git -C "$MONO" add -A || exit 1
fixture_git -C "$MONO" commit -q -m 'fixture' || exit 1
RECORD="$(run_scan "$MONO/service")"
FILES="$(record_of "$RECORD" files)"
assert_equals "the run succeeds" "0" "$(record_of "$RECORD" status)"
assert_contains "the subdirectory's files keep paths relative to it" "main.go" "$FILES"
assert_not_contains "a sibling directory is left out" "other/go.mod" "$FILES"

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
