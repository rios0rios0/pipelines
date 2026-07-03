#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="trivy-sca" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/trivy-sca.json"

# Install Trivy if not already available.
#
# The upstream `install.sh` resolves the `latest` Trivy release by
# calling GitHub's releases API. That call is rate-limited and
# occasionally returns an empty body (logged by the helper as
# `aquasecurity/trivy crit unable to find ''`), in which case the
# installer aborts WITHOUT dropping the binary on disk. The subsequent
# `trivy ...` invocations below would then exit `127` (`trivy: not
# found`) with no clear pointer back to the install step. Retry up to
# 3 times with linear backoff and verify the binary actually landed
# before continuing -- if the install never succeeds, fail loudly.
# Self-update an already-installed Trivy on persistent agents so long-lived
# hosts stay current for CVE fixes. Resolves the latest tag via the
# `releases/latest` redirect (not API-rate-limited). Fail-safe: any uncertainty
# (lookup blip or unparseable version) returns "no update", so it never forces a
# needless re-download or breaks the run.
trivy_update_available() {
  _tv_latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/aquasecurity/trivy/releases/latest 2>/dev/null | sed 's#.*/tag/v\{0,1\}##')
  _tv_current=$(trivy --version 2>/dev/null | awk '/^Version:/{print $2}')
  case "$_tv_latest" in [0-9]*.[0-9]*) ;; *) return 1 ;; esac
  case "$_tv_current" in [0-9]*.[0-9]*) ;; *) return 1 ;; esac
  [ "$_tv_latest" != "$_tv_current" ]
}

if ! command -v trivy > /dev/null 2>&1 || trivy_update_available; then
  echo "Downloading Trivy..."
  attempt=1
  maxAttempts=3
  installerLog="/tmp/trivy-install.log"
  installerStatus=0
  while [ $attempt -le $maxAttempts ]; do
    : > "$installerLog"
    installerStatus=0
    {
      curl -fsSL --show-error https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh 2>>"$installerLog" \
        | sh -s -- -b /tmp >>"$installerLog" 2>&1
    } || installerStatus=$?
    if [ -x /tmp/trivy ]; then
      break
    fi
    if [ $attempt -lt $maxAttempts ]; then
      sleepSeconds=$((attempt * 5))
      echo "Trivy install attempt $attempt failed (exit=$installerStatus, binary not at /tmp/trivy); retrying in ${sleepSeconds}s..." >&2
      [ -s "$installerLog" ] && sed 's/^/  | /' "$installerLog" >&2
      sleep $sleepSeconds
    fi
    attempt=$((attempt + 1))
  done
  # Last-resort fallback: the retry loop above installs the `latest`
  # Trivy, whose tag lookup can transiently fail (a rate-limited or empty
  # GitHub response makes upstream `install.sh` log `unable to find ''`
  # and drop no binary). Before failing the whole stage, try once more
  # against an explicit, known-good version so a flaky `latest` lookup
  # alone cannot red the pipeline. Override the pin via TRIVY_PINNED_VERSION
  # (any tag from https://github.com/aquasecurity/trivy/releases, e.g. v0.72.0).
  if [ ! -x /tmp/trivy ]; then
    : "${TRIVY_PINNED_VERSION:=v0.72.0}"
    echo "Trivy 'latest' install failed after $maxAttempts attempts; falling back to pinned $TRIVY_PINNED_VERSION..." >&2
    : > "$installerLog"
    installerStatus=0
    {
      curl -fsSL --show-error https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh 2>>"$installerLog" \
        | sh -s -- -b /tmp "$TRIVY_PINNED_VERSION" >>"$installerLog" 2>&1
    } || installerStatus=$?
  fi
  if [ ! -x /tmp/trivy ]; then
    echo "ERROR: Trivy install failed after $maxAttempts 'latest' attempts and a pinned ${TRIVY_PINNED_VERSION:-v0.72.0} fallback (last exit=$installerStatus). Common causes include a GitHub API rate limit on the 'latest' tag lookup, transient network failures, raw.githubusercontent.com being blocked, or upstream GitHub downtime. Last installer/curl output:" >&2
    [ -s "$installerLog" ] && sed 's/^/  | /' "$installerLog" >&2
    echo "Re-run the pipeline or pin a Trivy version explicitly." >&2
    rm -f "$installerLog"
    exit 1
  fi
  rm -f "$installerLog"
  # Move the downloaded binary into the user's ~/.local/bin (on PATH via the
  # shared preamble) so nothing is installed to a root-owned location.
  mv /tmp/trivy "$HOME/.local/bin/trivy"
fi

# Use default ignore file if the project doesn't provide one
ignoreFileExists=true
if [ ! -f ".trivyignore" ]; then
  ignoreFileExists=false
  defaultFile="$SCRIPTS_DIR/global/scripts/tools/trivy/.trivyignore"
  if [ -f "$defaultFile" ]; then
    cp "$defaultFile" .
  fi
fi

echo "Running Trivy SCA dependency vulnerability scan..."

# Trivy's language analyzers (notably Maven/`pom.xml`) resolve parent POMs and
# BOM-managed versions from the remote registry to build the full dependency
# tree. On shared CI runners Maven Central frequently rate-limits anonymous
# requests with HTTP 429 (`Retry-After: 1800`), which makes Trivy abort with a
# FATAL error and write no report -- failing the job for an infrastructure
# reason rather than a real finding. When the online scan produces no report
# because a remote repository was unreachable, retry once with `--offline-scan`
# so the scan still completes against locally resolvable dependencies. Full
# (online) coverage is preserved whenever the registry is reachable, and the
# dedicated OWASP dependency-check job provides authoritative deep SCA anyway.
trivyLog="/tmp/trivy-sca-run.log"
EXIT_CODE=0
trivy filesystem \
  --scanners vuln \
  --format json \
  --output "$fileName" \
  --exit-code 1 \
  "$(pwd)" > "$trivyLog" 2>&1 || EXIT_CODE=$?
cat "$trivyLog"

if [ ! -f "$fileName" ] && grep -qiE "remote Maven repository returned|Too Many Requests|429" "$trivyLog"; then
  echo "Trivy could not reach the remote Maven repository (rate-limited); retrying with --offline-scan..."
  EXIT_CODE=0
  trivy filesystem \
    --scanners vuln \
    --offline-scan \
    --format json \
    --output "$fileName" \
    --exit-code 1 \
    "$(pwd)" > "$trivyLog" 2>&1 || EXIT_CODE=$?
  cat "$trivyLog"
fi
rm -f "$trivyLog"

if [ "$ignoreFileExists" = false ]; then
  rm -f .trivyignore
fi

echo "Trivy SCA analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
