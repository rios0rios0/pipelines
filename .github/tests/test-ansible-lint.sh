#!/usr/bin/env bash
# The assertion helper takes its condition as a STRING and `eval`s it, so ShellCheck cannot
# see that every variable it reads is used. A file-wide directive is only honoured before the
# first command, which is why it sits here.
# shellcheck disable=SC2034
#
# Validation for the ansible-lint runner: the linter `make ansible-lint` runs over an Ansible
# project's playbooks, roles and collections, so a project's `make lint` never depends on
# whatever `ansible-lint` a machine has installed.
#
# Asserts:
#   1. the install: a pinned version whose wheel is refused unless its SHA-256 matches the
#      committed digest -- nothing reaches pip before it does -- and then installed binary-only
#      into a virtualenv of its own, its version read from the metadata pip wrote;
#   2. the run: the virtualenv's own launcher, with the virtualenv's `bin` first on PATH, so
#      neither an `ansible-lint` nor an `ansible-playbook` in `~/.local/bin` can answer for it;
#      the project's own configuration; the SARIF report; no schema refresh and no release
#      lookup; and not offline, so ansible-lint still provisions the project's collection;
#   3. the verdict: ansible-lint's exit code, passed through, with each failure named;
#   4. the skip: a project with no Ansible content installs nothing and gets an empty SARIF
#      report, while each sign of Ansible content is enough to lint it;
#   5. the wiring: `make ansible-lint`, and a project's `lint: ansible-lint`, run the runner;
#      `make sast` does not.
#
# Runs OFFLINE, and runs no Python. ansible-lint, the virtualenv's pip and curl are stubs: this is
# about what the runner hands ansible-lint and what it makes of the answer, not about
# ansible-lint's own rules. `jq` is the real one, to read the report the skip writes.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$SCRIPTS_DIR/global/scripts/tools/ansible-lint/run.sh"
PINS="$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

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

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=/dev/null
PINNED="$(. "$PINS" && printf '%s' "$ANSIBLE_LINT_PINNED_VERSION")"

# --- Stubs -----------------------------------------------------------------------------------
# A HOME of its own, holding a fake virtualenv where `run.sh` looks for one. The version it holds
# is the METADATA of a `.dist-info`, as pip writes it: `installed` seeds it and the fake `pip`
# rewrites it with ANSIBLE_LINT_STUB_INSTALLS. `ansible-lint` records its argv, the environment it
# was handed and which `ansible-playbook` its PATH resolves, writes a SARIF report where it is
# told to, and exits ANSIBLE_LINT_STUB_EXIT. `~/.local/bin`, which the shared preamble puts first
# on PATH, holds a decoy `ansible-lint` and `ansible-playbook` -- a developer's own Ansible -- that
# record it if they ever run, and the `curl` the install path uses.
STUB_HOME="$WORK/home"
VENV="$STUB_HOME/.local/share/ansible-lint-venv"
SITE="$VENV/lib/python3.13/site-packages"
mkdir -p "$VENV/bin" "$SITE" "$STUB_HOME/.local/bin" || exit 1

installed() { # installed <version>... -- the ansible-lint distributions the virtualenv holds
  local version
  rm -rf "$SITE"/ansible_lint-*.dist-info
  for version in "$@"; do
    mkdir -p "$SITE/ansible_lint-$version.dist-info" || exit 1
    printf 'Metadata-Version: 2.4\nName: ansible-lint\nVersion: %s\n' "$version" \
      > "$SITE/ansible_lint-$version.dist-info/METADATA"
  done
}

cat > "$VENV/bin/pip" <<'STUB'
#!/usr/bin/env sh
printf '%s\n' "$@" > "$ANSIBLE_LINT_STUB_PIP_ARGV"
site="$(dirname "$0")/../lib/python3.13/site-packages"
rm -rf "$site"/ansible_lint-*.dist-info
mkdir -p "$site/ansible_lint-$ANSIBLE_LINT_STUB_INSTALLS.dist-info"
printf 'Metadata-Version: 2.4\nName: ansible-lint\nVersion: %s\n' "$ANSIBLE_LINT_STUB_INSTALLS" \
  > "$site/ansible_lint-$ANSIBLE_LINT_STUB_INSTALLS.dist-info/METADATA"
