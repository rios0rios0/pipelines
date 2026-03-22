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
# Use -test to include test functions as roots (supports both binaries and library projects)
"$DEADCODE_BIN" -test ./... > "$fileName" 2>&1 || EXIT_CODE=$?

if [ -s "$fileName" ]; then
  echo "deadcode found unreachable code. See report at: $fileName"
  cat "$fileName"
  EXIT_CODE=${EXIT_CODE:-1}
else
  echo "No unreachable code detected."
  echo "OK" > "$fileName"
fi

echo "deadcode analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
