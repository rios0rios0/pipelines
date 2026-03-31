#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="deadcode" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/deadcode.txt"

# Install deadcode if not already available
DEADCODE_BIN="$(go env GOPATH)/bin/deadcode"
if [ ! -f "$DEADCODE_BIN" ]; then
  echo "Installing deadcode..."
  go install golang.org/x/tools/cmd/deadcode@latest
fi

echo "Running deadcode analysis..."
"$DEADCODE_BIN" -test ./... > "$fileName" 2>&1 || EXIT_CODE=$?

echo "deadcode analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