exit 0
STUB

cat > "$VENV/bin/ansible-lint" <<'STUB'
#!/usr/bin/env sh
printf '%s\n' "$@" > "$ANSIBLE_LINT_STUB_ARGV"
{
  printf 'PATH=%s\n' "$PATH"
  printf 'ANSIBLE_LINT_SKIP_SCHEMA_UPDATE=%s\n' "${ANSIBLE_LINT_SKIP_SCHEMA_UPDATE:-unset}"
  printf 'PRE_COMMIT=%s\n' "${PRE_COMMIT:-unset}"
  printf 'ansible-playbook=%s\n' "$(command -v ansible-playbook)"
} > "$ANSIBLE_LINT_STUB_ENV"
sarif=''
previous=''
for argument in "$@"; do
  [ "$previous" = "--sarif-file" ] && sarif="$argument"
  previous="$argument"
done
[ -n "$sarif" ] && echo '{"version": "2.1.0", "runs": []}' > "$sarif"
exit "${ANSIBLE_LINT_STUB_EXIT:-0}"
STUB

printf '#!/usr/bin/env sh\nexit 0\n' > "$VENV/bin/ansible-playbook"
for decoy in ansible-lint ansible-playbook; do
  printf '#!/usr/bin/env sh\necho "%s" >> "$ANSIBLE_LINT_STUB_DECOY"\nexit 0\n' "$decoy" > "$STUB_HOME/.local/bin/$decoy"
done

# curl, for the install path only: it records the URL and writes the scenario's "wheel".
cat > "$STUB_HOME/.local/bin/curl" <<'STUB'
#!/usr/bin/env sh
destination=''
previous=''
for argument in "$@"; do
  [ "$previous" = "-o" ] && destination="$argument"
  case "$argument" in https://*) printf '%s\n' "$argument" > "$ANSIBLE_LINT_STUB_CURL_URL" ;; esac
  previous="$argument"
done
printf '%s' "$ANSIBLE_LINT_STUB_WHEEL" > "$destination"
STUB
chmod +x "$VENV/bin/pip" "$VENV/bin/ansible-lint" "$VENV/bin/ansible-playbook" "$STUB_HOME/.local/bin/ansible-lint" "$STUB_HOME/.local/bin/ansible-playbook" "$STUB_HOME/.local/bin/curl"

# A collection: its `galaxy.yml`, a playbook naming its role, and its own configuration.
COLLECTION="$WORK/collection"
mkdir -p "$COLLECTION/playbooks" "$COLLECTION/roles/hello/tasks" || exit 1
printf -- '---\nnamespace: example\nname: demo\nversion: 1.0.0\n' > "$COLLECTION/galaxy.yml"
printf -- '---\n- name: Site\n  hosts: all\n  roles:\n    - example.demo.hello\n' > "$COLLECTION/playbooks/site.yml"
printf -- '---\n- name: Say hello\n  ansible.builtin.debug:\n    msg: hello\n' > "$COLLECTION/roles/hello/tasks/main.yml"
printf -- '---\nprofile: production\n' > "$COLLECTION/.ansible-lint"

