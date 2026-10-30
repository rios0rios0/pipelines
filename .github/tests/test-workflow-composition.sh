#!/usr/bin/env bash
set -e

# Enforces the GitHub Actions workflow composition standard documented in
# CLAUDE.md ("Workflow Composition Standard") and README.md.
#
# WHY THIS EXISTS
#
# Every file under `.github/workflows/` is valid YAML on its own, so nothing
# else in CI can tell a workflow that follows the standard from one that does
# not. The standard is therefore only real if something asserts it, and the
# failures it prevents are all of the same shape: they do not break a run, they
# make a run stop meaning what it looks like it means.
#
#   - A consumer that hand-writes a deploy job instead of calling a composed
#     workflow gets no `require-checks` gate, no environment scoping and no
#     shared script -- and the repository that did this went four days without
#     deploying, every pipeline green, because it had coupled two workflows with
#     `on: workflow_run:` and then renamed one of them. `workflow_run` matches by
#     DISPLAY NAME, and naming a workflow that does not exist is not an error; it
#     simply never fires. That is assertion 3 below, and it is the reason the
#     whole standard is "the deploy is a job with `needs:`".
#
#   - A composed workflow that re-declares its base's jobs rather than calling
#     it drifts from the base one input at a time, and each drift looks like a
#     deliberate difference to the next reader.
#
#   - A deployment job named anything other than `deployment > <provider>`
#     breaks `require-checks` for everyone downstream: GitHub composes a check's
#     name from the calling job and the called workflow's job, so the names
#     consumers list in `deployment_required_checks` are these strings.
#
# HOW IT READS THE FILES
#
# Tests 1-9 do not resolve the YAML -- the same constraint `order-check` and
# `var-catalog` work under. They are lookups into a fact table read from the
# files as indented text, which is sufficient because each is about a line shape
# (a job key at two spaces, a `name:` at four) rather than about a resolved
# document. A workflow written in flow style would slip past them; none is, and
# one would fail review long before this.
#
# Tests 10 to 18 are the exceptions and read the PARSED document. Test 10
# asserts on an input declared three mappings under `on:` -- a key a YAML 1.1
# reader does not even spell `on`, since it resolves it to the boolean `true` --
# where no indentation rule can tell which mapping a line belongs to, and
# Test 11 needs the `if:` as ONE expression, which a block scalar spreads over
# ten physical lines, Test 12 walks the whole trigger block for evaluated
# expressions, Test 13 compares a block-scalar prompt against the tool rules in
# another block scalar beside it, Test 14 evaluates a folded-scalar `if:`
# against input defaults declared under that same `on:` key, Test 15 splits
# every job's `if:` into clauses, which a block scalar may spread over several
# lines just as Test 11's does, and Test 16 tells a job-level
# `continue-on-error` from a step-level one, which only nesting distinguishes --
# and follows the GitLab and Azure DevOps twins through their includes and
# templates -- and Test 17 reads a job's `permissions:` beside the `with:` of its
# steps.
#
# The fact table and those eight checks are one Go command,
# `internal/testsuites/workflowcomposition`, built below from this checkout. It
# reads YAML 1.2, as GitHub Actions does, so the suite needs a Go toolchain and
# nothing else -- no Python, no PyYAML. A build that fails stops the suite by
# name instead of skipping the assertions it serves. Each check prints one
# finding per line and exits 0 whatever it found, a file it cannot read being a
# finding about that file: this script runs under `set -e`, where a failing
# command would end it with no FAIL line and no summary.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPTS_DIR

WORKFLOWS_DIR="$SCRIPTS_DIR/.github/workflows"

