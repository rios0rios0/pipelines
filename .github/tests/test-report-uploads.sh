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
# below selects its own lines from the output by prefix.
FINDINGS="$(/usr/bin/env python3 - <<'PY'
import glob, os, sys
try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML is required to read the workflows\n")
    sys.exit(2)

# Stages whose uploaded files ARE the job's product rather than a report about it.
DELIVERABLES = {
    'github/dart/stages/40-delivery/build/action.yaml',
}

# Stages whose tool must leave a report behind when it exits 0; each carries a
# `Verify Report` step immediately before its upload.
MANDATORY = {
    'github/global/stages/20-security/gitleaks/action.yaml',
    'github/global/stages/20-security/semgrep/action.yaml',
    'github/golang/stages/20-security/govulncheck/action.yaml',
    'github/java/stages/10-code-check/proguard/action.yaml',
    'github/javascript/stages/10-code-check/knip/action.yaml',
    'github/python/stages/10-code-check/vulture/action.yaml',
}

def step_lists(relative, document):
    runs = document.get('runs') or {}
    if runs.get('using') == 'composite':
        yield relative, runs.get('steps') or []
    for job_id, job in (document.get('jobs') or {}).items():
        yield '%s :: job %s' % (relative, job_id), (job or {}).get('steps') or []

files = sorted(glob.glob('github/**/action.yaml', recursive=True)
               + glob.glob('.github/workflows/*.yaml'))
verified = set()
for relative in files:
    with open(relative, encoding='utf-8') as handle:
        document = yaml.safe_load(handle) or {}
    for where, steps in step_lists(relative, document):
        for index, step in enumerate(steps):
            if not str(step.get('uses', '')).startswith('actions/upload-artifact@'):
                continue
            label = '%s :: step %d (%s)' % (where, index, step.get('name', 'unnamed'))
            optional = step.get('continue-on-error') is True
            with_ = step.get('with') or {}
            if relative in DELIVERABLES:
                if optional:
                    print('deliverable\t%s uploads the job\'s product but is continue-on-error' % label)
                continue
            if not optional:
                print('optional\t%s is not continue-on-error' % label)
            if optional and with_.get('if-no-files-found') == 'error':
                print('silent\t%s says `if-no-files-found: error` under continue-on-error, which fails nothing' % label)
            previous = steps[index - 1] if index > 0 else {}
            if previous.get('name') == 'Verify Report':
                verified.add(relative)
                if 'if' in previous:
                    print('verify\t%s: `Verify Report` must run on the default success() condition' % label)
                expected = str(with_.get('path', '')).rstrip('/')
                actual = str((previous.get('env') or {}).get('REPORT_DIR', ''))
                if actual != expected:
                    print('verify\t%s: `Verify Report` checks %r, the upload publishes %r' % (label, actual, expected))

for relative in sorted(MANDATORY - verified):
    print('verify\t%s has no `Verify Report` step right before its upload' % relative)
for relative in sorted(verified - MANDATORY):
    print('verify\t%s has a `Verify Report` step but is missing from MANDATORY in this test' % relative)
PY
)" || { echo -e "${RED}Could not read the workflows${NC}"; exit 1; }

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

echo "=============================="
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ] && echo -e "${GREEN}GitHub Actions report-upload contract holds${NC}"
[ "$TESTS_FAILED" -eq 0 ]
