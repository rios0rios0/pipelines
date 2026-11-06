#!/usr/bin/env sh

# Install kubeconform at a pinned, checksum-verified version, for the Argo CD
# `schema` runner. A validator's version is part of its verdict, so the pin
# decides it, not whatever a runner happens to have.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*\)/global/scripts/.*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

mkdir -p "$HOME/.local/bin"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" && export PATH ;;
esac

kubeconform_matches_pin() {
  [ "$(kubeconform -v 2>/dev/null)" = "v$KUBECONFORM_VERSION" ]
}

if command -v kubeconform > /dev/null 2>&1 && kubeconform_matches_pin; then
  echo "kubeconform $KUBECONFORM_VERSION is already installed."
  exit 0
fi

case "$(uname -m)" in
  x86_64)        KUBECONFORM_ARCH="amd64"; KUBECONFORM_DIGEST_ARCH="AMD64" ;;
  aarch64|arm64) KUBECONFORM_ARCH="arm64"; KUBECONFORM_DIGEST_ARCH="ARM64" ;;
  *)
    echo "ERROR: unsupported architecture for kubeconform: $(uname -m)" >&2
    exit 1
    ;;
esac

KUBECONFORM_SHA256=$(pinned_digest KUBECONFORM "$KUBECONFORM_DIGEST_ARCH") || exit 1

# Downloaded and unpacked in a directory of this run's own, beside the
# destination, then renamed into place -- see `terraform/terra/install.sh`.
_kc_work=$(mktemp -d "$HOME/.local/bin/.kubeconform.XXXXXX") || exit 1
trap 'rm -rf "$_kc_work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Installing kubeconform $KUBECONFORM_VERSION (linux/$KUBECONFORM_ARCH)..."
if ! download_verified \
  "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-${KUBECONFORM_ARCH}.tar.gz" \
  "$_kc_work/kubeconform.tar.gz" \
  "$KUBECONFORM_SHA256"; then
  exit 1
fi

if ! tar -xzf "$_kc_work/kubeconform.tar.gz" -C "$_kc_work" kubeconform; then
  echo "ERROR: failed to extract kubeconform from the downloaded archive." >&2
  exit 1
fi
if ! chmod 755 "$_kc_work/kubeconform" || ! mv -f "$_kc_work/kubeconform" "$HOME/.local/bin/kubeconform"; then
  echo "ERROR: failed to put kubeconform in place at $HOME/.local/bin/kubeconform." >&2
  exit 1
fi

if ! kubeconform -v > /dev/null 2>&1; then
  echo "ERROR: the installed kubeconform binary is not runnable on PATH." >&2
  exit 1
fi

echo "kubeconform $KUBECONFORM_VERSION installed."
