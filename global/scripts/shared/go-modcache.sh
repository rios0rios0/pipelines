#!/usr/bin/env sh

# Resolves GOPATH for the Go runners and keeps Go's module cache out of $TMPDIR.
#
# GitLab CI/CD only supports caching inside the project directory, so GOPATH
# falls back to "$(pwd)/.go" when the caller has not set one. Go derives
# GOMODCACHE from GOPATH, which means that fallback silently follows the working
# directory -- including into a temporary directory, whenever these scripts are
# invoked from one.
#
# That combination breaks anything that later tries to clean the temp directory.
# Go writes module cache entries as 0400 files inside 0500 directories, and
# unlinking a child requires its *parent* to be writable, so none of them can be
# removed without a chmod first; a plain `rm -rf` fails with EACCES on every
# entry.
#
# On Android/Termux the consequence is fatal rather than untidy.
# TermuxService.onDestroy() calls clearTermuxTMPDIR(), which collects one stack
# trace per entry it fails to delete and then stringifies the batch, so a single
# leaked cache (~8k entries) is enough to exhaust the 256 MB heap and kill the
# app on exit -- surfacing as an OutOfMemoryError in the Android logger, nowhere
# near Go.
#
# Relocating the cache is safe and costs nothing: it is content-addressed and
# immutable, which is why GOMODCACHE was split out of GOPATH in Go 1.15.

# Sets GOPATH when the caller has not, then redirects GOMODCACHE when the
# resulting cache would land under $TMPDIR.
#
# This is a no-op on CI runners, where the workspace is never inside the temp
# directory, and a no-op whenever the caller has made either choice explicitly.
#
# The containment check is textual, so a $TMPDIR reached through a symlink is
# not detected. That is deliberate: the comparison must work for a GOPATH that
# does not exist yet, which rules out canonicalising with `pwd -P`.
resolve_go_paths() {
  go_modcache_tmp_root=""

  # GitLab CI/CD just supports cache in the project directory
  if [ -z "${GOPATH+x}" ]; then
    GOPATH="$(pwd)/.go"
    export GOPATH
  fi

  # An explicit GOMODCACHE means the caller has already decided where it goes.
  if [ -n "${GOMODCACHE:-}" ]; then
    return 0
  fi

  go_modcache_tmp_root="${TMPDIR:-/tmp}"
  # Strip any trailing slash so the prefix comparison below is exact.
  while :; do
    case "$go_modcache_tmp_root" in
      ?*/) go_modcache_tmp_root="${go_modcache_tmp_root%/}" ;;
      *) break ;;
    esac
  done

  if [ -z "$go_modcache_tmp_root" ]; then
    return 0
  fi

  # Nothing to do unless GOPATH sits inside the temp directory. The trailing
  # slash on GOPATH makes "$GOPATH" == "$tmp_root" match too, which is a case
  # worth catching rather than excluding.
  case "$GOPATH/" in
    "$go_modcache_tmp_root"/*) ;;
    *) return 0 ;;
  esac

  # Without a home directory there is nowhere better to put it, and writing it
  # somewhere else under $TMPDIR would not help.
  if [ -z "${HOME:-}" ]; then
    echo "WARNING: GOPATH is under \$TMPDIR ($go_modcache_tmp_root) but \$HOME is unset;" >&2
    echo "         leaving GOMODCACHE at Go's default. The module cache will be written" >&2
    echo "         read-only inside the temp directory and cannot be deleted without a chmod." >&2
    return 0
  fi

  GOMODCACHE="$HOME/go/pkg/mod"
  export GOMODCACHE

  echo "GOPATH is under \$TMPDIR ($go_modcache_tmp_root); redirecting GOMODCACHE to $GOMODCACHE" >&2
  echo "so the read-only module cache is not written somewhere that cannot clean it up." >&2

  return 0
}
