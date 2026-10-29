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
# image already carries it -- and on GitLab CI and Azure DevOps, the pinned Go (section 3c).
#
# So no version is pinned anywhere in this file; the one table, in section 4, records which CodeQL
# release first read each Go, a fact about upstream rather than a choice. What is asserted is the
# RELATIONSHIP: nothing that has to read a module may be older than the module, and the Go
# analysis must bring its own toolchain rather than inherit one it cannot choose.

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
# the Dockerfile of the container folder it lives under. A clever rule would
# quietly stop matching the day somebody adds a second arrangement -- which is the
# failure mode this whole file exists to prevent -- so a module with no Dockerfile
# above it is reported rather than skipped. The one exception is the repository's
# own module at the root, which holds the Go helpers and has a pairing of its own
# (section 1b), written when it was added rather than assumed.
ROOT_MODULE="$SCRIPTS_DIR/go.mod"
MODULE_COUNT=0
FINDINGS=""

while IFS= read -r gomod; do
  [[ -z "$gomod" ]] && continue
  MODULE_COUNT=$((MODULE_COUNT + 1))
  [[ "$gomod" == "$ROOT_MODULE" ]] && continue

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
echo "1b. The root module is paired with every workflow that builds it"
# ---------------------------------------------------------------------------
# The root `go.mod` holds the Go helpers. No Dockerfile builds it: each helper's
# `run.sh` compiles it on the runner through `global/scripts/shared/go-helper.sh`,
# so its builders are the workflows that run a helper, and the Go they provision.
# The relationship is the one section 1 asserts -- no builder older than the
# directive -- and the builders are FOUND rather than listed: every `run.sh` that
# sits beside a `main.go` of this module is a helper, and every GitHub Actions file
# naming one (or running `make test`, which runs the helpers' tests) is a builder.
# A helper added later is then covered without anyone remembering this file.
if [[ -f "$ROOT_MODULE" ]]; then
  ROOT_DIRECTIVE="$(grep -oE '^go [0-9]+(\.[0-9]+)*' "$ROOT_MODULE" | head -1 | awk '{print $2}')"
  assert_true "the root module declares a 'go' directive" "[[ -n '$ROOT_DIRECTIVE' ]]"

  # A `main.go` under a NESTED module belongs to that module, not this one.
  NESTED_MODULES="$(find "$SCRIPTS_DIR" -mindepth 2 -type f -name 'go.mod' -not -path '*/.git/*' -exec dirname {} \;)"
  HELPERS=()
  while IFS= read -r main; do
    [[ -z "$main" ]] && continue
    dir="$(dirname "$main")"
    nested=false
    while IFS= read -r module_dir; do
      [[ -n "$module_dir" && "$dir/" == "$module_dir/"* ]] && nested=true
    done <<< "$NESTED_MODULES"
    if [[ "$nested" == false && -f "$dir/run.sh" ]]; then
      HELPERS+=("${dir#"$SCRIPTS_DIR"/}/run.sh")
    fi
  done < <(find "$SCRIPTS_DIR" -type f -name 'main.go' -not -path '*/.git/*' | sort)
  assert_true "the root module's helpers were found (${#HELPERS[@]})" "[[ ${#HELPERS[@]} -ge 1 ]]"

  BUILDERS=()
  while IFS= read -r file; do
    builds=false
    for helper in "${HELPERS[@]}"; do
      grep -qF "$helper" "$file" && builds=true
    done
    grep -qE '^ *run: *make test *$' "$file" && builds=true
    [[ "$builds" == true ]] && BUILDERS+=("$file")
  done < <(find "$SCRIPTS_DIR/.github/workflows" "$SCRIPTS_DIR/github" -type f -name '*.yaml' | sort)
  assert_true "the workflows that build it were found (${#BUILDERS[@]})" "[[ ${#BUILDERS[@]} -ge 1 ]]"

  FINDINGS=""
  for file in "${BUILDERS[@]}"; do
    versions="$(grep -oE "go-version: *'[0-9]+(\.[0-9]+)*'" "$file" | grep -oE "[0-9]+(\.[0-9]+)*" || true)"
    if [[ -z "$versions" ]]; then
      FINDINGS+="${file#"$SCRIPTS_DIR"/}: builds a Go helper with no 'go-version' pinned, so nothing pins the Go that builds it"$'\n'
      continue
    fi
    for version in $versions; do
      if ! version_le "$ROOT_DIRECTIVE" "$version"; then
        FINDINGS+="${file#"$SCRIPTS_DIR"/}: go-version '$version' is older than go.mod's 'go $ROOT_DIRECTIVE' -- go build will refuse to parse it"$'\n'
      fi
    done
  done
  assert_empty "every workflow that builds a Go helper provisions a Go that can read go.mod" "$FINDINGS"

  # GitLab CI and Azure DevOps have no pairing rule here yet: a template there
  # running a helper would build it with whatever Go its image carries, checked by
  # nothing. So one is reported until this file learns that platform's rule.
  UNPAIRED=""
  for helper in "${HELPERS[@]}"; do
    UNPAIRED+="$(grep -rlF "$helper" "$SCRIPTS_DIR/gitlab" "$SCRIPTS_DIR/azure-devops" 2> /dev/null \
      | sed "s|^$SCRIPTS_DIR/||" || true)"
  done
  assert_empty "no GitLab CI or Azure DevOps template runs a Go helper this file cannot pair" "$UNPAIRED"
