#!/usr/bin/env bash
# Test script for the CodeQL findings gate, `global/scripts/tools/codeql/gate.sh`, and for the
# GitHub Actions `20-security/codeql` composite that runs it.
#
# The GitHub job used to pass whatever CodeQL found. `github/codeql-action/analyze` fails only when
# the analysis itself fails: on GitHub a finding is acted on by code scanning, through the upload.
# A repository that could not upload -- code scanning needs GitHub Advanced Security on a private
# one -- was told to set `upload: 'never'` and keep "a build-breaking check without the alerts",
# but nothing in the job read the report any more, so every finding passed. GitLab CI, Azure DevOps
# and `make codeql` were never affected: `run.sh` filtered the report through
# `.codeql-false-positives` and failed on what remained. That filter is now one script that every
# platform runs, and this suite holds both halves of the contract.
#
# Asserts, against synthetic SARIF reports built in scratch space:
#   * every finding suppressed -> exit 0; one finding left -> exit 1, listed with its rule, message,
#     location and the `primaryLocationLineHash` a triaged finding would add to the file
#   * a finding is suppressed by ANY of its partialFingerprints values, by whole lines only (a
#     trailing comment silences nothing), exactly as `run.sh` always matched
#   * without a project file the default beside the script applies and nothing is written into the
#     project; a directory stands for the `*.sarif` reports in it, and their counts add up
#   * it fails closed: no argument, a missing report, an empty directory, a report that is not
#     SARIF, or no `jq` to read it -- each one is an error, never "no findings"
#   * `run.sh` delegates its verdict to it, end to end, with `codeql` replaced by a stub
# and, against the composite's YAML:
#   * the analysis runs the suite `run.sh` runs (`security-and-quality`) and never uploads
#   * a gate step runs this script on the analysis output, unconditionally fatal
#   * the SARIF upload is its own step, after the gate, `if: always()` and `continue-on-error`
#   * GitLab CI and Azure DevOps still reach the same script through `run.sh`
# and, for this repository's own scan:
#   * its root `codeql-config.yml` drops `actions/unpinned-tag` and nothing else, its root
#     `.codeql-false-positives` holds only bare fingerprints under dated rationales, and the
#     consumers' default beside the gate script lists nothing

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
GATE="$SCRIPTS_DIR/global/scripts/tools/codeql/gate.sh"
RUN_SH="$SCRIPTS_DIR/global/scripts/tools/codeql/run.sh"
ACTION="$SCRIPTS_DIR/github/global/stages/20-security/codeql/action.yaml"
TEST_DIR="$(mktemp -d)" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

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

assert_line() {
  local description="$1" needle="$2" haystack="$3"
  if printf '%s\n' "$haystack" | grep -qxF -- "$needle"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (no line '$needle')${NC}"
    printf '%s\n' "$haystack" | sed 's/^/         /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_no_match() {
  local description="$1" needle="$2" haystack="$3"
  if printf '%s\n' "$haystack" | grep -qF -- "$needle"; then
    echo -e "${RED}  FAIL: $description (unexpected '$needle')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

assert_empty() {
  local description="$1" findings="$2"
  if [ -z "$findings" ]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    printf '%s\n' "$findings" | sed 's/^/         /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# Tests 8 and 10 read YAML. Their checks are Go test support (`internal/testsuites/codeqlgate`),
# built from this checkout for this run; one that does not build stops the suite rather than leave
# those assertions reading nothing. A file a check cannot read is printed as a finding, so an
# unreadable action or configuration fails its assertion instead of passing it.
mkdir -p "$TEST_DIR/tools" || exit 1
CODEQL_CHECKS="$TEST_DIR/tools/codeqlgate"
if ! CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
  go build -C "$SCRIPTS_DIR" -trimpath -o "$CODEQL_CHECKS" ./internal/testsuites/codeqlgate; then
  echo -e "${RED}could not build ./internal/testsuites/codeqlgate, so no assertion can run${NC}"
  exit 1
fi

# result <rule> <uri> <line> <primaryLocationLineHash> [<primaryLocationStartColumnFingerprint>]
#
# One SARIF result, shaped as CodeQL writes it.
result() {
  local column=''
  [ -n "${5:-}" ] && column=",\"primaryLocationStartColumnFingerprint\":\"$5\""
  printf '{"ruleId":"%s","message":{"text":"fixture finding"},"partialFingerprints":{"primaryLocationLineHash":"%s"%s},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"%s"},"region":{"startLine":%s}}}]}' \
    "$1" "$4" "$column" "$2" "$3"
}

# sarif <path> [<result>...] -- a report with one run holding the given results.
sarif() {
  local path="$1" joined
  shift
  joined="$(IFS=,; echo "$*")"
  printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"CodeQL"}},"results":[%s]}]}\n' "$joined" > "$path"
}

