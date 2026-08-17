#!/usr/bin/env sh

# Install TFLint at a pinned, checksum-verified version.
#
# Every platform previously installed TFLint the way upstream documents it:
#
#   curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
#
# That fetches a script from a BRANCH (`master`, so whatever was pushed most
# recently, by anyone with write access, with no release and no review gate)
# and executes it as the CI user -- who at that moment holds the repository
# token and, in the Terraform pipelines, frequently cloud credentials too.
# Nothing pinned the script, nothing verified it, and the binary it went on to
# fetch was equally unverified. It is the exact supply-chain shape this
# repository's own SAST stage exists to flag, which is why `flyctl` was moved
# off the same pattern earlier.
#
# The release archive is downloaded and verified directly instead, which
# removes the vendor's install script from the trust path entirely.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

mkdir -p "$HOME/.local/bin"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" && export PATH ;;
esac

tflint_matches_pin() {
  _tf_current=$(tflint --version 2>/dev/null | awk '/TFLint version/{print $3}')
  [ "$_tf_current" = "$TFLINT_VERSION" ]
}

if command -v tflint > /dev/null 2>&1 && tflint_matches_pin; then
  echo "TFLint $TFLINT_VERSION is already installed."
  exit 0
fi

case "$(uname -m)" in
  x86_64)        TFLINT_ARCH="amd64"; TFLINT_DIGEST_ARCH="AMD64" ;;
  aarch64|arm64) TFLINT_ARCH="arm64"; TFLINT_DIGEST_ARCH="ARM64" ;;
  *)
    echo "ERROR: unsupported architecture for TFLint: $(uname -m)" >&2
    exit 1
    ;;
esac

TFLINT_SHA256=$(pinned_digest TFLINT "$TFLINT_DIGEST_ARCH") || exit 1

echo "Installing TFLint v$TFLINT_VERSION (linux/$TFLINT_ARCH)..."
if ! download_verified \
  "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_${TFLINT_ARCH}.zip" \
  /tmp/tflint.zip \
  "$TFLINT_SHA256"; then
  exit 1
fi

# TFLint ships a zip and `unzip` is absent from several slim CI images
# (alpine, the python:*-slim family, some Azure containers), where its absence
# would surface as `unzip: not found` immediately after a successful download.
# Python's stdlib `zipfile` is the fallback, matching how the Dart SDK archive
# is unpacked in `languages/dart/common.sh`.
if command -v unzip > /dev/null 2>&1; then
  unzip -oq /tmp/tflint.zip -d /tmp/tflint-extract
elif command -v python3 > /dev/null 2>&1; then
  python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
    /tmp/tflint.zip /tmp/tflint-extract
else
  echo "ERROR: cannot unpack /tmp/tflint.zip -- neither 'unzip' nor 'python3' is available." >&2
  rm -f /tmp/tflint.zip
  exit 1
fi

mv /tmp/tflint-extract/tflint "$HOME/.local/bin/tflint"
chmod +x "$HOME/.local/bin/tflint"
rm -rf /tmp/tflint.zip /tmp/tflint-extract

if ! tflint --version > /dev/null 2>&1; then
  echo "ERROR: the installed TFLint binary is not runnable on PATH." >&2
  exit 1
fi

echo "TFLint $TFLINT_VERSION installed."
