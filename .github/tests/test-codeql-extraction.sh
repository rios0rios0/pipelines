#!/usr/bin/env bash
# Test script for what a CodeQL scan reads: the Go build stays out of a go.work the source root does
# not hold (`global/scripts/tools/codeql/go-workspace.sh`), and a scan whose database holds none of
# the language's code fails (`global/scripts/tools/codeql/extraction.sh`), in `run.sh` and in the
# GitHub Actions `20-security/codeql` composite.
#
# A checkout or worktree kept below a directory whose go.work did not list it was scanned as
# passing while CodeQL analysed nothing. CodeQL's Go autobuilder looks for go.work files under the
# source root only, but every `go` command of its build walked up, joined the outside workspace and
# loaded no package (`directory prefix . does not contain modules listed in go.work`). The
# extractor recorded the go.mod alone, so `database create` succeeded over a database without one
# line of Go, every query ran over nothing, and the gate passed the empty report.
#
# Asserts, with `codeql` replaced by a stub whose `database create` builds as the Go autobuilder
# does -- `go build ./...` in every module directory under the source root, in the environment
# run.sh hands it -- and whose `database analyze` reports what that build loaded as the
# `<language>/summary/lines-of-code` metric:
#   * under an outside go.work that does not list the module, the build runs with GOWORK=off and
#     the scan passes, from the checkout as on CI and from the copy a local scan makes, placed under
#     the same workspace; the fixture fails without it
#   * the repository's own go.work is kept, under an outside one too, and an explicit GOWORK naming
#     a file outside gives way to it, or to GOWORK=off when there is none
#   * with no workspace, or GOWORK=off already, GOWORK is left as it was, and a scan of another
#     language never touches it
#   * a report whose metric is 0 fails the scan before the gate, listing the extractor's errors and
#     what the CLI counted under the source root, and leaves the report where the job publishes it
#   * a report without the metric, or whose metric is not a number, fails too
#   * every language run.sh is handed is judged by its own metric: go, py, java, js and cs
#   * a go.work below the source root that GOWORK=off leaves unread is named in a warning
# and, against synthetic reports, of `extraction.sh` as the GitHub composite runs it -- without
# --strict -- that a report whose metric is 0 fails, while one without the metric (`actions`), a
# report that cannot be read and no report at all only warn, as annotations on GitHub Actions; and
# the composite's Go workspace step, cut out of action.yaml and run as the runner runs it, hands
# the steps after it the GOWORK `run.sh` would use. The composite's step order and flags are held
# by `make test ONLY=codeql-gate`.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
RUN_SH="$SCRIPTS_DIR/global/scripts/tools/codeql/run.sh"
EXTRACTION="$SCRIPTS_DIR/global/scripts/tools/codeql/extraction.sh"
ACTION="$SCRIPTS_DIR/github/global/stages/20-security/codeql/action.yaml"
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

