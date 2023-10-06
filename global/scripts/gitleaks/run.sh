#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi
. "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

chmod -R 777 "$REPORT_PATH" # DinD approach needs this line
export CONTAINER_PATH="/opt/src"
fileName="$REPORT_PATH/gitleaks.json"

export ENTRYPOINT_FILE="gitleaks.entrypoint.sh"
cat >"$ENTRYPOINT_FILE" <<EOL
#!/bin/bash

fileName="$CONTAINER_PATH/$REPORT_PATH/gitleaks-\$REPORT_NUMBER.json"
git config --global --add safe.directory $CONTAINER_PATH
gitleaks detect --source "$CONTAINER_PATH" --report-path \$fileName
EOL
chmod +x "$ENTRYPOINT_FILE"

# default configuration file
docker run \
  -v "$(pwd):$CONTAINER_PATH" \
  --env REPORT_NUMBER="01" \
  --entrypoint "$CONTAINER_PATH/$ENTRYPOINT_FILE" \
  zricethezav/gitleaks:latest || EXIT_CODE=$?

if [ -z "$EXIT_CODE" ]; then
  # GitLab customized configuration file
  cp "$SCRIPTS_DIR/global/scripts/gitleaks/.gitleaks.toml" .
  docker run \
    -v "$(pwd):$CONTAINER_PATH" \
    --env REPORT_NUMBER="02" \
    --entrypoint "$CONTAINER_PATH/$ENTRYPOINT_FILE" \
    zricethezav/gitleaks:latest || EXIT_CODE=$?

  rm $ENTRYPOINT_FILE .gitleaks.toml
fi

if ls "$REPORT_PATH"/*.json 1> /dev/null 2>&1; then
  jq -s "add" "$REPORT_PATH"/*.json > "$fileName"
else
  echo "OK" > "$fileName"
fi

exit $EXIT_CODE
