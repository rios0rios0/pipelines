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
#
# What is deployed comes from one of two places. With FLY_IMAGE -- an image the
# pipeline already built and pushed, which `go-flyio.yaml` passes by default --
# that image is copied into registry.fly.io and deployed by digest, and Fly
# builds nothing. Without it, `flyctl deploy --remote-only` builds the
# Dockerfile from source on Fly's builder. Neither needs a Docker daemon on the
# runner.

if [ -z "$SCRIPTS_DIR" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
TOOL_NAME="deploy-flyio" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"
. "$SCRIPTS_DIR/global/scripts/deploy/common.sh"
. "$SCRIPTS_DIR/global/scripts/shared/build-version.sh"

# fly_image_registry <reference>
#
# The registry host an image reference names, by the rule Docker applies: the
# first path component is a host when it carries a `.` or a `:` or is
# `localhost`, and a reference without one is on Docker Hub.
fly_image_registry() {
  case "$1" in
    */*) _fir_first="${1%%/*}" ;;
    *) _fir_first="" ;;
  esac
  case "$_fir_first" in
    *.* | *:* | localhost) printf '%s\n' "$_fir_first" ;;
    *) printf '%s\n' "index.docker.io" ;;
  esac

  return 0
}

# fly_registry_token
#
# Print FLY_API_TOKEN the way flyctl itself hands it to registry.fly.io, which
# is fly-go's `Tokens.Docker()`: without its `FlyV1 ` (or `Bearer `) scheme, and
# only its macaroons when it carries any. A deploy token prints as
# `FlyV1 fm2_...,fm2_...`, and the registry is given what follows the scheme.
#
# The token goes into awk on stdin and out on stdout, so it is never on an argv:
# `printf` is a shell builtin, and awk is handed only the program text.
fly_registry_token() {
  printf '%s' "$FLY_API_TOKEN" | awk '
    { token = token $0 }
    END {
      sub(/^[ \t]+/, "", token)
      while (match(tolower(token), /^(flyv1|bearer)[ \t]+/)) {
        token = substr(token, RLENGTH + 1)
      }
      count = split(token, parts, ",")
      for (i = 1; i <= count; i++) {
        part = parts[i]
        sub(/^[ \t]+/, "", part)
        sub(/[ \t]+$/, "", part)
        if (part == "") {
          continue
        }
        if (part ~ /^(fm1r|fm1a|fm2)_/) {
          macaroons = macaroons (macaroons == "" ? "" : ",") part
        } else {
          others = others (others == "" ? "" : ",") part
        }
      }
      printf "%s", (macaroons != "" ? macaroons : others)
    }'

  return 0
}

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

# Validated HERE -- before the CLI is downloaded, before the app is created and long
# before anything is deployed -- because the two enforcement points below fail
# ASYMMETRICALLY on a malformed value, and the asymmetry produces exactly the state this
# feature exists to prevent. A value of `1 ` (trailing space, invisible in a settings UI)
# or `one` is not equal to `1`, so `--ha=false` is NOT passed and Fly creates the spare;
# the deploy then SUCCEEDS, so the guard below is satisfied and `flyctl scale count` runs
# with the bad value, is rejected as a bad argument, and the job goes red reporting
# "deployed, but could not scale". The app is left live on two machines and the operator
# is pointed at `flyctl scale show` rather than at the value they mistyped.
#
# Rejecting up front keeps the failure honest: nothing has been released, so there is no
# "live but not as asked for" state to explain.
if [ -n "${FLY_MACHINE_COUNT:-}" ]; then
  case "$FLY_MACHINE_COUNT" in
    *[!0-9]*)
      echo "ERROR: FLY_MACHINE_COUNT must be a whole number, got '$FLY_MACHINE_COUNT'." >&2
      echo "Nothing has been deployed. Check the value for stray whitespace or quotes." >&2
      exit 1
      ;;
  esac
fi

# The image to deploy instead of building one: FLY_IMAGE, a reference to an image
# the pipeline ALREADY built and pushed. `go-flyio.yaml` passes the one its
# `delivery > docker` job pushed to GHCR, by digest. Rebuilding the Dockerfile
# on Fly's builder took about two of the two and a half minutes a deploy spent,
# and it produced a second image with a different digest: production ran that
# second build, not the artifact CI made. Deploying the delivered image also
# takes Fly's builder out of the deploy path, so a stalled remote build cannot
# fail a deploy either.
#
# Validated HERE, for the reason FLY_MACHINE_COUNT is: a reference holds only
# letters, digits and `._/:@-`, so anything else -- whitespace, a quote -- is
# refused before a CLI is downloaded, instead of failing halfway through the
# copy or reaching the JSON receipt verbatim.
FLY_IMAGE="${FLY_IMAGE:-}"
case "$FLY_IMAGE" in
  *[!A-Za-z0-9._/:@-]*)
    echo "ERROR: FLY_IMAGE must be an image reference (letters, digits and '._/:@-'), got '$FLY_IMAGE'." >&2
    echo "Nothing has been deployed. Check the value for stray whitespace or quotes." >&2
    exit 1
    ;;
  *) ;;
esac

# An image built before this job already carries its version: the delivery job
# that built it was handed the same build argument. There is no build here to
# pass it to, so the name is neither passed nor validated -- refusing a value
# nothing reads would cost a deploy for nothing.
if [ -n "${FLY_VERSION_BUILD_ARG:-}" ] && [ -n "$FLY_IMAGE" ]; then
  echo "FLY_VERSION_BUILD_ARG is not passed: FLY_IMAGE was built before this job, with its version already in it."
fi

# The version handed to the image, when the consumer opts in by NAMING the
# Dockerfile `ARG` that receives it: FLY_VERSION_BUILD_ARG. A Dockerfile that
# compiles its version in otherwise reports its default -- `dev`, on every
# deploy -- because `--remote-only` builds from source on Fly's builder and
# nothing else passes the argument. FLY_APP_VERSION sets the value outright;
# left empty, it is the tag on a tag build and the commit otherwise, resolved by
# the same helper the GitHub image delivery uses, so a commit built in both
# places reports one version.
#
# OPT-IN, because the name is the consumer's to choose. A build argument this
# script passed on its own would land in any project already using `ARG VERSION`
# for something else -- a pinned tool's version, say -- and override it without
# a word.
#
# Validated HERE, before the CLI is downloaded and before anything is deployed,
# for the reason FLY_MACHINE_COUNT is: nothing downstream rejects a malformed
# name. A build argument no `ARG` declares is ignored rather than refused, so the
# deploy would succeed with an image still reporting its default.
if [ -n "${FLY_VERSION_BUILD_ARG:-}" ] && [ -z "$FLY_IMAGE" ]; then
  if ! build_arg_name_is_valid "$FLY_VERSION_BUILD_ARG"; then
    echo "ERROR: FLY_VERSION_BUILD_ARG must name a Dockerfile ARG (letters, digits and underscores, not starting with a digit), got '$FLY_VERSION_BUILD_ARG'." >&2
    echo "Nothing has been deployed. Check the value for stray whitespace or quotes." >&2
    exit 1
  fi

  if ! FLY_RESOLVED_VERSION=$(build_version "${FLY_APP_VERSION:-}"); then
    if [ -n "${FLY_APP_VERSION:-}" ]; then
      echo "ERROR: FLY_APP_VERSION must be a single word, with no whitespace, got '$FLY_APP_VERSION'." >&2
    else
      echo "ERROR: FLY_VERSION_BUILD_ARG is set, but no version could be resolved: the CI platform exposes no tag or commit, and this is not a git checkout." >&2
    fi
    echo "Nothing has been deployed." >&2
    exit 1
  fi

  # The one silent miss left is a valid name the Dockerfile never declares. It
  # warns rather than fails, since the check reads the file line by line, and it
  # reads only a file that is there: the config's `[build] dockerfile`, relative
  # to the config's own directory as flyctl resolves it, else that directory's
  # `Dockerfile`, which is where flyctl looks when the config names none.
  FLY_DOCKERFILE=""
  if [ -f "$FLY_CONFIG" ]; then
    FLY_DOCKERFILE=$(sed -n -e '/^[[:space:]]*\[build\][[:space:]]*$/,/^[[:space:]]*\[/{' \
      -e "s/^[[:space:]]*dockerfile[[:space:]]*=[[:space:]]*[\"']\\([^\"']*\\)[\"'].*/\\1/p" \
      -e '}' "$FLY_CONFIG" | head -n 1)
  fi
  case "$FLY_DOCKERFILE" in
    /*) ;;
    *) FLY_DOCKERFILE="$(dirname "$FLY_CONFIG")/${FLY_DOCKERFILE:-Dockerfile}" ;;
  esac
  if [ -f "$FLY_DOCKERFILE" ] && ! build_arg_is_declared "$FLY_DOCKERFILE" "$FLY_VERSION_BUILD_ARG"; then
    echo "WARNING: '$FLY_DOCKERFILE' declares no 'ARG $FLY_VERSION_BUILD_ARG', so the version passed to it reaches nothing." >&2
  fi

  echo "Build version: $FLY_VERSION_BUILD_ARG=$FLY_RESOLVED_VERSION"
fi

# The app name is resolved BEFORE anything is installed, because it has two
# documented sources: FLY_APP_NAME, and `app = "..."` in the committed fly.toml
# -- the configuration `go-flyio.yaml` describes as making `fly_app_name`
# optional, and the one `flyctl launch` produces. Two things below need it: the
# app auto-creation, and the copy of FLY_IMAGE. Gating the creation on
# FLY_APP_NAME alone made FLY_ORG a SILENT no-op for exactly that setup: the
# consumer minted the wider org-scoped token to opt in, the creation was skipped
# without a word, and the first deploy still failed with `Could not find App`.
#
# The parse stops at the first table header: `app` is a top-level TOML key, so a
# same-named key inside a later `[section]` is not it.
FLY_RESOLVED_APP="${FLY_APP_NAME:-}"
if [ -z "$FLY_RESOLVED_APP" ] && [ -f "$FLY_CONFIG" ]; then
  FLY_RESOLVED_APP=$(sed -n -e '/^[[:space:]]*\[/q' \
    -e "s/^[[:space:]]*app[[:space:]]*=[[:space:]]*[\"']\\([^\"']*\\)[\"'].*/\\1/p" \
    "$FLY_CONFIG" | head -n 1)
fi

# The copy of FLY_IMAGE names the app: the image lands in registry.fly.io/<app>,
# the repository that app's machines pull from. With no name there is nowhere to
# copy it, so this fails before anything is installed or copied -- on a dry run
# too, which needs no network to find it out.
if [ -n "$FLY_IMAGE" ] && [ -z "$FLY_RESOLVED_APP" ]; then
  echo "ERROR: FLY_IMAGE is set, but no app name could be resolved, and the image is copied to registry.fly.io/<app>." >&2
  echo "Set FLY_APP_NAME, or declare 'app = \"<name>\"' in '$FLY_CONFIG'. Nothing has been deployed." >&2
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

# crane copies FLY_IMAGE into registry.fly.io, registry to registry, with no
# Docker daemon. Installed the way flyctl is above: a pinned version whose
# release archive must match the digest committed in `pinned-versions.sh`
# before anything is unpacked, and nothing at all on a dry run. Only `crane` is
# taken from the archive, which also carries `gcrane` and `krane`. The archive
# lands in a private directory rather than at a fixed name under /tmp, so two
# deploys on one self-hosted host cannot swap each other's download.
if [ -n "$FLY_IMAGE" ]; then
  if ! command -v crane > /dev/null 2>&1 && deploy_is_dry_run; then
    echo "DRY RUN: skipping installation of crane."
  elif ! command -v crane > /dev/null 2>&1; then
    echo "Downloading crane..."

    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)        CRANE_ARCH="x86_64"; CRANE_DIGEST_ARCH="X86_64" ;;
      aarch64|arm64) CRANE_ARCH="arm64";  CRANE_DIGEST_ARCH="ARM64" ;;
      *)
        echo "Unsupported architecture: $ARCH" >&2
        exit 1
        ;;
    esac

    CRANE_SHA256=$(pinned_digest CRANE "$CRANE_DIGEST_ARCH") || exit 1

    CRANE_DOWNLOAD_DIR=$(mktemp -d) || exit 1
    echo "Installing crane v$CRANE_VERSION (Linux/$CRANE_ARCH)..."
    if ! download_verified \
      "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_${CRANE_ARCH}.tar.gz" \
      "$CRANE_DOWNLOAD_DIR/crane.tar.gz" \
      "$CRANE_SHA256"; then
      rm -rf "$CRANE_DOWNLOAD_DIR"
      exit 1
    fi
    if ! tar -xzf "$CRANE_DOWNLOAD_DIR/crane.tar.gz" -C "$CRANE_DOWNLOAD_DIR" crane; then
      echo "ERROR: failed to extract crane from its release archive (corrupt download or no space left)." >&2
      rm -rf "$CRANE_DOWNLOAD_DIR"
      exit 1
    fi
    chmod +x "$CRANE_DOWNLOAD_DIR/crane"
    mv "$CRANE_DOWNLOAD_DIR/crane" "$HOME/.local/bin/crane"
    rm -rf "$CRANE_DOWNLOAD_DIR"
  fi

  if ! command -v crane > /dev/null 2>&1 && ! deploy_is_dry_run; then
    echo "ERROR: crane installation did not produce a runnable 'crane' binary." >&2
    exit 1
  fi
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
#
# It runs BEFORE the copy of FLY_IMAGE below: an image can only be pushed into
# the repository of an app that exists.

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
    #
    # The failure is CLASSIFIED rather than reported with one guess. There are two
    # unrelated reasons `apps create` is refused, they need opposite fixes, and the
    # first version of this block advised the token fix for both:
    #
    #   * `Name has already been taken` -- Fly app names are GLOBALLY unique across
    #     every customer, not scoped to an organisation, so no permission change can
    #     obtain one that is held. Combined with the lookup above, this narrows the
    #     cause to TWO situations that flyctl's output cannot tell apart, and the
    #     message names both rather than picking one: a stranger holds the name (the
    #     likely case for an unprefixed name, since role-shaped names like
    #     `api-staging`, `web` and `api` are long gone), or the operator's OWN
    #     account holds it under an organisation `FLY_ORG` does not name -- `apps
    #     list` only ever shows what the token can reach, so a token scoped to one
    #     org is blind to an app the same person owns in another. Asserting the
    #     first would tell that operator to rename a running application when the
    #     fix was to point FLY_ORG at the org that already owns it.
    #   * anything else -- most often an app-scoped token, which cannot create apps.
    if ! FLY_CREATE_LOG=$(flyctl apps create "$FLY_RESOLVED_APP" --org "$FLY_ORG" 2>&1); then
      printf '%s\n' "$FLY_CREATE_LOG" >&2
      echo "ERROR: could not create Fly app '$FLY_RESOLVED_APP' in org '$FLY_ORG'." >&2
      if printf '%s\n' "$FLY_CREATE_LOG" | grep -qi 'already been taken'; then
        echo "The name '$FLY_RESOLVED_APP' is already taken on Fly: app names are GLOBALLY unique, not per-organisation, and the lookup above already proved it is not in '$FLY_ORG' -- so it is held either by another account, or by another organisation of yours that FLY_ORG does not name." >&2
        echo "This is NOT a token problem -- no credential can claim a name somebody else holds. If the app is yours, point FLY_ORG at the organisation that owns it ('flyctl apps list' under that org). Otherwise choose a name unique to you (prefix it with your org or product) and set FLY_APP_NAME, or 'app = \"<name>\"' in '$FLY_CONFIG', to match." >&2
      else
        echo "If the token is APP-SCOPED it cannot create apps: mint an org-scoped one with 'flyctl tokens create org --org $FLY_ORG', or create the app by hand and leave FLY_ORG unset." >&2
      fi
      exit 1
    fi
    printf '%s\n' "$FLY_CREATE_LOG"
  fi
