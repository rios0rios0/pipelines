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

# SARIF is produced via `trivy convert`. Trivy's SARIF writer panics with
# a nil-URL `SIGSEGV` in `pkg/report/sarif.go:103` when a Terraform
# `source` pin references an SSH remote like `git@host:path/repo?ref=x`
# because Go's `net/url` rejects the colon in the first path segment and
# `SarifWriter.addSarifResult` dereferences the nil result. To sidestep
# the panic, every `git@host:path` string in `trivy.json` is rewritten to
# the equivalent valid RFC 3986 URL `ssh://git@host/path` before
# conversion. `jq`'s `walk` traverses the full JSON tree so finding
# locations, artifact paths, and any other embedded URI reference are all
# normalized in one pass. The fallback `|| echo` is kept as a safety net
# for unrelated convert failures.
echo "Sanitizing SSH-style module URIs in Trivy JSON before SARIF conversion..."
jq 'walk(if type == "string" and test("^git@[^:]+:") then sub("^git@(?<h>[^:]+):(?<p>.+)$"; "ssh://git@\(.h)/\(.p)") else . end)' \
  "$jsonFile" > "$jsonFile.sanitized" && mv "$jsonFile.sanitized" "$jsonFile"

echo "Converting Trivy JSON report to SARIF..."
trivy convert \
  --format sarif \
  --output "$sarifFile" \
  "$jsonFile" || echo "SARIF conversion failed; trivy.json is authoritative."

if [ "$ignoreFileExists" = false ]; then
  rm -f .trivyignore
fi

echo "Trivy analysis complete. Results written to: $jsonFile (and $sarifFile when convertible)."
exit ${EXIT_CODE:-0}
