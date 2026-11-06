#!/usr/bin/env sh

# Install Helm at a pinned, checksum-verified version, for the Argo CD runners.
#
# `HelmInstaller@1` with `latest`, which is how the helm family gets its Helm,
# would hand this family a Helm no commit chose, so a chart could go red on a day
# nobody changed it. Runnable on its own, and the same copy runs on a developer's
# machine and in CI.

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

helm_matches_pin() {
  [ "$(helm version --template '{{.Version}}' 2>/dev/null)" = "v$HELM_VERSION" ]
}

if command -v helm > /dev/null 2>&1 && helm_matches_pin; then
  echo "Helm $HELM_VERSION is already installed."
  exit 0
fi

case "$(uname -m)" in
  x86_64)        HELM_ARCH="amd64"; HELM_DIGEST_ARCH="AMD64" ;;
  aarch64|arm64) HELM_ARCH="arm64"; HELM_DIGEST_ARCH="ARM64" ;;
  *)
    echo "ERROR: unsupported architecture for Helm: $(uname -m)" >&2
    exit 1
    ;;
esac

HELM_SHA256=$(pinned_digest HELM "$HELM_DIGEST_ARCH") || exit 1

# Downloaded and unpacked in a directory of this run's own, beside the
# destination, then renamed into place -- see `terraform/terra/install.sh`. The
# agents of a self-hosted machine share one `$HOME`, and `style:helm-lint` and
# `test:render` reach this script together.
_hm_work=$(mktemp -d "$HOME/.local/bin/.helm.XXXXXX") || exit 1
trap 'rm -rf "$_hm_work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Installing Helm $HELM_VERSION (linux/$HELM_ARCH)..."
if ! download_verified \
  "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${HELM_ARCH}.tar.gz" \
  "$_hm_work/helm.tar.gz" \
  "$HELM_SHA256"; then
  exit 1
fi

if ! tar -xzf "$_hm_work/helm.tar.gz" -C "$_hm_work" "linux-${HELM_ARCH}/helm"; then
  echo "ERROR: failed to extract Helm from the downloaded archive." >&2
  exit 1
fi
if ! chmod 755 "$_hm_work/linux-${HELM_ARCH}/helm" \
  || ! mv -f "$_hm_work/linux-${HELM_ARCH}/helm" "$HOME/.local/bin/helm"; then
  echo "ERROR: failed to put Helm in place at $HOME/.local/bin/helm." >&2
  exit 1
fi

if ! helm version > /dev/null 2>&1; then
  echo "ERROR: the installed Helm binary is not runnable on PATH." >&2
  exit 1
fi

echo "Helm $HELM_VERSION installed."
