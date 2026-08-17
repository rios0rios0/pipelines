#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="vulture" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"

fileName="$(pwd)/$REPORT_PATH/vulture.txt"

# Install vulture at the PINNED version.
#
# The unpinned install resolved to whatever PyPI served, and the "self-update"
# branch actively pulled the newest release on every run of a persistent agent.
# Vulture reports dead code, and each release changes what it considers dead, so
# an unchanged repository could pass one day and fail the next. `pip install` of
# an exact version is idempotent, which is why the update branch is now gone
# rather than replaced.
echo "Installing $VULTURE_SPEC..."
python -m pip install --user --quiet --only-binary :all: "$VULTURE_SPEC"

# Include a project-level whitelist if present to suppress known false positives
whitelistArgs=""
if [ -f ".vulture-whitelist.py" ]; then
  whitelistArgs=".vulture-whitelist.py"
fi

echo "Running vulture unused code analysis..."
# shellcheck disable=SC2086
python -m vulture . $whitelistArgs --min-confidence 80 --exclude .venv > "$fileName" 2>&1 || EXIT_CODE=$?

echo "vulture analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