assert_output() {
  local description="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (no match for '$needle')${NC}"
    printf '%s\n' "$haystack" | sed 's/^/         /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_no_output() {
  local description="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo -e "${RED}  FAIL: $description (unexpected '$needle')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# The stub builds with the real Go and writes its report with jq, as run.sh reads it.
for tool in go jq git; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo -e "${RED}this suite needs '$tool' on PATH, and it is not there${NC}"
    exit 1
  fi
done

# The stub CodeQL. `database create` records the GOWORK its build sees, then builds as the Go
# autobuilder does: `go build ./...` in every directory under the source root holding a go.mod
# (`go list` alone passes a package whose import cannot be resolved), each package `go list ./...`
# then names counting as a line of code and the first line of each failure as an extraction
# error. Another language reports CODEQL_STUB_LINES (1 by default) lines and
# CODEQL_STUB_ERRORS numbered errors. `database analyze` writes the report: no finding, those
# errors as `<prefix>/diagnostics/extraction-errors` notifications, and the
# `<prefix>/summary/lines-of-code` metric -- omitted with CODEQL_STUB_METRIC=none, a string with
# `text` -- carrying CODEQL_STUB_BASELINE as its `baseline` when set.
STUB_BIN="$TEST_DIR/bin"
mkdir -p "$STUB_BIN" "$TEST_DIR/home" || exit 1
cat > "$STUB_BIN/codeql" << 'STUB'
#!/usr/bin/env sh
record="$CODEQL_STUB_RECORD"
command="$1 $2"
shift 2
case "$command" in
  'database create')
    for argument in "$@"; do
      case "$argument" in
        --language=*) language="${argument#--language=}" ;;
        --source-root=*) root="${argument#--source-root=}" ;;
      esac
      database="$argument"
    done
    mkdir -p "$database"
    printf '%s\n' "${GOWORK-(unset)}" > "$record/gowork"
    printf '%s\n' "$language" > "$record/language"
    : > "$record/errors"
    if [ "$language" = go ]; then
      lines=0
      ( cd "$root" || exit 1; find . -name go.mod -not -path '*/vendor/*' ) | sort > "$record/modules"
      while IFS= read -r module; do
        if ( cd "$root/$(dirname "$module")" || exit 1; go build ./... && go list ./... ) > "$record/packages" 2> "$record/go-errors"; then
          lines=$((lines + $(grep -c . "$record/packages")))
        else
          head -n 1 "$record/go-errors" >> "$record/errors"
        fi
      done < "$record/modules"
    else
      lines="${CODEQL_STUB_LINES:-1}"
      count=0
      while [ "$count" -lt "${CODEQL_STUB_ERRORS:-0}" ]; do
        count=$((count + 1))
        printf 'fixture extraction error %s\n' "$count" >> "$record/errors"
      done
    fi
    printf '%s\n' "$lines" > "$record/lines"
    ;;
  'database analyze')
    for argument in "$@"; do
      case "$argument" in
        --output=*) output="${argument#--output=}" ;;
      esac
    done
    case "$(cat "$record/language")" in
      python) prefix=py ;;
      javascript) prefix=js ;;
      csharp) prefix=cs ;;
      *) prefix="$(cat "$record/language")" ;;
    esac
    jq -n --arg prefix "$prefix" --arg lines "$(cat "$record/lines")" --arg errors "$(cat "$record/errors")" \
      --arg metric "${CODEQL_STUB_METRIC:-number}" --arg baseline "${CODEQL_STUB_BASELINE:-}" '{
        version: "2.1.0",
        runs: [{
          tool: {driver: {name: "CodeQL"}},
          results: [],
          invocations: [{toolExecutionNotifications: [$errors | split("\n")[] | select(length > 0)
            | {descriptor: {id: ($prefix + "/diagnostics/extraction-errors")}, level: "error",
               message: {text: ("Extraction failed with error " + .)}}]}],
          properties: {metricResults: (if $metric == "none" then [] else [
            {ruleId: ($prefix + "/summary/lines-of-code"),
             value: (if $metric == "text" then "many" else ($lines | tonumber) end)}
            + (if $baseline == "" then {} else {baseline: ($baseline | tonumber)} end)] end)}
        }]
      }' > "$output"
    ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/codeql" || exit 1

# Fixture commits run no hook: a developer's global core.hooksPath is not what this suite tests.
mkdir -p "$TEST_DIR/no-hooks" || exit 1
fixture_git() {
  git -c user.name='fixture' -c user.email='fixture@example.invalid' -c init.defaultBranch='main' \
    -c core.hooksPath="$TEST_DIR/no-hooks" "$@"
}

