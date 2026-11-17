#!/usr/bin/env bash
# The Azure DevOps security stage's opt-in gate, `ENABLE_SECURITY_GATE`.
#
# Azure DevOps runs its SAST advisory for every toolchain at once (AGENTS.md, "Do not make SAST
# advisory again"): the scan step of each shared template carries `continueOnError`, and so does the
# dependency audit job of the JavaScript and Python stages. A consumer cannot override a literal
# inside a template, so the gate is a boolean parameter, `false` by default, that each hop forwards
# and that the flag is derived from. A hop that drops it fails nothing -- the job falls back to
# advisory and stays green -- so this holds the chain:
#
#   1. the four shared SAST templates declare `ENABLE_SECURITY_GATE`, a boolean defaulting to
#      `false`, their scan step's `continueOnError` is its negation, and their report is published
#      under `always()`, since a failing gated scan would otherwise skip the upload
#   2. the Go, JavaScript and Python security stages declare it the same way, forward it to every
#      shared SAST template they include, and derive their dependency audit job's flag from it
#   3. the Go, Python and JavaScript Docker entry points declare it and forward it to their
#      security stage
#
# A consumer that does not set the parameter therefore renders the same pipeline as before.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1

AZURE="$SCRIPTS_DIR/azure-devops"
SHARED_TOOLS=('semgrep' 'gitleaks' 'codeql' 'hadolint')
# Each entry: the language stage, the job whose flag it derives from the gate ('' for none), and
# the Docker entry point that includes the stage.
LANGUAGES=(
  'golang/stages/20-security/go.yaml||golang/go-docker.yaml'
  'javascript/stages/20-security/yarn.yaml|sca_yarn_audit|javascript/yarn-docker.yaml'
  'python/stages/20-security/pdm.yaml|sca_safety|python/pdm-docker.yaml'
)

# What every hop passes on and what every flag reads, written once so that no assertion can spell
# them differently.
FORWARDED='${{ parameters.ENABLE_SECURITY_GATE }}'
ADVISORY_UNLESS_GATED='${{ not(parameters.ENABLE_SECURITY_GATE) }}'
export FORWARDED ADVISORY_UNLESS_GATED

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_equals() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (expected '$expected', got '$actual')${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_empty() {
  local description="$1" findings="$2"
  if [[ -z "$findings" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    printf '%s\n' "$findings" | sed 's/^/         /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# The templates are read with mikefarah/yq, resolved the way every script here resolves it.
TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"
. "$SCRIPTS_DIR/global/scripts/shared/resolve-yq.sh"
YQ=""
resolve_yq "$TEST_DIR/yqbin" || {
  echo -e "${RED}could not resolve mikefarah/yq, so no assertion can run${NC}"
  exit 1
}

# declared_gate prints the type and default of a file's `ENABLE_SECURITY_GATE`, as `type|default`.
declared_gate() {
  "$YQ" eval '.parameters[] | select(.name == "ENABLE_SECURITY_GATE") | .type + "|" + (.default | tostring)' "$1" 2> /dev/null
}

echo "=========================================="
echo "Azure DevOps security gate validation"
echo "=========================================="

# ---------------------------------------------------------------------------
echo ""
echo "1. Every shared SAST template is advisory unless the gate is enabled"
# ---------------------------------------------------------------------------
for tool in "${SHARED_TOOLS[@]}"; do
  # given
  file="$AZURE/global/stages/20-security/$tool.yaml"

  # when
  declared="$(declared_gate "$file")"
  flags="$("$YQ" eval '.jobs[].steps[] | select(has("script")) | select(.script | test("global/scripts/tools/.+/run\.sh")) | .continueOnError' "$file" 2> /dev/null)"
  publish="$("$YQ" eval '.jobs[].steps[] | select(.task == "PublishPipelineArtifact@1") | .condition' "$file" 2> /dev/null)"

  # then
  assert_equals "$tool.yaml declares ENABLE_SECURITY_GATE, a boolean defaulting to false" 'boolean|false' "$declared"
  assert_equals "$tool.yaml derives its scan step's continueOnError from the gate" "$ADVISORY_UNLESS_GATED" "$flags"
  # A gated scan that fails would otherwise skip the upload, losing the report of what it found.
  assert_equals "$tool.yaml publishes its report even when the gated scan fails" 'always()' "$publish"
done

# ---------------------------------------------------------------------------
echo ""
echo "2. Every language security stage forwards the gate and derives its audit job from it"
# ---------------------------------------------------------------------------
for entry in "${LANGUAGES[@]}"; do
  IFS='|' read -r stage audit_job _ <<< "$entry"
  # given
  file="$AZURE/$stage"

  # when
  declared="$(declared_gate "$file")"
  included="$("$YQ" eval '[.stages[].jobs[] | select(has("template")) | select(.template | test("global/stages/20-security/"))] | length' "$file" 2> /dev/null)"
  dropped="$(FORWARDED="$FORWARDED" "$YQ" eval '.stages[].jobs[] | select(has("template")) | select(.template | test("global/stages/20-security/")) | select((.parameters.ENABLE_SECURITY_GATE // "") != strenv(FORWARDED)) | .template' "$file" 2> /dev/null)"

  # then
  assert_equals "$stage declares ENABLE_SECURITY_GATE, a boolean defaulting to false" 'boolean|false' "$declared"
  assert_equals "$stage includes the four shared SAST templates" '4' "$included"
  assert_empty "$stage forwards the gate to every shared SAST template it includes" "$dropped"

  if [[ -n "$audit_job" ]]; then
    flag="$(JOB="$audit_job" "$YQ" eval '.stages[].jobs[] | select(.job == strenv(JOB)) | .continueOnError' "$file" 2> /dev/null)"
    assert_equals "$stage derives $audit_job's continueOnError from the gate" "$ADVISORY_UNLESS_GATED" "$flag"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "3. Every Docker entry point forwards the gate to its security stage"
# ---------------------------------------------------------------------------
for entry in "${LANGUAGES[@]}"; do
  IFS='|' read -r _ _ docker <<< "$entry"
  # given
  file="$AZURE/$docker"

  # when
  declared="$(declared_gate "$file")"
  forwarded="$("$YQ" eval '.stages[] | select(.template == "stages/20-security/*") | .parameters.ENABLE_SECURITY_GATE' "$file" 2> /dev/null)"

  # then
  assert_equals "$docker declares ENABLE_SECURITY_GATE, a boolean defaulting to false" 'boolean|false' "$declared"
  assert_equals "$docker forwards the gate to its security stage" "$FORWARDED" "$forwarded"
done

echo ""
echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All Azure DevOps security gate tests passed!"
