#!/usr/bin/env bash
set -e

# Regression test for the version a build hands its image as a Dockerfile `ARG`
# (`global/scripts/shared/build-version.sh`), and for the two builds that pass it:
# the GitHub image delivery (`github/global/stages/40-delivery/docker`) and the
# Fly.io deploy (`global/scripts/deploy/flyio/run.sh`, all three platforms).
#
# Why it exists: a Dockerfile that compiles its version in -- `ARG VERSION=dev`,
# then `-ldflags "-X <package>.Version=${VERSION}"` -- reports its DEFAULT unless
# the build passes the argument, and no build here passed it. Every image said
# `dev`, so a startup log, a version endpoint and an error tracker's `release`
# carried the same word for every deploy. Nothing failed while that was true,
# which is why each part of the contract is pinned here rather than trusted:
#
#   - the value must be the SAME string wherever one commit is built. The image
#     delivery and Fly's builder each build the commit, and two spellings of it
#     file one release under two names -- so both resolve through one helper, and
#     the agreement is asserted by running both rather than by reading them;
#   - opting in is NAMING the `ARG`, and the default names nothing: a build
#     argument chosen by this repository would override a project's unrelated
#     `ARG VERSION`;
#   - a malformed name or value is refused before anything is built, because
#     nothing downstream refuses it -- a build argument no `ARG` declares is
#     ignored, and a newline in the value would reach `build-args` (a
#     NEWLINE-separated list) as a second argument.
#
# The delivery action's step is EXTRACTED AND EXECUTED, not grepped: a copy of
# its logic living here would keep passing after the action's own copy changed.
# The Fly.io cases that only concern Fly.io live with the other providers, in
# test-deploy-providers.sh.
#
# Since `go-flyio.yaml` deploys the image the delivery job pushed, a commit is
# built ONCE on that path, and the version reaches the deploy inside the image.
# So this suite also holds that image's way from the build to the deploy: the
# digest the build reports, the name it is pushed under, and each output that
# carries it on, down to the deploy step -- which, handed an image, passes no
# version of its own.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPTS_DIR

HELPER="$SCRIPTS_DIR/global/scripts/shared/build-version.sh"
DOCKER_ACTION="$SCRIPTS_DIR/github/global/stages/40-delivery/docker/action.yaml"
FLYIO_SH="$SCRIPTS_DIR/global/scripts/deploy/flyio/run.sh"
GO_DOCKER="$SCRIPTS_DIR/.github/workflows/go-docker.yaml"
GO_FLYIO="$SCRIPTS_DIR/.github/workflows/go-flyio.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
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

WORK_DIR="$(mktemp -d)" || exit 1
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Every case runs from here, with GIT_CEILING_DIRECTORIES stopping `git` at
# WORK_DIR, so the helper's last resort (`git rev-parse HEAD`) finds nothing
# unless a case builds a repository on purpose -- rather than finding whichever
# checkout the suite happens to be run from.
mkdir -p "$WORK_DIR/not-a-repo"

SHA='0123456789abcdef0123456789abcdef01234567'

# resolve [VAR=value...] [-- explicit]
#
# Runs `build_version` under POSIX sh in an otherwise EMPTY environment -- this
# suite runs inside GitHub Actions, where GITHUB_SHA and friends are always set,
# and a case that inherited them would assert the CI run's own commit. Leaves
# stdout in RESOLVED and the status in RC.
resolve() {
  local assignments=()
  local explicit=''
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == '--' ]]; then
      explicit="${2:-}"
      break
    fi
    assignments+=("$1")
    shift
  done

  RC=0
  RESOLVED="$(
    cd "$WORK_DIR/not-a-repo" || exit 1
    env -i PATH="$PATH" HOME="$HOME" GIT_CEILING_DIRECTORIES="$WORK_DIR" "${assignments[@]}" \
      sh -c '. "$1" && build_version "$2"' _ "$HELPER" "$explicit"
  )" || RC=$?
}

echo "Testing the build version handed to images..."
echo ""

# ---------------------------------------------------------------------------
echo "1. The helper: which version a build carries"
# ---------------------------------------------------------------------------
# Sourced, never executed, like every helper beside it -- and asserted first, so
# the refusals below cannot pass merely because there is no helper to refuse.
assert_true "the shared helper exists, without an executable bit" "[[ -f '$HELPER' && ! -x '$HELPER' ]]"

