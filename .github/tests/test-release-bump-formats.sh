#!/usr/bin/env bash
# Regression test for the version the release job of each platform reads from a bump commit or a
# version tag:
#
#   - GitHub Actions: the `extract` step of `github/global/stages/40-delivery/release/action.yaml`
#   - GitLab CI:      the script of `gitlab/global/stages/40-delivery/release.yaml`
#   - Azure DevOps:   the `Extract Release Version` step of `azure-devops/global/stages/40-delivery/release.yaml`
#
# A bump reaches `main` in one of three formats: a git-native branch merge
# (`Merge branch 'chore/bump-X.Y.Z'`), a conventional commit (`chore(bump): bumped version to
# X.Y.Z`, which Azure DevOps prefixes with `Merged PR N: `) and a GitHub-style pull request merge
# (`Merge pull request N from chore/bump-X.Y.Z`). X.Y.Z may be a fork's four-segment X.Y.Z.N or
# X.Y.Z-N. The commit-message patterns used to stop at three segments while the tag-ref path read
# four, so a `1.0.0.1` bump released `1.0.0` from a conventional commit, released nothing from the
# two branch formats on GitLab and Azure DevOps, and released `1.0.0` from them on GitHub.
#
# Only the subject, the message's first line, is read. An Azure DevOps merge commit is `Merged PR
# N: <title>` followed by the pull request's description, a squash merge's body lists the commits
# it squashed, and a GitHub merge commit's body is the pull request's title, so a bump named below
# the subject is not this commit's, and every platform used to tag it. A GitHub merge commit names
# the owner before the branch (`from owner/chore/bump-X.Y.Z`), which GitLab and Azure DevOps now
# read in the subject too. A tag that names no version releases nothing on GitHub, whose step used
# to fail on it; GitLab's request is valid JSON with or without a `CHANGELOG.md`; and the comment
# over each REGEX counts the formats it matches.
#
# Each step is EXTRACTED AND EXECUTED, not mirrored: it runs the way its runner runs it, on a
# fixture repository whose HEAD carries the message, and what is asserted is the version it hands
# on -- GitHub's `tag_name` output, the tag GitLab's releases API is asked for (a stub `curl`
# records the request) and Azure DevOps' `RELEASE_VERSION` variable. One matrix holds the three
# platforms to the same answer, so a pattern that drifts on one of them fails here.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
GITHUB_ACTION="$SCRIPTS_DIR/github/global/stages/40-delivery/release/action.yaml"
GITLAB_JOB="$SCRIPTS_DIR/gitlab/global/stages/40-delivery/release.yaml"
AZURE_JOB="$SCRIPTS_DIR/azure-devops/global/stages/40-delivery/release.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}  PASS: $1${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}  FAIL: $1${NC}"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$description"
  else
    fail "$description"
    printf '        expected: %s\n        actual:   %s\n' "$expected" "$actual"
  fi
}

assert_true() {
  local description="$1" condition="$2"
  if eval "$condition"; then
    pass "$description"
  else
    fail "$description"
  fi
}

for tool in git jq awk sed grep; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo -e "${RED}'$tool' is not installed, so the release steps cannot run${NC}"
    exit 1
  fi
done

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/gitlab" || exit 1

# ---------------------------------------------------------------------------------------------
# The three steps, as their runners run them.

# block <file> <anchor> <opening> -- the body of the first literal block scalar whose opening line
# matches <opening>, at or after the first line matching <anchor>, dedented: the shell the runner
# executes for that step. A list item that opens with a key (`- script: |`) ends at its next key.
# A literal `|` in a pattern is written `[|]`, never `\|`: awk applies string escapes to `-v`
# values, and gawk turns `\|` into a bare `|` (an alternation that matches every line) where
# mawk and BusyBox keep it, so only a bracket expression means the same to every awk.
block() {
  awk -v anchor="$2" -v opening="$3" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    !anchored && $0 ~ anchor { anchored = 1 }
    anchored && !inside && $0 ~ opening {
      inside = 1; body = -1; stop = indent($0)
      if ($0 ~ /^ *- [A-Za-z_-]+: [|]$/) { stop += 2 }
      next
    }
    inside {
      if ($0 ~ /^ *$/) { lines[++n] = ""; next }
      if (indent($0) <= stop) { exit }
      if (body < 0) { body = indent($0) }
      lines[++n] = substr($0, body + 1)
    }
    END { while (n > 0 && lines[n] == "") { n-- } for (i = 1; i <= n; i++) { print lines[i] } }
  ' "$1"
}

