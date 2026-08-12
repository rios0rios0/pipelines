#!/usr/bin/env sh

# Serves Terraform providers out of the directories this machine has already
# downloaded them into, so `terraform init` stops re-asking the network for
# things it already has.
#
# THE PROBLEM THIS SOLVES, precisely -- because the obvious fixes do not.
#
# Every tier that inits per-directory (`validate` over root modules, `terra-test`
# over `modules/*/`) makes one full provider-installation round trip per
# directory. `TF_PLUGIN_CACHE_DIR` caches the provider BINARY, and that is all it
# caches: Terraform still contacts the registry to enumerate versions, and still
# fetches the provider's `SHA256SUMS` + `SHA256SUMS.sig` to authenticate the
# package. For a HashiCorp-namespace provider those two files come from
# `releases.hashicorp.com`; for every community provider they come from that
# provider's GitHub release page.
#
# Measured with `TF_LOG=DEBUG` on a root module declaring three providers, one of
# them community-hosted, counting outbound request lines per `terraform init`:
#
#   warm plugin cache, no lock file   7 registry, 4 releases.hashicorp, 2 github
#   lock file, no plugin cache        7 registry, 4 releases.hashicorp, 2 github
#   lock file AND warm plugin cache   4 registry, 0                   , 0
#   filesystem_mirror                 0        , 0                   , 0
#
# Those are per-directory costs, so they multiply by the number of root modules.
# A monorepo with dozens of roots and a handful of community providers therefore
# asks github.com for the same few checksum files dozens of times inside a single
# job, from one egress IP, and github.com starts answering `503 Service
# Unavailable` and timing connections out. `init` then dies with:
#
#   Error while installing <namespace>/<provider> vX.Y.Z: could not query
#   provider registry for registry.terraform.io/<namespace>/<provider>: failed to
#   retrieve authentication checksums for provider: the request failed after 2
#   attempts, please try again later: 503 Service Unavailable returned from
#   github.com
#
# Note what such a run does NOT contain: not one `registry.terraform.io` failure
# and not one `releases.hashicorp.com` failure. The throttled host is github.com,
# and the only requests reaching it are the per-directory checksum fetches.
#
# WHY A MIRROR RATHER THAN A BIGGER CACHE. A Terraform `filesystem_mirror` is an
# installation METHOD: when one can satisfy a provider, Terraform never performs
# the registry protocol for it at all -- no version query, no checksum fetch. And
# the mirror's on-disk layout for an unpacked provider is
# `<host>/<namespace>/<name>/<version>/<os>_<arch>/`, which is byte-for-byte the
# layout `TF_PLUGIN_CACHE_DIR` already writes and the layout Terragrunt's provider
# cache already writes. So the store every tool on this machine has been filling
# for months is already a valid mirror; nothing has to be repacked, re-downloaded
# or converted. This helper only points Terraform at it.
#
# WHY `direct` CARRIES AN `exclude`, which reads backwards. The intuitive config
# is "mirror first, fall back to the network", spelled `filesystem_mirror` then a
# bare `direct {}`. That does not work. Terraform consults every installation
# method that matches a provider in order to choose the newest version that
# satisfies the constraint, so an unrestricted `direct` re-enables the registry
# query for EVERY provider, including the ones sitting in the mirror -- measured,
# not assumed. Reaching zero requests requires the mirror to be the only method
# allowed for `registry.terraform.io`, which is what the `exclude` expresses. The
# fallback therefore cannot live inside the config; it lives in
# `terraform_init_cached` below, as a second `init` run with this config absent.
#
# WHY READING A SHARED `$HOME` PATH IS SAFE HERE, given the incident that split
# the two tiers' cache defaults apart. `TF_PLUGIN_CACHE_DIR` is unsafe to share
# between concurrent agents because Terraform WRITES into it without locking --
# that is what produced `text file busy` and "the cached package does not match
# any of the checksums recorded in the dependency lock file". A mirror is only
# ever READ: Terraform copies out of it into each directory's own
# `.terraform/providers`. Sharing a read-only source between agents has no such
# hazard, which is why the mirror search path may include `$HOME` locations that
# the plugin-cache default deliberately avoids. This helper never writes to a
# mirror directory, and it must stay that way -- the write path is still
# `TF_PLUGIN_CACHE_DIR`, whose per-tier defaults are unchanged.

