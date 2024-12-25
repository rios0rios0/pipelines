#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi
. "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

export CONTAINER_PATH="/opt/src"
fileName="$CONTAINER_PATH/$REPORT_PATH/horusec.json"

if ! ls "$(pwd)"/horusec*.json 1> /dev/null 2>&1; then
  exit 101
fi

jq -s "add" "$SCRIPTS_DIR/global/scripts/horusec/default.json" "$(pwd)"/horusec*.json > "$(pwd)/custom.json"
# TODO: upgrade Horusec version whenever the stable version is released
# see more here: https://stackoverflow.com/questions/75522692/horusec-v2-8-is-not-working-in-ci-docker-in-docker-environment
docker run \
  -v "$(pwd):$CONTAINER_PATH" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  horuszup/horusec-cli:v2.9.0-beta.3 horusec start \
  --project-path "$CONTAINER_PATH" --container-bind-project-path "$(pwd)" \
  --config-file-path "$CONTAINER_PATH/custom.json" --json-output-file "$fileName"