block "$GITHUB_ACTION" "^ *- id: 'extract'$" '^ *run: [|]$' > "$WORK/github.sh"
block "$GITLAB_JOB" '^  script:$' '^ *- [|]$' > "$WORK/gitlab.sh"
# The agent fills its macros into the text before bash runs it. Only the walk below HEAD names
# them, and a fixture with no tag never reaches it, but no macro is left for bash to run.
block "$AZURE_JOB" '^ *- script: [|]$' '^ *- script: [|]$' \
  | sed -e 's/[$](\([A-Za-z]*\.[A-Za-z.]*\))/fixture-\1/g' > "$WORK/azure.sh"

echo "=== The steps this suite runs ==="
assert_true "GitHub Actions: the extract step, which writes the version to GITHUB_OUTPUT" \
  "grep -q 'tag_name=' '$WORK/github.sh' && grep -q 'GITHUB_REF_NAME' '$WORK/github.sh'"
assert_true "GitLab CI: the release script, which asks the releases API for the tag" \
  "grep -q 'CI_COMMIT_MESSAGE' '$WORK/gitlab.sh' && grep -q '/releases' '$WORK/gitlab.sh'"
assert_true "Azure DevOps: the extraction step, which sets RELEASE_VERSION" \
  "grep -q 'variable=RELEASE_VERSION' '$WORK/azure.sh' && ! grep -q 'annotatedtags' '$WORK/azure.sh'"

# The stub: `curl` ahead of the real one, for the GitLab script's one request. The body it posts is
# recorded, one JSON object per line.
cat > "$WORK/bin/curl" << 'STUB'
#!/usr/bin/env bash
data=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data) data="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "$data" | jq -c . >> "$CURL_STUB_DIR/requests.log" || exit 2
printf '{}'
STUB
chmod +x "$WORK/bin/curl" || exit 1

# The fixture repository. Each case commits an empty commit carrying its message, so HEAD is the
# commit the GitHub and Azure DevOps steps read. GitLab hands the message over in
# CI_COMMIT_MESSAGE instead, and the notes of its request come from a CHANGELOG.md.
FIXTURE="$WORK/repo"
git init -q -b main "$FIXTURE" || exit 1
git -C "$FIXTURE" config user.name 'Fixture'
git -C "$FIXTURE" config user.email 'fixture@example.invalid'
git -C "$FIXTURE" config commit.gpgsign false
git -C "$FIXTURE" config core.hooksPath "$FIXTURE/.git/no-hooks"
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- notes\n' > "$WORK/gitlab/CHANGELOG.md"

head_commit() {
  git -C "$FIXTURE" commit -q --allow-empty -m "$1"
}

# github_version <ref> <message> -- the tag_name the extract step outputs on a run of <ref> whose
# HEAD carries <message>: empty when it outputs skip_release, `<step failed>` when it fails.
github_version() {
  head_commit "$2" || return 1
  : > "$WORK/github.output"
  (
    cd "$FIXTURE" || exit 1
    GITHUB_REF="$1" GITHUB_REF_NAME="${1#refs/*/}" GITHUB_OUTPUT="$WORK/github.output" \
      bash --noprofile --norc -eo pipefail "$WORK/github.sh"
  ) > "$WORK/github.log" 2>&1 || { printf '<step failed>'; return 0; }
  sed -n 's/^tag_name=//p' "$WORK/github.output"
}

# gitlab_request <checkout> <tag> <message> [artifact] [registry] -- the body the release script
# posts to the releases API, as compact JSON, run in <checkout> in a pipeline for tag <tag> (empty:
# a branch pipeline) whose commit carries <message>, with the build stage's BUILD_ARTIFACT and
# PACKAGE_REGISTRY_URL set to [artifact] and [registry]: empty when it posts none, `<step failed>`
# when it fails, which the stub makes it do on a body that is not JSON.
GITLAB_SHA='0123456789abcdef0123456789abcdef01234567'
gitlab_request() {
  : > "$WORK/requests.log"
  (
    cd "$1" || exit 1
    PATH="$WORK/bin:$PATH" CURL_STUB_DIR="$WORK" \
      CI_COMMIT_TAG="$2" CI_COMMIT_MESSAGE="$3" CI_COMMIT_SHA="$GITLAB_SHA" \
      CI_API_V4_URL='https://gitlab.example.invalid/api/v4' CI_PROJECT_ID='7' \
      CI_JOB_TOKEN='fixture-token-placeholder' BUILD_ARTIFACT="${4:-}" PACKAGE_REGISTRY_URL="${5:-}" \
      sh -e "$WORK/gitlab.sh"
  ) > "$WORK/gitlab.log" 2>&1 || { printf '<step failed>'; return 0; }
  cat "$WORK/requests.log"
}

