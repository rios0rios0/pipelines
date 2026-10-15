#!/usr/bin/env bash
# The assertion helper takes its condition as a STRING and `eval`s it, so ShellCheck cannot
# see that every variable it reads is used. A file-wide directive is only honoured before the
# first command, which is why it sits here.
# shellcheck disable=SC2034
#
# Validation for the Checkov tier: the IaC misconfiguration scanner the Terraform pipelines
# lost when Trivy was removed.
#
# Asserts:
#   1. the install: a pinned version whose wheel is refused unless its SHA-256 matches the
#      committed digest -- nothing reaches pip before it does -- and then installed
#      binary-only into a virtualenv of its own, run by path;
#   2. the verdict: a failed check, a skip without a reason and a file Checkov could not parse
#      are findings; a reasoned skip is not; the verdict is read from the JSON report, not from
#      Checkov's exit code, which says nothing about the last two;
#   3. advisory by default: findings, and a scan that cannot complete, never fail the job
#      unless CHECKOV_BLOCKING is `true`, and a typo in that switch fails instead of quietly
#      meaning "advisory";
#   4. the scope: every directory in CHECKOV_DIRECTORIES, the repository's `.checkov.yaml`,
#      Terraform only, offline once installed, and a project with no Terraform skipped;
#   5. the wiring on every platform: terra.yaml and its composite action (GitHub), both terra
#      security stages (GitLab, Azure DevOps), and `make sast` for both Terraform fragments.
#
# Runs OFFLINE. Checkov, its virtualenv's Python, pip and curl are stubs: this is about what
# the runner hands Checkov and what it makes of the report, not about Checkov's own checks.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$SCRIPTS_DIR/global/scripts/tools/checkov/run.sh"
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
PINNED="$(. "$PINS" && printf '%s' "$CHECKOV_PINNED_VERSION")"

# --- Stubs -----------------------------------------------------------------------------------
# A HOME of its own, holding a fake virtualenv where `run.sh` looks for one. Its `python`
# answers the pin check from a file the fake `pip` rewrites, and hands everything else (the
# verdict script) to the real python3. `checkov` records its argv and environment and writes
# the JSON report of the scenario it is told to play.
STUB_HOME="$WORK/home"
VENV="$STUB_HOME/.local/share/checkov-venv"
mkdir -p "$VENV/bin" "$STUB_HOME/.local/bin" "$WORK/reports" || exit 1

cat > "$VENV/bin/python" <<'STUB'
#!/usr/bin/env sh
if [ "$1" = "-c" ]; then
  case "$2" in
    *importlib.metadata*) cat "$CHECKOV_STUB_VERSION_FILE"; exit 0 ;;
  esac
fi
exec python3 "$@"
STUB

cat > "$VENV/bin/pip" <<'STUB'
#!/usr/bin/env sh
printf '%s\n' "$@" > "$CHECKOV_STUB_PIP_ARGV"
printf '%s\n' "$CHECKOV_STUB_INSTALLS" > "$CHECKOV_STUB_VERSION_FILE"
exit 0
STUB

cat > "$VENV/bin/checkov" <<'STUB'
#!/usr/bin/env sh
printf '%s\n' "$@" > "$CHECKOV_STUB_ARGV"
printf '%s\n' "${CKV_SKIP_PACKAGE_UPDATE_CHECK:-unset}" > "$CHECKOV_STUB_ENV"
outputs=''
previous=''
for argument in "$@"; do
  [ "$previous" = "--output-file-path" ] && outputs="$argument"
  previous="$argument"
done
json=$(printf '%s' "$outputs" | cut -d, -f2)
sarif=$(printf '%s' "$outputs" | cut -d, -f3)
if [ -f "$CHECKOV_STUB_REPORTS/$CHECKOV_STUB_SCENARIO.json" ]; then
  cp "$CHECKOV_STUB_REPORTS/$CHECKOV_STUB_SCENARIO.json" "$json"
  echo '{"version":"2.1.0","runs":[]}' > "$sarif"
