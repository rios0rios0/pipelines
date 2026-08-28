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
# WHAT IT DOES NOT DO
#
# Tests 1-9 do not parse YAML with a library -- the same constraint `order-check`
# and `var-catalog` work under. They read the files as indented text, which is
# sufficient because each is about a line shape (a job key at two spaces, a
# `name:` at four) rather than about a resolved document. A workflow written in
# flow style would slip past them; none is, and one would fail review long
# before this.
#
# Tests 10, 11 and 12 are the exceptions and do need PyYAML. Test 10 asserts under a
# key YAML 1.1 RESOLVES -- `on:` parses as the boolean `true`, so `runs_on` sits
# under no key spelled `on` at all and no indentation rule can reach it -- and
# Test 11 needs the `if:` as ONE expression, which a block scalar spreads over
# ten physical lines, and Test 12 walks the whole trigger block for evaluated
# expressions. All three are written so that a host without PyYAML sees the
# assertion FAIL BY NAME rather than a traceback -- see the comments there. CI
# installs `python3-yaml` (`.github/workflows/ci.yaml`), and `make test` already
# requires it for `test-azure-step-names.sh` and `test-lambda-templates.sh`.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPTS_DIR

WORKFLOWS_DIR="$SCRIPTS_DIR/.github/workflows"

# Reusable workflows whose name carries a hyphen WITHOUT being `<toolchain>-`
# anything. All five are deliberate and none composes a base:
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
STANDALONE='flutter-artifacts.yaml update-major-version-tag.yaml dependency-updates.yaml reusable-claude-review.yaml reusable-claude-mention.yaml'

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

# The fact table every assertion below reads. One pass over the workflows,
# emitting `<kind>\t<workflow>\t<job>\t<detail>` lines, so the assertions are
# lookups into a flat file rather than nine separate parses.
FACTS="$(mktemp)"
trap 'rm -f "$FACTS"' EXIT

python3 - "$WORKFLOWS_DIR" > "$FACTS" <<'PY'
import os
import re
import sys

workflows_dir = sys.argv[1]

JOB_KEY = re.compile(r'^  ([A-Za-z0-9_-]+):\s*$')
STAGE_COMMENT = re.compile(r'^  # (\w+) stage\s*$')
# `uses:` may sit at the job level (a called workflow) or inside a step.
# Third-party actions are pinned to a full commit SHA with the human-readable
# version carried in a trailing `# vX.Y.Z` comment, so the ref must be captured
# WITHOUT anchoring at end-of-line. Anchoring there silently dropped every
# pinned `uses:` from the fact table, which would make Tests 3, 6 and 7 pass by
# having nothing left to check rather than by the invariant holding.
USES = re.compile(r"^\s*-?\s*uses:\s*'?([^'\s]+?)'?(?:\s+#.*)?\s*$")
NAME = re.compile(r"^    name:\s*'?([^']*)'?\s*$")
JOB_KEYS = ('needs', 'environment', 'permissions', 'if')
AT_JOB_LEVEL = {key: re.compile(r'^    ' + key + r':') for key in JOB_KEYS}


def emit(kind, workflow, job, detail=''):
    print('\t'.join((kind, workflow, job, detail)))


for filename in sorted(os.listdir(workflows_dir)):
    if not filename.endswith('.yaml'):
        continue
    with open(os.path.join(workflows_dir, filename), encoding='utf-8') as handle:
        lines = handle.read().splitlines()

    in_jobs = False
    job = ''
    stage_comment = ''
    for line in lines:
        if line.startswith('jobs:'):
            in_jobs = True
            continue
        if not in_jobs:
            # The `on:` block. A reusable workflow declares `workflow_call`; the
            # trap this standard exists to prevent declares `workflow_run`.
            if re.match(r'^\s+workflow_call:', line):
                emit('reusable', filename, '')
            if re.match(r'^\s+workflow_run:', line):
                emit('workflow-run', filename, '')
            continue

        stage = STAGE_COMMENT.match(line)
        if stage:
            stage_comment = stage.group(1)
            continue

        job_key = JOB_KEY.match(line)
        if job_key:
            job = job_key.group(1)
            emit('job', filename, job, stage_comment)
            stage_comment = ''
            continue

        if not job:
            continue

        display = NAME.match(line)
        if display:
            emit('job-name', filename, job, display.group(1))
            continue

        for key in JOB_KEYS:
            if AT_JOB_LEVEL[key].match(line):
                emit('job-has-' + key, filename, job)

        uses = USES.match(line)
        if uses:
            emit('uses', filename, job, uses.group(1))