resolve GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main GITHUB_SHA="$SHA"
assert_equals "a GitHub branch build carries the commit's first 7 characters" "0123456" "$RESOLVED"
resolve GITHUB_REF_TYPE=tag GITHUB_REF_NAME=1.2.3 GITHUB_SHA="$SHA"
assert_equals "a GitHub tag build carries the tag" "1.2.3" "$RESOLVED"
resolve GITHUB_REF_TYPE=tag GITHUB_REF_NAME=1.2.3 GITHUB_SHA="$SHA" -- 2.0.0
assert_equals "an explicit version wins over the tag" "2.0.0" "$RESOLVED"

resolve CI_COMMIT_TAG=3.0.0 CI_COMMIT_SHA="$SHA"
assert_equals "a GitLab tag pipeline carries the tag" "3.0.0" "$RESOLVED"
resolve CI_COMMIT_SHA="$SHA"
assert_equals "a GitLab branch pipeline carries the commit" "0123456" "$RESOLVED"

# Only the `refs/tags/` prefix goes, so the tag reads as the other two platforms
# report it; Azure's `Build.SourceBranchName` would have kept only `4.0.0`.
resolve BUILD_SOURCEBRANCH=refs/tags/release/4.0.0 BUILD_SOURCEVERSION="$SHA"
assert_equals "an Azure DevOps tag build carries the whole tag" "release/4.0.0" "$RESOLVED"
resolve BUILD_SOURCEBRANCH=refs/heads/main BUILD_SOURCEVERSION="$SHA"
assert_equals "an Azure DevOps branch build carries the commit" "0123456" "$RESOLVED"
resolve BUILD_SOURCEBRANCH=refs/tags/ BUILD_SOURCEVERSION="$SHA"
assert_equals "an empty Azure DevOps tag name falls back to the commit" "0123456" "$RESOLVED"

# A fixed 7, never `git rev-parse --short`, whose length grows with the clone's
# object count -- a shallow CI clone and a full one would disagree.
assert_true "the commit is cut to exactly 7 characters" "[[ \${#RESOLVED} -eq 7 ]]"

# The last resort is the checkout itself. Signing is switched off for the
# fixture's commit: a global `commit.gpgsign = true` whose signer needs an
# unlocked agent would otherwise fail the suite on a workstation and nowhere else.
GIT_FIXTURE="$WORK_DIR/a-repo"
mkdir -p "$GIT_FIXTURE"
git -C "$GIT_FIXTURE" init --quiet || exit 1
git -C "$GIT_FIXTURE" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
  commit --quiet --allow-empty --no-verify -m fixture || exit 1
FIXTURE_HEAD="$(git -C "$GIT_FIXTURE" rev-parse HEAD)"
RC=0
RESOLVED="$(
  cd "$GIT_FIXTURE" || exit 1
  env -i PATH="$PATH" HOME="$HOME" GIT_CEILING_DIRECTORIES="$WORK_DIR" \
    sh -c '. "$1" && build_version' _ "$HELPER"
)" || RC=$?
assert_equals "outside CI, the checkout's HEAD is used" "${FIXTURE_HEAD:0:7}" "$RESOLVED"

resolve
assert_true "with nothing to read, the helper fails" "[[ $RC -ne 0 ]]"
assert_equals "...and prints nothing" "" "$RESOLVED"

# Refused rather than printed: `build-args` is a NEWLINE-separated list, so a
# newline inside the value would add a build argument of the caller's choosing.
resolve -- "$(printf '1.0\nOTHER=1')"
assert_true "a version holding a newline is refused" "[[ $RC -ne 0 && -z '$RESOLVED' ]]"
resolve -- '1.0 beta'
assert_true "a version holding a space is refused" "[[ $RC -ne 0 ]]"
resolve -- "$(printf '1.0\tbeta')"
assert_true "a version holding a tab is refused" "[[ $RC -ne 0 ]]"
resolve -- "$(printf '1.0\001')"
assert_true "a version holding a control character is refused" "[[ $RC -ne 0 ]]"
echo ""

# ---------------------------------------------------------------------------
echo "2. The helper: build argument names and declarations"
# ---------------------------------------------------------------------------
name_is_valid() {
  sh -c '. "$1" && build_arg_name_is_valid "$2"' _ "$HELPER" "$1"
}
for name in VERSION APP_VERSION _VERSION V1; do
  assert_true "'$name' is a valid build argument name" "name_is_valid '$name'"
