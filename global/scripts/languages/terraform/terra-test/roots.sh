#!/usr/bin/env sh

# Sourced, never executed: the one definition of which ROOT modules
# `TERRA_TEST_ROOTS` adds to the terra-test tier. `terra-test/run.sh` runs what
# this lists and `test-all/run.sh` asks it whether tier 1 has anything to run,
# so the two cannot disagree -- the orchestrator never detects a test the runner
# then skips, nor skips a repository whose only tests the runner would have run.

# Prints one root module per line, sorted and de-duplicated: every directory at
# any depth under the space-separated `TERRA_TEST_ROOTS` that holds a
# `*.tftest.hcl` DIRECTLY in its `tests/` directory. Prints nothing when the
# variable is empty or names nothing that exists.
#
# - Directly, because that is where `terraform test` looks, and it is the same
#   non-recursive rule the module loop applies to `modules/<name>/tests/`. A
#   `tests/e2e/*.tftest.hcl` is an apply-time suite this tier never runs; a
#   pattern that matched it would hand the runner the test FILE as a root.
# - Vendored and derived trees are pruned at any depth -- `terraform init`
#   copies module sources into `.terraform/`, and Terragrunt copies whole
#   stacks, `tests/` included, into `.terragrunt-cache/`. Same set as
#   `VENDORED_DIRS` in `terra_coverage.py`.
# - A leading `./` is stripped, so `.`, `./stacks` and `stacks` name a root the
#   same way. The runner names each JUnit file after this path.
# - `modules/<name>` is dropped: the module loop already runs it, so a broad
#   root such as `.` cannot run a module's tests twice.
terra_test_root_dirs() {
  # shellcheck disable=SC2086 # word splitting is intended: these are separate paths
  for terra_test_search_root in ${TERRA_TEST_ROOTS:-}; do
    [ -d "${terra_test_search_root}" ] || continue
    find "${terra_test_search_root}" \
      \( -name .terraform -o -name .terragrunt-cache -o -name .external_modules -o -name .git \) -prune \
      -o -type f -name '*.tftest.hcl' -print
  done \
    | sed -n 's|/tests/[^/]*\.tftest\.hcl$||p' \
    | sed -e 's|^\(\./\)*||' -e '/^modules\/[^/]*$/d' \
    | sort -u
}
