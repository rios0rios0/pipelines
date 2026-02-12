#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi
. "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/trivy-sca.json"

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
