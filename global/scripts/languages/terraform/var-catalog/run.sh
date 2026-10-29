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
# repo-specific data in the consumer).
#
# The generator is Go, built from this checkout on every run (see
# global/scripts/shared/go-helper.sh); it needs a Go toolchain, 1.25 or newer,
# and nothing else.
set -eu

if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

. "$SCRIPTS_DIR/global/scripts/shared/go-helper.sh"
go_helper_run global/scripts/languages/terraform/var-catalog "$@"
