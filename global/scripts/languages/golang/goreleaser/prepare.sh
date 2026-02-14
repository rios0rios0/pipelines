#!/usr/bin/env bash
set -euo pipefail

BINARY_NAME="${1:?Binary name is required as the first argument}"
BINARY_PATH="${2:-.}" # Optional, defaults to "."

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
fi

TEMPLATE="$SCRIPTS_DIR/global/scripts/languages/golang/goreleaser/.goreleaser.yaml"

# Step 1: Check if project already has a goreleaser config
if [ -f ".goreleaser.yaml" ] || [ -f ".goreleaser.yml" ]; then
  echo "Project has its own .goreleaser config, using it as-is."
  exit 0
fi

# Step 2: Auto-detect binary path if not provided or set to default
if [ "$BINARY_PATH" = "." ]; then
  DETECTED=$(grep -rl "^func main()" --include="*.go" . 2>/dev/null | head -1 || true)
  if [ -n "$DETECTED" ]; then
    BINARY_PATH="./$(dirname "$DETECTED")"
    echo "Auto-detected main package at: $BINARY_PATH"
  else
    echo "Warning: Could not detect main package, using root (.)"
    BINARY_PATH="."
  fi
fi

# Step 3: Copy template and replace placeholders
cp "$TEMPLATE" .goreleaser.yaml
sed -i "s|__BINARY_NAME__|$BINARY_NAME|g" .goreleaser.yaml
sed -i "s|__BINARY_PATH__|$BINARY_PATH|g" .goreleaser.yaml

# Step 4: Exclude generated file from git
mkdir -p .git/info
echo '.goreleaser.yaml' >> .git/info/exclude

echo "Generated .goreleaser.yaml for '$BINARY_NAME' (main: $BINARY_PATH)"
