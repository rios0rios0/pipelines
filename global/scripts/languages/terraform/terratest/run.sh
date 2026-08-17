#!/usr/bin/env sh
set -eu

# GitLab CI/CD leverages this variable to source shared helpers from the
# pipelines checkout. Matches the preamble used by every other run.sh.
if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"

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

# Ensure the directory `go install` actually writes to is on PATH, so a fresh
# install is visible in the same invocation. It is `GOBIN` when that is set and
# `GOPATH/bin` otherwise; assuming `GOPATH/bin` meant that on a runner with
# `GOBIN` configured the binary landed somewhere never added to PATH, and the
# terratest run then failed on a missing `go-junit-report`.
GOBIN_DIR="$(go env GOBIN)"
[ -n "$GOBIN_DIR" ] || GOBIN_DIR="$(go env GOPATH)/bin"
export PATH="${GOBIN_DIR}:${PATH}"

# Installed UNCONDITIONALLY, not only when the binary is missing. A persistent
# runner with an older `go-junit-report` would otherwise keep it, so the pin
# would name a version that never ran. `go install` at an exact version is
# idempotent and served from the module cache, so this is cheap when already
# current -- and it is the same "always install" shape this script had before
# the pin, which resolved `@latest` on every run.
echo "Installing go-junit-report $GO_JUNIT_REPORT_VERSION..."
go install "github.com/jstemmer/go-junit-report/v2@$GO_JUNIT_REPORT_VERSION"

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