# project <name> -- a fresh project directory, printed on stdout.
project() {
  local directory="$TEST_DIR/$1"
  mkdir -p "$directory" || return 1
  printf '%s\n' "$directory"
}

# gate <project-dir> <argument>... -- runs the gate from the project, as every caller does, and
# prints its output followed by a last line `exit=<status>`.
gate() {
  local directory="$1"
  shift
  (
    cd "$directory" || exit 99
    "$GATE" "$@" 2>&1
    echo "exit=$?"
  )
}

status_of() { printf '%s\n' "$1" | tail -n 1; }

echo "=== CodeQL findings gate ==="
echo ""

echo "Test 1: every finding suppressed passes"
P="$(project all-suppressed)" || exit 1
sarif "$P/report.sarif" "$(result go/fixture-a main.go 3 suppressed-a:1)" "$(result go/fixture-b main.go 9 suppressed-b:1)"
printf '# triaged\nsuppressed-a:1\n\nsuppressed-b:1\n' > "$P/.codeql-false-positives"
OUT="$(gate "$P" report.sarif)"
assert_equals "the gate exits 0" "exit=0" "$(status_of "$OUT")"
assert_line "it says how many fingerprints it loaded" \
  "Loaded 2 false positive fingerprint(s) from .codeql-false-positives" "$OUT"
assert_line "it reports the counts in the line run.sh always printed" \
  "CodeQL found 2 issue(s) total, 2 suppressed as false positive(s), 0 remaining." "$OUT"
echo ""

echo "Test 2: an unsuppressed finding fails and is listed with its fingerprint"
P="$(project one-remaining)" || exit 1
sarif "$P/report.sarif" "$(result go/fixture-a main.go 3 suppressed-a:1)" "$(result js/fixture-left src/app.js 7 remaining-left:1)"
printf 'suppressed-a:1\n' > "$P/.codeql-false-positives"
OUT="$(gate "$P" report.sarif)"
assert_equals "the gate exits 1" "exit=1" "$(status_of "$OUT")"
assert_line "the counts name the one left" \
  "CodeQL found 2 issue(s) total, 1 suppressed as false positive(s), 1 remaining." "$OUT"
assert_line "the finding is listed as run.sh listed it" "  - js/fixture-left: fixture finding (src/app.js:7)" "$OUT"
assert_line "...followed by the value .codeql-false-positives would need" "    fingerprint: remaining-left:1" "$OUT"
assert_no_match "a suppressed finding is not listed" "go/fixture-a" "$OUT"
echo ""

echo "Test 3: fingerprints match any partialFingerprints value, by whole lines"
P="$(project any-value)" || exit 1
sarif "$P/report.sarif" "$(result go/fixture-a main.go 3 line-hash-a:1 17)"
printf '17\n' > "$P/.codeql-false-positives"
assert_equals "a listed column fingerprint suppresses the finding, as it always did" \
  "exit=0" "$(status_of "$(gate "$P" report.sarif)")"
P="$(project trailing-comment)" || exit 1
sarif "$P/report.sarif" "$(result go/fixture-a main.go 3 line-hash-a:1)"
printf 'line-hash-a:1  # triaged on a whim\n' > "$P/.codeql-false-positives"
assert_equals "a line carrying a trailing comment silences nothing" \
  "exit=1" "$(status_of "$(gate "$P" report.sarif)")"
echo ""

