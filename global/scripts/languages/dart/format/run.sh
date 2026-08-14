#!/usr/bin/env sh
set -e

# `dart format` gate for the `10-code-check` stage.
#
# Dart has exactly one formatter, it ships in the SDK, and its output is not
# configurable -- so unlike the Python stack (isort + black) or JavaScript
# (prettier + eslint) this is a single job with nothing to choose.
#
# Two modes:
#   check (default) -- `--output=none --set-exit-if-changed`, the CI gate
#   --fix           -- rewrite the files in place, for `make lint`
#
# `--set-exit-if-changed` is what makes the check meaningful. Plain `dart format
# --output=none` formats to nowhere and always exits 0, so a check written that
# way passes on every unformatted repository in existence.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/languages/dart/common.sh"

MODE="check"
TARGETS=""
for arg in "$@"; do
  case "$arg" in
    --fix) MODE="fix" ;;
    *) TARGETS="$TARGETS $arg" ;;
  esac
done

# `.` covers `lib/`, `test/`, `bin/`, `tool/` and `example/` in one pass, which
# is what a repository-wide gate should do. `dart format` already skips
# `.dart_tool/` and anything listed in `.gitignore`-style hidden directories.
if [ -z "$TARGETS" ]; then
  TARGETS="."
fi

dart_prepare_reports "dart-format"
dart_ensure_sdk

# shellcheck disable=SC2086
if [ "$MODE" = "fix" ]; then
  echo "Formatting Dart sources in place..."
  dart_run dart format $TARGETS
else
  echo "Checking Dart formatting..."
  EXIT_CODE=0
  # shellcheck disable=SC2086
  dart_run dart format --output=none --set-exit-if-changed $TARGETS || EXIT_CODE=$?
  if [ "$EXIT_CODE" -ne 0 ]; then
    echo "" >&2
    echo "ERROR: some files are not formatted. Run 'dart format .' (or 'make lint') and commit the result." >&2
    exit "$EXIT_CODE"
  fi
  echo "All Dart sources are correctly formatted."
fi
