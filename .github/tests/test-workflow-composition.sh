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
# Test 10 is the one exception and does need PyYAML, because the key it asserts
# under is one YAML 1.1 RESOLVES: `on:` parses as the boolean `true`, so
# `runs_on` sits under no key spelled `on` at all and no indentation rule can
# reach it. It is written so that a host without PyYAML sees that assertion FAIL
# BY NAME rather than a traceback -- see the comment there. CI installs
# `python3-yaml` (`.github/workflows/ci.yaml`), and `make test` already requires
# it for `test-azure-step-names.sh` and `test-lambda-templates.sh`.

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

echo "Test 10: the Claude reusables declare and consume runs_on"
# The Claude reusables are STANDALONE, so every rule above deliberately skips
# them -- and nothing else asserts their `runs_on` wiring. Consumers route these
# onto self-hosted runners through that input (#635), so a refactor that drops it
# or re-hardcodes the runner goes green while quietly pinning every such consumer
# back onto a hosted runner.
#
# Three things about the shape below are deliberate:
#
#   - It reads the PARSED document, the only assertion here that does, and the
#     file header says why. Same shape as `test-dart-pipeline.sh`, which asserts
#     this same wiring on the Dart workflows.
#   - The files come from a GLOB, not a list. A third `reusable-claude-*.yaml`
#     added to STANDALONE is already skipped by Tests 1, 2 and 9 by design; named
#     in a list here it would be unchecked by this one too, and a hardcoded runner
#     in it would go green. A glob matching nothing is itself reported, so a
#     rename fails here rather than passing by having nothing left to check.
#   - Every path through the Python exits 0 and speaks through stdout. This script
#     runs under `set -e`, so a non-zero exit inside the command substitution would
#     kill the suite after nine PASS lines with no FAIL line and no summary --
#     which reads as a crash rather than as a verdict. `except Exception` around
#     the per-file body is deliberately that broad: `OSError`/`YAMLError` cover an
#     unreadable file, but an EMPTY workflow (`safe_load` returns `None`), a scalar
#     `runs_on:` or a job with an empty body are all well-formed YAML that raise
#     `AttributeError` on the lookups below -- which would abort the suite for the
#     shapes it exists to report.
BAD_RUNS_ON="$(python3 - "$WORKFLOWS_DIR" <<'PY'
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
paths = sorted(glob.glob(os.path.join(workflows_dir, 'reusable-claude-*.yaml')))
if not paths:
    print('no reusable-claude-*.yaml in .github/workflows/ -- renamed, or removed')

for path in paths:
    name = os.path.basename(path)
    problems = []
    try:
        with open(path, encoding='utf-8') as handle:
            document = yaml.safe_load(handle) or {}

        # YAML 1.1 reads the `on:` key as the boolean `true`.
        trigger = document.get('on', document.get(True)) or {}
        spec = ((trigger.get('workflow_call') or {}).get('inputs') or {}).get('runs_on')
        if spec is None:
            problems.append('declares no runs_on workflow_call input')
        elif not isinstance(spec, dict):
            problems.append(f'runs_on is not an input declaration ({spec!r})')
        else:
            if spec.get('required') is not False:
                problems.append('runs_on is not optional')
            if spec.get('default') != '["ubuntu-latest"]':
                problems.append('runs_on does not default to ["ubuntu-latest"]')

        for job, body in (document.get('jobs') or {}).items():
            body = body or {}
            # A job that CALLS another workflow cannot declare `runs-on` -- GitHub
            # rejects the key there -- so it forwards the input instead. Demanding
            # `runs-on` of every job would fail such a job for being correct; not
            # asserting anything about it would let half a migration through, the
            # shape `test-dart-pipeline.sh` calls out on the Dart children.
            if 'uses' in body:
                if (body.get('with') or {}).get('runs_on') != '${{ inputs.runs_on }}':
                    problems.append(f'job {job} calls a workflow without forwarding runs_on')
            elif body.get('runs-on') != '${{ fromJSON(inputs.runs_on) }}':
                problems.append(f'job {job} does not consume fromJSON(inputs.runs_on)')
    except (OSError, yaml.YAMLError) as error:
        problems.append(f'unreadable ({error})')
    except Exception as error:                      # noqa: BLE001 -- see the note above
        problems.append(f'{type(error).__name__}: {error}')

    if problems:
        print(f'{name}: ' + '; '.join(problems))
PY
)"
assert_empty "the Claude reusables declare and consume the runs_on input" "$BAD_RUNS_ON"
echo ""

echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All workflow composition tests passed!"
