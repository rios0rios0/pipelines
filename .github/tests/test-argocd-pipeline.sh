#!/usr/bin/env bash
# The assertion helper takes its condition as a STRING and `eval`s it, so ShellCheck cannot
# see that every variable it reads is used. A file-wide directive is only honoured before the
# first command, which is why it sits here.
# shellcheck disable=SC2034,SC2016
#
# Validation for the Argo CD pipeline family (`azure-devops/argocd/`), for a GitOps repository
# of Helm charts.
#
# Sections 1 to 3 run OFFLINE (`helm` and `curl` are stubs there): the templates' wiring, the pins,
# the installers, and how a dependency on an https repository is built.
#
# Sections 4 to 7 hold the runners to their word with the REAL helm and kubeconform, on neutral
# fixture charts built here, because a stub of `helm template` would only prove the stub. Helm
# and kubeconform are the ones on PATH when they are at the pin, else the pinned installers fetch
# them into this run's scratch space. Wrappers record every argument they are given. kubeconform
# reads small schemas written here, except in section 7, which asks the two pinned commits
# themselves and so needs the network.
#
# Where neither the tools nor the network are to be had, those sections SKIP on a developer's
# machine and FAIL under CI, because a green run that exercised nothing is what they exist to
# prevent.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FAMILY="$SCRIPTS_DIR/azure-devops/argocd"
ENTRY="$FAMILY/argocd.yaml"
CODE_CHECK="$FAMILY/stages/10-code-check/argocd.yaml"
SECURITY="$FAMILY/stages/20-security/argocd.yaml"
TESTS="$FAMILY/stages/30-tests/argocd.yaml"
MANAGEMENT="$FAMILY/stages/35-management/argocd.yaml"
RELEASE="$FAMILY/stages/40-delivery/release.yaml"

RUNNERS="$SCRIPTS_DIR/global/scripts/languages/argocd"
COMMON="$RUNNERS/common.sh"
LINT="$RUNNERS/helm-lint/run.sh"
RENDER="$RUNNERS/render/run.sh"
SCHEMA="$RUNNERS/schema/run.sh"
HELM_INSTALLER="$RUNNERS/helm/install.sh"
KUBECONFORM_INSTALLER="$RUNNERS/kubeconform/install.sh"
PINS="$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
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

