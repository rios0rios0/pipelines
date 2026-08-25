#!/usr/bin/env bash
# The assertion helpers take their condition as a STRING and `eval` it, so
# ShellCheck cannot see that OUT / CODE are read, and reports them as unused.
# They are not. A file-wide directive is only honoured before the first command,
# which is why it sits here rather than beside each assignment.
# shellcheck disable=SC2034
set -e

# Validation for the JavaScript formatting gate: the runner under
# `global/scripts/languages/javascript/format/`, and its wiring on GitHub
# Actions, GitLab CI and Azure DevOps.
#
# Three classes of assertion:
#
#   1. STRUCTURAL -- the job is wired on all three platforms and every template
#      points at a script that exists. A stage added to one platform and
#      forgotten on the other two is the most likely regression in this
#      repository, and nothing else in CI would catch it: each file is valid YAML
#      on its own.
#
#   2. BLOCKING -- the job must NOT carry `continue-on-error` / `allow_failure` /
#      `continueOnError`, AND on GitHub Actions it must appear in every downstream
#      `needs:` array. This is the assertion the whole gate exists for. Its
#      sibling `style:eslint` IS advisory, so "make it consistent with the job
#      next to it" is a plausible-sounding edit that would silently restore the
#      exact hole this was written to close: `eslint-config-prettier` switches off
#      every ESLint rule that overlaps with Prettier, so with both jobs advisory
#      nothing anywhere fails on formatting.
#
#      The `needs:` half is the same rule read the other way, and GitHub Actions
#      is the only platform that needs it asserted: GitLab and Azure have real
#      stage barriers, while GitHub has none. A job nothing depends on is not a
#      gate -- it goes red beside a security stage, a test stage and a delivery
#      stage that all ran to completion on unformatted code. The first version of
#      this suite checked `continue-on-error` and NOT this, and the job shipped
#      orphaned; `dart.yaml` had the convention right all along.
#
#   3. BEHAVIOURAL -- the runner's own decisions: skip a project that does not use
#      Prettier, fail one that is unformatted, pass one that is not, rewrite in
#      `--fix` mode, and prefer the project's own `format:check` script when it
#      declares one.
#
# The behavioural half runs OFFLINE and installs nothing. Prettier is replaced by
# a stub on `node_modules/.bin`, because what is under test is this repository's
# dispatch and exit-code handling, not Prettier's opinion about a semicolon.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPTS_DIR

RUNNER="$SCRIPTS_DIR/global/scripts/languages/javascript/format/run.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

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

