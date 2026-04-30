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
if ! command -v trivy > /dev/null 2>&1; then
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
  if [ ! -x /tmp/trivy ]; then
    echo "ERROR: Trivy install failed after $maxAttempts attempts (last exit=$installerStatus). Common causes include a GitHub API rate limit on the 'latest' tag lookup, transient network failures, raw.githubusercontent.com being blocked, or upstream GitHub downtime. Last installer/curl output:" >&2
    [ -s "$installerLog" ] && sed 's/^/  | /' "$installerLog" >&2
    echo "Re-run the pipeline or pin a Trivy version explicitly." >&2
    rm -f "$installerLog"
    exit 1
  fi
  rm -f "$installerLog"
  export PATH="/tmp:$PATH"
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
trivy filesystem \
  --scanners vuln \
  --format json \
  --output "$fileName" \
  --exit-code 1 \
  "$(pwd)" || EXIT_CODE=$?

if [ "$ignoreFileExists" = false ]; then
  rm -f .trivyignore
fi

echo "Trivy SCA analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