fi

# Copy FLY_IMAGE to where Fly machines pull from. They pull from registry.fly.io,
# never from the registry the pipeline pushed to: on GitHub Actions the
# credential that reads GHCR is the job's own token, which expires with the job,
# and a machine that restarts or migrates later pulls its image again. So the
# image is copied into the app's own repository first, registry to registry.
#
# Only linux/amd64 is copied, the platform Fly machines run. The multi-arch
# index the delivery job pushes is resolved to that one image FIRST, and
# everything after names its digest: the copy reads it, the destination tag is
# derived from it, and the deploy ships it. A tag is mutable -- a re-run of the
# same commit is a new build with a new digest -- so a deploy by tag ships
# whichever build pushed it last, while a deploy by digest can only ship these
# bytes. flyctl hands a digest-pinned reference to Fly's API unchanged, and the
# machines are configured with what the API resolves. The tag exists so the
# registry keeps the image, and it is named after the digest, so it can never
# be moved onto other bytes.
#
# Credentials go into a throwaway DOCKER_CONFIG, removed as soon as the copy is
# done (and on any exit before it), never into $HOME/.docker, where a persistent
# self-hosted runner would keep them for the next job. Every secret reaches
# crane on stdin, never on argv: `crane auth login` only stores what it is
# given, so a credential that is wrong surfaces at the digest or the copy below,
# which say so.
if [ -n "$FLY_IMAGE" ]; then
  FLY_REGISTRY_REPOSITORY="registry.fly.io/$FLY_RESOLVED_APP"
  if deploy_is_dry_run; then
    # A dry run touches no network, and the digest is the one value only the
    # registry can answer, so the deploy it records names it symbolically.
    FLY_SOURCE_IMAGE="$FLY_IMAGE"
    FLY_IMAGE_DIGEST="<linux/amd64-digest>"
    if [ -n "${FLY_IMAGE_REGISTRY_PASSWORD:-}" ]; then
      echo "DRY RUN (no login performed): crane auth login $(fly_image_registry "$FLY_IMAGE") --username ${FLY_IMAGE_REGISTRY_USERNAME:-} --password-stdin"
    fi
    echo "DRY RUN (no login performed): crane auth login registry.fly.io --username x --password-stdin"
    echo "DRY RUN (no copy performed): crane copy --platform linux/amd64 $FLY_IMAGE $FLY_REGISTRY_REPOSITORY:deployment-<linux/amd64-digest>"
  else
    if ! FLY_DOCKER_CONFIG=$(mktemp -d); then
      echo "ERROR: could not create a temporary directory for the registry credentials." >&2
      exit 1
    fi
    trap 'rm -rf "$FLY_DOCKER_CONFIG"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    DOCKER_CONFIG="$FLY_DOCKER_CONFIG"
    export DOCKER_CONFIG

    # The registry holding FLY_IMAGE, when it needs a login. A public image needs
    # none, so no password means no login.
    if [ -n "${FLY_IMAGE_REGISTRY_PASSWORD:-}" ]; then
      FLY_IMAGE_REGISTRY=$(fly_image_registry "$FLY_IMAGE")
      if [ -z "${FLY_IMAGE_REGISTRY_USERNAME:-}" ]; then
        echo "ERROR: FLY_IMAGE_REGISTRY_PASSWORD is set, but FLY_IMAGE_REGISTRY_USERNAME is not." >&2
        echo "Set the user '$FLY_IMAGE_REGISTRY' expects with that password. Nothing has been deployed." >&2
        exit 1
      fi
      if ! printf '%s' "$FLY_IMAGE_REGISTRY_PASSWORD" \
        | crane auth login "$FLY_IMAGE_REGISTRY" --username "$FLY_IMAGE_REGISTRY_USERNAME" --password-stdin; then
        echo "ERROR: could not store the credentials for '$FLY_IMAGE_REGISTRY'. Nothing has been deployed." >&2
        exit 1
      fi
    fi
    # Nothing after this reads it, and flyctl, which runs next, has no business
    # inheriting it.
    unset FLY_IMAGE_REGISTRY_PASSWORD

    # registry.fly.io takes the user `x` and the API token, as `flyctl auth
    # docker` logs in.
    if ! fly_registry_token | crane auth login registry.fly.io --username x --password-stdin; then
      echo "ERROR: could not store the credentials for registry.fly.io. Nothing has been deployed." >&2
      exit 1
    fi

    echo "Resolving the linux/amd64 image of $FLY_IMAGE..."
    if ! FLY_SOURCE_IMAGE=$(crane digest --platform linux/amd64 --full-ref "$FLY_IMAGE"); then
      echo "ERROR: could not resolve the linux/amd64 image of '$FLY_IMAGE'." >&2
      echo "Check that it was pushed, that it was built for linux/amd64 (the platform Fly machines run), and that the job can read it -- on GitHub Actions, that the deploy job is granted 'packages: read'. Nothing has been deployed." >&2
      exit 1
    fi

    # `<repository>@sha256:<64 hex>`, or nothing is copied: a destination named
    # after anything else could not promise to hold these bytes.
    FLY_IMAGE_DIGEST="${FLY_SOURCE_IMAGE##*@}"
    case "$FLY_IMAGE_DIGEST" in
      sha256:*) FLY_IMAGE_HEX="${FLY_IMAGE_DIGEST#sha256:}" ;;
      *) FLY_IMAGE_HEX="" ;;
    esac
    case "$FLY_IMAGE_HEX" in
      *[!0-9a-f]*) FLY_IMAGE_HEX="" ;;
      *) ;;
    esac
    if [ "${#FLY_IMAGE_HEX}" -ne 64 ]; then
      echo "ERROR: '$FLY_IMAGE' resolved to '$FLY_SOURCE_IMAGE', which names no sha256 digest. Nothing has been deployed." >&2
      exit 1
    fi

    FLY_REGISTRY_TAG="$FLY_REGISTRY_REPOSITORY:deployment-$FLY_IMAGE_HEX"
    echo "Copying $FLY_SOURCE_IMAGE to $FLY_REGISTRY_TAG..."
    if ! crane copy --platform linux/amd64 "$FLY_SOURCE_IMAGE" "$FLY_REGISTRY_TAG"; then
      echo "ERROR: could not copy '$FLY_SOURCE_IMAGE' to '$FLY_REGISTRY_TAG'." >&2
      echo "Check that the app '$FLY_RESOLVED_APP' exists and that FLY_API_TOKEN can deploy it. Nothing has been deployed." >&2
      exit 1
    fi

    # The registry credentials have done their job. They are removed now rather
    # than when the job ends, so flyctl, which runs next, neither inherits a path
    # to them nor runs while they are on disk -- the reason the password above is
    # unset. The EXIT trap still covers every path that stops before here.
    rm -rf "$FLY_DOCKER_CONFIG"
    unset DOCKER_CONFIG
  fi
  FLY_DEPLOY_IMAGE="$FLY_REGISTRY_REPOSITORY@$FLY_IMAGE_DIGEST"