# run_lint <project> [VAR=value...] -- runs `run.sh` in the project; leaves its combined output in
# $OUTPUT and its exit code in $STATUS. Every setting the runner reads starts empty, so a value in
# the caller's environment cannot decide an assertion.
STATUS=0
run_lint() {
  local project="$1"
  shift
  rm -f "$WORK/argv" "$WORK/env" "$WORK/pip-argv" "$WORK/curl-url" "$WORK/decoy"
  # shellcheck disable=SC2086 # ANSIBLE_LINT_TEST_INSTALLED may name several versions, one per word
  installed ${ANSIBLE_LINT_TEST_INSTALLED:-$PINNED}
  STATUS=0
  OUTPUT="$(
    cd "$project" || exit 97
    env HOME="$STUB_HOME" SCRIPTS_DIR="$SCRIPTS_DIR" REPORT_PATH='' \
      ANSIBLE_LINT_VERSION='' ANSIBLE_LINT_SHA256_OVERRIDE='' \
      ANSIBLE_LINT_SKIP_SCHEMA_UPDATE='' PRE_COMMIT='' \
      ANSIBLE_LINT_STUB_ARGV="$WORK/argv" ANSIBLE_LINT_STUB_ENV="$WORK/env" \
      ANSIBLE_LINT_STUB_PIP_ARGV="$WORK/pip-argv" ANSIBLE_LINT_STUB_INSTALLS="$PINNED" \
      ANSIBLE_LINT_STUB_CURL_URL="$WORK/curl-url" ANSIBLE_LINT_STUB_DECOY="$WORK/decoy" \
      "$@" "$RUNNER" 2>&1
  )" || STATUS=$?
}

# after_flag <flag> -- the argument ansible-lint was handed after <flag>, if it was.
after_flag() {
  grep -A1 -x -- "$1" "$WORK/argv" 2> /dev/null | sed -n '2p'
}

echo "=========================================="
echo "ansible-lint runner validation"
echo "=========================================="

echo ""
echo "--- 1. The install: pinned, digest-verified, binary-only ---"

# shellcheck source=/dev/null
DIGEST="$(. "$PINS" && printf '%s' "$ANSIBLE_LINT_SHA256")"
ASSET="$(grep -B1 '^ANSIBLE_LINT_SHA256=' "$PINS" | sed -n 's/^# asset: //p')"
assert_true "pinned-versions.sh pins an ansible-lint version" "[[ '$PINNED' =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]"
assert_true "...with a 64-hex digest of its wheel" "[[ '$DIGEST' =~ ^[0-9a-f]{64}$ ]]"
assert_true "...tracked upstream as a PyPI package, so the scheduled check proposes its bumps" \
  "grep -B3 '^ANSIBLE_LINT_PINNED_VERSION=' '$PINS' | grep -q '^# upstream: pypi ansible-lint$'"
assert_true "...with an asset template the updater re-derives the digest from" \
  "[[ '$ASSET' == *'{version}'* ]]"
assert_true "the runner downloads exactly the file the asset template names" \
  "grep -qF \"\$(printf '%s' '$ASSET' | sed 's/{version}/\${ANSIBLE_LINT_VERSION}/g')\" '$RUNNER'"

# A "wheel" whose digest is not the committed one: the download is refused and pip never runs.
# The virtualenv reports an old version, so the runner takes its install path.
ANSIBLE_LINT_TEST_INSTALLED=0.0.0 run_lint "$COLLECTION" ANSIBLE_LINT_STUB_WHEEL='a wheel nobody published'
assert_true "a wheel that does not match the committed digest fails the lint" "[ '$STATUS' -eq 1 ]"
assert_true "...says the checksum did not match" "printf '%s' \"\$OUTPUT\" | grep -q 'checksum mismatch'"
assert_true "...and never reaches pip" "[ ! -f '$WORK/pip-argv' ]"
assert_true "...nor runs ansible-lint" "[ ! -f '$WORK/argv' ]"
assert_true "...after fetching it from PyPI's by-name path for the pinned version" \
  "grep -qx 'https://files.pythonhosted.org/packages/py3/a/ansible-lint/ansible_lint-$PINNED-py3-none-any.whl' '$WORK/curl-url'"

