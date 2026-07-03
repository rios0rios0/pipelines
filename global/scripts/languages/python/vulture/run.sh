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
  python -m pip install --user vulture --quiet
else
  # Already present (persistent agent): self-update so long-lived hosts stay
  # current for CVE fixes instead of pinning whatever was first installed. pip
  # only downloads when a newer release exists, so this is a no-op otherwise.
  echo "Updating vulture..."
  python -m pip install --user --upgrade vulture --quiet
fi

# Include a project-level whitelist if present to suppress known false positives
whitelistArgs=""
if [ -f ".vulture-whitelist.py" ]; then
  whitelistArgs=".vulture-whitelist.py"
fi

echo "Running vulture unused code analysis..."
# shellcheck disable=SC2086
python -m vulture . $whitelistArgs --min-confidence 80 --exclude .venv > "$fileName" 2>&1 || EXIT_CODE=$?

echo "vulture analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