assert_equals() {
  local description="$1"
  local expected="$2"
  local actual="$3"
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

skip() {
  echo -e "${YELLOW}  SKIP: $1${NC}"
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. STRUCTURAL
# ---------------------------------------------------------------------------

echo ""
echo "=== Structural: the gate is wired on all three platforms ==="

assert_true "the runner exists and is executable" "[[ -x '$RUNNER' ]]"

GH_ACTION="$SCRIPTS_DIR/github/javascript/stages/10-code-check/format/action.yaml"
assert_true "GitHub Actions: the composite action exists" "[[ -f '$GH_ACTION' ]]"
assert_true "GitHub Actions: the action calls the runner" \
  "grep -q 'languages/javascript/format/run.sh' '$GH_ACTION'"

for workflow in yarn npm; do
  wf="$SCRIPTS_DIR/.github/workflows/${workflow}.yaml"
  assert_true "GitHub Actions: ${workflow}.yaml declares 'code-check > style:format'" \
    "grep -q \"name: 'code-check > style:format'\" '$wf'"
  assert_true "GitHub Actions: ${workflow}.yaml points at the format action" \
    "grep -q 'javascript/stages/10-code-check/format@main' '$wf'"
done

GL_TEMPLATE="$SCRIPTS_DIR/gitlab/javascript/stages/10-code-check/yarn.yaml"
assert_true "GitLab CI: a 'style:format' job exists" "grep -q '^style:format:' '$GL_TEMPLATE'"
assert_true "GitLab CI: it calls the runner" \
  "grep -q 'languages/javascript/format/run.sh' '$GL_TEMPLATE'"
# The Node image runs as the unprivileged `node` user, so the Debian variant's
# `apt-get install` cannot work here. Comments are stripped before the negative
# half: the template EXPLAINS the choice in prose, and a grep over the whole file
# would match that explanation and report the opposite of the truth.
gl_code_only() { sed -e 's/#.*//' "$1"; }
assert_true "GitLab CI: it uses .scripts-repo, not the Debian variant" \
  "grep -q 'scripts-repo, before_script' '$GL_TEMPLATE' && ! gl_code_only '$GL_TEMPLATE' | grep -q 'scripts-repo-debian'"

AZ_STAGE="$SCRIPTS_DIR/azure-devops/javascript/stages/10-code-check/yarn.yaml"
AZ_STEPS="$SCRIPTS_DIR/azure-devops/javascript/stages/10-code-check/steps/format.yaml"
assert_true "Azure DevOps: a 'style_format' job exists" "grep -q \"job: 'style_format'\" '$AZ_STAGE'"
assert_true "Azure DevOps: the steps template exists" "[[ -f '$AZ_STEPS' ]]"
assert_true "Azure DevOps: it calls the runner" \
  "grep -q 'languages/javascript/format/run.sh' '$AZ_STEPS'"
assert_true "Azure DevOps: it checks the scripts repository out first" \
  "grep -q 'abstracts/scripts-repo.yaml' '$AZ_STEPS'"

# ---------------------------------------------------------------------------
# 2. BLOCKING
# ---------------------------------------------------------------------------

echo ""
echo "=== Blocking: the gate must be able to fail a build ==="

# Read the job's own block rather than the whole file: `style:eslint` and
# `quality:knip` are advisory in every one of these files, so a file-wide grep
# would pass on their settings and prove nothing about this job.
gh_job_block() {
  awk '/^  code_check-style_format:/{f=1} f{print} f&&/^$/{c++; if(c>=2) exit}' "$1"
}

for workflow in yarn npm; do
  wf="$SCRIPTS_DIR/.github/workflows/${workflow}.yaml"
  assert_true "GitHub Actions: ${workflow}.yaml style:format is NOT continue-on-error" \
    "! gh_job_block '$wf' | grep -q 'continue-on-error: true'"
done

# On GitHub Actions a blocking job that nothing `needs:` blocks nothing: there is
# no implicit stage barrier, so it runs CONCURRENTLY with the security, test and
# delivery stages instead of gating them. `dart.yaml` is the reference -- its own
# `code_check-style_format` is named in every second-stage `needs:` array.
for workflow in yarn npm; do
  wf="$SCRIPTS_DIR/.github/workflows/${workflow}.yaml"
  # Every job that declares `needs:` on a code-check sibling must name this one too.
  orphaned="$(awk '
    /^  [a-z_-]+:$/ { job = $1 }
    /needs: \[.*code_check-/ && !/code_check-style_format/ { print job " " $0 }
  ' "$wf")"
  assert_equals "GitHub Actions: ${workflow}.yaml gates its second stage on style:format" "" "$orphaned"
done

assert_true "GitLab CI: style:format is NOT allow_failure" \
  "! awk '/^style:format:/{f=1} f&&/^[a-z]/&&!/^style:format:/{exit} f{print}' '$GL_TEMPLATE' | grep -q 'allow_failure'"

assert_true "Azure DevOps: style_format is NOT continueOnError" \
  "! awk \"/job: 'style_format'/{f=1} f&&/job: 'quality_knip'/{exit} f{print}\" '$AZ_STAGE' | grep -q 'continueOnError'"

# ---------------------------------------------------------------------------
# 3. BEHAVIOURAL
# ---------------------------------------------------------------------------

echo ""
echo "=== Behavioural: what the runner decides ==="

# A Prettier stand-in. `--check` fails while the marker file is present and
# passes once it is gone; `--write` removes it. That is the whole contract this
# runner depends on -- an exit code and a stream of file names.
make_stub_prettier() {
  local dir="$1"
  mkdir -p "$dir/node_modules/.bin"
  cat > "$dir/node_modules/.bin/prettier" <<'STUB'
#!/usr/bin/env sh
mode="$1"
if [ "$mode" = '--write' ]; then
  rm -f UNFORMATTED
  echo 'bad.js 4ms'
  exit 0
fi
if [ -f UNFORMATTED ]; then
  echo '[warn] bad.js'
  echo '[warn] Code style issues found in 1 file.'
  exit 1
fi
echo 'All matched files use Prettier code style!'
exit 0
STUB
  chmod +x "$dir/node_modules/.bin/prettier"
}

# make_project <name> <configured|bare|scripted>
make_project() {
  local dir="$WORK_DIR/$1"
  local kind="$2"
  rm -rf "${dir:?}"
  mkdir -p "$dir"

  case "$kind" in
    bare)
      printf '{"name":"bare","version":"1.0.0"}\n' > "$dir/package.json"
      ;;
    configured)
      printf '{"name":"configured","version":"1.0.0","devDependencies":{"prettier":"^3.9.6"}}\n' > "$dir/package.json"
      printf '{"singleQuote":true}\n' > "$dir/.prettierrc"
      ;;
    scripted)
      printf '{"name":"scripted","version":"1.0.0","devDependencies":{"prettier":"^3.9.6"},"scripts":{"format:check":"echo RAN_PROJECT_SCRIPT; exit 3"}}\n' > "$dir/package.json"
      printf '{"singleQuote":true}\n' > "$dir/.prettierrc"
      ;;
  esac

  printf 'const   a=1\n' > "$dir/bad.js"
  printf '%s' "$dir"
}

