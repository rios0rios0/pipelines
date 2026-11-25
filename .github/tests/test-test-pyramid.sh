#!/usr/bin/env bash
# Validation script for the test-pyramid check (`global/scripts/tools/test-pyramid/`).
#
# The check judges whether a pull request worsens its repository's test pyramid: every test case of
# the target branch (the merge base) and of the pull request is put in a tier, and the two suites
# are compared by the book. The classification and the verdict are Go, unit-tested where they live
# (`make test ONLY=go-helpers`); this suite proves the rest, which only a real repository can:
#
#   - the end to end, against throwaway repositories whose `origin` is a local bare repository, so
#     the fetch, the merge base, the policy read from the target branch, the reports, the platform
#     outputs and the exit status are all exercised with no network;
#   - the wiring: every pipeline that tests -- each GitHub Actions base workflow, each GitLab CI and
#     Azure DevOps tests stage -- runs the check on pull requests only, for a language a profile
#     exists for, and a new one that does not fails here;
#   - `make test-pyramid`, from a consumer's Makefile.
# shellcheck disable=SC2016 # a single-quoted `$` or `${{ }}` here is text a template must hold, never an expansion
set -uo pipefail

echo "=== Testing the test-pyramid check ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$ROOT_DIR/global/scripts/tools/test-pyramid/run.sh"
PROFILES="$ROOT_DIR/global/scripts/tools/test-pyramid/internal/domain/entities/profiles.go"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
  echo -e "${GREEN}  PASS: $1${NC}"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  echo -e "${RED}  FAIL: $1${NC}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

# check <description> <command...>: passes when the command succeeds.
check() {
  local description="$1"
  shift
  if "$@"; then pass "$description"; else fail "$description"; fi
}

TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/no-hooks" || exit 1

# No global configuration reaches the fixtures: a `commit.gpgsign = true` whose signer needs an
# unlocked agent, or a `core.hooksPath` holding a secret scanner, would otherwise act on commits
# that hold nothing.
fixture_git() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -c init.defaultBranch=main -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c tag.gpgsign=false -c core.hooksPath="$TEST_DIR/no-hooks" "$@"
}

# go_tests <path> <build tag or ''> <count>: a Go test file with <count> tests.
go_tests() {
  local path="$1" tag="$2" count="$3" index
  mkdir -p "$(dirname "$path")" || return 1
  {
    [[ -n "$tag" ]] && printf '//go:build %s\n\n' "$tag"
    printf 'package fixture\n\nimport "testing"\n\n'
    for ((index = 1; index <= count; index++)); do
      printf 'func TestCase%d(t *testing.T) {}\n' "$index"
    done
  } > "$path"
}

# new_fixture <name>: a bare `origin` whose `main` holds ten Go unit tests and one integration
# test, and a clone of it on a branch named `feature`. Prints the clone's path.
new_fixture() {
  local name="$1"
  local origin="$TEST_DIR/$name/origin.git" seed="$TEST_DIR/$name/seed" work="$TEST_DIR/$name/work"
  fixture_git init --quiet --bare "$origin" || return 1
  fixture_git init --quiet "$seed" || return 1
  go_tests "$seed/pkg/unit_test.go" '' 10 || return 1
  go_tests "$seed/pkg/repository_test.go" integration 1 || return 1
  fixture_git -C "$seed" add -A || return 1
  fixture_git -C "$seed" commit --quiet -m base || return 1
  fixture_git -C "$seed" push --quiet "$origin" HEAD:refs/heads/main || return 1
  fixture_git clone --quiet "$origin" "$work" || return 1
  fixture_git -C "$work" checkout --quiet -b feature || return 1
  echo "$work"
}

# commit_all <repository> <message>: commits whatever the working tree holds.
commit_all() {
  fixture_git -C "$1" add -A || return 1
  fixture_git -C "$1" commit --quiet -m "$2" || return 1
}

# on_target <name> <path> <content>: lands a file on `main` behind the clone's back, through the seed
# repository, so only a fetch can tell the clone about it.
on_target() {
  local seed="$TEST_DIR/$1/seed"
  mkdir -p "$(dirname "$seed/$2")" || return 1
  printf '%s' "$3" > "$seed/$2" || return 1
  commit_all "$seed" "target: $2" || return 1
  fixture_git -C "$seed" push --quiet "$TEST_DIR/$1/origin.git" HEAD:refs/heads/main || return 1
}

