#!/usr/bin/env sh
# shellcheck shell=sh

# Shared helpers for the Argo CD chart runners, `helm-lint` and `render`.
#
# This file is SOURCED, never executed, so it carries no `run.sh` name and no
# executable bit -- same contract as `languages/dart/common.sh`. The caller has
# already run `cleanup.sh`, so `REPORT_PATH` is the tool's own report directory.
#
# Both runners walk the same matrix, one chart and one scenario at a time, so
# the walk lives here and a runner brings only what it does to one scenario.
#
#   chart      every directory holding a `Chart.yaml` under `ARGOCD_CHART_ROOTS`
#              (space-separated, default the repository root), except a subchart
#              vendored in another chart's `charts/` directory, which is part of
#              the chart around it
#   scenario   every `ci/*-values.yaml` of the chart, the chart-testing
#              convention, or the chart's defaults when it has none
#
# EACH SCENARIO RUNS ON ITS OWN. Merging the `ci/` files into one run, which the
# helm family does, cannot express what a GitOps chart keeps there: alternative
# shapes of one chart, whose values may exclude each other and which only reach
# a template together when something is already wrong. A chart with `required`
# values and no defaults for them is the other half of it: the scenarios are the
# only way it renders at all, so a chart that has any is never run with defaults.

ARGOCD_CHART_ROOTS="${ARGOCD_CHART_ROOTS:-.}"

# A root somebody configured and misspelt would otherwise find nothing and pass.
argocd_check_chart_roots() {
  for _cr_root in ${ARGOCD_CHART_ROOTS}; do
    if [ ! -d "${_cr_root}" ]; then
      echo "ERROR: the chart root '${_cr_root}' does not exist." >&2
      return 1
    fi
  done
}

# Prints every chart directory, one per line, sorted: `charts/example`, or `.`
# for a chart at the repository root.
#
# A subchart is told apart by what surrounds it, `<chart>/charts/<name>`, not by
# its path alone: `charts/example` at the top of a repository sits under a
# directory named `charts` too, and it is the chart this is looking for.
argocd_discover_charts() {
  # shellcheck disable=SC2086 # word splitting is intended: these are separate paths
  find ${ARGOCD_CHART_ROOTS} -name '.git' -prune -o -type f -name 'Chart.yaml' -print \
    | sed -e 's|/Chart\.yaml$||' -e 's|^\./||' \
    | while IFS= read -r _dc_chart; do
        _dc_parent="${_dc_chart%/*}"
        case "${_dc_parent}" in
          charts) _dc_owner='.' ;;
          */charts) _dc_owner="${_dc_parent%/charts}" ;;
          *) _dc_owner='' ;;
        esac
        if [ -z "${_dc_owner}" ] || [ ! -f "${_dc_owner}/Chart.yaml" ]; then
          printf '%s\n' "${_dc_chart}"
        fi
      done \
    | LC_ALL=C sort -u
}

# Prints the values file of every scenario of chart $1, one per line. Nothing
# when the chart has none, which is its single scenario, the defaults.
argocd_chart_scenarios() {
  for _cs_values in "$1"/ci/*-values.yaml; do
    if [ -f "${_cs_values}" ]; then
      printf '%s\n' "${_cs_values}"
    fi
  done
}

# `ci/alternative-values.yaml` is the scenario `alternative`.
argocd_scenario_name() {
  _sn_file="${1##*/}"
  printf '%s\n' "${_sn_file%-values.yaml}"
}

argocd_is_library_chart() {
  grep -Eq "^type:[[:space:]]*[\"']?library" "$1/Chart.yaml"
}

# `helm dependency list` prints a table ending at a blank line, whose last column
# is `ok` or `unpacked` for a dependency that is there. What can follow the blank
# line is a warning about a stray file, which is not a row. A chart Helm cannot
# load prints no table, so this finds nothing missing, and the lint or the render
# that comes next says what is wrong with it.
argocd_chart_misses_dependencies() {
  helm dependency list "$1" 2> /dev/null | awk '
    NR == 1 { next }
    NF == 0 { exit }
    $NF != "ok" && $NF != "unpacked" { missing = 1 }
    END { exit missing ? 0 : 1 }
  '
}

# `helm dependency build` refuses a committed `Chart.lock` whose https repository
# Helm has not been told about ("no repository definition for ..."), and a clean
# runner has been told about none. `oci://` and `file://` need no such thing. A
# repository the consumer already added is left alone, because it is added with
# its credentials, in `PRE_STEPS`, and a second entry for the URL would have none.
argocd_add_dependency_repositories() {
  _ar_known="$(helm repo list 2> /dev/null | awk -F '\t' '
    NR > 1 { gsub(/ /, "", $2); sub(/\/$/, "", $2); print $2 }
  ')"
  _ar_urls="$(helm dependency list "$1" 2> /dev/null | awk -F '\t' '
    NR == 1 { next }
    NF == 0 { exit }
    { gsub(/ /, "", $3); sub(/\/$/, "", $3) }
    $3 ~ /^https?:\/\// { print $3 }
  ')"
  for _ar_url in ${_ar_urls}; do
    if ! printf '%s\n' "${_ar_known}" | grep -qxF "${_ar_url}"; then
      _ar_name="argocd-dependency-$(printf '%s' "${_ar_url}" | cksum | cut -d ' ' -f 1)"
      helm repo add "${_ar_name}" "${_ar_url}" || return 1
    fi
  done
}

argocd_build_dependencies() {
  if argocd_chart_misses_dependencies "$1"; then
    argocd_add_dependency_repositories "$1" || return 1
    helm dependency build "$1"
  fi
}

