#!/usr/bin/env bash
set -e

# Regression test for `global/scripts/tools/containers/detect-changed-folders.sh`,
# the matrix builder behind the Container Images workflow.
#
# Why it exists: the merge that renamed `python.3.10-pdm-bullseye` to
# `python.3.10-pdm-bookworm` listed BOTH paths in `git diff`, the deleted folder
# reached the build matrix, and `docker buildx build` failed with
# `unable to prepare context: path "global/containers/python.3.10-pdm-bullseye"
# not found`. The script must only ever emit folders that exist at the commit
# being built, and a manual dispatch naming a missing folder must fail fast.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$SCRIPTS_DIR/global/scripts/tools/containers/detect-changed-folders.sh"

PASS=0
FAIL=0
pass() { echo "[test-containers-detect] PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "[test-containers-detect] FAIL: $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

# given: a repository with two image folders, then a push that renames one of them
cd "$WORK" || exit 1
git init --quiet .
git config user.email test@example.com
git config user.name test
mkdir -p global/containers/python.3.10-pdm-bullseye global/containers/tor-proxy.latest
echo 'FROM scratch' > global/containers/python.3.10-pdm-bullseye/Dockerfile
echo 'FROM scratch' > global/containers/tor-proxy.latest/Dockerfile
git add -A && git commit --quiet -m 'initial'
BEFORE="$(git rev-parse HEAD)"
git mv global/containers/python.3.10-pdm-bullseye global/containers/python.3.10-pdm-bookworm
echo '# rebuilt' >> global/containers/tor-proxy.latest/Dockerfile
git add -A && git commit --quiet -m 'rename'
AFTER="$(git rev-parse HEAD)"

# when: the push path runs
OUT="$(EVENT_NAME=push BEFORE="$BEFORE" AFTER="$AFTER" "$SCRIPT" 2>/dev/null)"

# then: the deleted folder is absent, the renamed and modified ones are present
if echo "$OUT" | grep -q '"tag":"3.10-pdm-bullseye"'; then
  fail "push: deleted folder python.3.10-pdm-bullseye leaked into the matrix"
else
  pass "push: deleted folder is excluded from the matrix"
fi
if echo "$OUT" | grep -q '{"name":"python","tag":"3.10-pdm-bookworm"}' && echo "$OUT" | grep -q '{"name":"tor-proxy","tag":"latest"}'; then
  pass "push: renamed and modified folders are built"
else
  fail "push: expected python:3.10-pdm-bookworm and tor-proxy:latest, got: $OUT"
fi
if echo "$OUT" | grep -q '^has_changes=true$'; then
  pass "push: has_changes is true when folders remain"
else
  fail "push: has_changes should be true, got: $OUT"
fi

# given: a push that only deletes a folder
git rm -r --quiet global/containers/python.3.10-pdm-bookworm
git commit --quiet -m 'delete'
BEFORE2="$AFTER"
AFTER2="$(git rev-parse HEAD)"
# when
OUT2="$(EVENT_NAME=push BEFORE="$BEFORE2" AFTER="$AFTER2" "$SCRIPT" 2>/dev/null)"
# then: nothing to build, and the output is still valid JSON for the workflow
if echo "$OUT2" | grep -q '^has_changes=false$' && echo "$OUT2" | grep -q '^matrix={"include":\[\]}$'; then
  pass "push: a deletion-only push produces an empty matrix"
else
  fail "push: deletion-only push should produce an empty matrix, got: $OUT2"
fi

# given: a manual dispatch naming a folder that does not exist
# when
if EVENT_NAME=workflow_dispatch INPUT_FOLDER=python.3.10-pdm-bullseye "$SCRIPT" >/dev/null 2>"$WORK/err.txt"; then
  fail "dispatch: a missing folder should fail fast"
else
  # then: the error names the folder and lists the valid ones
  if grep -q "python.3.10-pdm-bullseye' does not exist" "$WORK/err.txt" && grep -q 'tor-proxy.latest' "$WORK/err.txt"; then
    pass "dispatch: a missing folder fails fast and lists the valid folders"
  else
    fail "dispatch: unexpected error output: $(cat "$WORK/err.txt")"
  fi
fi

# given: a manual dispatch with an empty folder input
# when
OUT3="$(EVENT_NAME=workflow_dispatch INPUT_FOLDER='' "$SCRIPT" 2>/dev/null)"
# then: every existing folder is built
if echo "$OUT3" | grep -q '{"name":"tor-proxy","tag":"latest"}' && ! echo "$OUT3" | grep -q 'python'; then
  pass "dispatch: empty input builds every existing folder and nothing else"
else
  fail "dispatch: expected only tor-proxy:latest, got: $OUT3"
fi

# given: a first push of a branch (GitHub reports an all-zero `before`)
# when
OUT4="$(EVENT_NAME=push BEFORE=0000000000000000000000000000000000000000 AFTER="$AFTER2" "$SCRIPT" 2>/dev/null)"
# then: everything that exists is built
if echo "$OUT4" | grep -q '{"name":"tor-proxy","tag":"latest"}'; then
  pass "push: an initial push builds every existing folder"
else
  fail "push: initial push should build tor-proxy:latest, got: $OUT4"
fi

echo "[test-containers-detect] $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
