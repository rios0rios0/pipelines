#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="trivy" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

jsonFile="$(pwd)/$REPORT_PATH/trivy.json"
sarifFile="$(pwd)/$REPORT_PATH/trivy.sarif"

# Install Trivy if not already available
if ! command -v trivy > /dev/null 2>&1; then
  echo "Downloading Trivy..."
  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /tmp
  export PATH="/tmp:$PATH"
fi

# Use default ignore file if the project doesn't provide one
ignoreFileExists=true
if [ ! -f ".trivyignore" ]; then
  ignoreFileExists=false
  defaultFile="$SCRIPTS_DIR/global/scripts/tools/trivy/.trivyignore"
  cp "$defaultFile" .
fi

echo "Running Trivy IaC misconfiguration scan..."
# Primary output is JSON — always works and aligns with the other tool
# scripts (`trivy-sca.json`, `govulncheck.json`, `semgrep.json`, etc.).
trivy filesystem \
  --scanners misconfig \
  --format json \
  --output "$jsonFile" \
  --exit-code 1 \
  "$(pwd)" || EXIT_CODE=$?

# SARIF is produced best-effort via `trivy convert` for consumers that
# publish to GitHub Code Scanning. Trivy's SARIF writer crashes with a
# nil-URL SIGSEGV in `pkg/report/sarif.go:103` when a Terraform `source`
# pin references an SSH remote like `git@host:path/repo?ref=x` (Go's
# `net/url` rejects the colon in the first path segment). Swallowing the
# convert failure keeps the job green; consumers fall back to `trivy.json`
# when SARIF is missing.
echo "Converting Trivy JSON report to SARIF (best-effort)..."
trivy convert \
  --format sarif \
  --output "$sarifFile" \
  "$jsonFile" || echo "SARIF conversion failed; trivy.json is authoritative."

if [ "$ignoreFileExists" = false ]; then
  rm -f .trivyignore
fi

echo "Trivy analysis complete. Results written to: $jsonFile (and $sarifFile when convertible)."
exit ${EXIT_CODE:-0}