# Reusable workflows whose name carries a hyphen WITHOUT being `<toolchain>-`
# anything. All six are deliberate and none composes a base:
#
#   flutter-artifacts.yaml        `flutter` is a toolchain in its own right (see
#                                 the naming table in CLAUDE.md) and Dart's
#                                 checks live in `dart.yaml`, so there is no
#                                 `flutter.yaml` for this to call.
#   update-major-version-tag.yaml repository maintenance, not a language
#                                 pipeline -- it moves the `vN` tag that action
#                                 consumers pin to.
#   dependency-updates.yaml       repository maintenance on a schedule, not a
#                                 toolchain pipeline. There is no
#                                 `dependency.yaml` for it to be a target of --
#                                 the hyphen is part of one name rather than a
#                                 `<toolchain>-<target>` split.
#   dependency-updates-verify.yaml the security gate on a pull request that
#                                 moves pins: it proves the diff of ANY such
#                                 pull request, not only the scheduled one, so
#                                 it is a check of its own rather than a stage
#                                 `dependency-updates.yaml` composes, and
#                                 `-verify` is not a delivery or provider suffix.
#   reusable-claude-review.yaml   code review by Claude on every pull request.
#                                 The `reusable-` prefix marks the definition
#                                 apart from the caller repository's name
#                                 `claude-review.yaml`, including this one --
#                                 so `reusable` is a marker, not a toolchain,
#                                 and there is no `reusable.yaml` to compose.
#   reusable-claude-mention.yaml  the `@claude` mention responder, standalone
#                                 for the same reason.
#
# Anything else added here needs a reason of the same kind. "It did not fit the
# standard" is not one; that is the finding, not the exemption.
STANDALONE='flutter-artifacts.yaml update-major-version-tag.yaml dependency-updates.yaml dependency-updates-verify.yaml reusable-claude-review.yaml reusable-claude-mention.yaml'

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

is_standalone() {
  local candidate="$1"
  case " $STANDALONE " in
    *" $candidate "*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "================================"
echo "Workflow composition standard"
echo "================================"
echo ""

# The checks, built once into scratch space the EXIT trap removes. The build pins
# what `global/scripts/shared/go-helper.sh` pins: no C compiler, go.mod and go.sum
# never rewritten, and no go.work above the checkout deciding what builds.
COMPOSITION_TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$COMPOSITION_TMP"' EXIT
COMPOSITION="$COMPOSITION_TMP/workflowcomposition"
FACTS="$COMPOSITION_TMP/facts"

if ! command -v go > /dev/null 2>&1; then
  echo -e "${RED}FAIL: Go 1.25 or newer is required to build the workflow composition checks${NC}"
  exit 1
fi
if ! CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
  go build -C "$SCRIPTS_DIR" -o "$COMPOSITION" ./internal/testsuites/workflowcomposition; then
  echo -e "${RED}FAIL: could not build ./internal/testsuites/workflowcomposition from $SCRIPTS_DIR${NC}"
  exit 1
fi

# composition_check <check> <directory>: that check's findings, one per line. The
# command fails only when it cannot run at all -- called wrongly, or unable to
# write its output -- and that becomes a finding here rather than the end of a
# `set -e` suite with no FAIL line.
composition_check() {
  local status=0
  "$COMPOSITION" "$@" || status=$?
  if [[ $status -ne 0 ]]; then
    echo "workflowcomposition $1 exited $status"
  fi
}

# The fact table every assertion of Tests 1-9 reads. One pass over the
# workflows, emitting `<kind>\t<workflow>\t<job>\t<detail>` lines, so the
# assertions are lookups into a flat file rather than nine separate parses. A
# workflow it cannot read stops the suite, because a table missing a file would
# let every lookup about that file pass.
"$COMPOSITION" facts "$WORKFLOWS_DIR" > "$FACTS" \
  || { echo -e "${RED}FAIL: could not build the fact table from $WORKFLOWS_DIR${NC}"; exit 1; }

# Exact, field-wise lookups into the fact table. `grep -P` would do this in one
# line and is a GNU extension; awk with -F'\t' behaves the same everywhere.
fact_has() {
  local kind="$1" workflow="$2" job="$3"
  awk -F'\t' -v k="$kind" -v f="$workflow" -v j="$job" \
    '$1 == k && $2 == f && $3 == j { found = 1 } END { exit !found }' "$FACTS"
}

fact_value() {
  local kind="$1" workflow="$2" job="$3"
  awk -F'\t' -v k="$kind" -v f="$workflow" -v j="$job" \
    '$1 == k && $2 == f && $3 == j { print $4; exit }' "$FACTS"
}

reusable_workflows() {
  awk -F'\t' '$1 == "reusable" { print $2 }' "$FACTS" | sort -u
}

echo "Test 1: a hyphenated workflow name is <toolchain>-<target>"
NO_BASE=''
while IFS= read -r file; do
  base="${file%.yaml}"
  case "$base" in *-*) ;; *) continue ;; esac
  is_standalone "$file" && continue
  toolchain="${base%%-*}"
  [[ -f "$WORKFLOWS_DIR/${toolchain}.yaml" ]] \
    || NO_BASE="${NO_BASE}${file}: no ${toolchain}.yaml beside it -- name it for the toolchain, or add it to STANDALONE with a reason"$'\n'
