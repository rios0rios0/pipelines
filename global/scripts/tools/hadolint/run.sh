#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="hadolint" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/hadolint.sarif"

# Find all Dockerfiles in the project
DOCKERFILES=$(find "$(pwd)" -name "Dockerfile*" \
  -not -path "*/.git/*" \
  -not -path "*/node_modules/*" \
  -not -path "*/vendor/*" \
  -not -path "*/.codeql-db/*")

if [ -z "$DOCKERFILES" ]; then
  echo "No Dockerfiles found, skipping Hadolint analysis."
  cat > "$fileName" <<'EOF'
{
  "version": "2.1.0",
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
  "runs": [
    {
      "tool": {
        "driver": {
          "name": "Hadolint",
          "informationUri": "https://github.com/hadolint/hadolint",
          "rules": []
        }
      },
      "results": []
    }
  ]
}
EOF
  echo "Empty report written to: $fileName"
  exit 0
fi

# Install Hadolint if not already available.
#
# Hadolint ships a self-contained binary on every GitHub release, so it is
# downloaded directly rather than pulled as a Docker image -- Docker Hub's
# anonymous pull rate limit would otherwise risk a `toomanyrequests` failure on
# a cache-cold runner.
#
# The version is PINNED and the binary is CHECKSUM-VERIFIED, which replaces a
# whole apparatus of retries, backoff and fallbacks built around resolving
# `releases/latest` at run time. That apparatus was load-bearing precisely
# because the lookup was unreliable: rate-limited at 60 requests/hour per IP,
# intermittently 403 from shared runner egress, and fatal when it returned
# empty. None of it is needed against a fixed URL.
#
# It was also, by then, hiding a real failure. Hadolint v2.15.1 renamed its
# assets from `hadolint-Linux-x86_64` to `hadolint-linux-x86_64` (lower-case
# "l"). The resolver kept returning the new version, the download kept 404ing
# on the old capitalised name, and the fallback kept quietly installing
# v2.14.0 -- so the "always current for CVE fixes" behaviour had silently
# stopped being true, and the retry logic made it look like a flaky network
# rather than a broken URL. Pinning fixes the version and the asset name in the
# same place.
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"

hadolint_matches_pin() {
  _hl_current=$(hadolint --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//')
  [ "$_hl_current" = "$HADOLINT_VERSION" ]
}

if ! command -v hadolint > /dev/null 2>&1 || ! hadolint_matches_pin; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)        HADOLINT_ARCH="x86_64"; HADOLINT_DIGEST_ARCH="X86_64" ;;
    aarch64|arm64) HADOLINT_ARCH="arm64";  HADOLINT_DIGEST_ARCH="ARM64" ;;
    *)
      echo "ERROR: unsupported architecture for Hadolint: $ARCH" >&2
      exit 1
      ;;
  esac

  HADOLINT_SHA256=$(pinned_digest HADOLINT "$HADOLINT_DIGEST_ARCH") || exit 1

  echo "Installing Hadolint v$HADOLINT_VERSION (linux/$HADOLINT_ARCH)..."
  if ! download_verified \
    "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-$HADOLINT_ARCH" \
    /tmp/hadolint \
    "$HADOLINT_SHA256"; then
    exit 1
  fi

  chmod +x /tmp/hadolint
  # Prove the binary actually runs before it is installed. A verified download
  # cannot be corrupt, but it can still be the wrong architecture for this
  # host -- which surfaces as `Exec format error`, and is far clearer here than
  # as exit 127 at the lint call below.
  if ! /tmp/hadolint --version > /dev/null 2>&1; then
    echo "ERROR: the downloaded Hadolint binary does not run on this host (architecture mismatch?)." >&2
    rm -f /tmp/hadolint
    exit 1
  fi

  # Move the downloaded binary into the user's ~/.local/bin (on PATH via the
  # shared preamble) so nothing is installed to a root-owned location.
  mv /tmp/hadolint "$HOME/.local/bin/hadolint"
fi

# Defense in depth: refuse to proceed unless `hadolint` is genuinely runnable
# -- whether freshly downloaded above or assumed preinstalled -- instead of
# falling through to an opaque `hadolint: not found` (exit 127) at the lint
# call below.
if ! hadolint --version > /dev/null 2>&1; then
  echo "ERROR: 'hadolint' is not runnable on PATH; aborting before lint." >&2
  exit 1
fi

# Use default config if the project doesn't provide one
configFileExists=true
if [ ! -f ".hadolint.yaml" ]; then
  configFileExists=false
  defaultFile="$SCRIPTS_DIR/global/scripts/tools/hadolint/.hadolint.yaml"
  cp "$defaultFile" .
fi

echo "Running Hadolint analysis..."
echo "Linting Dockerfiles:"
echo "$DOCKERFILES" | while read -r f; do echo "  - $f"; done

# shellcheck disable=SC2086
hadolint --format sarif $DOCKERFILES > "$fileName" || EXIT_CODE=$?

if [ "$configFileExists" = false ]; then
  rm -f .hadolint.yaml
fi

echo "Hadolint analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