# Builds the provider-installation config and publishes its path in
# `TF_PROVIDER_MIRROR_CONFIG`. Returns 0 when a mirror is available, 1 when the
# caller should behave exactly as it did before this helper existed.
#
# Search order, highest priority first. Each directory that exists contributes
# one `filesystem_mirror` block; all of them are local, so however many are
# emitted the version enumeration still touches no network:
#
#   1. TF_PROVIDER_MIRROR_DIR    explicit operator override
#   2. TERRA_PROVIDER_CACHE_DIR  the store Terragrunt's provider cache server fills
#   3. $XDG_CACHE_HOME/terra/providers   the terra CLI's default store
#   4. TF_PLUGIN_CACHE_DIR       this tier's own cache, filled by the fallback below
#
# Entry 4 is what makes a cold machine converge inside a single run: the online
# fallback writes there, so the NEXT directory needing that provider version finds
# it in the mirror. A cold run pays one checksum fetch per distinct provider
# version instead of one per directory.
provider_mirror_configure() {
  TF_PROVIDER_MIRROR_CONFIG=''

  # A disabled mirror must leave behaviour bit-for-bit identical, so this is
  # checked before anything else is inspected or created.
  case "${TF_PROVIDER_MIRROR:-on}" in
    off | OFF | 0 | false | FALSE | no | NO)
      echo "  provider mirror: disabled via TF_PROVIDER_MIRROR; using the origin registry."
      return 1
      ;;
    *) ;;
  esac

  # Terraform accepts one CLI config file, and two `provider_installation` blocks
  # cannot be merged into it. A consumer that has already pointed Terraform at
  # their own config -- a private registry credential, a corporate mirror -- owns
  # that decision, and silently replacing it would be worse than declining.
  # `TERRAFORM_CONFIG` is the deprecated spelling Terraform still honours.
  if [ -n "${TF_CLI_CONFIG_FILE:-}" ] || [ -n "${TERRAFORM_CONFIG:-}" ]; then
    echo "  provider mirror: skipped, the caller already set a Terraform CLI config file."
    return 1
  fi

  # The terra CLI's default store only has a meaning when there is a cache home
  # to derive it from, so it is resolved before the loop rather than inline.
  # Spelling it `${XDG_CACHE_HOME:-${HOME:-}/.cache}` would expand to
  # `/.cache/terra/providers` with BOTH variables unset -- a path at the
  # filesystem root belonging to no user, and an ABSOLUTE one, so the `/*` guard
  # below could not catch it either.
  provider_mirror_terra_dir=''
  if [ -n "${XDG_CACHE_HOME:-}" ]; then
    provider_mirror_terra_dir="${XDG_CACHE_HOME}/terra/providers"
  elif [ -n "${HOME:-}" ]; then
    provider_mirror_terra_dir="${HOME}/.cache/terra/providers"
  fi

  provider_mirror_candidates=''
  for provider_mirror_dir in \
    "${TF_PROVIDER_MIRROR_DIR:-}" \
    "${TERRA_PROVIDER_CACHE_DIR:-}" \
    "${provider_mirror_terra_dir}" \
    "${TF_PLUGIN_CACHE_DIR:-}"; do
    [ -n "${provider_mirror_dir}" ] || continue
    [ -d "${provider_mirror_dir}" ] || continue

    # Terraform resolves a relative `filesystem_mirror` path against its own
    # working directory, which `-chdir` moves per root module -- so a relative
    # candidate would name a different place for every directory in the loop.
    # `XDG_CACHE_HOME` is required to be absolute but nothing enforces it, and an
    # operator override is free-form.
    case "${provider_mirror_dir}" in
      /*) ;;
      *) continue ;;
    esac

    # The same directory reaches this loop twice whenever a caller points two of
    # the variables at one store. Duplicate `filesystem_mirror` blocks are not an
    # error, but they make the config misleading to read in a build log.
    case "
${provider_mirror_candidates}" in
      *"
${provider_mirror_dir}
"*) continue ;;
      *) ;;
    esac
    provider_mirror_candidates="${provider_mirror_candidates}${provider_mirror_dir}
"
  done

  if [ -z "${provider_mirror_candidates}" ]; then
    echo "  provider mirror: no local provider store found; using the origin registry."
    return 1
  fi

  if ! provider_mirror_config="$(mktemp 2> /dev/null)"; then
    echo "  provider mirror: could not create a temporary CLI config; using the origin registry." >&2
    return 1
  fi

  {
    echo '# Generated by global/scripts/shared/terraform-provider-mirror.sh.'
    echo '# Serves providers from stores this machine already populated so that'
    echo '# `terraform init` performs no registry or GitHub requests for them.'
    echo 'provider_installation {'
    printf '%s' "${provider_mirror_candidates}" | while IFS= read -r provider_mirror_dir; do
      [ -n "${provider_mirror_dir}" ] || continue
      # HCL string literals take backslash escapes, so both metacharacters have to
      # be escaped -- backslash first, or it would double-escape the quotes added
      # after it.
      provider_mirror_escaped="$(printf '%s' "${provider_mirror_dir}" | sed -e 's|\\|\\\\|g' -e 's|"|\\"|g')"
      echo '  filesystem_mirror {'
      echo "    path    = \"${provider_mirror_escaped}\""
      echo '    include = ["registry.terraform.io/*/*"]'
      echo '  }'
    done
    # See the header: an unrestricted `direct` would re-enable the registry query
    # for providers the mirror already holds. Providers from any OTHER host stay
    # on the direct path, so a private registry keeps working untouched.
    echo '  direct {'
    echo '    exclude = ["registry.terraform.io/*/*"]'
    echo '  }'
    echo '}'
  } > "${provider_mirror_config}"

  TF_PROVIDER_MIRROR_CONFIG="${provider_mirror_config}"

  echo "  provider mirror: serving registry.terraform.io providers from"
  printf '%s' "${provider_mirror_candidates}" | while IFS= read -r provider_mirror_dir; do
    [ -n "${provider_mirror_dir}" ] || continue
    echo "    - ${provider_mirror_dir}"
  done
  echo "  provider mirror: anything missing falls back to the origin registry, per directory."

  return 0
}