echo "Test 4: without a project file the default applies, and nothing is written"
P="$(project no-file)" || exit 1
sarif "$P/report.sarif" "$(result go/fixture-a main.go 3 line-hash-a:1)"
OUT="$(gate "$P" report.sarif)"
assert_equals "the finding fails the gate" "exit=1" "$(status_of "$OUT")"
assert_no_match "the default lists no fingerprint" "Loaded" "$OUT"
assert_true "no .codeql-false-positives is left in the project" "[ ! -e '$P/.codeql-false-positives' ]"
assert_true "the project holds nothing but its report" "[ \"\$(ls -A '$P')\" = 'report.sarif' ]"
echo ""

echo "Test 5: a directory stands for the SARIF reports in it"
P="$(project directory)" || exit 1
mkdir -p "$P/results dir" || exit 1
sarif "$P/results dir/go.sarif" "$(result go/fixture-a main.go 3 dir-a:1)"
sarif "$P/results dir/python.sarif" "$(result py/fixture-b app.py 4 dir-b:1)"
printf 'not a report\n' > "$P/results dir/notes.txt"
printf 'dir-a:1\ndir-b:1\n' > "$P/.codeql-false-positives"
OUT="$(gate "$P" "results dir")"
assert_equals "two suppressed reports pass" "exit=0" "$(status_of "$OUT")"
assert_line "their counts add up" \
  "CodeQL found 2 issue(s) total, 2 suppressed as false positive(s), 0 remaining." "$OUT"
printf 'dir-a:1\n' > "$P/.codeql-false-positives"
OUT="$(gate "$P" "results dir")"
assert_equals "a finding in either report fails" "exit=1" "$(status_of "$OUT")"
assert_line "...and is listed" "  - py/fixture-b: fixture finding (app.py:4)" "$OUT"
P="$(project run-without-results)" || exit 1
printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"CodeQL"}}}]}\n' > "$P/report.sarif"
OUT="$(gate "$P" report.sarif)"
assert_equals "a run that carries no results passes" "exit=0" "$(status_of "$OUT")"
assert_line "...as zero findings" "CodeQL found 0 issue(s) total, 0 suppressed as false positive(s), 0 remaining." "$OUT"
echo ""

echo "Test 6: it fails closed"
P="$(project closed)" || exit 1
mkdir -p "$P/empty" || exit 1
printf 'not json\n' > "$P/broken.sarif"
printf '{"version":"2.1.0"}\n' > "$P/no-runs.sarif"
OUT="$(gate "$P")"
assert_equals "no argument is an error" "exit=1" "$(status_of "$OUT")"
OUT="$(gate "$P" missing.sarif)"
assert_equals "a missing report is an error" "exit=1" "$(status_of "$OUT")"
assert_line "...that names it" "ERROR: SARIF report not found: missing.sarif" "$OUT"
OUT="$(gate "$P" empty)"
assert_equals "a directory with no report is an error" "exit=1" "$(status_of "$OUT")"
OUT="$(gate "$P" broken.sarif)"
assert_equals "a report that is not JSON is an error" "exit=1" "$(status_of "$OUT")"
assert_line "...that says so" "ERROR: broken.sarif is not a readable SARIF report." "$OUT"
OUT="$(gate "$P" no-runs.sarif)"
assert_equals "JSON that is not a SARIF report is an error" "exit=1" "$(status_of "$OUT")"
# A PATH holding every tool the gate calls except jq. `env` is reached by absolute path in the
# shebang, so it needs no entry here.
NO_JQ_BIN="$TEST_DIR/no-jq-bin"
mkdir -p "$NO_JQ_BIN" || exit 1
for tool in sh dirname grep; do
  ln -s "$(command -v "$tool")" "$NO_JQ_BIN/$tool" || exit 1
done
sarif "$P/report.sarif"
OUT="$(cd "$P" || exit 99; PATH="$NO_JQ_BIN" "$GATE" report.sarif 2>&1; echo "exit=$?")"
assert_equals "no jq to read the report is an error" "exit=1" "$(status_of "$OUT")"
assert_line "...that names jq" "ERROR: the CodeQL gate needs 'jq' to read the SARIF report, and it is not installed." "$OUT"
echo ""

