#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="debride" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/debride.txt"

if ! command -v debride > /dev/null 2>&1; then
  echo "Installing debride..."
  gem install debride --no-document --quiet
fi

echo "Running debride unused code analysis..."
debride . > "$fileName" 2>&1 || EXIT_CODE=$?

echo "debride analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