# go_module <dir> <module path> [<import>]: a module of one package, at a Go every CI image runs.
go_module() {
  local dir="$1" path="$2" import="${3:-}" package
  package="${path##*/}"
  mkdir -p "$dir" || return 1
  printf 'module %s\n\ngo 1.21\n' "$path" > "$dir/go.mod"
  if [ -n "$import" ]; then
    printf 'package %s\n\nimport "%s"\n\n// V is the imported value.\nconst V = %s.V\n' "$package" "$import" "${import##*/}" > "$dir/$package.go"
  else
    printf 'package %s\n\n// V is one.\nconst V = 1\n' "$package" > "$dir/$package.go"
  fi
}

# commit_all <dir>: makes <dir> a repository holding everything in it, as a clone would.
commit_all() {
  printf 'build/\n.codeql-db/\n' > "$1/.gitignore"
  fixture_git -C "$1" init -q || return 1
  fixture_git -C "$1" add -A || return 1
  fixture_git -C "$1" commit -q -m 'fixture' || return 1
}

# Runs run.sh for language $2 in project $1 with the environment assignments in $3..., recording
# into a fresh directory whose path it prints; the exit status goes to "$record/status" and the
# output to "$record/output". The Go environment is the suite's own -- no go env file, no GOFLAGS,
# no toolchain or module download -- so a developer's settings cannot change what the stub builds.
run_scan() {
  local project="$1" language="$2" record
  shift 2
  record="$(mktemp -d "$TEST_DIR/record.XXXXXX")" || exit 1
  local status=0
  (
    cd "$project" || exit 1
    env -u CI -u TF_BUILD -u GITHUB_ACTIONS -u CODEQL_THREADS -u CODEQL_SOURCE_SCOPE -u CODEQL_RAM \
      -u CODEQL_BUILD_MODE -u GOWORK -u GOFLAGS -u GOMODCACHE \
      HOME="$TEST_DIR/home" PATH="$STUB_BIN:$PATH" SCRIPTS_DIR="$SCRIPTS_DIR" \
      GOENV=off GOTOOLCHAIN=local GOPROXY=off GOCACHE="$TEST_DIR/gocache" GOPATH="$TEST_DIR/gopath" \
      CODEQL_STUB_RECORD="$record" "$@" "$RUN_SH" "$language"
  ) > "$record/output" 2>&1 || status=$?
  echo "$status" > "$record/status"
  echo "$record"
}

record_of() { cat "$1/$2" 2> /dev/null; }

# The layouts. OUTSIDE holds a go.work that lists only its own module, `listed`; below it sit a
# repository it does not list (`project`), as a checkout or worktree kept there would be, and one
# with a go.work of its own (`own`), whose module `a` imports `b` through that workspace alone, so
# it loads only when the workspace is used.
OUTSIDE="$TEST_DIR/outside"
go_module "$OUTSIDE/listed" 'example.com/listed' || exit 1
printf 'go 1.21\n\nuse ./listed\n' > "$OUTSIDE/go.work"
PROJECT="$OUTSIDE/project"
go_module "$PROJECT" 'example.com/fixture' || exit 1
commit_all "$PROJECT" || exit 1
OWN="$OUTSIDE/own"
go_module "$OWN/b" 'example.com/b' || exit 1
go_module "$OWN/a" 'example.com/a' 'example.com/b' || exit 1
printf 'go 1.21\n\nuse (\n\t./a\n\t./b\n)\n' > "$OWN/go.work"
commit_all "$OWN" || exit 1
GO_ENV=(env -u GOWORK -u GOFLAGS GOENV=off GOTOOLCHAIN=local GOPROXY=off GOCACHE="$TEST_DIR/gocache" GOPATH="$TEST_DIR/gopath")

echo "Testing what global/scripts/tools/codeql/run.sh reads..."
echo ""

echo "Test 1: the fixtures fail the way the scans did"
OUT="$(cd "$PROJECT" || exit 1; "${GO_ENV[@]}" go build ./... 2>&1)"
assert_output "a module under a go.work that does not list it builds nothing" \
  "does not contain modules listed in go.work" "$OUT"
