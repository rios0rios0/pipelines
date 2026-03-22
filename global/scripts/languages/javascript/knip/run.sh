#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="knip" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/knip.json"

echo "Running knip unused exports/files analysis..."
# Use npx to run knip without a global install; --reporter json produces machine-readable output
# knip exits non-zero when it finds unused files or exports
npx --yes knip --reporter json > "$fileName" 2>&1 || EXIT_CODE=$?

if [ "${EXIT_CODE:-0}" -ne 0 ]; then
  echo "knip found unused files/exports. See report at: $fileName"
else
  echo "No unused files or exports detected."
fi

echo "knip analysis complete. Results written to: $fileName"
exit "${EXIT_CODE:-0}"