fi

if [ -n "$FLY_IMAGE" ]; then
  # The copied image, by digest. Nothing is built, so no `--remote-only`, and
  # there is no build to hand a `--build-arg` to.
  set -- deploy --image "$FLY_DEPLOY_IMAGE"
else
  # `--remote-only` builds the image on Fly's builder rather than on the CI
  # runner. That is the right default here because it removes the need for a
  # Docker daemon in the job -- GitLab and Azure DevOps agents frequently have
  # none, and requiring privileged Docker-in-Docker just to deploy would be a
  # steeper prerequisite than the deploy itself.
  set -- deploy --remote-only
fi

if [ -n "${FLY_APP_NAME:-}" ]; then
  set -- "$@" --app "$FLY_APP_NAME"
fi
if [ -f "$FLY_CONFIG" ]; then
  set -- "$@" --config "$FLY_CONFIG"
fi
if [ -n "${FLY_STRATEGY:-}" ]; then
  set -- "$@" --strategy "$FLY_STRATEGY"
fi
if [ -n "${FLY_VERSION_BUILD_ARG:-}" ] && [ -z "$FLY_IMAGE" ]; then
  set -- "$@" --build-arg "$FLY_VERSION_BUILD_ARG=$FLY_RESOLVED_VERSION"
fi