# run_check <repository> [NAME=value...]: runs the check inside <repository> with no CI variable but
# those named and no global git configuration. Prints its output, then `exit=<status>`.
run_check() {
  local repository="$1" output status
  shift
  output="$(
    cd "$repository" || exit 97
    env -u SYSTEM_PULLREQUEST_TARGETBRANCH -u GITHUB_BASE_REF -u CI_MERGE_REQUEST_TARGET_BRANCH_NAME \
      -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY -u TF_BUILD -u REPORT_PATH -u TEST_PYRAMID_BLOCKING \
      -u TEST_PYRAMID_TARGET -u TEST_PYRAMID_BASE -u TEST_PYRAMID_LANGUAGE -u SCRIPTS_DIR \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GITHUB_BASE_REF=main TEST_PYRAMID_LANGUAGE=go "$@" \
      sh "$CHECK" 2>&1
  )"
  status=$?
  printf '%s\nexit=%s\n' "$output" "$status"
}

# expect <description> <output> <exit status> [text that must appear...]
expect() {
  local description="$1" output="$2" status="$3" text missing=''
  shift 3
  if ! grep -qx "exit=$status" <<< "$output"; then
    missing="exit=$status"
  fi
  for text in "$@"; do
    grep -qF -- "$text" <<< "$output" || missing="${missing:+$missing, }'$text'"
  done
  if [[ -z "$missing" ]]; then
    pass "$description"
  else
    fail "$description (missing $missing)"
    printf '%s\n' "$output" | sed 's/^/        /'
  fi
}

echo "--- 1. the verdict, end to end ---"

work="$(new_fixture kept)" || exit 1
go_tests "$work/pkg/more_test.go" '' 5 && commit_all "$work" 'more unit tests'
output="$(run_check "$work")"
expect "keeps the pyramid when the pull request adds unit tests" "$output" 0 \
  'this pull request keeps the test pyramid' 'policy from the defaults (no .test-pyramid on "main")'
check "writes the summary, the JSON report and both trees' per-file decisions" \
  test -s "$work/build/reports/test-pyramid/summary.md" -a -s "$work/build/reports/test-pyramid/test-pyramid.json" \
  -a -s "$work/build/reports/test-pyramid/go-target.tsv" -a -s "$work/build/reports/test-pyramid/go-pull-request.tsv"
check "records each file's tier and the rule that decided it" \
  grep -qxF "$(printf 'integration\t1\tevidence\tpkg/repository_test.go')" "$work/build/reports/test-pyramid/go-pull-request.tsv"

work="$(new_fixture advisory)" || exit 1
go_tests "$work/e2e/flow_test.go" e2e 3 && commit_all "$work" 'e2e tests'
output="$(run_check "$work")"
expect "warns but passes when the pull request worsens the pyramid and the policy is advisory" "$output" 0 \
  'WORSENED  functional and e2e tests are now 21.4% of the suite' 'The check is advisory here, so the job passes'

work="$(new_fixture blocking)" || exit 1
on_target blocking .test-pyramid $'blocking true\n' && fixture_git -C "$work" pull --quiet --rebase origin main
go_tests "$work/e2e/flow_test.go" e2e 3 && commit_all "$work" 'e2e tests'
output="$(run_check "$work")"
expect "fails when the target branch's .test-pyramid is blocking" "$output" 1 \
  'policy from .test-pyramid on "main": blocking true' 'ERROR: this pull request worsens the test pyramid'

printf 'blocking false\n' > "$work/.test-pyramid" && commit_all "$work" 'try to loosen the policy'
output="$(run_check "$work")"
expect "still fails when the pull request itself turns blocking off: the target branch decides" "$output" 1 \
  'this pull request changes .test-pyramid' 'blocking true'

work="$(new_fixture forced)" || exit 1
go_tests "$work/e2e/flow_test.go" e2e 3 && commit_all "$work" 'e2e tests'
expect "fails when TEST_PYRAMID_BLOCKING=true asks for it, with no policy at all" \
  "$(run_check "$work" TEST_PYRAMID_BLOCKING=true)" 1 'blocking true'
expect "refuses a TEST_PYRAMID_BLOCKING that is neither true nor false" \
  "$(run_check "$work" TEST_PYRAMID_BLOCKING=yes)" 2 "TEST_PYRAMID_BLOCKING must be 'true' or 'false'"

