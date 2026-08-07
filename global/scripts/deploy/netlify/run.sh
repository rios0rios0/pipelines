#!/usr/bin/env sh

# Deploy to Netlify.
#
# Netlify's free tier is no longer a set of fixed quotas: since the April 2026
# pricing update it is a pool of 300 credits/month drawn down by everything the
# site does -- 15 credits per deploy, 20 per GB of bandwidth, 10 per GB-hour of
# compute, 2 per 10k web requests. That changes how a pipeline should behave on
# it. Deploys themselves cost credits, so a job that redeploys on every push to
# every branch can exhaust the month's pool without serving a single visitor:
# 300 credits is 20 deploys if nothing else draws on it. The `--no-build` flag
# below matters for the same reason -- building on Netlify burns compute
# credits, while building on the CI runner (which the pipeline is already
# paying for in minutes) and uploading the artifact does not.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="deploy-netlify" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/deploy/common.sh"

deploy_require_env "NETLIFY_AUTH_TOKEN" \
  "Create a personal access token at https://app.netlify.com/user/applications#personal-access-tokens."
deploy_require_env "NETLIFY_SITE_ID" \
  "Copy the site's API ID from Site configuration > General > Site details."

NETLIFY_OUTPUT_DIRECTORY="${NETLIFY_OUTPUT_DIRECTORY:-dist}"
DEPLOY_ENVIRONMENT="${DEPLOY_ENVIRONMENT:-production}"
export DEPLOY_ENVIRONMENT

if [ ! -d "$NETLIFY_OUTPUT_DIRECTORY" ] && [ "${DEPLOY_DRY_RUN:-false}" != "true" ]; then
  echo "ERROR: build output directory '$NETLIFY_OUTPUT_DIRECTORY' does not exist." >&2
  echo "Run the project's build before this step, or set NETLIFY_OUTPUT_DIRECTORY." >&2
  exit 1
fi

deploy_npm_cli "netlify" "netlify-cli"

# `--no-build` keeps the build on the CI runner rather than re-running it on
# Netlify, where it would draw down the credit pool a second time for work the
# pipeline has already done.
set -- deploy --dir "$NETLIFY_OUTPUT_DIRECTORY" --site "$NETLIFY_SITE_ID" --no-build

if [ "$DEPLOY_ENVIRONMENT" = "production" ]; then
  set -- "$@" --prod
fi

if [ -n "${NETLIFY_DEPLOY_MESSAGE:-}" ]; then
  set -- "$@" --message "$NETLIFY_DEPLOY_MESSAGE"
fi

# The token reaches the CLI through `NETLIFY_AUTH_TOKEN` in the environment,
# never as `--auth=<value>` on argv.
deploy_run netlify "$@" || EXIT_CODE=$?

deploy_record "netlify" "$NETLIFY_SITE_ID"

exit "${EXIT_CODE:-0}"
