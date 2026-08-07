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

  # Resolve the latest tag through the `releases/latest` redirect rather than
  # the GitHub API: the API is rate limited to 60 requests/hour per IP
  # unauthenticated and intermittently returns 403 from shared runner IPs,
  # which would leave the version empty and -- with no `set -e` under POSIX sh
  # -- sail through into a malformed download URL. Same resolver the gitleaks
  # and shellcheck installers use.
  #
  # `--proto '=https' --proto-redir '=https'` is required precisely BECAUSE
  # this resolver depends on following a redirect. By default `curl -L` will
  # happily follow an HTTPS response into a plain-HTTP location, so a hostile
  # or compromised redirect could downgrade the transport and choose which
  # bytes land in the archive below -- an archive this script then makes
  # executable and runs with the job's credentials in scope. Constraining both
  # the initial request and every redirect target to HTTPS removes the
  # downgrade as an option rather than trusting the remote not to offer it.
  FLYCTL_VERSION=$(curl -fsSLI --proto '=https' --proto-redir '=https' -o /dev/null -w '%{url_effective}' https://github.com/superfly/flyctl/releases/latest | sed 's#.*/tag/##')
  if [ -z "$FLYCTL_VERSION" ]; then
    echo "ERROR: could not resolve the latest flyctl version (GitHub outage or network failure)." >&2
    exit 1
  fi

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)        FLYCTL_ARCH="x86_64" ;;
    aarch64|arm64) FLYCTL_ARCH="arm64" ;;
    *)
      echo "Unsupported architecture: $ARCH" >&2
      exit 1
      ;;
  esac

  # Same HTTPS pinning as the resolver above: the release asset URL redirects
  # to a CDN, and this is the request whose bytes become an executable.
  if ! curl -fsSL --proto '=https' --proto-redir '=https' "https://github.com/superfly/flyctl/releases/download/$FLYCTL_VERSION/flyctl_${FLYCTL_VERSION#v}_Linux_${FLYCTL_ARCH}.tar.gz" -o /tmp/flyctl.tar.gz; then
    echo "ERROR: failed to download flyctl $FLYCTL_VERSION (Linux/$FLYCTL_ARCH)." >&2
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
