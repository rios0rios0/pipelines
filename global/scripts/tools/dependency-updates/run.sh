#!/usr/bin/env sh
# Report every pinned third-party dependency that has a newer version upstream.
#
# Usage:
#   run.sh                    # check this repo; exit 1 when anything is stale
#   run.sh --report-only      # report without failing (exit 0 unless a lookup broke)
#   run.sh --repo-dir /path   # target a different repository root
#
# Exit codes:
#   0  every pin is current
#   1  at least one update, drifted copy, or unannotated pin
#   2  an upstream could not be consulted -- deliberately NOT reported as clean,
#      because a rate-limited API must never look like a green light
#
# Set GITHUB_TOKEN (or GH_TOKEN) before running: roughly forty of the lookups hit
# api.github.com, which allows 60 requests/hour unauthenticated and will
# otherwise start returning 403 part-way through.
#
# Emits build/reports/dependency-updates/{json,md} (override via REPORT_PATH).
# Stdlib-only python3, matching the sibling order-check and tftest-gen runners.
set -eu

if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
# Defaulted before sourcing `cleanup.sh`, which reads `$REPORT_PATH` unguarded.
# This script runs under `set -u` (the sibling tool runners do not), so an unset
# variable there aborts before the report directory is ever created.
REPORT_PATH="${REPORT_PATH:-build/reports}"
export REPORT_PATH
TOOL_NAME="dependency-updates" . "$SCRIPTS_DIR/global/scripts/shared/cleanup.sh"

if ! command -v python3 > /dev/null 2>&1; then
  echo "ERROR: python3 is required on PATH" >&2
  exit 1
fi

exec python3 "$SCRIPTS_DIR/global/scripts/tools/dependency-updates/check_updates.py" \
  --report "$REPORT_PATH" "$@"
