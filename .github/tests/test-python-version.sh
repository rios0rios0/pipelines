#!/usr/bin/env bash
# The Python each PDM template runs, and the Python each PDM image ships.
#
# `azure-devops/python/pdm-docker.yaml` takes `PYTHON_VERSION`, the Python of every job that sets
# one up: the code check, `sca:safety` and the CodeQL analysis, `test:all` and
# `report:dependency-track`. It reaches each of them through two more template parameters, and a
# hop that drops it fails nothing: that job sets up the default and passes, so a project that moved
# to 3.15 would run part of its pipeline on 3.14 and never be told. A `.venv` restored from a cache
# saved under the other Python is the same failure, since PDM reuses the interpreter inside it. So
# this holds the chain:
#
#   1. the entry point, the four stages and the abstract declare `PYTHON_VERSION`, a string
#      defaulting to '3.14', the Python every job ran before the parameter existed
#   2. the entry point forwards it to the four stages, and each stage forwards it to every include
#      of the abstract
#   3. every `UsePythonVersion@0` of the family -- the abstract's, and the one the CodeQL job runs
#      from `PRE_STEPS` -- sets up the parameter, never a literal, and the `.venv` cache key names
#      it in a quoted segment: the Cache task takes an unquoted segment holding a `.` for a file
#      whose contents it should hash
#
# and, for every PDM image under `global/containers/`, that its base image is the Python and the
# Debian release its folder names. The folder name IS the published tag, so an image copied from
# its predecessor and left on the old base would publish one Python under another's name.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1

FAMILY="$SCRIPTS_DIR/azure-devops/python"
ENTRY="$FAMILY/pdm-docker.yaml"
ABSTRACT_INCLUDE='../../abstracts/pdm-python3.14.yaml'
ABSTRACT="$FAMILY/abstracts/pdm-python3.14.yaml"
SECURITY="$FAMILY/stages/20-security/pdm.yaml"
STAGES=(
  'stages/10-code-check/pdm.yaml'
  'stages/20-security/pdm.yaml'
  'stages/30-tests/pdm.yaml'
  'stages/35-management/pdm.yaml'
)
CONTAINERS="$SCRIPTS_DIR/global/containers"

# What every hop passes on, written once so that no assertion can spell it differently.
EXPRESSION='${{ parameters.PYTHON_VERSION }}'
export EXPRESSION

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

relative() { printf '%s' "${1#"$SCRIPTS_DIR"/}"; }

echo "=========================================="
echo "Python version validation"
echo "=========================================="

# ---------------------------------------------------------------------------
echo ""
echo "1. Every Azure DevOps PDM template declares PYTHON_VERSION, defaulting to 3.14"
# ---------------------------------------------------------------------------
# given -- the entry point, the four stages that set up Python, and the abstract they include
for file in "$ENTRY" "${STAGES[@]/#/$FAMILY/}" "$ABSTRACT"; do
  # when
  declared="$("$YQ" eval '.parameters[] | select(.name == "PYTHON_VERSION") | .type + "|" + .default' "$file" 2> /dev/null)"
  # then
  assert_true "$(relative "$file") declares PYTHON_VERSION, a string defaulting to '3.14' (${declared:-not declared})" \
    '[[ "$declared" == "string|3.14" ]]'
done

