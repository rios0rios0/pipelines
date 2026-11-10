#!/usr/bin/env bash
# Validation script for the goose migration-order check
# (`global/scripts/languages/golang/migration-order/run.sh`).
#
# goose refuses to apply a migration older than the version a database has reached, so a pull
# request whose new migration is not newer than the newest one on its target branch passes review
# and the tests, then stops the first deploy after the merge. The check finds the goose directories
# from the files themselves, fetches the target branch and compares versions as goose reads them.
#
# Every case runs the real script against throwaway repositories whose `origin` is a local bare
# repository, so the fetch, the detection and the verdict are all exercised with no network. The
# wiring half asserts that each platform's Go code-check stage runs the script on pull requests
# only, and that `golang.mk` exposes it as `make migration-order`.
set -uo pipefail

echo "=== Testing the goose migration-order check ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$ROOT_DIR/global/scripts/languages/golang/migration-order/run.sh"

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

# goose_sql <path>: writes a SQL migration goose would read.
goose_sql() {
  mkdir -p "$(dirname "$1")" || return 1
  printf -- '-- +goose Up\nSELECT 1;\n\n-- +goose Down\nSELECT 1;\n' > "$1"
}

# goose_go <path>: writes a Go migration, registered the way goose's Go migrations register.
goose_go() {
  mkdir -p "$(dirname "$1")" || return 1
  printf 'package migrations\n\nimport "github.com/pressly/goose/v3"\n\nfunc init() { goose.AddMigrationContext(nil, nil) }\n' > "$1"
}

# plain_sql <path>: a numbered SQL file goose does not read (no annotation).
plain_sql() {
  mkdir -p "$(dirname "$1")" || return 1
  printf 'SELECT 1;\n' > "$1"
}