done
for name in '' 'VERSION ' ' VERSION' 9VERSION APP-VERSION APP.VERSION 'VERSION=1'; do
  assert_true "'$name' is refused as a build argument name" "! name_is_valid '$name'"
done

DOCKERFILE_FIXTURE="$WORK_DIR/Dockerfile.fixture"
is_declared() {
  printf '%b\n' "$1" > "$DOCKERFILE_FIXTURE"
  sh -c '. "$1" && build_arg_is_declared "$2" VERSION' _ "$HELPER" "$DOCKERFILE_FIXTURE"
}
assert_true "'ARG VERSION' declares it" "is_declared 'FROM scratch\nARG VERSION'"
assert_true "'ARG VERSION=dev' declares it" "is_declared 'FROM scratch\nARG VERSION=dev'"
assert_true "an indented, lower-case 'arg' declares it, as Docker reads it" \
  "is_declared 'FROM scratch\n  arg VERSION=dev'"
assert_true "a second name on one ARG instruction declares it" \
  "is_declared 'FROM scratch\nARG TARGETOS=linux VERSION=dev'"
assert_true "'ARG VERSIONS' does not declare it" "! is_declared 'FROM scratch\nARG VERSIONS=1'"
assert_true "'ARG APP_VERSION' does not declare it" "! is_declared 'FROM scratch\nARG APP_VERSION=1'"
assert_true "'ARG version' does not declare it: the name is case-sensitive" \
  "! is_declared 'FROM scratch\nARG version=1'"
assert_true "a commented-out ARG does not declare it" "! is_declared 'FROM scratch\n# ARG VERSION=dev'"
assert_true "an ENV of the same name does not declare it" "! is_declared 'FROM scratch\nENV VERSION=1'"
echo ""

# ---------------------------------------------------------------------------
echo "3. The image delivery action: shape"
# ---------------------------------------------------------------------------
# PyYAML rather than reading the indented text, for the reason the sibling
# suites give: the step bodies are block scalars, and re-deriving their
# indentation by hand is a parser. A host without PyYAML gets the siblings'
# degradation -- every query answers with the reason, so the assertions below
# fail by name and the suite still reaches its summary.
#
# yaml_query <file> <python expression>
#
# Evaluates the expression with `doc` (the parsed file), `trigger` (its `on:`
# block, which PyYAML reads as the key True) and `step(steps, fragment)` (the
# first step whose `id` equals, or whose `uses` contains, the fragment), and
# prints the result. A failed lookup prints its error instead of raising, so a
# missing key is a FAIL line rather than a crash under `set -e`.
yaml_query() {
  python3 - "$1" "$2" <<'PY'
import sys

try:
    import yaml
except ImportError:
    print('PyYAML is required for this assertion '
          '(CI installs python3-yaml; locally: pip install pyyaml)')
    raise SystemExit(0)

with open(sys.argv[1], encoding='utf-8') as handle:
    doc = yaml.safe_load(handle)


def step(steps, fragment):
    for candidate in steps or []:
        if candidate.get('id') == fragment or fragment in str(candidate.get('uses', '')):
            return candidate
    raise LookupError(f'no step matches {fragment!r}')


trigger = doc.get('on', doc.get(True)) if isinstance(doc, dict) else None
try:
    value = eval(sys.argv[2], {'doc': doc, 'trigger': trigger, 'step': step})
except Exception as error:  # noqa: BLE001 -- reported, never raised
    value = f'<{type(error).__name__}: {error}>'
print('' if value is None else value)
PY
}

assert_equals "the action declares version_build_arg" \
  "string" "$(yaml_query "$DOCKER_ACTION" "doc['inputs']['version_build_arg']['type']")"
assert_equals "...as optional" \
  "False" "$(yaml_query "$DOCKER_ACTION" "doc['inputs']['version_build_arg']['required']")"
assert_equals "...naming nothing by default, so no consumer is opted in unasked" \
  "" "$(yaml_query "$DOCKER_ACTION" "doc['inputs']['version_build_arg']['default']")"

GATE="inputs.version_build_arg != ''"
assert_equals "the scripts are fetched only for a caller that opts in" \
  "$GATE" "$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'abstracts/scripts-repo@')['if']")"
