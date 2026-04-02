#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="shellcheck" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/shellcheck.json"

# Find all shell scripts in the project
SCRIPT_LIST=$(find "$(pwd)" -name "*.sh" \
  -not -path "*/.git/*" \
  -not -path "*/node_modules/*" \
  -not -path "*/vendor/*" \
  -not -path "*/.codeql-db/*")

if [ -z "$SCRIPT_LIST" ]; then
  echo "No shell scripts found, skipping ShellCheck analysis."
  echo "[]" > "$fileName"
  echo "Empty report written to: $fileName"
  exit 0
fi

# Install ShellCheck if not already available
if ! command -v shellcheck > /dev/null 2>&1; then
  echo "Downloading ShellCheck..."
  SHELLCHECK_VERSION=$(curl -fsSL https://api.github.com/repos/koalaman/shellcheck/releases/latest | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  ARCH="x86_64" ;;
    aarch64) ARCH="aarch64" ;;
    armv6l)  ARCH="armv6hf" ;;
    *)
      echo "Unsupported architecture: $ARCH" >&2
      exit 1
      ;;
  esac

  curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/$SHELLCHECK_VERSION/shellcheck-$SHELLCHECK_VERSION.linux.$ARCH.tar.xz" -o /tmp/shellcheck.tar.xz
  tar -xJf /tmp/shellcheck.tar.xz -C /tmp
  mv "/tmp/shellcheck-$SHELLCHECK_VERSION/shellcheck" /tmp/shellcheck
  chmod +x /tmp/shellcheck
  rm -rf /tmp/shellcheck.tar.xz "/tmp/shellcheck-$SHELLCHECK_VERSION"
  export PATH="/tmp:$PATH"
fi

echo "Running ShellCheck analysis..."
echo "Checking scripts:"
echo "$SCRIPT_LIST" | while read -r f; do echo "  - $f"; done

find "$(pwd)" -name "*.sh" \
  -not -path "*/.git/*" \
  -not -path "*/node_modules/*" \
  -not -path "*/vendor/*" \
  -not -path "*/.codeql-db/*" \
  -print0 | xargs -0 shellcheck --format=json1 --severity=warning > "$fileName" || EXIT_CODE=$?

echo "ShellCheck analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
