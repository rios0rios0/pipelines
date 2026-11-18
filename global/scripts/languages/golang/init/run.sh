#!/usr/bin/env sh
set -e

# GitLab CI/CD steps/jobs leverages this variable to perform other commands
if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*\)/global/scripts/.*|\1|')"
  export SCRIPTS_DIR
fi

# The CI step that runs this script is a process of its own (Azure DevOps' "Load Custom
# Configuration", GitLab CI's Dependency-Track job), and the Go steps after it are others: what the
# project's `config.sh` exports dies with this process, so the git settings that authenticate
# private module fetches reach those steps only through the global git configuration of the
# runner. A `config.sh` writes them there on a CI runner -- an older one everywhere, a current one
# whenever TF_BUILD, GITHUB_ACTIONS or GITLAB_CI is set -- so both keep working. On a developer's
# machine nothing runs this script: a developer sources `config.sh` in the shell that runs Go, and
# `make codeql` sources it itself (see global/scripts/tools/codeql/run.sh).
INIT_SCRIPT="config.sh"
if [ -f "$INIT_SCRIPT" ]; then
  # shellcheck disable=SC1090
  . ./"$INIT_SCRIPT"
else
  echo "The '$INIT_SCRIPT' file was not found, skipping..."
fi
