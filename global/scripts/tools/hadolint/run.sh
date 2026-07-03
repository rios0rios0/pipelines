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
# a cache-cold runner. The version is resolved from GitHub's `releases/latest`
# API for convenience, but that endpoint is rate-limited (60 req/hour per IP
# unauthenticated) and intermittently returns HTTP 5xx/403. Under POSIX `sh`
# (no `set -e`) an empty version used to flow straight into a malformed URL
# (".../download//hadolint-Linux-x86_64"), which 404s; the binary was never
# written and the failure surfaced only as a cryptic `hadolint: not found`
# (exit 127) at the lint call below. The install is now hardened: the lookup
# and the download are retried with backoff, the resolved version is validated
# non-empty (falling back to a pinned version otherwise), and the binary is
# verified to actually run before linting. Mirrors the Trivy install-retry
# idiom in `global/scripts/tools/trivy/run.sh`.
# Self-update an already-installed Hadolint on persistent agents so long-lived
# hosts stay current for CVE fixes. Resolves the latest tag via the
# `releases/latest` redirect (not API-rate-limited). Fail-safe: any uncertainty
# (lookup blip or unparseable version) returns "no update", so it never forces a
# needless re-download or breaks the run.
hadolint_update_available() {
  _hl_latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/hadolint/hadolint/releases/latest 2>/dev/null | sed 's#.*/tag/v\{0,1\}##')
  _hl_current=$(hadolint --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//')
  case "$_hl_latest" in [0-9]*.[0-9]*) ;; *) return 1 ;; esac
  case "$_hl_current" in [0-9]*.[0-9]*) ;; *) return 1 ;; esac
  [ "$_hl_latest" != "$_hl_current" ]
}

if ! command -v hadolint > /dev/null 2>&1 || hadolint_update_available; then
  echo "Downloading Hadolint..."

  # Known-good fallback used whenever the latest-version lookup cannot be
  # resolved. Overridable so an operator can pin a specific release without
  # editing this script when the API is unavailable.
  HADOLINT_PINNED_VERSION="${HADOLINT_PINNED_VERSION:-v2.14.0}"

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)        HADOLINT_ARCH="x86_64" ;;
    aarch64|arm64) HADOLINT_ARCH="arm64" ;;
    *)
      echo "ERROR: unsupported architecture for Hadolint: $ARCH" >&2
      exit 1
      ;;
  esac

  # Run a command up to 3 times with linear backoff (5s, then 10s) so a
  # transient 5xx/network blip is ridden out rather than being fatal. Progress
  # goes to stderr to keep stdout clean for command substitution.
  # POSIX `sh` has no `local`, so these temporaries are function-name-prefixed
  # to keep them from leaking into / colliding with the script scope.
  hadolint_retry() {
    _hadolint_retry_attempt=1
    _hadolint_retry_max=3
    while :; do
      if "$@"; then
        return 0
      fi
      if [ "$_hadolint_retry_attempt" -ge "$_hadolint_retry_max" ]; then
        return 1
      fi
      _hadolint_retry_wait=$((_hadolint_retry_attempt * 5))
      echo "  attempt $_hadolint_retry_attempt/$_hadolint_retry_max failed; retrying in ${_hadolint_retry_wait}s..." >&2
      sleep "$_hadolint_retry_wait"
      _hadolint_retry_attempt=$((_hadolint_retry_attempt + 1))
    done
  }

  # Resolve the latest published version. curl's exit status is checked
  # explicitly: a `curl | grep | sed` pipeline reports only sed's status, so a
  # failed curl (e.g. HTTP 504) would otherwise masquerade as success with
  # empty output. Returns non-zero -- engaging the retry, then the pinned
  # fallback -- when curl fails or no tag can be parsed.
  hadolint_latest_version() {
    _hadolint_latest_version_body=$(curl -fsSL https://api.github.com/repos/hadolint/hadolint/releases/latest) || return 1
    _hadolint_latest_version_tag=$(printf '%s\n' "$_hadolint_latest_version_body" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    [ -n "$_hadolint_latest_version_tag" ] || return 1
    printf '%s\n' "$_hadolint_latest_version_tag"
  }

  if HADOLINT_VERSION=$(hadolint_retry hadolint_latest_version) && [ -n "$HADOLINT_VERSION" ]; then
    echo "Resolved latest Hadolint version: $HADOLINT_VERSION"
  else
    HADOLINT_VERSION="$HADOLINT_PINNED_VERSION"
    echo "WARN: could not resolve the latest Hadolint version (GitHub rate limit, outage, or network failure); falling back to pinned $HADOLINT_VERSION." >&2
  fi

  # Ordered candidate list: the resolved version first, then the pinned
  # fallback as a last resort (skipped when identical). `set --` keeps the
  # iteration ShellCheck-clean without unquoted word-splitting.
  set -- "$HADOLINT_VERSION"
  if [ "$HADOLINT_VERSION" != "$HADOLINT_PINNED_VERSION" ]; then
    set -- "$@" "$HADOLINT_PINNED_VERSION"
  fi

  hadolint_installed=false
  for hadolint_candidate in "$@"; do
    echo "Installing Hadolint $hadolint_candidate (linux/$HADOLINT_ARCH)..."
    # Download with retries, make executable, then prove the binary actually
    # runs. Only a binary that answers `--version` is accepted; a 0-byte file
    # left by a 404 or a corrupt download fails here and the next candidate is
    # tried.
    if hadolint_retry curl -fsSL "https://github.com/hadolint/hadolint/releases/download/$hadolint_candidate/hadolint-Linux-$HADOLINT_ARCH" -o /tmp/hadolint \
      && chmod +x /tmp/hadolint \
      && /tmp/hadolint --version > /dev/null 2>&1; then
      hadolint_installed=true
      break
    fi
    echo "WARN: Hadolint $hadolint_candidate did not produce a runnable binary; trying the next source..." >&2
    rm -f /tmp/hadolint
  done

  if [ "$hadolint_installed" != true ]; then
    echo "ERROR: Hadolint could not be installed after trying the latest and pinned ($HADOLINT_PINNED_VERSION) versions." >&2
    echo "Likely a GitHub API rate limit on the 'latest' lookup, a transient network failure, or upstream GitHub downtime. Re-run the pipeline, or set HADOLINT_PINNED_VERSION to a known-good release." >&2
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
