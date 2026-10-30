#!/usr/bin/env bash
# Runs this repository's validation: every suite in this directory, `test-<name>.sh`, then the Go
# helpers' unit tests (`go-helpers`, `go test -count=1 ./...`). `make test` runs them all;
# `make test ONLY="workflow-composition supply-chain"` runs the named ones. Every suite runs even
# after one fails, and the exit status is non-zero when any did.
#
# A new suite is a new `test-<name>.sh` here: nothing else lists the suites.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1

suites=("$@")
if [[ "${#suites[@]}" -eq 0 ]]; then
  for script in .github/tests/test-*.sh; do
    name="${script##*/test-}"
    suites+=("${name%.sh}")
  done
  suites+=('go-helpers')
fi

failed=()
for suite in "${suites[@]}"; do
  echo "=== ${suite}"
  if [[ "$suite" == 'go-helpers' ]]; then
    go test -count=1 ./... || failed+=("$suite")
  elif [[ -f ".github/tests/test-${suite}.sh" ]]; then
    ".github/tests/test-${suite}.sh" || failed+=("$suite")
  else
    echo "no suite named '${suite}' in .github/tests" >&2
    failed+=("$suite")
  fi
done

if [[ "${#failed[@]}" -gt 0 ]]; then
  echo "FAILED: ${failed[*]}" >&2
  exit 1
fi
echo "All ${#suites[@]} suites passed."
