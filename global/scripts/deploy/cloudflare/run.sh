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
CLOUDFLARE_API_URL="${CLOUDFLARE_API_URL:-https://api.cloudflare.com/client/v4}"
DEPLOY_ENVIRONMENT="${DEPLOY_ENVIRONMENT:-production}"
export DEPLOY_ENVIRONMENT

# cloudflare_ensure_project
#
# Create the Pages project when it does not exist yet.
#
# `wrangler pages deploy` refuses to create one: on a project that was never
# set up it exits with "The Pages project <name> does not exist", which on a
# first deploy is indistinguishable from a typo in the name. That left the one
# manual step in an otherwise fully scripted setup -- and it surfaced at the
# worst moment, on the first green pipeline, after the credentials had already
# been proven correct by the very request that reported the project missing.
#
# Existence is asked of the REST API rather than scraped from
# `wrangler pages project list`: the API answers with an HTTP status code,
# which cannot be misparsed and needs no JSON reader, so this adds no
# dependency beyond `curl` -- already required by the Render provider in this
# same family, and already installed by the GitLab template.
cloudflare_ensure_project() {
  # A dry run resolves the command line without touching the network, so the
  # check is skipped for the same reason the CLI installation is: it would be
  # the only part of the family that reached out to a real API, and the
  # validation harness runs offline and without credentials.
  if deploy_is_dry_run; then
    echo "DRY RUN: skipping the existence check for Pages project '$CLOUDFLARE_PROJECT_NAME'."
    return 0
  fi

  if ! command -v curl > /dev/null 2>&1; then
    echo "WARNING: 'curl' is unavailable, so the Pages project cannot be verified." >&2
    echo "If '$CLOUDFLARE_PROJECT_NAME' does not exist, create it once with:" >&2
    echo "  wrangler pages project create $CLOUDFLARE_PROJECT_NAME --production-branch $CLOUDFLARE_PRODUCTION_BRANCH" >&2
    return 0
  fi

  # The token reaches curl on stdin, never on argv, for the same reason the
  # Render provider does it that way: argv is readable through `ps` on a
  # shared runner. `proto = "=https"` pins the transport, because
  # CLOUDFLARE_API_URL is overridable and a plain-HTTP override would put the
  # bearer token on the wire in cleartext.
  _cep_status="$(
    {
      printf 'url = "%s/accounts/%s/pages/projects/%s"\n' \
        "$CLOUDFLARE_API_URL" "$CLOUDFLARE_ACCOUNT_ID" "$CLOUDFLARE_PROJECT_NAME"
      printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN"
      printf 'header = "Accept: application/json"\n'
      printf 'request = "GET"\nproto = "=https"\nproto-redir = "=https"\nsilent\nshow-error\n'
      printf 'output = "/dev/null"\nwrite-out = "%%{http_code}"\n'
    } | curl --config -
  )"

  case "$_cep_status" in
    200)
      echo "Pages project '$CLOUDFLARE_PROJECT_NAME' already exists."
      return 0
      ;;
    404)
      echo "Pages project '$CLOUDFLARE_PROJECT_NAME' does not exist yet; creating it."
      ;;
    *)
      # Anything else -- 401, 403, a 5xx, or an empty string because the
      # request never left the runner -- is not evidence of absence. Creating
      # on that basis would turn one transient API failure into a second,
      # duplicate project, so the script reports what it saw and lets the
      # deploy fail with the real error instead of inventing state.
      echo "WARNING: could not verify Pages project '$CLOUDFLARE_PROJECT_NAME' (HTTP ${_cep_status:-no response})." >&2
      echo "Leaving it untouched; the deploy below will report the underlying error." >&2
      return 0
      ;;
  esac

  # `--production-branch` is deliberately NOT `CLOUDFLARE_BRANCH`. That one
  # labels the deployment being uploaded, and on a preview deploy it holds a
  # preview name -- creating the project with it would make the preview branch
  # the project's production branch, so every preview would publish straight to
  # the production URL. The two are different questions and get different
  # variables.
  if ! deploy_run wrangler pages project create "$CLOUDFLARE_PROJECT_NAME" \
    --production-branch "$CLOUDFLARE_PRODUCTION_BRANCH"; then
    echo "ERROR: failed to create Pages project '$CLOUDFLARE_PROJECT_NAME'." >&2
    echo "The API token needs the 'Cloudflare Pages: Edit' permission to create a project." >&2
    exit 1
  fi
}

deploy_npm_cli "wrangler" "$WRANGLER_CLI_SPEC"

case "$CLOUDFLARE_TARGET" in
  pages)
    deploy_require_env "CLOUDFLARE_PROJECT_NAME" \
      "The Pages project name, as shown in the Cloudflare dashboard (Workers & Pages)."

    CLOUDFLARE_OUTPUT_DIRECTORY="${CLOUDFLARE_OUTPUT_DIRECTORY:-dist}"
    if [ ! -d "$CLOUDFLARE_OUTPUT_DIRECTORY" ] && ! deploy_is_dry_run; then
      echo "ERROR: build output directory '$CLOUDFLARE_OUTPUT_DIRECTORY' does not exist." >&2
      echo "Run the project's build before this step, or set CLOUDFLARE_OUTPUT_DIRECTORY." >&2
      exit 1
    fi

    # Defaulted here rather than at the top of the file because it is only
    # meaningful for Pages: a Workers deploy has no production branch.
    CLOUDFLARE_PRODUCTION_BRANCH="${CLOUDFLARE_PRODUCTION_BRANCH:-main}"
    cloudflare_ensure_project

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
