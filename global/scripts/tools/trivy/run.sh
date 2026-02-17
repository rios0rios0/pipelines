#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi
TOOL_NAME="trivy" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/trivy.sarif"

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
trivy filesystem \
  --scanners misconfig \
  --format sarif \
  --output "$fileName" \
  --exit-code 1 \
  "$(pwd)" || EXIT_CODE=$?

if [ "$ignoreFileExists" = false ]; then
  rm -f .trivyignore
fi

echo "Trivy analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