assert_equals "the version is resolved only for a caller that opts in" \
  "$GATE" "$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'version')['if']")"
assert_equals "the resolved build argument reaches the build" \
  '${{ steps.version.outputs.build_args }}' \
  "$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'docker/build-push-action@')['with']['build-args']")"
# The step checks the Dockerfile the build actually builds, or its warning is
# about a different file.
assert_equals "the declaration check reads the Dockerfile the build builds" \
  "$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'docker/build-push-action@')['with']['file']")" \
  "$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'version')['env']['DOCKERFILE']")"
# Resolved before the login and the builder setup, so a refusal costs nothing.
assert_equals "the version is resolved before the registry login" "True" \
  "$(yaml_query "$DOCKER_ACTION" "[s.get('id') for s in doc['runs']['steps']].index('version') < [i for i, s in enumerate(doc['runs']['steps']) if 'docker/login-action@' in str(s.get('uses'))][0]")"
# An input interpolated into a `run:` body is pasted in before bash parses it.
assert_equals "no input is interpolated into the version step's script" "False" \
  "$(yaml_query "$DOCKER_ACTION" "'\${{' in step(doc['runs']['steps'], 'version')['run']")"

# The image the action pushed, named by the digest the build itself reported --
# the reference the Fly.io deploy ships, version and all.
assert_equals "the action outputs the image its own step names" '${{ steps.image.outputs.image }}' \
  "$(yaml_query "$DOCKER_ACTION" "doc['outputs']['image']['value']")"
assert_equals "the build step is the one with the 'build' id" "build" \
  "$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'docker/build-push-action@')['id']")"
assert_equals "the image is named by the digest that build reports" '${{ steps.build.outputs.digest }}' \
  "$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'image')['env']['DIGEST']")"
assert_equals "the image is named after the push" "True" \
  "$(yaml_query "$DOCKER_ACTION" "[s.get('id') for s in doc['runs']['steps']].index('image') > [s.get('id') for s in doc['runs']['steps']].index('build')")"
# Spelled as both tagging steps spell the name the build pushes, or the output
# names an image nobody pushed. A caller's own `tags` choose another name, which
# this action does not know, so it names nothing then.
assert_equals "the image name is the one the release tags are pushed under" \
  "$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'release-tags')['env']['IMAGE']")" \
  "$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'image')['env']['IMAGE']")"
assert_equals "...and the one docker/metadata-action tags" \
  "$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'meta')['with']['images']")" \
  "$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'image')['env']['IMAGE']")"
assert_equals "the image is named only when the action chose the tags" "inputs.tags == ''" \
  "$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'image')['if']")"
assert_equals "no input is interpolated into the image step's script" "False" \
  "$(yaml_query "$DOCKER_ACTION" "'\${{' in step(doc['runs']['steps'], 'image')['run']")"
echo ""

# ---------------------------------------------------------------------------
echo "4. The image delivery action: the step, executed"
# ---------------------------------------------------------------------------
yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'version')['run']" > "$WORK_DIR/version-step.sh"
STEP_DOCKERFILE="$(yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'version')['env']['DOCKERFILE']")"
DOCKER_PROJECT="$WORK_DIR/docker-project"
mkdir -p "$DOCKER_PROJECT/$(dirname "$STEP_DOCKERFILE")"

# run_version_step [VAR=value...]
#
# Runs the action's real step the way the runner does (`bash -eo pipefail`, in
# the checkout), with VERSION_BUILD_ARG=VERSION unless a case overrides it.
# Leaves its output in STEP_OUT, the GITHUB_OUTPUT it wrote in STEP_OUTPUT and
# its status in STEP_RC. GITHUB_OUTPUT is EMPTIED first, so a step that writes
# nothing cannot pass against what the previous case left behind.
run_version_step() {
  : > "$WORK_DIR/github_output"
  STEP_RC=0
  # shellcheck disable=SC2034  # read by assert_true's eval'd conditions, which ShellCheck cannot see
  STEP_OUT="$(
    cd "$DOCKER_PROJECT" || exit 1
    env -i PATH="$PATH" HOME="$HOME" GIT_CEILING_DIRECTORIES="$WORK_DIR" \
      SCRIPTS_DIR="$SCRIPTS_DIR" GITHUB_OUTPUT="$WORK_DIR/github_output" \
      DOCKERFILE="$STEP_DOCKERFILE" VERSION_BUILD_ARG=VERSION TAG_NAME='' "$@" \
      bash --noprofile --norc -eo pipefail "$WORK_DIR/version-step.sh" 2>&1
  )" || STEP_RC=$?
  STEP_OUTPUT="$(cat "$WORK_DIR/github_output")"
}