echo "Test 7: run.sh delegates its verdict to the gate"
# The stub CodeQL: `database create` makes the database directory, and `database analyze` writes
# one finding whose fingerprint CODEQL_STUB_FINGERPRINT names to the --output report.
STUB_BIN="$TEST_DIR/bin"
mkdir -p "$STUB_BIN" "$TEST_DIR/home" || exit 1
cat > "$STUB_BIN/codeql" << 'STUB'
#!/usr/bin/env sh
command="$1 $2"
shift 2
case "$command" in
  'database create')
    for argument in "$@"; do database="$argument"; done
    mkdir -p "$database"
    ;;
  'database analyze')
    for argument in "$@"; do
      case "$argument" in
        --output=*) output="${argument#--output=}" ;;
      esac
    done
    printf '{"runs":[{"results":[{"ruleId":"py/fixture","message":{"text":"fixture finding"},"partialFingerprints":{"primaryLocationLineHash":"%s"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"app.py"},"region":{"startLine":2}}}]}]}]}\n' \
      "$CODEQL_STUB_FINGERPRINT" > "$output"
    ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/codeql" || exit 1

# scan <project> <fingerprint> -- runs `run.sh python` there and prints its output and `exit=<n>`.
scan() {
  (
    cd "$1" || exit 99
    HOME="$TEST_DIR/home" PATH="$STUB_BIN:$PATH" SCRIPTS_DIR="$SCRIPTS_DIR" CODEQL_SOURCE_SCOPE=tree \
      CODEQL_STUB_FINGERPRINT="$2" "$RUN_SH" python 2>&1
    echo "exit=$?"
  )
}

P="$(project scan)" || exit 1
printf 'print(1)\n' > "$P/app.py"
printf 'scan-triaged:1\n' > "$P/.codeql-false-positives"
OUT="$(scan "$P" scan-triaged:1)"
assert_equals "a scan whose only finding is triaged passes" "exit=0" "$(status_of "$OUT")"
assert_line "...counted by the gate" "CodeQL found 1 issue(s) total, 1 suppressed as false positive(s), 0 remaining." "$OUT"
OUT="$(scan "$P" scan-new:1)"
assert_equals "a scan with a new finding fails" "exit=1" "$(status_of "$OUT")"
assert_line "...listing it with its fingerprint" "    fingerprint: scan-new:1" "$OUT"
assert_true "run.sh calls the gate and exits with its status" \
  "grep -A1 -F 'global/scripts/tools/codeql/gate.sh\" \"\$fileName\"' '$RUN_SH' | grep -qx 'exit \$?'"
assert_true "run.sh keeps no fingerprint filter of its own" "! grep -q 'partialFingerprints' '$RUN_SH'"
echo ""

echo "Test 8: the GitHub composite analyses, gates, then uploads at best"
FINDINGS="$("$CODEQL_CHECKS" composite "$ACTION" "$SCRIPTS_DIR")"
assert_empty "the analysis never uploads, the gate is fatal, the upload is best-effort and last" "$FINDINGS"
echo ""

echo "Test 9: GitLab CI and Azure DevOps reach the same gate through run.sh"
assert_true "the GitLab CI CodeQL stage runs run.sh" \
  "grep -q 'global/scripts/tools/codeql/run.sh' '$SCRIPTS_DIR/gitlab/global/stages/20-security/codeql.yaml'"
assert_true "the Azure DevOps CodeQL stage runs run.sh" \
  "grep -q 'global/scripts/tools/codeql/run.sh' '$SCRIPTS_DIR/azure-devops/global/stages/20-security/codeql.yaml'"
echo ""

echo "Test 10: this repository's own scan narrows nothing it has not explained"
# The root `codeql-config.yml` and `.codeql-false-positives` are read by this repository's own
# analysis alone. They are the two places a finding here can be made to disappear, so both stay
# exactly as narrow as their comments justify, and the consumers' default stays empty.
FINDINGS="$("$CODEQL_CHECKS" own-scan "$SCRIPTS_DIR")"
assert_empty "the config drops actions/unpinned-tag alone, every suppression is a dated bare fingerprint, the default lists nothing" "$FINDINGS"
echo ""

echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