OUT="$(cd "$OWN/a" || exit 1; "${GO_ENV[@]}" GOWORK=off go build ./... 2>&1)"
assert_output "the repository's own workspace does not build under GOWORK=off, so switching it off always would break it" \
  "no required module provides package example.com/b" "$OUT"
assert_true "...while it builds with the workspace" "(cd '$OWN/a' || exit 1; ${GO_ENV[*]} go build ./... > /dev/null 2>&1)"

echo ""
echo "Test 2: under an outside go.work, the checkout is built with GOWORK=off"
RECORD="$(run_scan "$PROJECT" go CI=true)"
OUT="$(record_of "$RECORD" output)"
assert_equals "the scan passes" "0" "$(record_of "$RECORD" status)"
assert_equals "the build runs with GOWORK=off" "off" "$(record_of "$RECORD" gowork)"
assert_output "...and says why, naming the workspace" \
  "The Go workspace $OUTSIDE/go.work is outside the source root; building with GOWORK=off" "$OUT"
assert_output "the module's package is extracted" "CodeQL extracted 1 line(s) of go code." "$OUT"
assert_output "the gate then decides" "CodeQL found 0 issue(s) total" "$OUT"

echo ""
echo "Test 3: a local scan's copy, placed under the same workspace, is built with GOWORK=off"
mkdir -p "$OUTSIDE/tmp" || exit 1
RECORD="$(run_scan "$PROJECT" go TMPDIR="$OUTSIDE/tmp")"
OUT="$(record_of "$RECORD" output)"
assert_output "the scan builds from the copy" "CODEQL_SOURCE_SCOPE=git" "$OUT"
assert_equals "the scan passes" "0" "$(record_of "$RECORD" status)"
assert_equals "the build runs with GOWORK=off" "off" "$(record_of "$RECORD" gowork)"
assert_true "the copy is removed afterwards" "[ -z \"\$(ls -A '$OUTSIDE/tmp')\" ]"

echo ""
echo "Test 4: the repository's own go.work is kept"
RECORD="$(run_scan "$OWN" go CI=true)"
OUT="$(record_of "$RECORD" output)"
assert_equals "the scan passes" "0" "$(record_of "$RECORD" status)"
assert_equals "GOWORK is left unset, under an outside workspace too" "(unset)" "$(record_of "$RECORD" gowork)"
assert_output "both modules are extracted through it" "CodeQL extracted 2 line(s) of go code." "$OUT"
assert_no_output "nothing is said about a workspace" "The Go workspace" "$OUT"
RECORD="$(run_scan "$OWN" go CI=true GOWORK="$OWN/go.work")"
assert_equals "an explicit GOWORK naming it is kept" "$OWN/go.work" "$(record_of "$RECORD" gowork)"

echo ""
echo "Test 5: an explicit GOWORK naming a file outside gives way"
RECORD="$(run_scan "$OWN" go CI=true GOWORK="$OUTSIDE/go.work")"
assert_equals "to the repository's own go.work" "$OWN/go.work" "$(record_of "$RECORD" gowork)"
assert_equals "...and the scan passes" "0" "$(record_of "$RECORD" status)"
RECORD="$(run_scan "$PROJECT" go CI=true GOWORK="$OUTSIDE/go.work")"
assert_equals "to GOWORK=off when the repository has none" "off" "$(record_of "$RECORD" gowork)"
RECORD="$(run_scan "$PROJECT" go CI=true GOWORK="$TEST_DIR/missing/go.work")"
assert_equals "...as does one naming a file that is not there" "off" "$(record_of "$RECORD" gowork)"

echo ""
echo "Test 6: with no outside workspace, GOWORK is left as it was"
PLAIN="$TEST_DIR/plain"
go_module "$PLAIN" 'example.com/plain' || exit 1
if [ -n "$(cd "$PLAIN" || exit 1; "${GO_ENV[@]}" go env GOWORK)" ]; then
  echo "  SKIP: a go.work above $TEST_DIR reaches every fixture here, so none of them is without one"
