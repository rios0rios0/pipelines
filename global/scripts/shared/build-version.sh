#!/usr/bin/env sh
# shellcheck shell=sh
#
# Resolves the version a build hands its image, for a pipeline that opts into
# passing one to the Dockerfile as a build argument.
# SOURCED, never executed -- it carries no `run.sh` name and no executable bit.
#
# A Dockerfile that compiles its version in -- `ARG VERSION=dev`, then
# `-ldflags "-X <package>.Version=${VERSION}"` or an application constant --
# reports its DEFAULT unless the build passes the argument, and no build here
# passed it. Every image therefore said `dev`: the startup log, a version
# endpoint and an error tracker's `release` read the same word for every
# deploy, so nothing could tie an event to the build that raised it.
#
# ONE IMPLEMENTATION for every caller, because the value is only worth having if
# it is the SAME string wherever the same commit is built. A commit is routinely
# built twice -- the image delivery pushes one to the registry, and a host such
# as Fly.io builds its own from source -- and two spellings of one commit file
# one release under two names.

# build_version [explicit]
#
# Prints the version and returns 0, or prints nothing and returns 1. In order:
#
#   1. `explicit`, when non-empty -- a version the caller already knows, such as
#      the tag a release job has just cut on the default branch, before any tag
#      build of it exists;
#   2. the tag, on a tag build: `GITHUB_REF_NAME` when `GITHUB_REF_TYPE` is
#      `tag`, `CI_COMMIT_TAG` on GitLab, and `BUILD_SOURCEBRANCH` minus its
#      `refs/tags/` prefix on Azure DevOps. Only the prefix goes, so a tag such
#      as `release/1.2.3` comes out whole, the way the other two platforms report
#      it -- Azure's own `Build.SourceBranchName` would keep only `1.2.3`;
#   3. the commit, cut to its first 7 characters: `GITHUB_SHA`, `CI_COMMIT_SHA`
#      or `BUILD_SOURCEVERSION`, else `git rev-parse HEAD`. A fixed length rather
#      than `git rev-parse --short`, whose length grows with the object count of
#      the clone it runs in, so a shallow CI clone and a full one could abbreviate
#      the same commit differently. 7 is the length GitHub displays.
#
# A value carrying whitespace or a control character is refused rather than
# printed. Callers hand the version on as `NAME=VALUE`, and one of them
# (`docker/build-push-action`'s `build-args`) reads a NEWLINE-separated list, so
# a newline inside the value would smuggle in a second build argument.
build_version() {
  _bv_version="${1:-}"

  if [ -z "$_bv_version" ]; then
    if [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
      _bv_version="$GITHUB_REF_NAME"
    elif [ -n "${CI_COMMIT_TAG:-}" ]; then
      _bv_version="$CI_COMMIT_TAG"
    else
      case "${BUILD_SOURCEBRANCH:-}" in
        refs/tags/?*) _bv_version="${BUILD_SOURCEBRANCH#refs/tags/}" ;;
      esac
    fi
  fi

  if [ -z "$_bv_version" ]; then
    _bv_commit="${GITHUB_SHA:-${CI_COMMIT_SHA:-${BUILD_SOURCEVERSION:-}}}"
    if [ -z "$_bv_commit" ]; then
      _bv_commit=$(git rev-parse HEAD 2> /dev/null) || _bv_commit=""
    fi
    _bv_version=$(printf '%.7s' "$_bv_commit")
  fi

  case "$_bv_version" in
    "" | *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac

  printf '%s\n' "$_bv_version"
}

# build_arg_name_is_valid <name>
#
# True for a name a Dockerfile `ARG` can declare: a letter or an underscore,
# then letters, digits and underscores. Checked before anything is built,
# because a near miss is SILENT -- a build argument no `ARG` declares is ignored
# rather than refused, so `VERSION ` (a trailing space, invisible in a settings
# UI) would build and ship an image still reporting its default, which is the
# state opting in exists to end.
build_arg_name_is_valid() {
  case "${1:-}" in
    "" | [!A-Za-z_]* | *[!A-Za-z0-9_]*) return 1 ;;
  esac

  return 0
}

# build_arg_is_declared <dockerfile> <name>
#
# True when the Dockerfile declares `ARG <name>`, with or without a default and
# alone or beside other names on the same instruction. The keyword is matched in
# any case, as Docker reads it; the name is matched exactly, as Docker does.
# `<name>` must already have passed `build_arg_name_is_valid`: it becomes part
# of a regular expression, and only that check keeps it free of metacharacters.
#
# For a WARNING, never a refusal: it reads the file line by line, so an `ARG`
# continued from the line before is missed, and a false alarm must cost a line
# in the log rather than a release.
build_arg_is_declared() {
  grep -qE "^[[:space:]]*[Aa][Rr][Gg][[:space:]]+([^#]*[[:space:]])?$2([[:space:]=]|$)" "$1"
}