skip() {
  echo -e "${YELLOW}  SKIP: $1${NC}"
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

# What cannot run here: a skip for a person, and a failure for CI, which has the network.
unavailable() {
  if [ -n "${CI:-}" ]; then
    echo -e "${RED}  FAIL: $1${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    skip "$1"
  fi
}

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

# The lines of a template that are not comments, so prose about a job cannot satisfy a check
# for the job, or fail a check for its absence.
active() { grep -vE '^[[:space:]]*#' "$1"; }

# `- name: 'X'` is declared with this type and this default.
declares() {
  local file="$1" name="$2" type="$3" default="$4"
  grep -A2 -F -e "- name: '$name'" "$file" | grep -qF -e "type: '$type'" \
    && grep -A2 -F -e "- name: '$name'" "$file" | grep -qF -e "default: $default"
}

# `template: '<target>'` is followed, in its own block, by `NAME: ${{ parameters.NAME }}`.
forwards() {
  local file="$1" target="$2" name="$3"
  awk -v target="template: '$target'" '
    index($0, target) { inside = 1; next }
    inside && /^[[:space:]]*- / { inside = 0 }
    inside { print }
  ' "$file" | grep -qF -e "$name: \${{ parameters.$name }}"
}

echo "=========================================="
echo "Argo CD pipeline validation"
echo "=========================================="

echo ""
echo "--- 1. The templates ---"

for template in "$ENTRY" "$CODE_CHECK" "$SECURITY" "$TESTS" "$MANAGEMENT" "$RELEASE"; do
  assert_true "${template#"$SCRIPTS_DIR"/} exists" "[ -f '$template' ]"
done

# The order is the pipeline: every stage after the first waits for the one above it.
EXPECTED_STAGES="stages/10-code-check/argocd.yaml
stages/20-security/argocd.yaml
stages/30-tests/argocd.yaml
stages/35-management/argocd.yaml
stages/40-delivery/release.yaml"
ACTUAL_STAGES="$(active "$ENTRY" | sed -n "s/^  - template: '\(.*\)'$/\1/p")"
assert_true "the entry point includes the five stages, in order" \
  '[ "$ACTUAL_STAGES" = "$EXPECTED_STAGES" ]'

for spec in "PRE_STEPS|stepList|[]" "CHART_ROOTS|string|'.'" "MANIFEST_DIRS|string|''" \
            "KUBERNETES_VERSION|string|'master'" "EXTRA_TEST_JOBS|jobList|[]" \
            "DOWNLOAD_COVERAGE_ARTIFACT|boolean|false" "COVERAGE_ARTIFACT_NAME|string|'coverage'" \
            'COVERAGE_ARTIFACT_TARGET_PATH|string|"$(Build.SourcesDirectory)"'; do
  IFS='|' read -r spec_name spec_type spec_default <<< "$spec"
  assert_true "the entry point declares $spec_name ($spec_type, default $spec_default)" \
    'declares "$ENTRY" "$spec_name" "$spec_type" "$spec_default"'
done

for hop in "stages/10-code-check/argocd.yaml|PRE_STEPS" "stages/10-code-check/argocd.yaml|CHART_ROOTS" \
           "stages/30-tests/argocd.yaml|PRE_STEPS" "stages/30-tests/argocd.yaml|CHART_ROOTS" \
           "stages/30-tests/argocd.yaml|MANIFEST_DIRS" "stages/30-tests/argocd.yaml|KUBERNETES_VERSION" \
           "stages/30-tests/argocd.yaml|EXTRA_TEST_JOBS" \
           "stages/35-management/argocd.yaml|DOWNLOAD_COVERAGE_ARTIFACT" \
           "stages/35-management/argocd.yaml|COVERAGE_ARTIFACT_NAME" \
           "stages/35-management/argocd.yaml|COVERAGE_ARTIFACT_TARGET_PATH"; do
  hop_target="${hop%%|*}"
  hop_name="${hop#*|}"
  assert_true "the entry point forwards $hop_name to $hop_target" \
    'forwards "$ENTRY" "$hop_target" "$hop_name"'
  assert_true "$hop_target declares $hop_name" \
    "grep -qE \"^ *- name: '$hop_name'\" '$FAMILY/$hop_target'"
done

# Credentials a consumer hands `PRE_STEPS` reach the jobs that build dependencies, and no other.
assert_true "PRE_STEPS is not forwarded to the security stage" '! grep -q PRE_STEPS "$SECURITY"'
assert_true "style:helm-lint splices PRE_STEPS before the lint" \
  "grep -A12 \"job: 'style_helm_lint'\" '$CODE_CHECK' | grep -qF '\${{ each step in parameters.PRE_STEPS }}'"
assert_true "test:render splices PRE_STEPS before the render" \
  "grep -A12 \"job: 'test_render'\" '$TESTS' | grep -qF '\${{ each step in parameters.PRE_STEPS }}'"
assert_true "test:schema holds none of them" \
  "! awk '/job: .test_schema./,/EXTRA_TEST_JOBS/' '$TESTS' | grep -q 'parameters.PRE_STEPS'"

assert_true "the code check runs the shared basic checks" \
  "active '$CODE_CHECK' | grep -qF \"template: '../../../global/stages/10-code-check/basic-checks.yaml'\""
assert_true "the code check has style:helm-lint" \
  "active '$CODE_CHECK' | grep -qF \"displayName: 'style:helm-lint'\""
assert_true "style:helm-lint runs the runner" \
  "active '$CODE_CHECK' | grep -qF 'global/scripts/languages/argocd/helm-lint/run.sh'"

assert_true "semgrep reads the charts as Kubernetes" \
  "active '$SECURITY' | grep -qF \"SEMGREP_LANGUAGE: 'kubernetes'\""
assert_true "gitleaks runs" \
  "active '$SECURITY' | grep -qF \"template: '../../../global/stages/20-security/gitleaks.yaml'\""
assert_true "hadolint does not: a chart repository holds no Dockerfile" \
  '! active "$SECURITY" | grep -qi hadolint'

assert_true "test:render runs the runner" \
  "active '$TESTS' | grep -qF 'global/scripts/languages/argocd/render/run.sh'"
assert_true "test:schema runs the runner" \
  "active '$TESTS' | grep -qF 'global/scripts/languages/argocd/schema/run.sh'"
assert_true "EXTRA_TEST_JOBS is a list of jobs, spliced into the tests stage" \
  "active '$TESTS' | grep -qF '\${{ each job in parameters.EXTRA_TEST_JOBS }}:'"
assert_true "test:schema waits for test:render" \
  "grep -A3 \"job: 'test_schema'\" '$TESTS' | grep -qF \"dependsOn: 'test_render'\""
# Separate jobs have separate workspaces: the artifact is the only way the manifests arrive.
assert_true "test:render publishes what it rendered" \
  "active '$TESTS' | grep -A5 'PublishPipelineArtifact@1' | grep -qF \"artifactName: 'argocd-render'\""
assert_true "...only when the render worked, so a retry of a failed one can publish" \
  "! active '$TESTS' | grep -A3 'PublishPipelineArtifact@1' | grep -q 'condition:'"
assert_true "test:schema downloads it to where the runner reads" \
  "active '$TESTS' | grep -A4 'DownloadPipelineArtifact@2' | grep -qF '\$(Build.SourcesDirectory)/\$(REPORT_PATH)/argocd-render'"

# A parameter that stops short of the step, or a report published from a path nothing writes, fails
# nothing: the job stays green with the option ignored, and the Tests tab is merely empty.
for mapping in "$CODE_CHECK|ARGOCD_CHART_ROOTS: \${{ parameters.CHART_ROOTS }}" \
               "$TESTS|ARGOCD_CHART_ROOTS: \${{ parameters.CHART_ROOTS }}" \
               "$TESTS|ARGOCD_MANIFEST_DIRS: \${{ parameters.MANIFEST_DIRS }}" \
               "$TESTS|ARGOCD_KUBERNETES_VERSION: \${{ parameters.KUBERNETES_VERSION }}"; do
  mapping_file="${mapping%%|*}"
  mapping_line="${mapping#*|}"
  assert_true "${mapping_file#"$FAMILY"/} maps '$mapping_line' into its step" \
    'active "$mapping_file" | grep -qF -e "$mapping_line"'
done
# The same paths the real runs below read their reports from.
for report in "$CODE_CHECK|argocd-helm-lint/junit-helm-lint.xml" \
              "$TESTS|argocd-render/junit-render.xml" \
              "$TESTS|argocd-schema/junit-schema.xml"; do
  report_file="${report%%|*}"
  report_path="${report#*|}"
  assert_true "the report of ${report_path%%/*} is published from where its runner writes it" \
    'active "$report_file" | grep -qF -e "testResultsFiles: \"\$(REPORT_PATH)/$report_path\""'
done
for template in "$CODE_CHECK" "$TESTS"; do
  assert_true "${template#"$FAMILY"/} says where the reports are" \
    "active '$template' | grep -qF \"REPORT_PATH: 'build/reports'\""
done

# Stages are separate jobs, so the download is the only channel into the Sonar job, and nothing
# about a template fails when a literal starts pinning it: see the terra suite.
assert_true "the Sonar job takes the coverage opt-in from the parameter" \
  "forwards '$MANAGEMENT' '../../../global/stages/35-management/sonarqube.yaml' DOWNLOAD_COVERAGE_ARTIFACT"
assert_true "...and it defaults to off, as a chart repository publishes no coverage" \
  'declares "$MANAGEMENT" DOWNLOAD_COVERAGE_ARTIFACT boolean false'
assert_true "...with no literal pinning it" \
  "! active '$MANAGEMENT' | grep -qE 'DOWNLOAD_COVERAGE_ARTIFACT: *(true|false)'"

# Argo CD is the delivery. An id a consumer needs is an id this family must not take.
assert_true "the last stage is called release" "active '$RELEASE' | grep -qF \"stage: 'release'\""
assert_true "no stage takes the id delivery" \
  "! grep -rhE \"^[[:space:]]*- stage: 'delivery'\" '$FAMILY'"
assert_true "nothing in the family deploys" \
  "! grep -rhE '^[[:space:]]*-? *(deployment|environment):' '$FAMILY'"
assert_true "the release gate reads the management result, not a helper" \
  "active '$RELEASE' | grep -qF \"in(dependencies.management.result, 'Succeeded', 'SucceededWithIssues')\""
assert_true "the entry point says why there is no deploy stage" \
  "grep -q 'Argo CD is the delivery' '$ENTRY'"

# The hook is the reason a consumer can keep its private checks in its own repository, so the
# one example a consumer copies has to show it, a second checkout included.
assert_true "the usage example shows EXTRA_TEST_JOBS" "grep -qE '^# +EXTRA_TEST_JOBS:' '$ENTRY'"
assert_true "...with a job that checks out another repository" \
  "grep -qE \"^# +- checkout: 'example-platform'\" '$ENTRY'"

echo ""
echo "--- 2. The pins and the scripts ---"

for tool in HELM KUBECONFORM; do
  assert_true "$tool has a version and an amd64 and arm64 digest" \
    "grep -q '^${tool}_PINNED_VERSION=' '$PINS' && grep -q '^${tool}_SHA256_AMD64=' '$PINS' && grep -q '^${tool}_SHA256_ARM64=' '$PINS'"
done
for pin in CRDS_CATALOG KUBERNETES_JSON_SCHEMA; do
  assert_true "$pin is a whole commit, never a branch" \
    "grep -qE '^${pin}_PINNED_VERSION=\"[0-9a-f]{40}\"$' '$PINS'"
done
assert_true "helm tracks the major Argo CD renders with" \
  "grep -B1 -A1 '^# upstream: github-release helm/helm' '$PINS' | grep -q 'track=4'"
assert_true "both schema locations are built from the pins" \
  "grep -q '{CRDS_CATALOG_VERSION}' '$SCHEMA' && grep -q '{KUBERNETES_JSON_SCHEMA_VERSION}' '$SCHEMA'"
assert_true "no schema location names a branch" \
  "! grep -E '^[^#]*raw\.githubusercontent\.com/[^/]+/[^/]+/(main|master)/' '$SCHEMA'"

for script in "$LINT" "$RENDER" "$SCHEMA" "$HELM_INSTALLER" "$KUBECONFORM_INSTALLER"; do
  assert_true "${script#"$RUNNERS"/} is executable POSIX sh" \
    "[ -x '$script' ] && head -1 '$script' | grep -qx '#!/usr/bin/env sh'"
done
assert_true "common.sh is sourced, not executed (no +x)" "[ ! -x '$COMMON' ]"

echo ""
echo "--- 3. Offline: the installers, and a dependency from an https repository ---"

# curl serves the release built here, and logs one line per call.
STUBS="$WORK/stubs"
mkdir -p "$STUBS" || exit 1
cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env sh
destination=''
previous=''
for argument in "$@"; do
  [ "$previous" = "-o" ] && destination="$argument"
  previous="$argument"
done
printf 'download\n' >> "$STUB_CURL_LOG"
cat "$STUB_TARBALL" > "$destination"
STUB
chmod +x "$STUBS/curl"

case "$(uname -m)" in
  aarch64 | arm64) ARCH='arm64' ;;
  *) ARCH='amd64' ;;
