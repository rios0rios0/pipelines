#!/usr/bin/env bash
set -e

# Pin the `working_directory` contract on the reusable workflows that accept it.
#
# WHY THIS EXISTS
#
# A repository whose project does not sit at its root -- a Rails API under `api/`
# beside a frontend under `app/`, a gem under `gem/` -- could not call these
# workflows at all: every command ran in the workspace root, `bundle exec` found
# no Gemfile, and `actions/setup-node` failed on its second step with
# "Dependencies lock file is not found". The repository that hit this copied
# `bundler.yaml` into its own `.github/workflows/default.yaml`, job for job, and
# added `working-directory:` by hand -- which is the failure this library exists
# to prevent: a consumer maintaining a fork of the shared pipeline, drifting from
# it one input at a time.
#
# The input closes that, and it has four properties that all fail QUIETLY if
# they regress, which is why each is asserted here rather than left to review:
#
#   - **A step that loses `working-directory:` does not fail; it runs in the
#     wrong directory.** `bundle exec rubocop` at the root of a repository whose
#     Gemfile is in `api/` reports "could not locate Gemfile" -- but the RuboCop
#     job is `continue-on-error`, so the pipeline stays green and the style gate
#     silently checks nothing.
#
#   - **A `hashFiles()` guard that keeps a root-relative literal is not an error
#     either.** `hashFiles('coverage/index.html')` is simply always empty for a
#     project one directory down, so the coverage and JUnit steps SKIP. Nothing
#     in the log says a report was expected.
#
#   - **Scoping the repository-wide scanners would shrink the security surface
#     without any signal at all.** Gitleaks, Semgrep, CodeQL, Hadolint and
#     basic-checks read the whole repository on purpose; pointing them at the
#     project directory would leave every file outside it unscanned and every
#     job still green. The third assertion group below fails if any of them ever
#     grows a `working_directory`.
#
#   - **A SonarQube runner that cannot see the project's coverage does not skip
#     the property, it CLEARS it.** `sonarqube/run.sh` globs for coverage relative
#     to its own directory and, finding none, appends an empty
#     `sonar.javascript.lcov.reportPaths=` -- last definition wins in a Java
#     properties file, so the value the repository set for itself is overwritten
#     and SonarQube reports 0% coverage on new code. That fails a default quality
#     gate on every pull request while the job, being `continue-on-error`, stays
#     green with one line of log.
#
# WHAT IT DOES NOT DO
#
# It does not assert that the input EXISTS on workflows that never took it. Only
# the toolchains threaded so far are listed, and adding one there is what brings
# it under these rules.
#
# The files are parsed, not read as indented text the way `order-check` and
# `var-catalog` read theirs: every assertion here is about a step's `with:` map or
# a step-level key, which is a nesting question rather than a line shape. The
# parser is Go test support (`internal/testsuites/workingdirectory`), built from
# this checkout for this run.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_empty() {
  local description="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo -e "${RED}        $line${NC}"
    done <<< "$value"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo "================================"
echo "working_directory contract"
echo "================================"
echo ""

# One pass over every file in scope, emitting `<group>\t<finding>` lines, so each
# assertion below is a lookup in a flat file rather than a seventh parse of the
# same nine workflows. A checker that does not build stops the suite: every
# assertion below would otherwise read an empty file and pass for it.
WORK_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK_DIR"' EXIT
FINDINGS="$WORK_DIR/findings"
CHECKER="$WORK_DIR/workingdirectory"
if ! CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
  go build -C "$SCRIPTS_DIR" -trimpath -o "$CHECKER" ./internal/testsuites/workingdirectory; then
  echo -e "${RED}could not build ./internal/testsuites/workingdirectory, so no assertion can run${NC}"
  exit 1
fi

# A checker that cannot read a workflow (a file yamldoc refuses, an unreadable one) prints nothing
# and exits 1; read as an empty findings file, every assertion below would pass for it.
if ! "$CHECKER" "$SCRIPTS_DIR" > "$FINDINGS"; then
  echo -e "${RED}./internal/testsuites/workingdirectory could not read the workflows, so no assertion can run${NC}"
  exit 1
fi

# `awk` rather than `grep -P`: the group separator is a TAB, and a portable BRE
# cannot name one -- `grep -P` is a GNU extension this suite has no reason to
# require, and `grep $'\t'` reads as a typo the first time somebody edits it.
group() {
  local name="$1"
  awk -F '\t' -v group="$name" '$1 == group { sub(/^[^\t]*\t/, ""); print }' "$FINDINGS"
}

echo "Test 1: every workflow and stage in scope declares the input, optional and rooted at '.'"
assert_empty \
  "every workflow/action in scope declares an optional string 'working_directory' defaulting to '.'" \
  "$(group declared)"
echo ""

echo "Test 2: a composed workflow forwards the input to the base it calls"
assert_empty \
  "every -library/-docker variant passes 'working_directory' to its toolchain workflow" \
  "$(group forwarded)"
echo ""

echo "Test 3: the repository-wide scanners are NOT scoped to the project"
assert_empty \
  "gitleaks, semgrep, codeql, hadolint and basic-checks keep scanning from the repository root" \
  "$(group repository_wide)"
echo ""

echo "Test 4: every project-scoped step actually receives the input"
assert_empty \
  "every install, tool run and setup step in a toolchain job runs in 'working_directory'" \
  "$(group threaded)"
echo ""

echo "Test 5: report, coverage and artifact paths follow the project"
assert_empty \
  "no coverage/JUnit/report path or hashFiles() guard is left relative to the workspace root" \
  "$(group report_paths)"
echo ""

echo "Test 6: the Ruby version is read from the project rather than hardcoded"
assert_empty \
  "every ruby/setup-ruby resolves 'ruby_version', then the project's '.ruby-version', then '3.3'" \
  "$(group ruby_version)"
echo ""

echo "Test 7: the SonarQube scan stays repository-wide but knows where the project is"
assert_empty \
  "every Sonar step runs from the repository root and exports 'SONAR_PROJECT_DIR', and the runner reads it" \
  "$(group sonar)"
echo ""

echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo "================================"

if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi

echo "All working_directory tests passed!"
