#!/usr/bin/env sh
# Check (or auto-fix) the Terragrunt file-ordering standard for a repo.
#
# Usage:
#   run.sh                       # check the current repo; fail CI on drift
#   run.sh --fix                 # rewrite files into the canonical order
#   run.sh --repo-dir /path      # target a specific repo root
#   run.sh --config FILE         # use a specific .terraform-order.json
#
# Enforces (see the checker's internal/cli package for the full contract):
#   * environments/**/root.hcl  -- dependency blocks + inputs grouped by
#                                  ascending dependency number
#   * stacks/*/variables.tf      -- `// SET ON .HCL` before `// SET ON .ENV`,
#                                  .HCL vars ordered by dependency number
#   * **/providers.tf            -- providers ordered heaviest -> lightest
#   * stacks/*/outputs.tf        -- outputs ordered by main*.tf declaration order
#   * terragrunt inputs          -- every input declared as a stack variable
#
# Emits build/reports/junit-order-check.xml (override the directory via
# REPORT_PATH) so CI providers render results in their Tests tab. The checker
# is Go, built from this checkout on every run (see
# global/scripts/shared/go-helper.sh); it needs a Go toolchain, 1.25 or newer,
# and nothing else -- no Terraform.
set -eu

if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/shared/go-helper.sh"
go_helper_run global/scripts/languages/terraform/order-check "$@"
