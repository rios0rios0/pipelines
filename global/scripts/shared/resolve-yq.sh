#!/usr/bin/env sh
# shellcheck shell=sh
# shellcheck disable=SC2034  # `YQ` is consumed by the scripts that SOURCE this file
#
# Resolves mikefarah/yq -- the only `yq` these pipelines can use.
# SOURCED, never executed -- it carries no `run.sh` name and no executable bit.
#
# `yq` is TWO UNRELATED PROGRAMS SHARING A NAME:
#
#   mikefarah/yq  a Go YAML processor, invoked `yq eval '<expression>' <file>`
#   kislyuk/yq    a jq wrapper, which reads the expression as a FILENAME and
#                 rejects `eval` outright
#
# Which one answers `yq` is decided by the machine, not by anything in this
# repository. GitHub's `ubuntu-latest` preinstalls mikefarah's; Debian and
# Ubuntu's own `yq` package and `pip install yq` are kislyuk's. So the same
# command is correct on one runner and nonsense on the next.
#
# Accepting whichever one is on PATH is how a project's `.golangci.yml` silently
# stopped being applied: the merge steps ended in `2>/dev/null || true`, the
# wrong `yq` produced empty output instead of an error, the repository's
# `enable`, `disable` and `linters-settings` were all dropped, and the run
# carried on against the shared default alone. The symptom is a wall of findings
# for linters the project had deliberately disabled or retuned -- with nothing
# anywhere saying the config was ignored.
#
# This file exists so that resolution happens ONCE, in one place. It used to
# live inside golangci-lint/run.sh, which meant the test suite that covers that
# script had no equivalent and called a bare `yq` in its own assertions -- so
# `make test` passed on GitHub's runners and failed on any Debian-ish
# workstation, for a reason that looks nothing like the real cause. A second
# copy of this logic is how the discrepancy would come back.

# Overridable so an operator can respond to an upstream issue without waiting
# for a release here. The digest that pairs with it is the subject of a
# follow-up change; see the note on `download_verified` below.
YQ_VERSION="${YQ_VERSION:-v4.47.1}"

# yq_is_mikefarah <command>
#
# mikefarah/yq prints its own repository URL in the version banner; kislyuk/yq
# prints a bare `yq <version>`. Matching the URL is what separates them, since
# both answer `--version` and both exit 0.
yq_is_mikefarah() {
  [ -n "$1" ] && "$1" --version 2>&1 | grep -q 'mikefarah'
}

# resolve_yq [target_dir]
#
# Sets YQ to a usable mikefarah/yq and returns 0, or returns non-zero having
# explained why on stderr. The caller decides whether that is fatal, because it
# is fatal in production and merely a skip in a test.
#
# A mikefarah `yq` already on PATH is used as-is; otherwise the pinned release
# is downloaded into `target_dir` (default `./bin`, which is what
# golangci-lint/run.sh has always used and what its tests assert on).
resolve_yq() {
  _ry_dir="${1:-./bin}"

  if command -v yq > /dev/null 2>&1 && yq_is_mikefarah yq; then
    # Resolved to an absolute path rather than left as the bare word, so a
    # caller that later prepends to PATH -- which the merge tests do
    # deliberately -- cannot end up running a different binary than the one
    # this function approved.
    YQ="$(command -v yq)"
    return 0
  fi

  mkdir -p "$_ry_dir" || {
    echo "resolve_yq: could not create '$_ry_dir'" >&2
    return 1
  }

  case "$(uname -s)" in
    Darwin) _ry_os='darwin' ;;
    *) _ry_os='linux' ;;
  esac
  case "$(uname -m)" in
    aarch64 | arm64) _ry_arch='arm64' ;;
    *) _ry_arch='amd64' ;;
  esac

  # `SKIP` is deliberate and TEMPORARY, and it is the honest encoding of what
  # this download has always done: it was previously a bare `curl` inside
  # run.sh, verified against nothing. Routing it through the shared helper does
  # not make it verified -- it makes the gap ANNOUNCE ITSELF on every use
  # instead of hiding in a second downloader nobody had cause to read. The
  # follow-up change adds `YQ_PINNED_VERSION` and the per-arch digests to
  # pinned-versions.sh and replaces `SKIP` with `$(pinned_digest YQ ...)`.
  if ! download_verified \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${_ry_os}_${_ry_arch}" \
    "$_ry_dir/yq" \
    "SKIP"; then
    echo "resolve_yq: could not download mikefarah/yq ${YQ_VERSION} for ${_ry_os}/${_ry_arch}" >&2
    return 1
  fi

  chmod +x "$_ry_dir/yq" || {
    echo "resolve_yq: could not make the downloaded yq executable" >&2
    return 1
  }

  YQ="$_ry_dir/yq"
  return 0
}