work="$(new_fixture invalid)" || exit 1
printf 'blocking yes\nmix 90/20/0\n' > "$work/.test-pyramid" && commit_all "$work" 'a broken policy'
expect "stops on a pull request whose .test-pyramid is invalid, naming each line" "$(run_check "$work")" 2 \
  'the .test-pyramid of this pull request is invalid' 'line 1: blocking is true or false' 'line 2: the mix percentages'

work="$(new_fixture rules)" || exit 1
on_target rules .test-pyramid $'unit ^e2e/\n' && fixture_git -C "$work" pull --quiet --rebase origin main
go_tests "$work/e2e/flow_test.go" e2e 3 && commit_all "$work" 'e2e tests'
expect "classifies both trees with the target branch's path rules" "$(run_check "$work")" 0 \
  'this pull request keeps the test pyramid' '1 path rule(s)'

work="$(new_fixture languages)" || exit 1
mkdir -p "$work/web" && printf "it('adds', () => {});\nit('subtracts', () => {});\n" > "$work/web/sum.test.ts"
commit_all "$work" 'a TypeScript suite'
on_target languages .test-pyramid $'languages go javascript\n' && fixture_git -C "$work" pull --quiet --rebase origin main
expect "judges the suites the target branch's .test-pyramid names, each on its own" "$(run_check "$work")" 0 \
  'test-pyramid [go]:' 'test-pyramid [javascript]:'

echo ""
echo "--- 2. the two commits ---"

# The fork point holds 100 unit tests and 10 e2e tests (top-heavy); the pull request adds 10 unit
# tests; the target branch gains 100 more after the fork. Judged against the merge base the pull
# request improves the suite; judged against the target's tip it would look like it worsened it.
work="$(new_fixture merge-base)" || exit 1
seed="$TEST_DIR/merge-base/seed"
go_tests "$seed/pkg/unit_test.go" '' 100 && go_tests "$seed/e2e/flow_test.go" e2e 10 && printf 'blocking true\n' > "$seed/.test-pyramid"
commit_all "$seed" 'fork point' && fixture_git -C "$seed" push --quiet "$TEST_DIR/merge-base/origin.git" HEAD:refs/heads/main
fixture_git -C "$work" pull --quiet --rebase origin main
go_tests "$work/pkg/feature_test.go" '' 10 && commit_all "$work" 'more unit tests'
go_tests "$seed/pkg/later_test.go" '' 100 && commit_all "$seed" 'the target moves on' &&
  fixture_git -C "$seed" push --quiet "$TEST_DIR/merge-base/origin.git" HEAD:refs/heads/main
expect "compares the pull request with its merge base, not with the target branch's tip" "$(run_check "$work")" 0 \
  'with the merge base with "main"' 'this pull request keeps the test pyramid'

# GitHub Actions and Azure DevOps check out a merge of the pull request into its target: its merge
# base with the target branch is the target's tip, the commit the merge was made on.
fixture_git -C "$work" fetch --quiet origin && fixture_git -C "$work" merge --quiet --no-ff --no-edit origin/main
tip="$(fixture_git -C "$work" rev-parse --short=12 origin/main)"
expect "compares a merge commit, as the platforms check one out, with the target it merges into" \
  "$(run_check "$work")" 0 "with the merge base with \"main\" ($tip)"

shallow="$TEST_DIR/shallow"
fixture_git -C "$TEST_DIR/advisory/work" push --quiet origin feature &&
  fixture_git clone --quiet --depth 1 --branch feature "file://$TEST_DIR/advisory/origin.git" "$shallow"
output="$(run_check "$shallow")"
expect "deepens a shallow clone to reach the merge base" "$output" 0 'WORSENED'
if grep -q 'no merge base' <<< "$output"; then fail "a shallow clone falls back to the target's tip"; else pass "a shallow clone is not compared with the target's tip"; fi

notrepo="$TEST_DIR/not-a-repository"
mkdir -p "$notrepo"
expect "stops outside a git repository" "$(run_check "$notrepo")" 2 'not inside a git repository'
expect "stops when no suite is named" "$(run_check "$TEST_DIR/kept/work" TEST_PYRAMID_LANGUAGE=)" 2 'no suite to judge'
expect "stops on a language no profile exists for" "$(run_check "$TEST_DIR/kept/work" TEST_PYRAMID_LANGUAGE=cobol)" 2 \
  'no test-pyramid profile for "cobol"'