esac

# A release of `tool` that answers its version the way the real binary does. The script is padded
# to a few MiB, because the race between installs lives in the time `tar` spends writing it.
fake_binary() {
  local tool="$1" version="$2" destination="$3"
  mkdir -p "$(dirname "$destination")" || return 1
  {
    printf '#!/bin/sh\n'
    if [ "$tool" = 'helm' ]; then
      printf 'printf "v%s"\n' "$version"
    else
      printf 'printf "v%s\\n"\n' "$version"
    fi
    printf 'exit 0\n'
    head -c 4194304 /dev/zero | tr '\0' '#'
    printf '\n'
  } > "$destination"
  chmod 755 "$destination"
}

fake_release() {
  local tool="$1" version="$2" dir="$WORK/release-$1-$2"
  if [ "$tool" = 'helm' ]; then
    fake_binary helm "$version" "$dir/linux-$ARCH/helm" || return 1
    tar -czf "$dir/release.tar.gz" -C "$dir" "linux-$ARCH/helm"
  else
    fake_binary kubeconform "$version" "$dir/kubeconform" || return 1
    tar -czf "$dir/release.tar.gz" -C "$dir" kubeconform
  fi
}

# run_installer <tool> <installer> <home> <log> [<sha256>]: asked for 9.9.9, in a clean environment,
# verified through `<TOOL>_SHA256_OVERRIDE`, which is how a version other than the pin stays verified.
run_installer() {
  local tool="$1" installer="$2" home="$3" log="$4" prefix tarball digest
  prefix="$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')"
  tarball="$WORK/release-$tool-9.9.9/release.tar.gz"
  digest="${5:-$(sha256sum "$tarball" | awk '{print $1}')}"
  env -i HOME="$home" PATH="$STUBS:/usr/bin:/bin" SCRIPTS_DIR="$SCRIPTS_DIR" \
    "${prefix}_VERSION=9.9.9" "${prefix}_SHA256_OVERRIDE=$digest" \
    STUB_TARBALL="$tarball" STUB_CURL_LOG="$home/curl.log" "$installer" > "$log" 2>&1
}

version_in() {
  if [ "$2" = 'helm' ]; then
    "$1/.local/bin/helm" version --template '{{.Version}}'
  else
    "$1/.local/bin/kubeconform" -v
  fi
}

for spec in "helm|$HELM_INSTALLER" "kubeconform|$KUBECONFORM_INSTALLER"; do
  tool="${spec%%|*}"
  installer="${spec#*|}"
  fake_release "$tool" 1.0.0 || exit 1
  fake_release "$tool" 9.9.9 || exit 1

  home="$WORK/$tool-pinned"
  mkdir -p "$home/.local/bin" || exit 1
  : > "$home/curl.log"
  fake_binary "$tool" 9.9.9 "$home/.local/bin/$tool" || exit 1
  run_installer "$tool" "$installer" "$home" "$WORK/$tool-pinned.log"
  INSTALL_RC=$?
  assert_true "$tool: one already at the pin is kept" "[ $INSTALL_RC -eq 0 ]"
  assert_true "$tool: ...and nothing is downloaded" "[ ! -s '$home/curl.log' ]"

  home="$WORK/$tool-stale"
  mkdir -p "$home/.local/bin" || exit 1
  : > "$home/curl.log"
  fake_binary "$tool" 1.0.0 "$home/.local/bin/$tool" || exit 1
  run_installer "$tool" "$installer" "$home" "$WORK/$tool-stale.log"
  INSTALL_RC=$?
  INSTALLED="$(version_in "$home" "$tool")"
  assert_true "$tool: a stale one is replaced" "[ $INSTALL_RC -eq 0 ] && [ '$INSTALLED' = 'v9.9.9' ]"
  assert_true "$tool: ...leaving no scratch directory" \
    "[ -z \"\$(find '$home/.local/bin' -mindepth 1 -name '.$tool*')\" ]"

  home="$WORK/$tool-tampered"
  mkdir -p "$home/.local/bin" || exit 1
  : > "$home/curl.log"
  fake_binary "$tool" 1.0.0 "$home/.local/bin/$tool" || exit 1
  run_installer "$tool" "$installer" "$home" "$WORK/$tool-tampered.log" \
    '0000000000000000000000000000000000000000000000000000000000000000'
  INSTALL_RC=$?
  INSTALLED="$(version_in "$home" "$tool")"
  assert_true "$tool: a download failing verification fails the install" "[ $INSTALL_RC -ne 0 ]"
  assert_true "$tool: ...and leaves the installed one as it was" "[ '$INSTALLED' = 'v1.0.0' ]"
  assert_true "$tool: ...and no scratch directory" \
    "[ -z \"\$(find '$home/.local/bin' -mindepth 1 -name '.$tool*')\" ]"

  # How a self-hosted machine runs a pipeline: agents share one HOME, and parallel jobs reach this
  # script together. Staged at a fixed path, one job moves a file another is still writing.
  home="$WORK/$tool-together"
  mkdir -p "$home/.local/bin" || exit 1
  : > "$home/curl.log"
  fake_binary "$tool" 1.0.0 "$home/.local/bin/$tool" || exit 1
  pids=()
  for run in 1 2 3 4; do
    run_installer "$tool" "$installer" "$home" "$WORK/$tool-together-$run.log" &
    pids+=("$!")
  done
  TOGETHER_FAILED=0
  for pid in "${pids[@]}"; do
    wait "$pid" || TOGETHER_FAILED=$((TOGETHER_FAILED + 1))
  done
  INSTALLED="$(version_in "$home" "$tool")"
  assert_true "$tool: four installs on one HOME all succeed" "[ $TOGETHER_FAILED -eq 0 ]"
  assert_true "$tool: ...and leave a runnable $tool at the pin" "[ '$INSTALLED' = 'v9.9.9' ]"
done

# `helm dependency build` refuses a committed Chart.lock whose https repository Helm was never
# told about, on every clean runner. Real Helm would need a chart repository to answer, so this
# is a stub with `helm dependency list`'s real table, that records what it is asked.
HTTPS_HOME="$WORK/https-home"
mkdir -p "$HTTPS_HOME/.local/bin" || exit 1
cat > "$HTTPS_HOME/.local/bin/helm" <<'STUB'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$HELM_STUB_LOG"
case "$1 $2" in
  'version --template') printf 'v%s' "$HELM_STUB_VERSION" ;;
  'dependency list')
    status='missing'
    [ -f "$HELM_STUB_BUILT" ] && status='ok'
    printf 'NAME   \tVERSION\tREPOSITORY                          \tSTATUS \n'
    printf 'example\t1.0.0  \t%s\t%s\n\n' "$HELM_STUB_URL" "$status"
    printf 'WARNING: "charts/stray-1.0.0.tgz" is not in Chart.yaml.\n'
    ;;
  'repo list')
    [ -z "$HELM_STUB_KNOWN" ] && exit 0
    printf 'NAME  \tURL\n'
    printf 'theirs\t%s\n' "$HELM_STUB_KNOWN"
    ;;
  'repo add') [ -z "$HELM_STUB_ADD_FAILS" ] ;;
  'dependency build') : > "$HELM_STUB_BUILT" ;;
esac
STUB
chmod +x "$HTTPS_HOME/.local/bin/helm"

HTTPS_REPO="$WORK/https-repo"
mkdir -p "$HTTPS_REPO/charts/example-remote" || exit 1
printf 'apiVersion: v2\nname: example-remote\nversion: 0.1.0\n' > "$HTTPS_REPO/charts/example-remote/Chart.yaml"
# shellcheck disable=SC1090 # the pin file is this repository's own
HELM_PIN="$(. "$PINS" && printf '%s' "$HELM_VERSION")"