# The same "wheel", with its digest supplied: pip installs that verified file, binary-only.
WHEEL_DIGEST="$(printf '%s' 'a wheel nobody published' | sha256sum | awk '{print $1}')"
ANSIBLE_LINT_TEST_INSTALLED=0.0.0 run_lint "$COLLECTION" ANSIBLE_LINT_STUB_WHEEL='a wheel nobody published' \
  ANSIBLE_LINT_SHA256_OVERRIDE="$WHEEL_DIGEST"
assert_true "a verified wheel is handed to pip as a file" \
  "grep -qx '.*/ansible_lint-$PINNED-py3-none-any.whl' '$WORK/pip-argv'"
assert_true "...binary-only, so no sdist build script runs during the install" \
  "grep -qx -- '--only-binary' '$WORK/pip-argv' && grep -qx ':all:' '$WORK/pip-argv'"
assert_true "...and the lint then runs" "[ -f '$WORK/argv' ] && [ '$STATUS' -eq 0 ]"
assert_true "the runner never installs ansible-lint from the index by name" \
  "! grep -v '^[[:space:]]*#' '$RUNNER' | grep -qE 'pip[^|]* install [^|]*ansible-lint(==|[[:space:]]|\$)'"

# An install that leaves another version in the virtualenv is an install that failed.
ANSIBLE_LINT_TEST_INSTALLED=0.0.0 run_lint "$COLLECTION" ANSIBLE_LINT_STUB_WHEEL='a wheel nobody published' \
  ANSIBLE_LINT_SHA256_OVERRIDE="$WHEEL_DIGEST" ANSIBLE_LINT_STUB_INSTALLS=0.0.2
assert_true "a virtualenv that does not hold the pin after the install fails the lint, naming what it holds" \
  "[ '$STATUS' -eq 1 ] && printf '%s' \"\$OUTPUT\" | grep -q \"it holds '0.0.2'\" && [ ! -f '$WORK/argv' ]"

# The pin is read from the METADATA pip wrote, and a virtualenv holding two ansible-lint
# distributions -- a broken install -- is reinstalled, not trusted.
run_lint "$COLLECTION"
assert_true "the pinned version already installed is used as it is" \
  "[ '$STATUS' -eq 0 ] && [ ! -f '$WORK/pip-argv' ] && [ ! -f '$WORK/curl-url' ] && [ -f '$WORK/argv' ]"
ANSIBLE_LINT_TEST_INSTALLED="$PINNED 0.0.1" run_lint "$COLLECTION"
assert_true "a virtualenv holding two ansible-lint distributions is reinstalled rather than trusted" \
  "[ -f '$WORK/curl-url' ] && [ ! -f '$WORK/argv' ]"

echo ""
echo "--- 2. The run: the pinned ansible-lint, on the project's terms ---"

run_lint "$COLLECTION"
assert_true "the lint runs the virtualenv's own launcher, by path" \
  "grep -q '\"\$ANSIBLE_LINT_VENV/bin/ansible-lint\" \"\$@\"' '$RUNNER' && [ -f '$WORK/argv' ]"
assert_true "...so an ansible-lint first on PATH never runs" "[ ! -f '$WORK/decoy' ]"
assert_true "...with the virtualenv's bin first on PATH" "grep -qx 'PATH=$VENV/bin:.*' '$WORK/env'"
assert_true "...so the ansible-playbook it runs is the one installed beside it" \
  "grep -qx 'ansible-playbook=$VENV/bin/ansible-playbook' '$WORK/env'"
assert_true "the schemas are the pinned wheel's: no schema refresh" \
  "grep -qx 'ANSIBLE_LINT_SKIP_SCHEMA_UPDATE=1' '$WORK/env'"
assert_true "...and no release lookup, which ansible-lint skips only offline or under pre-commit" \
  "grep -qx 'PRE_COMMIT=1' '$WORK/env'"
assert_true "not offline, so ansible-lint still provisions the project's own collection" \
  "! grep -qx -- '--offline' '$WORK/argv'"