fi
exit "${CHECKOV_STUB_EXIT:-0}"
STUB

# curl, for the install path only: it records the URL and writes the scenario's "wheel".
cat > "$STUB_HOME/.local/bin/curl" <<'STUB'
#!/usr/bin/env sh
destination=''
previous=''
for argument in "$@"; do
  [ "$previous" = "-o" ] && destination="$argument"
  case "$argument" in https://*) printf '%s\n' "$argument" > "$CHECKOV_STUB_CURL_URL" ;; esac
  previous="$argument"
done
printf '%s' "$CHECKOV_STUB_WHEEL" > "$destination"
STUB
chmod +x "$VENV/bin/python" "$VENV/bin/pip" "$VENV/bin/checkov" "$STUB_HOME/.local/bin/curl"

# Reports in Checkov's own shapes, as 3.3.x writes them.
REPORTS="$WORK/reports"
check() { # check <id> <resource> <comment|-> -- one check entry
  local comment=''
  [ "$3" != '-' ] && comment=", \"suppress_comment\": \"$3\""
  printf '{"check_id": "%s", "resource": "%s", "file_path": "/main.tf", "file_line_range": [1, 9], "check_result": {"result": "FAILED"%s}}' \
    "$1" "$2" "$comment"
}
document() { # document <failed> <skipped> <parsing errors> -- one framework's report
  printf '{"check_type": "terraform", "results": {"passed_checks": [], "failed_checks": [%s], "skipped_checks": [%s], "parsing_errors": [%s]}, "summary": {"checkov_version": "%s"}}' \
    "$1" "$2" "$3" "$PINNED"
}
document '' '' '' > "$REPORTS/clean.json"
document "$(check CKV_OCI_10 oci_objectstorage_bucket.public -)" '' '' > "$REPORTS/failed.json"
document '' "$(check CKV_OCI_10 oci_objectstorage_bucket.kept 'kept public on purpose: decision record 7')" '' > "$REPORTS/reasoned.json"
document '' "$(check CKV_OCI_10 oci_objectstorage_bucket.bare 'No comment provided')" '' > "$REPORTS/unreasoned.json"
document '' "$(check CKV_OCI_10 oci_objectstorage_bucket.blank '  ')" '' > "$REPORTS/blank.json"
document '' '' '"/stacks/bad.tf"' > "$REPORTS/unparsed.json"
printf '{"passed": 0, "failed": 0, "skipped": 0, "parsing_errors": 0, "resource_count": 0, "checkov_version": "%s"}' \
  "$PINNED" > "$REPORTS/bare-summary.json"
printf '[%s, %s]' "$(document '' '' '')" "$(document "$(check CKV_OCI_7 oci_objectstorage_bucket.second -)" '' '')" \
  > "$REPORTS/two-frameworks.json"
echo 'not json' > "$REPORTS/garbage.json"

# A project with one Terraform file, and one with none.
PROJECT="$WORK/project"
mkdir -p "$PROJECT/stacks" "$WORK/no-terraform" || exit 1
echo 'resource "null_resource" "fixture" {}' > "$PROJECT/stacks/main.tf"