fi
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
  "[[ -f '$SELF_WORKFLOW' ]] && grep -q '20-security/codeql' '$SELF_WORKFLOW'"

NAMED_FILE="$(grep -oE "go_version_file: *'[^']+'" "$SELF_WORKFLOW" 2> /dev/null | head -1 | sed "s/.*'\\(.*\\)'/\\1/")"
assert_true "the go.mod it names is really there ($NAMED_FILE)" \
  "[[ -n '$NAMED_FILE' && -f '$SCRIPTS_DIR/$NAMED_FILE' ]]"

# Autobuild extracts EVERY module here from the repository root, under the one Go set up from that
# file with `GOTOOLCHAIN=local`. A module whose directive is newer than the named file's could not
# be extracted at all, so the named file has to carry the newest directive in the repository.
NEWEST_DIRECTIVE=""
NEWEST_MODULE=""
while IFS= read -r gomod; do
  [[ -z "$gomod" ]] && continue
  directive="$(grep -oE '^go [0-9]+(\.[0-9]+)*' "$gomod" | head -1 | awk '{print $2}')"
  [[ -z "$directive" ]] && continue
  if [[ -z "$NEWEST_DIRECTIVE" ]] || ! version_le "$directive" "$NEWEST_DIRECTIVE"; then
    NEWEST_DIRECTIVE="$directive"
    NEWEST_MODULE="${gomod#"$SCRIPTS_DIR"/}"
  fi
done < <(find "$SCRIPTS_DIR" -type f -name 'go.mod' -not -path '*/.git/*' | sort)
NAMED_DIRECTIVE=""
if [[ -n "$NAMED_FILE" && -f "$SCRIPTS_DIR/$NAMED_FILE" ]]; then
  NAMED_DIRECTIVE="$(grep -oE '^go [0-9]+(\.[0-9]+)*' "$SCRIPTS_DIR/$NAMED_FILE" | head -1 | awk '{print $2}')"
fi
assert_true "the go.mod it names carries the newest directive here, go $NEWEST_DIRECTIVE of $NEWEST_MODULE, so its Go reads every module" \
  "[[ -n '$NAMED_DIRECTIVE' && -n '$NEWEST_DIRECTIVE' ]] && version_le '$NEWEST_DIRECTIVE' '$NAMED_DIRECTIVE'"