printf 'FROM scratch\nARG VERSION=dev\n' > "$DOCKER_PROJECT/$STEP_DOCKERFILE"
run_version_step GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main GITHUB_SHA="$SHA"
assert_equals "a branch build hands the image the commit" "build_args=VERSION=0123456" "$STEP_OUTPUT"
assert_true "...without a warning, since the Dockerfile declares the ARG" \
  "! grep -q '::warning::' <<< \"\$STEP_OUT\""
run_version_step GITHUB_REF_TYPE=tag GITHUB_REF_NAME=1.2.3 GITHUB_SHA="$SHA"
assert_equals "a tag build hands the image the tag" "build_args=VERSION=1.2.3" "$STEP_OUTPUT"
# `tag_name` is the release the release job has just cut on the branch, before
# any tag build of it exists; the image is tagged with it, so it must say it.
run_version_step TAG_NAME=1.3.0 GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main GITHUB_SHA="$SHA"
assert_equals "the release this run cut wins over the commit" "build_args=VERSION=1.3.0" "$STEP_OUTPUT"
run_version_step VERSION_BUILD_ARG=APP_VERSION GITHUB_SHA="$SHA"
assert_equals "the build argument carries the name the caller chose" \
  "build_args=APP_VERSION=0123456" "$STEP_OUTPUT"

run_version_step 'VERSION_BUILD_ARG=VERSION ' GITHUB_SHA="$SHA"
assert_true "a malformed name fails the step" "[[ $STEP_RC -ne 0 ]]"
assert_equals "...and hands the build nothing" "" "$STEP_OUTPUT"
assert_true "...with an error that names the rule" \
  "grep -q '::error::version_build_arg must name a Dockerfile ARG' <<< \"\$STEP_OUT\""
run_version_step TAG_NAME="$(printf '1.3.0\nOTHER=1')" GITHUB_SHA="$SHA"
assert_true "a release version holding a newline fails the step" "[[ $STEP_RC -ne 0 ]]"
assert_equals "...and smuggles no second build argument in" "" "$STEP_OUTPUT"
assert_true "...saying no version could be resolved" \
  "grep -q '::error::version_build_arg is set, but no version could be resolved' <<< \"\$STEP_OUT\""
run_version_step
assert_true "nothing to resolve fails the step" "[[ $STEP_RC -ne 0 ]]"
assert_equals "...and hands the build nothing" "" "$STEP_OUTPUT"
assert_true "...saying no version could be resolved" \
  "grep -q '::error::version_build_arg is set, but no version could be resolved' <<< \"\$STEP_OUT\""

printf 'FROM scratch\n' > "$DOCKER_PROJECT/$STEP_DOCKERFILE"
run_version_step GITHUB_SHA="$SHA"
assert_true "a Dockerfile without the ARG warns" \
  "grep -q \"::warning::$STEP_DOCKERFILE declares no 'ARG VERSION'\" <<< \"\$STEP_OUT\""
assert_equals "...and still hands the build the argument, as a warning must" \
  "build_args=VERSION=0123456" "$STEP_OUTPUT"

# The step that names the pushed image, executed the same way. The name comes out
# lower-case, because `docker/metadata-action` lower-cases it before tagging and a
# registry refuses an upper-case repository, and the digest is the build's.
yaml_query "$DOCKER_ACTION" "step(doc['runs']['steps'], 'image')['run']" > "$WORK_DIR/image-step.sh"
FIXTURE_DIGEST="sha256:$(printf 'd%.0s' $(seq 64))"

# run_image_step [VAR=value...] -- leaves IMAGE_STEP_RC, IMAGE_STEP_OUT and the
# GITHUB_OUTPUT it wrote in IMAGE_STEP_OUTPUT, emptied first like run_version_step's.
run_image_step() {
  : > "$WORK_DIR/github_output"
  IMAGE_STEP_RC=0
  # shellcheck disable=SC2034  # read by assert_true's eval'd conditions, which ShellCheck cannot see
  IMAGE_STEP_OUT="$(
    cd "$DOCKER_PROJECT" || exit 1
    env -i PATH="$PATH" HOME="$HOME" GITHUB_OUTPUT="$WORK_DIR/github_output" "$@" \
      bash --noprofile --norc -eo pipefail "$WORK_DIR/image-step.sh" 2>&1
  )" || IMAGE_STEP_RC=$?
  IMAGE_STEP_OUTPUT="$(cat "$WORK_DIR/github_output")"
}

