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
# PHPMD 3 replaced the positional `<paths> <format> <ruleset>` command line with an `analyze`
# command that takes the format and the rule set as options. Handed the PHPMD 2 form, it reads `.`
# as a command name and exits 1 with `Command "." is not defined.` before analysing a file, which
# is how every PHP pipeline failed once setup-php began installing 3.0.0. A persistent agent can
# still hold PHPMD 2, which has no `analyze` command, so the installed major picks the form.
#
# Only the report goes into the report file. stderr -- the reason a run stopped, and PHPMD 3's
# progress bar if `--no-progress` is ever dropped -- goes to the log: redirected into the report,
# the error above was invisible in the job log and left a "JSON" report that was not JSON.
if phpmd --version 2> /dev/null | grep -q '^PHPMD [12]\.'; then
  phpmd . json unusedcode > "$fileName" || EXIT_CODE=$?
else
  phpmd analyze --format json --ruleset unusedcode --no-progress . > "$fileName" || EXIT_CODE=$?
fi

echo "PHPMD analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
