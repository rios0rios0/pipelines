#!/usr/bin/env sh

# Deploy to Cloudflare Pages or Workers.
#
# Cloudflare is the only provider in this family whose free tier is both
# permanent AND licensed for commercial use, and Pages does not meter bandwidth
# at all -- which is why an MVP that unexpectedly goes viral gets a traffic
# spike here instead of an invoice. The limits that do bind are on the compute
# side (Workers: 100k requests/day, 10ms CPU per invocation), so the practical
# question when choosing it is whether the app fits the Workers runtime, not
# whether the free tier will run out.
#
# One script covers both products because they share a CLI (`wrangler`), a
# credential pair, and an install path; `CLOUDFLARE_TARGET` picks the verb.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="deploy-cloudflare" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/deploy/common.sh"

deploy_require_env "CLOUDFLARE_API_TOKEN" \
  "Create one at https://dash.cloudflare.com/profile/api-tokens with the 'Edit Cloudflare Workers' template."
deploy_require_env "CLOUDFLARE_ACCOUNT_ID" \
  "Copy it from the right-hand sidebar of any domain's overview page in the Cloudflare dashboard."

CLOUDFLARE_TARGET="${CLOUDFLARE_TARGET:-pages}"
DEPLOY_ENVIRONMENT="${DEPLOY_ENVIRONMENT:-production}"
export DEPLOY_ENVIRONMENT

deploy_npm_cli "wrangler" "wrangler"

case "$CLOUDFLARE_TARGET" in
  pages)
    deploy_require_env "CLOUDFLARE_PROJECT_NAME" \
      "The Pages project name, as shown in the Cloudflare dashboard (Workers & Pages)."

    CLOUDFLARE_OUTPUT_DIRECTORY="${CLOUDFLARE_OUTPUT_DIRECTORY:-dist}"
    if [ ! -d "$CLOUDFLARE_OUTPUT_DIRECTORY" ] && [ "${DEPLOY_DRY_RUN:-false}" != "true" ]; then
      echo "ERROR: build output directory '$CLOUDFLARE_OUTPUT_DIRECTORY' does not exist." >&2
      echo "Run the project's build before this step, or set CLOUDFLARE_OUTPUT_DIRECTORY." >&2
      exit 1
    fi

    set -- pages deploy "$CLOUDFLARE_OUTPUT_DIRECTORY" \
      --project-name "$CLOUDFLARE_PROJECT_NAME"

    # Pages models environments as branches: the project's production branch
    # publishes to the production URL and every other branch gets a preview
    # URL. Passing the branch explicitly keeps that mapping under the
    # pipeline's control instead of depending on whatever the runner happens to
    # have checked out (a detached HEAD on most CI checkouts, which Pages would
    # otherwise treat as an unnamed preview).
    if [ -n "${CLOUDFLARE_BRANCH:-}" ]; then
      set -- "$@" --branch "$CLOUDFLARE_BRANCH"
    fi

    DEPLOY_TARGET="$CLOUDFLARE_PROJECT_NAME"
    ;;

  workers)
    set -- deploy

    # Workers environments come from named `[env.<name>]` sections in
    # `wrangler.toml`. Only pass `--env` when the consumer asked for a
    # non-production environment: `--env production` requires an `[env.production]`
    # section to exist, so sending it unconditionally would break every project
    # that uses the plain top-level configuration.
    if [ "$DEPLOY_ENVIRONMENT" != "production" ]; then
      set -- "$@" --env "$DEPLOY_ENVIRONMENT"
    fi

    DEPLOY_TARGET="${CLOUDFLARE_WORKER_NAME:-$(basename "$(pwd)")}"
    ;;

  *)
    echo "ERROR: unsupported CLOUDFLARE_TARGET '$CLOUDFLARE_TARGET' (expected 'pages' or 'workers')." >&2
    exit 1
    ;;
esac

# Both credentials reach wrangler through the environment, never argv.
deploy_run wrangler "$@" || EXIT_CODE=$?

deploy_record "cloudflare-$CLOUDFLARE_TARGET" "$DEPLOY_TARGET"

exit "${EXIT_CODE:-0}"