# Guards the two public retry overrides. A non-integer -- or, for the attempt
# count, `0` -- would otherwise blow up the `[ ... -le ... ]` test and the `$(( ))`
# arithmetic in `terraform_init_cached` with a cryptic "not a valid number" which,
# under `set -e`, aborts the whole run somewhere unrelated. Coerce a bad value
# back to the default and warn instead of hard-failing: the retry loop's whole
# purpose is resilience, so a typo'd knob must not be able to sink the suite.
validate_positive_int() {
  # $1=value  $2=min allowed  $3=default  $4=var name (for the warning)
  case "$1" in
    '' | *[!0-9]*) ;; # empty / non-digit → warn
    *) if [ "$1" -ge "$2" ]; then printf '%s' "$1"; return 0; fi ;;
  esac
  echo "  warning: $4='$1' is not an integer >= $2; falling back to default ($3)." >&2
  printf '%s' "$3"
}

# Normalises the retry knobs once per run. Callers invoke this before their loop
# so an invalid override warns a single time rather than once per directory.
terraform_init_retry_defaults() {
  TF_INIT_MAX_ATTEMPTS="$(validate_positive_int "${TF_INIT_MAX_ATTEMPTS:-4}" 1 4 TF_INIT_MAX_ATTEMPTS)"
  TF_INIT_RETRY_DELAY="$(validate_positive_int "${TF_INIT_RETRY_DELAY:-5}" 0 5 TF_INIT_RETRY_DELAY)"
}

