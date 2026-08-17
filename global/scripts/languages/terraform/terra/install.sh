#!/usr/bin/env sh

# Install the terra CLI (https://github.com/rios0rios0/terra) at a pinned,
# checksum-verified version.
#
# Every platform previously ran the vendor's one-liner:
#
#   curl -fsSL https://raw.githubusercontent.com/rios0rios0/terra/main/install.sh | sh
#
# terra being first-party changes nothing about that shape. The script came
# from the `main` BRANCH, so any commit pushed there executed on every
# consumer's runner on their next pipeline -- no release, no tag, no review gate
# between a push and arbitrary code running with the job's cloud credentials in
# scope. A first-party repository is a smaller blast radius than a stranger's,
# not a different mechanism, and it is the mechanism this change is about.
#
# The release tarball is downloaded and verified against a committed digest
# instead. `terra install` still resolves Terraform and Terragrunt afterwards --
# that is terra's own job and unchanged here.

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

terra_matches_pin() {
  _tr_current=$(terra version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ "$_tr_current" = "$TERRA_VERSION" ]
}

if command -v terra > /dev/null 2>&1 && terra_matches_pin; then
  echo "terra $TERRA_VERSION is already installed."
  exit 0
fi

case "$(uname -m)" in
  x86_64)        TERRA_ARCH="amd64"; TERRA_DIGEST_ARCH="AMD64" ;;
  aarch64|arm64) TERRA_ARCH="arm64"; TERRA_DIGEST_ARCH="ARM64" ;;
  *)
    echo "ERROR: unsupported architecture for terra: $(uname -m)" >&2
    exit 1
    ;;
esac

TERRA_SHA256=$(pinned_digest TERRA "$TERRA_DIGEST_ARCH") || exit 1

echo "Installing terra $TERRA_VERSION (linux/$TERRA_ARCH)..."
if ! download_verified \
  "https://github.com/rios0rios0/terra/releases/download/${TERRA_VERSION}/terra-${TERRA_VERSION}-linux-${TERRA_ARCH}.tar.gz" \
  /tmp/terra.tar.gz \
  "$TERRA_SHA256"; then
  exit 1
fi

if ! tar -xzf /tmp/terra.tar.gz -C /tmp terra; then
  echo "ERROR: failed to extract terra from /tmp/terra.tar.gz." >&2
  rm -f /tmp/terra.tar.gz
  exit 1
fi
rm -f /tmp/terra.tar.gz
chmod +x /tmp/terra
mv /tmp/terra "$HOME/.local/bin/terra"

if ! terra version > /dev/null 2>&1; then
  echo "ERROR: the installed terra binary is not runnable on PATH." >&2
  exit 1
fi

echo "terra $TERRA_VERSION installed."
