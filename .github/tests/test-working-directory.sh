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
# The parse is PyYAML rather than the indented-text reading `order-check` and
# `var-catalog` work under: every assertion here is about a step's `with:` map or
# a step-level key, which is a nesting question rather than a line shape, and the
# workflow-composition suite already depends on PyYAML for exactly that reason.

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
# same nine workflows.
FINDINGS="$(mktemp)"
trap 'rm -f "$FINDINGS"' EXIT

python3 - "$SCRIPTS_DIR" > "$FINDINGS" <<'PY'
import os
import re
import sys

try:
    import yaml
except ImportError:                                 # pragma: no cover
    print('deps\tPyYAML is required for this suite (pip install pyyaml)')
    raise SystemExit(0)

ROOT = sys.argv[1]
WORKFLOWS = os.path.join(ROOT, '.github', 'workflows')

# The toolchain workflows that accept the input, and the base each variant calls.
BASES = {
    'bundler.yaml': None,
    'npm.yaml': None,
    'yarn.yaml': None,
    'bundler-library.yaml': 'bundler',
    'bundler-docker.yaml': 'bundler',
    'npm-library.yaml': 'npm',
    'npm-docker.yaml': 'npm',
    'yarn-library.yaml': 'yarn',
    'yarn-docker.yaml': 'yarn',
}

# Composite stages that run a project command and therefore take the same input.
ACTIONS = [
    os.path.join('github', 'javascript', 'stages', '10-code-check', 'format', 'action.yaml'),
    os.path.join('github', 'javascript', 'stages', '10-code-check', 'knip', 'action.yaml'),
]

# Jobs that scan the REPOSITORY. They must never be scoped to the project: see
# the header. `code_check-basic_checks` is here for the same reason -- it reads
# the changelog and the branch's ancestry, neither of which is in the project.
REPOSITORY_WIDE = {
    'code_check-basic_checks',
    'security-sast_codeql',
    'security-sast_semgrep',
    'security-sast_gitleaks',
    'security-sast_hadolint',
}

SCOPE = '${{ inputs.working_directory }}'

# The shared SonarQube runner, and the variable that tells it where the project is.
SONAR_RUNNER = os.path.join('global', 'scripts', 'tools', 'sonarqube', 'run.sh')
SONAR_PROJECT_DIR = 'SONAR_PROJECT_DIR'

# A `run:` step belongs to the project when its script drives the project's own
# toolchain. Anchored at the start of a line so the Corepack guard
# (`... || npm i -g corepack`), which installs a global shim and is genuinely
# path-independent, is not swept in with the installs.
PROJECT_COMMAND = re.compile(r'(?m)^\s*(npm|yarn|bundle|gem exec)\b')
PROJECT_SCRIPT = '/global/scripts/languages/'


def emit(group, message):
    print('%s\t%s' % (group, message))


def load(path):
    with open(path, encoding='utf-8') as handle:
        return yaml.safe_load(handle)


def triggers(document):
    # YAML 1.1 resolves the `on:` key to the boolean True, which is why this
    # exists rather than a plain `document['on']`.
    return document.get('on', document.get(True, {})) or {}


def call_inputs(document):
    return (triggers(document).get('workflow_call') or {}).get('inputs') or {}


def steps_of(job):
    return job.get('steps') or []


def declares(name, spec, expected_default):
    """The input has to be OPTIONAL and default to the root, or every existing
    consumer of the workflow becomes a validation error on the next run."""
    problems = []
    if spec is None:
        return ['%s does not declare `working_directory`' % name]
    if spec.get('required') not in (False, None):
        problems.append('%s declares `working_directory` as required' % name)
    if spec.get('default') != expected_default:
        problems.append("%s defaults `working_directory` to %r, not %r"
                        % (name, spec.get('default'), expected_default))
    return problems