run_https() {
  rm -f "$WORK/https.log" "$WORK/https.built"
  (
    cd "$HTTPS_REPO" || exit 1
    env HOME="$HTTPS_HOME" PATH="$HTTPS_HOME/.local/bin:$PATH" REPORT_PATH='' SCRIPTS_DIR="$SCRIPTS_DIR" \
      HELM_VERSION="$HELM_PIN" HELM_STUB_VERSION="$HELM_PIN" \
      HELM_STUB_LOG="$WORK/https.log" HELM_STUB_BUILT="$WORK/https.built" \
      HELM_STUB_URL='https://charts.example.invalid/stable/' "$@" "$LINT" 2>&1
  )
}

HTTPS_RC=0
HTTPS_OUT="$(run_https env HELM_STUB_KNOWN='' HELM_STUB_ADD_FAILS='')" || HTTPS_RC=$?
HTTPS_ADD_LINE="$(grep -n '^repo add ' "$WORK/https.log" | head -1 | cut -d: -f1)"
HTTPS_BUILD_LINE="$(grep -n '^dependency build ' "$WORK/https.log" | head -1 | cut -d: -f1)"
assert_true "an https dependency is built" "[ $HTTPS_RC -eq 0 ]"
assert_true "...after its repository was added, as a clean runner knows none" \
  '[ -n "$HTTPS_ADD_LINE" ] && [ -n "$HTTPS_BUILD_LINE" ] && [ "$HTTPS_ADD_LINE" -lt "$HTTPS_BUILD_LINE" ]'
assert_true "...under the URL the chart names, without the slash Helm ignores" \
  "grep -qE '^repo add argocd-dependency-[0-9]+ https://charts\.example\.invalid/stable$' '$WORK/https.log'"

HTTPS_RC=0
HTTPS_OUT="$(run_https env HELM_STUB_KNOWN='https://charts.example.invalid/stable' HELM_STUB_ADD_FAILS='')" || HTTPS_RC=$?
assert_true "a repository the consumer added is left alone: its entry has the credentials" \
  "[ $HTTPS_RC -eq 0 ] && ! grep -q '^repo add ' '$WORK/https.log' && grep -q '^dependency build ' '$WORK/https.log'"

HTTPS_RC=0
HTTPS_OUT="$(run_https env HELM_STUB_KNOWN='' HELM_STUB_ADD_FAILS='true')" || HTTPS_RC=$?
assert_true "a repository that cannot be added fails the job" "[ $HTTPS_RC -ne 0 ]"
assert_true "...naming the chart" '[[ "$HTTPS_OUT" == *"FAILED: charts/example-remote (dependencies)"* ]]'
assert_true "...and never reaches the build" "! grep -q '^dependency build ' '$WORK/https.log'"

echo ""
echo "--- 4. Real helm and kubeconform ---"

# Asked for by name, in a HOME of their own, so what they download is this run's alone.
TOOLS_HOME="$WORK/tools"
mkdir -p "$TOOLS_HOME" || exit 1
REAL_TOOLS=''
if HOME="$TOOLS_HOME" "$HELM_INSTALLER" > "$WORK/tools.log" 2>&1 \
  && HOME="$TOOLS_HOME" "$KUBECONFORM_INSTALLER" >> "$WORK/tools.log" 2>&1; then
  REAL_HELM="$(PATH="$TOOLS_HOME/.local/bin:$PATH" command -v helm)"
  REAL_KUBECONFORM="$(PATH="$TOOLS_HOME/.local/bin:$PATH" command -v kubeconform)"
  REAL_TOOLS='yes'
  echo "  using $("$REAL_HELM" version --short) and kubeconform $("$REAL_KUBECONFORM" -v)"
else
  sed 's/^/        /' "$WORK/tools.log"
  unavailable "helm and kubeconform are neither on PATH at the pin nor downloadable, so sections 4 to 7 cannot run"
fi

# The checker of the JUnit reports: it parses at least as strictly as a conforming XML parser.
REPORTS="$WORK/terraform-reports"
if ! CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
  go -C "$SCRIPTS_DIR" build -trimpath -o "$REPORTS" ./internal/testsuites/terraform-reports; then
  echo -e "${RED}FAIL: could not build the report checker (it needs Go 1.25 or newer)${NC}"
  exit 1
fi

# A HOME whose `~/.local/bin`, which `cleanup.sh` puts first on PATH, holds wrappers that record
# every call and run the real tool.
RUN_HOME="$WORK/run-home"
mkdir -p "$RUN_HOME/.local/bin" || exit 1
cat > "$RUN_HOME/.local/bin/helm" <<'SPY'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$ARGOCD_TEST_LOG"
exec "$ARGOCD_TEST_HELM" "$@"
SPY
cat > "$RUN_HOME/.local/bin/kubeconform" <<'SPY'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$ARGOCD_TEST_LOG"
exec "$ARGOCD_TEST_KUBECONFORM" "$@"
SPY
chmod +x "$RUN_HOME/.local/bin/helm" "$RUN_HOME/.local/bin/kubeconform"

# run_in <repo> <runner> [NAME=value ...]: the runner's output, on a clean slate of environment.
run_in() {
  local repo="$1" runner="$2"
  shift 2
  : > "$WORK/calls.log"
  (
    cd "$repo" || exit 1
    env -u XDG_CONFIG_HOME -u XDG_CACHE_HOME -u XDG_DATA_HOME \
      -u ARGOCD_CHART_ROOTS -u ARGOCD_MANIFEST_DIRS -u ARGOCD_SCHEMA_LOCATIONS -u ARGOCD_KUBERNETES_VERSION \
      HOME="$RUN_HOME" REPORT_PATH='' SCRIPTS_DIR="$SCRIPTS_DIR" \
      ARGOCD_TEST_LOG="$WORK/calls.log" ARGOCD_TEST_HELM="$REAL_HELM" ARGOCD_TEST_KUBECONFORM="$REAL_KUBECONFORM" \
      "$@" "$runner" 2>&1
  )
}

# chart <directory> <name> [<extra Chart.yaml line> ...]
chart() {
  local directory="$1" name="$2" line
  shift 2
  mkdir -p "$directory/templates" || return 1
  printf 'apiVersion: v2\nname: %s\nversion: 0.1.0\n' "$name" > "$directory/Chart.yaml"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$directory/Chart.yaml"
  done
}

# Two alternative shapes of one chart. `flavour` has no default, so it does not render without a
# scenario, `nested` has none either, so it does not lint without one, and the two values cannot
# meet, so it does not render with both.
stack_chart() {
  local directory="$1/charts/example-stack"
  chart "$directory" 'example-stack' || return 1
  cat > "$directory/templates/application.yaml" <<'TEMPLATE'
{{- if and .Values.alpha .Values.beta }}
{{- fail "alpha and beta are alternatives: these scenarios were merged" }}
{{- end }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: example-{{ required "flavour has no default" .Values.flavour }}
spec:
  project: {{ .Values.nested.project }}
  destination:
    server: https://kubernetes.default.svc
TEMPLATE
  mkdir -p "$directory/ci" || return 1
  printf 'flavour: alpha\nalpha: true\nnested:\n  project: default\n' > "$directory/ci/alpha-values.yaml"
  printf 'flavour: beta\nbeta: true\nnested:\n  project: default\n' > "$directory/ci/beta-values.yaml"
}

# A chart with no scenario. What sits in `ci/` here is not one: only `*-values.yaml` is.
defaults_chart() {
  local directory="$1/charts/example-defaults"
  chart "$directory" 'example-defaults' || return 1
  printf 'greeting: hello-from-the-defaults\n' > "$directory/values.yaml"
  cat > "$directory/templates/configmap.yaml" <<'TEMPLATE'
apiVersion: v1
kind: ConfigMap
metadata:
  name: example-defaults
data:
  greeting: {{ .Values.greeting | quote }}
TEMPLATE
  mkdir -p "$directory/ci" || return 1
  printf 'notes about this chart\n' > "$directory/ci/README.md"
}

# A vendored subchart, which fails on its own: only the umbrella gives it its value.
umbrella_chart() {
  local directory="$1/charts/example-umbrella" subchart
  subchart="$directory/charts/example-sub"
  chart "$directory" 'example-umbrella' 'dependencies:' '  - name: example-sub' '    version: 0.1.0' || return 1
  printf 'example-sub:\n  name: named-by-the-umbrella\n' > "$directory/values.yaml"
  chart "$subchart" 'example-sub' || return 1
  cat > "$subchart/templates/configmap.yaml" <<'TEMPLATE'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ required "the umbrella names this" .Values.name }}
