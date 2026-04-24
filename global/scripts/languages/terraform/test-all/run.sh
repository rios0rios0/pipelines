#!/usr/bin/env sh
set -eu

# GitLab CI/CD leverages this variable to source shared helpers from the
# pipelines checkout. Matches the preamble used by every other run.sh.
if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

# Unified Terraform/Terra test runner. Orchestrates the two existing tiers
# (`terra-test` over `modules/*/tests/*.tftest.hcl` and `terratest` over
# `tests/terratest/*.go`) behind a single entry point so every platform can
# publish one JUnit and one coverage artifact per build.
#
# Behavior:
#   1. Detect which tiers the consumer actually has.
#   2. If neither tier has tests, exit 0 with an empty JUnit so CI publishers
#      don't fail with "no test results". Repos with no tests are a valid
#      state — a shared-toolbox-style stack repo with no modules is common.
#   3. Run each applicable tier in sequence (terra-test first, then
#      terratest). Each tier's own runner still emits its own artifacts.
#   4. Merge both JUnit files into `${REPORT_PATH}/junit-terra-all.xml` for
#      the single `PublishTestResults@2` / GitLab `artifacts:reports:junit` /
#      GitHub `actions/upload-artifact` consumer.
#   5. Propagate a non-zero exit from either tier so CI correctly fails.
#
# Outputs (under $REPORT_PATH, default build/reports/):
#   - terra-tests.xml          per-module `terraform test` aggregate (tier 1)
#   - terra-coverage.{md,json,xml}  terra-test coverage (tier 1)
#   - junit-terratest.xml      terratest Go suite (tier 2)
#   - junit-terra-all.xml      merged JUnit across both tiers (this runner)
#
# Why a merged JUnit instead of two `PublishTestResults` tasks?
# Azure DevOps merges multiple publishes into one Tests tab, but GitLab CI
# and GitHub Actions don't — a second `reports: junit` / `upload-artifact`
# overwrites the first. The merged file is the portable contract.

REPORT_PATH="${REPORT_PATH:-build/reports}"
# Honor the same `TESTS_DIR` override that `terratest/run.sh` exposes so
# consumers with a non-standard Terratest location (e.g., `test/terratest/`
# or `e2e/terratest/`) get consistent detection + execution from both the
# orchestrator and the tier runner. Defaults match the tier runner.
TESTS_DIR="${TESTS_DIR:-tests/terratest}"
MERGED_JUNIT="${REPORT_PATH}/junit-terra-all.xml"
TERRA_JUNIT="${REPORT_PATH}/terra-tests.xml"
TERRATEST_JUNIT="${REPORT_PATH}/junit-terratest.xml"

TERRA_TEST_RUNNER="${SCRIPTS_DIR}/global/scripts/languages/terraform/terra-test/run.sh"
TERRATEST_RUNNER="${SCRIPTS_DIR}/global/scripts/languages/terraform/terratest/run.sh"

# ---------- Detect which tiers have tests ----------
has_terra_tests=0
has_terratest=0

if [ -d modules ]; then
  for mod in modules/*/; do
    # POSIX `sh` has no nullglob — an empty modules/ still iterates once
    # with the literal glob. Skip that phantom.
    [ -d "${mod}" ] || continue
    if [ -d "${mod}tests" ] && ls "${mod}tests"/*.tftest.hcl > /dev/null 2>&1; then
      has_terra_tests=1
      break
    fi
  done
fi

if [ -d "${TESTS_DIR}" ] && ls "${TESTS_DIR}"/*.go > /dev/null 2>&1; then
  has_terratest=1
fi

mkdir -p "${REPORT_PATH}"

if [ "${has_terra_tests}" -eq 0 ] && [ "${has_terratest}" -eq 0 ]; then
  echo "No Terraform tests detected:"
  echo "  - no modules/*/tests/*.tftest.hcl files"
  echo "  - no ${TESTS_DIR}/*.go files"
  echo "Emitting an empty JUnit so the CI publisher doesn't fail and skipping."
  # Valid empty JUnit keeps `PublishTestResults@2` / GitLab / GitHub happy.
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="terra-all"/>\n' > "${MERGED_JUNIT}"
  exit 0
fi

# ---------- Run tier 1: terra-test ----------
rc_terra_test=0
if [ "${has_terra_tests}" -eq 1 ]; then
  echo "=== Tier 1: terraform test (terra-test) ==="
  REPORT_PATH="${REPORT_PATH}" sh "${TERRA_TEST_RUNNER}" || rc_terra_test=$?
else
  echo "Tier 1 skipped: no modules/*/tests/*.tftest.hcl detected."
fi

# ---------- Run tier 2: terratest ----------
rc_terratest=0
if [ "${has_terratest}" -eq 1 ]; then
  echo
  echo "=== Tier 2: terratest (Go suite under ${TESTS_DIR}/) ==="
  REPORT_PATH="${REPORT_PATH}" TESTS_DIR="${TESTS_DIR}" sh "${TERRATEST_RUNNER}" || rc_terratest=$?
else
  echo "Tier 2 skipped: no ${TESTS_DIR}/*.go detected."
fi

# ---------- Merge JUnit files ----------
# A plain concatenation of two JUnit files breaks the XML (two `<?xml?>`
# prologs, two root `<testsuites>` elements). Strip the prolog and the
# outer `<testsuites ...>`/`</testsuites>` wrappers from each, then wrap
# every remaining `<testsuite>` block in one outer `<testsuites>` root.
{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="terra-all">\n'
  for f in "${TERRA_JUNIT}" "${TERRATEST_JUNIT}"; do
    if [ -f "${f}" ]; then
      sed -e '/<?xml/d' \
          -e 's|<testsuites[^>]*>||g' \
          -e 's|</testsuites>||g' \
          "${f}"
    fi
  done
  printf '</testsuites>\n'
} > "${MERGED_JUNIT}"

echo
echo "=== terra test:all summary ==="
echo "  merged JUnit          : ${MERGED_JUNIT}"
[ -f "${REPORT_PATH}/terra-coverage.xml" ] && \
  echo "  coverage (Cobertura)  : ${REPORT_PATH}/terra-coverage.xml"
[ -f "${REPORT_PATH}/terra-coverage.md" ] && \
  echo "  coverage (Markdown)   : ${REPORT_PATH}/terra-coverage.md"
echo "  tier 1 (terra-test)   : exit=${rc_terra_test} (ran=${has_terra_tests})"
echo "  tier 2 (terratest)    : exit=${rc_terratest} (ran=${has_terratest})"

# Preserve the original failure code from whichever tier failed first so the
# CI surface shows a meaningful exit status instead of a generic 1.
if [ "${rc_terra_test}" -ne 0 ]; then
  exit "${rc_terra_test}"
fi
exit "${rc_terratest}"
