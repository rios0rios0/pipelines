#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi
. "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/govulncheck.json"

# Install govulncheck if not already available
if ! command -v govulncheck > /dev/null 2>&1; then
  echo "Installing govulncheck..."
  go install golang.org/x/vuln/cmd/govulncheck@latest
fi

echo "Running govulncheck SCA vulnerability scan..."
govulncheck -json ./... > "$fileName" 2>&1 || EXIT_CODE=$?

echo "govulncheck analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