# The action has to be referenced by LOCAL PATH. `@main` resolves to the copy on the default
# branch, so a pull request changing the action would test the old one and report green on code
# nobody ran -- and an external `uses:` on a branch name is a high-severity SonarCloud finding
# (`githubactions:S7637`) into the bargain. Both were observed on #602 before this line existed.
assert_true "the self-scan runs THIS commit's action, not the published one" \
  "grep -qE \"uses: *'\\./github/global/stages/20-security/codeql'\" '$SELF_WORKFLOW'"
assert_empty "the self-scan does not reference the action through a moving branch" \
  "$(grep -n '20-security/codeql@' "$SELF_WORKFLOW" || true)"
echo ""

# The input is useless if no consumer can reach it, and that is exactly how it shipped
# first: the action grew `go_version_file` while `go.yaml` still called it with two inputs,
# so every consumer going through the reusable workflows kept the old behaviour and the fix
# only ever worked for this repository's own self-scan.
echo ""
echo "3b. Consumers can actually reach the toolchain input"
for wf in go go-docker go-binary go-library go-render; do
  FILE="$SCRIPTS_DIR/.github/workflows/$wf.yaml"
  assert_true "$wf.yaml declares go_version_file" \
    "grep -qE '^ +go_version_file:' '$FILE'"
  # `grep -F`: the needle contains `${{ }}`, which is an unmatched brace to ERE and a
  # parameter expansion to the shell. Fixed-string matching sidesteps both.
  assert_true "$wf.yaml passes it on rather than declaring it decoratively" \
    "grep -qF 'inputs.go_version_file }}' '$FILE'"
done

# The chain has to be unbroken end to end: `go-render` -> `go-docker` -> `go.yaml` -> action.
# Any one link declaring the input without forwarding it looks fine in isolation.
assert_true "go.yaml hands the input to the CodeQL action, not just to itself" \
  "grep -A 4 \"20-security/codeql@main\" '$SCRIPTS_DIR/.github/workflows/go.yaml' | grep -q 'go_version_file:'"

# And when nobody sets it, the action must still find a module that is not at the root --
# otherwise the default silently reproduces the original failure for those repositories.
assert_true "the action searches for the module when the named file is absent" \
  "grep -q 'find . -name go.mod' '$CODEQL_ACTION'"
assert_true "an ambiguous tree is reported rather than guessed at" \
  "grep -q 'Go toolchain not resolved' '$CODEQL_ACTION'"
assert_true "the discovered path is what setup-go is given" \
  "grep -qF 'steps.go_toolchain.outputs.file' '$CODEQL_ACTION'"
echo ""

# ---------------------------------------------------------------------------
echo "3c. The Go analysis has a Go on GitLab CI and Azure DevOps too"
# ---------------------------------------------------------------------------
# GitHub Actions sets the module's Go up above. The other two platforms run CodeQL through
# `run.sh`, and the Go autobuilder builds with whatever `go` is on PATH, so there the JOB decides
# the toolchain -- and a job without one analyses no Go at all:
#
#   - GitLab CI's shared `sast:codeql` runs in the pipeline's default `docker:x.y` image, which is
#     Alpine: the bundle's glibc-linked Java runtime cannot start there (`java: not found`), and
#     the image has no Go. The Go stage moves the job onto `.go`, the image of every other Go job.
#   - Azure DevOps' shared CodeQL job set up no Go. A Microsoft-hosted agent carries Go 1.24 to
#     1.26 and reaches a newer module only by downloading its toolchain; an agent with no Go, or no
#     route to proxy.golang.org, failed the analysis, and `continueOnError` reported that as passed
#     with issues. The Go stage hands the template the `GoTool@0` the other Go jobs run.
GITLAB_GO_SECURITY="$SCRIPTS_DIR/gitlab/golang/stages/20-security/go.yaml"
# The job's own block: from its key to the next line that starts in column 0 -- the next key, or
# the comment above it.
GITLAB_CODEQL_JOB="$(awk '/^sast:codeql:/ { inside = 1; print; next }
  inside && /^[^[:space:]]/ { exit }
  inside { print }' "$GITLAB_GO_SECURITY" 2> /dev/null)"
