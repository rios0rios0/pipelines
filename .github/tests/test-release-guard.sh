#!/usr/bin/env bash
# Tests for the release guard: `global/scripts/shared/semver.sh` (SemVer 2.0.0 precedence),
# `global/scripts/deploy/release-guard/run.sh` (the verdict), the
# `github/global/stages/50-deployment/release-guard` action, and its wiring into every
# deployment workflow.
#
# WHY THIS EXISTS
#
# Every deployment workflow here deploys `production` from a tag run, and a tag run starts
# whenever a tag is pushed. A weekly job re-pushed the tags of superseded bumps (backend
# `2.1.0`/`2.1.1` after `2.1.2`, frontend `0.4.0` after `0.4.1`), and each push started a
# production deploy of a release weeks old (medhub-life/.github-private#920). The guard refuses a
# tag older than the newest SemVer tag unless a rollback is asked for, and passes everything it
# cannot order, so it changes nothing for a caller whose tags are not SemVer.
#
# Four classes of assertion:
#
#   1. PRECEDENCE -- section 11 of the SemVer specification, including the cases a version sort
#      gets wrong: a release outranks its own pre-releases, a numeric identifier ranks below an
#      alphanumeric one, and a number past 2^53 still compares exactly.
#   2. VERDICT -- the guard run against a given tag list: older (skipped), newest (deployed), a
#      re-run of the newest (deployed), a tag that is not SemVer (deployed), and an older tag with
#      the rollback input (deployed), plus the platform tag sources and what reaches the outputs.
#   3. REMOTE -- the same verdicts with the tags listed from a real remote, offline: a bare
#      fixture repository, so the listing a CI checkout depends on runs for real, reads the
#      REMOTE's tags rather than the clone's, and reaches no verdict when the remote is gone.
#   4. WIRING -- every deployment workflow gates its deployment job on the guard, held by the Go
#      check `internal/testsuites/releaseguard`, which is proven to fire on deliberate violations.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
export SCRIPTS_DIR

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_true() {
  local description="$1" condition="$2"
  if eval "$condition"; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_equals() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    echo -e "${RED}        expected: $expected${NC}"
    echo -e "${RED}        actual:   $actual${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_empty() {
  local description="$1" findings="$2"
  if [[ -z "$findings" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    printf '%s\n' "$findings" | sed 's/^/        /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

SEMVER_SH="$SCRIPTS_DIR/global/scripts/shared/semver.sh"
GUARD_SH="$SCRIPTS_DIR/global/scripts/deploy/release-guard/run.sh"
GUARD_ACTION="$SCRIPTS_DIR/github/global/stages/50-deployment/release-guard/action.yaml"
WORKFLOWS_DIR="$SCRIPTS_DIR/.github/workflows"

WORK_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/home" "$WORK_DIR/plain" || exit 1

# semver <function> [args...]: one function of the library, run as the scripts run it.
semver() {
  sh -c '. "$1"; shift; "$@"' sh "$SEMVER_SH" "$@"
}

# run_guard <dir> [VAR=value...]: runs the guard in <dir> with nothing of this shell's environment
# but PATH -- in particular none of the GITHUB_* variables a CI run of this suite carries -- and
# leaves the combined output in $OUT, the exit status in $STATUS, what reached `$GITHUB_OUTPUT` in
# $OUTPUTS, and the job summary in $SUMMARY.
run_guard() {
  local dir="$1"
  shift
  local outputs="$WORK_DIR/github-output" summary="$WORK_DIR/step-summary"
  : > "$outputs"
  : > "$summary"
  STATUS=0
  OUT="$(
    cd "$dir" || exit 1
    env -i PATH="$PATH" HOME="$WORK_DIR/home" SCRIPTS_DIR="$SCRIPTS_DIR" \
      GITHUB_OUTPUT="$outputs" GITHUB_STEP_SUMMARY="$summary" "$@" sh "$GUARD_SH" 2>&1
  )" || STATUS=$?
  OUTPUTS="$(cat "$outputs")"
  # shellcheck disable=SC2034  # read by assert_true's eval'd conditions, which ShellCheck cannot see
  SUMMARY="$(cat "$summary")"
}

# The tags the incident left behind on the backend: superseded bumps re-pushed below the newest.
INCIDENT_TAGS=$'0.4.0\n2.1.0\n2.1.1\n2.1.2\nrelease-notes'

echo "=== Release guard ==="
echo ""
echo "1. Precedence (semver.sh)"

assert_true "semver.sh is sourced, not executed: it carries no executable bit" "[[ ! -x '$SEMVER_SH' ]]"
assert_true "run.sh is executable" "[[ -x '$GUARD_SH' ]]"

for tag in 0.0.0 1.0.0 v1.2.3 1.0.0-alpha 1.0.0-alpha.1 1.0.0-0.3.7 1.0.0-x.7.z.92 1.0.0-x-y-z.-- \
  1.0.0+20130313144700 1.0.0-beta+exp.sha.5114f85 1.0.0+21AF26D3----117B344092BD 1.0.0+001 \
  99999999999999999999.0.0; do
  assert_true "'$tag' names a version" "semver semver_version '$tag' > /dev/null"
done
for tag in '' 1.0 1.0.0.0 01.0.0 1.01.0 1.0.0- 1.0.0+ 1.0.0-01 1.0.0-alpha..1 1.0.0-alpha. vv1.0.0 \
  V1.0.0 app/1.0.0 release-2026 ' 1.0.0' 1.0.0_1; do
  assert_true "'$tag' names no version" "! semver semver_version '$tag' > /dev/null"
done
assert_equals "the version a v-prefixed tag names drops the prefix" "1.2.3" "$(semver semver_version v1.2.3)"

# Section 11's own example, in ascending order, then past the release.
ORDERED=(1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta 1.0.0-beta 1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1
  1.0.0 2.0.0 2.1.0 2.1.1)
for ((index = 1; index < ${#ORDERED[@]}; index++)); do
  lower="${ORDERED[index - 1]}"
  higher="${ORDERED[index]}"
  assert_equals "$lower < $higher" "-1" "$(semver semver_compare "$lower" "$higher")"
  assert_equals "$higher > $lower" "1" "$(semver semver_compare "$higher" "$lower")"
done
assert_equals "a numeric identifier ranks below an alphanumeric one" "-1" "$(semver semver_compare 1.0.0-1 1.0.0-alpha)"
assert_equals "numeric identifiers compare as numbers (9 < 10)" "-1" "$(semver semver_compare 1.0.0-alpha.9 1.0.0-alpha.10)"
assert_equals "core numbers compare as numbers (1.9 < 1.10)" "-1" "$(semver semver_compare 1.9.0 1.10.0)"
assert_equals "a number past 2^53 still compares exactly" "1" \
  "$(semver semver_compare 9007199254740993.0.0 9007199254740992.0.0)"
assert_equals "alphanumeric identifiers compare in ASCII order (B < a)" "-1" "$(semver semver_compare 1.0.0-B 1.0.0-a)"
assert_equals "the v prefix does not change precedence" "0" "$(semver semver_compare v1.2.3 1.2.3)"
assert_equals "build metadata does not change precedence" "0" "$(semver semver_compare 1.0.0+a 1.0.0+b)"
assert_true "comparing a tag that names no version is an error, not an order" \
  "! semver semver_compare 1.0.0 release-2026 > /dev/null"

assert_equals "the highest of a list skips what names no version" "2.1.2" \
  "$(printf '%s\n' "$INCIDENT_TAGS" | semver semver_highest)"
assert_equals "a release outranks its own release candidate, whichever is read first" "2.0.0" \
  "$(printf '2.0.0\n2.0.0-rc.1\n1.9.9\n' | semver semver_highest)"
assert_equals "...and in the other order too" "2.0.0" \
  "$(printf '2.0.0-rc.1\n2.0.0\n' | semver semver_highest)"
assert_equals "surrounding blanks are ignored and the tag keeps its spelling" "v3.0.0" \
  "$(printf '  2.0.0\n\tv3.0.0 \r\n' | semver semver_highest)"
assert_equals "of two tags of equal precedence, the first read wins" "v1.0.0" \
  "$(printf 'v1.0.0\n1.0.0\n' | semver semver_highest)"
assert_equals "a list naming no version yields nothing" "" "$(printf 'latest\nrelease-2026\n' | semver semver_highest)"
echo ""

echo "2. Verdict (run.sh)"

run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=2.1.0 RELEASE_GUARD_TAGS="$INCIDENT_TAGS"
assert_equals "older: reaches a verdict" "0" "$STATUS"
assert_equals "older: is NOT deployed, and names the newest release" $'deploy=false\nnewest=2.1.2' "$OUTPUTS"
assert_true "older: the summary says it was not deployed and why" \
  "grep -q 'is older than \`2.1.2\`' <<< \"\$SUMMARY\" && grep -q 'not deployed' <<< \"\$SUMMARY\""
assert_true "older: the summary says how to roll back on purpose" "grep -q 'allow_rollback' <<< \"\$SUMMARY\""
assert_true "older: the verdict is also left in the report directory" \
  "grep -qx 'deploy=false' '$WORK_DIR/plain/build/reports/release-guard/verdict.txt'"

run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=2.1.2 RELEASE_GUARD_TAGS="$INCIDENT_TAGS"
assert_equals "newest: is deployed" $'deploy=true\nnewest=2.1.2' "$OUTPUTS"
assert_equals "newest: reaches a verdict" "0" "$STATUS"

run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=v2.1.2 RELEASE_GUARD_TAGS="$INCIDENT_TAGS"
assert_equals "equal re-run: a tag of the newest release's precedence is deployed" $'deploy=true\nnewest=v2.1.2' "$OUTPUTS"
run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=2.1.2 RELEASE_GUARD_TAGS="$INCIDENT_TAGS"$'\n2.1.2'
assert_equals "equal re-run: the newest tag pushed again is deployed" "deploy=true" "$(head -n 1 <<< "$OUTPUTS")"

run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=release-2026-11 RELEASE_GUARD_TAGS="$INCIDENT_TAGS"
assert_equals "not SemVer: is deployed as before, compared with nothing" "deploy=true" "$OUTPUTS"
# No RELEASE_GUARD_TAGS and no clone to list: the guard must not even try.
run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=release-2026-11
assert_equals "not SemVer: lists no tags at all, so it needs no remote" "0" "$STATUS"
assert_equals "not SemVer: ...and still deploys" "deploy=true" "$OUTPUTS"

run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=1.0.0 RELEASE_GUARD_TAGS=$'latest\nnightly'
assert_equals "no SemVer tag in the repository: the first release is deployed" $'deploy=true\nnewest=1.0.0' "$OUTPUTS"

run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=2.1.0 RELEASE_GUARD_TAGS="$INCIDENT_TAGS" RELEASE_GUARD_ALLOW_ROLLBACK=true
assert_equals "rollback: an older tag is deployed when the rollback input is set" $'deploy=true\nnewest=2.1.2' "$OUTPUTS"
assert_true "rollback: the summary records that it rolled back on purpose" "grep -q 'rolling back on purpose' <<< \"\$SUMMARY\""
run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=2.1.0 RELEASE_GUARD_TAGS="$INCIDENT_TAGS" RELEASE_GUARD_ALLOW_ROLLBACK=True
assert_equals "rollback: Azure DevOps' 'True' spelling is honoured" "deploy=true" "$(head -n 1 <<< "$OUTPUTS")"
for value in false ture 'yes please' ''; do
  run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=2.1.0 RELEASE_GUARD_TAGS="$INCIDENT_TAGS" RELEASE_GUARD_ALLOW_ROLLBACK="$value"
  assert_equals "rollback: '$value' is not a rollback, so the older tag is refused" "deploy=false" "$(head -n 1 <<< "$OUTPUTS")"
done

run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=2.0.0-rc.1 RELEASE_GUARD_TAGS=$'1.9.0\n2.0.0'
assert_equals "pre-release: a release candidate after its release is older" "deploy=false" "$(head -n 1 <<< "$OUTPUTS")"
run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=2.0.0 RELEASE_GUARD_TAGS=$'1.9.0\n2.0.0-rc.1'
assert_equals "pre-release: a release after its release candidate is newest" "deploy=true" "$(head -n 1 <<< "$OUTPUTS")"

run_guard "$WORK_DIR/plain" GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main
assert_equals "a branch run: nothing to compare, so it deploys" "deploy=true" "$OUTPUTS"
assert_equals "a branch run: needs no remote" "0" "$STATUS"

run_guard "$WORK_DIR/plain" GITHUB_REF_TYPE=tag GITHUB_REF_NAME=2.1.0 RELEASE_GUARD_TAGS="$INCIDENT_TAGS"
assert_equals "GitHub Actions: the run's own tag is judged" "deploy=false" "$(head -n 1 <<< "$OUTPUTS")"
run_guard "$WORK_DIR/plain" CI_COMMIT_TAG=2.1.0 RELEASE_GUARD_TAGS="$INCIDENT_TAGS"
assert_equals "GitLab CI: the pipeline's tag is judged" "deploy=false" "$(head -n 1 <<< "$OUTPUTS")"
run_guard "$WORK_DIR/plain" BUILD_SOURCEBRANCH=refs/tags/2.1.0 RELEASE_GUARD_TAGS="$INCIDENT_TAGS"
assert_equals "Azure DevOps: the build's tag is judged" "deploy=false" "$(head -n 1 <<< "$OUTPUTS")"
run_guard "$WORK_DIR/plain" BUILD_SOURCEBRANCH=refs/heads/main
assert_equals "Azure DevOps: a branch build deploys" "deploy=true" "$OUTPUTS"

run_guard "$WORK_DIR/plain" GITHUB_ACTIONS=true RELEASE_GUARD_TAG=2.1.0 RELEASE_GUARD_TAGS="$INCIDENT_TAGS"
assert_true "GitHub Actions: a refusal is a warning annotation on the run" \
  "grep -q '^::warning title=Release guard::2.1.0 is older than 2.1.2' <<< \"\$OUT\""

run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=2.1.0 RELEASE_GUARD_TAGS="$INCIDENT_TAGS" \
  RELEASE_GUARD_ROLLBACK_HINT='Dispatch it by hand with environment production.'
assert_true "a caller's own rollback hint replaces the default one" \
  "grep -q 'Dispatch it by hand with environment production.' <<< \"\$SUMMARY\" && ! grep -q 'allow_rollback' <<< \"\$SUMMARY\""

# A name this guard cannot order may hold anything; none of it may reach `$GITHUB_OUTPUT`, where a
# newline would add an output of its own, or close the summary's code span.
run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=$'x\ndeploy=false' RELEASE_GUARD_TAGS="$INCIDENT_TAGS"
assert_equals "the judged name never reaches the outputs, so it cannot inject one" "deploy=true" "$OUTPUTS"
run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG='release`x' RELEASE_GUARD_TAGS="$INCIDENT_TAGS"
assert_true "a backtick in an unordered name is dropped from the summary" \
  "grep -q '\`releasex\`' <<< \"\$SUMMARY\""
echo ""

echo "3. Tags listed from the remote"

REMOTE="$WORK_DIR/remote.git"
SEED="$WORK_DIR/seed"
CLONE="$WORK_DIR/clone"
# The fixture is isolated from whoever runs the suite: no signing, and no hooks from a global
# `core.hooksPath` (a secret scanner on push, say) acting on repositories that hold nothing.
FIXTURE_GIT=(-c init.defaultBranch=main -c user.email=test@example.com -c user.name=test
  -c commit.gpgsign=false -c tag.gpgsign=false -c core.hooksPath="$WORK_DIR/no-hooks")
if ! git "${FIXTURE_GIT[@]}" init -q --bare "$REMOTE" \
  || ! git "${FIXTURE_GIT[@]}" init -q "$SEED" \
  || ! git "${FIXTURE_GIT[@]}" -C "$SEED" commit -q --allow-empty -m 'first'; then
  echo -e "${RED}could not build the fixture repositories, so no remote assertion can run${NC}"
  exit 1
fi
while IFS= read -r tag; do
  git "${FIXTURE_GIT[@]}" -C "$SEED" tag "$tag" || exit 1
done <<< "$INCIDENT_TAGS"
git "${FIXTURE_GIT[@]}" -C "$SEED" push -q "$REMOTE" HEAD:refs/heads/main --tags || exit 1
git "${FIXTURE_GIT[@]}" clone -q "$REMOTE" "$CLONE" || exit 1

run_guard "$CLONE" RELEASE_GUARD_TAG=2.1.0
assert_equals "remote: older is NOT deployed" $'deploy=false\nnewest=2.1.2' "$OUTPUTS"
run_guard "$CLONE" RELEASE_GUARD_TAG=2.1.2
assert_equals "remote: newest is deployed" $'deploy=true\nnewest=2.1.2' "$OUTPUTS"

# A newer release that reached the remote after the clone was made: the clone's own tags would
# approve 2.1.2, which is no longer the newest.
git "${FIXTURE_GIT[@]}" -C "$SEED" tag 2.2.0 || exit 1
git "${FIXTURE_GIT[@]}" -C "$SEED" push -q "$REMOTE" 2.2.0 || exit 1
run_guard "$CLONE" RELEASE_GUARD_TAG=2.1.2
assert_equals "remote: the remote's tags decide, not the clone's" $'deploy=false\nnewest=2.2.0' "$OUTPUTS"

run_guard "$CLONE" RELEASE_GUARD_TAG=2.1.2 RELEASE_GUARD_REMOTE="$WORK_DIR/no-such-remote.git" \
  RELEASE_GUARD_RETRY_DELAYS='0 0'
assert_equals "remote: a remote that cannot be listed reaches no verdict" "1" "$STATUS"
assert_equals "remote: ...and writes no verdict a gate could read as a yes" "" "$OUTPUTS"
assert_true "remote: ...and says nothing was deployed" "grep -q 'No verdict was reached' <<< \"\$OUT\""
assert_equals "remote: ...after asking once more for every retry delay" "2" "$(grep -c 'asking again in 0s' <<< "$OUT")"
run_guard "$WORK_DIR/plain" RELEASE_GUARD_TAG=2.1.2 RELEASE_GUARD_RETRY_DELAYS=''
assert_equals "remote: outside any clone it reaches no verdict either" "1" "$STATUS"
assert_true "remote: no retry delay asks exactly once" "! grep -q 'asking again' <<< \"\$OUT\""
echo ""

echo "4. Wiring"

assert_true "the action calls the guard script" "grep -q 'global/scripts/deploy/release-guard/run.sh' '$GUARD_ACTION'"
assert_true "the action honours a rollback on a workflow_dispatch run only" \
  "grep -qF \"RELEASE_GUARD_ALLOW_ROLLBACK: \\\"\\\${{ github.event_name == 'workflow_dispatch' && inputs.allow_rollback || 'false' }}\\\"\" '$GUARD_ACTION'"
assert_true "the action checks the repository out, so its remote can be listed" \
  "grep -q \"uses: 'actions/checkout@\" '$GUARD_ACTION'"

mkdir -p "$WORK_DIR/tools" || exit 1
CHECKER="$WORK_DIR/tools/releaseguard"
if ! CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
  go build -C "$SCRIPTS_DIR" -trimpath -o "$CHECKER" ./internal/testsuites/releaseguard; then
  echo -e "${RED}could not build ./internal/testsuites/releaseguard, so no wiring assertion can run${NC}"
  exit 1
fi

assert_empty "every deployment workflow gates its deployment on the release guard" \
  "$("$CHECKER" wiring "$WORKFLOWS_DIR" 2>&1)"

# Each deliberate violation, made to a copy of one real workflow, must be reported by name.
# mutated <name> <program>: the findings about go-flyio.yaml once `awk` <program> has rewritten it.
mutated() {
  local dir="$WORK_DIR/mutated/$1"
  mkdir -p "$dir" || return 1
  awk "$2" "$WORKFLOWS_DIR/go-flyio.yaml" > "$dir/go-flyio.yaml" || return 1
  "$CHECKER" wiring "$dir" 2>&1
}
# FOUND is read only inside assert_true's eval'd conditions, which ShellCheck cannot see.
FOUND="$(mutated needs '{ sub(/needs: \[ .go-docker., .deployment-release-guard. \]/, "needs: [ '\''go-docker'\'' ]") } 1')"
assert_true "a deployment that does not need the guard is reported" "grep -q 'does not need deployment-release-guard' <<< \"\$FOUND\""
FOUND="$(mutated gate '{ sub(/ needs\.deployment-release-guard\.outputs\.deploy == .true. &&/, "") } 1')"
assert_true "a deployment if: without the guard's yes is reported" "grep -q 'with no .needs.deployment-release-guard.outputs.deploy' <<< \"\$FOUND\""
FOUND="$(mutated environment '1; /^    name: .deployment > release-guard.$/ { print "    environment: '\''production'\''" }')"
assert_true "a guard job that enters an environment is reported" "grep -q 'declares .environment:.' <<< \"\$FOUND\""
FOUND="$(mutated default '/^      allow_rollback:$/ { input = 1 } input && /default: false/ { sub(/false/, "true"); input = 0 } 1')"
assert_true "a rollback input that defaults to on is reported" "grep -q 'no .allow_rollback. input' <<< \"\$FOUND\""
FOUND="$(mutated constant '{ sub(/allow_rollback: "\$\{\{ inputs\.allow_rollback \}\}"/, "allow_rollback: '\''true'\''") } 1')"
assert_true "a constant handed to the guard instead of the input is reported" "grep -q 'hands the guard allow_rollback' <<< \"\$FOUND\""
# shellcheck disable=SC2034  # read by the eval'd condition below
FOUND="$(mutated output '{ sub(/github\.ref_type != .tag. && .true. \|\| steps\.guard\.outputs\.deploy/, "steps.guard.outputs.deploy || '\''true'\''") } 1')"
assert_true "a fail-open deploy output is reported" "grep -q 'outputs deploy' <<< \"\$FOUND\""
echo ""

echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
