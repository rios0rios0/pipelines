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

# TFLint ships a zip, and `unzip` is absent from several CI images -- the
# `golang` image the GitLab CI terra jobs run on has neither `unzip` nor
# `bsdtar` nor BusyBox -- where its absence would surface as `unzip: not found`
# right after a successful download. The archive holds one member, `tflint`,
# deflated, which is the one shape GNU gzip decompresses too, checking its CRC;
# a second member makes gzip fail rather than drop it, so the last fallback
# cannot quietly install half of an archive. The checksum was verified above, so
# whichever tool runs only ever unpacks the pinned release.
unpack_tflint() {
  mkdir -p /tmp/tflint-extract || return 1
  if command -v unzip > /dev/null 2>&1; then
    unzip -oq /tmp/tflint.zip -d /tmp/tflint-extract
  elif command -v bsdtar > /dev/null 2>&1; then
    bsdtar -xf /tmp/tflint.zip -C /tmp/tflint-extract
  elif command -v busybox > /dev/null 2>&1 && busybox --list | grep -qx unzip; then
    busybox unzip -oq /tmp/tflint.zip -d /tmp/tflint-extract
  elif command -v gzip > /dev/null 2>&1; then
    gzip -dc < /tmp/tflint.zip > /tmp/tflint-extract/tflint
  else
    echo "ERROR: cannot unpack /tmp/tflint.zip -- none of 'unzip', 'bsdtar', 'busybox' or 'gzip' is available." >&2
    return 1
  fi
}

if ! unpack_tflint; then
  echo "ERROR: could not unpack /tmp/tflint.zip." >&2
  rm -rf /tmp/tflint.zip /tmp/tflint-extract
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
