#!/usr/bin/env sh
# Check (or auto-fix) the Terragrunt file-ordering standard for a repo.
#
# Usage:
#   run.sh                       # check the current repo; fail CI on drift
#   run.sh --fix                 # rewrite files into the canonical order
#   run.sh --repo-dir /path      # target a specific repo root
#   run.sh --config FILE         # use a specific .terraform-order.json
#
# Enforces (see check_order.py for the full contract):
#   * environments/**/root.hcl  -- dependency blocks + inputs grouped by
#                                  ascending dependency number
#   * stacks/*/variables.tf      -- `// SET ON .HCL` before `// SET ON .ENV`,
#                                  .HCL vars ordered by dependency number
#   * **/providers.tf            -- providers ordered heaviest -> lightest
#   * stacks/*/outputs.tf        -- outputs ordered by main*.tf declaration order
#
# Emits build/reports/junit-order-check.xml (override the directory via
# REPORT_PATH) so CI providers render results in their Tests tab. Stdlib-only:
# the only runtime dependency is python3, matching the sibling tftest-gen.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
PY="${SCRIPT_DIR}/check_order.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required on PATH" >&2
  exit 1
fi

exec python3 "$PY" "$@"
