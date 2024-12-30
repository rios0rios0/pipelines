#!/usr/bin/env sh
set -e

# GitLab CI/CD steps/jobs leverages this variable to perform other commands
if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi

INIT_SCRIPT="config.sh"
[[ -f $INIT_SCRIPT ]] && . ./$INIT_SCRIPT || echo "The '$INIT_SCRIPT' file was not found, skipping..."