# run_scan <project> <scenario> [VAR=value...] -- runs `run.sh` in the project; prints its
# combined output and leaves its exit code in $STATUS.
STATUS=0
run_scan() {
  local project="$1" scenario="$2"
  shift 2
  rm -f "$WORK/argv" "$WORK/env" "$WORK/pip-argv" "$WORK/curl-url"
  printf '%s\n' "$PINNED" > "$WORK/version"
  STATUS=0
  OUTPUT="$(
    cd "$project" || exit 97
    env HOME="$STUB_HOME" SCRIPTS_DIR="$SCRIPTS_DIR" REPORT_PATH='' GITHUB_ACTIONS='' \
      CHECKOV_BLOCKING='' CHECKOV_DIRECTORIES='' CHECKOV_SHA256_OVERRIDE='' \
      CHECKOV_STUB_SCENARIO="$scenario" CHECKOV_STUB_REPORTS="$REPORTS" \
      CHECKOV_STUB_ARGV="$WORK/argv" CHECKOV_STUB_ENV="$WORK/env" \
      CHECKOV_STUB_VERSION_FILE="$WORK/version" CHECKOV_STUB_PIP_ARGV="$WORK/pip-argv" \
      CHECKOV_STUB_INSTALLS="$PINNED" CHECKOV_STUB_CURL_URL="$WORK/curl-url" \
      "$@" "$RUNNER" 2>&1
  )" || STATUS=$?
}

echo "=========================================="
echo "Checkov tier validation"
echo "=========================================="

echo ""
echo "--- 1. The install: pinned, digest-verified, binary-only, run by path ---"

# shellcheck source=/dev/null
DIGEST="$(. "$PINS" && printf '%s' "$CHECKOV_SHA256")"
ASSET="$(grep -B1 '^CHECKOV_SHA256=' "$PINS" | sed -n 's/^# asset: //p')"
assert_true "pinned-versions.sh pins a Checkov version" "[[ '$PINNED' =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]"
assert_true "...with a 64-hex digest of its wheel" "[[ '$DIGEST' =~ ^[0-9a-f]{64}$ ]]"
assert_true "...tracked upstream as a PyPI package, so the scheduled check proposes its bumps" \
  "grep -B3 '^CHECKOV_PINNED_VERSION=' '$PINS' | grep -q '^# upstream: pypi checkov$'"
assert_true "...with an asset template the updater re-derives the digest from" \
  "[[ '$ASSET' == *'{version}'* ]]"
assert_true "the runner downloads exactly the file the asset template names" \
  "grep -qF \"\$(printf '%s' '$ASSET' | sed 's/{version}/\${CHECKOV_VERSION}/g')\" '$RUNNER'"

# A "wheel" whose digest is not the committed one: the download is refused and pip never runs.
# The virtualenv reports an old version, so the runner takes its install path.
run_scan_tampered() { # run_scan_tampered <CHECKOV_BLOCKING> <CHECKOV_SHA256_OVERRIDE>
  rm -f "$WORK/pip-argv" "$WORK/argv"
  printf '0.0.0\n' > "$WORK/version"
  STATUS=0
  OUTPUT="$(
    cd "$PROJECT" || exit 97
    env HOME="$STUB_HOME" SCRIPTS_DIR="$SCRIPTS_DIR" REPORT_PATH='' GITHUB_ACTIONS='' \
      CHECKOV_DIRECTORIES='' CHECKOV_SHA256_OVERRIDE="$2" CHECKOV_BLOCKING="$1" \
      CHECKOV_STUB_SCENARIO=clean CHECKOV_STUB_REPORTS="$REPORTS" \
      CHECKOV_STUB_ARGV="$WORK/argv" CHECKOV_STUB_ENV="$WORK/env" \
      CHECKOV_STUB_VERSION_FILE="$WORK/version" CHECKOV_STUB_PIP_ARGV="$WORK/pip-argv" \
      CHECKOV_STUB_INSTALLS="$PINNED" CHECKOV_STUB_CURL_URL="$WORK/curl-url" \
      CHECKOV_STUB_WHEEL='a wheel nobody published' "$RUNNER" 2>&1
  )" || STATUS=$?
}
run_scan_tampered true ''
assert_true "a wheel that does not match the committed digest fails a blocking scan" "[ '$STATUS' -eq 1 ]"
assert_true "...says the checksum did not match" "printf '%s' \"\$OUTPUT\" | grep -q 'checksum mismatch'"
assert_true "...and never reaches pip" "[ ! -f '$WORK/pip-argv' ]"
assert_true "...nor runs Checkov" "[ ! -f '$WORK/argv' ]"
assert_true "...after fetching it from PyPI's by-name path for the pinned version" \
  "grep -qx 'https://files.pythonhosted.org/packages/py3/c/checkov/checkov-$PINNED-py3-none-any.whl' '$WORK/curl-url'"
