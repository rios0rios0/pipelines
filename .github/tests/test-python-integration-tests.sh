#!/usr/bin/env bash
# Test the opt-in integration-test step of the Azure DevOps PDM pipeline.
#
# Two halves, because either alone is defeatable:
#   * the runner (`global/scripts/languages/python/test-integration/run.sh`) is
#     run against throwaway Makefiles: it runs `make test-integration` only when
#     a rule defines that target, propagates the target's failure, warns and
#     passes when there is nothing to run, and runs no recipe while looking;
#   * the templates are read with PyYAML: `RUN_INTEGRATION_TESTS` is a boolean
#     that defaults to off on the stage and on `pdm-docker.yaml`, the entry
#     template forwards it, and the step exists only behind it, after the unit
#     tests.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_SH="$SCRIPTS_DIR/global/scripts/languages/python/test-integration/run.sh"
TEST_DIR="$(mktemp -d)" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
  echo -e "${GREEN}  PASS: $1${NC}"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  echo -e "${RED}  FAIL: $1${NC}"
  if [ -n "${2:-}" ]; then
    while IFS= read -r line; do echo "         $line"; done <<< "$2"
  fi
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# run_in <name> <makefile-content|-> [env...]: runs the runner in a fresh
# directory (no Makefile when the content is `-`) and sets OUT, RC and DIR.
run_in() {
  local name="$1" content="$2"
  shift 2
  DIR="$TEST_DIR/$name"
  mkdir -p "$DIR" || return 1
  if [ "$content" != "-" ]; then
    printf '%b' "$content" > "$DIR/Makefile" || return 1
  fi
  OUT="$(cd "$DIR" && env -u TF_BUILD "$@" "$RUN_SH" 2>&1)"
  RC=$?
}

echo "Runner"

# given a Makefile that defines the target
run_in with-target 'test-integration:\n\ttouch ran\n'
# then the target ran and the step passed
if [ "$RC" -eq 0 ] && [ -f "$DIR/ran" ]; then
  pass "runs make test-integration when the Makefile defines it"
else
  fail "runs make test-integration when the Makefile defines it" "rc=$RC $OUT"
fi

# given a target that fails
run_in failing-target 'test-integration:\n\texit 3\n'
# then the step fails too
if [ "$RC" -ne 0 ]; then
  pass "fails the step when the integration tests fail"
else
  fail "fails the step when the integration tests fail" "$OUT"
fi

# given a Makefile without the target, whose default goal leaves a marker
# shellcheck disable=SC2016 # `$(MAKE)` is Makefile text, not shell
run_in without-target 'all:\n\ttouch ran\nother:\n\t$(MAKE) all\n'
# then it warns, passes, and ran no recipe while looking
if [ "$RC" -eq 0 ] && [ ! -f "$DIR/ran" ] && echo "$OUT" | grep -q "WARNING: .*'test-integration'"; then
  pass "warns and passes, running nothing, when the target is missing"
else
  fail "warns and passes, running nothing, when the target is missing" "rc=$RC $OUT"
fi

# given the name only as a prerequisite of another target
run_in prerequisite-only 'all: test-integration\n\ttouch ran\n'
# then it is not a target of its own and nothing runs
if [ "$RC" -eq 0 ] && [ ! -f "$DIR/ran" ] && echo "$OUT" | grep -q "WARNING:"; then
  pass "does not count a name that is only a prerequisite"
else
  fail "does not count a name that is only a prerequisite" "rc=$RC $OUT"
fi

# given a target defined in an included file, with a double colon
run_in included-target 'include tests.mk\n'
printf 'test-integration::\n\ttouch ran\n' > "$DIR/tests.mk"
OUT="$(cd "$DIR" && env -u TF_BUILD "$RUN_SH" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$DIR/ran" ]; then
  pass "finds the target in an included file"
else
  fail "finds the target in an included file" "rc=$RC $OUT"
fi

# given no Makefile at all, on Azure DevOps
run_in no-makefile - TF_BUILD=True
# then the warning is raised as an Azure DevOps issue and the step passes
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '^##vso\[task.logissue type=warning\]'; then
  pass "raises an Azure DevOps warning when there is no Makefile"
else
  fail "raises an Azure DevOps warning when there is no Makefile" "rc=$RC $OUT"
fi

if [ -x "$RUN_SH" ]; then
  pass "the runner is executable"
else
  fail "the runner is executable"
fi

echo "Templates"

WIRING="$(cd "$SCRIPTS_DIR" && /usr/bin/env python3 - << 'PY'
import sys
try:
    import yaml
except ImportError:
    print("PyYAML is required to read the Azure DevOps templates")
    sys.exit(0)

PARAM = "RUN_INTEGRATION_TESTS"
GUARD = "${{ if parameters.%s }}" % PARAM
STEP = "$(Scripts.Directory)/global/scripts/languages/python/test-integration/run.sh"
problems = []

def load(path):
    with open(path) as handle:
        return yaml.safe_load(handle)

def check_declared(path, doc):
    params = [p for p in doc.get("parameters", []) if p.get("name") == PARAM]
    if len(params) != 1:
        problems.append(f"{path}: declares {PARAM} {len(params)} times, expected once")
    elif params[0].get("type") != "boolean" or params[0].get("default") is not False:
        problems.append(f"{path}: {PARAM} must be a boolean defaulting to false")

stage_path = "azure-devops/python/stages/30-tests/pdm.yaml"
stage = load(stage_path)
check_declared(stage_path, stage)
steps = stage["stages"][0]["jobs"][0]["steps"]
unit = [i for i, s in enumerate(steps) if isinstance(s, dict) and s.get("displayName") == "Run Tests"]
guarded = [i for i, s in enumerate(steps) if isinstance(s, dict) and GUARD in s]
bare = [s for s in steps if isinstance(s, dict) and s.get("script") == STEP]
if bare:
    problems.append(f"{stage_path}: the integration step runs without the {PARAM} guard")
if len(guarded) != 1:
    problems.append(f"{stage_path}: expected one step guarded by {PARAM}, found {len(guarded)}")
else:
    inner = steps[guarded[0]][GUARD]
    if [s.get("script") for s in inner] != [STEP]:
        problems.append(f"{stage_path}: the {PARAM} guard must hold only the integration runner")
    if not unit or guarded[0] < unit[0]:
        problems.append(f"{stage_path}: the integration step must come after the unit tests")

entry_path = "azure-devops/python/pdm-docker.yaml"
entry = load(entry_path)
check_declared(entry_path, entry)
calls = [s for s in entry["stages"] if s.get("template") == "stages/30-tests/pdm.yaml"]
forwarded = calls and (calls[0].get("parameters") or {}).get(PARAM)
if forwarded != "${{ parameters.%s }}" % PARAM:
    problems.append(f"{entry_path}: does not forward {PARAM} to the test stage")

print("\n".join(problems))
PY
)"
if [ -z "$WIRING" ]; then
  pass "RUN_INTEGRATION_TESTS defaults to off, is forwarded, and guards one step after the unit tests"
else
  fail "RUN_INTEGRATION_TESTS defaults to off, is forwarded, and guards one step after the unit tests" "$WIRING"
fi

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
