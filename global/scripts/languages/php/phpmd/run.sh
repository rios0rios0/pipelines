#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="phpmd" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

fileName="$(pwd)/$REPORT_PATH/phpmd.json"

if ! command -v phpmd > /dev/null 2>&1; then
  echo "Installing PHPMD..."
  composer global require phpmd/phpmd --quiet
  COMPOSER_BIN_DIR="$(composer global config bin-dir --absolute --quiet 2>/dev/null || echo "$HOME/.composer/vendor/bin")"
  export PATH="$PATH:$COMPOSER_BIN_DIR"
else
  # Already present (persistent agent): self-update so long-lived hosts stay
  # current for CVE fixes. `composer global update` only fetches a newer
  # release when one exists, so this is a no-op otherwise.
  echo "Updating PHPMD..."
  # Best-effort: PHPMD may have been installed by another mechanism on this
  # host, so only self-update when composer is actually available rather than
  # failing the step with `composer: not found`.
  if command -v composer > /dev/null 2>&1; then
    composer global update phpmd/phpmd --quiet
  else
    echo "WARN: composer not available; keeping the installed PHPMD." >&2
  fi
fi

echo "Running PHPMD unused code analysis..."
phpmd . json unusedcode > "$fileName" 2>&1 || EXIT_CODE=$?

echo "PHPMD analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
