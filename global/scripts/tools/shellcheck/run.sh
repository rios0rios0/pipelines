#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="shellcheck" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/shellcheck.json"

# Find all shell scripts in the project
SCRIPT_LIST=$(find "$(pwd)" -name "*.sh" \
  -not -path "*/.git/*" \
  -not -path "*/node_modules/*" \
  -not -path "*/vendor/*" \
  -not -path "*/.codeql-db/*")

if [ -z "$SCRIPT_LIST" ]; then
  echo "No shell scripts found, skipping ShellCheck analysis."
  echo "[]" > "$fileName"
  echo "Empty report written to: $fileName"
  exit 0
fi

# Install ShellCheck if not already available.
#
# The version is PINNED and the archive is CHECKSUM-VERIFIED. This previously
# resolved `releases/latest` at run time and unpacked the result unverified,
# which made the linting standard applied to a commit depend on the day it ran:
# a new ShellCheck release adds checks, so an unchanged script could pass in the
# morning and fail in the afternoon with nothing in the diff to explain it.
# ShellCheck publishes no checksum manifest, so the digests in
# `pinned-versions.sh` were computed from the published artifacts.
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

shellcheck_matches_pin() {
  _sc_current=$(shellcheck --version 2>/dev/null | awk '/^version:/{print $2}')
  [ "$_sc_current" = "$SHELLCHECK_VERSION" ]
}

if ! command -v shellcheck > /dev/null 2>&1 || ! shellcheck_matches_pin; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  ARCH="x86_64";  SHELLCHECK_DIGEST_ARCH="X86_64" ;;
    aarch64) ARCH="aarch64"; SHELLCHECK_DIGEST_ARCH="AARCH64" ;;
    armv6l)  ARCH="armv6hf"; SHELLCHECK_DIGEST_ARCH="ARMV6HF" ;;
    *)
      echo "Unsupported architecture: $ARCH" >&2
      exit 1
      ;;
  esac

  SHELLCHECK_SHA256=$(pinned_digest SHELLCHECK "$SHELLCHECK_DIGEST_ARCH") || exit 1

  # The release asset and the directory inside it both carry a leading `v`,
  # which the pinned version deliberately does not -- so it is added here once
  # rather than being carried through every comparison above.
  echo "Installing ShellCheck v$SHELLCHECK_VERSION (linux/$ARCH)..."
  if ! download_verified \
    "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.$ARCH.tar.xz" \
    /tmp/shellcheck.tar.xz \
    "$SHELLCHECK_SHA256"; then
    exit 1
  fi

  if ! tar -xJf /tmp/shellcheck.tar.xz -C /tmp; then
    echo "ERROR: failed to extract ShellCheck from /tmp/shellcheck.tar.xz." >&2
    rm -f /tmp/shellcheck.tar.xz
    exit 1
  fi
  mv "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /tmp/shellcheck
  chmod +x /tmp/shellcheck
  rm -rf /tmp/shellcheck.tar.xz "/tmp/shellcheck-v${SHELLCHECK_VERSION}"
  # Move the downloaded binary into the user's ~/.local/bin (on PATH via the
  # shared preamble) so nothing is installed to a root-owned location.
  mv /tmp/shellcheck "$HOME/.local/bin/shellcheck"
fi

echo "Running ShellCheck analysis..."
echo "Checking scripts:"
echo "$SCRIPT_LIST" | while read -r f; do echo "  - $f"; done

find "$(pwd)" -name "*.sh" \
  -not -path "*/.git/*" \
  -not -path "*/node_modules/*" \
  -not -path "*/vendor/*" \
  -not -path "*/.codeql-db/*" \
  -print0 | xargs -0 shellcheck --format=json1 --severity=warning > "$fileName" || EXIT_CODE=$?

echo "ShellCheck analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
