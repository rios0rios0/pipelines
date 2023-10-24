#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi
. "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

chmod -R 777 "$REPORT_PATH" # DinD approach needs this line
export CONTAINER_PATH="/src" # for this tool, it must be this value
fileName="$CONTAINER_PATH/$REPORT_PATH/semgrep.json"

defaultFile="$SCRIPTS_DIR/global/scripts/semgrep/.semgrepignore"
cp "$defaultFile" .

if [ -f ".semgrep.yaml" ]; then
  docker run \
  -v "$(pwd):$CONTAINER_PATH" \
  --workdir "$CONTAINER_PATH" \
  returntocorp/semgrep:latest \
  semgrep \
  --metrics=off \
  --config "p/$1" \
  --config "p/docker" \
  --config "p/dockerfile" \
  --config "p/secrets" \
  --config "p/owasp-top-ten" \
  --config "p/r2c-best-practices" \
  --config ".semgrep.yaml" \
  --enable-version-check --force-color \
  --error --json --output "$fileName" || EXIT_CODE=$?
else
  docker run \
  -v "$(pwd):$CONTAINER_PATH" \
  --workdir "$CONTAINER_PATH" \
  returntocorp/semgrep:latest \
  semgrep \
  --metrics=off \
  --config "p/$1" \
  --config "p/docker" \
  --config "p/dockerfile" \
  --config "p/secrets" \
  --config "p/owasp-top-ten" \
  --config "p/r2c-best-practices" \
  --enable-version-check --force-color \
  --error --json --output "$fileName" || EXIT_CODE=$?
fi

if ! ls "$REPORT_PATH"/*.json 1> /dev/null 2>&1; then
  echo "OK" > "$fileName"
fi

rm .semgrepignore
exit $EXIT_CODE