PY

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
# Two more things about the shape below are deliberate:
#
#   - It reads the PARSED document, one of the two assertions here that does, and
#     the file header says why. Same shape as `test-dart-pipeline.sh`.
#   - Every path through the Python exits 0 and speaks through stdout. This script
#     runs under `set -e`, so a non-zero exit inside the command substitution would
#     kill the suite mid-run with no FAIL line and no summary -- which reads as a
#     crash rather than as a verdict. `except Exception` around the per-file body
#     is deliberately that broad: `OSError`/`YAMLError` cover an unreadable file,
#     but an EMPTY workflow (`safe_load` returns `None`), a scalar `runs_on:` or a
#     job with an empty body are all well-formed YAML that raise `AttributeError`
#     on the lookups below -- which would abort the suite for the shapes it exists
#     to report.
BAD_RUNS_ON="$(python3 - "$WORKFLOWS_DIR" <<'PY'
import glob
import os
import re
import sys

try:
    import yaml
except ImportError:
    print('PyYAML is required for this assertion '
          '(CI installs python3-yaml; locally: pip install pyyaml)')
    sys.exit(0)

workflows_dir = sys.argv[1]

# `${{inputs.runs_on}}` and `${{ inputs.runs_on }}` are the same forward. Comparing
# the raw string would report the correct one as "not forwarding runs_on", which
# points a reader at the wrong defect -- `test-dart-pipeline.sh` checks presence for
# the same reason. Normalising keeps the stricter check without the false positive.
EXPRESSION = re.compile(r'\$\{\{\s*(.*?)\s*\}\}')


def normalized(value):
    return EXPRESSION.sub(r'${{ \1 }}', value) if isinstance(value, str) else value


# A job's runner must be CALLER-SELECTABLE; it need not be this exact input.
# `runs-on` is a hard selector, so a hardcoded runner is what strands a consumer --
# and a workflow spanning two platforms genuinely cannot express both through one
# input (`flutter-artifacts.yaml` documents an `ipa` job needing macOS). So the rule
# is "resolves from a DECLARED input", which rejects every hardcoded runner while
# leaving a second input available for a hard platform requirement.
# `\s*` inside, not just around: `normalized()` collapses the whitespace bordering
# `${{ … }}` and a reformat may equally produce `fromJSON( inputs.runs_on )`. Anchoring
# on exact interior spacing would report that correct job as PINNING A RUNNER -- the
# wrong-defect message the `with:` compare was already fixed for.
RUNNER = re.compile(r'^\$\{\{\s*fromJSON\(\s*inputs\.(\w+)\s*\)\s*\}\}$')


def declared_inputs(document):
    # YAML 1.1 reads the `on:` key as the boolean `true`.
    trigger = document.get('on', document.get(True)) or {}
    return (trigger.get('workflow_call') or {}).get('inputs') or {}


def runs_on_input(document):
    return declared_inputs(document).get('runs_on')


def takes_runs_on(workflows_dir, uses):
    """Does the workflow this job CALLS declare a `runs_on` input?

    A `with:` key the callee does not declare is rejected by GitHub outright, so
    demanding the forward unconditionally would be a trap the day a `runs_on`-
    declaring workflow calls one without it (`update-major-version-tag.yaml` is the
    callable example here, and `release.yaml` already calls it). Only a sibling in
    this directory can be resolved; anything else is assumed to take it, which is
    the status quo rather than a new silence.
    """
    reference = str(uses).split('@')[0]
    # By basename alone, `someorg/theirrepo/.github/workflows/go.yaml@v1` would resolve
    # to THIS repository's `go.yaml` and the forward would be demanded of a callee that
    # does not declare it -- the same trap this function exists to avoid, from the other
    # side. Only a local path or this repository's own workflows are resolvable.
    if not (reference.startswith('./')
            or reference.startswith('rios0rios0/pipelines/.github/workflows/')):
        return True
    path = os.path.join(workflows_dir, os.path.basename(reference))
    if not os.path.isfile(path):
        return True
    try:
        with open(path, encoding='utf-8') as handle:
            return runs_on_input(yaml.safe_load(handle) or {}) is not None
    except (OSError, yaml.YAMLError):
        return True


# DECLARATION half: these must offer the input at all.
must_declare = sorted(glob.glob(os.path.join(workflows_dir, 'reusable-claude-*.yaml')))
if not must_declare:
    print('no reusable-claude-*.yaml in .github/workflows/ -- renamed, or removed')