run_image_step IMAGE=ghcr.io/Fixture-Owner/Fixture-Repo DIGEST="$FIXTURE_DIGEST"
assert_equals "the pushed image is named lower-case, by the build's digest" \
  "image=ghcr.io/fixture-owner/fixture-repo@$FIXTURE_DIGEST" "$IMAGE_STEP_OUTPUT"
run_image_step IMAGE=ghcr.io/Fixture-Owner/Fixture-Repo DIGEST=
assert_true "a build that reported no digest names no image, and says so" \
  "[[ $IMAGE_STEP_RC -eq 0 && -z \"\$IMAGE_STEP_OUTPUT\" ]] && grep -q '::warning::' <<< \"\$IMAGE_STEP_OUT\""
echo ""

# ---------------------------------------------------------------------------
echo "5. Both builds of one commit carry one version"
# ---------------------------------------------------------------------------
# The property the shared helper exists for, asserted end to end: the image
# delivery's step and the Fly.io deploy, run against the same description of a
# build, hand their images the same string.
printf 'FROM scratch\nARG VERSION=dev\n' > "$DOCKER_PROJECT/$STEP_DOCKERFILE"
FLY_PROJECT="$WORK_DIR/fly-project"
mkdir -p "$FLY_PROJECT"

# fly_version [VAR=value...] -- the value Fly's dry run passes to --build-arg.
fly_version() {
  (
    cd "$FLY_PROJECT" || exit 1
    env -i PATH="$PATH" HOME="$FLY_PROJECT" GIT_CEILING_DIRECTORIES="$WORK_DIR" \
      SCRIPTS_DIR="$SCRIPTS_DIR" DEPLOY_DRY_RUN=true FLY_API_TOKEN=fixture-token-placeholder \
      FLY_APP_NAME=fixture-app FLY_VERSION_BUILD_ARG=VERSION "$@" sh "$FLYIO_SH" > /dev/null 2>&1
  ) || return 0
  sed -n 's/.*--build-arg VERSION=\([^ ]*\).*/\1/p' "$FLY_PROJECT/build/reports/deploy-flyio/command.txt"
}

# Agreement is only worth asserting on a value: two builds that both pass NOTHING
# also agree, and that is the very state this suite exists to rule out.
for fixture in \
  "GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main GITHUB_SHA=$SHA" \
  "GITHUB_REF_TYPE=tag GITHUB_REF_NAME=1.2.3 GITHUB_SHA=$SHA"; do
  read -r -a assignments <<< "$fixture"
  run_version_step "${assignments[@]}"
  delivered="${STEP_OUTPUT#build_args=VERSION=}"
  deployed="$(fly_version "${assignments[@]}")"
  assert_true "image delivery and Fly pass one version for: $fixture" \
    "[[ -n '$delivered' && '$delivered' == '$deployed' ]]"
done
# The release a bump merge cuts reaches each build by its own input -- `tag_name`
# for the image, `version` for Fly -- and must come out the same.
run_version_step TAG_NAME=1.3.0 GITHUB_REF_TYPE=branch GITHUB_SHA="$SHA"
delivered="${STEP_OUTPUT#build_args=VERSION=}"
deployed="$(fly_version FLY_APP_VERSION=1.3.0 GITHUB_REF_TYPE=branch GITHUB_SHA="$SHA")"
assert_true "image delivery and Fly pass one version for a release cut in the run" \
  "[[ -n '$delivered' && '$delivered' == '$deployed' ]]"

