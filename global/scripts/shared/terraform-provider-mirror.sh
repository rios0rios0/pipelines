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
# TWO CONFIGS, AND THE DIFFERENCE BETWEEN THEM IS THE WHOLE DESIGN.
#
# The PRIMARY config pairs the mirror with `direct { exclude = ... }`, making the
# mirror the only method allowed for `registry.terraform.io`. That reaches zero
# outbound requests, but it is all-or-nothing: one provider the mirror cannot
# serve fails the whole `init`.
#
# The FALLBACK config pairs the same mirror with an unrestricted `direct {}`.
# Measured, because the intuition here is wrong in both directions: an
# unrestricted `direct` DOES re-enable the registry version query for every
# provider (4 requests to `registry.terraform.io`), but it does NOT re-fetch the
# github checksums for providers the mirror can serve. In a root declaring one
# mirrored and one missing provider, the mirrored one installs from the mirror
# `(unauthenticated)` with no github traffic at all, and the single missing one
# is the only `SHA256SUMS` fetched. So the fallback pays github exactly for the
# genuine misses rather than for every community provider in the directory --
# which is what an earlier revision did, and why two root modules kept failing on
# a provider the mirror was already holding.
#
# Registry queries are the cheap half and have never been the failing half; the
# github checksum fetches are what gets throttled. The fallback minimises those
# rather than the total.
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
  # BOTH are cleared up front. Every path out of this function other than the
  # last one is a decline, and a decline has to leave `terraform_init_cached`
  # with nothing to reach for -- otherwise a second call in the same shell (a
  # runner that re-configures, a caller that disables the mirror partway) would
  # still see the previous call's paths and hand Terraform a `-config-file` that
  # `provider_mirror_cleanup` has already deleted.
  TF_PROVIDER_MIRROR_CONFIG=''
  TF_PROVIDER_MIRROR_FALLBACK_CONFIG=''

  provider_mirror_disabled=0
  case "${TF_PROVIDER_MIRROR:-on}" in
    off | OFF | 0 | false | FALSE | no | NO) provider_mirror_disabled=1 ;;
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

  # Repair a plugin cache that an earlier revision of this helper poisoned. That
  # revision ran the mirror attempt with `TF_PLUGIN_CACHE_DIR` still set, so
  # Terraform wrote symlinks-into-the-mirror there, and every later online
  # install of those exact versions fails with "cannot install package into
  # target directory ... because it is a symlink" until they are removed. The
  # `validate` tier heals itself because its cache is workspace-relative and the
  # checkout wipes it, but `terra-test` defaults to a `$HOME` path that persists
  # across builds on a self-hosted machine, so without this the tier stays broken
  # until somebody clears the directory by hand.
  #
  # Only links pointing INTO one of the mirrors resolved above are removed --
  # those are exactly this helper's own artifacts. A consumer who legitimately
  # runs their own `filesystem_mirror` alongside a plugin cache has the same
  # symlinks for a different target, and deleting theirs would force a needless
  # re-download.
  if [ -n "${TF_PLUGIN_CACHE_DIR:-}" ] && [ -d "${TF_PLUGIN_CACHE_DIR}" ] \
    && command -v readlink > /dev/null 2>&1; then
    provider_mirror_pruned=0
    # Fed by a here-document rather than a pipe so the counter below increments in
    # THIS shell; a `find | while` would run the loop in a subshell and the total
    # would always print as zero.
    while IFS= read -r provider_mirror_link; do
      [ -n "${provider_mirror_link}" ] || continue
      provider_mirror_target="$(readlink "${provider_mirror_link}" 2>/dev/null)" || continue
      provider_mirror_saved_ifs="${IFS}"
      IFS='