TEMPLATE
}

# A library chart and a chart that needs it, with the dependency absent.
library_charts() {
  local library="$1/charts/example-library" consumer="$1/charts/example-consumer"
  chart "$library" 'example-library' 'type: library' || return 1
  printf '{{- define "example.greeting" -}}hello-from-the-library{{- end -}}\n' > "$library/templates/_greeting.tpl"
  chart "$consumer" 'example-consumer' 'dependencies:' '  - name: example-library' '    version: 0.1.0' \
    '    repository: file://../example-library' || return 1
  cat > "$consumer/templates/configmap.yaml" <<'TEMPLATE'
apiVersion: v1
kind: ConfigMap
metadata:
  name: example-consumer
data:
  greeting: {{ include "example.greeting" . | quote }}
TEMPLATE
}

if [ -n "$REAL_TOOLS" ]; then
  GOOD="$WORK/good"
  stack_chart "$GOOD" || exit 1
  defaults_chart "$GOOD" || exit 1
  umbrella_chart "$GOOD" || exit 1
  library_charts "$GOOD" || exit 1
  # Under `.git` nothing is a chart, whatever it looks like.
  chart "$GOOD/.git/modules/example" 'example-git-internals' || exit 1

  # What lint and render both walk, proven once on each.
  LINT_RC=0
  LINT_OUT="$(run_in "$GOOD" "$LINT")" || LINT_RC=$?
  LINT_JUNIT="$GOOD/build/reports/argocd-helm-lint/junit-helm-lint.xml"
  assert_true "lint: good charts pass" "[ $LINT_RC -eq 0 ]"
  assert_true "lint: a chart with scenarios is linted once per scenario" \
    "grep -qxF 'lint charts/example-stack --values charts/example-stack/ci/alpha-values.yaml' '$WORK/calls.log' && grep -qxF 'lint charts/example-stack --values charts/example-stack/ci/beta-values.yaml' '$WORK/calls.log'"
  assert_true "lint: ...and never with its defaults, which cannot work" \
    "! grep -qxF 'lint charts/example-stack' '$WORK/calls.log'"
  assert_true "lint: a chart without scenarios is linted with its defaults" \
    "grep -qxF 'lint charts/example-defaults' '$WORK/calls.log'"
  assert_true "lint: a library chart is linted too" \
    "grep -qxF 'lint charts/example-library' '$WORK/calls.log'"
  assert_true "lint: an absent dependency is built first" \
    "grep -qxF 'dependency build charts/example-consumer' '$WORK/calls.log'"
  assert_true "lint: the report is well-formed" "'$REPORTS' well-formed '$LINT_JUNIT'"
  assert_true "lint: ...and counts every scenario" \
    "'$REPORTS' root '$LINT_JUNIT' testsuites tests=6 failures=0"

  echo ""
  echo "--- 5. test:render ---"

  # What the lint built, gone again: the two jobs run in separate workspaces.
  rm -rf "$GOOD/charts/example-consumer/charts" "$GOOD/charts/example-consumer/Chart.lock"
  RENDER_RC=0
  RENDER_OUT="$(run_in "$GOOD" "$RENDER")" || RENDER_RC=$?
  RENDERED="$GOOD/build/reports/argocd-render/rendered"
  RENDER_JUNIT="$GOOD/build/reports/argocd-render/junit-render.xml"

  assert_true "a good chart passes" "[ $RENDER_RC -eq 0 ]"
  assert_true "the report is well-formed" "'$REPORTS' well-formed '$RENDER_JUNIT'"
  assert_true "...and records no failure" "'$REPORTS' root '$RENDER_JUNIT' testsuites failures=0"
  assert_true "...nor the scenarios of a chart it did not walk" \
    "! grep -qE 'example-sub|example-git-internals' '$RENDER_JUNIT'"

  assert_true "two ci/ scenarios: alpha is rendered from its own file" \
    "grep -q 'name: example-alpha' '$RENDERED/charts/example-stack/alpha.yaml'"
  assert_true "two ci/ scenarios: beta is rendered from its own file" \
    "grep -q 'name: example-beta' '$RENDERED/charts/example-stack/beta.yaml'"
  assert_true "...neither carries the other" \
    "! grep -q 'example-beta' '$RENDERED/charts/example-stack/alpha.yaml' && ! grep -q 'example-alpha' '$RENDERED/charts/example-stack/beta.yaml'"
  assert_true "...each render was handed exactly one values file" \
    "[ \"\$(grep -c '^template charts/example-stack --include-crds --values charts/example-stack/ci/[a-z]*-values.yaml\$' '$WORK/calls.log')\" -eq 2 ]"
  assert_true "...and no render was handed none, as this chart has scenarios" \
    "[ ! -e '$RENDERED/charts/example-stack/default.yaml' ]"
  assert_true "...the report names both" \
    "grep -qF 'charts/example-stack (scenario: alpha)' '$RENDER_JUNIT' && grep -qF 'charts/example-stack (scenario: beta)' '$RENDER_JUNIT'"

  assert_true "a chart without ci/ renders with its defaults" \
    "grep -q 'hello-from-the-defaults' '$RENDERED/charts/example-defaults/default.yaml'"
  assert_true "...with no values file" \
    "grep -qxF 'template charts/example-defaults --include-crds' '$WORK/calls.log'"
  assert_true "...and is named so in the report" \
    "grep -qF 'charts/example-defaults (scenario: default)' '$RENDER_JUNIT'"

  assert_true "a vendored subchart is not a chart of its own" \
    "[ ! -e '$RENDERED/charts/example-umbrella/charts' ] && ! grep -q 'template charts/example-umbrella/charts' '$WORK/calls.log'"
  assert_true "...it renders inside its umbrella" \
    "grep -q 'name: named-by-the-umbrella' '$RENDERED/charts/example-umbrella/default.yaml'"

  assert_true "an absent dependency is built first" \
    "grep -qxF 'dependency build charts/example-consumer' '$WORK/calls.log' && [ -f '$GOOD/charts/example-consumer/charts/example-library-0.1.0.tgz' ]"
  assert_true "...and is rendered with" \
    "grep -q 'hello-from-the-library' '$RENDERED/charts/example-consumer/default.yaml'"
  assert_true "a library chart is not rendered: Helm refuses to" \
    "! grep -q '^template charts/example-library' '$WORK/calls.log' && [ ! -e '$RENDERED/charts/example-library/default.yaml' ]"

  run_in "$GOOD" "$RENDER" > /dev/null
  assert_true "a dependency already there is not built again" \
    "! grep -q '^dependency build' '$WORK/calls.log'"

  ROOTS_RC=0
  ROOTS_OUT="$(run_in "$GOOD" "$RENDER" ARGOCD_CHART_ROOTS='charts/example-stack charts/example-defaults')" || ROOTS_RC=$?
  assert_true "ARGOCD_CHART_ROOTS narrows the search to several roots" \
    "[ $ROOTS_RC -eq 0 ] && [ -f '$RENDERED/charts/example-defaults/default.yaml' ] && [ -f '$RENDERED/charts/example-stack/beta.yaml' ] && [ ! -e '$RENDERED/charts/example-consumer' ]"

  # A value a shell would split, on its way to Helm and back out as a file name.
  mkdir -p "$WORK/spaced" || exit 1
  stack_chart "$WORK/spaced" || exit 1
  mv "$WORK/spaced/charts/example-stack/ci/alpha-values.yaml" "$WORK/spaced/charts/example-stack/ci/two words-values.yaml"
  SPACED_LINT_RC=0
  run_in "$WORK/spaced" "$LINT" > /dev/null || SPACED_LINT_RC=$?
  SPACED_RC=0
  SPACED_OUT="$(run_in "$WORK/spaced" "$RENDER")" || SPACED_RC=$?
  assert_true "a scenario with a space in its name stays one scenario" \
    "[ $SPACED_LINT_RC -eq 0 ] && [ $SPACED_RC -eq 0 ] && [ -s '$WORK/spaced/build/reports/argocd-render/rendered/charts/example-stack/two words.yaml' ]"

  # A chart at the root of the repository, whose `charts/` directory is its subcharts'. The same
  # directory holds standalone charts in every other fixture here, which is the difference.
  ROOT_REPO="$WORK/root-chart"
  mkdir -p "$ROOT_REPO" || exit 1
  chart "$ROOT_REPO" 'example-root' 'dependencies:' '  - name: example-sub' '    version: 0.1.0' || exit 1
  printf 'example-sub:\n  name: named-by-the-root\n' > "$ROOT_REPO/values.yaml"
  chart "$ROOT_REPO/charts/example-sub" 'example-sub' || exit 1
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {{ required "named by the root" .Values.name }}\n' \
    > "$ROOT_REPO/charts/example-sub/templates/configmap.yaml"
  ROOT_RC=0
  ROOT_OUT="$(run_in "$ROOT_REPO" "$RENDER")" || ROOT_RC=$?
  assert_true "a chart at the repository root renders, and its subchart inside it" \
    "[ $ROOT_RC -eq 0 ] && grep -q 'name: named-by-the-root' '$ROOT_REPO/build/reports/argocd-render/rendered/default.yaml'"

  EMPTY_REPO="$WORK/no-charts"
  mkdir -p "$EMPTY_REPO" || exit 1
  EMPTY_RC=0
  EMPTY_OUT="$(run_in "$EMPTY_REPO" "$RENDER")" || EMPTY_RC=$?
  assert_true "a repository with no chart passes, and says so" \
    '[ $EMPTY_RC -eq 0 ] && [[ "$EMPTY_OUT" == *"No chart found"* ]]'
  assert_true "...with a report the publish step can read" \
    "'$REPORTS' root '$EMPTY_REPO/build/reports/argocd-render/junit-render.xml' testsuites tests=0"

  # Everything that must fail, in one repository beside a healthy chart, because a run that stopped
  # at the first failure, or lost one, would look just the same from the exit code.
  BROKEN="$WORK/broken"
  defaults_chart "$BROKEN" || exit 1
  chart "$BROKEN/charts/example-mixed" 'example-mixed' || exit 1
  cat > "$BROKEN/charts/example-mixed/templates/configmap.yaml" <<'TEMPLATE'
{{- if .Values.broken }}
{{- fail "this scenario does not render" }}
{{- end }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: example-mixed
{{- if .Values.unparsable }}
data: [not closed
{{- end }}
TEMPLATE
  mkdir -p "$BROKEN/charts/example-mixed/ci" || exit 1
  printf 'broken: false\n' > "$BROKEN/charts/example-mixed/ci/healthy-values.yaml"
  printf 'broken: true\n' > "$BROKEN/charts/example-mixed/ci/broken-values.yaml"
  printf 'unparsable: true\n' > "$BROKEN/charts/example-mixed/ci/unparsable-values.yaml"
  chart "$BROKEN/charts/example-required" 'example-required' || exit 1
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {{ required "no default" .Values.name }}\n' \
    > "$BROKEN/charts/example-required/templates/configmap.yaml"
  chart "$BROKEN/charts/example-orphan" 'example-orphan' 'dependencies:' '  - name: example-gone' \
    '    version: 0.1.0' '    repository: file://../example-gone' || exit 1

  FAILED_RC=0
  FAILED_OUT="$(run_in "$BROKEN" "$RENDER")" || FAILED_RC=$?
  FAILED_RENDERED="$BROKEN/build/reports/argocd-render/rendered"
  FAILED_JUNIT="$BROKEN/build/reports/argocd-render/junit-render.xml"
  assert_true "a failing scenario fails the job" "[ $FAILED_RC -ne 0 ]"
  assert_true "...and is named, chart and scenario" \
    '[[ "$FAILED_OUT" == *"FAILED: charts/example-mixed (scenario: broken)"* ]]'
  assert_true "...with Helm's own reason in the log" '[[ "$FAILED_OUT" == *"this scenario does not render"* ]]'
  assert_true "...the scenario beside it is not blamed" \
    '[[ "$FAILED_OUT" != *"FAILED: charts/example-mixed (scenario: healthy)"* ]]'
  assert_true "...and still rendered" "[ -s '$FAILED_RENDERED/charts/example-mixed/healthy.yaml' ]"
  assert_true "...the failure leaves no manifest for test:schema to read" \
    "[ ! -e '$FAILED_RENDERED/charts/example-mixed/broken.yaml' ]"
  assert_true "...the charts after it were still walked" \
    "[ -s '$FAILED_RENDERED/charts/example-defaults/default.yaml' ]"
  assert_true "...the report is well-formed" "'$REPORTS' well-formed '$FAILED_JUNIT'"
  assert_true "...and carries all four failures, the reason included" \
    "'$REPORTS' root '$FAILED_JUNIT' testsuites failures=4 && grep -q 'this scenario does not render' '$FAILED_JUNIT'"
  assert_true "a scenario that renders no YAML fails, named" \
    '[[ "$FAILED_OUT" == *"FAILED: charts/example-mixed (scenario: unparsable)"* ]]'
  assert_true "a chart without ci/ that needs values fails, scenario default" \
    '[[ "$FAILED_OUT" == *"FAILED: charts/example-required (scenario: default)"* ]]'
  assert_true "a dependency that cannot be built fails, named" \
    '[[ "$FAILED_OUT" == *"FAILED: charts/example-orphan (dependencies)"* ]]'

  LINT_FAILED_RC=0
  LINT_FAILED_OUT="$(run_in "$BROKEN" "$LINT")" || LINT_FAILED_RC=$?
  LINT_FAILED_JUNIT="$BROKEN/build/reports/argocd-helm-lint/junit-helm-lint.xml"
  assert_true "lint: a failing scenario fails the job, named" \
    '[ $LINT_FAILED_RC -ne 0 ] && [[ "$LINT_FAILED_OUT" == *"FAILED: charts/example-mixed (scenario: unparsable)"* ]]'
  assert_true "lint: ...the scenario beside it is not blamed" \
    '[[ "$LINT_FAILED_OUT" != *"FAILED: charts/example-mixed (scenario: healthy)"* ]]'
  assert_true "lint: a dependency that cannot be built fails, named" \
    '[[ "$LINT_FAILED_OUT" == *"FAILED: charts/example-orphan (dependencies)"* ]]'
  assert_true "lint: ...in a well-formed report" "'$REPORTS' root '$LINT_FAILED_JUNIT' testsuites failures=2"
  # `helm lint` lets `required` and `fail` through by design, so these two are the render's alone.
  assert_true "lint: what only a render can see stays the render's to fail" \
    '[[ "$LINT_FAILED_OUT" == *"charts/example-mixed (scenario: broken) ... ok"* ]] && [[ "$LINT_FAILED_OUT" == *"charts/example-required (scenario: default) ... ok"* ]]'

  MISSPELT_RC=0
  MISSPELT_OUT="$(run_in "$GOOD" "$RENDER" ARGOCD_CHART_ROOTS='charts/example-stack charts/example-typo')" || MISSPELT_RC=$?
  assert_true "a chart root that does not exist fails rather than finding nothing" \
    '[ $MISSPELT_RC -ne 0 ] && [[ "$MISSPELT_OUT" == *"charts/example-typo"* ]]'
  MISSPELT_LINT_RC=0
  MISSPELT_LINT_OUT="$(run_in "$GOOD" "$LINT" ARGOCD_CHART_ROOTS='charts/example-typo')" || MISSPELT_LINT_RC=$?
  assert_true "lint: ...and the same for the lint" "[ $MISSPELT_LINT_RC -ne 0 ]"

  # A scenario named by whoever wrote the chart, in a report something has to parse.
  HOSTILE="$WORK/hostile"
  defaults_chart "$HOSTILE" || exit 1
  printf 'greeting: 1\n' > "$HOSTILE/charts/example-defaults/ci/a&b<c-values.yaml"
  printf '{{ fail "a ]]> in a diagnostic" }}\n' > "$HOSTILE/charts/example-defaults/templates/broken.yaml"
  HOSTILE_RC=0
  HOSTILE_OUT="$(run_in "$HOSTILE" "$RENDER")" || HOSTILE_RC=$?
  assert_true "XML metacharacters in a scenario and a diagnostic cannot break the report" \
    "[ $HOSTILE_RC -ne 0 ] && '$REPORTS' well-formed '$HOSTILE/build/reports/argocd-render/junit-render.xml'"

  echo ""
  echo "--- 6. test:schema ---"

  # The smallest schemas that can tell a valid resource from an invalid one, laid out the way the
  # two pinned repositories lay theirs out, so these locations have the shape of the real ones.
  SCHEMAS="$WORK/schemas"
  mkdir -p "$SCHEMAS/master-standalone-strict" "$SCHEMAS/argoproj.io" || exit 1
  cat > "$SCHEMAS/master-standalone-strict/configmap-v1.json" <<'JSON'
{"type": "object", "additionalProperties": false, "required": ["apiVersion", "kind", "metadata"],
 "properties": {"apiVersion": {}, "kind": {}, "metadata": {"type": "object"},
                "data": {"type": "object", "additionalProperties": {"type": "string"}}}}
JSON
  cat > "$SCHEMAS/argoproj.io/application_v1alpha1.json" <<'JSON'
{"type": "object", "required": ["spec"],
 "properties": {"spec": {"type": "object", "additionalProperties": false, "required": ["project"],
                         "properties": {"project": {"type": "string"}, "destination": {"type": "object"}}}}}
JSON
  for kind in applicationset appproject; do
    printf '{"type": "object", "required": ["spec"]}\n' > "$SCHEMAS/argoproj.io/${kind}_v1alpha1.json"
  done
  LOCATIONS="$SCHEMAS/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
  LOCATIONS="$LOCATIONS $SCHEMAS/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

  # A rendered chart and a directory of plain manifests. The custom resource has no schema
  # anywhere, which is not a failure: no catalog holds them all.
  VALID="$WORK/valid"
  stack_chart "$VALID" || exit 1
  mkdir -p "$VALID/bootstrap" || exit 1
  cat > "$VALID/bootstrap/root.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: example-root
spec:
  project: default
---
apiVersion: example.invalid/v1
kind: ExampleWidget
metadata:
  name: example-widget
YAML

  run_in "$VALID" "$RENDER" > /dev/null
  VALID_RC=0
  VALID_OUT="$(run_in "$VALID" "$SCHEMA" ARGOCD_MANIFEST_DIRS='bootstrap' ARGOCD_SCHEMA_LOCATIONS="$LOCATIONS")" || VALID_RC=$?
  VALID_JUNIT="$VALID/build/reports/argocd-schema/junit-schema.xml"
  assert_true "valid manifests pass" "[ $VALID_RC -eq 0 ]"
  assert_true "...rendered and plain alike, the custom resource skipped" \
    '[[ "$VALID_OUT" == *"3 resources found"* || "$VALID_OUT" == *"Valid: 3,"* ]] && [[ "$VALID_OUT" == *"Skipped: 1"* ]]'
  assert_true "...read through the render's directory and the configured one" \
    "grep -F -- '-ignore-missing-schemas -summary build/reports/argocd-render/rendered bootstrap' '$WORK/calls.log' | grep -q -- '-strict'"
  assert_true "...the report is well-formed" "'$REPORTS' well-formed '$VALID_JUNIT'"
  assert_true "...and records no failure" "'$REPORTS' root '$VALID_JUNIT' testsuites failures=0"
  assert_true "the render's output survives the schema run" \
    "[ -f '$VALID/build/reports/argocd-render/rendered/charts/example-stack/alpha.yaml' ]"

  # Each of these is valid until the one line that breaks it, in a fresh copy of the fixture.
  fixture_copy() {
    rm -rf "$WORK/copy"
    cp -R "$VALID" "$WORK/copy"
  }

  # A template that renders and is still nothing a cluster would accept: the case this tier is for.
  fixture_copy
  sed -i 's/^  project: /  projectt: /' "$WORK/copy/charts/example-stack/templates/application.yaml"
  run_in "$WORK/copy" "$RENDER" > /dev/null
  RENDER_INVALID_RC=$?
  INVALID_RC=0
  INVALID_OUT="$(run_in "$WORK/copy" "$SCHEMA" ARGOCD_SCHEMA_LOCATIONS="$LOCATIONS")" || INVALID_RC=$?
  INVALID_JUNIT="$WORK/copy/build/reports/argocd-schema/junit-schema.xml"
  assert_true "an invalid rendered manifest renders" "[ $RENDER_INVALID_RC -eq 0 ]"
  assert_true "...and fails test:schema" "[ $INVALID_RC -ne 0 ]"
  assert_true "...naming the chart, the scenario and the resource" \
    '[[ "$INVALID_OUT" == *"charts/example-stack/alpha.yaml - Application example-alpha is invalid"* ]]'
  assert_true "...in the report too, which stays well-formed" \
    "'$REPORTS' well-formed '$INVALID_JUNIT' && grep -q 'charts/example-stack/alpha.yaml' '$INVALID_JUNIT'"
  assert_true "...and counts the failures" "'$REPORTS' root '$INVALID_JUNIT' testsuites failures=2"

  fixture_copy
  sed -i 's/^  project: default$/  destination: {}/' "$WORK/copy/bootstrap/root.yaml"
  run_in "$WORK/copy" "$RENDER" > /dev/null
  INVALID_RC=0
  INVALID_OUT="$(run_in "$WORK/copy" "$SCHEMA" ARGOCD_MANIFEST_DIRS='bootstrap' ARGOCD_SCHEMA_LOCATIONS="$LOCATIONS")" || INVALID_RC=$?
  assert_true "an invalid plain manifest fails test:schema, naming the file" \
    '[ $INVALID_RC -ne 0 ] && [[ "$INVALID_OUT" == *"bootstrap/root.yaml - Application example-root is invalid"* ]]'
  UNCONFIGURED_RC=0
  UNCONFIGURED_OUT="$(run_in "$WORK/copy" "$SCHEMA" ARGOCD_SCHEMA_LOCATIONS="$LOCATIONS")" || UNCONFIGURED_RC=$?
  assert_true "...and only ARGOCD_MANIFEST_DIRS brings it in" "[ $UNCONFIGURED_RC -eq 0 ]"

  # A key given twice is valid YAML to most readers, and one of the two values is lost to it.
  fixture_copy
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\ndata:\n  a: "1"\ndata:\n  b: "2"\n' \
    > "$WORK/copy/bootstrap/duplicate.yaml"
  rm -f "$WORK/copy/bootstrap/root.yaml"
  run_in "$WORK/copy" "$RENDER" > /dev/null
  INVALID_RC=0
  INVALID_OUT="$(run_in "$WORK/copy" "$SCHEMA" ARGOCD_MANIFEST_DIRS='bootstrap' ARGOCD_SCHEMA_LOCATIONS="$LOCATIONS")" || INVALID_RC=$?
  assert_true "strict mode reaches kubeconform: a duplicate key fails" "[ $INVALID_RC -ne 0 ]"
  assert_true "...it is asked for by name" "grep -q -- '^-strict ' '$WORK/calls.log'"

  # The way this tier goes quiet: skipping is on, so a location that resolves nothing reads as
  # "no schema" for everything. The first command proves it would pass, the second that it does not.
  NOTHING="$WORK/nothing/{{.ResourceKind}}.json"
  fixture_copy
  run_in "$WORK/copy" "$RENDER" > /dev/null
  QUIET_RC=0
  (
    cd "$WORK/copy" || exit 1
    "$REAL_KUBECONFORM" -strict -ignore-missing-schemas -schema-location "$NOTHING" build/reports/argocd-render/rendered
  ) > /dev/null 2>&1 || QUIET_RC=$?
  assert_true "a location that resolves nothing passes kubeconform alone" "[ $QUIET_RC -eq 0 ]"
  RESOLVES_RC=0
  RESOLVES_OUT="$(run_in "$WORK/copy" "$SCHEMA" ARGOCD_SCHEMA_LOCATIONS="$NOTHING")" || RESOLVES_RC=$?
  assert_true "...and fails test:schema, saying why" \
    '[ $RESOLVES_RC -ne 0 ] && [[ "$RESOLVES_OUT" == *"cannot validate the kinds this check exists for"* ]]'
  # Only the core kinds' directory is versioned, so only they would have gone quiet here.
  VERSION_RC=0
  VERSION_OUT="$(run_in "$WORK/copy" "$SCHEMA" ARGOCD_SCHEMA_LOCATIONS="$LOCATIONS" ARGOCD_KUBERNETES_VERSION='9.99.0')" || VERSION_RC=$?
  assert_true "a Kubernetes version the schemas do not hold fails too" \
    '[ $VERSION_RC -ne 0 ] && [[ "$VERSION_OUT" == *"Kubernetes version: 9.99.0"* ]]'

  MISSING_RC=0
  MISSING_OUT="$(run_in "$VALID" "$SCHEMA" ARGOCD_MANIFEST_DIRS='bootstrap bootstrapp' ARGOCD_SCHEMA_LOCATIONS="$LOCATIONS")" || MISSING_RC=$?
  assert_true "a manifest directory that does not exist fails, named" \
    '[ $MISSING_RC -ne 0 ] && [[ "$MISSING_OUT" == *"the manifest directory '"'"'bootstrapp'"'"' does not exist"* ]]'

  NO_RENDER="$WORK/no-render"
  mkdir -p "$NO_RENDER" || exit 1
  NO_RENDER_RC=0
  NO_RENDER_OUT="$(run_in "$NO_RENDER" "$SCHEMA" ARGOCD_SCHEMA_LOCATIONS="$LOCATIONS")" || NO_RENDER_RC=$?
  assert_true "with nothing rendered and nothing configured, it fails rather than pass empty" \
    '[ $NO_RENDER_RC -ne 0 ] && [[ "$NO_RENDER_OUT" == *"nothing to validate"* ]]'

  mkdir -p "$NO_RENDER/bootstrap" || exit 1
  cp "$VALID/bootstrap/root.yaml" "$NO_RENDER/bootstrap/root.yaml"
  PLAIN_RC=0
  PLAIN_OUT="$(run_in "$NO_RENDER" "$SCHEMA" ARGOCD_MANIFEST_DIRS='bootstrap' ARGOCD_SCHEMA_LOCATIONS="$LOCATIONS")" || PLAIN_RC=$?
  assert_true "a repository of plain manifests needs no chart" "[ $PLAIN_RC -eq 0 ]"

  echo ""
  echo "--- 7. The two pinned schema commits ---"

  # Every location above is a fixture, so nothing yet proves that the pinned commits serve Argo
  # CD's three kinds, or that they are strict about them. A pin moved to a commit that renamed a
  # file passes everything else here. The probe asks for the host and not for a pinned file, which
  # would read a bad pin as a network that is down.
  if curl -sS --max-time 30 -o /dev/null 'https://raw.githubusercontent.com/'; then
    PINNED="$WORK/pinned"
    mkdir -p "$PINNED/bootstrap" || exit 1
    cat > "$PINNED/bootstrap/valid.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: example-app
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: example
  source:
    repoURL: https://example.invalid/charts.git
    targetRevision: HEAD
    path: charts/example-stack
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: example-set
spec:
  generators:
    - list:
        elements:
          - name: example
  template:
    metadata:
      name: 'example-{{name}}'
    spec:
      project: default
      destination:
        server: https://kubernetes.default.svc
        namespace: example
      source:
        repoURL: https://example.invalid/charts.git
        targetRevision: HEAD
        path: charts/example-stack
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: example-project
spec:
  sourceRepos:
    - '*'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: example-deployment
spec:
  selector:
    matchLabels:
      app: example
  template:
    metadata:
      labels:
        app: example
    spec:
      containers:
        - name: example
          image: example.invalid/example:1.0.0
YAML
    PINNED_RC=0
    PINNED_OUT="$(run_in "$PINNED" "$SCHEMA" ARGOCD_MANIFEST_DIRS='bootstrap')" || PINNED_RC=$?
    assert_true "the pinned commits accept a valid Application, ApplicationSet, AppProject and Deployment" \
      '[ $PINNED_RC -eq 0 ] && [[ "$PINNED_OUT" == *"Valid: 4, Invalid: 0, Errors: 0, Skipped: 0"* ]]'
    assert_true "...with both locations named by commit" \
      "grep -q 'kubernetes-json-schema/[0-9a-f]\{40\}/' '$WORK/calls.log' && grep -q 'CRDs-catalog/[0-9a-f]\{40\}/' '$WORK/calls.log'"

    for spec in 'destination:|destinationn:|Application example-app' \
                'generators:|generatorss:|ApplicationSet example-set' \
                'sourceRepos:|sourceReposs:|AppProject example-project' \
                'selector:|selectorr:|Deployment example-deployment'; do
      IFS='|' read -r spec_from spec_to spec_resource <<< "$spec"
      rm -rf "$WORK/typo"
      cp -R "$PINNED" "$WORK/typo"
      sed -i "0,/^  $spec_from/s//  $spec_to/" "$WORK/typo/bootstrap/valid.yaml"
      TYPO_RC=0
      TYPO_OUT="$(run_in "$WORK/typo" "$SCHEMA" ARGOCD_MANIFEST_DIRS='bootstrap')" || TYPO_RC=$?
      assert_true "a misspelt field fails the pinned schema of: $spec_resource" \
        '[ $TYPO_RC -ne 0 ] && [[ "$TYPO_OUT" == *"$spec_resource is invalid"* ]]'
    done
  else
    unavailable "raw.githubusercontent.com is out of reach, so the two pinned commits cannot be asked"
  fi
fi

echo ""
echo "=========================================="
echo -e "Passed:  ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:  ${RED}$TESTS_FAILED${NC}"
[[ $TESTS_SKIPPED -gt 0 ]] && echo -e "Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}Argo CD pipeline validation FAILED${NC}"
  exit 1
fi
echo -e "${GREEN}Argo CD pipeline validation passed${NC}"
exit 0