# On `go-flyio.yaml`'s default path there is only ONE build: the deploy ships the
# image delivered above, whose version is already in it, and builds nothing -- so it
# passes no version of its own, even with the build argument named.
# shellcheck disable=SC2034  # read by assert_true's eval'd conditions
FLY_IMAGE_CMD="$(
  cd "$FLY_PROJECT" || exit 1
  env -i PATH="$PATH" HOME="$FLY_PROJECT" GIT_CEILING_DIRECTORIES="$WORK_DIR" \
    SCRIPTS_DIR="$SCRIPTS_DIR" DEPLOY_DRY_RUN=true FLY_API_TOKEN=fixture-token-placeholder \
    FLY_APP_NAME=fixture-app FLY_VERSION_BUILD_ARG=VERSION GITHUB_SHA="$SHA" \
    FLY_IMAGE="ghcr.io/fixture-owner/fixture-repo@$FIXTURE_DIGEST" sh "$FLYIO_SH" > /dev/null 2>&1
  cat build/reports/deploy-flyio/command.txt 2>/dev/null
)"
assert_true "a deploy of the delivered image passes no version of its own" \
  "grep -q -- '--image ' <<< \"\$FLY_IMAGE_CMD\" && ! grep -q -- '--build-arg' <<< \"\$FLY_IMAGE_CMD\""
echo ""

# ---------------------------------------------------------------------------
echo "6. The Go workflows: wiring"
# ---------------------------------------------------------------------------
assert_equals "go-docker.yaml declares version_build_arg, naming nothing by default" "" \
  "$(yaml_query "$GO_DOCKER" "trigger['workflow_call']['inputs']['version_build_arg']['default']")"
assert_equals "go-docker.yaml hands it to the image delivery" '${{ inputs.version_build_arg }}' \
  "$(yaml_query "$GO_DOCKER" "step(doc['jobs']['delivery-docker']['steps'], '40-delivery/docker@')['with']['version_build_arg']")"
assert_equals "go-docker.yaml exposes the release this run cut" \
  '${{ jobs.delivery-release.outputs.tag_name }}' \
  "$(yaml_query "$GO_DOCKER" "trigger['workflow_call']['outputs']['tag_name']['value']")"

assert_equals "go-flyio.yaml declares version_build_arg, naming nothing by default" "" \
  "$(yaml_query "$GO_FLYIO" "trigger['workflow_call']['inputs']['version_build_arg']['default']")"
assert_equals "go-flyio.yaml hands it to go-docker.yaml, for the registry image" \
  '${{ inputs.version_build_arg }}' \
  "$(yaml_query "$GO_FLYIO" "doc['jobs']['go-docker']['with']['version_build_arg']")"
assert_equals "go-flyio.yaml hands it to the deploy, for Fly's own build when opted into" \
  '${{ inputs.version_build_arg }}' \
  "$(yaml_query "$GO_FLYIO" "step(doc['jobs']['deployment-flyio']['steps'], '50-deployment/flyio@')['with']['version_build_arg']")"

# The registry image's way to the deploy, one hop at a time: the delivery step's
# output, the delivery job's, the workflow's, and the deploy's input. A hop that is
# dropped or misspelled hands the deploy an empty image, which it refuses.
assert_equals "go-docker.yaml's delivery step carries the 'docker' id" "docker" \
  "$(yaml_query "$GO_DOCKER" "step(doc['jobs']['delivery-docker']['steps'], '40-delivery/docker@')['id']")"
assert_equals "go-docker.yaml's delivery job outputs that step's image" '${{ steps.docker.outputs.image }}' \
  "$(yaml_query "$GO_DOCKER" "doc['jobs']['delivery-docker']['outputs']['image']")"
assert_equals "go-docker.yaml outputs the image its delivery job pushed" \
  '${{ jobs.delivery-docker.outputs.image }}' \
  "$(yaml_query "$GO_DOCKER" "trigger['workflow_call']['outputs']['image']['value']")"
assert_equals "go-flyio.yaml hands the deploy that image, unless the caller builds from source" \
  "\${{ !inputs.fly_build_from_source && needs.go-docker.outputs.image || '' }}" \
  "$(yaml_query "$GO_FLYIO" "step(doc['jobs']['deployment-flyio']['steps'], '50-deployment/flyio@')['with']['image']")"
# The deploy after a bump merge runs on the branch, so without this it would carry
# the commit while the image pushed in the same run carries the release.
assert_equals "go-flyio.yaml hands the deploy the release go-docker.yaml cut" \
  '${{ needs.go-docker.outputs.tag_name }}' \
  "$(yaml_query "$GO_FLYIO" "step(doc['jobs']['deployment-flyio']['steps'], '50-deployment/flyio@')['with']['version']")"
echo ""

echo "================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All build version tests passed!"
