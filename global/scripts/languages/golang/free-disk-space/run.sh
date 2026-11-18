#!/usr/bin/env sh
# Free disk space on a Microsoft-hosted Ubuntu agent before a Go test job fills it.
#
# A hosted agent is a fresh VM whose disk starts most of the way full -- Microsoft guarantees only
# about 10 GB free, and the disk cannot be enlarged -- because the image carries toolchains for
# every language. A Go test job that compiles a large module twice (the unit phase, then the
# integration phase with coverage instrumentation) and pulls several GB of container images for its
# integration suites runs out of that headroom: the agent warns `Free disk space on / is lower than
# 5%`, a database container's own disk guard turns read-only, and the next large write ends in `No
# space left on device`, in whichever step happens to write last.
#
# So, on request (the Azure DevOps Go template's `FREE_DISK_SPACE` parameter), this removes what a
# Go job never uses, logging `df -h` before and after and what each removal freed:
#   - the Android SDK, GHC (both the old `/opt/ghc` and GHCup's `/usr/local/.ghcup`) and Swift;
#   - the .NET SDKs, but NOT the .NET runtime: the same job's `PublishCodeCoverageResults@2` runs a
#     .NET program to publish the coverage report, and skips the publication -- with no more than a
#     warning -- when it finds no `dotnet` on PATH. `dotnet`, `host/` and `shared/` stay, and the
#     SDKs, their packs, templates and manifests, nearly all of the space, go;
#   - the CodeQL bundles of the agent's tool cache (the security stage's CodeQL job runs on an agent
#     of its own);
#   - the Docker images the image pre-pulls. It runs before the tests pull theirs, and an image a
#     container uses -- a service container of the job -- is never removed.
# Every path is checked first, so one the image no longer carries is skipped, not an error, and a
# removal that fails is reported and left: freeing space is housekeeping, and never fails the job.
#
# It deletes toolchains from the machine it runs on, so it is meant for a hosted agent, thrown away
# after the job. On a self-hosted agent they would stay deleted for every later job.
#
# Environment:
#   FREE_DISK_SPACE_ROOT  prefix of every path removed (default empty, the agent's own root); the
#                         test suite points it at a fixture tree
#   FREE_DISK_SPACE_PATH  filesystem whose usage is logged (default /)
#   AGENT_TOOLSDIRECTORY  the agent's tool cache, set by Azure DevOps (default /opt/hostedtoolcache)

ROOT="${FREE_DISK_SPACE_ROOT:-}"
TARGET="${FREE_DISK_SPACE_PATH:-/}"
TOOL_CACHE="${AGENT_TOOLSDIRECTORY:-$ROOT/opt/hostedtoolcache}"
DOTNET="$ROOT/usr/share/dotnet"

# available_kb: the space left on the target filesystem, in KiB; empty when df cannot tell.
available_kb() {
  df -Pk "$TARGET" 2> /dev/null | awk 'NR == 2 { print $4 }'
}

# freed_since <available KiB before>: how much more is available now, as `N MiB` under a GiB and
# `X.Y GiB` from there.
freed_since() {
  awk -v before="$1" -v after="$(available_kb)" 'BEGIN {
    freed = (before == "" || after == "") ? 0 : after - before
    if (freed < 0) freed = 0
    if (freed < 1048576) printf "%d MiB", freed / 1024
    else printf "%.1f GiB", freed / 1048576
  }'
}

# as_root <command>...: runs the command as root -- directly when this already is root, through
# password-less sudo otherwise. `-n` makes sudo fail rather than wait for a password nobody types.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

# free_paths <what> <path>...: removes every given path that exists, as root, and logs what that
# freed; when none exists it says so and removes nothing.
free_paths() {
  _fp_what="$1"
  shift
  _fp_before="$(available_kb)"
  _fp_found=''
  _fp_failed=''
  for _fp_path in "$@"; do
    if [ -e "$_fp_path" ] || [ -L "$_fp_path" ]; then
      _fp_found=1
      if ! as_root rm -rf -- "$_fp_path"; then
        _fp_failed="$_fp_failed $_fp_path"
      fi
    fi
  done
  if [ -z "$_fp_found" ]; then
    echo "$_fp_what: not on this agent, nothing to remove."
  elif [ -n "$_fp_failed" ]; then
    echo "WARNING: $_fp_what: could not remove$_fp_failed; it stays. Freed $(freed_since "$_fp_before")."
  else
    echo "$_fp_what: removed, $(freed_since "$_fp_before") freed."
  fi
  unset _fp_what _fp_before _fp_found _fp_failed _fp_path
  return 0
}

START_KB="$(available_kb)"
echo "Disk usage of $TARGET before freeing space:"
df -h "$TARGET" 2> /dev/null || echo "WARNING: df could not read $TARGET."

free_paths 'Android SDK' "$ROOT/usr/local/lib/android"
free_paths '.NET SDKs (the runtime stays)' \
  "$DOTNET/sdk" "$DOTNET/sdk-manifests" "$DOTNET/packs" "$DOTNET/templates" \
  "$DOTNET/library-packs" "$DOTNET/metadata"
free_paths 'GHC' "$ROOT/opt/ghc" "$ROOT/usr/local/.ghcup"
free_paths 'Swift' "$ROOT/usr/share/swift"
free_paths 'CodeQL bundles in the tool cache' "$TOOL_CACHE/CodeQL"

if command -v docker > /dev/null 2>&1; then
  BEFORE_KB="$(available_kb)"
  if docker image prune --all --force > /dev/null 2>&1; then
    echo "Pre-pulled Docker images: removed, $(freed_since "$BEFORE_KB") freed."
  else
    echo "WARNING: Pre-pulled Docker images: docker could not prune them; they stay."
  fi
else
  echo "Pre-pulled Docker images: docker is not installed, nothing to remove."
fi

if command -v dotnet > /dev/null 2>&1; then
  echo "The .NET runtimes the coverage publication runs on:"
  dotnet --list-runtimes 2> /dev/null || echo "WARNING: dotnet could not list its runtimes."
fi

echo "Disk usage of $TARGET after freeing space ($(freed_since "$START_KB") freed in all):"
df -h "$TARGET" 2> /dev/null || echo "WARNING: df could not read $TARGET."
exit 0