done < <(reusable_workflows)
assert_empty "every <toolchain>-<target>.yaml has a <toolchain>.yaml beside it" "$NO_BASE"
echo ""

echo "Test 2: composed workflows CALL their base instead of re-declaring it"
NOT_COMPOSED=''
while IFS= read -r file; do
  base="${file%.yaml}"
  case "$base" in *-*) ;; *) continue ;; esac
  is_standalone "$file" && continue
  toolchain="${base%%-*}"
  [[ -f "$WORKFLOWS_DIR/${toolchain}.yaml" ]] || continue
  awk -F'\t' -v f="$file" -v t="$toolchain" \
    '$1 == "uses" && $2 == f && index($4, "rios0rios0/pipelines/.github/workflows/" t) == 1 { found = 1 }
     END { exit !found }' "$FACTS" \
    || NOT_COMPOSED="${NOT_COMPOSED}${file}: declares jobs of its own instead of 'uses:' a ${toolchain}*.yaml"$'\n'
done < <(reusable_workflows)
assert_empty "every composed workflow delegates to a sibling workflow" "$NOT_COMPOSED"
echo ""

echo "Test 3: no workflow couples itself to another by display name"
assert_empty "no 'on: workflow_run:' anywhere (it fails silently when a name changes)" \
  "$(awk -F'\t' '$1 == "workflow-run" { print $2 }' "$FACTS")"
echo ""

echo "Test 4: reusable workflows live only in .github/workflows/"
assert_empty "no reusable workflow outside .github/workflows/" \
  "$(grep -rl 'workflow_call:' "$SCRIPTS_DIR/github" "$SCRIPTS_DIR/gitlab" "$SCRIPTS_DIR/azure-devops" 2>/dev/null || true)"
echo ""

