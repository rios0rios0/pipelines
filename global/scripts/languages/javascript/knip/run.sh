#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="knip" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"

fileName="$(pwd)/$REPORT_PATH/knip.json"

# PINNED. `npx --yes knip` resolves and executes the newest published knip on
# every run -- a package downloaded and run with no version, no lockfile and no
# review, which is the npm supply-chain path in its most direct form. Knip also
# gates the build on what it considers unused, and that changes between
# releases, so an unchanged repository could go red overnight.
echo "Running knip unused exports/files analysis ($KNIP_SPEC)..."
npx --yes "$KNIP_SPEC" --reporter json > "$fileName" 2>&1 || EXIT_CODE=$?

echo "knip analysis complete. Results written to: $fileName"
exit "${EXIT_CODE:-0}"