assert_true "the GitLab CI Go stage overrides the shared sast:codeql job" \
  "[[ -n \"\$GITLAB_CODEQL_JOB\" ]]"
assert_true "it runs in the .go image, which carries glibc and the pinned Go" \
  "grep -qE \"^  extends: .*'\\.go'\" <<< \"\$GITLAB_CODEQL_JOB\""
assert_true "it installs jq, which the findings gate reads the SARIF with" \
  "grep -qE 'apt-get install .*[[:space:]]jq([[:space:]]|$)' <<< \"\$GITLAB_CODEQL_JOB\""
# `.go`'s before_script and cache put GOPATH inside the checkout, and the autobuilder searches the
# whole source root for go.mod files (skipping only `vendor/`): a module cache there is extracted as
# hundreds of extra projects. So the job takes `.go`'s image and nothing else of it.
assert_true "it turns the .go cache off" \
  "grep -qE '^  cache: *\\[ *\\]' <<< \"\$GITLAB_CODEQL_JOB\""
assert_empty "it neither runs .go's before_script nor sets a GOPATH of its own" \
  "$(grep -nE '\.go, *before_script|GOPATH' <<< "$GITLAB_CODEQL_JOB" | grep -vE '^[0-9]+: *#' || true)"
# Only where the job runs is overridden; what it runs stays the shared runner and gate.
assert_empty "it keeps the shared job's script rather than a copy of it" \
  "$(grep -nE '^  script:' <<< "$GITLAB_CODEQL_JOB" || true)"

AZURE_CODEQL="$SCRIPTS_DIR/azure-devops/global/stages/20-security/codeql.yaml"
AZURE_GO_SECURITY="$SCRIPTS_DIR/azure-devops/golang/stages/20-security/go.yaml"
assert_true "the Azure DevOps CodeQL template takes PRE_STEPS" \
  "grep -A1 -E \"name: *'PRE_STEPS'\" '$AZURE_CODEQL' | grep -qE \"type: *'stepList'\""
PRE_STEPS_LINE="$(grep -n 'each step in parameters.PRE_STEPS' "$AZURE_CODEQL" | head -1 | cut -d: -f1)"
RUNNER_LINE="$(grep -n 'global/scripts/tools/codeql/run.sh' "$AZURE_CODEQL" | head -1 | cut -d: -f1)"
assert_true "it runs them BEFORE run.sh, so the extractor builds with what they install" \
  "[[ -n '$PRE_STEPS_LINE' && -n '$RUNNER_LINE' && $PRE_STEPS_LINE -lt $RUNNER_LINE ]]"
# The Go stage's call of that template: from its `- template:` line to the next list item at the
# same indentation.
AZURE_CODEQL_CALL="$(awk '/- template: .*20-security\/codeql\.yaml/ { inside = 1; indent = index($0, "-"); print; next }
  inside { if (match($0, /^ *- /) && RLENGTH == indent + 1) exit; print }' "$AZURE_GO_SECURITY" 2> /dev/null)"
assert_true "the Azure DevOps Go stage passes CodeQL a GoTool@0 step" \
  "grep -q 'PRE_STEPS:' <<< \"\$AZURE_CODEQL_CALL\" && grep -q \"task: 'GoTool@0'\" <<< \"\$AZURE_CODEQL_CALL\""
