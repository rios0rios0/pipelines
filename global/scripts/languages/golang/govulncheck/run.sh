#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="govulncheck" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"

fileName="$(pwd)/$REPORT_PATH/govulncheck.json"

# Install govulncheck if not already available.
#
# PINNED. `@latest` let the module proxy choose the version, so the scanner
# deciding whether this code is vulnerable changed without a diff -- and
# `go.sum` verification proved only that the bytes matched whatever version the
# proxy picked, which is integrity without identity.
GOVULNCHECK_BIN="$(go env GOPATH)/bin/govulncheck"
if [ ! -f "$GOVULNCHECK_BIN" ]; then
  echo "Installing govulncheck $GOVULNCHECK_VERSION..."
  go install "golang.org/x/vuln/cmd/govulncheck@$GOVULNCHECK_VERSION"
fi

echo "Running govulncheck SCA vulnerability scan..."
"$GOVULNCHECK_BIN" -json ./... > "$fileName" 2>&1 || EXIT_CODE=$?

echo "govulncheck analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
