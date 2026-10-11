#!/usr/bin/env sh
# shellcheck shell=sh
#
# Builds and runs one of this repository's Go helpers from the checkout it is
# sourced from. SOURCED, never executed -- it carries no `run.sh` name and no
# executable bit.
#
# The helpers are Go rather than Python: compiled and type-checked, tested with
# the same discipline as every Go project here, and linted by the same golden
# configuration they enforce. They are built from SOURCE on every run, from the
# checkout the consumer pinned, so the code that runs is always the code that
# was reviewed at that ref -- there is no separately published binary to drift
# from it, and no release step to forget.
#
# The module is standard-library only at run time: building a helper downloads
# no third-party module, so the build needs a Go toolchain and nothing else from
# the network (test-only dependencies are never built into a helper).
#
#   go_helper_run <package path from the repository root> [arguments...]
#
# Environment the build pins, whatever the caller's shell says:
#
#   CGO_ENABLED=0           no C compiler needed, on any image
#   GOFLAGS=-mod=readonly   go.mod and go.sum are never rewritten by a build
#   GOWORK=off              a go.work above the checkout cannot change what builds

go_helper_run() {
  _ghr_package="$1"
  shift

  if ! command -v go > /dev/null 2>&1; then
    echo "ERROR: Go is required to run $_ghr_package -- install Go 1.25 or newer (https://go.dev/dl/)." >&2
    return 1
  fi

  _ghr_dir="$(mktemp -d)" || return 1
  if ! CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
    go -C "$SCRIPTS_DIR" build -trimpath -o "$_ghr_dir/helper" "./$_ghr_package"; then
    rm -rf "$_ghr_dir"
    echo "ERROR: could not build $_ghr_package from $SCRIPTS_DIR" >&2
    return 1
  fi

  _ghr_status=0
  "$_ghr_dir/helper" "$@" || _ghr_status=$?
  rm -rf "$_ghr_dir"
  return "$_ghr_status"
}
