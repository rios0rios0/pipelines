#!/usr/bin/env bash
set -e

# A module's `go` directive must be readable by every toolchain that has to read it.
#
# The directive is a MINIMUM LANGUAGE VERSION, not a record of which Go the team
# happens to run -- and every `go` invocation refuses outright when it is asked to
# read a directive newer than itself:
#
#   go: go.mod requires go >= 1.27.0 (running go 1.26.6; GOTOOLCHAIN=local)
#
# That is not a warning it recovers from. It is returned before parsing, so the
# build, the tidy, the dependency download and any external analyser all fail
# identically, and none of the resulting messages names the two versions that
# disagree in a way a reader can act on.
#
# This repository has already paid for it twice, from a single edit:
#
#   - `Build & Push tor-proxy:latest` broke on 2026-07-27 and stayed broken for
#     over three weeks. Its Dockerfile pinned `golang:1.19.0-alpine3.16` while an
#     automated dependency bump had walked `health/go.mod` to `go 1.27.0`. The
#     failure reads `go: errors parsing go.mod`, which names no version at all.
#   - `Analyze (go)` -- GitHub's DEFAULT-SETUP CodeQL, which is configured in the
#     repository's settings rather than in a workflow anyone here can edit -- broke
#     on 2026-08-20 and failed ten consecutive runs on `main` and on every pull
#     request. Its runner ships one specific Go and sets `GOTOOLCHAIN=local`
#     deliberately, so it cannot fetch a newer one: extraction failed for the only
#     Go project in the repository, which CodeQL reports as a *configuration error*
#     rather than as a finding.
#
# The second is the reason this check is worth having rather than just fixing the
# number once. The builder image is ours and its failure is loud; the analyser's
# toolchain belongs to GitHub, is not declared anywhere in this repository, and
# moves on their schedule. The only durable defence is to keep the directive at
# the floor the DEPENDENCIES require -- what `go mod tidy` computes on its own --
# instead of letting it track the newest release. A floor that low is readable by
# every toolchain at or above it, including ones nobody here chose.
#
# What is asserted mechanically is the half that is knowable from this repository:
# no module may declare a directive its own builder image cannot read. The rest is
# the comment above and the CHANGELOG entry beside it.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_empty() {
  local description="$1"
  local findings="$2"
  if [[ -z "$findings" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "         $line"
    done <<< "$findings"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_true() {
  local description="$1"
  local condition="$2"
  if eval "$condition"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# version_le <a> <b> -- true when a <= b, comparing Go versions field by field.
#
# `sort -V` is deliberately not used: it is a GNU extension that BusyBox `sort`
# does not implement, and these suites are expected to give the same answer on a
# maintainer's Alpine container as on a GitHub runner. Three numeric fields is
# the whole grammar of a Go version here, so comparing them is shorter than
# depending on a flag that may not exist.
version_le() {
  local a="$1" b="$2" i
  local -a fa fb
  IFS='.' read -r -a fa <<< "$a"
  IFS='.' read -r -a fb <<< "$b"
  for i in 0 1 2; do
    local x="${fa[i]:-0}" y="${fb[i]:-0}"
    ((10#$x < 10#$y)) && return 0
    ((10#$x > 10#$y)) && return 1
  done
  return 0
}

echo "================================"
echo "Go module toolchain agreement"
echo "================================"
echo ""

# ---------------------------------------------------------------------------
echo "1. Every go.mod is paired with a builder that can read it"
# ---------------------------------------------------------------------------
# The pairing rule is positional and deliberately dumb: a `go.mod` is compiled by
# the Dockerfile of the container folder it lives under. That is the only
# arrangement this repository has, and a clever rule would quietly stop matching
# the day somebody adds a second one -- which is the failure mode this whole file
# exists to prevent. A module with no Dockerfile above it is reported rather than
# skipped, for the same reason.
MODULE_COUNT=0
FINDINGS=""

while IFS= read -r gomod; do
  [[ -z "$gomod" ]] && continue
  MODULE_COUNT=$((MODULE_COUNT + 1))

  directive="$(grep -oE '^go [0-9]+(\.[0-9]+)*' "$gomod" | head -1 | awk '{print $2}')"
  if [[ -z "$directive" ]]; then
    FINDINGS+="${gomod#"$SCRIPTS_DIR"/}: declares no 'go' directive"$'\n'
    continue
  fi

  dockerfile=""
  dir="$(dirname "$gomod")"
  while [[ "$dir" != "$SCRIPTS_DIR" && "$dir" != "/" ]]; do
    if [[ -f "$dir/Dockerfile" ]]; then
      dockerfile="$dir/Dockerfile"
      break
    fi
    dir="$(dirname "$dir")"
  done

  if [[ -z "$dockerfile" ]]; then
    FINDINGS+="${gomod#"$SCRIPTS_DIR"/}: no Dockerfile above it, so nothing pins the Go that builds it"$'\n'
    continue
  fi

  builder="$(grep -oE '^FROM +golang:[0-9]+(\.[0-9]+)*' "$dockerfile" | head -1 | sed 's/.*golang://')"
  if [[ -z "$builder" ]]; then
    FINDINGS+="${dockerfile#"$SCRIPTS_DIR"/}: no 'FROM golang:<version>' stage builds ${gomod#"$SCRIPTS_DIR"/}"$'\n'
    continue
  fi

  if ! version_le "$directive" "$builder"; then
    FINDINGS+="${gomod#"$SCRIPTS_DIR"/}: 'go $directive' exceeds its builder golang:$builder — go build will refuse to parse it"$'\n'
  fi
done < <(find "$SCRIPTS_DIR" -type f -name 'go.mod' -not -path '*/.git/*' | sort)

assert_empty "no go.mod declares a directive its builder image cannot read" "$FINDINGS"
assert_true "at least one Go module was actually examined" "[[ $MODULE_COUNT -ge 1 ]]"
echo ""

# ---------------------------------------------------------------------------
echo "2. The comparison itself is sound"
# ---------------------------------------------------------------------------
# A comparison that answered "fine" for everything would make section 1 pass for
# the worst possible reason -- the same silent-pass shape the supply-chain suite
# guards against -- so the comparator is exercised against the exact pair that
# broke, and against the boundaries either side of it.
assert_true "1.27.0 is NOT readable by golang:1.26.6 (the CodeQL failure)" \
  "! version_le 1.27.0 1.26.6"
assert_true "1.27.0 is NOT readable by golang:1.19.0 (the image build failure)" \
  "! version_le 1.27.0 1.19.0"
assert_true "1.25.0 IS readable by golang:1.26.7 (the pairing this commit ships)" \
  "version_le 1.25.0 1.26.7"
assert_true "a directive equal to its builder is readable" "version_le 1.25.0 1.25.0"
assert_true "a two-field directive is compared as its zero patch" "version_le 1.25 1.25.0"
assert_true "the minor field is compared numerically, not as text" "version_le 1.9.0 1.26.0"
echo ""

echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  echo "================================"
  exit 1
fi
echo "================================"
echo -e "${GREEN}Go module toolchain agreement holds${NC}"