else
  RECORD="$(run_scan "$PLAIN" go CI=true)"
  assert_equals "no workspace: GOWORK stays unset" "(unset)" "$(record_of "$RECORD" gowork)"
  assert_equals "...and the scan passes" "0" "$(record_of "$RECORD" status)"
fi
RECORD="$(run_scan "$PROJECT" go CI=true GOWORK=off)"
assert_equals "GOWORK=off stays off" "off" "$(record_of "$RECORD" gowork)"
assert_no_output "...without a word about a workspace" "The Go workspace" "$(record_of "$RECORD" output)"
RECORD="$(run_scan "$PROJECT" python CI=true)"
assert_equals "a scan of another language never sets GOWORK" "(unset)" "$(record_of "$RECORD" gowork)"

echo ""
echo "Test 7: a Go database holding no code fails the scan before the gate"
NEWER="$TEST_DIR/newer"
go_module "$NEWER" 'example.com/newer' || exit 1
printf 'module example.com/newer\n\ngo 1.999\n' > "$NEWER/go.mod"
RECORD="$(run_scan "$NEWER" go CI=true CODEQL_STUB_BASELINE=4)"
OUT="$(record_of "$RECORD" output)"
assert_equals "the scan fails" "1" "$(record_of "$RECORD" status)"
assert_output "...saying no code was extracted, against what was counted" \
  "ERROR: CodeQL extracted no go code: the database holds 0 lines of it, of the 4 counted under the source root" "$OUT"
assert_output "...listing what the extractor reported" "  - Extraction failed with error go: go.mod requires go >= 1.999" "$OUT"
assert_output "...and where every diagnostic is" "under runs[].invocations[].toolExecutionNotifications" "$OUT"
assert_no_output "the gate never reports the empty report as clean" "CodeQL found" "$OUT"
assert_true "the report stays where the job publishes it" "[ -f '$NEWER/build/reports/codeql/codeql.sarif' ]"
assert_true "the database is cleaned up" "[ ! -e '$NEWER/.codeql-db' ]"

echo ""
echo "Test 8: every language is judged by its own metric"
for language in python java javascript csharp; do
  RECORD="$(run_scan "$PLAIN" "$language" CI=true CODEQL_STUB_LINES=0)"
  OUT="$(record_of "$RECORD" output)"
  assert_equals "$language: no code fails the scan" "1" "$(record_of "$RECORD" status)"
  assert_output "$language: ...naming the language" "ERROR: CodeQL extracted no $language code" "$OUT"
  RECORD="$(run_scan "$PLAIN" "$language" CI=true CODEQL_STUB_LINES=5)"
  OUT="$(record_of "$RECORD" output)"
  assert_equals "$language: code passes to the gate" "0" "$(record_of "$RECORD" status)"
  assert_output "$language: ...counted" "CodeQL extracted 5 line(s) of $language code." "$OUT"
done

echo ""
echo "Test 9: what the report says, and fails to say"
RECORD="$(run_scan "$PLAIN" python CI=true CODEQL_STUB_LINES=0 CODEQL_STUB_BASELINE=0)"
assert_output "none counted under the source root either asks whether the language is right" \
  "and none was counted under the source root either: is 'python' this project's language?" "$(record_of "$RECORD" output)"
RECORD="$(run_scan "$PLAIN" python CI=true CODEQL_STUB_LINES=0)"
assert_output "no extractor error is said as such" "  (nothing)" "$(record_of "$RECORD" output)"
RECORD="$(run_scan "$PLAIN" python CI=true CODEQL_STUB_LINES=0 CODEQL_STUB_ERRORS=12)"
OUT="$(record_of "$RECORD" output)"
assert_equals "at most ten errors are listed" "10" "$(printf '%s\n' "$OUT" | grep -c '^  - Extraction failed with error fixture extraction error ')"
assert_output "...and the rest counted" "  ... and 2 more" "$OUT"
RECORD="$(run_scan "$PLAIN" python CI=true CODEQL_STUB_METRIC=none)"
OUT="$(record_of "$RECORD" output)"
assert_equals "a report without the metric fails" "1" "$(record_of "$RECORD" status)"
assert_output "...saying nothing tells whether code was read" "carries no lines-of-code metric for 'python'" "$OUT"
assert_no_output "...before the gate" "CodeQL found" "$OUT"
RECORD="$(run_scan "$PLAIN" python CI=true CODEQL_STUB_METRIC=text)"
assert_equals "a metric that is not a number fails" "1" "$(record_of "$RECORD" status)"
assert_output "...as unreadable" "could not read how much code CodeQL extracted" "$(record_of "$RECORD" output)"

