#!/usr/bin/env sh
# shellcheck shell=sh
#
# Integrity-checked downloads for every binary these pipelines install and run.
# SOURCED, never executed -- it carries no `run.sh` name and no executable bit.
#
# Before this existed, every installer here followed the same shape: resolve a
# version over the network, `curl` an artifact, `chmod +x`, run it. Nothing
# verified what arrived. That put the integrity of every scan, build and deploy
# in the hands of whoever could answer the request -- upstream, their CDN, a
# proxy on the runner's egress path, or anyone who compromised a release asset
# after publication. The binary then ran with the job's credentials in scope,
# which on the security jobs includes a token that can write to the repository
# it is scanning.
#
# The rule this file enforces: NOTHING IS EXECUTED BEFORE ITS SHA-256 MATCHES A
# DIGEST COMMITTED IN THIS REPOSITORY. A mismatch is fatal and the artifact is
# deleted, so a poisoned download cannot be picked up by a later step that only
# checks whether the file exists.

# verify_sha256 <file> <expected-hex-digest>
#
# 0 when the file's SHA-256 equals the expectation, non-zero otherwise.
#
# Three hashers are tried because there is no single one present everywhere
# these scripts run: coreutils `sha256sum` on most Linux images (busybox
# provides it too), `shasum` on macOS and the BSD-derived agents, and `openssl`
# as the last resort on minimal images that ship neither. If NONE is available
# the function fails rather than passing -- an unverifiable download must not
# be indistinguishable from a verified one.
verify_sha256() {
  _vs_file="$1"
  _vs_expected="$2"

  if [ ! -f "$_vs_file" ]; then
    echo "ERROR: cannot verify '$_vs_file': no such file." >&2
    return 1
  fi

  if command -v sha256sum > /dev/null 2>&1; then
    _vs_actual=$(sha256sum "$_vs_file" | awk '{print $1}')
  elif command -v shasum > /dev/null 2>&1; then
    _vs_actual=$(shasum -a 256 "$_vs_file" | awk '{print $1}')
  elif command -v openssl > /dev/null 2>&1; then
    _vs_actual=$(openssl dgst -sha256 "$_vs_file" | awk '{print $NF}')
  else
    echo "ERROR: no SHA-256 tool available (looked for sha256sum, shasum, openssl)." >&2
    echo "       Refusing to install an unverifiable download. Add coreutils or openssl to the image." >&2
    return 1
  fi

  # Case-folded: `shasum` and `openssl` have historically differed in case
  # across versions, and a digest that matches but reads as a mismatch would
  # send someone hunting a compromise that never happened.
  _vs_actual=$(printf '%s' "$_vs_actual" | tr '[:upper:]' '[:lower:]')
  _vs_expected=$(printf '%s' "$_vs_expected" | tr '[:upper:]' '[:lower:]')

  if [ "$_vs_actual" != "$_vs_expected" ]; then
    echo "ERROR: checksum mismatch for '$_vs_file'." >&2
    echo "       expected: $_vs_expected" >&2
    echo "       actual:   $_vs_actual" >&2
    return 1
  fi

  return 0
}

# pinned_digest <TOOL> <ARCH_SUFFIX>
#
# Echo the SHA-256 that `<TOOL>` should be verified against, reading the
# variables `pinned-versions.sh` defines:
#
#   <TOOL>_PINNED_VERSION    the version whose digest is committed here
#   <TOOL>_VERSION           the version actually requested (env-overridable)
#   <TOOL>_SHA256_<ARCH>     the committed digest for that version and arch
#   <TOOL>_SHA256_OVERRIDE   a digest supplied alongside a version override
#
# A committed digest describes ONE exact build, so it cannot be reused when an
# operator overrides the version -- verifying the new download against the old
# digest would fail every time and read like an attack. The three outcomes are
# therefore: version unchanged -> committed digest; version overridden WITH a
# digest -> that digest; version overridden WITHOUT one -> `SKIP` plus a
# warning naming the variable that restores verification.
#
# Centralised because the alternative is this branch copied into every
# installer, each with the pinned version written out a second time -- which is
# exactly the kind of duplicate that drifts silently on the next bump.
# The four temporaries in this function are assigned through `eval`, because
# their variable NAMES are composed from the tool argument. ShellCheck cannot
# follow an assignment made that way and reports each read as
# referenced-but-unassigned (SC2154); the `:-` default in every eval is what
# actually guarantees they are always set. The directive sits on the function
# rather than on a single line because it applies to the whole body from here.
# shellcheck disable=SC2154
pinned_digest() {
  _pd_tool="$1"
  _pd_arch="$2"

  eval "_pd_pinned=\${${_pd_tool}_PINNED_VERSION:-}"
  eval "_pd_wanted=\${${_pd_tool}_VERSION:-}"
  eval "_pd_override=\${${_pd_tool}_SHA256_OVERRIDE:-}"
  if [ -n "$_pd_arch" ]; then
    eval "_pd_committed=\${${_pd_tool}_SHA256_${_pd_arch}:-}"
  else
    eval "_pd_committed=\${${_pd_tool}_SHA256:-}"
  fi

  if [ -n "$_pd_override" ]; then
    printf '%s\n' "$_pd_override"
    return 0
  fi

  if [ "$_pd_wanted" != "$_pd_pinned" ]; then
    echo "WARNING: ${_pd_tool}_VERSION is overridden to '$_pd_wanted' (pinned: '$_pd_pinned')." >&2
    echo "         The committed digest describes '$_pd_pinned' only, so this download is UNVERIFIED." >&2
    echo "         Set ${_pd_tool}_SHA256_OVERRIDE to that build's SHA-256 to keep it verified." >&2
    printf 'SKIP\n'
    return 0
  fi

  if [ -z "$_pd_committed" ]; then
    echo "ERROR: no committed digest for ${_pd_tool} on this architecture." >&2
    echo "       Add ${_pd_tool}_SHA256_${_pd_arch} to global/scripts/shared/pinned-versions.sh." >&2
    return 1
  fi

  printf '%s\n' "$_pd_committed"
  return 0
}