run_scan_tampered '' ''
assert_true "advisory, the refused download is a warning, not a failure" \
  "[ '$STATUS' -eq 0 ] && printf '%s' \"\$OUTPUT\" | grep -q 'does not fail the job'"

# The same "wheel", with its digest supplied: pip installs that verified file, binary-only.
WHEEL_DIGEST="$(printf '%s' 'a wheel nobody published' | sha256sum | awk '{print $1}')"
run_scan_tampered true "$WHEEL_DIGEST"
assert_true "a verified wheel is handed to pip as a file" \
  "grep -qx '.*/checkov-$PINNED-py3-none-any.whl' '$WORK/pip-argv'"
assert_true "...binary-only, so no sdist build script runs during the install" \
  "grep -qx -- '--only-binary' '$WORK/pip-argv' && grep -qx ':all:' '$WORK/pip-argv'"
assert_true "...and the scan then runs" "[ -f '$WORK/argv' ] && [ '$STATUS' -eq 0 ]"
assert_true "the runner never installs Checkov from the index by name" \
  "! grep -v '^[[:space:]]*#' '$RUNNER' | grep -qE 'pip[^|]* install [^|]*checkov(==|[[:space:]]|\$)'"
assert_true "the scan runs the virtualenv's own launcher, so another checkov on PATH cannot shadow it" \
  "grep -q '\"\$CHECKOV_VENV/bin/checkov\" \"\$@\"' '$RUNNER'"

echo ""
echo "--- 2. The verdict comes from the report ---"

for spec in 'clean|0|nothing to report' \
            'bare-summary|0|nothing to report' \
            'reasoned|0|nothing to report' \
            'failed|1|1 failed check' \
            'unreasoned|1|1 skip(s) without a reason' \
            'blank|1|1 skip(s) without a reason' \
            'unparsed|1|1 file(s) it could not parse' \
            'two-frameworks|1|1 failed check'; do
  scenario="${spec%%|*}"; rest="${spec#*|}"; expected="${rest%%|*}"; message="${rest#*|}"
  run_scan "$PROJECT" "$scenario" CHECKOV_BLOCKING=true CHECKOV_STUB_EXIT=0
  assert_true "blocking, '$scenario' exits $expected" "[ '$STATUS' -eq '$expected' ]"
  assert_true "...and says '$message'" "printf '%s' \"\$OUTPUT\" | grep -qF '$message'"
done
run_scan "$PROJECT" unreasoned CHECKOV_BLOCKING=true
assert_true "a skip without a reason is named, with the syntax that fixes it" \
  "printf '%s' \"\$OUTPUT\" | grep -q 'CKV_OCI_10  oci_objectstorage_bucket.bare' && printf '%s' \"\$OUTPUT\" | grep -qF '#checkov:skip=<ID>:<reason>'"
run_scan "$PROJECT" failed CHECKOV_BLOCKING=true CHECKOV_STUB_EXIT=0
assert_true "a failed check fails even when Checkov exits 0 (a repository's soft-fail)" "[ '$STATUS' -eq 1 ]"
run_scan "$PROJECT" clean CHECKOV_BLOCKING=true CHECKOV_STUB_EXIT=1
assert_true "Checkov's exit 1 over a report with no findings is not a finding" "[ '$STATUS' -eq 0 ]"
run_scan "$PROJECT" garbage CHECKOV_BLOCKING=true
assert_true "an unreadable report fails a blocking scan" \
  "[ '$STATUS' -eq 1 ] && printf '%s' \"\$OUTPUT\" | grep -q 'could not be read'"