echo ""
echo "Test 10: a go.work below the source root that GOWORK=off leaves unread is named"
# `svc` stands alone; `nested/go.work` is a workspace of its own whose `a` imports `b`. CodeQL's
# autobuilder builds that workspace from `nested/`, which GOWORK=off leaves outside any module, so
# none of its modules is extracted -- a gap the scan cannot see, since `svc` has code.
NESTED="$OUTSIDE/nested-repo"
go_module "$NESTED/svc" 'example.com/svc' || exit 1
go_module "$NESTED/nested/b" 'example.com/b' || exit 1
go_module "$NESTED/nested/a" 'example.com/a' 'example.com/b' || exit 1
printf 'go 1.21\n\nuse (\n\t./a\n\t./b\n)\n' > "$NESTED/nested/go.work"
commit_all "$NESTED" || exit 1
RECORD="$(run_scan "$NESTED" go CI=true)"
OUT="$(record_of "$RECORD" output)"
assert_equals "the build runs with GOWORK=off" "off" "$(record_of "$RECORD" gowork)"
assert_output "...and warns that the nested workspace goes unread" \
  "WARNING: GOWORK=off leaves the go.work below the source root unread (nested/go.work), so CodeQL extracts none of its modules" "$OUT"
assert_no_output "...without an annotation off GitHub Actions" "::warning" "$OUT"
RECORD="$(run_scan "$PROJECT" go CI=true)"
assert_no_output "a repository with no go.work below its root gets no warning" "WARNING" "$(record_of "$RECORD" output)"

echo ""
echo "Test 11: extraction.sh fails a report that says 0, and only warns when it cannot tell"
REPORTS="$TEST_DIR/reports"
mkdir -p "$REPORTS/one" "$REPORTS/mixed" "$REPORTS/zero-among" "$REPORTS/empty" || exit 1
# report <path> <lines|none|text> [<baseline>] [<rule prefix>]: a report shaped as CodeQL writes it,
# whose lines-of-code metric holds <lines>, a string with `text`, or is left out with `none`.
report() {
  jq -n --arg lines "$2" --arg baseline "${3:-}" --arg prefix "${4:-go}" '{version: "2.1.0", runs: [{
    tool: {driver: {name: "CodeQL"}}, results: [],
    invocations: [{toolExecutionNotifications: [{descriptor: {id: ($prefix + "/diagnostics/extraction-errors")},
      level: "error", message: {text: "Extraction failed with error fixture"}}]}],
    properties: {metricResults: (if $lines == "none" then [] else [
      {ruleId: ($prefix + "/summary/lines-of-code"), value: (if $lines == "text" then "many" else ($lines | tonumber) end)}
      + (if $baseline == "" then {} else {baseline: ($baseline | tonumber)} end)] end)}}]}' > "$1"
}
# extract <argument>...: runs extraction.sh off GitHub Actions; prints its output and `exit=<n>`.
extract() { env -u GITHUB_ACTIONS "$EXTRACTION" "$@" 2>&1; echo "exit=$?"; }
status_of() { printf '%s\n' "$1" | tail -n 1; }
report "$REPORTS/one/go.sarif" 7
report "$REPORTS/one/python.sarif" 0 3 py
report "$REPORTS/one/actions.sarif" none '' actions
report "$REPORTS/one/text.sarif" text
printf 'not json\n' > "$REPORTS/one/broken.sarif"
OUT="$(extract "$REPORTS/one/go.sarif")"
assert_equals "a report with code passes" "exit=0" "$(status_of "$OUT")"
assert_output "...named by its file" "CodeQL extracted 7 line(s) of go code." "$OUT"
OUT="$(extract --language javascript-typescript "$REPORTS/one/go.sarif")"
assert_output "--language names it instead" "CodeQL extracted 7 line(s) of javascript-typescript code." "$OUT"
OUT="$(extract "$REPORTS/one/python.sarif")"
assert_equals "a report that says 0 fails" "exit=1" "$(status_of "$OUT")"
assert_output "...against what was counted" \
  "ERROR: CodeQL extracted no python code: the database holds 0 lines of it, of the 3 counted under the source root" "$OUT"
