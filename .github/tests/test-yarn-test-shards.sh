#!/usr/bin/env bash
set -u

# Pin the `test_shards` contract of the Yarn workflows.
#
# WHY THIS EXISTS
#
# `test_shards` splits `tests > test:all` across runners. Above 1, `tests > test:all (shard <i>/<n>)`
# runs one shard of the suite per runner and hands its coverage on, and `tests > test:all` waits for
# every shard, merges their coverage and reports it; at 1, the default, `tests > test:all` runs the
# whole suite as it always did. Every property below fails QUIETLY when it regresses: the run stays
# green while the suite it reports on stops being the whole suite.
#
#   - **A failed shard FAILS `tests > test:all`, never skips it.** Every job past the first stage
#     gates on `!cancelled() && !failure()`, and that gate SKIPS this one after a failed shard. A
#     skipped job passes a required check, so the pull request would merge with its tests red. The
#     gate is EVALUATED here, at every moment that matters, rather than matched as text.
#   - **One job is named `tests > test:all`.** It is the check consumers require and the name a
#     `deployment_required_checks` entry gives. Two jobs of that name, one of them skipped, are two
#     check runs of one name, and the skipped one satisfies the requirement whatever the other did.
#   - **Each mode runs its own test step, and only its own.** A condition flipped on the step that
#     runs `yarn test:ci` would leave the default mode running no test at all, and the job green.
#   - **The merge reads exactly the shards 1..n.** A shard that left no coverage, or a stray
#     `coverage-shard-*` artifact beside them, makes the merged figure one over a suite that did not
#     run in full. `Verify the shards` is EXECUTED here, cut out of yarn.yaml, against those layouts.
#   - **The hand-off has one shape on both sides.** What a shard uploads and where the merge unpacks
#     it are two steps of two jobs; the layout is simulated end to end below.
#   - **The composed workflows pass the input on.** One that drops it accepts the value and runs the
#     suite in one job, which looks exactly like the default.
#
# The workflows are parsed by Go test support (`internal/testsuites/yarntestshards`), built from this
# checkout for this run, and the steps it cuts out of yarn.yaml run under bash as the runner runs a
# `shell: 'bash'` step. Offline: it needs Go and bash, nothing else.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1

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
  if [[ -n "${2:-}" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo -e "${RED}        $line${NC}"
    done <<< "$2"
  fi
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

assert_empty() { # assert_empty <description> <findings>
  if [[ -z "$2" ]]; then pass "$1"; else fail "$1" "$2"; fi
}

assert_eq() { # assert_eq <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected $(printf '%q' "$2"), got $(printf '%q' "$3")"; fi
}

assert_contains() { # assert_contains <description> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "$(printf 'no %q in:\n%s' "$2" "$3")"; fi
}

echo "================================"
echo "test_shards contract"
echo "================================"
echo ""

WORK_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK_DIR"' EXIT
FINDINGS="$WORK_DIR/findings"
CHECKER="$WORK_DIR/yarntestshards"

# A checker that does not build, or cannot read the workflows, stops the suite: every assertion below
# would otherwise read an empty findings file and pass for it.
if ! CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
  go build -C "$SCRIPTS_DIR" -trimpath -o "$CHECKER" ./internal/testsuites/yarntestshards; then
  echo -e "${RED}could not build ./internal/testsuites/yarntestshards, so no assertion can run${NC}"
  exit 1
fi
if ! "$CHECKER" check "$SCRIPTS_DIR" > "$FINDINGS"; then
  echo -e "${RED}./internal/testsuites/yarntestshards could not read the workflows, so no assertion can run${NC}"
  exit 1
fi
LIMIT="$("$CHECKER" limit "$SCRIPTS_DIR")" || { echo -e "${RED}yarn.yaml's shard table cannot be read${NC}"; exit 1; }
"$CHECKER" script "$SCRIPTS_DIR" tests-test_all 'Verify the shards' > "$WORK_DIR/verify.sh" \
  || { echo -e "${RED}could not cut 'Verify the shards' out of yarn.yaml${NC}"; exit 1; }
"$CHECKER" script "$SCRIPTS_DIR" tests-test_all_shards 'Stage the coverage of the shard' > "$WORK_DIR/stage.sh" \
  || { echo -e "${RED}could not cut 'Stage the coverage of the shard' out of yarn.yaml${NC}"; exit 1; }

# `awk` rather than `grep -P`: the group separator is a TAB, which a portable BRE cannot name.
group() {
  awk -F '\t' -v group="$1" '$1 == group { sub(/^[^\t]*\t/, ""); print }' "$FINDINGS"
}

# run_step <script> <directory> [NAME=value ...]: runs a step cut out of yarn.yaml as the runner runs
# a `shell: 'bash'` step, in its working directory, with no environment but PATH and what is named;
# leaves its output in OUT and its status in RC.
run_step() {
  local script="$1" directory="$2"
  shift 2
  RC=0
  OUT="$(
    cd "$directory" || exit 99
    env -i PATH="$PATH" "$@" bash --noprofile --norc -eo pipefail "$script" 2>&1
  )" || RC=$?
}

# project [shard ...]: a project directory whose coverage/shards holds each named shard's report.
project() {
  local directory shard
  directory="$(mktemp -d "$WORK_DIR/project.XXXXXX")" || exit 1
  mkdir -p "$directory/coverage/shards" || exit 1
  for shard in "$@"; do
    mkdir -p "$directory/coverage/shards/$shard" || exit 1
    printf '{"/runner-%s/work/src/shard%s.ts":{}}\n' "$shard" "$shard" > "$directory/coverage/shards/$shard/coverage-final.json"
  done
  printf '%s' "$directory"
}

echo "Test 1: yarn.yaml takes the input, and every workflow composed on it passes it on"
assert_empty "test_shards is an optional number defaulting to 1, declared and forwarded by every yarn-*.yaml" \
  "$(group input)"
echo ""

echo "Test 2: one job is named 'tests > test:all', in both modes"
assert_empty "only tests-test_all is 'tests > test:all'; it needs the shards, each shard has a check of its own, and the management stage still needs it" \
  "$(group jobs)"
echo ""

echo "Test 3: the shards are 1..n and every one reports"
assert_empty "the matrix is the table indexed by test_shards, entry n being 1..n, with fail-fast off" \
  "$(group matrix)"
echo ""

echo "Test 4: the gates, evaluated -- a failed shard fails 'tests > test:all' rather than skipping it"
assert_empty "the shards run only when asked for; 'tests > test:all' runs after a failed shard and in the single mode, and skips after a failed security job, a cancelled run and a tag" \
  "$(group gates)"
echo ""

echo "Test 5: each mode runs its own steps, the shards the same setup and install as the single run"
assert_empty "yarn test:ci runs alone in the single mode, the download, verdict, merge and clean-up alone in the sharded one, in order, every other step in both" \
  "$(group steps)"
echo ""

echo "Test 6: what a shard uploads is what 'tests > test:all' downloads"
assert_empty "one artifact per shard, from and into the same directory, merged into it, and neither step allowed to fail its job quietly" \
  "$(group handoff)"
echo ""

echo "Test 7: 'Verify the shards', run as the runner runs it"
directory="$(project 1 2 3)"
run_step "$WORK_DIR/verify.sh" "$directory" SHARDS_RESULT=success TEST_SHARDS=3 TEST_SHARDS_MAX="$LIMIT"
assert_eq "every shard passed and left its coverage: the merge goes ahead" 0 "$RC"

directory="$(project 1 3)"
run_step "$WORK_DIR/verify.sh" "$directory" SHARDS_RESULT=failure TEST_SHARDS=3 TEST_SHARDS_MAX="$LIMIT"
assert_eq "a shard failed: tests > test:all fails" 1 "$RC"
assert_contains "...naming the shards' result and the shard that left nothing" \
  "::error::not every shard passed (the shards finished 'failure', and shard(s) 2 left no coverage)" "$OUT"

directory="$(project 1 2)"
run_step "$WORK_DIR/verify.sh" "$directory" SHARDS_RESULT=cancelled TEST_SHARDS=2 TEST_SHARDS_MAX="$LIMIT"
assert_eq "a shard was cancelled: tests > test:all fails, every report present or not" 1 "$RC"

directory="$(project 1 2)"
run_step "$WORK_DIR/verify.sh" "$directory" SHARDS_RESULT=success TEST_SHARDS=3 TEST_SHARDS_MAX="$LIMIT"
assert_eq "every shard passed but one's coverage is gone (an expired artifact): it fails" 1 "$RC"
assert_contains "...naming that shard and the way out" "shard(s) 3 passed but left no coverage" "$OUT"
assert_contains "...which is to re-run every job" "re-run every job" "$OUT"

directory="$(project 1 2)"
: > "$directory/coverage/shards/2/coverage-final.json"
run_step "$WORK_DIR/verify.sh" "$directory" SHARDS_RESULT=success TEST_SHARDS=2 TEST_SHARDS_MAX="$LIMIT"
assert_eq "an empty report counts as none" 1 "$RC"

directory="$(project 1 2 4)"
run_step "$WORK_DIR/verify.sh" "$directory" SHARDS_RESULT=success TEST_SHARDS=2 TEST_SHARDS_MAX="$LIMIT"
assert_eq "a shard this job did not run sits beside them: it fails rather than merge it" 1 "$RC"
assert_contains "...naming it" "coverage/shards holds 4 beside shards 1 to 2" "$OUT"

directory="$(project 1 2)"
printf 'x\n' > "$directory/coverage/shards/notes.txt"
run_step "$WORK_DIR/verify.sh" "$directory" SHARDS_RESULT=success TEST_SHARDS=2 TEST_SHARDS_MAX="$LIMIT"
assert_eq "anything else in coverage/shards fails too" 1 "$RC"
assert_contains "...by name" "holds notes.txt" "$OUT"

directory="$(project 1 2)"
run_step "$WORK_DIR/verify.sh" "$directory" SHARDS_RESULT=failure TEST_SHARDS="$((LIMIT + 1))" TEST_SHARDS_MAX="$LIMIT"
assert_eq "test_shards past the table's end, where no shard could start: it fails" 1 "$RC"
assert_contains "...naming the input and the range it takes" "::error::test_shards is '$((LIMIT + 1))', but it takes a whole number from 1 to $LIMIT" "$OUT"

directory="$(project 1 2)"
run_step "$WORK_DIR/verify.sh" "$directory" SHARDS_RESULT=failure TEST_SHARDS=2.5 TEST_SHARDS_MAX="$LIMIT"
assert_eq "a test_shards that is not a whole number fails the same way" 1 "$RC"
assert_contains "...naming it" "test_shards is '2.5'" "$OUT"

# shellcheck disable=SC2046 # one argument per shard number is the point
directory="$(project $(seq 1 "$LIMIT"))"
run_step "$WORK_DIR/verify.sh" "$directory" SHARDS_RESULT=success TEST_SHARDS="$LIMIT" TEST_SHARDS_MAX="$LIMIT"
assert_eq "the table's last entry, $LIMIT shards, is accepted" 0 "$RC"
echo ""

echo "Test 8: 'Stage the coverage of the shard', run as the runner runs it"
directory="$(mktemp -d "$WORK_DIR/shard.XXXXXX")" || exit 1
mkdir -p "$directory/coverage" || exit 1
printf '{"/runner/work/src/a.ts":{}}\n' > "$directory/coverage/coverage-final.json"
run_step "$WORK_DIR/stage.sh" "$directory" SHARD=2
assert_eq "a shard that wrote its coverage stages it" 0 "$RC"
if cmp -s "$directory/coverage/coverage-final.json" "$directory/coverage/shards/2/coverage-final.json"; then
  pass "...unchanged, under coverage/shards/<its number>/"
else
  fail "...unchanged, under coverage/shards/<its number>/" "$(command ls -R "$directory/coverage" 2>&1)"
fi

directory="$(mktemp -d "$WORK_DIR/shard.XXXXXX")" || exit 1
run_step "$WORK_DIR/stage.sh" "$directory" SHARD=1
assert_eq "a shard that wrote no coverage fails where it happened" 1 "$RC"
assert_contains "...naming the script that should have written it" \
  "::error::yarn test:ci:shard left no coverage/coverage-final.json" "$OUT"

mkdir -p "$directory/coverage" || exit 1
: > "$directory/coverage/coverage-final.json"
run_step "$WORK_DIR/stage.sh" "$directory" SHARD=1
assert_eq "an empty report fails the same way" 1 "$RC"

# The hand-off end to end: each shard stages its report in a workspace of its own, its artifact holds
# that workspace's `coverage/shards/` (a directory upload is rooted at the directory), and the merge
# unpacks every artifact into one `coverage/shards/` (`merge-multiple`). Test 6 holds the two steps
# to those paths; this holds the layout they produce to what the verification reads.
merged="$(project)"
staged=''
for shard in 1 2 3; do
  directory="$(mktemp -d "$WORK_DIR/shard.XXXXXX")" || exit 1
  mkdir -p "$directory/coverage" || exit 1
  printf '{"/runner-%s/work/src/shard%s.ts":{}}\n' "$shard" "$shard" > "$directory/coverage/coverage-final.json"
  run_step "$WORK_DIR/stage.sh" "$directory" SHARD="$shard"
  if [[ "$RC" -eq 0 ]] && cp -R "$directory/coverage/shards/." "$merged/coverage/shards/"; then
    staged="$staged $shard"
  fi
done
assert_eq "each of three shards stages its report for the hand-off" ' 1 2 3' "$staged"
run_step "$WORK_DIR/verify.sh" "$merged" SHARDS_RESULT=success TEST_SHARDS=3 TEST_SHARDS_MAX="$LIMIT"
assert_eq "three shards' artifacts, unpacked together, are what the verification accepts" 0 "$RC"
assert_contains "...each shard's report under its own number" "shard2.ts" \
  "$(cat "$merged/coverage/shards/2/coverage-final.json" 2> /dev/null)"
echo ""

echo "Test 9: the documentation states what the workflow does"
assert_empty "the input's description and README.md give the table's range, README.md states the contract, and AGENTS.md lists this suite" \
  "$(group docs)"
echo ""

echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo "================================"

if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi

echo "All test_shards tests passed!"