# write_files <repo> <path>...: writes each path by its kind -- `*.go` a Go migration, a path under
# `plain/` a plain SQL file, anything else a goose SQL migration.
write_files() {
  local repo="$1" path
  shift
  for path in "$@"; do
    case "$path" in
      *.go) goose_go "$repo/$path" || return 1 ;;
      plain/*) plain_sql "$repo/$path" || return 1 ;;
      *) goose_sql "$repo/$path" || return 1 ;;
    esac
  done
}

# new_fixture <name> <path>...: a bare `origin` whose `main` holds the given files, and a clone of
# it on a branch named `feature`. Prints the clone's path.
new_fixture() {
  local name="$1"
  shift
  local origin="$TEST_DIR/$name/origin.git" seed="$TEST_DIR/$name/seed" work="$TEST_DIR/$name/work"
  fixture_git init --quiet --bare "$origin" || return 1
  fixture_git init --quiet "$seed" || return 1
  write_files "$seed" "$@" || return 1
  fixture_git -C "$seed" add -A || return 1
  fixture_git -C "$seed" commit --quiet --allow-empty -m base || return 1
  fixture_git -C "$seed" push --quiet "$origin" HEAD:refs/heads/main || return 1
  fixture_git clone --quiet "$origin" "$work" || return 1
  fixture_git -C "$work" checkout --quiet -b feature || return 1
  echo "$work"
}

# commit_files <repo> <path>...: writes the files and commits them.
commit_files() {
  local repo="$1"
  shift
  write_files "$repo" "$@" || return 1
  fixture_git -C "$repo" add -A || return 1
  fixture_git -C "$repo" commit --quiet -m change || return 1
}

# push_to_target <name> <branch> <path>...: lands files on the target branch behind the clone's
# back, through the seed repository, so only a fetch can tell the clone about them.
push_to_target() {
  local name="$1" branch="$2"
  shift 2
  local seed="$TEST_DIR/$name/seed"
  if fixture_git -C "$seed" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    fixture_git -C "$seed" checkout --quiet "$branch" || return 1
  else
    fixture_git -C "$seed" checkout --quiet -b "$branch" main || return 1
  fi
  commit_files "$seed" "$@" || return 1
  fixture_git -C "$seed" push --quiet --force "$TEST_DIR/$name/origin.git" "HEAD:refs/heads/$branch" || return 1
}

# run_check <repo> <target-argument or ''> [NAME=value...]: runs the check inside <repo> with no CI
# variable but those named and no global git configuration. Prints its output, then `exit=<status>`.
run_check() {
  local repo="$1" target="$2"
  shift 2
  local args=() output status
  [[ -n "$target" ]] && args=("$target")
  output="$(
    cd "$repo" || exit 97
    env -u SYSTEM_PULLREQUEST_TARGETBRANCH -u GITHUB_BASE_REF -u CI_MERGE_REQUEST_TARGET_BRANCH_NAME \
      -u GOOSE_MIGRATION_DIRS GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$@" \
      sh "$CHECK_SCRIPT" ${args[@]+"${args[@]}"} 2>&1
  )"
  status=$?
  printf '%s\nexit=%s\n' "$output" "$status"
}

# assert_check <description> <expected status> <run_check output> [text the output holds...]
# A leading `!` on a text asserts the output does NOT hold it.
assert_check() {
  local description="$1" expected="$2" output="$3"
  shift 3
  local status="${output##*exit=}" problems='' text
  [[ "$status" == "$expected" ]] || problems="$problems exit $status (expected $expected);"
  for text in "$@"; do
    if [[ "$text" == '!'* ]]; then
      grep -qF -- "${text#!}" <<<"$output" && problems="$problems holds [${text#!}];"
    else
      grep -qF -- "$text" <<<"$output" || problems="$problems lacks [$text];"
    fi
  done
  if [[ -z "$problems" ]]; then
    pass "$description"
  else
    fail "$description --$problems"
    printf '%s\n' "$output" | sed 's/^/        /'
  fi
}

BASE_MIGRATIONS=(db/migrations/20260101000000_a.sql db/migrations/20260201000000_b.sql)

# =============================================================================
# Test 1: the verdict
# =============================================================================
echo "TEST 1: a new migration must be newer than the newest one on the target branch"

work="$(new_fixture newer "${BASE_MIGRATIONS[@]}")" || exit 1
commit_files "$work" db/migrations/20260301000000_c.sql || exit 1
assert_check "a newer migration passes" 0 "$(run_check "$work" '')" \
  "ok    20260301000000_c.sql" "newest on main is 20260201000000_b.sql"

work="$(new_fixture older "${BASE_MIGRATIONS[@]}")" || exit 1
commit_files "$work" db/migrations/20260115000000_late.sql || exit 1
assert_check "an older migration fails and names the newest one" 1 "$(run_check "$work" '')" \
  "FAIL  20260115000000_late.sql is not newer than 20260201000000_b.sql" "ERROR: a new goose migration"

work="$(new_fixture equal "${BASE_MIGRATIONS[@]}")" || exit 1
commit_files "$work" db/migrations/20260201000000_twin.sql || exit 1
assert_check "a migration with the newest one's version fails" 1 "$(run_check "$work" '')" \
  "FAIL  20260201000000_twin.sql is not newer than 20260201000000_b.sql"

work="$(new_fixture twins "${BASE_MIGRATIONS[@]}")" || exit 1
commit_files "$work" db/migrations/20260301000000_c.sql db/migrations/20260301000000_d.sql || exit 1
assert_check "two new migrations sharing a version fail" 1 "$(run_check "$work" '')" \
  "has the same version as"

work="$(new_fixture unchanged "${BASE_MIGRATIONS[@]}")" || exit 1
commit_files "$work" README.md || exit 1
assert_check "a branch adding no migration passes" 0 "$(run_check "$work" '')" \
  "db/migrations: no new migrations"
echo ""

# =============================================================================
# Test 2: the target branch is fetched, not trusted
# =============================================================================
echo "TEST 2: a target branch that moved after the branch was opened is the one judged against"
# The clone was made before the target gained a newer migration, so its `origin/main` is stale:
# only a fetch shows that the branch's migration has meanwhile become the older one.
work="$(new_fixture moved "${BASE_MIGRATIONS[@]}")" || exit 1
commit_files "$work" db/migrations/20260301000000_c.sql || exit 1
push_to_target moved main db/migrations/20260401000000_d.sql || exit 1
assert_check "a migration overtaken on the target fails" 1 "$(run_check "$work" '')" \
  "FAIL  20260301000000_c.sql is not newer than 20260401000000_d.sql"
echo ""

# =============================================================================
# Test 3: a renamed migration is judged by its new version
# =============================================================================
echo "TEST 3: renames are additions"
# With rename detection a renamed file is neither added nor judged, which would wave through the
# exact rename that fixes -- or breaks -- the order.
work="$(new_fixture renamed-older "${BASE_MIGRATIONS[@]}")" || exit 1
fixture_git -C "$work" mv db/migrations/20260201000000_b.sql db/migrations/20260110000000_b.sql || exit 1
fixture_git -C "$work" commit --quiet -m rename || exit 1
assert_check "a migration renamed to an older version fails" 1 "$(run_check "$work" '')" \
  "FAIL  20260110000000_b.sql is not newer than 20260201000000_b.sql"

work="$(new_fixture renamed-newer "${BASE_MIGRATIONS[@]}")" || exit 1
fixture_git -C "$work" mv db/migrations/20260201000000_b.sql db/migrations/20260301000000_b.sql || exit 1
fixture_git -C "$work" commit --quiet -m rename || exit 1
assert_check "a migration renamed to a newer version is judged, and passes" 0 "$(run_check "$work" '')" \
  "ok    20260301000000_b.sql"
echo ""

# =============================================================================
# Test 4: versions are read as goose reads them
# =============================================================================
echo "TEST 4: sequential numbering, leading zeros and long versions"
# `0009` is not a number in shell arithmetic, which reads a leading zero as octal.
work="$(new_fixture sequential migrations/0007_g.sql migrations/0008_h.sql)" || exit 1
commit_files "$work" migrations/0009_i.sql || exit 1
assert_check "0009 is newer than 0008" 0 "$(run_check "$work" '')" "ok    0009_i.sql"

work="$(new_fixture sequential-older migrations/0007_g.sql migrations/0010_j.sql)" || exit 1
commit_files "$work" migrations/0009_i.sql || exit 1
assert_check "0009 is not newer than 0010" 1 "$(run_check "$work" '')" \
  "FAIL  0009_i.sql is not newer than 0010_j.sql"

work="$(new_fixture zero-padded migrations/0042_a.sql)" || exit 1
commit_files "$work" migrations/42_b.sql || exit 1
assert_check "42 and 0042 are the same version" 1 "$(run_check "$work" '')" \
  "FAIL  42_b.sql is not newer than 0042_a.sql"

# 9007199254740993 rounds to 9007199254740992 as a double, so a numeric comparison in awk calls
# the two equal and fails a migration that is newer.
work="$(new_fixture long-version migrations/9007199254740992_a.sql)" || exit 1
commit_files "$work" migrations/9007199254740993_b.sql || exit 1
assert_check "a version past 2^53 compares exactly" 0 "$(run_check "$work" '')" \
  "ok    9007199254740993_b.sql"
echo ""

# =============================================================================
# Test 5: which directories are goose directories
# =============================================================================
echo "TEST 5: the directories are read from the files"
work="$(new_fixture detection "${BASE_MIGRATIONS[@]}" \
  internal/store/testdata/migrations/20300101000000_future.sql \
  vendor/example.com/lib/migrations/20300101000000_future.sql \
  plain/sql/05_init.sql)" || exit 1
commit_files "$work" \
  internal/store/testdata/migrations/20200101000000_old.sql \
  vendor/example.com/lib/migrations/20200101000000_old.sql \
  plain/sql/01_seed.sql || exit 1
assert_check "testdata, vendor and files without the goose annotation are not checked" 0 \
  "$(run_check "$work" '')" '!testdata' '!vendor' '!plain/sql'

work="$(new_fixture go-migrations db/migrations/20260201000000_b.go)" || exit 1
commit_files "$work" db/migrations/20260101000000_a.go || exit 1
assert_check "a Go migration is checked like a SQL one" 1 "$(run_check "$work" '')" \
  "FAIL  20260101000000_a.go is not newer than 20260201000000_b.go"

# goose reads one directory, so each is compared with itself: a seeders directory is neither
# older nor newer than the schema beside it.
work="$(new_fixture per-directory db/migrations/20260601000000_m.sql db/seeders/20260101000000_s.sql)" || exit 1
commit_files "$work" db/seeders/20260201000000_t.sql || exit 1
assert_check "each directory is compared with its own newest migration" 0 "$(run_check "$work" '')" \
  "ok    20260201000000_t.sql" "db/seeders: newest on main is 20260101000000_s.sql"

# goose reads a directory's own files, not the tree under it: the newer version in `archive/` is
# not the parent's newest, so the parent's new migration is judged against its own siblings only.
work="$(new_fixture subdirectory db/migrations/20260601000000_m.sql \
  db/migrations/archive/20300101000000_future.sql)" || exit 1
commit_files "$work" db/migrations/20260701000000_n.sql || exit 1
assert_check "a subdirectory is not part of its parent" 0 "$(run_check "$work" '')" \
  "db/migrations: newest on main is 20260601000000_m.sql" "ok    20260701000000_n.sql" \
  "db/migrations/archive: no new migrations"

work="$(new_fixture new-subdirectory db/migrations/20260601000000_m.sql)" || exit 1
commit_files "$work" db/migrations/archive/20200101000000_old.sql || exit 1
assert_check "a new directory has nothing to compare with" 0 "$(run_check "$work" '')" \
  "db/migrations/archive: no migrations on 'main' yet" "db/migrations: no new migrations"

work="$(new_fixture root-directory 20260201000000_b.sql)" || exit 1
commit_files "$work" 20260101000000_a.sql || exit 1
assert_check "migrations at the repository root are checked" 1 "$(run_check "$work" '')" \
  "FAIL  20260101000000_a.sql is not newer than 20260201000000_b.sql"

# Without goose migrations the check returns before fetching: the origin is gone and it passes.
work="$(new_fixture no-goose plain/sql/05_init.sql)" || exit 1
commit_files "$work" plain/sql/01_seed.sql || exit 1
rm -rf "$TEST_DIR/no-goose/origin.git"
assert_check "a repository without goose migrations passes without fetching" 0 "$(run_check "$work" '')" \
  "no goose migrations in this repository"
echo ""

# =============================================================================
# Test 6: the target branch each platform names
# =============================================================================
echo "TEST 6: the target branch comes from the platform, then from origin's default branch"
work="$(new_fixture targets "${BASE_MIGRATIONS[@]}")" || exit 1
push_to_target targets develop db/migrations/20260501000000_d.sql || exit 1
commit_files "$work" db/migrations/20260301000000_c.sql || exit 1
assert_check "no variable: origin's default branch" 0 "$(run_check "$work" '')" "newest on main is"
assert_check "an argument names the target" 1 "$(run_check "$work" develop)" "newest on develop is"
assert_check "Azure DevOps: SYSTEM_PULLREQUEST_TARGETBRANCH, a full ref" 1 \
  "$(run_check "$work" '' SYSTEM_PULLREQUEST_TARGETBRANCH=refs/heads/develop)" "newest on develop is"
assert_check "GitHub Actions: GITHUB_BASE_REF" 1 \
  "$(run_check "$work" '' GITHUB_BASE_REF=develop)" "newest on develop is"
assert_check "GitLab CI: CI_MERGE_REQUEST_TARGET_BRANCH_NAME" 1 \
  "$(run_check "$work" '' CI_MERGE_REQUEST_TARGET_BRANCH_NAME=develop)" "newest on develop is"
echo ""

# =============================================================================
# Test 7: a shallow checkout, and a fetch that fails
# =============================================================================
echo "TEST 7: shallow checkouts and fetch failures"
# Every platform checks out shallow by default; the script fetches the target's tree at depth 1.
new_fixture shallow "${BASE_MIGRATIONS[@]}" >/dev/null || exit 1
shallow="$TEST_DIR/shallow/shallow-work"
fixture_git clone --quiet --depth 1 "file://$TEST_DIR/shallow/origin.git" "$shallow" || exit 1
fixture_git -C "$shallow" checkout --quiet -b feature || exit 1
commit_files "$shallow" db/migrations/20260115000000_late.sql || exit 1
push_to_target shallow main db/migrations/20260401000000_d.sql || exit 1
assert_check "a shallow clone fetches the moved target and judges against it" 1 \
  "$(run_check "$shallow" '')" "FAIL  20260115000000_late.sql is not newer than 20260401000000_d.sql"
if [[ "$(fixture_git -C "$shallow" rev-parse --is-shallow-repository)" == 'true' ]]; then
  pass "the shallow clone stays shallow"
else
  fail "the fetch deepened the shallow clone"
fi

work="$(new_fixture offline "${BASE_MIGRATIONS[@]}")" || exit 1
commit_files "$work" db/migrations/20260115000000_late.sql || exit 1
fixture_git -C "$work" remote set-url origin "$TEST_DIR/offline/missing.git" || exit 1
assert_check "an unreachable origin falls back to the copy fetched earlier" 1 "$(run_check "$work" '')" \
  "could not fetch 'main' from origin" "FAIL  20260115000000_late.sql"
assert_check "a target that was never fetched cannot be checked" 2 "$(run_check "$work" release)" \
  "cannot fetch 'release' from origin"

# The ceiling keeps git from finding a repository above the scratch directory, wherever TMPDIR is.
outside="$TEST_DIR/not-a-repository"
mkdir -p "$outside" || exit 1
assert_check "outside a git repository the check cannot run" 2 \
  "$(run_check "$outside" '' GIT_CEILING_DIRECTORIES="$TEST_DIR")" "not inside a git repository"
echo ""

# =============================================================================
# Test 8: GOOSE_MIGRATION_DIRS
# =============================================================================
echo "TEST 8: GOOSE_MIGRATION_DIRS replaces the detection, or turns the check off"
work="$(new_fixture configured "${BASE_MIGRATIONS[@]}" db/other/20260101000000_x.sql)" || exit 1
commit_files "$work" db/migrations/20260115000000_late.sql db/other/20260201000000_y.sql || exit 1
assert_check "only the named directory is checked" 0 \
  "$(run_check "$work" '' GOOSE_MIGRATION_DIRS=db/other)" "ok    20260201000000_y.sql" '!db/migrations'
assert_check "several directories, a trailing slash tolerated" 1 \
  "$(run_check "$work" '' 'GOOSE_MIGRATION_DIRS=db/other db/migrations/')" \
  "FAIL  20260115000000_late.sql"
assert_check "a named directory without migrations is refused, not passed" 2 \
  "$(run_check "$work" '' GOOSE_MIGRATION_DIRS=db/typo)" "GOOSE_MIGRATION_DIRS names 'db/typo'"
assert_check "none turns the check off" 0 \
  "$(run_check "$work" '' GOOSE_MIGRATION_DIRS=none)" "turned off"
echo ""

# =============================================================================
# Test 9: the wiring
# =============================================================================
echo "TEST 9: every platform runs the check on pull requests, and make runs it locally"
SCRIPT_PATH='global/scripts/languages/golang/migration-order/run.sh'

GITHUB_WORKFLOW="$ROOT_DIR/.github/workflows/go.yaml"
GITHUB_ACTION="$ROOT_DIR/github/golang/stages/10-code-check/migration-order/action.yaml"
job="$(awk '/^  code_check-quality_migration_order:/{found=1; print; next} found && /^  [^ #]/{exit} found' "$GITHUB_WORKFLOW")"
if grep -qF "name: 'code-check > quality:migration-order'" <<<"$job" \
  && grep -qF "github/golang/stages/10-code-check/migration-order@main" <<<"$job" \
  && grep -qF "if: \"github.event_name == 'pull_request'\"" <<<"$job"; then
  pass "GitHub Actions: go.yaml runs code-check > quality:migration-order on pull requests"
else
  fail "GitHub Actions: go.yaml lacks the pull-request-only migration-order job"
fi
if grep -qF "$SCRIPT_PATH" "$GITHUB_ACTION"; then
  pass "GitHub Actions: the composite action runs the script"
else
  fail "GitHub Actions: the composite action does not run $SCRIPT_PATH"
fi

GITLAB_STAGE="$ROOT_DIR/gitlab/golang/stages/10-code-check/go.yaml"
job="$(awk '/^quality:migration-order:/{found=1; print; next} found && /^[^ #]/{exit} found' "$GITLAB_STAGE")"
# shellcheck disable=SC2016 # the GitLab variable is matched as text, never expanded here
if grep -qF "$SCRIPT_PATH" <<<"$job" && grep -qF 'if: "$CI_MERGE_REQUEST_IID"' <<<"$job" \
  && ! grep -qF 'CI_DEFAULT_BRANCH' <<<"$job"; then
  pass "GitLab CI: quality:migration-order runs the script on merge requests only"
else
  fail "GitLab CI: quality:migration-order is missing or not limited to merge requests"
fi

AZURE_STAGE="$ROOT_DIR/azure-devops/golang/stages/10-code-check/go.yaml"
job="$(awk "/- job: 'quality_migration_order'/{found=1; print; next} found && /^      - (job|template):/{exit} found" "$AZURE_STAGE")"
if grep -qF "displayName: 'quality:migration-order'" <<<"$job" && grep -qF "$SCRIPT_PATH" <<<"$job" \
  && grep -qF "condition: eq(variables['Build.Reason'], 'PullRequest')" <<<"$job"; then
  pass "Azure DevOps: quality:migration-order runs the script on pull requests"
else
  fail "Azure DevOps: quality:migration-order is missing or not limited to pull requests"
fi

if grep -qE '^migration-order:' "$ROOT_DIR/makefiles/golang.mk" \
  && grep -qF "$SCRIPT_PATH" "$ROOT_DIR/makefiles/golang.mk"; then
  pass "golang.mk provides make migration-order"
else
  fail "golang.mk lacks the migration-order target"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
