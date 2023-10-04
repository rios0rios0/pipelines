#!/usr/bin/env sh

export SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

chmod -R 777 "$REPORT_PATH" # DinD approach needs this line
export CONTAINER_PATH="/src" # for this tool, it must be this value
fileName="$CONTAINER_PATH/$REPORT_PATH/semgrep.json"

customFile=".semgrepignore"
defaultFile="$SCRIPTS_DIR/global/scripts/semgrep/.semgrepignore"
if [ -f "$customFile" ]; then
  cat "$defaultFile" >> "$customFile"
else
  cp "$defaultFile" .
fi

docker run \
  -v "$(pwd):$CONTAINER_PATH" \
  --workdir "$CONTAINER_PATH" \
  returntocorp/semgrep:latest semgrep \
  --metrics off \
  --config "p/$1" \
  --config "p/docker" \
  --config "p/dockerfile" \
  --config "p/secrets" \
  --config "p/owasp-top-ten" \
  --config "p/r2c-best-practices" \
  --enable-version-check --force-color \
  --error --json --output "$fileName" || EXIT_CODE=$?

if ! ls "$REPORT_PATH"/*.json 1> /dev/null 2>&1; then
  echo "OK" > "$fileName"
fi

rm .semgrepignore
exit $EXIT_CODE
