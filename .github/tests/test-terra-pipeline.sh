#!/usr/bin/env bash
# The assertion helper takes its condition as a STRING and `eval`s it, so ShellCheck cannot
# see that every variable it reads is used. A file-wide directive is only honoured before the
# first command, which is why it sits here.
# shellcheck disable=SC2034
set -e
# Validation for the Terraform (terra) pipeline's tool gap.
#
# CodeQL ships no HCL extractor. `.github/workflows/terra.yaml` used to carry a
# `sast:codeql` job with `codeql_language: 'hcl'`, and it failed on every run at
# `codeql resolve languages` ("Did not recognize the following languages: hcl");
# `continue-on-error` turned that into a red-but-ignored job on every pull request of
# every consumer. The gap is handled the way the Dart pipeline handles the same gap: by
# a deliberate ABSENCE, with Semgrep's Terraform rules as the static analysis for HCL.
# An absence is exactly what a later "make the languages consistent" edit silently
# undoes, so this suite defends it on every platform and in both Makefile includes
# (`terra.mk` pairs with this workflow, `terraform.mk` with the raw Terraform one).
#
# Runs OFFLINE with nothing but bash and grep.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

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

skip() {
  echo -e "${YELLOW}  SKIP: $1${NC}"
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

echo "=========================================="
echo "Terraform pipeline validation"
echo "=========================================="

echo ""
echo "--- 1. Tool gap: CodeQL is absent on every platform ---"

GITHUB_WORKFLOW="$SCRIPTS_DIR/.github/workflows/terra.yaml"
assert_true "GitHub: the Terraform workflow exists" "[ -f '$GITHUB_WORKFLOW' ]"
assert_true "GitHub: no CodeQL job is wired in the Terraform workflow" \
  "! grep -E '^[^#]*20-security/codeql' '$GITHUB_WORKFLOW'"
assert_true "GitHub: no job asks CodeQL for the hcl language" \
  "! grep -qE \"^[^#]*codeql_language: *'?hcl\" '$GITHUB_WORKFLOW'"
assert_true "GitHub: the absence is explained where the job used to be, so it survives review" \
  "grep -q 'no HCL extractor' '$GITHUB_WORKFLOW'"

# `**` only recurses with globstar; without it the pattern silently means one level, which
# is exactly how a stage file two levels down would escape the assertion. Both the raw
# Terraform trees and the Terra CLI trees are inspected on both platforms, at every depth.
shopt -s globstar
found_template=0
for template in "$SCRIPTS_DIR"/gitlab/terra/**/*.yaml "$SCRIPTS_DIR"/gitlab/terraform/**/*.yaml \
                "$SCRIPTS_DIR"/azure-devops/terra/**/*.yaml "$SCRIPTS_DIR"/azure-devops/terraform/**/*.yaml; do
  [ -f "$template" ] || continue
  found_template=1
  assert_true "$(echo "$template" | sed "s|$SCRIPTS_DIR/||"): no CodeQL job is wired for Terraform" \
    "! grep -E '^[^#]*codeql' '$template'"
done
[ "$found_template" -eq 1 ] || skip "no GitLab/Azure DevOps Terraform template found to inspect"

echo ""
echo "--- 2. Both Makefile includes skip CodeQL for the same reason ---"
for mk in terra terraform; do
  assert_true "$mk.mk leaves CODEQL_LANGUAGE unset so 'make sast' skips CodeQL" \
    "! grep -qE '^CODEQL_LANGUAGE' '$SCRIPTS_DIR/makefiles/$mk.mk'"
  assert_true "$mk.mk says why, so the omission reads as a decision" \
    "grep -qi 'CodeQL does not support Terraform' '$SCRIPTS_DIR/makefiles/$mk.mk'"
done

echo ""
echo "--- 3. Terra forwards the coverage artifact parameters to the shared Sonar job ---"

# The feature here IS the forwarding, and nothing about a template fails when it stops
# happening. `35-management/terra.yaml` used to pin `DOWNLOAD_COVERAGE_ARTIFACT: false`
# as a literal; stages are separate jobs with separate workspaces, so that artifact
# download is the only channel into the Sonar job, and a Terraform consumer that did
# produce a coverage report had no way to reach `sonar-scanner`. A later edit that
# re-pins the literal, or that drops either hop of the two-hop chain, leaves a pipeline
# that still parses and still runs -- it just silently stops carrying the value, which
# shows up as 0% coverage rather than as a failure. Both hops, the absence of the pin
# and the backward-compatible defaults are therefore asserted. The defaults matter on
# their own: they reproduce the old pinned behaviour exactly, which is what lets this
# land without touching a single existing consumer.
#
# Note `false` legitimately remains in both files as the parameter's `default:`, so the
# pin assertion looks for the literal being PASSED (`NAME: false`), not for the word.

TERRA_ROOT="$SCRIPTS_DIR/azure-devops/terra/terra.yaml"
TERRA_MGMT="$SCRIPTS_DIR/azure-devops/terra/stages/35-management/terra.yaml"

for hop in "$TERRA_ROOT|stages/35-management/terra.yaml" \
           "$TERRA_MGMT|../../../global/stages/35-management/sonarqube.yaml"; do
  hop_file="${hop%%|*}"
  hop_target="${hop#*|}"
  hop_label="$(echo "$hop_file" | sed "s|$SCRIPTS_DIR/||")"

  assert_true "$hop_label: the template exists" "[ -f '$hop_file' ]"

  for param in DOWNLOAD_COVERAGE_ARTIFACT COVERAGE_ARTIFACT_NAME COVERAGE_ARTIFACT_TARGET_PATH; do
    assert_true "$hop_label: declares $param as a parameter" \
      "grep -qE \"^ *- name: '$param'\" '$hop_file'"
    assert_true "$hop_label: forwards $param on to $hop_target" \
      "grep -A12 -F \"template: '$hop_target'\" '$hop_file' | grep -qF '$param: \${{ parameters.$param }}'"
  done

  # The defaults keep the pre-change behaviour: no download, named `coverage`, repo root.
  for spec in 'DOWNLOAD_COVERAGE_ARTIFACT|default: false' \
              "COVERAGE_ARTIFACT_NAME|default: 'coverage'" \
              'COVERAGE_ARTIFACT_TARGET_PATH|default: "$(Build.SourcesDirectory)"'; do
    spec_param="${spec%%|*}"
    spec_default="${spec#*|}"
    assert_true "$hop_label: $spec_param keeps the backward-compatible '$spec_default'" \
      "grep -A2 -F -e \"- name: '\$spec_param'\" \"\$hop_file\" | grep -qF -e \"\$spec_default\""
  done

  assert_true "$hop_label: passes no literal DOWNLOAD_COVERAGE_ARTIFACT, so the opt-in is not re-pinned" \
    "! grep -qE '^[^#]*DOWNLOAD_COVERAGE_ARTIFACT: *(true|false)' '$hop_file'"
done

echo ""
echo "=========================================="
echo -e "Passed:  ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:  ${RED}$TESTS_FAILED${NC}"
[[ $TESTS_SKIPPED -gt 0 ]] && echo -e "Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}Terraform pipeline validation FAILED${NC}"
  exit 1
fi
echo -e "${GREEN}Terraform pipeline validation passed${NC}"
exit 0