run_scan "$PROJECT" none CHECKOV_BLOCKING=true
assert_true "a missing report fails a blocking scan" "[ '$STATUS' -eq 1 ]"
run_scan "$PROJECT" clean CHECKOV_BLOCKING=true CHECKOV_STUB_EXIT=2
assert_true "an exit code other than 0 or 1 fails a blocking scan" \
  "[ '$STATUS' -eq 1 ] && printf '%s' \"\$OUTPUT\" | grep -q 'exited with code 2'"

echo ""
echo "--- 3. Advisory unless CHECKOV_BLOCKING is true ---"

run_scan "$PROJECT" failed
assert_true "by default a finding does not fail the scan" "[ '$STATUS' -eq 0 ]"
assert_true "...but is reported as a warning naming the switch" \
  "printf '%s' \"\$OUTPUT\" | grep -q 'set CHECKOV_BLOCKING=true'"
run_scan "$PROJECT" failed GITHUB_ACTIONS=true
assert_true "...and on GitHub Actions as a warning annotation" \
  "printf '%s' \"\$OUTPUT\" | grep -q '^::warning title=Checkov::'"
run_scan "$PROJECT" failed CHECKOV_BLOCKING=false
assert_true "CHECKOV_BLOCKING=false is the same advisory scan" "[ '$STATUS' -eq 0 ]"
for scenario in none garbage; do
  run_scan "$PROJECT" "$scenario"
  assert_true "advisory, a scan that cannot complete ('$scenario') does not fail" "[ '$STATUS' -eq 0 ]"
done
run_scan "$PROJECT" clean CHECKOV_STUB_EXIT=2
assert_true "advisory, a crashed Checkov does not fail" "[ '$STATUS' -eq 0 ]"
run_scan "$PROJECT" clean CHECKOV_BLOCKING=ture
assert_true "a typo in CHECKOV_BLOCKING fails, rather than quietly meaning advisory" \
  "[ '$STATUS' -eq 1 ] && printf '%s' \"\$OUTPUT\" | grep -q \"must be 'true' or 'false'\""
assert_true "...before Checkov runs" "[ ! -f '$WORK/argv' ]"

echo ""
echo "--- 4. What is scanned, and how ---"

run_scan "$PROJECT" clean
assert_true "Terraform only" "grep -qx -- '--framework' '$WORK/argv' && grep -A1 -x -- '--framework' '$WORK/argv' | grep -qx terraform"
assert_true "offline once installed: --skip-download" "grep -qx -- '--skip-download' '$WORK/argv'"
assert_true "...and no update lookup" "grep -qx 'true' '$WORK/env'"
assert_true "the repository root by default" "grep -A1 -x -- '--directory' '$WORK/argv' | grep -qx '\\.'"
assert_true "SARIF and JSON reports beside the console table" \
  "grep -qx 'console,build/reports/checkov/checkov.json,build/reports/checkov/checkov.sarif' '$WORK/argv'"
assert_true "no configuration file unless the repository has one" "! grep -qx -- '--config-file' '$WORK/argv'"

echo 'framework: [terraform]' > "$PROJECT/.checkov.yaml"
run_scan "$PROJECT" clean
assert_true "the repository's .checkov.yaml is passed as Checkov's configuration" \
  "grep -A1 -x -- '--config-file' '$WORK/argv' | grep -qx '.checkov.yaml'"
rm -f "$PROJECT/.checkov.yaml"

mkdir -p "$PROJECT/modules" || exit 1
echo 'resource "null_resource" "module" {}' > "$PROJECT/modules/main.tf"
run_scan "$PROJECT" clean CHECKOV_DIRECTORIES='stacks modules'
assert_true "every directory in CHECKOV_DIRECTORIES is scanned" \
  "[ \"\$(grep -A1 -x -- '--directory' '$WORK/argv' | grep -cxE 'stacks|modules')\" -eq 2 ]"