# gitlab_version <tag> <message> -- the tag the release script asks the releases API for, in a
# pipeline for tag <tag> (empty: a branch pipeline) whose commit carries <message>: empty when it
# asks for none, `<step failed>` when it fails.
gitlab_version() {
  local request
  request="$(gitlab_request "$WORK/gitlab" "$1" "$2")"
  if [[ "$request" == '<step failed>' ]]; then
    printf '%s' "$request"
    return 0
  fi
  printf '%s' "$request" | jq -r '.tag_name'
}

# azure_version <source branch> <message> -- the RELEASE_VERSION the extraction step sets on a run
# of <source branch> whose HEAD carries <message>: empty when it sets SKIP_RELEASE instead,
# `<step failed>` when it fails.
azure_version() {
  head_commit "$2" || return 1
  (
    cd "$FIXTURE" || exit 1
    BUILD_SOURCEBRANCH="$1" BUILD_SOURCEBRANCHNAME="${1##*/}" \
      bash --noprofile --norc "$WORK/azure.sh"
  ) > "$WORK/azure.log" 2>&1 || { printf '<step failed>'; return 0; }
  sed -n 's/^##vso\[task\.setvariable variable=RELEASE_VERSION\]//p' "$WORK/azure.log" | tail -n 1
}

# check_message <description> <expected> <message> -- each platform on a `main` run whose commit
# carries <message> releases <expected> (empty: nothing).
check_message() {
  local description="$1" expected="$2" message="$3"
  assert_eq "GitHub Actions: $description" "$expected" "$(github_version refs/heads/main "$message")"
  assert_eq "GitLab CI: $description" "$expected" "$(gitlab_version '' "$message")"
  assert_eq "Azure DevOps: $description" "$expected" "$(azure_version refs/heads/main "$message")"
}

# check_tag <description> <expected> <tag> <message> -- each platform on a run of tag <tag>, whose
# commit carries <message>, releases <expected>.
check_tag() {
  local description="$1" expected="$2" tag="$3" message="$4"
  assert_eq "GitHub Actions: $description" "$expected" "$(github_version "refs/tags/$tag" "$message")"
  assert_eq "GitLab CI: $description" "$expected" "$(gitlab_version "$tag" "$message")"
  assert_eq "Azure DevOps: $description" "$expected" "$(azure_version "refs/tags/$tag" "$message")"
}

# ---------------------------------------------------------------------------------------------
for VERSION in 1.2.3 1.0.0.1 1.0.1-2; do
  echo ""
  echo "=== A bump to $VERSION, in every format, releases $VERSION ==="
  # given: a bump merged to main in each format, its subject alone or above the body its server
  # writes; when: the run on main reads its message; then: every platform releases the whole
  # version, its fourth segment included
  check_message "a git-native branch merge" "$VERSION" "Merge branch 'chore/bump-$VERSION'"
  check_message "a git-native branch merge naming its target" "$VERSION" \
    "Merge branch 'chore/bump-$VERSION' into 'main'"
  check_message "a remote-tracking branch merge" "$VERSION" \
    "Merge remote-tracking branch 'origin/chore/bump-$VERSION'"
  check_message "a conventional commit" "$VERSION" "chore(bump): bumped version to $VERSION"
  check_message "an Azure DevOps merge of a conventional commit" "$VERSION" \
    "Merged PR 101: chore(bump): bumped version to $VERSION"
  check_message "a pull request merge naming its target" "$VERSION" \
    "Merge pull request #8 from chore/bump-$VERSION into main"
  check_message "a pull request merge with no # and no target" "$VERSION" \
    "Merge pull request 8 from origin/chore/bump-$VERSION"
  check_message "a GitHub merge commit, whose body is the conventional title" "$VERSION" \
    "$(printf 'Merge pull request #8 from owner/chore/bump-%s\n\nchore(bump): bumped version to %s' "$VERSION" "$VERSION")"
  check_message "a GitHub merge commit's subject alone, the owner before the branch" "$VERSION" \
    "Merge pull request #8 from owner/chore/bump-$VERSION"
  check_message "an Azure DevOps merge whose pull request description follows the title" "$VERSION" \
    "$(printf 'Merged PR 101: chore(bump): bumped version to %s\n\nBumped the version.\n\nRelated work items: #12' "$VERSION")"
  check_message "a GitLab merge request merge, the title and the reference below it" "$VERSION" \
    "$(printf "Merge branch 'chore/bump-%s' into 'main'\n\nchore(bump): bumped version to %s\n\nSee merge request group/project!12" "$VERSION" "$VERSION")"
  check_message "a squash merge, the pull request number after the conventional title" "$VERSION" \
    "$(printf 'chore(bump): bumped version to %s (#12)\n\n* chore(bump): bumped version to %s' "$VERSION" "$VERSION")"
