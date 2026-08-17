#!/usr/bin/env sh

# Deploy to Vercel.
#
# Vercel is the most-used deployment platform (~33% share) and its Hobby tier is
# free, but the tier carries a licence restriction the other four providers in
# this family do not: HOBBY IS NON-COMMERCIAL. A project that takes payment,
# runs ads, or otherwise earns revenue needs Pro. That is a real trap for the
# exact audience this family targets -- an MVP is free to host right up to the
# day it starts working -- so the check below warns when the consumer has
# declared a commercial deployment while still on Hobby, rather than letting
# them discover it as an account suspension.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="deploy-vercel" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/deploy/common.sh"

deploy_require_env "VERCEL_TOKEN" \
  "Create one at https://vercel.com/account/tokens and expose it to the job as a secret."

# `VERCEL_ORG_ID` / `VERCEL_PROJECT_ID` are what make a CI deploy non-interactive.
# Without them the CLI tries to infer the project from the working directory and
# then PROMPTS to link or create one; on a runner there is no TTY to answer, so
# the job either hangs until the platform's job timeout or creates a stray
# project on the account. Both are printed by `vercel link` locally and are not
# secret -- they are identifiers, not credentials.
deploy_require_env "VERCEL_PROJECT_ID" \
  "Run 'vercel link' locally and copy the projectId from .vercel/project.json."
deploy_require_env "VERCEL_ORG_ID" \
  "Run 'vercel link' locally and copy the orgId from .vercel/project.json."

DEPLOY_ENVIRONMENT="${DEPLOY_ENVIRONMENT:-production}"
export DEPLOY_ENVIRONMENT

if deploy_is_truthy "${VERCEL_COMMERCIAL:-false}" \
  && [ "$(printf '%s' "${VERCEL_PLAN:-hobby}" | tr '[:upper:]' '[:lower:]')" = "hobby" ]; then
  echo "WARN: VERCEL_COMMERCIAL=true but VERCEL_PLAN is still 'hobby'. Vercel's Hobby tier" >&2
  echo "WARN: is licensed for non-commercial use only -- a revenue-generating project needs" >&2
  echo "WARN: Pro. Set VERCEL_PLAN=pro once the account is upgraded to silence this." >&2
fi

deploy_npm_cli "vercel" "$VERCEL_CLI_SPEC"

# `--yes` skips every confirmation prompt; `--prod` targets the production
# alias. A preview deployment (the default) is what a pull request wants, so
# DEPLOY_ENVIRONMENT drives the flag rather than hardcoding production.
set -- deploy --yes
if [ "$DEPLOY_ENVIRONMENT" = "production" ]; then
  set -- "$@" --prod
fi
if [ -n "${VERCEL_WORKING_DIRECTORY:-}" ]; then
  set -- "$@" --cwd "$VERCEL_WORKING_DIRECTORY"
fi

# The token reaches the CLI through `VERCEL_TOKEN` in the environment, never as
# `--token=<value>` on argv -- see the header of common.sh for why.
deploy_run vercel "$@" || EXIT_CODE=$?

deploy_record "vercel" "${VERCEL_PROJECT_ID}"

exit "${EXIT_CODE:-0}"
