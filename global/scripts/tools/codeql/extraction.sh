#!/usr/bin/env sh
#
# Whether a CodeQL analysis read any code. Reads each SARIF report's
# `<language>/summary/lines-of-code` metric -- the lines of the language's code its database held,
# which the `security-and-quality` suite measures for every language that has the metric -- and
# fails a report that says 0.
#
#   extraction.sh [--strict] [--language <name>] <report.sarif | directory of *.sarif> [...]
#
# Why: `database create` refuses some databases that hold no code -- one with no file of a language
# CodeQL knows, a Go build that matched no package -- but not every one. A Go build whose packages
# all failed to load still extracts its go.mod (a go.work outside the checkout did exactly that),
# and a source file holding nothing but comments is extracted like any other. The database then
# held no line of code, every query ran over nothing, the report carried no finding, and the gate
# passed it: an empty result that read exactly like a clean one. The metric carries a `baseline`,
# the lines the CLI counted under the source root, which only says how much was there to read: the
# database's own counts (`codeql database print-baseline`, `baselineLinesOfCode`) come from the
# files on disk and read the same over an empty database as over a full one.
#
# Two callers, two policies:
#   * `run.sh` (`make codeql`, GitLab CI, Azure DevOps) passes --strict. It analyses only languages
#     that carry the metric (go, python, java, javascript, csharp), so a report without it, one it
#     cannot read, or no report at all fails too: then nothing says the analysis read anything.
#   * the GitHub Actions `20-security/codeql` composite, on what `github/codeql-action/analyze`
#     wrote, does not. A language without the metric -- `actions`, which this repository's own scan
#     analyses -- or a report the action did not write is a warning, never a failure, so the check
#     can only stop a job that analysed nothing. On GitHub Actions each warning and failure is an
#     annotation too, since nobody opens a passing job's log.
#
# --language names the language in the messages; without it a report is named by its file, which
# the action writes as `<language>.sarif`. The verdict is reached after every report is read: 1 when
# any said 0 (or, --strict, could not say), else 0.

STRICT=false
LANGUAGE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) STRICT=true ;;
    --language)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --language needs a value." >&2
        exit 1
      fi
      LANGUAGE="$2"
      shift
      ;;
    --) shift; break ;;
    -?*)
      echo "ERROR: unknown option '$1'. Usage: extraction.sh [--strict] [--language <name>] <report.sarif | directory of *.sarif> [...]" >&2
      exit 1
      ;;
    *) break ;;
  esac
  shift
done
if [ "$#" -eq 0 ]; then
  echo "Usage: extraction.sh [--strict] [--language <name>] <report.sarif | directory of *.sarif> [...]" >&2
  exit 1
fi

FAILED=false

# annotate <error|warning> <message>: the message as a GitHub Actions annotation, which the runner
# reads from stdout; anywhere else, nothing.
annotate() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::$1 title=CodeQL::$2"
  fi
}

# undecided <message>: the check could not tell whether the analysis read code. --strict, that fails
# it; otherwise it is a warning.
undecided() {
  if [ "$STRICT" = true ]; then
    echo "ERROR: $1" >&2
    annotate error "$1"
    FAILED=true
  else
    echo "WARNING: $1" >&2
    annotate warning "$1"
  fi
}

if ! command -v jq > /dev/null 2>&1; then
  undecided "telling how much code CodeQL extracted needs 'jq', and it is not installed."
  [ "$FAILED" = true ] && exit 1
  exit 0
fi

METRICS='[.runs[]?.properties.metricResults[]? | select((.ruleId // .rule.id // "") | type == "string" and endswith("/summary/lines-of-code"))]'

# check <report>: reads one report's metric and says what it found.
check() {
  label="${LANGUAGE:-$(basename "$1" .sarif)}"
  if ! jq -e 'type == "object" and (.runs | type == "array")' "$1" > /dev/null 2>&1; then
    undecided "$1 is not a readable SARIF report, so nothing says whether CodeQL read any code."
    return
  fi
  lines="$(jq -r "$METRICS"' | if length == 0 then "none" elif all(.value | type == "number") then [.[].value] | add else "unreadable" end' "$1" 2> /dev/null)" || lines=''
  case "$lines" in
    none)
      undecided "the CodeQL report carries no lines-of-code metric for '$label', so nothing says the analysis read any code: $1"
      ;;
    0)
      baseline="$(jq -r "$METRICS"' | [.[].baseline | numbers] | if length == 0 then "" else add end' "$1" 2> /dev/null)" || baseline=''
      case "$baseline" in
        '' | *[!0-9]*) counted='' ;;
        0) counted=", and none was counted under the source root either: is '$label' this project's language?" ;;
        *) counted=", of the $baseline counted under the source root" ;;
      esac
      echo "ERROR: CodeQL extracted no $label code: the database holds 0 lines of it$counted" >&2
      echo "Every query ran over nothing, so this scan cannot pass. What the extractor reported as errors:" >&2
      jq -r '[.runs[]?.invocations[]?.toolExecutionNotifications[]? | select(.level == "error") | .message.text // "" | split("\n")[0] | select(length > 0)] | unique
        | if length == 0 then "  (nothing)" else (.[:10][] | "  - " + .), (if length > 10 then "  ... and \(length - 10) more" else empty end) end' "$1" >&2
      echo "Every diagnostic CodeQL recorded is in $1, under runs[].invocations[].toolExecutionNotifications." >&2
      annotate error "CodeQL extracted no $label code, so every query ran over nothing; the job log lists what the extractor reported."
      FAILED=true
      ;;
    '' | *[!0-9]*)
      undecided "could not read how much code CodeQL extracted from $1."
      ;;
    *)
      echo "CodeQL extracted $lines line(s) of $label code."
      ;;
  esac
}

for argument in "$@"; do
  if [ -z "$argument" ]; then
    undecided "no SARIF report was named, so nothing says whether CodeQL read any code."
  elif [ -d "$argument" ]; then
    found=false
    for report in "$argument"/*.sarif; do
      [ -f "$report" ] || continue
      found=true
      check "$report"
    done
    if [ "$found" = false ]; then
      undecided "no SARIF report (*.sarif) in $argument, so nothing says whether CodeQL read any code."
    fi
  elif [ -f "$argument" ]; then
    check "$argument"
  else
    undecided "SARIF report not found: $argument"
  fi
done

[ "$FAILED" = true ] && exit 1
exit 0