assert_true "the project's .ansible-lint is its configuration" "[ \"\$(after_flag --config-file)\" = '.ansible-lint' ]"
assert_true "a SARIF report under build/reports/ansible-lint/" \
  "[ \"\$(after_flag --sarif-file)\" = '$COLLECTION/build/reports/ansible-lint/ansible-lint.sarif' ] && [ -f '$COLLECTION/build/reports/ansible-lint/ansible-lint.sarif' ]"
run_lint "$COLLECTION" REPORT_PATH="$WORK/reports"
assert_true "...or under an absolute REPORT_PATH, as given" \
  "[ \"\$(after_flag --sarif-file)\" = '$WORK/reports/ansible-lint/ansible-lint.sarif' ]"

# Each name ansible-lint looks for, and the first of them when there are several.
CONFIGS="$WORK/configs"
for name in .ansible-lint.yml .ansible-lint.yaml .config/ansible-lint.yml .config/ansible-lint.yaml; do
  rm -rf "$CONFIGS" && mkdir -p "$CONFIGS/.config" || exit 1
  printf -- '---\nprofile: min\n' > "$CONFIGS/$name"
  run_lint "$CONFIGS"
  assert_true "a configuration named $name is handed to ansible-lint" \
    "[ '$STATUS' -eq 0 ] && [ \"\$(after_flag --config-file)\" = '$name' ]"
done
printf -- '---\nprofile: min\n' > "$CONFIGS/.ansible-lint"
run_lint "$CONFIGS"
assert_true "...and of several, the first in ansible-lint's own order" "[ \"\$(after_flag --config-file)\" = '.ansible-lint' ]"
rm -rf "$CONFIGS" && mkdir -p "$CONFIGS" || exit 1
printf -- '---\nnamespace: example\nname: bare\nversion: 1.0.0\n' > "$CONFIGS/galaxy.yml"
run_lint "$CONFIGS"
assert_true "without one, ansible-lint's own defaults apply" "[ -f '$WORK/argv' ] && ! grep -qx -- '--config-file' '$WORK/argv'"

echo ""
echo "--- 3. The verdict is ansible-lint's exit code ---"

for spec in '0|0|found nothing to report' \
            '2|2|found violations' \
            '3|3|its configuration is invalid' \
            '4|4|held the lock' \
            '5|5|linted no file, though this project has Ansible content' \
            '1|1|the lint did not complete'; do
  code="${spec%%|*}"; rest="${spec#*|}"; expected="${rest%%|*}"; message="${rest#*|}"
  run_lint "$COLLECTION" ANSIBLE_LINT_STUB_EXIT="$code"
  assert_true "ansible-lint exiting $code exits $expected" "[ '$STATUS' -eq '$expected' ]"
  assert_true "...and says '$message'" "printf '%s' \"\$OUTPUT\" | grep -qF '$message'"
done

echo ""
echo "--- 4. Nothing to lint is a skip ---"

# Not Ansible content: YAML without a play -- a `hosts:` nested deeper, as in a Kubernetes
# Ingress -- and Ansible content only where the runner does not look: hidden directories,
# node_modules/, vendor/ and the top-level build/.
NONE="$WORK/no-ansible"
mkdir -p "$NONE/k8s" "$NONE/.github/workflows" "$NONE/node_modules/pkg/roles" "$NONE/vendor/playbooks" \
  "$NONE/build/collections/roles" || exit 1
