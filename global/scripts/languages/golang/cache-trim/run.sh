#!/usr/bin/env sh
# Drop the Go build cache when the agent is low on disk, so the module cache can still be saved.
#
# A job that keeps GOCACHE inside GOPATH has its post-job cache task tar both caches together.
# On a large module the two outgrow the agent and the archive dies mid-write
# (`tar: Wrote only N of M bytes`). A cache save is ALL-OR-NOTHING, so the module cache is lost
# with it and every later run re-downloads every dependency -- the cache stops paying for itself
# exactly on the repositories that need it most.
#
# The build cache is the right one to sacrifice: it is the larger of the two, and any source or
# toolchain change invalidates it anyway, whereas `pkg/mod` is a pure network cost. Below the
# threshold both are kept and this is a no-op.
#
# Environment:
#   DISK_TRIM_THRESHOLD  percent-used at or above which the build cache is dropped (default 85)
#   DISK_TRIM_PATH       filesystem to measure (default /)
set -eu

DEFAULT_THRESHOLD=85

# Read a percentage from an environment variable, tolerating the forms a human actually writes.
#
# `85`, `85%`, `" 85 "` all mean the same thing, and the docs describe this as a percent -- so a
# consumer writing `85%` is the expected mistake, not an exotic one. Left unsanitised, `[ 95 -ge
# 85% ]` aborts the comparison, the trim never runs, and the guard silently stops guarding: the
# one failure mode this script exists to prevent. A value carrying no digit at all falls back to
# the default for the same reason.
read_percent() {
    raw="$1"
    fallback="$2"

    digits="$(printf '%s' "$raw" | tr -dc '0-9')"
    if [ -z "$digits" ]; then
        printf '%s' "$fallback"
        return
    fi

    printf '%s' "$digits"
}

threshold="$(read_percent "${DISK_TRIM_THRESHOLD:-}" "$DEFAULT_THRESHOLD")"
target="${DISK_TRIM_PATH:-/}"

used="$(df --output=pcent "$target" 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -z "$used" ]; then
    echo "Could not read disk usage for '$target' - leaving both caches alone."
    exit 0
fi

echo "Disk usage on '$target': ${used}% (trim threshold ${threshold}%)"

if [ "$used" -ge "$threshold" ]; then
    echo "Dropping the Go build cache so the module cache can still be saved."
    go clean -cache || true
    df -h "$target" | tail -1
else
    echo "Enough room to keep both caches."
fi
