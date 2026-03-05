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

# Install Hadolint if not already available
if ! command -v hadolint > /dev/null 2>&1; then
  echo "Downloading Hadolint..."
  HADOLINT_VERSION=$(curl -fsSL https://api.github.com/repos/hadolint/hadolint/releases/latest | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
  curl -fsSL "https://github.com/hadolint/hadolint/releases/download/$HADOLINT_VERSION/hadolint-Linux-x86_64" -o /tmp/hadolint
  chmod +x /tmp/hadolint
  export PATH="/tmp:$PATH"
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
