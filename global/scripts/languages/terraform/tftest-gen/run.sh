#!/usr/bin/env sh
# Generate tests/smoke.tftest.hcl for a single terraform-module repo.
#
# Usage:
#   run.sh                     # generate in the current repo root
#   run.sh --force             # overwrite even hand-written tests (dangerous)
#   run.sh --repo-dir /path    # target a specific repo root
#
# Companion to `terraform test` (via `terra-test/run.sh`). Produces a
# plan-time smoke + per-variable-validation coverage suite with mocked
# providers so no credentials or network access are required.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
PY="${SCRIPT_DIR}/gen_smoke_tests.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required on PATH" >&2
  exit 1
fi

exec python3 "$PY" "$@"
