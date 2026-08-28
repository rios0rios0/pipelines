#!/usr/bin/env sh

# Deploy to Fly.io.
#
# Fly.io is the one provider in this family with NO free tier -- the permanent
# free allowance was withdrawn in 2024 and new accounts get a 2-hour trial. It
# earns its place anyway because it is the cheapest way to keep a real container
# running continuously: a shared-cpu-1x/256MB machine is roughly $2/month, below
# every paid entry point among the other four, and it runs an ordinary
# Dockerfile across ~35 regions rather than constraining the app to static files
# or an edge runtime. For an MVP that must not cold-start -- a webhook receiver,
# a bot, anything with a health check -- that is usually worth more than a free
# tier that sleeps.
#
# `flyctl` is installed from its GitHub release archive rather than through the
# vendor's `curl https://fly.io/install.sh | sh` one-liner. Piping a remote
# script into a shell hands the CI runner's credentials to whatever that URL
# returns at that moment, which is exactly the supply-chain shape the SAST
# stage of this repository exists to flag; the release tarball is a fixed,
# checksum-able artifact and matches how gitleaks, hadolint and shellcheck are
# installed here.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="deploy-flyio" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/deploy/common.sh"

deploy_require_env "FLY_API_TOKEN" \
  "Generate one with 'flyctl tokens create deploy' and expose it to the job as a secret."

DEPLOY_ENVIRONMENT="${DEPLOY_ENVIRONMENT:-production}"
export DEPLOY_ENVIRONMENT

FLY_CONFIG="${FLY_CONFIG:-fly.toml}"
if [ ! -f "$FLY_CONFIG" ] && [ -z "${FLY_APP_NAME:-}" ] && ! deploy_is_dry_run; then
  echo "ERROR: neither '$FLY_CONFIG' nor FLY_APP_NAME is present." >&2
  echo "Run 'flyctl launch' locally to generate fly.toml and commit it, or set FLY_APP_NAME." >&2
  exit 1
fi

# A dry run only resolves and records the command line, so downloading the CLI
# would be pure cost -- and skipping it is what lets the validation harness run
# this provider offline.
if ! command -v flyctl > /dev/null 2>&1 && deploy_is_dry_run; then
  echo "DRY RUN: skipping installation of flyctl."
elif ! command -v flyctl > /dev/null 2>&1; then
  echo "Downloading flyctl..."

  # The version is PINNED and the archive is CHECKSUM-VERIFIED. Resolving
  # `releases/latest` at run time left the deploy client -- the process that
  # holds the production Fly API token -- chosen by whoever answered the
  # redirect, and left a deploy unable to state which client shipped it.
  #
  # `download_verified` keeps the HTTPS constraint that mattered here
  # (`--proto '=https' --proto-redir '=https'`): release URLs redirect to a
  # CDN, and by default curl follows an HTTPS response into a plain-HTTP
  # location, so a hostile redirect could otherwise choose the bytes that
  # become this executable.
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)        FLYCTL_ARCH="x86_64"; FLYCTL_DIGEST_ARCH="X86_64" ;;
    aarch64|arm64) FLYCTL_ARCH="arm64";  FLYCTL_DIGEST_ARCH="ARM64" ;;
    *)
      echo "Unsupported architecture: $ARCH" >&2
      exit 1
      ;;
  esac

  FLYCTL_SHA256=$(pinned_digest FLYCTL "$FLYCTL_DIGEST_ARCH") || exit 1

  echo "Installing flyctl v$FLYCTL_VERSION (Linux/$FLYCTL_ARCH)..."
  if ! download_verified \
    "https://github.com/superfly/flyctl/releases/download/v${FLYCTL_VERSION}/flyctl_${FLYCTL_VERSION}_Linux_${FLYCTL_ARCH}.tar.gz" \
    /tmp/flyctl.tar.gz \
    "$FLYCTL_SHA256"; then
    exit 1
  fi
  if ! tar -xzf /tmp/flyctl.tar.gz -C /tmp flyctl; then
    echo "ERROR: failed to extract flyctl from /tmp/flyctl.tar.gz (corrupt download or no space in /tmp)." >&2
    rm -f /tmp/flyctl.tar.gz
    exit 1
  fi
  rm -f /tmp/flyctl.tar.gz
  chmod +x /tmp/flyctl
  mv /tmp/flyctl "$HOME/.local/bin/flyctl"
fi

if ! command -v flyctl > /dev/null 2>&1 && ! deploy_is_dry_run; then
  echo "ERROR: flyctl installation did not produce a runnable 'flyctl' binary." >&2
  exit 1
fi

# Create the app on its first deploy, so standing up a new environment does not
# depend on somebody remembering to run `flyctl apps create` by hand. `flyctl
# deploy` does NOT create an app -- it fails with `Could not find App "<name>"`
# -- so without this the first pipeline of every new environment is red, and the
# fix lives in one person's shell history instead of in this repository.
#
# OPT-IN, via FLY_ORG. Left unset the whole step is skipped and nothing changes
# for a consumer that creates its apps deliberately. That default matters
# because of the token scope this costs:
#
#   * An APP-SCOPED deploy token (`flyctl tokens create deploy --app <app>`)
#     CANNOT create apps. It is the tighter credential -- a token for
#     `api-staging` cannot touch `api-production` -- and it is the right choice
#     when the apps already exist.
#   * Auto-creation therefore requires an ORG-SCOPED token (`flyctl tokens
#     create org --org <org>`), which can manage EVERY app in the organisation.
#
# That is a real widening of blast radius and it is the consumer's call, not
# this library's. Setting FLY_ORG is the consumer stating it made that trade.
#
# Existence is checked with `apps list` rather than by running `apps create` and
# swallowing the error. Fly app names are GLOBALLY unique, so a name already
# taken by an unrelated organisation is rejected with the same "already taken"
# message as one of ours -- treating that as success would report a green deploy
# against an app this account does not own. `apps list` only ever shows apps the
# token can actually reach, so a miss means "create it", never "someone else has
# it and we quietly gave up".