# ---------------------------------------------------------------------------
echo ""
echo "2. PYTHON_VERSION reaches every job"
# ---------------------------------------------------------------------------
for stage in "${STAGES[@]}"; do
  # given -- the stage's include in the entry point, and the stage's includes of the abstract
  # when
  forwarded="$(STAGE="$stage" "$YQ" eval '.stages[] | select(.template == strenv(STAGE)) | .parameters.PYTHON_VERSION' "$ENTRY" 2> /dev/null)"
  includes="$(TARGET="$ABSTRACT_INCLUDE" "$YQ" eval '[.. | select(tag == "!!map" and has("template")) | select(.template == strenv(TARGET))] | length' "$FAMILY/$stage" 2> /dev/null)"
  dropped="$(TARGET="$ABSTRACT_INCLUDE" "$YQ" eval '.. | select(tag == "!!map" and has("template")) | select(.template == strenv(TARGET)) | select((.parameters.PYTHON_VERSION // "") != strenv(EXPRESSION)) | path | join(".")' "$FAMILY/$stage" 2> /dev/null)"
  # then
  assert_true "the entry point forwards PYTHON_VERSION to $stage (${forwarded:-nothing})" \
    '[[ "$forwarded" == "$EXPRESSION" ]]'
  assert_true "$stage includes the abstract (includes: ${includes:-0})" '[[ "${includes:-0}" -gt 0 ]]'
  assert_empty "...and forwards its PYTHON_VERSION to every one of them" "$dropped"
done

# ---------------------------------------------------------------------------
echo ""
echo "3. Each job sets up the Python it is given, and caches by it"
# ---------------------------------------------------------------------------
# given -- every template of the family
literal=''
while IFS= read -r -d '' file; do
  # when
  found="$("$YQ" eval '.. | select(tag == "!!map") | select(.task == "UsePythonVersion@0") | select((.inputs.versionSpec // "") != strenv(EXPRESSION)) | (.inputs.versionSpec // "(none)")' "$file" 2> /dev/null)"
  [[ -n "$found" ]] && literal="${literal}$(relative "$file"): versionSpec ${found}"$'\n'
done < <(find "$FAMILY" -name '*.yaml' -print0)
# then
assert_empty "every UsePythonVersion@0 of the Azure DevOps Python templates sets up PYTHON_VERSION" "$literal"

codeql="$("$YQ" eval '.. | select(tag == "!!map" and has("template")) | select(.template | test("20-security/codeql\.yaml$")) | (.parameters.PRE_STEPS // [])[] | select(.task == "UsePythonVersion@0") | .inputs.versionSpec' "$SECURITY" 2> /dev/null)"
assert_true "the CodeQL job's PRE_STEPS set up PYTHON_VERSION, as every other job of its stage does (${codeql:-none})" \
  '[[ "$codeql" == "$EXPRESSION" ]]'

# A segment the Cache task reads as a file fails the step, which is `continueOnError`: caching
# would stop with every job still green.
cache_key="$("$YQ" eval '.steps[] | select(.task == "Cache@2") | .inputs.key' "$ABSTRACT" 2> /dev/null)"
assert_true "the abstract's .venv cache key names PYTHON_VERSION in a quoted segment (${cache_key:-no key})" \
  '[[ "$cache_key" == *"|\"Python $EXPRESSION\"|"* ]]'
assert_true "...beside the directory it is restored into and pdm.lock" \
  '[[ "$cache_key" == *"|\"\$(System.DefaultWorkingDirectory)\"|"* && "$cache_key" == *"|pdm.lock" ]]'

# ---------------------------------------------------------------------------
echo ""
echo "4. Each PDM image is built on the Python its tag names"
# ---------------------------------------------------------------------------
# given -- every `python.<minor>-pdm-<codename>` folder, the folder name being the published tag
images=0
while IFS= read -r folder; do
  images=$((images + 1))
  tag="${folder#*.}"
  minor="${tag%%-*}"
  codename="${tag##*-}"
  # when
  base="$(awk 'toupper($1) == "FROM" { print $2; exit }' "$CONTAINERS/$folder/Dockerfile" 2> /dev/null)"
  # then
  assert_true "$folder is built on Python $minor and Debian $codename (${base:-no FROM})" \
    '[[ "$base" == "python:$minor-slim-$codename@sha256:"* ]]'
done < <(find "$CONTAINERS" -mindepth 1 -maxdepth 1 -type d -name 'python.*-pdm-*' -printf '%f\n' | sort)
assert_true "there is a PDM image to check ($images)" '[[ "$images" -gt 0 ]]'

echo ""
echo "=========================================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=========================================="
[[ "$TESTS_FAILED" -eq 0 ]]
