#!/usr/bin/env sh
set -eu

# GitLab CI/CD leverages this variable to source shared helpers from the
# pipelines checkout. Matches the preamble used by every other run.sh.
if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*\)/global/scripts/.*|\1|')"
  export SCRIPTS_DIR
fi

# Renders every chart under `ARGOCD_CHART_ROOTS` with `helm template`, once per
# `ci/*-values.yaml` scenario, as Argo CD will render it. A template that does
# not render fails here, on the pull request, instead of as an out-of-sync
# application after the merge. `common.sh` holds the walk and why the scenarios
# are never merged.
#
# The manifests land in build/reports/argocd-render/rendered/, as
# `<chart>/<scenario>.yaml`, which is what the `schema` runner validates and
# what names the chart and the scenario in anything it finds. The report beside
# them is `junit-render.xml`.
#
# A library chart is linted and never rendered: Helm refuses to, by design, and
# the chart that depends on it is what renders its templates.

REPORT_PATH="${REPORT_PATH:-}"
TOOL_NAME="argocd-render" . "${SCRIPTS_DIR}/global/scripts/shared/cleanup.sh"
. "${SCRIPTS_DIR}/global/scripts/languages/argocd/common.sh"

RENDERED_DIR="${REPORT_PATH}/rendered"
mkdir -p "${RENDERED_DIR}"

# `--include-crds` because Argo CD applies a chart's `crds/` too. Helm's
# diagnostics stay out of the manifest: only stdout goes to the file.
render_scenario() {
  if argocd_is_library_chart "$1"; then
    return 0
  fi
  mkdir -p "${RENDERED_DIR}/$1"
  _rn_output="${RENDERED_DIR}/$1/$2.yaml"
  if helm template "$1" --include-crds ${3:+--values "$3"} > "${_rn_output}"; then
    return 0
  fi
  rm -f "${_rn_output}"
  return 1
}

argocd_run_scenarios 'render' 'Rendering' render_scenario
