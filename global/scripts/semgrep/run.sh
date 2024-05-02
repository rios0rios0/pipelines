#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi
. "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

chmod -R 777 "$REPORT_PATH" # DinD approach needs this line
export CONTAINER_PATH="/src" # for this tool, it must be this value
fileName="$CONTAINER_PATH/$REPORT_PATH/semgrep.json"

# TODO: Should we merge files?
ignoreFileExists=true

if [ ! -f ".semgrepignore" ]; then
  ignoreFileExists=false
  defaultFile="$SCRIPTS_DIR/global/scripts/semgrep/.semgrepignore"
  cp "$defaultFile" .
fi

dockerRun="docker run \
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
  --error --json --output "$fileName"" 

if [ -f ".semgrepexcluderules" ]; then # check if you have rules to exclude
  semgrepExcludeRules=""
  IFS='
  '
  for line in $(cat ".semgrepexcluderules"); do
    semgrepExcludeRules="$semgrepExcludeRules --exclude-rule $line"
  done
  dockerRun="$dockerRun$semgrepExcludeRules"
fi

if [ -f ".semgrep.yaml" ]; then # check if you have custom rules to add
  dockerRun="$dockerRun --config ".semgrep.yaml""
fi

eval "$dockerRun" || EXIT_CODE=$?

if ! ls "$REPORT_PATH"/*.json 1> /dev/null 2>&1; then
  echo "OK" > "$fileName"
fi

if [ ! $ignoreFileExists ]; then
  rm .semgrepignore
fi

exit $EXIT_CODE
