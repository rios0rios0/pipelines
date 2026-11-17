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

# gitlab_version <tag> <message> -- the tag the release script asks the releases API for, in a
# pipeline for tag <tag> (empty: a branch pipeline) whose commit carries <message>: empty when it
# asks for none, `<step failed>` when it fails.
gitlab_version() {
  : > "$WORK/requests.log"
  (
    cd "$WORK/gitlab" || exit 1
    PATH="$WORK/bin:$PATH" CURL_STUB_DIR="$WORK" \
      CI_COMMIT_TAG="$1" CI_COMMIT_MESSAGE="$2" CI_COMMIT_SHA='0123456789abcdef0123456789abcdef01234567' \
      CI_API_V4_URL='https://gitlab.example.invalid/api/v4' CI_PROJECT_ID='7' \
      CI_JOB_TOKEN='fixture-token-placeholder' sh -e "$WORK/gitlab.sh"
  ) > "$WORK/gitlab.log" 2>&1 || { printf '<step failed>'; return 0; }
  jq -r '.tag_name' "$WORK/requests.log"
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
  # given: a bump merged to main in each format; when: the run on main reads its message;
  # then: every platform releases the whole version, its fourth segment included
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
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
