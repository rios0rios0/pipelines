#!/usr/bin/env bash
set -e

# Every toolchain that reads a `go.mod` must be new enough for the `go` directive in it.
#
# The directive is a MINIMUM LANGUAGE VERSION -- a requirement the module states -- and every
# `go` invocation refuses one newer than itself, before parsing:
#
#   go: go.mod requires go >= 1.27.0 (running go 1.26.6; GOTOOLCHAIN=local)
#
# That is not a warning it recovers from. The build, the tidy, the dependency download and any
# external analyser all fail identically, and none of the resulting messages names the two
# versions that disagree in a way a reader can act on.
#
# This repository paid for it twice, from one automated dependency bump:
#
#   - `Build & Push tor-proxy:latest` broke on 2026-07-27 and stayed broken for over three
#     weeks. Its Dockerfile still pinned `golang:1.19.0-alpine3.16`. The failure reads
#     `go: errors parsing go.mod`, which names no version at all.
#   - `Analyze (go)` -- then GitHub's DEFAULT-SETUP CodeQL -- broke on 2026-08-20 and failed ten
#     consecutive runs on `main` and on every pull request. Its runner ships one Go and sets
#     `GOTOOLCHAIN=local` deliberately, so it cannot fetch another: extraction failed for the
#     only Go project in the repository, which CodeQL reports as a *configuration error* rather
#     than as a finding.
#
# **The fix is upward, in both places, and the direction is the point.** The module says what it
# needs; the toolchains follow. Lowering the directive to suit the oldest thing that reads it
# would make this green by giving up whatever the module is entitled to use, and would have to be
# done again on every future release -- a ratchet running the wrong way. The builder image was
# raised to the directive, and the Go analysis now installs the toolchain the module asks for
# (`go_version_file` on `github/global/stages/20-security/codeql`) instead of hoping the runner
# image already carries it.
#
# So there is no version pinned anywhere in this file. What is asserted is the RELATIONSHIP:
# nothing that has to read a module may be older than the module, and the Go analysis must bring
# its own toolchain rather than inherit one it cannot choose.

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
assert_true "1.27.0 IS readable by golang:1.27.0 (the pairing this commit ships)" \
  "version_le 1.27.0 1.27.0"
assert_true "a newer builder than the directive is fine -- only the reverse breaks" \
  "version_le 1.27.0 1.28.0"
assert_true "a two-field directive is compared as its zero patch" "version_le 1.25 1.25.0"
assert_true "the minor field is compared numerically, not as text" "version_le 1.9.0 1.26.0"
echo ""

# ---------------------------------------------------------------------------
echo "3. The Go analysis brings its own toolchain"
# ---------------------------------------------------------------------------
# The builder image is ours and its failure is loud. The ANALYSER's toolchain is
# not: it belongs to GitHub, is declared nowhere in this repository, and moves on
# their schedule -- so "it works today" is not a property anything here can keep.
# The only durable answer is for the analysis to install what the module asks for,
# which is what these assert is still wired.
CODEQL_ACTION="$SCRIPTS_DIR/github/global/stages/20-security/codeql/action.yaml"

assert_true "the shared CodeQL action still exists where the workflows call it" \
  "[[ -f '$CODEQL_ACTION' ]]"
assert_true "the Go analysis installs a toolchain rather than taking the runner's" \
  "grep -q 'actions/setup-go@' '$CODEQL_ACTION'"

# `go-version-file`, never `go-version`. A pinned version here would just move the
# drift into this file and need bumping on every Go release; reading the module's
# own directive means the toolchain cannot be older than the code that requires it.
assert_true "the toolchain is read from the module, not pinned in the action" \
  "grep -q 'go-version-file:' '$CODEQL_ACTION'"
assert_empty "no hardcoded 'go-version:' pin sits beside it" \
  "$(grep -n 'go-version:' "$CODEQL_ACTION" || true)"

# The step is useless if it lands after the database is initialised: the extractor
# resolves `go` from PATH at build time, so a toolchain installed afterwards is a
# toolchain nothing used.
SETUP_GO_LINE="$(grep -n 'actions/setup-go@' "$CODEQL_ACTION" | head -1 | cut -d: -f1)"
INIT_LINE="$(grep -n 'codeql-action/init@' "$CODEQL_ACTION" | head -1 | cut -d: -f1)"
assert_true "the toolchain is installed BEFORE CodeQL initialises its database" \
  "[[ -n '$SETUP_GO_LINE' && -n '$INIT_LINE' && $SETUP_GO_LINE -lt $INIT_LINE ]]"

# This repository analyses itself through that action, and the file it names has to
# be the module that actually exists -- a stale path silently falls back to the
# runner's Go, which is the state this whole file exists to prevent.
SELF_WORKFLOW="$SCRIPTS_DIR/.github/workflows/codeql.yaml"
assert_true "this repository scans itself through the shared action" \
  "[[ -f '$SELF_WORKFLOW' ]] && grep -q '20-security/codeql@main' '$SELF_WORKFLOW'"

NAMED_FILE="$(grep -oE "go_version_file: *'[^']+'" "$SELF_WORKFLOW" 2> /dev/null | head -1 | sed "s/.*'\\(.*\\)'/\\1/")"
assert_true "the go.mod it names is really there ($NAMED_FILE)" \
  "[[ -n '$NAMED_FILE' && -f '$SCRIPTS_DIR/$NAMED_FILE' ]]"
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