run_scan "$PROJECT" clean CHECKOV_DIRECTORIES='stacks absent' CHECKOV_BLOCKING=true
assert_true "a directory that does not exist fails a blocking scan" \
  "[ '$STATUS' -eq 1 ] && printf '%s' \"\$OUTPUT\" | grep -q \"'absent', which is not a directory\""
run_scan "$PROJECT" clean CHECKOV_DIRECTORIES='stacks absent'
assert_true "...and is a warning in advisory mode" "[ '$STATUS' -eq 0 ]"

run_scan "$WORK/no-terraform" failed CHECKOV_BLOCKING=true
assert_true "a project with no Terraform skips, even when blocking" "[ '$STATUS' -eq 0 ]"
assert_true "...without running Checkov" "[ ! -f '$WORK/argv' ]"
assert_true "...and leaves a valid, empty SARIF report" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"runs\"][0][\"results\"] == []' '$WORK/no-terraform/build/reports/checkov/checkov.sarif'"
mkdir -p "$WORK/no-terraform/.terraform/modules/x" "$WORK/no-terraform/node_modules/y" || exit 1
echo 'resource "null_resource" "vendored" {}' > "$WORK/no-terraform/.terraform/modules/x/main.tf"
echo 'resource "null_resource" "vendored" {}' > "$WORK/no-terraform/node_modules/y/main.tf"
run_scan "$WORK/no-terraform" failed CHECKOV_BLOCKING=true
assert_true "Terraform only under hidden directories or node_modules does not count" \
  "[ '$STATUS' -eq 0 ] && [ ! -f '$WORK/argv' ]"

echo ""
echo "--- 5. Wired in on every platform ---"

WIRING="$(python3 - "$SCRIPTS_DIR" <<'PY'
import os
import sys

import yaml


class Loader(yaml.SafeLoader):
    pass


Loader.add_constructor("!reference", lambda loader, node: loader.construct_sequence(node))
root = sys.argv[1]


def load(relative):
    with open(os.path.join(root, relative), encoding="utf-8") as handle:
        return yaml.load(handle, Loader=Loader)


problems = []
workflow = load(".github/workflows/terra.yaml")
inputs = workflow[True]["workflow_call"]["inputs"]
if inputs.get("checkov_blocking", {}).get("default") is not False:
    problems.append("terra.yaml: checkov_blocking must default to false")
if inputs.get("checkov_blocking", {}).get("type") != "boolean":
    problems.append("terra.yaml: checkov_blocking must be a boolean")
if inputs.get("checkov_directories", {}).get("default") != ".":
    problems.append("terra.yaml: checkov_directories must default to '.'")
jobs = workflow["jobs"]
job = jobs.get("security-sast_checkov") or {}
if job.get("name") != "security > sast:checkov":
    problems.append("terra.yaml: the job must be named 'security > sast:checkov'")
if "continue-on-error" in job:
    problems.append("terra.yaml: advisory mode lives in the script, not in a job-level continue-on-error")
step = (job.get("steps") or [{}])[0]
if step.get("uses") != "rios0rios0/pipelines/github/global/stages/20-security/checkov@main":
    problems.append("terra.yaml: the job must run the checkov stage @main")
if step.get("with") != {"blocking": "${{ inputs.checkov_blocking }}", "directories": "${{ inputs.checkov_directories }}"}:
    problems.append("terra.yaml: the job must pass checkov_blocking and checkov_directories through")
for name in ("tests-test_all", "tests-test_validate", "tests-test_structural"):
    if "security-sast_checkov" not in (jobs[name].get("needs") or []):
        problems.append("terra.yaml: %s must need security-sast_checkov, as it needs the other scans" % name)

action = load("github/global/stages/20-security/checkov/action.yaml")
execute = [s for s in action["runs"]["steps"] if s.get("name") == "Execute"]
if not execute or execute[0].get("env") != {"CHECKOV_BLOCKING": "${{ inputs.blocking }}", "CHECKOV_DIRECTORIES": "${{ inputs.directories }}"}:
    problems.append("action.yaml: the inputs must reach the script through env:")