CODEQL_GO="$(grep -A3 'GoTool@0' <<< "$AZURE_CODEQL_CALL" | grep -oE "version: *'[0-9.]+'" | grep -oE '[0-9][0-9.]*' | head -1)"
OTHER_GO="$(grep -A3 'GoTool@0' "$SCRIPTS_DIR/azure-devops/golang/abstracts/go.yaml" | grep -oE "version: *'[0-9.]+'" | grep -oE '[0-9][0-9.]*' | head -1)"
assert_true "it is the Go the other Go jobs run ($CODEQL_GO; azure-devops/golang/abstracts/go.yaml: $OTHER_GO)" \
  "[[ -n '$CODEQL_GO' && '$CODEQL_GO' == '$OTHER_GO' ]]"
echo ""

# ---------------------------------------------------------------------------
echo "4. Go is analysed"
# ---------------------------------------------------------------------------
# From 2026-08-21 the Go leg was waived, in a job of its own that announced the gap: the newest
# CodeQL bundle then, 2.26.3, carried a Go extractor built with go1.26, and that extractor refuses
# a newer language version -- `package requires newer Go version go1.27 (application built with
# go1.26)` -- while `database create` still exits 0 over the broken types. Every bundle from
# `codeql-bundle-v2.26.4` (2026-08-26) is built with go1.27, and Go is analysed again.
#
# These keep it so. A language dropped from a matrix looks identical to one nobody thought of, and
# reads as covered on every dashboard that counts green checks: leaving Go out again has to be a
# decision this file is edited for, not a line that goes missing.
assert_true "Go is in this repository's CodeQL matrix" \
  "grep -qE \"language: *\\[.*'go'\" '$SELF_WORKFLOW'"
assert_empty "no waiver job or expiry date is left behind" \
  "$(grep -nE 'go-analysis-waived|Go is not being analysed|Expires 20[0-9]{2}-' "$SELF_WORKFLOW" || true)"

# A leg that runs, fails and is forgiven is worse than one that is honestly absent. Comment lines
# are dropped before matching, for the reason `test-supply-chain.sh` gives about its own rules: a
# check that forbids a pattern must not be failed by a paragraph explaining it.
assert_empty "no continue-on-error hides a failing analysis" \
  "$(grep -n 'continue-on-error' "$SELF_WORKFLOW" | grep -vE '^[0-9]+: *#' || true)"

# The bundle `run.sh` installs -- GitLab CI, Azure DevOps, `make codeql` -- has to read the newest
# directive too, and it is the EXTRACTOR that refuses one, not the toolchain: a prebuilt binary, so
# each Go minor has a first bundle able to read it, the first whose `go/extractor/go.mod` names that
# Go. A module moving to a minor not listed here fails until someone looks the release up and adds
# the row:
#
#   gh api 'repos/github/codeql/contents/go/extractor/go.mod?ref=codeql-cli/vX.Y.Z' \
#     --jq .content | base64 -d | grep '^go '
declare -A FIRST_BUNDLE_FOR_GO=([1.24]='2.20.5' [1.25]='2.22.4' [1.26]='2.24.2' [1.27]='2.26.4')
NEWEST_MINOR="$(cut -d. -f1,2 <<< "$NEWEST_DIRECTIVE")"
PINNED_BUNDLE="$(grep -oE '^CODEQL_BUNDLE_PINNED_VERSION="codeql-bundle-v[0-9]+\.[0-9]+\.[0-9]+"' \
  "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
FIRST_BUNDLE="${FIRST_BUNDLE_FOR_GO[${NEWEST_MINOR:-none}]:-}"
assert_true "the first CodeQL bundle that reads go $NEWEST_MINOR, the newest directive here, is recorded" \
  "[[ -n '$FIRST_BUNDLE' ]]"
assert_true "the pinned bundle ($PINNED_BUNDLE) reads go $NEWEST_MINOR, as every bundle from $FIRST_BUNDLE does" \
  "[[ -n '$PINNED_BUNDLE' && -n '$FIRST_BUNDLE' ]] && version_le '$FIRST_BUNDLE' '$PINNED_BUNDLE'"
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
