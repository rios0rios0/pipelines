#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="vulture" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/vulture.txt"

# Install vulture if not already available
if ! command -v vulture > /dev/null 2>&1; then
  echo "Installing vulture..."
  pip install vulture --quiet
fi

echo "Running vulture unused code analysis..."
# Include a project-level whitelist if present to suppress known false positives
whitelistArgs=""
if [ -f ".vulture-whitelist.py" ]; then
  whitelistArgs=".vulture-whitelist.py"
fi

# Minimum confidence of 80% reduces false positives from dynamic attribute access
# shellcheck disable=SC2086
vulture . $whitelistArgs --min-confidence 80 > "$fileName" 2>&1 || EXIT_CODE=$?

if [ -s "$fileName" ]; then
  echo "vulture found unused code. See report at: $fileName"
  cat "$fileName"
  EXIT_CODE=${EXIT_CODE:-1}
else
  echo "No unused code detected."
  echo "OK" > "$fileName"
fi

echo "vulture analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