assert_output "...listing what the extractor reported" "  - Extraction failed with error fixture" "$OUT"
for case_ in "actions.sarif|carries no lines-of-code metric for 'actions'" \
  "text.sarif|could not read how much code CodeQL extracted" \
  "broken.sarif|is not a readable SARIF report" \
  "missing.sarif|SARIF report not found"; do
  name="${case_%%|*}"
  message="${case_#*|}"
  OUT="$(extract "$REPORTS/one/$name")"
  assert_equals "$name: only a warning" "exit=0" "$(status_of "$OUT")"
  assert_output "$name: ...saying why" "WARNING: " "$OUT"
  assert_output "$name: ...$message" "$message" "$OUT"
  OUT="$(extract --strict "$REPORTS/one/$name")"
  assert_equals "$name: --strict fails" "exit=1" "$(status_of "$OUT")"
  assert_output "$name: ...as an error" "ERROR: " "$OUT"
done
OUT="$(extract "")"
assert_equals "no report named is a warning" "exit=0" "$(status_of "$OUT")"
assert_output "...that says so" "WARNING: no SARIF report was named" "$OUT"
OUT="$(extract "$REPORTS/empty")"
assert_equals "a directory with no report is a warning" "exit=0" "$(status_of "$OUT")"
assert_equals "...and an error under --strict" "exit=1" "$(status_of "$(extract --strict "$REPORTS/empty")")"
report "$REPORTS/mixed/go.sarif" 5
report "$REPORTS/mixed/actions.sarif" none '' actions
OUT="$(extract "$REPORTS/mixed")"
assert_equals "a directory of a report with code and one without the metric passes" "exit=0" "$(status_of "$OUT")"
assert_output "...reading both" "CodeQL extracted 5 line(s) of go code." "$OUT"
assert_output "...and warning about the second" "carries no lines-of-code metric for 'actions'" "$OUT"
report "$REPORTS/zero-among/go.sarif" 5
report "$REPORTS/zero-among/python.sarif" 0 '' py
OUT="$(extract "$REPORTS/zero-among")"
assert_equals "one report that says 0 fails the directory" "exit=1" "$(status_of "$OUT")"
assert_output "...after reading every report" "CodeQL extracted 5 line(s) of go code." "$OUT"
OUT="$(GITHUB_ACTIONS=true "$EXTRACTION" "$REPORTS/one/actions.sarif" "$REPORTS/one/python.sarif" 2> /dev/null)"
assert_output "on GitHub Actions a warning is an annotation" \
  "::warning title=CodeQL::the CodeQL report carries no lines-of-code metric for 'actions'" "$OUT"
