#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="knip" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/knip.json"

echo "Running knip unused exports/files analysis..."
npx --yes knip --reporter json > "$fileName" 2>&1 || EXIT_CODE=$?

echo "knip analysis complete. Results written to: $fileName"
exit "${EXIT_CODE:-0}"
