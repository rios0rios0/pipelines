#!/usr/bin/env bash
set -e

# Test script for the SAST gate in `makefiles/common.mk`.
#
# The property under test is that `make sast` can FAIL. Every SAST recipe once
# carried a `-` prefix (and `codeql` a trailing `|| true`), which tells Make to
# ignore the recipe's exit status, so the target returned 0 on findings, on a
# crash and on termination alike -- real runs printed `Error 123 (ignored)` and
# `Terminated (ignored)` and then reported success. The documented pre-push gate
# is `make lint && make sast`, whose `&&` could therefore never short-circuit.
#
# Asserts:
#   * each tool target exits non-zero when its runner does, and 0 when it does not
#   * `sast` runs EVERY tool even after one fails -- the run-to-completion
#     behaviour the `-` prefixes were introduced for, which the fix has to keep
#   * `sast` exits non-zero afterwards, and names the tools that failed
#   * `sast` exits 0 with a `SAST PASSED` line when nothing found anything
#   * the CodeQL skip is still a skip, not a failure, when no language is set
#   * a language fragment's `SAST_TOOLS_EXTRA` joins the same suite, in either
#     include order
#   * no SAST recipe reintroduces `-` or `|| true`
#
# The tool runners are replaced by stubs with scripted exit codes: this is about
# the makefile's plumbing, not about whether Semgrep finds anything.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(mktemp -d)" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_true() {
  local description="$1"
  local condition="$2"
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
  if printf '%s' "$haystack" | grep -q "$needle"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (no match for '$needle')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_not_contains() {
  local description="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -q "$needle"; then
    echo -e "${RED}  FAIL: $description (unexpected match for '$needle')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

TOOLS='codeql semgrep hadolint shellcheck gitleaks'

# Builds a fake pipelines checkout at $1/pipelines carrying the REAL `makefiles/`
# and stub tool runners, plus a consumer project at $1/project that includes them.
#
# $2 is a space-separated list of `tool=exitcode` overrides; any tool not named
# exits 0. Each stub records that it ran, so a later assertion can tell "the
# suite stopped early" apart from "the suite ran and reported".
make_fixture() {
  local codes="$2" fake="$1/pipelines" project="$1/project"
  local tool code

  mkdir -p "$fake/makefiles" "$project"
  cp "$SCRIPTS_DIR"/makefiles/*.mk "$fake/makefiles/"
  mkdir -p "$fake/ran"

  for tool in $TOOLS; do
    code=0
    for pair in $codes; do
      [ "${pair%%=*}" = "$tool" ] && code="${pair##*=}"
    done
    mkdir -p "$fake/global/scripts/tools/$tool"
    {
      echo '#!/usr/bin/env sh'
      echo "echo \"stub $tool ran\""
      echo "touch '$fake/ran/$tool'"
      echo "exit $code"
    } > "$fake/global/scripts/tools/$tool/run.sh"
    chmod +x "$fake/global/scripts/tools/$tool/run.sh"
  done

  {
    echo "SCRIPTS_DIR ?= $fake"
    echo '-include $(SCRIPTS_DIR)/makefiles/common.mk'
    echo 'CODEQL_LANGUAGE ?= go'
    echo 'SEMGREP_LANGUAGE ?= golang'
  } > "$project/Makefile"
}

# Runs `make $2...` in the fixture project at $1 and prints the exit code.
mk_status() {
  local project="$1"; shift
  local status=0
  ( cd "$project" && make "$@" ) > /dev/null 2>&1 || status=$?
  echo "$status"
}

# Runs `make $2...` in the fixture project at $1 and prints its combined output.
mk_output() {
  local project="$1"; shift
  ( cd "$project" && make "$@" ) 2>&1 || true
}

echo "Testing the SAST gate in makefiles/common.mk..."
echo ""

echo "An individual tool target propagates its runner's exit code"
# Each of these ran green on a failing tool before the fix, which is what made
# `make gitleaks` a safe-looking thing to put in a hook.
for tool in $TOOLS; do
  FX="$TEST_DIR/one-$tool"
  make_fixture "$FX" "$tool=1"
  assert_true "make $tool fails when its runner fails" \
    "[ \"\$(mk_status '$FX/project' $tool)\" -ne 0 ]"
done

for tool in $TOOLS; do
  FX="$TEST_DIR/ok-$tool"
  make_fixture "$FX" ""
  assert_equals "make $tool succeeds when its runner succeeds" \
    "0" "$(mk_status "$FX/project" "$tool")"
done

# ShellCheck reaches make through `xargs`, which reports 123 -- not 1 -- when a
# command it ran exited 1..125. A fix that special-cased "exit code 1" would
# still have let every ShellCheck finding through.
FX="$TEST_DIR/xargs-123"
make_fixture "$FX" "shellcheck=123"
assert_true "make shellcheck fails on the 123 that xargs reports, not just on 1" \
  "[ \"\$(mk_status '$FX/project' shellcheck)\" -ne 0 ]"

# A tool killed by the OOM killer or a timeout is the case that reported
# `Terminated (ignored)` and passed. 143 is SIGTERM.
FX="$TEST_DIR/terminated"
make_fixture "$FX" "semgrep=143"
assert_true "make semgrep fails when the tool is terminated rather than finishing" \
  "[ \"\$(mk_status '$FX/project' semgrep)\" -ne 0 ]"

echo ""
echo "The aggregate fails, and says so"
FX="$TEST_DIR/agg-fail"
make_fixture "$FX" "semgrep=1"
assert_true "make sast fails when any single tool fails" \
  "[ \"\$(mk_status '$FX/project' sast)\" -ne 0 ]"
AGG_OUT="$(mk_output "$FX/project" sast)"
assert_contains "make sast names the failing tool on its verdict line" \
  'SAST FAILED:.*semgrep' "$AGG_OUT"
assert_contains "make sast points at the reports directory" \
  'build/reports' "$AGG_OUT"
assert_contains "make sast points at the per-tool suppression files" \
  'semgrepignore' "$AGG_OUT"

echo ""
echo "The aggregate still runs every tool before it fails"
# This is the behaviour the `-` prefixes were introduced for, and the reason the
# fix is not simply deleting them: a prerequisite-only `sast` stops at the first
# failure, so a repository with a Semgrep finding never learns it has a Gitleaks
# one too. `codeql` is first in the suite, so failing it is the hardest case.
FX="$TEST_DIR/agg-runall"
make_fixture "$FX" "codeql=1 semgrep=1"
mk_status "$FX/project" sast > /dev/null
for tool in $TOOLS; do
  assert_true "$tool still ran although an earlier tool had already failed" \
    "[ -f '$FX/pipelines/ran/$tool' ]"
done
RUNALL_OUT="$(mk_output "$FX/project" sast)"
assert_contains "the first failing tool appears on the verdict line" \
  'SAST FAILED:.*codeql' "$RUNALL_OUT"
assert_contains "so does the one that failed after it" \
  'SAST FAILED:.*semgrep' "$RUNALL_OUT"

echo ""
echo "A clean run is unambiguous too"
FX="$TEST_DIR/agg-pass"
make_fixture "$FX" ""
assert_equals "make sast succeeds when no tool reports anything" \
  "0" "$(mk_status "$FX/project" sast)"
assert_contains "make sast says so on its last line, rather than only by exit code" \
  'SAST PASSED' "$(mk_output "$FX/project" sast)"

echo ""
echo "The CodeQL skip is a skip, not a failure"
# Dart and Terraform have no CodeQL extractor and signal that by leaving
# CODEQL_LANGUAGE unset. The skip must not be reported as a finding.
FX="$TEST_DIR/codeql-unset"
make_fixture "$FX" "codeql=1"
sed -i '/^CODEQL_LANGUAGE/d' "$FX/project/Makefile"
assert_equals "make codeql succeeds when no language is configured" \
  "0" "$(mk_status "$FX/project" codeql)"
assert_true "and does not run the runner at all" \
  "[ ! -f '$FX/pipelines/ran/codeql' ]"
assert_equals "make sast succeeds when the only 'failing' tool is the skipped CodeQL" \
  "0" "$(mk_status "$FX/project" sast)"

echo ""
echo "A language fragment's extra tool joins the same suite, in either order"
# `dart.mk` appends its OSV-Scanner target. It must be run by the same
# run-everything-then-report loop, and -- because `SAST_TOOLS_EXTRA` is only ever
# appended to and only ever read -- the include order must not change the suite.
# With a single `?=` variable, including the fragment first would have left
# `sast` running OSV-Scanner alone while still reporting success.
for order in common-first fragment-first; do
  FX="$TEST_DIR/extra-$order"
  make_fixture "$FX" ""
  mkdir -p "$FX/pipelines/global/scripts/languages/extra"
  {
    echo '#!/usr/bin/env sh'
    echo "touch '$FX/pipelines/ran/extra'"
    echo 'exit 1'
  } > "$FX/pipelines/global/scripts/languages/extra/run.sh"
  chmod +x "$FX/pipelines/global/scripts/languages/extra/run.sh"
  {
    echo 'SAST_TOOLS_EXTRA += extra'
    echo 'extra:'
    printf '\t@$(SCRIPTS_DIR)/global/scripts/languages/extra/run.sh\n'
  } > "$FX/pipelines/makefiles/extra.mk"

  if [ "$order" = 'common-first' ]; then
    printf 'SCRIPTS_DIR ?= %s\n-include $(SCRIPTS_DIR)/makefiles/common.mk\n-include $(SCRIPTS_DIR)/makefiles/extra.mk\nCODEQL_LANGUAGE ?= go\n' \
      "$FX/pipelines" > "$FX/project/Makefile"
  else
    printf 'SCRIPTS_DIR ?= %s\n-include $(SCRIPTS_DIR)/makefiles/extra.mk\n-include $(SCRIPTS_DIR)/makefiles/common.mk\nCODEQL_LANGUAGE ?= go\n' \
      "$FX/pipelines" > "$FX/project/Makefile"
  fi

  assert_true "$order: make sast fails when only the fragment's extra tool fails" \
    "[ \"\$(mk_status '$FX/project' sast)\" -ne 0 ]"
  assert_true "$order: the fragment's extra tool ran" \
    "[ -f '$FX/pipelines/ran/extra' ]"
  assert_true "$order: the base suite ran too, rather than being replaced" \
    "[ -f '$FX/pipelines/ran/gitleaks' ] && [ -f '$FX/pipelines/ran/semgrep' ]"
done

echo ""
echo "make -n still shows each tool's real command"
# `.github/tests/test-dart-pipeline.sh` reads `make -n sast` to prove a Dart
# project skips CodeQL and scans with the Dart ruleset. Recipe lines containing
# `$(MAKE)` are executed even under `--dry-run`, which is what keeps that
# readable now that `sast` dispatches through sub-makes rather than
# prerequisites.
FX="$TEST_DIR/dry-run"
make_fixture "$FX" ""
DRY_OUT="$(mk_output "$FX/project" -n sast)"
assert_contains "make -n sast prints the semgrep runner and its language" \
  'semgrep/run.sh "golang"' "$DRY_OUT"
assert_contains "make -n sast prints the gitleaks runner" \
  'gitleaks/run.sh' "$DRY_OUT"
assert_true "make -n sast runs nothing" \
  "[ ! -f '$FX/pipelines/ran/semgrep' ]"
assert_not_contains "including a fragment after common.mk emits no 'overriding recipe' warning" \
  'verriding recipe' "$DRY_OUT"

echo ""
echo "No recipe reintroduces the suppression"
# The static half of this suite. The behavioural assertions above run against
# stubs, so a `-` reintroduced on one recipe would be caught there too -- but
# this names the mistake directly, which is what a reviewer needs to see.
# The pattern needs a REAL tab: `grep -E` reads `\t` as a literal `t`, so the
# obvious spelling of this check matches nothing and passes against the very
# code it exists to reject. Verified by running this suite against the
# pre-fix `makefiles/`, where it must fail.
TAB="$(printf '\t')"
SUPPRESSED="$(grep -nE "^$TAB-@?.*(global/scripts/tools/|global/scripts/languages/dart/sca)" "$SCRIPTS_DIR"/makefiles/*.mk || true)"
assert_equals "no SAST recipe is prefixed with '-' (make ignores its exit status)" \
  "" "$SUPPRESSED"
FORCED="$(grep -nE '(global/scripts/tools/|languages/dart/sca).*\|\|[[:space:]]*true' "$SCRIPTS_DIR"/makefiles/*.mk || true)"
assert_equals "no SAST recipe ends in '|| true'" "" "$FORCED"
assert_true "the CodeQL guard is still a recipe-level test, not a parse-time ifeq" \
  "! grep -qE '^ifeq.*CODEQL_LANGUAGE' '$SCRIPTS_DIR/makefiles/common.mk'"
assert_true "common.mk still skips CodeQL cleanly when no language is configured" \
  "grep -q 'skipping CodeQL' '$SCRIPTS_DIR/makefiles/common.mk'"

echo ""
echo "======================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All tests passed."
