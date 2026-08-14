#!/usr/bin/env sh
set -e

# `dart analyze` gate for the `10-code-check` stage -- the static analysis every
# Dart and Flutter project already runs in its editor, promoted to a CI gate
# with machine-readable reports.
#
# This job carries more weight in a Dart pipeline than its equivalent does
# elsewhere, because two of the tools this repository leans on for other
# languages have nothing to offer Dart:
#
#   - CodeQL has NO Dart extractor (dart-lang/sdk#52953, open since 2023), so
#     the `sast:codeql` job is absent from every Dart template.
#   - The Semgrep registry publishes no Dart rules at all: `p/dart` is a 404 and
#     `r/dart` returns a literally empty `rules: []`. Semgrep still runs for its
#     language-agnostic packs (secrets, Dockerfile, OWASP) plus the Dart rules
#     this repository ships itself at
#     `global/scripts/tools/semgrep/rules/dart.yaml`.
#
# The Dart analyzer is therefore the primary source of language-level
# correctness findings, which is why its severity gate is configurable rather
# than fixed -- see `dart_analyze_report.py` for `DART_FATAL_WARNINGS` /
# `DART_FATAL_INFOS`.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/languages/dart/common.sh"

TARGETS="$*"
[ -n "$TARGETS" ] || TARGETS="."

dart_prepare_reports "dart-analyze"
dart_ensure_sdk
dart_pub_get

# A project with no `analysis_options.yaml` gets the SDK's bare defaults, which
# enable almost no lints -- the job would pass while checking nothing. Say so
# once, loudly, instead of reporting a clean run that means nothing.
if [ ! -f "analysis_options.yaml" ]; then
  echo "WARNING: no 'analysis_options.yaml' found. The analyzer is running with SDK defaults," >&2
  echo "         which enable very few lints. Add one that includes package:lints/recommended.yaml" >&2
  echo "         (or package:flutter_lints/flutter.yaml for Flutter) to get real coverage." >&2
fi

echo "Running 'dart analyze' over: $TARGETS"

if dart_is_dry_run; then
  # shellcheck disable=SC2086
  dart_run dart analyze --format=machine $TARGETS
  echo "DRY RUN: no analysis was performed and no report was written."
  exit 0
fi

ANALYZE_OUT="$(mktemp)"
ANALYZE_ERR="$(mktemp)"
cleanup_tmp() { rm -f "$ANALYZE_OUT" "$ANALYZE_ERR"; }
trap cleanup_tmp EXIT

# The analyzer's own exit code is deliberately ignored here and the verdict is
# recomputed from the parsed diagnostics instead. Two reasons: `dart analyze`
# maps severities onto exit codes in a way that has changed across SDK releases,
# and this pipeline's gate is configurable (a repository may accept INFO-level
# lints while it adopts a stricter set), so the tool's own all-or-nothing
# verdict is the wrong one to propagate.
ANALYZE_STATUS=0
# shellcheck disable=SC2086
dart analyze --format=machine $TARGETS > "$ANALYZE_OUT" 2> "$ANALYZE_ERR" || ANALYZE_STATUS=$?

# Distinguish "the analyzer ran and found problems" from "the analyzer could not
# run". The second case produces a non-zero status and NO parseable diagnostic
# rows, and treating it as a clean result is the quiet failure this guard
# exists to prevent: an unresolved package or a broken SDK would otherwise be
# published as a green analysis with an empty report.
if [ "$ANALYZE_STATUS" -ne 0 ] && ! grep -qE '^(INFO|WARNING|ERROR)\|' "$ANALYZE_OUT"; then
  echo "ERROR: 'dart analyze' failed to run (exit $ANALYZE_STATUS) and produced no diagnostics." >&2
  cat "$ANALYZE_ERR" >&2
  exit "$ANALYZE_STATUS"
fi

[ -s "$ANALYZE_ERR" ] && cat "$ANALYZE_ERR" >&2

REPORT_EXIT=0
python3 "$SCRIPTS_DIR/global/scripts/languages/dart/analyze/dart_analyze_report.py" "$DART_TOOL_REPORT_PATH" \
  < "$ANALYZE_OUT" || REPORT_EXIT=$?

echo ""
echo "Reports written to: $DART_TOOL_REPORT_PATH"
exit "$REPORT_EXIT"
