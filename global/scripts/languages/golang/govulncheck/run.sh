#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="govulncheck" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/govulncheck.json"

# Install govulncheck if not already available
GOVULNCHECK_BIN="$(go env GOPATH)/bin/govulncheck"
if [ ! -f "$GOVULNCHECK_BIN" ]; then
  echo "Installing govulncheck..."
  go install golang.org/x/vuln/cmd/govulncheck@latest
fi

echo "Running govulncheck SCA vulnerability scan..."
"$GOVULNCHECK_BIN" -json ./... > "$fileName" 2>&1 || EXIT_CODE=$?

echo "govulncheck analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