echo ""
echo "--- 3. what each platform shows ---"

summary="$TEST_DIR/step-summary.md"
: > "$summary"
output="$(run_check "$TEST_DIR/advisory/work" GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$summary")"
expect "annotates the run on GitHub Actions" "$output" 0 '::warning title=Test pyramid::This pull request worsens the test pyramid of: go.'
check "appends the summary to GitHub's job summary" grep -qF '### `go`: worsens the test pyramid' "$summary"
expect "logs an issue and uploads the summary on Azure DevOps" "$(run_check "$TEST_DIR/advisory/work" TF_BUILD=True)" 0 \
  '##vso[task.logissue type=warning]' '##vso[task.uploadsummary]'
expect "fails with an error annotation when blocking, on GitHub Actions" \
  "$(run_check "$TEST_DIR/blocking/work" GITHUB_ACTIONS=true)" 1 '::error title=Test pyramid::'

echo ""
echo "--- 4. the wiring ---"

# The profiles the checker has, read from where they are declared.
mapfile -t KNOWN < <(grep -o 'Language: *"[a-z]*"' "$PROFILES" | sed 's/.*"\(.*\)"/\1/' | sort)
known() {
  local language
  for language in "${KNOWN[@]}"; do [[ "$language" == "$1" ]] && return 0; done
  return 1
}
check "the profiles are the nine languages the pipelines test" \
  test "${KNOWN[*]}" = 'dart dotnet go java javascript php python ruby terraform'

# GitHub Actions: every base workflow with a tests stage runs the check, for its language, on pull
# requests only, behind the stage barrier's status gate.
declare -A WORKFLOW_LANGUAGE=(
  [go.yaml]=go [pdm.yaml]=python [gradle.yaml]=java [maven.yaml]=java [yarn.yaml]=javascript
  [npm.yaml]=javascript [composer.yaml]=php [bundler.yaml]=ruby [dotnet.yaml]=dotnet [dart.yaml]=dart
  [terra.yaml]=terraform
)
# This repository's own CI is not a template: its suites are shell scripts that judge pipelines.
EXCLUDED_WORKFLOWS=' default.yaml '
for workflow in "$ROOT_DIR"/.github/workflows/*.yaml; do
  name="${workflow##*/}"
  grep -q "name: 'tests > test:all'" "$workflow" || continue
  [[ "$EXCLUDED_WORKFLOWS" == *" $name "* ]] && continue
  language="${WORKFLOW_LANGUAGE[$name]:-}"
  if [[ -z "$language" ]]; then
    fail "$name has a tests stage and no expected test-pyramid language here: add it to WORKFLOW_LANGUAGE"
    continue
  fi
  block="$(awk '/^  tests-test_pyramid:$/ { on = 1; print; next } on && /^  [a-z]/ { on = 0 } on' "$workflow")"
  if grep -qF "name: 'tests > test:pyramid'" <<< "$block" &&
    grep -qF "uses: 'rios0rios0/pipelines/github/global/stages/30-tests/test-pyramid@main'" <<< "$block" &&
    grep -qF "language: '$language'" <<< "$block" &&
    grep -qF "if: \"!cancelled() && !failure() && github.event_name == 'pull_request'\"" <<< "$block" &&
    known "$language"; then
    pass "$name runs tests > test:pyramid for $language on pull requests"
  else
    fail "$name runs tests > test:pyramid for $language on pull requests"
    printf '%s\n' "$block" | sed 's/^/        /'
  fi
done

ACTION="$ROOT_DIR/github/global/stages/30-tests/test-pyramid/action.yaml"
check "the GitHub composite checks out the whole history" grep -qx '        fetch-depth: 0' "$ACTION"
check "the GitHub composite provisions Go for the checker, with no cache" \
  grep -qE "uses: 'actions/setup-go@[0-9a-f]{40}'" "$ACTION"
check "the GitHub composite passes the language through env, never into run:" \
  grep -qF 'TEST_PYRAMID_LANGUAGE: "${{ inputs.language }}"' "$ACTION"
check "the GitHub composite's report upload cannot fail the job" grep -qx '      continue-on-error: true' "$ACTION"

