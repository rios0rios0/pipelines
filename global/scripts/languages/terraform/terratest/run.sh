#!/usr/bin/env sh
set -eu

# Runs the consumer's Terratest Go suite and publishes the results as
# JUnit XML. Complements the `terra-test` runner (native `terraform test`
# over modules) by covering the use cases that `terraform test` can't:
#
#   - Stacks and environments that reference private git SSH modules or
#     resolve dependency outputs (a real `terraform validate` would need
#     credentials). Terratest can run `terraform fmt`, `terraform validate
#     -no-color -backend=false -get=false`, and drive the HCL parser
#     directly (github.com/hashicorp/hcl/v2/hclparse) — none require
#     cloud credentials.
#   - Cross-module invariants (every stack must pin `required_version`,
#     every customer dir must match `{id}-{alias}`, etc.) which are hard
#     to express in a .tftest.hcl file.
#
# Convention: the consumer puts Go test files under `tests/terratest/`
# with a go.mod in that directory. The runner:
#
#   1. Auto-installs `go-junit-report` if the agent doesn't have it,
#      rather than forcing every consumer to pre-provision it.
#   2. Runs `go test -v ./...` from tests/terratest/.
#   3. Pipes the output through go-junit-report to
#      $REPORT_PATH/junit-terratest.xml.
#   4. Propagates the non-zero exit status (via -set-exit-code) so CI
#      fails on a red test.
#
# Skipped silently if tests/terratest/ doesn't exist — consumers opt in
# by creating the directory.

REPORT_PATH="${REPORT_PATH:-build/reports}"
TESTS_DIR="${TESTS_DIR:-tests/terratest}"
JUNIT="${REPORT_PATH}/junit-terratest.xml"

if [ ! -d "${TESTS_DIR}" ]; then
  echo "No ${TESTS_DIR}/ directory; skipping terratest runner."
  exit 0
fi
if [ -z "$(ls "${TESTS_DIR}"/*.go 2>/dev/null)" ]; then
  echo "No Go test files in ${TESTS_DIR}/; skipping terratest runner."
  exit 0
fi

mkdir -p "${REPORT_PATH}"

# Ensure GOPATH/bin is on PATH so a fresh `go install` is visible in the
# same invocation. `go env GOPATH` is portable across macOS/Linux and
# every Go version.
GOBIN="$(go env GOPATH)/bin"
export PATH="${GOBIN}:${PATH}"

if ! command -v go-junit-report > /dev/null 2>&1; then
  echo "Installing go-junit-report..."
  go install github.com/jstemmer/go-junit-report/v2@latest
fi

echo "Running terratest suite in ${TESTS_DIR}/..."
# `-set-exit-code` makes go-junit-report return the same exit status as
# `go test`, so CI fails when a test fails even though go test's output
# has been consumed by the pipe.
(
  cd "${TESTS_DIR}"
  go test -v ./...
) 2>&1 | go-junit-report -set-exit-code > "${JUNIT}"
rc=$?

echo "JUnit report: ${JUNIT}"
echo "terratest exit code: ${rc}"
exit "${rc}"