done

echo ""
echo "=== A commit that is not a bump releases nothing ==="
# given: a merge or a commit that is not a bump; when: the run on main reads it;
# then: no platform releases anything
check_message "a feature merge" "" "Merged PR 102: feat: added a"
check_message "a fix commit" "" "fix(core): corrected an edge case"
check_message "a pull request merge that is not a bump" "" "Merge pull request #9 from feat/b"
check_message "a branch merge that only looks like a bump" "" "Merge branch 'feat/bump-1.0.0.1'"
check_message "a commit that names chore(bump) but no version" "" \
  "docs(release): explained the chore(bump) commit"
check_message "a version change that is not a chore(bump) commit" "" "chore: bumped version to 1.0.0.1"

echo ""
echo "=== A bump named only below the subject releases nothing ==="
# given: a merge whose subject is not a bump, with a bump in a later line -- an Azure DevOps pull
# request description, the commit list of a squash merge, the title of a GitHub merge commit whose
# branch is not a bump; when: the run on main reads it; then: no platform releases anything,
# whichever format and version shape the later line has
check_message "an Azure DevOps merge whose description reads like a conventional bump" "" \
  "$(printf 'Merged PR 102: feat: added a\n\nchore(bump): bumped version to 9.9.9')"
check_message "an Azure DevOps merge whose description quotes two bump merges" "" \
  "$(printf "Merged PR 103: docs: described the release flow\n\nMerge branch 'chore/bump-1.0.0.1'\nMerge pull request #7 from chore/bump-1.0.1-2 into main")"
check_message "a squash merge whose commit list holds a bump" "" \
  "$(printf 'feat: added a (#12)\n\n* feat: added a\n\n* chore(bump): bumped version to 1.0.0.1')"
check_message "a GitHub merge commit of a branch that is not a bump, under a bump title" "" \
  "$(printf 'Merge pull request #9 from owner/feat/b\n\nchore(bump): bumped version to 9.9.9')"

echo ""
echo "=== A version tag releases the version its ref names ==="
# given: a run of a version tag; when: the step reads its ref; then: every platform releases the
# version the tag names, without a `v`, whatever the commit says
check_tag "a plain tag" "1.0.0" "1.0.0" "chore: tagged"
check_tag "a v-prefixed tag" "1.0.0" "v1.0.0" "chore: tagged"
check_tag "a fork's dot four-segment tag" "1.0.0.1" "1.0.0.1" "chore: tagged"
check_tag "a fork's dash four-segment tag" "1.0.1-2" "v1.0.1-2" "chore: tagged"
check_tag "a tag over the bump its commit names" "3.3.1" "3.3.1" \
  "Merged PR 101: chore(bump): bumped version to 9.9.9"

echo ""
echo "=== A tag that names no version releases nothing, and the step succeeds ==="
# given: a run of a tag that names no version (`latest`), on a commit that is or is not a bump;
# when: the GitHub Actions extract step reads its ref; then: it outputs skip_release and no
# version, and succeeds, since a tag run releases the version its tag names or nothing. The GitLab
# job runs on a version tag alone (its rules), and the Azure DevOps step sets no `pipefail`.
for MESSAGE in 'chore: tagged' 'chore(bump): bumped version to 1.2.3'; do
  assert_eq "GitHub Actions: a tag that names no version, on '$MESSAGE', releases nothing" "" \
    "$(github_version refs/tags/latest "$MESSAGE")"
  assert_true "...and outputs skip_release" "grep -qx 'skip_release=true' '$WORK/github.output'"