# --- a project that does not use Prettier is skipped, not failed --------------
BARE="$(make_project bare bare)"
CODE=0
OUT="$(cd "$BARE" && "$RUNNER" 2>&1)" || CODE=$?
assert_equals "a project with no Prettier exits 0" "0" "$CODE"
assert_true "...and says it skipped" "grep -q 'skipping the formatting check' <<< \"\$OUT\""

# --- a configured project with an unformatted file fails ---------------------
CONFIGURED="$(make_project configured configured)"
make_stub_prettier "$CONFIGURED"
touch "$CONFIGURED/UNFORMATTED"
CODE=0
OUT="$(cd "$CONFIGURED" && "$RUNNER" 2>&1)" || CODE=$?
assert_equals "an unformatted project exits non-zero" "1" "$CODE"
assert_true "...and names the offending file" "grep -q 'bad.js' <<< \"\$OUT\""
assert_true "...and says how to fix it" "grep -q \"Run 'make format'\" <<< \"\$OUT\""
assert_true "...and writes the report" "[[ -f '$CONFIGURED/build/reports/prettier/prettier.txt' ]]"

# --- `--fix` rewrites, and the re-check then passes --------------------------
CODE=0
(cd "$CONFIGURED" && "$RUNNER" --fix > /dev/null 2>&1) || CODE=$?
assert_equals "--fix exits 0" "0" "$CODE"
assert_true "...and rewrote the tree" "[[ ! -f '$CONFIGURED/UNFORMATTED' ]]"

CODE=0
OUT="$(cd "$CONFIGURED" && "$RUNNER" 2>&1)" || CODE=$?
assert_equals "a formatted project exits 0" "0" "$CODE"
assert_true "...and says so" "grep -q 'All sources are correctly formatted' <<< \"\$OUT\""

# --- the project's own `format:check` wins over calling Prettier directly ----
#
# The fixture's script exits 3 and prints a sentinel, so both halves are proven
# at once: that it ran, and that its exit code is the job's verdict rather than
# being flattened to 0/1 somewhere in between.
if command -v npm > /dev/null 2>&1; then
  SCRIPTED="$(make_project scripted scripted)"
  make_stub_prettier "$SCRIPTED"
  CODE=0
  OUT="$(cd "$SCRIPTED" && "$RUNNER" 2>&1)" || CODE=$?
  assert_true "a declared format:check script is preferred" "grep -q 'RAN_PROJECT_SCRIPT' <<< \"\$OUT\""
  assert_equals "...and its exit code is the verdict" "3" "$CODE"
else
  skip "npm is not installed, so the project-script path cannot be exercised"
  skip "npm is not installed, so its exit-code propagation cannot be exercised"
fi

# ---------------------------------------------------------------------------

echo ""
echo "==================================="
echo -e "Passed:  ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed:  ${RED}${TESTS_FAILED}${NC}"
echo -e "Skipped: ${YELLOW}${TESTS_SKIPPED}${NC}"
echo "==================================="

if [[ "$TESTS_FAILED" -gt 0 ]]; then
  exit 1
fi