for filename, base in sorted(BASES.items()):
    path = os.path.join(WORKFLOWS, filename)
    if not os.path.isfile(path):
        emit('declared', '%s is missing entirely' % filename)
        continue

    document = load(path)
    inputs = call_inputs(document)

    for problem in declares(filename, inputs.get('working_directory'), '.'):
        emit('declared', problem)
    if inputs.get('working_directory', {}).get('type') not in ('string', None):
        emit('declared', '%s types `working_directory` as %r rather than string'
             % (filename, inputs['working_directory'].get('type')))

    jobs = document.get('jobs') or {}

    # A variant that declares the input and forgets to forward it is the exact
    # regression this catches: it accepts the value and silently ignores it.
    if base is not None:
        forwarded = False
        for job in jobs.values():
            uses = job.get('uses') or ''
            if uses.endswith('/.github/workflows/%s.yaml@main' % base):
                if (job.get('with') or {}).get('working_directory') == SCOPE:
                    forwarded = True
        if not forwarded:
            emit('forwarded', '%s does not pass `working_directory` to %s.yaml'
                 % (filename, base))
        continue

    for job_name, job in jobs.items():
        for index, step in enumerate(steps_of(job)):
            where = '%s :: %s :: step %d' % (filename, job_name, index)
            uses = step.get('uses') or ''
            with_ = step.get('with') or {}
            script = step.get('run') or ''

            if job_name in REPOSITORY_WIDE:
                if 'working_directory' in with_ or 'working-directory' in step:
                    emit('repository_wide',
                         '%s scopes a repository-wide scan to the project' % where)
                continue

            if uses.startswith('ruby/setup-ruby@'):
                if with_.get('working-directory') != SCOPE:
                    emit('threaded', '%s: ruby/setup-ruby has no `working-directory`' % where)
                version = str(with_.get('ruby-version', ''))
                for needle in ('inputs.ruby_version', 'env.RUBY_VERSION_FILE', "'3.3'"):
                    if needle not in version:
                        emit('ruby_version',
                             '%s: `ruby-version` does not reference %s' % (where, needle))
                # `.tool-versions` is multi-language: asdf and mise write one for
                # `nodejs` or `python` alone, and `ruby/setup-ruby` given `default`
                # against one with no `ruby` line does not fall back -- it fails the
                # step. Inferring `default` from that filename would break a polyglot
                # repository that passes NO input at all, so the guard must never
                # widen back to it.
                if 'tool-versions' in version or 'TOOL_VERSIONS' in version:
                    emit('ruby_version',
                         '%s: `ruby-version` infers `default` from `.tool-versions`, which '
                         'says nothing about a `ruby` entry being in it' % where)

            if uses.startswith('actions/setup-node@'):
                path_input = str(with_.get('cache-dependency-path', ''))
                if SCOPE not in path_input:
                    emit('threaded',
                         '%s: actions/setup-node caches against the workspace root' % where)

            if '/stages/10-code-check/' in uses and 'javascript' in uses:
                if with_.get('working_directory') != SCOPE:
                    emit('threaded', '%s: %s is called without `working_directory`'
                         % (where, uses.split('/stages/')[-1].split('@')[0]))

            # The Sonar scan is the one project-aware step that must KEEP running from
            # the repository root -- `sonar.sources` is the whole repository -- while
            # still being told where the project is. It decides whether coverage exists
            # by globbing relative to its own working directory, and when it finds none
            # it appends EMPTY `sonar.*.reportPaths` values, which override the ones the
            # repository set for itself: a subfolder project then reports 0% coverage on
            # new code, failing a default quality gate with a green job and one line of
            # log. Both halves are asserted because either alone is a silent no-op.
            if SONAR_RUNNER in script.replace('\\', '/'):
                if 'working-directory' in step:
                    emit('sonar', '%s: the Sonar scan is scoped to the project, so it '
                                  'stops analysing the rest of the repository' % where)
                if (step.get('env') or {}).get(SONAR_PROJECT_DIR) != SCOPE:
                    emit('sonar', '%s: the Sonar runner is not told where the project is '
                                  '(no `%s`), so a subfolder project is read as having no '
                                  'coverage' % (where, SONAR_PROJECT_DIR))

            if script and (PROJECT_COMMAND.search(script) or PROJECT_SCRIPT in script):
                if step.get('working-directory') != SCOPE:
                    emit('threaded', '%s: a project command runs in the workspace root: %s'
                         % (where, script.strip().splitlines()[-1].strip()))

            # A report path left root-relative does not fail -- it makes the step
            # skip, so the report simply stops appearing.
            for key in ('json-summary-path', 'json-final-path', 'vite-config-path', 'path'):
                value = with_.get(key)
                if not isinstance(value, str):
                    continue
                if re.match(r"^(\./)?(coverage|junit-report|build|vite\.config)", value):
                    emit('report_paths', '%s: `%s: %s` is relative to the workspace root'
                         % (where, key, value))
            guard = str(step.get('if', ''))
            for literal in ("hashFiles('coverage", "hashFiles('junit", "hashFiles('build"):
                if literal in guard:
                    emit('report_paths',
                         '%s: a hashFiles() guard names a workspace-root path' % where)

for relative in ACTIONS:
    path = os.path.join(ROOT, relative)
    if not os.path.isfile(path):
        emit('declared', '%s is missing entirely' % relative)
        continue

    document = load(path)
    inputs = document.get('inputs') or {}
    for problem in declares(relative, inputs.get('working_directory'), '.'):
        emit('declared', problem)

    action_scope = '${{ inputs.working_directory }}'
    for index, step in enumerate((document.get('runs') or {}).get('steps') or []):
        where = '%s :: step %d' % (relative, index)
        uses = step.get('uses') or ''
        with_ = step.get('with') or {}
        script = step.get('run') or ''

        if uses.startswith('actions/setup-node@'):
            if action_scope not in str(with_.get('cache-dependency-path', '')):
                emit('threaded',
                     '%s: actions/setup-node caches against the workspace root' % where)

        if uses.startswith('actions/upload-artifact@'):
            if action_scope not in str(with_.get('path', '')):
                emit('report_paths',
                     '%s: the report is uploaded from the workspace root' % where)

        if script and (PROJECT_COMMAND.search(script) or PROJECT_SCRIPT in script):
            if step.get('working-directory') != action_scope:
                emit('threaded', '%s: a project command runs in the workspace root' % where)

# The other half of the Sonar contract: the workflow exporting the variable is a
# no-op unless the runner reads it, and both live in different files.
sonar_runner = os.path.join(ROOT, SONAR_RUNNER)
if not os.path.isfile(sonar_runner):
    emit('sonar', '%s is missing entirely' % SONAR_RUNNER)
else:
    with open(sonar_runner, encoding='utf-8') as handle:
        runner = handle.read()
    if SONAR_PROJECT_DIR not in runner:
        emit('sonar', '%s ignores `%s`, so the workflows exporting it change nothing'
             % (SONAR_RUNNER, SONAR_PROJECT_DIR))
PY

# `awk` rather than `grep -P`: the group separator is a TAB, and a portable BRE
# cannot name one -- `grep -P` is a GNU extension this suite has no reason to
# require, and `grep $'\t'` reads as a typo the first time somebody edits it.
group() {
  awk -F '\t' -v group="$1" '$1 == group { sub(/^[^\t]*\t/, ""); print }' "$FINDINGS"
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

assert_empty \
  "PyYAML must be importable (every assertion above is a no-op without it)" \
  "$(group deps)"
echo ""

echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo "================================"

if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi

echo "All working_directory tests passed!"