# The app name is resolved BEFORE the guard, because it has two documented
# sources: FLY_APP_NAME, and `app = "..."` in the committed fly.toml -- the
# configuration `go-flyio.yaml` describes as making `fly_app_name` optional, and
# the one `flyctl launch` produces. Gating the creation on FLY_APP_NAME alone
# made FLY_ORG a SILENT no-op for exactly that setup: the consumer minted the
# wider org-scoped token to opt in, this block was skipped without a word, and
# the first deploy still failed with `Could not find App`.
#
# The parse stops at the first table header: `app` is a top-level TOML key, so a
# same-named key inside a later `[section]` is not it.
FLY_RESOLVED_APP="${FLY_APP_NAME:-}"
if [ -z "$FLY_RESOLVED_APP" ] && [ -f "$FLY_CONFIG" ]; then
  FLY_RESOLVED_APP=$(sed -n -e '/^[[:space:]]*\[/q' \
    -e "s/^[[:space:]]*app[[:space:]]*=[[:space:]]*[\"']\\([^\"']*\\)[\"'].*/\\1/p" \
    "$FLY_CONFIG" | head -n 1)
fi

# Never silent: opting in and getting nothing is the failure this whole block
# exists to remove, so an unresolvable name says so rather than skipping. Not
# gated on the dry run -- it costs no network and no install, and a dry run is
# where a consumer would most want to find out.
if [ -n "${FLY_ORG:-}" ] && [ -z "$FLY_RESOLVED_APP" ]; then
  echo "WARNING: FLY_ORG is set but no app name could be resolved, so app auto-creation is skipped." >&2
  echo "Set FLY_APP_NAME, or declare 'app = \"<name>\"' in '$FLY_CONFIG'." >&2
fi

if [ -n "$FLY_RESOLVED_APP" ] && [ -n "${FLY_ORG:-}" ] && ! deploy_is_dry_run; then
  # `--json` rather than the table: the human table's columns are presentation
  # and may be re-laid-out by any flyctl release, while the JSON key is the
  # API's own name for the field. The trailing quote in the pattern keeps the
  # match exact, so `api-staging` does not match an existing `api-staging-2`.
  #
  # flyctl's exit status is read separately from grep's, and its diagnostic is
  # kept rather than sent to /dev/null. Folding the two together made a FAILED
  # lookup -- an API 500, an expired token, a renamed subcommand -- identical to
  # "the app is absent": the script would announce it was creating an app that
  # already exists, `apps create` would be rejected for the name being taken,
  # and the job would die advising the operator to widen a token that was never
  # the problem. A miss only means "create it" once it is proven to be a miss.
  if ! FLY_APPS_JSON=$(flyctl apps list --json 2>&1); then
    echo "ERROR: could not list Fly apps to check whether '$FLY_RESOLVED_APP' exists." >&2
    printf '%s\n' "$FLY_APPS_JSON" >&2
    exit 1
  fi
  if printf '%s\n' "$FLY_APPS_JSON" \
    | grep -qi "\"name\"[[:space:]]*:[[:space:]]*\"${FLY_RESOLVED_APP}\""; then
    echo "Fly app '$FLY_RESOLVED_APP' already exists; deploying into it."
  else
    echo "Fly app '$FLY_RESOLVED_APP' does not exist; creating it in org '$FLY_ORG'..."
    # NOT routed through `deploy_run`: that helper overwrites `command.txt`, and
    # that file must end the job holding the DEPLOY command -- it is the first
    # thing anyone debugging a red deploy reads. Provisioning is not the deploy.
    # No credential is on this argv either; the org slug is not a secret.
    if ! flyctl apps create "$FLY_RESOLVED_APP" --org "$FLY_ORG"; then
      echo "ERROR: could not create Fly app '$FLY_RESOLVED_APP' in org '$FLY_ORG'." >&2
      echo "If the token is APP-SCOPED it cannot create apps: mint an org-scoped one with 'flyctl tokens create org --org $FLY_ORG', or create the app by hand and leave FLY_ORG unset." >&2
      exit 1
    fi
  fi
fi

# `--remote-only` builds the image on Fly's builder rather than on the CI
# runner. That is the right default here because it removes the need for a
# Docker daemon in the job -- GitLab and Azure DevOps agents frequently have
# none, and requiring privileged Docker-in-Docker just to deploy would be a
# steeper prerequisite than the deploy itself.
set -- deploy --remote-only

if [ -n "${FLY_APP_NAME:-}" ]; then
  set -- "$@" --app "$FLY_APP_NAME"
fi
if [ -f "$FLY_CONFIG" ]; then
  set -- "$@" --config "$FLY_CONFIG"
fi
if [ -n "${FLY_STRATEGY:-}" ]; then
  set -- "$@" --strategy "$FLY_STRATEGY"
fi

# The token reaches flyctl through `FLY_API_TOKEN` in the environment, never as
# `--access-token=<value>` on argv.
deploy_run flyctl "$@" || EXIT_CODE=$?

deploy_record "flyio" "${FLY_APP_NAME:-$FLY_CONFIG}"

exit "${EXIT_CODE:-0}"