assert_output "...and so is a failure" "::error title=CodeQL::CodeQL extracted no python code" "$OUT"
assert_no_output "off GitHub Actions there is none" "::" "$(extract "$REPORTS/one/actions.sarif" "$REPORTS/one/python.sarif")"
NO_JQ_BIN="$TEST_DIR/no-jq-bin"
mkdir -p "$NO_JQ_BIN" || exit 1
ln -s "$(command -v sh)" "$NO_JQ_BIN/sh" || exit 1
OUT="$(PATH="$NO_JQ_BIN" "$EXTRACTION" "$REPORTS/one/go.sarif" 2>&1; echo "exit=$?")"
assert_equals "no jq is a warning" "exit=0" "$(status_of "$OUT")"
assert_output "...naming jq" "needs 'jq', and it is not installed" "$OUT"
assert_equals "...and an error under --strict" "exit=1" \
  "$(status_of "$(PATH="$NO_JQ_BIN" "$EXTRACTION" --strict "$REPORTS/one/go.sarif" 2>&1; echo "exit=$?")")"
assert_equals "no argument is a usage error" "exit=1" "$(status_of "$(extract)")"
assert_equals "an unknown option is a usage error" "exit=1" "$(status_of "$(extract --bogus "$REPORTS/one/go.sarif")")"
assert_equals "--language without a value is a usage error" "exit=1" "$(status_of "$(extract --language)")"

echo ""
echo "Test 12: the composite's Go workspace step hands the later steps the GOWORK run.sh would use"
# block <file> <anchor> <opening>: the body of the first literal block scalar whose opening line
# matches <opening>, at or after the first line matching <anchor>, dedented -- the shell the runner
# executes for that step (as `test-release-bump-formats.sh` cuts its steps out). A literal `|` in a
# pattern is written `[|]`: gawk turns `\|` into an alternation that matches every line.
block() {
  awk -v anchor="$2" -v opening="$3" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    !anchored && $0 ~ anchor { anchored = 1 }
    anchored && !inside && $0 ~ opening { inside = 1; body = -1; stop = indent($0); next }
    inside {
      if ($0 ~ /^ *$/) { lines[++n] = ""; next }
      if (indent($0) <= stop) { exit }
      if (body < 0) { body = indent($0) }
      lines[++n] = substr($0, body + 1)
    }
    END { while (n > 0 && lines[n] == "") { n-- } for (i = 1; i <= n; i++) { print lines[i] } }
  ' "$1"
}
STEP="$TEST_DIR/go-workspace-step.sh"
block "$ACTION" "^ *id: 'go_workspace'$" '^ *run: [|]$' > "$STEP"
assert_true "the step is cut out of action.yaml" "grep -q 'codeql_go_workspace' '$STEP' && grep -q 'GITHUB_ENV' '$STEP'"
# run_step <workspace> [NAME=value...]: runs the step in bash, as the runner does, from the action's
# own directory; prints what it wrote to GITHUB_ENV, then its output.
run_step() {
  local workspace="$1" env_file
  shift
  env_file="$(mktemp "$TEST_DIR/github-env.XXXXXX")" || exit 1
  (
    cd "$workspace" || exit 1
    "${GO_ENV[@]}" GITHUB_ACTIONS=true GITHUB_ACTION_PATH="$(dirname "$ACTION")" GITHUB_WORKSPACE="$workspace" \
      GITHUB_ENV="$env_file" "$@" bash -e "$STEP"
  ) > "$env_file.output" 2>&1
  cat "$env_file"
  echo "---"
  cat "$env_file.output"
}
OUT="$(run_step "$PROJECT")"
assert_output "under an outside go.work: GOWORK=off" "GOWORK=off" "$OUT"
OUT="$(run_step "$OWN" GOWORK="$OUTSIDE/go.work")"
assert_output "an explicit GOWORK outside gives way to the repository's own go.work" "GOWORK=$OWN/go.work" "$OUT"
OUT="$(run_step "$OWN")"
assert_no_output "the repository's own go.work is kept" "GOWORK=" "$OUT"
OUT="$(run_step "$NESTED")"
assert_output "a nested go.work left unread is a warning annotation" \
  "::warning title=CodeQL::GOWORK=off leaves the go.work below the source root unread (nested/go.work)" "$OUT"

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
