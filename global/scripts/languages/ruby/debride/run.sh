#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="debride" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"

fileName="$(pwd)/$REPORT_PATH/debride.txt"

# PINNED. Same reasoning as vulture: an unpinned `gem install` plus a
# `gem update` on every run meant the dead-code verdict for a given commit
# depended on the day it was computed. `DEBRIDE_SPEC` is `name:version`, which
# is the form `gem install -v` takes.
DEBRIDE_NAME="${DEBRIDE_SPEC%%:*}"
DEBRIDE_GEM_VERSION="${DEBRIDE_SPEC##*:}"
if ! command -v debride > /dev/null 2>&1; then
  echo "Installing $DEBRIDE_NAME $DEBRIDE_GEM_VERSION..."
  gem install --user-install -n "$HOME/.local/bin" "$DEBRIDE_NAME" -v "$DEBRIDE_GEM_VERSION" --no-document --quiet
fi

echo "Running debride unused code analysis..."
debride . > "$fileName" 2>&1 || EXIT_CODE=$?

echo "debride analysis complete. Results written to: $fileName"
exit ${EXIT_CODE:-0}
