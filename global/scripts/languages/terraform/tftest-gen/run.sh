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
#
# The generator is Go, built from this checkout on every run (see
# global/scripts/shared/go-helper.sh); it needs a Go toolchain, 1.25 or newer.
# `terraform`, when on PATH, formats the generated file.
set -eu

if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/shared/go-helper.sh"
go_helper_run global/scripts/languages/terraform/tftest-gen "$@"
