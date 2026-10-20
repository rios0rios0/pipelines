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

# REBUILT when stale, not merely when absent.
#
# `go install` builds this tool from source, so the binary carries the Go
# toolchain it was compiled with. Testing only for the file's existence meant a
# binary cached by an earlier run was reused forever -- including after the
# runner's Go moved on. govulncheck loads the standard library with the
# source-processing packages of the Go it was BUILT with, so a binary built with
# an older Go cannot parse the newer standard library and dies before analysing
# anything: "Loading packages failed, possibly due to a mismatch between the Go
# version used to build govulncheck and the Go version on PATH". That surfaces
# as a failed scan with zero findings, which reads like a broken pipeline rather
# than what it is.
#
# The same check also makes the pin real: a leftover binary of a DIFFERENT
# govulncheck version used to satisfy the existence test, so the pinned version
# was never installed.
#
# `go version -m` reports both facts without running the tool: the first line
# ends with the Go version that built it, and the `mod` line carries the module
# version.
govulncheckNeedsInstall=1
if [ -f "$GOVULNCHECK_BIN" ]; then
  govulncheckBuildInfo="$(go version -m "$GOVULNCHECK_BIN" 2>/dev/null)"
  govulncheckBuiltWith="$(echo "$govulncheckBuildInfo" | awk 'NR == 1 { print $2 }')"
  govulncheckBuiltVersion="$(echo "$govulncheckBuildInfo" | awk '$1 == "mod" && $2 == "golang.org/x/vuln" { print $3 }')"
  if [ "$govulncheckBuiltWith" = "$(go env GOVERSION)" ] &&
    [ "$govulncheckBuiltVersion" = "$GOVULNCHECK_VERSION" ]; then
    govulncheckNeedsInstall=0
  else
    echo "Cached govulncheck is stale (built with ${govulncheckBuiltWith:-unknown}" \
      "at version ${govulncheckBuiltVersion:-unknown}; want $(go env GOVERSION)" \
      "at $GOVULNCHECK_VERSION) -- reinstalling."
  fi
fi
if [ "$govulncheckNeedsInstall" -eq 1 ]; then
  echo "Installing govulncheck $GOVULNCHECK_VERSION with $(go env GOVERSION)..."
  go install "golang.org/x/vuln/cmd/govulncheck@$GOVULNCHECK_VERSION"
fi

echo "Running govulncheck SCA vulnerability scan..."
# Only stdout is the report. govulncheck writes its JSON there and everything
# else on stderr, so folding stderr in with `2>&1` could leave a report that
# neither `-mode convert` below nor anyone reading the artifact can parse.
scanErrors="$(mktemp)"
"$GOVULNCHECK_BIN" -json ./... > "$fileName" 2> "$scanErrors" || EXIT_CODE=$?

echo "govulncheck analysis complete. Results written to: $fileName"

# Whatever the scan said on stderr reaches the log, bounded. A scan that could
# not run at all fails here, with its own reason in the log rather than only in
# the artifact: "exited with code 1" alone does not say whether anything was
# found or nothing was analysed.
if [ -s "$scanErrors" ]; then
  echo "govulncheck error output:"
  head -n 40 "$scanErrors"
fi
rm -f "$scanErrors"
if [ -n "$EXIT_CODE" ]; then
  echo "govulncheck exited with code $EXIT_CODE. First lines of the report:"
  head -n 40 "$fileName"
  exit "$EXIT_CODE"
fi

# THE VERDICT comes from the report, never from the exit code of the `-json`
# run: with `-json` (or `-format`) govulncheck exits 0 whatever it found, so
# while this script passed that code on, the job passed every vulnerability
# although the pipelines document it as blocking. `-mode convert` replays the
# report through govulncheck's own text output without scanning again -- which
# also prints the findings into the log -- and exits 3 when the code calls a
# vulnerable symbol. A vulnerability in a package the code imports, or a module
# it requires, without the vulnerable symbol being reached is listed but does
# not fail the job: that is govulncheck's own default.
VERDICT=0
"$GOVULNCHECK_BIN" -mode convert < "$fileName" || VERDICT=$?
case "$VERDICT" in
  0) echo "govulncheck: this code reaches no known vulnerability." ;;
  3) echo "govulncheck: this code calls a known-vulnerable symbol (listed above); upgrade the module to its fixed version." >&2 ;;
  *) echo "govulncheck: could not read its own report back (exit $VERDICT), so no verdict was reached." >&2 ;;
esac
exit "$VERDICT"