'
      # shellcheck disable=SC2086 # word splitting on the newline IFS set above is
      # how the candidate list is iterated; the paths themselves may contain spaces
      for provider_mirror_dir in ${provider_mirror_candidates}; do
        case "${provider_mirror_target}" in
          "${provider_mirror_dir}"/*)
            rm -f "${provider_mirror_link}"
            provider_mirror_pruned=$((provider_mirror_pruned + 1))
            break
            ;;
          *) ;;
        esac
      done
      IFS="${provider_mirror_saved_ifs}"
    done << EOF
$(find "${TF_PLUGIN_CACHE_DIR}" -type l 2> /dev/null)
EOF
    if [ "${provider_mirror_pruned}" -gt 0 ]; then
      echo "  provider mirror: removed ${provider_mirror_pruned} stale symlink(s) from ${TF_PLUGIN_CACHE_DIR} left by an earlier revision."
    fi
  fi

  # Disabling the mirror is the ONLY remaining way to reach a pure-`direct`
  # install, and therefore the only way to meet a leftover symlink -- so the
  # repair above runs first and this returns after it, not before.
  if [ "${provider_mirror_disabled}" -eq 1 ]; then
    echo "  provider mirror: disabled via TF_PROVIDER_MIRROR; using the origin registry."
    return 1
  fi

  # Reported after the knob, deliberately: an operator who turned the mirror off
  # should be told that, not told which stores were missing.
  if [ -z "${provider_mirror_candidates}" ]; then
    echo "  provider mirror: no local provider store found; using the origin registry."
    return 1
  fi

  if ! provider_mirror_config="$(mktemp 2> /dev/null)"; then
    echo "  provider mirror: could not create a temporary CLI config; using the origin registry." >&2
    return 1
  fi

  if ! provider_mirror_fallback_config="$(mktemp 2> /dev/null)"; then
    rm -f "${provider_mirror_config}"
    echo "  provider mirror: could not create a temporary CLI config; using the origin registry." >&2
    return 1
  fi

  # Emits the shared `filesystem_mirror` blocks. Both configs list exactly the
  # same stores; only their `direct` block differs.
  provider_mirror_emit_mirrors() {
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
  }

  {
    echo '# Generated by global/scripts/shared/terraform-provider-mirror.sh.'
    echo '# Primary: the mirror is the ONLY method allowed for registry.terraform.io,'
    echo '# so a satisfied `init` performs no outbound request whatsoever.'
    echo 'provider_installation {'
    provider_mirror_emit_mirrors
    echo '  direct {'
    echo '    exclude = ["registry.terraform.io/*/*"]'
    echo '  }'
    echo '}'
  } > "${provider_mirror_config}"

  {
    echo '# Generated by global/scripts/shared/terraform-provider-mirror.sh.'
    echo '# Fallback: same stores, but the registry may also serve. Providers the'
    echo '# mirror holds still install from it, so github is asked only for misses.'
    echo 'provider_installation {'
    provider_mirror_emit_mirrors
    echo '  direct {}'
    echo '}'
  } > "${provider_mirror_fallback_config}"

  TF_PROVIDER_MIRROR_CONFIG="${provider_mirror_config}"
  TF_PROVIDER_MIRROR_FALLBACK_CONFIG="${provider_mirror_fallback_config}"

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
  if [ -n "${TF_PROVIDER_MIRROR_FALLBACK_CONFIG:-}" ]; then
    rm -f "${TF_PROVIDER_MIRROR_FALLBACK_CONFIG}"
    TF_PROVIDER_MIRROR_FALLBACK_CONFIG=''
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
    # `env -u TF_PLUGIN_CACHE_DIR` is load-bearing, and leaving it out breaks the
    # FALLBACK rather than this attempt. With a plugin cache configured AND a
    # `filesystem_mirror` serving the package, Terraform populates the cache by
    # writing a SYMLINK into it pointing at the mirror. Nothing complains at the
    # time. But the online fallback later has to install a real package at that
    # exact path, and refuses:
    #
    #   Error while installing hashicorp/tls v4.3.0: cannot install package into
    #   target directory <cache>/registry.terraform.io/hashicorp/tls/4.3.0/
    #   linux_amd64 because it is a symlink
    #
    # That is deterministic, so the retry loop below burns every attempt on it
    # and blames a transient registry for a failure that will never clear. The
    # mirror gains nothing from the cache anyway -- it is already a local
    # directory -- so the two are never enabled together, leaving the fallback as
    # the cache's only writer.
    #
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
      if env -u TF_PLUGIN_CACHE_DIR TF_CLI_CONFIG_FILE="${TF_PROVIDER_MIRROR_CONFIG}" \
        terraform -chdir="${terraform_init_dir}" init -lockfile=readonly "$@" > /dev/null 2>&1; then
        return 0
      fi
    else
      if env -u TF_PLUGIN_CACHE_DIR TF_CLI_CONFIG_FILE="${TF_PROVIDER_MIRROR_CONFIG}" \
        terraform -chdir="${terraform_init_dir}" init "$@" > /dev/null 2>&1; then
        return 0
      fi
    fi
  fi

  # The fallback keeps the mirror in play and only adds the registry to it, so a
  # provider the mirror holds still installs locally and github is asked solely
  # for the genuine misses. `TF_PLUGIN_CACHE_DIR` stays in force here, which is
  # what makes a cold machine converge: the downloaded misses land in the cache as
  # real directories, and the cache is itself one of the mirror's search paths, so
  # the next directory needing that version is served locally.
  #
  # Mirror-served providers do get symlinked into the cache by this attempt, and
  # that is deliberate rather than overlooked. Those symlinks are only a hazard
  # for a PURE-`direct` install, which no path through this helper performs any
  # more -- the only way to reach one is to disable the mirror, and
  # `provider_mirror_configure` prunes them in that case before returning.
  terraform_init_attempt=1
  while [ "${terraform_init_attempt}" -le "${TF_INIT_MAX_ATTEMPTS:-4}" ]; do
    if [ -n "${TF_PROVIDER_MIRROR_FALLBACK_CONFIG:-}" ]; then
      if TF_CLI_CONFIG_FILE="${TF_PROVIDER_MIRROR_FALLBACK_CONFIG}" \
        terraform -chdir="${terraform_init_dir}" init "$@"; then
        return 0
      fi
    elif terraform -chdir="${terraform_init_dir}" init "$@"; then
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
