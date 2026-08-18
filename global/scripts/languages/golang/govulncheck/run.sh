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
# `go install` writes to `GOBIN` when that is set and only falls back to
# `GOPATH/bin`. Hard-coding `GOPATH/bin` meant that on a runner with `GOBIN`
# configured the install landed somewhere this script never looked -- so it
# either failed outright or silently kept using an older binary left in
# `GOPATH/bin`, which is the pin quietly not applying.
GOBIN_DIR="$(go env GOBIN)"
[ -n "$GOBIN_DIR" ] || GOBIN_DIR="$(go env GOPATH)/bin"
GOVULNCHECK_BIN="$GOBIN_DIR/govulncheck"
if [ ! -f "$GOVULNCHECK_BIN" ]; then
  echo "Installing govulncheck $GOVULNCHECK_VERSION..."
  go install "golang.org/x/vuln/cmd/govulncheck@$GOVULNCHECK_VERSION"
fi

echo "Running govulncheck SCA vulnerability scan..."
"$GOVULNCHECK_BIN" -json ./... > "$fileName" 2>&1 || EXIT_CODE=$?

echo "govulncheck analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
