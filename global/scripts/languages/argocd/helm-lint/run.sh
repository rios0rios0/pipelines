#!/usr/bin/env sh
set -eu

# GitLab CI/CD leverages this variable to source shared helpers from the
# pipelines checkout. Matches the preamble used by every other run.sh.
if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*\)/global/scripts/.*|\1|')"
  export SCRIPTS_DIR
fi

# Runs `helm lint` over every chart under `ARGOCD_CHART_ROOTS`, once per
# `ci/*-values.yaml` scenario: a template that reads a value only a scenario sets
# fails a lint that is given none. `common.sh` holds the walk and why it runs
# scenario by scenario.
#
# `helm lint` is not a render. It lets `required` and `fail` through, by design,
# so a scenario that trips one of them passes here and fails in the `render`
# runner, which is what the two jobs are for.
#
# Reports land in build/reports/argocd-helm-lint/, as `junit-helm-lint.xml`.

REPORT_PATH="${REPORT_PATH:-}"
TOOL_NAME="argocd-helm-lint" . "${SCRIPTS_DIR}/global/scripts/shared/cleanup.sh"
. "${SCRIPTS_DIR}/global/scripts/languages/argocd/common.sh"

lint_scenario() {
  helm lint "$1" ${3:+--values "$3"}
}

argocd_run_scenarios 'helm-lint' 'Linting' lint_scenario
