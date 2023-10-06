#!/usr/bin/env sh

export SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

export CONTAINER_PATH="/opt/src"
fileName="$CONTAINER_PATH/$REPORT_PATH/horusec.json"

if ! ls "$(pwd)"/horusec*.json 1> /dev/null 2>&1; then
  exit 101
fi

jq -s "add" "$SCRIPTS_DIR/global/scripts/horusec/default.json" "$(pwd)"/horusec*.json > "$(pwd)/custom.json"
docker run \
  -v "$(pwd):$CONTAINER_PATH" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  horuszup/horusec-cli:v2.7 horusec start \
  -p "$CONTAINER_PATH" -P "$(pwd)" --config-file-path "$CONTAINER_PATH/custom.json" -O "$fileName"
