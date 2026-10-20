#!/usr/bin/env sh
#
# The CodeQL findings gate. Reads SARIF reports, drops every result one of whose
# `partialFingerprints` values is listed in the project's `.codeql-false-positives`, prints what
# remains, and exits 1 when anything does.
#
#   gate.sh <report.sarif | directory of *.sarif> [...]
#
# It is the ONE place that decides whether a CodeQL scan passes, on every platform:
#
#   * `run.sh` calls it after a local `make codeql`, a GitLab CI or an Azure DevOps analysis;
#   * the GitHub Actions `20-security/codeql` composite calls it on the SARIF that
#     `github/codeql-action/analyze` wrote, because that action fails only when the analysis
#     itself fails -- never on a finding. Before this gate ran there, a repository that could not
#     upload its results (code scanning needs GitHub Advanced Security on a private one) passed
#     the job whatever CodeQL found, since nothing else read the report.
#
# The project's `.codeql-false-positives` is read from the working directory; without one, the
# default beside this script applies, and nothing is written into the project either way. Each
# remaining finding is listed with its `primaryLocationLineHash`, so the value a triaged finding
# needs in that file can be read from the job log, where no SARIF may have been published.
#
# It fails closed: a report that is missing, unreadable or not SARIF is an error, never "no
# findings" -- a gate that passes because it could not look is the failure it exists to prevent.

GATE_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1

if [ "$#" -eq 0 ]; then
  echo "Usage: gate.sh <report.sarif | directory of *.sarif> [...]" >&2
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: the CodeQL gate needs 'jq' to read the SARIF report, and it is not installed." >&2
  exit 1
fi

# Expand every argument into report files: a directory stands for the `*.sarif` files directly in
# it, which is how `github/codeql-action/analyze` writes one report per language. The list is
# rebuilt into the positional parameters, so a path with spaces survives.
for argument in "$@"; do
  shift
  if [ -d "$argument" ]; then
    found=false
    for report in "$argument"/*.sarif; do
      [ -f "$report" ] || continue
      set -- "$@" "$report"
      found=true
    done
    if [ "$found" = false ]; then
      echo "ERROR: no SARIF report (*.sarif) in $argument." >&2
      exit 1
    fi
  elif [ -f "$argument" ]; then
    set -- "$@" "$argument"
  else
    echo "ERROR: SARIF report not found: $argument" >&2
    exit 1
  fi
done

for report in "$@"; do
  if ! jq -e 'type == "object" and (.runs | type == "array")' "$report" > /dev/null 2>&1; then
    echo "ERROR: $report is not a readable SARIF report." >&2
    exit 1
  fi
done

# Use the default false positives file if the project doesn't provide one
FP_FILE="$(pwd)/.codeql-false-positives"
if [ ! -f "$FP_FILE" ]; then
  FP_FILE="$GATE_DIR/.codeql-false-positives"
fi

# Load false positive fingerprints: one per line, whole lines only -- a trailing comment makes the
# line a different value, and so silences nothing.
FP_FILTER='[]'
if [ -f "$FP_FILE" ]; then
  FP_FILTER=$(grep -v '^\s*#' "$FP_FILE" | grep -v '^\s*$' | jq -R -s 'split("\n") | map(select(length > 0))')
fi
FP_COUNT=$(echo "$FP_FILTER" | jq 'length')
if [ "$FP_COUNT" -gt 0 ]; then
  echo "Loaded $FP_COUNT false positive fingerprint(s) from .codeql-false-positives"
fi

# A result is suppressed when ANY of its partialFingerprints values is listed.
# shellcheck disable=SC2016 # `$h` and `$fp` are jq variables, bound by `as` and `--argjson`
UNSUPPRESSED='select((.partialFingerprints // {} | to_entries | map(.value) | any(. as $h | $fp | any(. == $h))) | not)'

# Count results excluding false positives matched by SARIF partialFingerprints
TOTAL_COUNT=$(jq -s '[.[].runs[] | (.results // [])[]] | length' "$@")
RESULT_COUNT=$(jq -s --argjson fp "$FP_FILTER" "[.[].runs[] | (.results // [])[] | $UNSUPPRESSED] | length" "$@")
case "$TOTAL_COUNT$RESULT_COUNT" in
  '' | *[!0-9]*)
    echo "ERROR: could not count the findings in $*." >&2
    exit 1
    ;;
esac
SUPPRESSED=$((TOTAL_COUNT - RESULT_COUNT))

echo "CodeQL found $TOTAL_COUNT issue(s) total, $SUPPRESSED suppressed as false positive(s), $RESULT_COUNT remaining."
if [ "$RESULT_COUNT" -gt 0 ]; then
  jq -r -s --argjson fp "$FP_FILTER" \
    ".[].runs[] | (.results // [])[] | $UNSUPPRESSED"' | "  - \(.ruleId): \(.message.text) (\(.locations[0].physicalLocation.artifactLocation.uri):\(.locations[0].physicalLocation.region.startLine))"
      + (if .partialFingerprints.primaryLocationLineHash then "\n    fingerprint: \(.partialFingerprints.primaryLocationLineHash)" else "" end)' "$@"
  exit 1
fi

exit 0