done

echo ""
echo "=== GitLab CI: the release request is valid JSON, with or without a CHANGELOG.md ==="
mkdir -p "$WORK/gitlab-no-changelog" || exit 1
# given: a bump in a repository with no CHANGELOG.md
# when: the script asks the releases API for the release
REQUEST="$(gitlab_request "$WORK/gitlab-no-changelog" '' 'chore(bump): bumped version to 1.2.3')"
# then: the body is JSON (the stub refuses anything else) for the version, with no notes
assert_eq "GitLab CI: with no CHANGELOG.md, the release is still asked for" "1.2.3" \
  "$(printf '%s' "$REQUEST" | jq -r '.tag_name' 2> /dev/null)"
assert_eq "...with an empty description" '""' "$(printf '%s' "$REQUEST" | jq -c '.description' 2> /dev/null)"

# given: a bump whose build stage left an artifact, in a repository with a CHANGELOG.md
REGISTRY='https://gitlab.example.invalid/api/v4/projects/7/packages/generic/app/1.2.3'
# when: the script asks the releases API for the release
REQUEST="$(gitlab_request "$WORK/gitlab" '' 'chore(bump): bumped version to 1.2.3' 'app-1.2.3.tar.gz' "$REGISTRY")"
# then: the body names the release, pins its commit, carries the notes and links the artifact
assert_eq "GitLab CI: the release is named after its version, on the pipeline's commit" \
  "Release 1.2.3 $GITLAB_SHA" "$(printf '%s' "$REQUEST" | jq -r '.name + " " + .ref' 2> /dev/null)"
assert_eq "...carries the notes of the newest CHANGELOG.md section" "true" \
  "$(printf '%s' "$REQUEST" | jq -r '.description | contains("- notes")' 2> /dev/null)"
assert_eq "...and links the build artifact under the package registry" \
  "[{\"name\":\"app-1.2.3.tar.gz\",\"url\":\"$REGISTRY/app-1.2.3.tar.gz\"}]" \
  "$(printf '%s' "$REQUEST" | jq -c '.assets.links' 2> /dev/null)"

echo ""
echo "=== The comment over each REGEX counts the formats it matches ==="
# alternatives <regex> -- how many formats an extended regex matches: its `|`s outside every
# group, plus one. The regex reaches awk through ENVIRON, which applies no escapes, unlike `-v`.
alternatives() {
  RE="$1" awk 'BEGIN {
    re = ENVIRON["RE"]; n = 1; depth = 0
    for (i = 1; i <= length(re); i++) {
      c = substr(re, i, 1)
      if (c == "\\") { i++ }
      else if (c == "(") { depth++ }
      else if (c == ")") { depth-- }
      else if (c == "|" && depth == 0) { n++ }
    }
    print n
  }'
}
NUMBERS=(zero one two three four five six seven eight nine)
# given: the REGEX of the GitLab script and of the Azure DevOps extraction step, and each
# "<number> canonical bump" phrase in the file that holds it; when: the formats the REGEX matches
# are counted; then: there is such a phrase, and every one names that count
for PLATFORM in 'GitLab CI:gitlab' 'Azure DevOps:azure'; do
  SCRIPT="$WORK/${PLATFORM#*:}.sh"
  JOB="$GITLAB_JOB"
  [[ "${PLATFORM#*:}" == 'gitlab' ]] || JOB="$AZURE_JOB"
  COUNT="$(alternatives "$(sed -n 's/^REGEX="\(.*\)"$/\1/p' "$SCRIPT")")"
  assert_eq "${PLATFORM%%:*}: each 'canonical bump' comment names the $COUNT formats of the REGEX" \
    "${NUMBERS[$COUNT]:-$COUNT} canonical bump" \
    "$(grep -oE '(one|two|three|four|five|six|seven|eight|nine) canonical bump' "$JOB" | sort -u | tr '\n' ' ' | sed 's/ $//')"
done

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