echo "Test 5: stage jobs are named for the stage they run in"
BAD_NAME=''
while IFS=$'\t' read -r _ file job action; do
  case "$action" in
    *50-deployment/require-checks*) continue ;;
    *40-delivery/*) expected='delivery > ' ;;
    *50-deployment/*) expected='deployment > ' ;;
    *) continue ;;
  esac
  display="$(fact_value 'job-name' "$file" "$job")"
  case "$display" in
    "$expected"*) ;;
    *) BAD_NAME="${BAD_NAME}${file} job '${job}': name is '${display}', must start with '${expected}'"$'\n' ;;
  esac
done < <(awk -F'\t' '$1 == "uses"' "$FACTS")
assert_empty "every 40-delivery job is 'delivery > …' and every 50-deployment job is 'deployment > …'" "$BAD_NAME"
echo ""

echo "Test 6: deployment jobs are gated, scoped and placed"
UNGATED=''
while IFS=$'\t' read -r _ file job action; do
  case "$action" in
    *50-deployment/require-checks*) continue ;;
    *50-deployment/*) ;;
    *) continue ;;
  esac
  # `needs:` is the whole point of the standard -- it is what a `workflow_run`
  # coupling cannot express, and what makes a missed deploy a skipped job rather
  # than silence.
  fact_has 'job-has-needs' "$file" "$job" \
    || UNGATED="${UNGATED}${file} job '${job}': no 'needs:', so it can deploy a commit nothing verified"$'\n'
  # `environment:` is what keeps two environments' credentials apart.
  fact_has 'job-has-environment' "$file" "$job" \
    || UNGATED="${UNGATED}${file} job '${job}': no 'environment:', so its credentials are not scoped"$'\n'
  # Without an `if:` a pull request deploys.
  fact_has 'job-has-if' "$file" "$job" \
    || UNGATED="${UNGATED}${file} job '${job}': no 'if:', so a pull request deploys"$'\n'
  # The stage comment is how a reader places a job in the 5-stage model without
  # resolving the action it calls.
  stage="$(fact_value 'job' "$file" "$job")"
  [[ "$stage" == 'fifth' ]] \
    || UNGATED="${UNGATED}${file} job '${job}': not preceded by a '# fifth stage' comment (found '${stage:-none}')"$'\n'
done < <(awk -F'\t' '$1 == "uses"' "$FACTS")
assert_empty "every deployment job declares needs:, environment: and if:, under '# fifth stage'" "$UNGATED"
echo ""

echo "Test 7: internal references declare their revision policy"
INTERNAL_REFERENCE_FINDINGS="$(
  awk -F'\t' \
    '$1 == "uses" && index($4, "rios0rios0/pipelines/") == 1 && $4 !~ /@main$/ { print $2 ": unexpected internal ref " $4 }' \
    "$FACTS"
)"
YARN_SEMGREP_REF="$(fact_value 'uses' 'yarn.yaml' 'security-sast_semgrep')"
if [[ "$YARN_SEMGREP_REF" != '$/github/global/stages/20-security/semgrep' ]]; then
  INTERNAL_REFERENCE_FINDINGS="${INTERNAL_REFERENCE_FINDINGS}${INTERNAL_REFERENCE_FINDINGS:+$'\n'}yarn.yaml: Semgrep must resolve at the reusable workflow's exact commit (found '${YARN_SEMGREP_REF:-none}')"
fi
assert_empty "internal refs use explicit @main or exact-running-commit $/ semantics" \
  "$INTERNAL_REFERENCE_FINDINGS"
echo ""

echo "Test 8: every reusable workflow is documented"
UNDOCUMENTED=''
while IFS= read -r file; do
  grep -q "\`${file}\`" "$SCRIPTS_DIR/README.md" \
    || UNDOCUMENTED="${UNDOCUMENTED}${file}: not listed in README.md"$'\n'
done < <(reusable_workflows)
assert_empty "every workflow_call workflow appears in README.md" "$UNDOCUMENTED"
echo ""

echo "Test 9: a deployment suffix names a provider that exists"
NO_ACTION=''
while IFS= read -r file; do
  base="${file%.yaml}"
  case "$base" in *-*) suffix="${base#*-}" ;; *) continue ;; esac
  is_standalone "$file" && continue
  # `docker`, `library` and `binary` are DELIVERY suffixes (fourth stage), not
  # deployment providers; every other suffix must name a real provider
  # directory, which is what stops `<toolchain>-<madeup>.yaml` from existing.
  case "$suffix" in
    docker | library | binary) continue ;;
    # Everything else is asserted below. Named rather than left implicit so the
    # delivery/deployment split is readable at the point it is made.
    *) ;;
  esac
  [[ -d "$SCRIPTS_DIR/github/global/stages/50-deployment/${suffix}" ]] \
    || NO_ACTION="${NO_ACTION}${file}: no github/global/stages/50-deployment/${suffix}/ to call"$'\n'
done < <(reusable_workflows)
assert_empty "every deployment suffix names a 50-deployment provider that exists" "$NO_ACTION"
echo ""

echo "Test 10: every workflow declaring runs_on declares and consumes it the same way"
# Two halves, because either alone is defeatable.
#
# The CONTRACT half runs over every workflow that declares a `runs_on` input --
# 19 of them today, not just the two this test was written for. The shape is not
# Claude-specific: `go.yaml`, `yarn.yaml`, `npm.yaml`, `dart.yaml` and their
# children all declare the byte-identical input, and only the Dart ones were
# asserted anywhere (`test-dart-pipeline.sh`). Running the same body over all of
# them costs nothing and closes the gap a `reusable-claude-*` glob leaves: a
# future Claude workflow named outside that pattern.
#
# The DECLARATION half keeps the glob, because generalising alone would invert
# the assertion -- a workflow that DROPS the input stops being iterated and
# passes by not being looked at. The Claude reusables are STANDALONE, so Tests 1,
# 2 and 9 skip them by design and nothing else names them; the glob, rather than
# a list of two filenames, is what stops a third one from being invisible here as
# well. A glob matching nothing is itself reported, so a rename fails rather than
# passing with nothing left to check.
#
# One job may take a selector of its OWN, `<purpose>_runs_on`, that falls back to
# the pipeline's: `fromJSON(inputs.codeql_runs_on || inputs.runs_on)` sends CodeQL to
# a runner of its own on a shared self-hosted host and leaves it with every other job
# when empty. A fallback reads correctly and still fails silently in three ways, so
# each is a finding: a link after `runs_on` (which always has a value) is never read;
# a link that is required or has a non-empty default never lets the job fall through
# to the rest; and a composed workflow that does not forward its base's
# `<purpose>_runs_on` strands its consumers on `runs_on` for that job -- the drop looks
# exactly like the default, so nothing else would ever notice it.
#
# Two more things about the shape below are deliberate:
#
#   - It reads the PARSED document, and the file header says why. Same shape as
#     `test-dart-pipeline.sh`.
#   - A file it cannot read, or one shaped unlike a workflow -- a scalar
#     `runs_on:`, a job whose body is a list -- is a finding about that file, not
#     the end of the check. An EMPTY workflow or a job with an empty body is
#     well-formed and read as empty, which is exactly when a pinned runner or a
#     missing input has to be reported rather than skipped.
BAD_RUNS_ON="$(composition_check runs-on "$WORKFLOWS_DIR")"
assert_empty "every runs_on input is optional, defaults to hosted, and reaches every job, directly or as a fallback" "$BAD_RUNS_ON"
echo ""

echo "Test 11: the mention responder's trigger guard reads the right author"
# The `@claude` responder runs with `contents: write` and this repository's secrets,
# so its `if:` is the authorization boundary. It shipped with a hole: an
# `issue_comment` payload carries BOTH `comment` and `issue`, so the clause reading
# `github.event.issue.author_association` -- the THREAD AUTHOR's -- also evaluated on
# every comment, and any comment by anyone on a maintainer-opened `@claude` thread
# started the job.
#
# That guard now lives in a free-text `if:` block, which is the shape a reformat or a
# "simplify these conditions" pass eats first, defended only by a comment saying not
# to. This whole suite exists because a review habit is not an assertion, so the guard
# gets one too.
#
# It is asserted STRUCTURALLY, not as a string match: the expression is split into its
# top-level `||` clauses, and each clause that reads an `author_association` must also
# carry the null-check selecting the payload it belongs to. The `issue` clause must
# additionally exclude comment events -- by `github.event.comment == null` or by
# `github.event_name == 'issues'`, either spelling, because the invariant is what
# matters and not the idiom. A clause reading no association at all is an unguarded
# trigger and is reported as one.
BAD_TRIGGER="$(composition_check trigger "$WORKFLOWS_DIR")"
assert_empty "every trigger clause checks the association of whoever wrote what it matched" "$BAD_TRIGGER"
echo ""

echo "Test 12: no trigger-block description or default carries an evaluated expression"

# A `${{ }}` sequence in a `description:` or `default:` under `on:` is EVALUATED by
# GitHub, not treated as documentation -- and the trigger block has no context, so an
# example naming `github` makes the whole file fail to compile. It fails in the shape
# that is hardest to read: the workflow is never triggered, yet every push produces a
# failed run with no jobs, no logs, and the file PATH where the workflow name belongs.
# `go-flyio.yaml` shipped exactly that in its `fly_app_name` example. Usage examples
# belong in a `#` comment, which is never evaluated.
#
# Scoped to the CLASS, not the instance that was found: every file under `on:` (not
# only reusable ones -- `workflow_dispatch` inputs evaluate identically), and every
# `description` AND `default` (a `default:` is the likelier place to write
# `${{ github.ref_name }}` believing it resolves), including nested `outputs`.
BAD_ON_EXPRESSION="$(composition_check on-expression "$WORKFLOWS_DIR")"
assert_empty "no trigger-block description or default carries an evaluated expression" "$BAD_ON_EXPRESSION"
echo ""

echo "Test 13: the Claude prompts describe the tools those jobs actually grant"

# `anthropics/claude-code-action` ships a prompt template that tells the model, in its
# own words, to "install dependencies, run build commands, etc." and then -- when a
# linter or test suite is denied -- to "explain this in your comment so that the user
# can update your `--allowedTools`". Neither is right here: the pipeline compiles,
# lints and tests the same commit in its own jobs, and the denial is the design. Left
# alone, the template produced reviews carrying a "Note on verification: `go build
# ./...` and `go vet` were denied by the tool permissions in this run" -- a caveat
# about a decision, addressed to a reader who did not make it.
#
# Both prompts therefore state the tool surface and name the toolchains they exclude.
# That only stays true while the prose and the wiring move together, and they are
# edited in different places for different reasons -- so the pairing is asserted:
#
#   - a granted Bash command missing from the prompt is the drift that RE-CREATES the
#     defect: the model meets its own tools by being denied them, or never reaches for
#     one it has;
#   - a command the prompt calls denied while the allowlist grants it is the same
#     drift reversed, and it reads as a rule the model may then break by accident.
#
# Both halves read SENTENCES, and the first version of this assertion did not -- which
# left a hole the review of the pull request that added it found. A prompt states an
# exclusion wherever it is clearest: the mention responder's sits in its Tools paragraph
# ("`gh` is not granted, and neither is `git diff`"), not under `Denied on purpose:`. A
# collision check scoped to that one paragraph never read the sentence, while the naming
# check -- searching the whole prompt for a backticked `gh` -- found it there and counted
# a DENIAL as a description. Granting `Bash(gh:*)` to the responder therefore left this
# assertion green while its prompt told the model that tool was denied: both halves
# defeated by the same sentence. So denial sentences are partitioned out of the naming
# match and scanned for collisions wherever they appear, and `covers()` makes a widened
# grant (`Bash(git:*)`) collide with a narrow denial (`git diff`) that a `git add` grant
# correctly does not.
#
# The `prompt` + `track_progress` pairing is asserted for the same class of reason and
# is the more expensive half to get wrong: a `prompt:` on a comment or issue event
# SELECTS AGENT MODE (`src/modes/detector.ts`), where the action's template is replaced
# by the custom prompt -- so adding one to the mention responder without
# `track_progress: true` would silently stop it answering the question it was mentioned
# for, while every job stayed green.
BAD_CLAUDE_TOOLS="$(composition_check claude-tools "$WORKFLOWS_DIR")"
assert_empty "every Claude prompt matches the tools its job grants and denies" "$BAD_CLAUDE_TOOLS"
echo ""

echo "Test 14: the review job skips the pull requests automation opens"

# Every `chore/bump-*`, `bump/*` and autoupdate pull request is generated wholesale by a
# tool and merged unread, so reviewing one spends a full-diff Claude run on a diff nobody
# reads back. The guard that stops it is a job-level `if:` -- free-text, one expression,
# and exactly the shape a "tidy these conditions" pass eats first.
#
# So it is EVALUATED, not matched. The expression is run, with GitHub's rules -- strings
# compared ignoring case, `!` binding tighter than `==`, `==` across types comparing them as
# numbers -- against ten pull requests whose verdict is known, which is what makes the
# assertion survive a reordering, a rename of the input, or a rewrite from `startsWith` to
# `contains`, while still failing when a prefix is dropped. The evaluator models only the
# subset a guard is written in (`expression.go` lists it); anything else fails the case by
# name rather than being guessed at. Two of the ten are the traps: a plain feature branch
# must still BE reviewed (or "skip everything" passes this test), and emptying the input
# must not skip everything either -- `startsWith(ref, '')` is TRUE, so an input used
# without a non-empty check silently disables every review in the repository that set it.
BAD_REVIEW_GUARD="$(composition_check review-guard "$WORKFLOWS_DIR")"
assert_empty "the review runs on human pull requests and on no automated one" "$BAD_REVIEW_GUARD"
echo ""

echo "Test 15: a job gated on a status function does not start on a cancelled run"

# A CANCELLED job is not a FAILED one, and an `if:` that calls any status-check function
# loses the `success()` GitHub otherwise prepends. So `!failure() && (...)` -- the gate every
# delivery and deployment job carried, because it lets delivery run past a `delivery-release`
# skipped on a non-bump commit and past a base pipeline that skips every job on a tag -- is
# still TRUE when `cancel-in-progress` supersedes the run. Its lint, tests and SAST are
# cancelled and delivery starts anyway. medhub-life/backend run 36349435394 did exactly that:
# every check was cancelled at 21:20:24Z, `delivery > docker` started seven seconds later,
# and it published an image of a commit nothing had verified while keeping a runner slot
# busy for ~23 minutes. Its `deployment > flyio` then started too.
#
# Asserted per CLAUSE and structurally, the way Test 11 is, because "the expression contains
# `!cancelled()`" is defeatable: `!failure() && (!cancelled() || x)` contains it and still
# starts on a cancelled push. The `if:` is split into top-level `||` clauses and each clause
# into top-level `&&` conjuncts, outside parentheses and quoted strings; every clause must
# carry `!cancelled()` or `success()` as a conjunct of its OWN -- both are false on a
# cancelled run, which makes the whole clause false. The clause beside a status function
# needs one even when it calls none itself: `(success() && a) || b` gets no implicit
# `success()`, so `b` alone starts the job -- which is why the library release gates spell
# their tag clause `(!cancelled() && startsWith(github.ref, 'refs/tags/'))`.
#
# Two things pass without a guard. An `if:` calling no status function is safe, because
# GitHub prepends `success()` to it. And a clause that selects `failure()` or `cancelled()`
# positively runs after one BY DESIGN (a notifier, a cleanup) rather than by accident.
# `always()` is neither: on a delivery job it is the same defect as `!failure()`.
#
# The classifier is also run against the gate every delivery job carried, verbatim, and
# the shapes a "tidy these conditions" pass produces, so a parser that stops matching
# fails here instead of passing with nothing flagged.
BAD_CANCEL_GATE="$(composition_check cancel-gate "$WORKFLOWS_DIR")"
assert_empty "every status-gated job clause refuses a cancelled run" "$BAD_CANCEL_GATE"
echo ""

echo "Test 16: a check job fails the run when its check fails"

# A job-level `continue-on-error` concludes the RUN as passed whatever the job did. On a lint or
# security job that makes the check advisory: the job goes red, nothing downstream waits for it,
# and the run reports success. That is how a consumer's golangci-lint stayed red on its default
# branch for about seven hours with every run green, while a golangci-lint built with an older Go
# than the code's could not load the standard library and no linter ran at all (#725).
#
# The rule: a `code-check >` or `security >` job carries no job-level `continue-on-error` -- a
# literal `true`, or an expression that can become one -- unless it is listed below with the
# reason it may stay advisory. The one failure a check tolerates is a refused report upload, and
# that belongs at the upload STEP (`make test ONLY=report-uploads` holds that half), so step-level
# flags are outside this rule.
#
# Two lists, because they mean different things:
#
#   ADVISORY    advisory ON PURPOSE, each with the reason recorded where its users read it.
#   UNREVIEWED  advisory since before this rule, with no reason recorded anywhere. Each needs the
#               check the Go pipeline had before it was made to block -- does any consumer fail
#               it today? -- because every one that does turns red the moment it blocks. This
#               list may only SHRINK: a new advisory job goes in ADVISORY with its reason, or is
#               not advisory at all.
#
# An entry whose job no longer carries the flag fails as well, so neither list outlives the code
# it excuses. The classifier also runs against canaries, so a parser that stops matching fails
# here instead of passing with nothing flagged.
BAD_ADVISORY_JOB="$(composition_check advisory-job "$WORKFLOWS_DIR")"
assert_empty "no code-check or security job is advisory unless listed with its reason" "$BAD_ADVISORY_JOB"

# The same rule on the Go pipeline's GitLab CI and Azure DevOps twins, where the flag is spelled
# `allow_failure` and `continueOnError`. Neither platform has a refused upload to excuse -- they
# publish through their own artifact stores, which GitHub's storage allowance does not meter -- so
# a job or a check step carrying the flag fails here unless listed. Azure's `task:` steps (a cache,
# an artifact publish) decide nothing about the code and stay outside the rule.
#
# Read from the two Go stage files of each platform AND every stage template they pull in from this
# repository, so a check that moves into a shared template stays covered. Those shared templates
# are why AZURE_ADVISORY is not empty: Azure DevOps runs its four SAST tools advisory by the
# per-platform decision CLAUDE.md records, for every toolchain at once, and making them block is a
# decision about every Azure pipeline rather than about the Go one.
BAD_ADVISORY_TWIN="$(composition_check advisory-twin "$SCRIPTS_DIR")"
assert_empty "the Go pipeline's GitLab and Azure DevOps twins keep no check advisory unless listed" \
  "$BAD_ADVISORY_TWIN"
echo ""

echo "Test 17: a deployment handed a delivered image may pull it"

# `go-flyio.yaml` deploys the image `delivery > docker` pushed to GHCR instead of building one, and
# its deployment job pulls that image with its own `GITHUB_TOKEN`. A job that declares
# `permissions:` gets `none` for every scope it leaves out, so without `packages: read` the pull of
# a private image is refused -- at deploy time, after every check has passed, and as an
# authentication error that reads like a bad token rather than a missing grant.
#
# Asserted over every workflow, not over `go-flyio.yaml` alone, so the next deployment composed on a
# delivered image is held too: a job whose step is handed a `needs.<job>.outputs.image` and that
# declares `permissions:` must grant `packages` (`read` or `write`, or the `read-all` / `write-all`
# shorthand). A job declaring none inherits its caller's grant and is not asked. The scan must find
# at least one such job, so renaming the output cannot make it pass by reading nothing, and the
# classifier is run against canaries first.
BAD_PACKAGES_GRANT="$(composition_check packages-grant "$WORKFLOWS_DIR")"
assert_empty "every deployment handed a delivered image may pull it" "$BAD_PACKAGES_GRANT"
echo ""

echo "Test 18: the stages run one after another"

# GitHub Actions has no stages. A job starts as soon as the jobs it `needs:` are done, so a stage is
# only as real as its edges: a security job that needs one lint job starts while the changelog gate
# and the cross-compile check are still running, and a run of eleven jobs reads as one wide column
# rather than code-check -> security -> tests -> management. A consumer pipeline grew to 53 checks
# started at once (dotfiles PR #284, 19 jobs running at the peak) before anything objected.
#
# The rule, read from the PARSED workflows: a job named `security > `, `tests > ` or `management > `
# needs EVERY job of the stage before it (the nearest earlier stage the file has); a `delivery > ` or
# `deployment > ` job needs the whole pipeline it ships -- the base workflow it calls, or the last
# checking stage of its own file. Its companion: a job downstream of a check that can be skipped
# calls a status function in its own `if:`. GitHub skips every job of a dependency chain from a
# skipped one onwards unless the job's condition says otherwise, and `basic-checks` runs only on a
# pull request, so without it the barrier would skip every later stage on every push to `main`,
# green and silently. A skip further down -- a job that runs only after a release was cut -- may
# still propagate, on purpose. Canaries run first, so a parser that stops reading stages fails here.
BAD_STAGE_BARRIER="$(composition_check stage-barrier "$WORKFLOWS_DIR")"
assert_empty "every stage waits for the whole stage before it, and survives a skipped check" "$BAD_STAGE_BARRIER"
echo ""

echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All workflow composition tests passed!"
