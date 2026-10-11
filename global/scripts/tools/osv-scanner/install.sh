#!/usr/bin/env sh

# Install OSV-Scanner at the pinned, checksum-verified version, as
# `$HOME/.local/bin/osv-scanner`.
#
# It is what scans a container image rebuild for the dependency-update checks:
# the image is exported straight from its registry and OSV-Scanner reads the OS
# packages and artifacts inside it, against the same OSV.dev database the pins
# themselves are checked against.
#
# The copy already there is reused only when its SHA-256 is the committed one --
# the release asset IS the binary, so the digest that verified the download
# also identifies the installed file. A version check would accept any build
# that prints the right number, and whatever else is earlier on PATH is never
# consulted: callers run this exact path, because a scanner that changed
# underneath would change the verdict on an unchanged image, and the earlier
# verdict could not be reproduced.

if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

OSV_SCANNER_BINARY="$HOME/.local/bin/osv-scanner"

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64 | Linux/amd64)  OSV_ARCH="amd64"; OSV_DIGEST_ARCH="AMD64" ;;
  Linux/aarch64 | Linux/arm64) OSV_ARCH="arm64"; OSV_DIGEST_ARCH="ARM64" ;;
  *)
    echo "ERROR: no OSV-Scanner digest is pinned for $(uname -s)/$(uname -m) -- only Linux amd64 and arm64." >&2
    echo "       Run with --scan-images=false to skip the image scan here, or pass --osv-scanner" >&2
    echo "       naming an OSV-Scanner $OSV_SCANNER_VERSION you installed and verified yourself." >&2
    exit 1
    ;;
esac

OSV_SHA256=$(pinned_digest OSV_SCANNER "$OSV_DIGEST_ARCH") || exit 1

if [ -f "$OSV_SCANNER_BINARY" ]; then
  if [ "$OSV_SHA256" = "SKIP" ]; then
    # A version overridden without a digest has nothing to compare bytes
    # against; `pinned_digest` has already said so, loudly.
    _osv_installed=$("$OSV_SCANNER_BINARY" --version 2> /dev/null | awk '/^osv-scanner version:/{print $3}')
    if [ "$_osv_installed" = "$OSV_SCANNER_VERSION" ]; then
      echo "OSV-Scanner $OSV_SCANNER_VERSION is already installed (unverified)."
      exit 0
    fi
  elif verify_sha256 "$OSV_SCANNER_BINARY" "$OSV_SHA256" 2> /dev/null; then
    echo "OSV-Scanner $OSV_SCANNER_VERSION is already installed."
    exit 0
  fi
fi

mkdir -p "$HOME/.local/bin"
# Downloaded beside its destination and renamed into place, so a concurrent job
# on the same self-hosted host never runs a half-written file, and two installs
# never write the same temporary file.
_osv_download_dir=$(mktemp -d "$HOME/.local/bin/.osv-scanner.XXXXXX") || exit 1
trap 'rm -rf "$_osv_download_dir"' EXIT
_osv_download="$_osv_download_dir/osv-scanner"

echo "Installing OSV-Scanner v$OSV_SCANNER_VERSION (linux/$OSV_ARCH)..."
if ! download_verified \
  "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_linux_$OSV_ARCH" \
  "$_osv_download" \
  "$OSV_SHA256"; then
  exit 1
fi
chmod 755 "$_osv_download"
mv "$_osv_download" "$OSV_SCANNER_BINARY"