for path in sorted(glob.glob(os.path.join(workflows_dir, '*.yaml'))):
    name = os.path.basename(path)
    problems = []
    try:
        with open(path, encoding='utf-8') as handle:
            document = yaml.safe_load(handle) or {}

        spec = runs_on_input(document)
        if spec is None:
            # CONTRACT half applies only to workflows that offer the input, so its
            # ABSENCE has to be a finding in its own right or the whole assertion
            # inverts -- a workflow that drops the input stops being iterated and
            # passes by not being looked at. Two ways it becomes one:
            if path in must_declare:
                print(f'{name}: declares no runs_on workflow_call input')
            elif 'workflow_call' in (document.get('on', document.get(True)) or {}):
                # A REUSABLE workflow that composes one taking `runs_on` must pass the
                # choice through; otherwise its consumers cannot reach a self-hosted
                # runner at all, for the composed pipeline OR its own jobs. `yarn-docker`
                # and `yarn-library` were exactly this -- their npm twins with the input
                # dropped. A LEAF caller (this repository's own `claude-review.yaml`) is
                # not reusable and is entitled to take the default, so it is not asked.
                for job, body in (document.get('jobs') or {}).items():
                    body = body or {}
                    if 'uses' in body and takes_runs_on(workflows_dir, body['uses']):
                        print(f'{name}: job {job} calls a workflow that takes runs_on, but '
                              f'{name} declares no runs_on of its own to forward -- its '
                              f'consumers cannot reach another runner')
            continue

        if not isinstance(spec, dict):
            problems.append(f'runs_on is not an input declaration ({spec!r})')
        else:
            if spec.get('required') is not False:
                problems.append('runs_on is not optional')
            if spec.get('default') != '["ubuntu-latest"]':
                problems.append('runs_on does not default to ["ubuntu-latest"]')

        reaches_a_job = False
        for job, body in (document.get('jobs') or {}).items():
            body = body or {}
            # A job that CALLS another workflow cannot declare `runs-on` -- GitHub
            # rejects the key there -- so it forwards the input instead. Demanding
            # `runs-on` of every job would fail such a job for being correct; not
            # asserting anything about it would let half a migration through, the
            # shape `test-dart-pipeline.sh` calls out on the Dart children.
            if 'uses' in body:
                if not takes_runs_on(workflows_dir, body['uses']):
                    continue
                if normalized((body.get('with') or {}).get('runs_on')) != '${{ inputs.runs_on }}':
                    problems.append(f'job {job} calls a workflow without forwarding runs_on')
                else:
                    reaches_a_job = True
                continue
            selected = normalized(body.get('runs-on'))
            selector = RUNNER.match(selected) if isinstance(selected, str) else None
            if not selector:
                problems.append(f'job {job} pins a runner instead of resolving one from an '
                                f'input ({body.get("runs-on")!r})')
            elif selector.group(1) not in declared_inputs(document):
                problems.append(f'job {job} resolves its runner from inputs.{selector.group(1)}, '
                                f'which the workflow does not declare')
            elif selector.group(1) == 'runs_on':
                reaches_a_job = True

        # The runner rule accepts ANY declared input, which is what lets a job with a hard
        # platform requirement take a second one. Without this, a workflow could declare
        # `runs_on` and route every job through something else: the consumer sets it, GitHub
        # accepts it because it is declared, and nobody reads it. A silently ignored input is
        # worse than a rejected one, and the assertion's label promises it reaches a job.
        if not problems and not reaches_a_job:
            problems.append('declares runs_on that no job resolves from or forwards')
    except (OSError, yaml.YAMLError) as error:
        problems.append(f'unreadable ({error})')
    except Exception as error:                      # noqa: BLE001 -- see the note above
        problems.append(f'{type(error).__name__}: {error}')

    if problems:
        print(f'{name}: ' + '; '.join(problems))
PY
)"
assert_empty "every runs_on input is optional, defaults to hosted, and reaches every job" "$BAD_RUNS_ON"
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
BAD_TRIGGER="$(python3 - "$WORKFLOWS_DIR" <<'PY'
import json
import os
import re
import sys

try:
    import yaml
except ImportError:
    print('PyYAML is required for this assertion '
          '(CI installs python3-yaml; locally: pip install pyyaml)')
    sys.exit(0)

WORKFLOW = 'reusable-claude-mention.yaml'
ASSOCIATION = re.compile(r'github\.event\.(\w+)\.author_association')
# Either spelling excludes an `issue_comment` payload, which carries both objects.
COMMENT_EXCLUSIONS = ("github.event.comment == null", "github.event_name == 'issues'")
# WHICH association a clause reads is only half the boundary; the other half is what it
# is read AGAINST. Adding `CONTRIBUTOR` or `NONE` is one token inside the same free-text
# block, and it opens the job to anyone who has ever landed a commit -- or to anyone at
# all -- while every pairing check above still passes.
PRIVILEGED = ['COLLABORATOR', 'MEMBER', 'OWNER']
ALLOWLIST = re.compile(r'contains\(\s*fromJSON\(\s*\'(\[[^\']*\])\'\s*\)')


def or_clauses(expression):
    """Split on `||` at parenthesis depth 0 -- the clauses are themselves parenthesised."""
    clauses, depth, current = [], 0, ''
    index = 0
    while index < len(expression):
        character = expression[index]
        if character == '(':
            depth += 1
        elif character == ')':
            depth -= 1
        elif depth == 0 and expression[index:index + 2] == '||':
            clauses.append(current)
            current = ''
            index += 2
            continue
        current += character
        index += 1
    clauses.append(current)
    return [clause.strip() for clause in clauses if clause.strip()]