# `--ha=false` when the app is pinned to a single machine. Fly's deploy creates a SPARE
# machine the first time a process group is filled -- the log reads "This deployment will:
# create 2 app machines" -- which is the right default for a stateless app and the wrong
# one for a process that is not yet safe to run twice. Passed only for a count of 1, so
# every other value keeps Fly's own behaviour.
if [ "${FLY_MACHINE_COUNT:-}" = "1" ]; then
  set -- "$@" --ha=false
fi

# The token reaches flyctl through `FLY_API_TOKEN` in the environment, never as
# `--access-token=<value>` on argv.
deploy_run flyctl "$@" || EXIT_CODE=$?

# Enforced AFTER the deploy and only when it succeeded: scaling around a release that
# never became healthy resizes the app to an image nobody wants. Idempotent, so a run
# already at the requested count still proves the ceiling rather than assuming an earlier
# deploy set it.
#
# Why a ceiling is worth expressing at all: an app whose process is not safe to run twice
# -- an in-process event bus, an in-memory rate limiter, background workers with no leader
# election -- is silently WRONG on two machines rather than broken, so nothing reports it.
# `min_machines_running` in fly.toml is a FLOOR and cannot say this.
if [ -n "${FLY_MACHINE_COUNT:-}" ] && [ -z "${EXIT_CODE:-}" ] && ! deploy_is_dry_run; then
  echo "Pinning $FLY_RESOLVED_APP to $FLY_MACHINE_COUNT machine(s)..."
  if ! flyctl scale count "$FLY_MACHINE_COUNT" --app "$FLY_RESOLVED_APP" --yes; then
    echo "ERROR: deployed, but could not scale '$FLY_RESOLVED_APP' to $FLY_MACHINE_COUNT machine(s)." >&2
    echo "The release is live and the machine count is NOT what was asked for -- check 'flyctl scale show --app $FLY_RESOLVED_APP'." >&2
    EXIT_CODE=1
  fi
fi

# The receipt names the image a FLY_IMAGE deploy shipped, and the one it was
# copied from -- the artifact the pipeline delivered.
if [ -n "$FLY_IMAGE" ]; then
  deploy_record "flyio" "${FLY_APP_NAME:-$FLY_CONFIG}" "$FLY_DEPLOY_IMAGE" "$FLY_SOURCE_IMAGE"
else
  deploy_record "flyio" "${FLY_APP_NAME:-$FLY_CONFIG}"
fi

exit "${EXIT_CODE:-0}"