# download_verified <url> <destination> <expected-sha256>
#
# Fetch over HTTPS, verify, and keep the file only if it matches.
#
# `--proto '=https' --proto-redir '=https'` is not decoration. Release URLs
# redirect to a CDN, and by default curl will follow an HTTPS response into a
# plain-HTTP location -- so a hostile redirect could choose the bytes that end
# up being made executable. Constraining the initial request AND every redirect
# to HTTPS removes the downgrade rather than trusting the remote not to offer
# it.
#
# Passing the digest as the literal string `SKIP` performs the download without
# verification and prints a loud warning. That escape hatch exists for the two
# cases where a digest genuinely cannot be known in advance -- a consumer
# pinning their own tool version, or an artifact whose publisher ships no
# manifest -- and it is deliberately noisy so it cannot become the default by
# accident.
download_verified() {
  _dv_url="$1"
  _dv_dest="$2"
  _dv_sha="$3"

  if [ -z "$_dv_sha" ]; then
    echo "ERROR: download_verified called with no expected checksum for '$_dv_url'." >&2
    echo "       Add the digest to global/scripts/shared/pinned-versions.sh, or pass 'SKIP' deliberately." >&2
    return 1
  fi

  echo "Downloading $_dv_url"
  if command -v curl > /dev/null 2>&1; then
    if ! curl -fsSL --proto '=https' --proto-redir '=https' "$_dv_url" -o "$_dv_dest"; then
      echo "ERROR: failed to download '$_dv_url'." >&2
      rm -f "$_dv_dest"
      return 1
    fi
  elif command -v wget > /dev/null 2>&1; then
    if ! wget -q --https-only -O "$_dv_dest" "$_dv_url"; then
      echo "ERROR: failed to download '$_dv_url'." >&2
      rm -f "$_dv_dest"
      return 1
    fi
  else
    echo "ERROR: neither curl nor wget is available to download '$_dv_url'." >&2
    return 1
  fi

  if [ "$_dv_sha" = "SKIP" ]; then
    echo "WARNING: '$_dv_url' was installed WITHOUT checksum verification." >&2
    echo "         A pinned version with a committed digest is the supported path;" >&2
    echo "         see global/scripts/shared/pinned-versions.sh." >&2
    return 0
  fi

  if ! verify_sha256 "$_dv_dest" "$_dv_sha"; then
    # Removed, not merely reported. A later step that only tests for existence
    # would otherwise install the artifact this function just rejected.
    echo "       Refusing to install '$_dv_dest'; the file has been deleted." >&2
    echo "       If this followed a deliberate version change, update the digest in" >&2
    echo "       global/scripts/shared/pinned-versions.sh. Otherwise treat the artifact as hostile." >&2
    rm -f "$_dv_dest"
    return 1
  fi

  # `${var##*/}` rather than `basename`: one less binary to depend on in a
  # minimal image, and this line runs on the success path of every install.
  echo "Checksum OK for ${_dv_dest##*/}"
  return 0
}

# download_verified_against_manifest <url> <destination> <manifest-url> <asset-name>
#
# For artifacts whose version is chosen by the CONSUMER rather than pinned here
# -- the Dart and Flutter SDKs are the whole reason this exists. No digest can
# be committed for a version this repository does not choose, so the publisher's
# own manifest is used instead.
#
# Be clear about what this does and does not buy. It does NOT defend against a
# compromised publisher, who would simply sign the manifest too. It DOES defend
# against a truncated or corrupted transfer, a cache serving stale or wrong
# bytes, and a redirect answered by something that cannot also rewrite the
# manifest fetched separately over HTTPS. That is strictly more than the
# nothing that was checked before, and it is the most that is available when
# the version is not ours to fix.
download_verified_against_manifest() {
  _dm_url="$1"
  _dm_dest="$2"
  _dm_manifest="$3"
  _dm_asset="$4"

  _dm_expected=$(curl -fsSL --proto '=https' --proto-redir '=https' "$_dm_manifest" 2>/dev/null \
    | grep -E "([ *]|^)${_dm_asset}\$|^[0-9a-fA-F]{64}\$" \
    | awk '{print $1}' | head -1)

  if [ -z "$_dm_expected" ]; then
    echo "WARNING: no published checksum found at '$_dm_manifest'; downloading without verification." >&2
    download_verified "$_dm_url" "$_dm_dest" "SKIP"
    return $?
  fi

  download_verified "$_dm_url" "$_dm_dest" "$_dm_expected"
}
