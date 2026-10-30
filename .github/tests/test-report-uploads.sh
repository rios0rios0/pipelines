#!/usr/bin/env bash
set -e

# Hold the GitHub Actions report-upload contract: publishing a report never
# decides whether a job passes.
#
# Why a dedicated regression test exists:
#
# Every stage here uploads what its tool wrote under `build/reports/` with
# `actions/upload-artifact`. That call can fail for reasons that have nothing to
# do with the code under test. The one that made this test necessary is the
# account's Actions storage allowance: once the month's included storage-time is
# spent and the budget stops further usage, GitHub answers EVERY upload with
#
#   Failed to CreateArtifact: Artifact storage quota has been hit.
#
# and deleting artifacts does not bring it back -- the allowance is accrued
# GB-hours, so it returns only when the next billing month starts. On
# medhub-life, from 2026-09-17, that turned `quality:knip`, `sast:semgrep`,
# `sast:gitleaks`, `sast:hadolint` and `sca:govulncheck` red on every run with
# nothing found, and because every later stage `needs` them, `test:all`,
# `test:build` and every deployment job were SKIPPED in four repositories for a
# week. The test gate vanished and nothing said so.
#
# So every report upload is `continue-on-error`, and three things must hold at
# once:
#
#   1. No report upload can fail its job. A new stage copied from an old one,
#      or an upload added to an existing one, is caught here.
#   2. A MANDATORY report is still enforced. `if-no-files-found: 'error'` used to
#      be the only thing that failed a scan which exited 0 without writing its
#      report; under `continue-on-error` that setting fails nothing, so the rule
#      lives in a `Verify Report` step placed right before the upload.
#   3. A DELIVERABLE is not a report. When the uploaded files ARE what the job
#      exists to produce, a failed upload means nothing was delivered, and that
#      job must still fail.
#
# And one about how long an upload is kept. `actions/upload-artifact` cuts a
# `retention-days` longer than the repository's own artifact retention down to
# it, and says so in a warning annotation. Every medhub-life repository keeps
# artifacts for 2 days, so each stage asking for 10 (30 for a coverage report)
# printed "Retention days cannot be greater than the maximum allowed retention
# set within the repository. Using 2 instead." on every job that uploads, on
# every run, where it buried the annotations that mean something. So:
#
#   4. Every `retention-days` asks for the shorter of the stage's own number of
#      days and the repository's retention, `github.retention_days`; leaving it
#      out keeps the repository's retention.
#
# Nothing else in CI can catch a regression: the YAML is valid either way, and
# this repository is a template library -- the first execution is always in a
# consumer's project.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPTS_DIR" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# assert_empty <description> <captured-output>
#
# Passes when the output is empty; the offending step is printed on failure, so
# the message names what to fix rather than only that something is wrong.
assert_empty() {
  local description="$1"
  local output="$2"
  if [ -z "$output" ]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    echo "$output" | sed 's/^/         /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# One pass over every composite action and reusable workflow; each assertion
# below selects its own lines from the output by prefix. The pass is Go test
# support (`internal/testsuites/reportuploads`), built from this checkout for
# this run.
TOOL_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TOOL_DIR"' EXIT
CHECKER="$TOOL_DIR/reportuploads"
if ! CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
  go build -C "$SCRIPTS_DIR" -trimpath -o "$CHECKER" ./internal/testsuites/reportuploads; then
  echo -e "${RED}could not build ./internal/testsuites/reportuploads, so no assertion can run${NC}"
  exit 1
fi
FINDINGS="$("$CHECKER")" || { echo -e "${RED}Could not read the workflows${NC}"; exit 1; }

select_findings() {
  echo "$FINDINGS" | awk -F '\t' -v kind="$1" '$1 == kind { print $2 }'
}

echo "1. Every report upload is continue-on-error"
assert_empty "no report upload can fail its job" "$(select_findings optional)"
echo ""

echo "2. No optional upload keeps a rule it can no longer enforce"
assert_empty "no continue-on-error upload says if-no-files-found: error" "$(select_findings silent)"
echo ""

echo "3. Mandatory reports are enforced by a Verify Report step"
assert_empty "every mandatory report is verified before its upload" "$(select_findings verify)"
echo ""

echo "4. A deliverable upload still fails its job"
assert_empty "no deliverable upload is continue-on-error" "$(select_findings deliverable)"
echo ""

echo "5. No upload asks to be kept longer than the repository keeps artifacts"
assert_empty "every retention-days is bounded by the repository's retention" "$(select_findings retention)"
echo ""

echo "=============================="
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ] && echo -e "${GREEN}GitHub Actions report-upload contract holds${NC}"
[ "$TESTS_FAILED" -eq 0 ]