elif "checkov/run.sh" not in execute[0].get("run", ""):
    problems.append("action.yaml: Execute must run checkov/run.sh")
if action["inputs"]["blocking"].get("default") != "false":
    problems.append("action.yaml: blocking must default to 'false'")

gitlab = load("gitlab/global/stages/20-security/checkov.yaml").get("sast:checkov") or {}
if not any("checkov/run.sh" in line for line in gitlab.get("script") or []):
    problems.append("gitlab: sast:checkov must run checkov/run.sh")
azure = load("azure-devops/global/stages/20-security/checkov.yaml")["jobs"][0]
if not any("checkov/run.sh" in str(s.get("script", "")) for s in azure["steps"]):
    problems.append("azure-devops: sast_checkov must run checkov/run.sh")

for relative, needle in (
    ("gitlab/terra/stages/20-security/terra.yaml", "gitlab/global/stages/20-security/checkov.yaml"),
    ("gitlab/terraform/stages/20-security/terra.yaml", "gitlab/global/stages/20-security/checkov.yaml"),
    ("azure-devops/terra/stages/20-security/terra.yaml", "global/stages/20-security/checkov.yaml"),
    ("azure-devops/terraform/stages/20-security/terra.yaml", "global/stages/20-security/checkov.yaml"),
):
    with open(os.path.join(root, relative), encoding="utf-8") as handle:
        if needle not in handle.read():
            problems.append("%s: the security stage must include the Checkov job" % relative)

print("\n".join(problems))
PY
)"
assert_true "terra.yaml, its action and both terra security stages on GitLab and Azure DevOps wire the scan" \
  "[ -z \"\$WIRING\" ] || { printf '%s\n' \"\$WIRING\" | sed 's/^/         /'; false; }"

for fragment in terra terraform; do
  MAKE_PROJECT="$WORK/make-$fragment"
  mkdir -p "$MAKE_PROJECT" || exit 1
  {
    echo "SCRIPTS_DIR = $SCRIPTS_DIR"
    echo "-include \$(SCRIPTS_DIR)/makefiles/$fragment.mk"
    echo "-include \$(SCRIPTS_DIR)/makefiles/common.mk"
  } > "$MAKE_PROJECT/Makefile"
  DRY_RUN="$(make -n --no-print-directory -C "$MAKE_PROJECT" sast 2>&1)"
  assert_true "$fragment.mk: 'make sast' runs Checkov" \
    "printf '%s' \"\$DRY_RUN\" | grep -q 'global/scripts/tools/checkov/run.sh'"
  echo 'CHECKOV_BLOCKING = true' >> "$MAKE_PROJECT/Makefile"
  DRY_RUN="$(make -n --no-print-directory -C "$MAKE_PROJECT" checkov 2>&1)"
  assert_true "$fragment.mk: a project's CHECKOV_BLOCKING reaches the script" \
    "printf '%s' \"\$DRY_RUN\" | grep -q \"CHECKOV_BLOCKING='true'\""
done
GO_PROJECT="$WORK/make-go"
mkdir -p "$GO_PROJECT" || exit 1
{
  echo "SCRIPTS_DIR = $SCRIPTS_DIR"
  echo "-include \$(SCRIPTS_DIR)/makefiles/golang.mk"
  echo "-include \$(SCRIPTS_DIR)/makefiles/common.mk"
} > "$GO_PROJECT/Makefile"
DRY_RUN="$(make -n --no-print-directory -C "$GO_PROJECT" sast 2>&1)"
assert_true "a project without Terraform does not get Checkov in its 'make sast'" \
  "! printf '%s' \"\$DRY_RUN\" | grep -q 'checkov/run.sh'"

echo ""
echo "=========================================="
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}Checkov tier validation FAILED${NC}"
  exit 1
fi
echo -e "${GREEN}Checkov tier validation passed${NC}"
exit 0
