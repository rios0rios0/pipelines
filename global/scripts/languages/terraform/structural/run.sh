#!/usr/bin/env sh
set -eu

# Runs the consumer's repo-local structural test script and publishes the
# results as JUnit XML. Complements the `terra-test` runner (native
# `terraform test` over modules) and the `terratest` runner (Go suite over
# stacks + environments) with a third tier reserved for assertions that
# are inherently project-specific:
#
#   - Customer / tenant directory naming conventions
#   - Shared `root.hcl` presence per environment stack
#   - Bootstrap config self-containedness
#   - Any other repo-convention gate that's trivial in bash but awkward
#     in Go or a `.tftest.hcl` file
#
# The runner never ships assertions itself — every consumer owns the
# content of `tests/structural.sh`. The runner contract is:
#
#   1. The consumer writes `tests/structural.sh` (any interpreter, any
#      assertions, any layout — just make it executable).
#   2. The script emits `build/reports/junit-structural.xml` in JUnit XML
#      format if it wants the results to render in the CI provider's
#      Tests tab.
#   3. The script exits non-zero on any failure; the runner propagates.
#
# Skipped silently (exit 0) when `tests/structural.sh` doesn't exist — a
# consumer without convention-level assertions doesn't see a broken stage.
# Matches the opt-in contract already established by the sibling
# `terra-test` and `terratest` runners.

SCRIPT="${STRUCTURAL_SCRIPT:-tests/structural.sh}"

if [ ! -f "${SCRIPT}" ]; then
  echo "No ${SCRIPT} found; skipping structural runner."
  exit 0
fi

if [ ! -x "${SCRIPT}" ]; then
  echo "ERROR: ${SCRIPT} exists but is not executable. Run 'chmod +x ${SCRIPT}' and retry." >&2
  exit 1
fi

echo "Running structural tests: ${SCRIPT}"
"./${SCRIPT}"