# GitLab CI: every tests stage with a test:all job runs the shared job for a known language.
GITLAB_TEMPLATE="$ROOT_DIR/gitlab/global/stages/30-tests/test-pyramid.yaml"
for stage in "$ROOT_DIR"/gitlab/*/stages/30-tests/*.yaml; do
  name="${stage#"$ROOT_DIR/"}"
  grep -q '^test:all:' "$stage" || continue
  language="$(sed -n "s/^    TEST_PYRAMID_LANGUAGE: '\([a-z]*\)'$/\1/p" "$stage")"
  if grep -qF "gitlab/global/stages/30-tests/test-pyramid.yaml'" "$stage" && grep -q '^test:pyramid:$' "$stage" &&
    grep -qF "  extends: '.test-pyramid'" "$stage" && [[ -n "$language" ]] && known "$language"; then
    pass "$name runs test:pyramid for $language"
  else
    fail "$name runs test:pyramid for a known language"
  fi
done
check "the GitLab CI job runs on merge requests only" \
  test "$(awk '/^  rules:/ { on = 1; next } on && /^    - if:/ { print }' "$GITLAB_TEMPLATE")" = '    - if: "$CI_MERGE_REQUEST_IID"'
check "the GitLab CI job clones the whole history" grep -qx '    GIT_DEPTH: 0' "$GITLAB_TEMPLATE"
check "the GitLab CI job runs in the pinned Go image" grep -qE "^  image: 'golang:[0-9.]+@sha256:[0-9a-f]{64}'$" "$GITLAB_TEMPLATE"

# Azure DevOps: every tests stage includes the shared job for a known language.
AZURE_TEMPLATE="$ROOT_DIR/azure-devops/global/stages/30-tests/test-pyramid.yaml"
for stage in "$ROOT_DIR"/azure-devops/*/stages/30-test*/*.yaml; do
  name="${stage#"$ROOT_DIR/"}"
  [[ "$name" == azure-devops/argocd/* ]] && continue # renders and validates manifests; no test suite
  grep -q "^      - job: 'test_" "$stage" || continue
  language="$(awk '/test-pyramid.yaml'"'"'$/ { on = 1; next } on && /LANGUAGE:/ { gsub(/[^a-z]/, "", $2); print $2; exit }' "$stage")"
  if grep -qF "      - template: '../../../global/stages/30-tests/test-pyramid.yaml'" "$stage" &&
    [[ -n "$language" ]] && known "$language"; then
    pass "$name runs test:pyramid for $language"
  else
    fail "$name runs test:pyramid for a known language"
  fi
done
check "the Azure DevOps job runs on pull requests only" \
  grep -qF "condition: and(succeeded(), eq(variables['Build.Reason'], 'PullRequest'))" "$AZURE_TEMPLATE"
check "the Azure DevOps job checks out the whole history, keeping the credentials for the fetch" \
  grep -qx '        fetchDepth: 0' "$AZURE_TEMPLATE"
check "the Azure DevOps job provisions Go for the checker" grep -qF "task: 'GoTool@0'" "$AZURE_TEMPLATE"

echo ""
echo "--- 5. make test-pyramid ---"

for fragment in golang python java javascript dotnet dart terraform terra; do
  language="$(sed -n 's/^export TEST_PYRAMID_LANGUAGE ?= \([a-z]*\)$/\1/p' "$ROOT_DIR/makefiles/$fragment.mk")"
  if [[ -n "$language" ]] && known "$language"; then pass "$fragment.mk names the $language suite"; else fail "$fragment.mk names a known suite"; fi
done
printf 'SCRIPTS_DIR := %s\ninclude $(SCRIPTS_DIR)/makefiles/common.mk\ninclude $(SCRIPTS_DIR)/makefiles/golang.mk\n' "$ROOT_DIR" > "$TEST_DIR/kept/work/Makefile"
output="$(
  cd "$TEST_DIR/kept/work" || exit 97
  env -u TEST_PYRAMID_LANGUAGE -u REPORT_PATH -u GITHUB_ACTIONS -u TF_BUILD GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    make --no-print-directory test-pyramid TARGET_BRANCH=main 2>&1
)"
status=$?
expect "make test-pyramid judges the language fragment's suite against TARGET_BRANCH" "$(printf '%s\nexit=%s\n' "$output" "$status")" 0 \
  'test-pyramid [go]:' 'this pull request keeps the test pyramid'

echo ""
echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo "================================"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
  exit 1
fi
echo "All test-pyramid tests passed!"