# Escape the five XML predefined entities. The ampersand goes FIRST, or the
# other replacements would have theirs escaped a second time.
argocd_escape_xml() {
  sed -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

# argocd_record <name> [<log of the failure>]
#
# One report line for one test case, with its verdict on the job log. On a
# failure the diagnostic goes to the log as well, so a reader never has to open
# an artifact to see the reason.
argocd_record() {
  _rc_name="$(printf '%s' "$1" | argocd_escape_xml)"
  _ARGOCD_TOTAL=$((_ARGOCD_TOTAL + 1))
  if [ "$#" -eq 1 ]; then
    echo 'ok'
    printf '    <testcase classname="%s" name="%s"/>\n' "${_ARGOCD_SUITE}" "${_rc_name}" >> "${_ARGOCD_WORK}/cases"
    return 0
  fi
  echo 'FAILED'
  cat "$2"
  printf '%s\n' "$1" >> "${_ARGOCD_WORK}/failed"
  {
    printf '    <testcase classname="%s" name="%s">\n' "${_ARGOCD_SUITE}" "${_rc_name}"
    printf '      <failure message="%s"><![CDATA[\n' "${_rc_name}"
    # `]]>` in a diagnostic would close the section early, and a control
    # character is not XML at all, even in CDATA.
    tr -d '\000-\010\013\014\016-\037' < "$2" | sed 's/]]>/]]]]><![CDATA[>/g'
    printf '\n]]></failure>\n    </testcase>\n'
  } >> "${_ARGOCD_WORK}/cases"
}

argocd_write_junit() {
  _wj_failed="$(wc -l < "${_ARGOCD_WORK}/failed" | tr -d ' ')"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuites name="%s" tests="%s" failures="%s">\n' "${_ARGOCD_SUITE}" "${_ARGOCD_TOTAL}" "${_wj_failed}"
    printf '  <testsuite name="%s" tests="%s" failures="%s">\n' "${_ARGOCD_SUITE}" "${_ARGOCD_TOTAL}" "${_wj_failed}"
    cat "${_ARGOCD_WORK}/cases"
    printf '  </testsuite>\n'
    printf '</testsuites>\n'
  } > "${REPORT_PATH}/junit-${_ARGOCD_SUITE}.xml"
}

# argocd_run_one <verb> <callback> <chart> <scenario> <values file, or empty>
argocd_run_one() {
  _ro_name="$3 (scenario: $4)"
  printf '%s %s ... ' "$1" "${_ro_name}"
  # stdin stays out of it: the callers read their lists from it.
  if "$2" "$3" "$4" "$5" < /dev/null > "${_ARGOCD_WORK}/log" 2>&1; then
    argocd_record "${_ro_name}"
  else
    argocd_record "${_ro_name}" "${_ARGOCD_WORK}/log"
  fi
}

# argocd_run_scenarios <suite> <verb> <callback>
#
# Calls `<callback> <chart> <scenario> <values file, or empty for the defaults>`
# once per scenario of every chart, after making sure the chart's dependencies
# are there. A failure does not stop the walk, so one run names every chart and
# scenario that is broken; it writes `junit-<suite>.xml`, and returns non-zero
# when anything failed. A repository with no chart in it passes, as a repository
# with no Dockerfile passes Hadolint: the chart roots are checked separately.
argocd_run_scenarios() {
  _ARGOCD_SUITE="$1"
  _ARGOCD_TOTAL=0
  argocd_check_chart_roots || return 1

  _ARGOCD_WORK="$(mktemp -d)" || return 1
  trap 'rm -rf "${_ARGOCD_WORK}"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  : > "${_ARGOCD_WORK}/cases"
  : > "${_ARGOCD_WORK}/failed"

  argocd_discover_charts > "${_ARGOCD_WORK}/charts"
  if [ ! -s "${_ARGOCD_WORK}/charts" ]; then
    echo "No chart found under '${ARGOCD_CHART_ROOTS}'; nothing to do."
    argocd_write_junit
    return 0
  fi

  "${SCRIPTS_DIR}/global/scripts/languages/argocd/helm/install.sh" || return 1

  while IFS= read -r _rs_chart; do
    if ! argocd_build_dependencies "${_rs_chart}" < /dev/null > "${_ARGOCD_WORK}/log" 2>&1; then
      printf 'Building the dependencies of %s ... ' "${_rs_chart}"
      argocd_record "${_rs_chart} (dependencies)" "${_ARGOCD_WORK}/log"
      continue
    fi
    argocd_chart_scenarios "${_rs_chart}" > "${_ARGOCD_WORK}/scenarios"
    if [ ! -s "${_ARGOCD_WORK}/scenarios" ]; then
      argocd_run_one "$2" "$3" "${_rs_chart}" 'default' ''
      continue
    fi
    while IFS= read -r _rs_values; do
      argocd_run_one "$2" "$3" "${_rs_chart}" "$(argocd_scenario_name "${_rs_values}")" "${_rs_values}"
    done < "${_ARGOCD_WORK}/scenarios"
  done < "${_ARGOCD_WORK}/charts"

  argocd_write_junit
  _rs_failed="$(wc -l < "${_ARGOCD_WORK}/failed" | tr -d ' ')"
  echo "${_ARGOCD_SUITE}: ${_ARGOCD_TOTAL} scenario(s), $((_ARGOCD_TOTAL - _rs_failed)) passed, ${_rs_failed} failed."
  echo "JUnit report: ${REPORT_PATH}/junit-${_ARGOCD_SUITE}.xml"
  if [ "${_rs_failed}" -gt 0 ]; then
    sed 's/^/FAILED: /' "${_ARGOCD_WORK}/failed"
    return 1
  fi
}