path = os.path.join(sys.argv[1], WORKFLOW)
try:
    with open(path, encoding='utf-8') as handle:
        document = yaml.safe_load(handle) or {}

    for job, body in (document.get('jobs') or {}).items():
        condition = ' '.join(str((body or {}).get('if', '')).split())
        if not condition:
            print(f'{WORKFLOW}: job {job} has no `if:` -- the trigger is unguarded')
            continue
        for clause in or_clauses(condition):
            authors = set(ASSOCIATION.findall(clause))
            if not authors:
                print(f'{WORKFLOW}: job {job} has a clause reading no author_association: {clause}')
                continue
            if len(authors) > 1:
                # `or_clauses` splits at parenthesis depth 0, which only separates the
                # clauses while each is itself parenthesised. Wrap the expression --
                # `github.event_name != 'x' && ( (A) || (B) || (C) )`, or anything a
                # "tidy these conditions" pass produces -- and every `||` sits at depth
                # 1, the split returns ONE clause, and every check below degrades from
                # `paired within a clause` to `present somewhere in the expression`
                # while still printing PASS. That is this assertion's own threat model,
                # so the assumption is checked rather than documented.
                print(f'{WORKFLOW}: job {job} has one clause reading {len(authors)} payload '
                      f'associations {sorted(authors)} -- the top-level `||` split did not '
                      f'separate them, so the null-check pairing is unverified')
                continue
            for raw in ALLOWLIST.findall(clause):
                try:
                    allowed = sorted(json.loads(raw))
                except ValueError:
                    print(f'{WORKFLOW}: job {job} has an association list that is not JSON: {raw}')
                    continue
                if allowed != PRIVILEGED:
                    print(f'{WORKFLOW}: job {job} admits {allowed} -- the trigger allowlist must '
                          f'be exactly {PRIVILEGED}')
            for author in sorted(authors):
                if f'github.event.{author} != null' not in clause:
                    print(f'{WORKFLOW}: job {job} reads {author}.author_association '
                          f'without requiring github.event.{author} != null')
                if author == 'issue' and not any(x in clause for x in COMMENT_EXCLUSIONS):
                    print(f'{WORKFLOW}: job {job} reads the THREAD AUTHOR association on a clause '
                          f'that an issue_comment payload also reaches -- it carries both '
                          f'`comment` and `issue`')
except (OSError, yaml.YAMLError) as error:
    print(f'{WORKFLOW}: unreadable ({error})')
except Exception as error:                          # noqa: BLE001 -- see Test 10's note
    print(f'{WORKFLOW}: {type(error).__name__}: {error}')
PY
)"
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
BAD_ON_EXPRESSION="$(python3 - "$WORKFLOWS_DIR" <<'PY'
import glob
import os
import sys

try:
    import yaml
except ImportError:
    print('PyYAML is required for this assertion '
          '(CI installs python3-yaml; locally: pip install pyyaml)')
    sys.exit(0)

workflows_dir = sys.argv[1]

# Only `description` and `default` are documentation-shaped keys a human writes prose
# into. Every other scalar under `on:` (branch globs, paths, types) is data GitHub
# reads literally, and none of it would contain `${{` except by the same mistake --
# so flagging the two keys names the defect precisely instead of pattern-matching text.
EVALUATED_KEYS = ('description', 'default')


def walk(node, path):
    """Yield (dotted-path, value) for every EVALUATED_KEYS scalar under the trigger block."""
    if isinstance(node, dict):
        for key, value in node.items():
            child = f'{path}.{key}' if path else str(key)
            if key in EVALUATED_KEYS and isinstance(value, str):
                yield child, value
            else:
                yield from walk(value, child)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from walk(value, f'{path}[{index}]')


for workflow in sorted(glob.glob(os.path.join(workflows_dir, '*.yaml'))):
    name = os.path.basename(workflow)
    try:
        document = yaml.safe_load(open(workflow)) or {}
        # YAML 1.1 resolves `on:` to the boolean True -- the same quirk Test 10 documents.
        trigger = document.get('on', document.get(True)) or {}
        for location, value in walk(trigger, ''):
            if '${{' in value:
                print(f'{name}: on.{location} contains an evaluated expression')
    except (OSError, yaml.YAMLError) as error:
        print(f'{name}: unreadable ({error})')
    except Exception as error:                      # noqa: BLE001 -- see Test 10's note
        print(f'{name}: {type(error).__name__}: {error}')
PY
)"
assert_empty "no trigger-block description or default carries an evaluated expression" "$BAD_ON_EXPRESSION"
echo ""

echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All workflow composition tests passed!"
