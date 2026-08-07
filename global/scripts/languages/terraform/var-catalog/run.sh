#!/usr/bin/env sh
# Generate (or verify) the shared `variable` declarations each stack needs.
#
# Usage:
#   run.sh                       # write stacks/<stack>/variables-shared.tf
#   run.sh --check               # fail if the committed output is stale (CI gate)
#   run.sh --report              # print what would change; write nothing
#   run.sh --repo-dir /path      # target a specific repo root
#
# The canonical bodies live in the consumer's own `.terraform-var-catalog.hcl`,
# the same split the sibling order-check uses (generic script here,
# repo-specific data in the consumer). Stdlib-only: the sole runtime dependency
# is python3, matching the sibling tftest-gen.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
PY="${SCRIPT_DIR}/gen_shared_variables.py"

if [ ! -f "${PY}" ]; then
  echo "var-catalog: ${PY} not found" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "var-catalog: python3 is required" >&2
  exit 1
fi

exec python3 "${PY}" "$@"
