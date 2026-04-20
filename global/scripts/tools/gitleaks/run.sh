#!/usr/bin/env sh

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="gitleaks" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

chmod -R 777 "$REPORT_PATH" # DinD approach needs this line
export CONTAINER_PATH="/opt/src"
fileName="$REPORT_PATH/gitleaks.json"

# Path to the GitLab-customized rule set we ship in this repo. It is mounted
# read-only into the container alongside the project source so the second
# pass can point at it via `--config` without ever touching the project's
# working tree (the previous behaviour was to `cp` it over the project's
# `.gitleaks.toml`, then `rm` afterwards — which silently deleted any
# project-local config the consumer relied on).
GITLAB_CONFIG_HOST_PATH="$SCRIPTS_DIR/global/scripts/tools/gitleaks/.gitleaks.toml"
GITLAB_CONFIG_CONTAINER_PATH="/opt/pipelines-gitleaks-config.toml"

export ENTRYPOINT_FILE="gitleaks.entrypoint.sh"
cat >"$ENTRYPOINT_FILE" <<EOL
#!/bin/bash

fileName="$CONTAINER_PATH/$REPORT_PATH/gitleaks-\$REPORT_NUMBER.json"
git config --global --add safe.directory $CONTAINER_PATH
configArg=""
if [ -n "\$GITLEAKS_CONFIG" ]; then
  configArg="--config \$GITLEAKS_CONFIG"
fi
# shellcheck disable=SC2086
gitleaks detect --source "$CONTAINER_PATH" --report-path \$fileName \$configArg
EOL
chmod +x "$ENTRYPOINT_FILE"

# Pass 1: gitleaks defaults + the project's `.gitleaks.toml` / `.gitleaksignore`
# if present (gitleaks auto-discovers them at the source root).
docker run \
  -v "$(pwd):$CONTAINER_PATH" \
  --env REPORT_NUMBER="01" \
  --entrypoint "$CONTAINER_PATH/$ENTRYPOINT_FILE" \
  zricethezav/gitleaks:latest || EXIT_CODE=$?

# Pass 2: GitLab-customized rule set, mounted read-only and explicitly
# selected with `--config`. The project's `.gitleaksignore` (fingerprint
# allowlist) is still auto-discovered from the source root and applies to
# this pass too. Skipped when pass 1 already failed.
if [ -z "$EXIT_CODE" ]; then
  docker run \
    -v "$(pwd):$CONTAINER_PATH" \
    -v "$GITLAB_CONFIG_HOST_PATH:$GITLAB_CONFIG_CONTAINER_PATH:ro" \
    --env REPORT_NUMBER="02" \
    --env GITLEAKS_CONFIG="$GITLAB_CONFIG_CONTAINER_PATH" \
    --entrypoint "$CONTAINER_PATH/$ENTRYPOINT_FILE" \
    zricethezav/gitleaks:latest || EXIT_CODE=$?
fi

rm -f "$ENTRYPOINT_FILE"

if ls "$REPORT_PATH"/*.json 1> /dev/null 2>&1; then
  jq -s "add" "$REPORT_PATH"/*.json > "$fileName"
else
  echo "OK" > "$fileName"
fi

exit $EXIT_CODE