# Removes the generated CLI config. Callers invoke this from their own `trap`
# rather than the helper installing one, because a sourced function that installs
# an EXIT trap silently replaces whatever trap the caller already had.
provider_mirror_cleanup() {
  if [ -n "${TF_PROVIDER_MIRROR_CONFIG:-}" ]; then
    rm -f "${TF_PROVIDER_MIRROR_CONFIG}"
    TF_PROVIDER_MIRROR_CONFIG=''
  fi
}

# Runs `terraform -chdir=<dir> init <args...>`, preferring the mirror.
#
#   terraform_init_cached <dir> [init args...]
#
# Attempt 1 uses the mirror and is completely silent: its output is discarded
# whether it succeeds or fails, because a mirror miss is an ordinary event on a
# cold machine and printing a scary provider-resolution error for it would train
# readers to ignore the real one. Attempts 2..N are the caller's original
# behaviour -- same arguments, no CLI config, output left entirely alone so the
# caller's own redirection applies unchanged.
#
# Retries wrap only the online attempts, since a mirror failure is deterministic
# and re-running it would just burn wall-clock. `TF_INIT_MAX_ATTEMPTS` and
# `TF_INIT_RETRY_DELAY` keep the names and defaults they had when this loop lived
# in `terra-test/run.sh`.
terraform_init_cached() {
  terraform_init_dir="$1"
  shift

  if [ -n "${TF_PROVIDER_MIRROR_CONFIG:-}" ]; then
    # `-lockfile=readonly` only when a lock file is already there, and the
    # conditional is not cosmetic: with no lock file the flag makes `init` fail
    # outright ("Changes to the required provider dependencies were detected, but
    # the lock file is read-only"), which would send every directory in a
    # lock-free repo down the fallback path and defeat the whole helper.
    #
    # Where a lock file DOES exist the flag earns its place. An unpacked mirror
    # can only produce `h1:` directory hashes, never the `zh:` zip hashes, so an
    # unguarded offline `init` that has to add an entry writes a lock file valid
    # only on the platform that generated it. Read-only turns that silent
    # degradation into a clean miss, and the online fallback then records the
    # complete entry. When the lock file is already complete the flag is inert --
    # `init` succeeds and the file is untouched.
    if [ -f "${terraform_init_dir}/.terraform.lock.hcl" ]; then
      if TF_CLI_CONFIG_FILE="${TF_PROVIDER_MIRROR_CONFIG}" \
        terraform -chdir="${terraform_init_dir}" init -lockfile=readonly "$@" > /dev/null 2>&1; then
        return 0
      fi
    else
      if TF_CLI_CONFIG_FILE="${TF_PROVIDER_MIRROR_CONFIG}" \
        terraform -chdir="${terraform_init_dir}" init "$@" > /dev/null 2>&1; then
        return 0
      fi
    fi
  fi

  terraform_init_attempt=1
  while [ "${terraform_init_attempt}" -le "${TF_INIT_MAX_ATTEMPTS:-4}" ]; do
    if terraform -chdir="${terraform_init_dir}" init "$@"; then
      return 0
    fi
    if [ "${terraform_init_attempt}" -lt "${TF_INIT_MAX_ATTEMPTS:-4}" ]; then
      terraform_init_sleep=$((terraform_init_attempt * ${TF_INIT_RETRY_DELAY:-5}))
      echo "  terraform init failed (attempt ${terraform_init_attempt}/${TF_INIT_MAX_ATTEMPTS:-4}); retrying in ${terraform_init_sleep}s — transient registry.terraform.io 5xx / github.com 503 on provider checksums are the common causes..." >&2
      sleep "${terraform_init_sleep}"
    fi
    terraform_init_attempt=$((terraform_init_attempt + 1))
  done

  return 1
}
