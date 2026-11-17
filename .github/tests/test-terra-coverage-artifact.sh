#!/usr/bin/env bash
set -e

# Hold the retry contract of the `terra-coverage` artifact that the Terraform
# test stage (`azure-devops/terra/stages/30-tests/terra.yaml`) publishes for the
# SonarQube stage.
#
# Why a dedicated regression test exists:
#
# A pipeline artifact name can be published once per run. The stage used to
# publish `terra-coverage` under `condition: always()`, so a failed or
# cancelled `test:all` took the name, and retrying the job then failed on
# `Artifact terra-coverage already exists for build <id>` after every test had
# passed: no retry of that job could ever pass. Three things must hold:
#
#   1. Only a passing attempt publishes `terra-coverage`, and only once: the
#      step first asks the build API whether an earlier attempt already did.
#   2. A failed attempt (or a passing re-run that finds the name taken) still
#      publishes its reports, under a name unique to the attempt.
#   3. The check reads the job token from stdin, never from argv, and fails
#      open: an answer it does not understand publishes as before.
#
# The check step's own inline script runs against a `curl` stub that answers
# the status the case needs and records its arguments.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="$SCRIPTS_DIR/azure-devops/terra/stages/30-tests/terra.yaml"
TEST_DIR="$(mktemp -d)" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# assert <description> <command...>: passes when the command succeeds.
assert() {
  local description="$1"
  shift
  if "$@"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}
not() { ! "$@"; }
has() { grep -qF -- "$2" <<< "$1"; } # has <text> <needle>

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# The block of the step whose artifact is <name> (an ERE): from its `- task:`
# line to the line before the next list item.
publish_task() {
  awk -v want="$1" '
    /^ *- (task|bash|script|template):/ {
      if (block != "" && found) { printf "%s", block; done = 1; exit }
      block = ""; found = 0
    }
    { block = block $0 "\n" }
    $0 ~ ("artifactName: .?" want ".?$") { found = 1 }
    END { if (!done && found) printf "%s", block }
  ' "$STAGE"
}

echo "== only a passing attempt publishes terra-coverage =="
FIXED="$(publish_task 'terra-coverage')"
assert "a task publishes terra-coverage" test -n "$FIXED"
assert "it runs only after success, and only when no earlier attempt published it" \
  has "$FIXED" "condition: and(succeeded(), ne(variables['TERRA_COVERAGE_PUBLISHED'], 'true'))"
always_publish() {
  awk '/PublishPipelineArtifact@1/ { t = 1 } t && /condition: *always\(\)/ { bad = 1 } /^ *- (task|bash|script):/ && !/PublishPipelineArtifact@1/ { t = 0 } END { exit !bad }' "$STAGE"
}
assert "no artifact of the stage is published under always()" not always_publish

echo "== a failed attempt keeps its reports under a name of its own =="
ATTEMPT="$(publish_task 'terra-coverage-attempt-[$][(]System[.]JobAttempt[)]')"
assert "a task publishes terra-coverage-attempt-<attempt>" test -n "$ATTEMPT"
assert "it runs after a failure or when the fixed name is taken" \
  has "$ATTEMPT" "condition: or(failed(), eq(variables['TERRA_COVERAGE_PUBLISHED'], 'true'))"
assert "it never fails the job itself" has "$ATTEMPT" "continueOnError: true"

# The check step's inline script: the `- bash: |` block whose displayName is
# the check's, de-indented.
awk '
  /^ *- bash: \|$/ { capture = 1; body = ""; next }
  capture && /displayName: .Check for an earlier Terra coverage report./ { printf "%s", body; exit }
  capture && /^ *(displayName|condition|env):/ { capture = 0 }
  capture { body = body $0 "\n" }
' "$STAGE" | sed -e 's/^              //' > "$TEST_DIR/check.sh"

mkdir -p "$TEST_DIR/bin"
{
  echo '#!/usr/bin/env bash'
  echo "echo \"\$*\" >> '$TEST_DIR/curl.args'"
  echo "cat > '$TEST_DIR/curl.stdin'"
  echo "cat '$TEST_DIR/status'"
} > "$TEST_DIR/bin/curl"
chmod +x "$TEST_DIR/bin/curl"

# run_check <status the build API answers>
run_check() {
  printf '%s' "$1" > "$TEST_DIR/status"
  rm -f "$TEST_DIR/curl.args" "$TEST_DIR/curl.stdin"
  env PATH="$TEST_DIR/bin:$PATH" SYSTEM_COLLECTIONURI='https://ci.example.test/org/' SYSTEM_TEAMPROJECTID='project-id' \
    BUILD_BUILDID=42 SYSTEM_JOBATTEMPT=2 SYSTEM_ACCESSTOKEN='fixture-token-placeholder' bash "$TEST_DIR/check.sh"
}

echo "== the check =="
assert "the inline script was cut out of the stage" grep -q "artifactName=terra-coverage" "$TEST_DIR/check.sh"
OUT="$(run_check 200)"
assert "an earlier passing attempt sets TERRA_COVERAGE_PUBLISHED" \
  has "$OUT" "##vso[task.setvariable variable=TERRA_COVERAGE_PUBLISHED]true"
assert "and the attempt publishes under its own name" has "$OUT" "terra-coverage-attempt-2 instead"
assert "it asks for this build's terra-coverage artifact" \
  grep -qF "https://ci.example.test/org/project-id/_apis/build/builds/42/artifacts?artifactName=terra-coverage" "$TEST_DIR/curl.args"
assert "the token reaches curl on stdin" grep -qF "Authorization: Bearer fixture-token-placeholder" "$TEST_DIR/curl.stdin"
assert "and never on its command line" not grep -qF "fixture-token-placeholder" "$TEST_DIR/curl.args"
OUT="$(run_check 404)"
assert "no earlier copy leaves the variable unset" not has "$OUT" "TERRA_COVERAGE_PUBLISHED"
OUT="$(run_check 500)"
assert "an answer it does not understand fails open" not has "$OUT" "TERRA_COVERAGE_PUBLISHED"
assert "and says so" has "$OUT" "publishing it as before"

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