printf 'name: example\n' > "$NONE/config.yml"
printf 'spec:\n  tls:\n    - hosts:\n        - example.com\n' > "$NONE/k8s/ingress.yaml"
printf -- '- hosts: all\n' > "$NONE/.github/workflows/play.yml"
printf -- '---\nnamespace: example\nname: hidden\nversion: 1.0.0\n' > "$NONE/.github/galaxy.yml"
run_lint "$NONE" ANSIBLE_LINT_STUB_EXIT=2
assert_true "a project with no Ansible content skips, whatever ansible-lint would have said" "[ '$STATUS' -eq 0 ]"
assert_true "...without running ansible-lint" "[ ! -f '$WORK/argv' ]"
assert_true "...or installing anything" "[ ! -f '$WORK/curl-url' ] && [ ! -f '$WORK/pip-argv' ]"
assert_true "...and says so" "printf '%s' \"\$OUTPUT\" | grep -q 'No Ansible content found'"
assert_true "...and leaves a valid, empty SARIF report" \
  "jq -e '.runs[0].results == [] and .runs[0].tool.driver.name == \"ansible-lint\"' '$NONE/build/reports/ansible-lint/ansible-lint.sarif' > /dev/null"
ANSIBLE_LINT_TEST_INSTALLED=0.0.0 run_lint "$NONE"
assert_true "...even when the pinned version is not installed" "[ '$STATUS' -eq 0 ] && [ ! -f '$WORK/curl-url' ]"

# Each sign of Ansible content, on its own, is enough to lint the project.
SIGNS="$WORK/signs"
for sign in 'galaxy.yml|---' 'playbooks/|' 'roles/|' 'tasks/main.yml|---' \
            'site.yml|- hosts: all' 'deploy.yaml|- name: Deploy\n  hosts: all' \
            '.ansible-lint|---' '.config/ansible-lint.yml|---'; do
  path="${sign%%|*}"; content="${sign#*|}"
  rm -rf "$SIGNS" && mkdir -p "$SIGNS" || exit 1
  if [[ "$path" == */ ]]; then
    mkdir -p "$SIGNS/$path" || exit 1
  else
    mkdir -p "$(dirname "$SIGNS/$path")" || exit 1
    printf '%b\n' "$content" > "$SIGNS/$path"
  fi
  run_lint "$SIGNS"
  assert_true "'$path' alone is Ansible content, so ansible-lint runs" "[ -f '$WORK/argv' ] && [ '$STATUS' -eq 0 ]"
done

echo ""
echo "--- 5. Wired in for Make, as a linter ---"

MAKE_PROJECT="$WORK/make"
mkdir -p "$MAKE_PROJECT" || exit 1
{
  echo "SCRIPTS_DIR = $SCRIPTS_DIR"
  echo "-include \$(SCRIPTS_DIR)/makefiles/common.mk"
  echo "lint: ansible-lint"
} > "$MAKE_PROJECT/Makefile"
DRY_RUN="$(make -n --no-print-directory -C "$MAKE_PROJECT" ansible-lint 2>&1)"
assert_true "'make ansible-lint' runs the runner" \
  "printf '%s' \"\$DRY_RUN\" | grep -q 'global/scripts/tools/ansible-lint/run.sh'"
DRY_RUN="$(make -n --no-print-directory -C "$MAKE_PROJECT" lint 2>&1)"
assert_true "...and so does a project's 'lint: ansible-lint'" \
  "printf '%s' \"\$DRY_RUN\" | grep -q 'global/scripts/tools/ansible-lint/run.sh'"
DRY_RUN="$(make -n --no-print-directory -C "$MAKE_PROJECT" sast 2>&1)"
assert_true "'make sast' does not run it: it is a linter, not a SAST tool" \
  "! printf '%s' \"\$DRY_RUN\" | grep -q 'ansible-lint/run.sh'"
assert_true "common.mk lists the target among those it provides, and as phony" \
  "grep -q '^#.*Targets provided:' '$SCRIPTS_DIR/makefiles/common.mk' && sed -n '/^# Targets provided:/,/^# Requires:/p' '$SCRIPTS_DIR/makefiles/common.mk' | grep -qw 'ansible-lint' && grep -qE '^\.PHONY:.* ansible-lint( |$)' '$SCRIPTS_DIR/makefiles/common.mk'"

echo ""
echo "=========================================="
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}ansible-lint runner validation FAILED${NC}"
  exit 1
fi
echo -e "${GREEN}ansible-lint runner validation passed${NC}"
exit 0
