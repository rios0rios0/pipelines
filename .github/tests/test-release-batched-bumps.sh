#!/usr/bin/env bash
# Regression test for the version tags `azure-devops/global/stages/40-delivery/release.yaml`
# cuts when one run carries several merges.
#
# A CI trigger with `batch: true` builds every merge that landed while a run was in progress in
# ONE run, at the newest commit. The release job used to read only that commit's message, so a
# version bump merged in the same batch, but not last, was never tagged: no tag, no release, and
# nothing failed. The job now also walks HEAD's first-parent history back to the newest version
# tag and tags every bump on the way that has no tag yet, oldest first, each on its own commit.
#
# Both steps' scripts are EXTRACTED AND EXECUTED, not grepped: they run against throwaway
# repositories, with a stub `curl` that answers the tag API and records every request, so what is
# asserted is what the API is asked for -- which tag, on which commit, with which notes, in which
# order -- and the outcomes that must not move: a run whose HEAD is the bump tags it as before, a
# run with no new bump and a tag that already exists stay no-ops, and a tag run releases its tag.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
RELEASE="$SCRIPTS_DIR/azure-devops/global/stages/40-delivery/release.yaml"

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

for tool in git jq awk sed sort; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo -e "${RED}'$tool' is not installed, so the release scripts cannot run${NC}"
    exit 1
  fi
done

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/repos" || exit 1

# ---------------------------------------------------------------------------------------------
# The two scripts, as the agent runs them.

# script_block <file> <n> -- the body of the n-th `script: |` block, dedented: the bash the agent
# runs for that step.
script_block() {
  awk -v want="$2" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    !inside && /^ *- script: \|$/ {
      if (++count == want) { inside = 1; key = indent($0) + 2; body = -1 }
      next
    }
    inside {
      if ($0 ~ /^ *$/) { lines[++n] = ""; next }
      if (indent($0) <= key) { exit }
      if (body < 0) { body = indent($0) }
      lines[++n] = substr($0, body + 1)
    }
    END { while (n > 0 && lines[n] == "") { n-- } for (i = 1; i <= n; i++) { print lines[i] } }
  ' "$1"
}

script_block "$RELEASE" 1 > "$WORK/extract.sh"
script_block "$RELEASE" 2 > "$WORK/create-tag.sh"

echo "=== Release job: the steps this suite runs ==="
assert_true "the first step is 'Extract Release Version' and has a script" \
  "[[ -s '$WORK/extract.sh' ]] && grep -q 'COMMIT_MESSAGE=\"\$(git log -1 --pretty=%B)\"' '$WORK/extract.sh'"
assert_true "the second step creates the tags and has a script" \
  "[[ -s '$WORK/create-tag.sh' ]] && grep -q 'annotatedtags' '$WORK/create-tag.sh'"
assert_true "the job checks out the whole history, which the walk back to the last tag needs" \
  "grep -q 'fetchDepth: 0' '$RELEASE'"
assert_true "...and every tag, which tells it where the last release is" \
  "grep -q 'fetchTags: true' '$RELEASE'"
assert_true "the tag step still receives its prefix through VERSION_PREFIX" \
  "grep -q 'VERSION_PREFIX: \"\${{ prefix }}\"' '$RELEASE'"

# render <script> <commit> -- the script with the agent's macros filled in, the way the agent
# substitutes them into the text before bash runs it.
render() {
  sed -e "s/[$](Build\.SourceVersion)/$2/g" \
      -e 's|[$](System\.TeamFoundationCollectionUri)|https://dev.example.invalid/org/|g' \
      -e 's/[$](System\.TeamProject)/project/g' \
      -e 's/[$](Build\.Repository\.ID)/repository-id/g' \
      -e 's/[$](System\.AccessToken)/fixture-token-placeholder/g' "$1"
}
assert_eq "no agent macro is left unfilled in the rendered scripts" "" \
  "$(cat "$WORK/extract.sh" "$WORK/create-tag.sh" | render /dev/stdin 0000000 | grep -oE '\$\([A-Za-z]+\.[A-Za-z.]+\)' | sort -u | tr '\n' ' ')"

# The stub. `curl` ahead of the real one: it answers the annotated-tag POST the way the REST API
# would -- 409 for a tag named in CURL_STUB_EXISTING, CURL_STUB_STATUS otherwise (201 by default)
# -- and records each request body as `name commit message` JSON, one per line. `sleep` returns at
# once, so a retried failure costs nothing.
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
out='' data='' url=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-X|--header) shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ "$url" == *'/_apis/git/repositories/repository-id/annotatedtags?'* ]] || { echo "unexpected URL: $url" >&2; exit 2; }
jq -c '{name: .name, commit: .taggedObject.objectId, message: .message}' "$data" >> "$CURL_STUB_LOG" || exit 2
name="$(jq -r '.name' "$data")"
status="${CURL_STUB_STATUS:-201}"
case " ${CURL_STUB_EXISTING:-} " in *" $name "*) status=409 ;; esac
printf '{}' > "$out"
printf '%s' "$status"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/sleep"
chmod +x "$WORK/bin/curl" "$WORK/bin/sleep" || exit 1

# vso_var <output> <name> -- the value a step set with `##vso[task.setvariable]`, which the agent
# hands to the next step as an environment variable.
vso_var() {
  sed -n "s/^##vso\[task\.setvariable variable=$2\]//p" "$1" | tail -n 1
}

# run_release <repo> <source branch> [prefix] -- both steps on the repository's HEAD. Leaves
# EXTRACT_OUT / TAG_OUT (logs), EXTRACT_EXIT / TAG_EXIT and REQUESTS (one `name@commit` per
# request, in order), and the step variables SKIP / VERSION_SET / BATCHED.
run_release() {
  local repo="$1" branch="$2" prefix="${3:-}" head
  head="$(git -C "$repo" rev-parse HEAD)" || return 1
  render "$WORK/extract.sh" "$head" > "$WORK/extract.run"
  render "$WORK/create-tag.sh" "$head" > "$WORK/create-tag.run"
  EXTRACT_OUT="$WORK/extract.out"
  TAG_OUT="$WORK/tag.out"
  : > "$WORK/curl.log"
  (
    cd "$repo" || exit 1
    BUILD_SOURCEBRANCH="$branch" BUILD_SOURCEBRANCHNAME="${branch##*/}" bash "$WORK/extract.run"
  ) > "$EXTRACT_OUT" 2>&1
  EXTRACT_EXIT=$?
  SKIP="$(vso_var "$EXTRACT_OUT" SKIP_RELEASE)"
  VERSION_SET="$(vso_var "$EXTRACT_OUT" RELEASE_VERSION)"
  BATCHED="$(vso_var "$EXTRACT_OUT" BATCHED_RELEASES)"
  (
    cd "$repo" || exit 1
    PATH="$WORK/bin:$PATH" CURL_STUB_LOG="$WORK/curl.log" \
      CURL_STUB_EXISTING="${CURL_STUB_EXISTING:-}" CURL_STUB_STATUS="${CURL_STUB_STATUS:-}" \
      SKIP_RELEASE="$SKIP" RELEASE_VERSION="$VERSION_SET" BATCHED_RELEASES="$BATCHED" \
      VERSION_PREFIX="$prefix" bash "$WORK/create-tag.run"
  ) > "$TAG_OUT" 2>&1
  TAG_EXIT=$?
  REQUESTS="$(jq -r '.name + "@" + .commit' "$WORK/curl.log" | tr '\n' ' ')"
  REQUESTS="${REQUESTS% }"
}

# notes_of <n> -- the message of the n-th request (1-based).
notes_of() {
  sed -n "${1}p" "$WORK/curl.log" | jq -r '.message'
}

# ---------------------------------------------------------------------------------------------
# Fixture repositories. `main` takes every change as a merge commit (`--no-ff`), so the branch's
# first parent is the chain of merges, as on a server that merges pull requests.

# new_repo <name> -- prints the path of a repository on `main` with an empty CHANGELOG.md.
new_repo() {
  local dir="$WORK/repos/$1"
  mkdir -p "$dir" || return 1
  git -C "$dir" init -q -b main || return 1
  git -C "$dir" config user.name 'Fixture'
  git -C "$dir" config user.email 'fixture@example.invalid'
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" config tag.gpgsign false
  git -C "$dir" config core.hooksPath "$dir/.git/no-hooks"
  printf '# Changelog\n\n## [Unreleased]\n' > "$dir/CHANGELOG.md"
  git -C "$dir" add CHANGELOG.md || return 1
  git -C "$dir" commit -q -m 'chore: initial commit' || return 1
  printf '%s' "$dir"
}

# merge <repo> <branch> <merge message> -- a change on <branch>, merged into main; prints the merge.
merge() {
  local repo="$1" branch="$2" message="$3"
  git -C "$repo" checkout -q -b "$branch" main || return 1
  printf '%s\n' "$branch" >> "$repo/work.txt"
  git -C "$repo" add work.txt || return 1
  git -C "$repo" commit -q -m "feat: $branch" || return 1
  git -C "$repo" checkout -q main || return 1
  git -C "$repo" merge -q --no-ff -m "$message" "$branch" || return 1
  git -C "$repo" rev-parse HEAD
}

# bump <repo> <version> <merge message> [branch] -- a bump pull request (a CHANGELOG section for
# the version, committed as `chore(bump)`) merged into main; prints the merge commit.
bump() {
  local repo="$1" version="$2" message="$3" branch="${4:-chore/bump-$2}"
  git -C "$repo" checkout -q -b "$branch" main || return 1
  awk -v v="$version" '{ print } /^## \[Unreleased\]$/ { print ""; print "## [" v "] - 2026-01-01"; print ""; print "- notes for " v }' \
    "$repo/CHANGELOG.md" > "$repo/CHANGELOG.next" || return 1
  mv -f "$repo/CHANGELOG.next" "$repo/CHANGELOG.md" || return 1
  git -C "$repo" add CHANGELOG.md || return 1
  git -C "$repo" commit -q -m "chore(bump): bumped version to $version" || return 1
  git -C "$repo" checkout -q main || return 1
  git -C "$repo" merge -q --no-ff -m "$message" "$branch" || return 1
  git -C "$repo" rev-parse HEAD
}

# released <repo> <version> [commit] -- the version's tag, as a previous run created it.
released() {
  git -C "$1" tag -a "$2" -m "$2" "${3:-HEAD}"
}

# ---------------------------------------------------------------------------------------------
echo ""
echo "=== HEAD is the bump: tagged exactly as before ==="
R="$(new_repo head-is-bump)" || exit 1
bump "$R" 1.0.0 'Merged PR 101: chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" 1.0.0
merge "$R" feat/a 'Merged PR 102: feat: added a' > /dev/null
HEAD_SHA="$(bump "$R" 1.1.0 'Merged PR 103: chore(bump): bumped version to 1.1.0')"
run_release "$R" refs/heads/main
assert_eq "the version comes from HEAD" "1.1.0" "$VERSION_SET"
assert_eq "nothing below HEAD is collected" "" "$BATCHED"
assert_eq "one tag, on HEAD" "1.1.0@$HEAD_SHA" "$REQUESTS"
assert_true "its notes are the 1.1.0 section" "notes_of 1 | grep -q 'notes for 1.1.0' && ! notes_of 1 | grep -q 'notes for 1.0.0'"
assert_eq "the step succeeds" "0" "$TAG_EXIT"

echo ""
echo "=== The bump is one commit below HEAD: tagged on the bump, not on HEAD ==="
R="$(new_repo bump-below-head)" || exit 1
bump "$R" 1.0.0 'Merged PR 101: chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" 1.0.0
BUMP_SHA="$(bump "$R" 1.1.0 'Merged PR 102: chore(bump): bumped version to 1.1.0')"
HEAD_SHA="$(merge "$R" feat/a 'Merged PR 103: feat: added a')"
run_release "$R" refs/heads/main
assert_eq "HEAD is not a bump" "true" "$SKIP"
assert_eq "the bump below HEAD is collected" "1.1.0=$BUMP_SHA" "$BATCHED"
assert_eq "one tag, on the bump commit" "1.1.0@$BUMP_SHA" "$REQUESTS"
assert_true "...which is not HEAD" "[[ '$BUMP_SHA' != '$HEAD_SHA' ]]"
assert_true "its notes are the 1.1.0 section of the bump commit's CHANGELOG.md" "notes_of 1 | grep -q 'notes for 1.1.0'"
assert_eq "the step succeeds" "0" "$TAG_EXIT"
assert_true "the log says HEAD gets no tag of its own" "grep -q 'HEAD is not a bump commit' '$TAG_OUT'"

echo ""
echo "=== Two bumps in one batch: both tagged, oldest first, each on its own commit ==="
R="$(new_repo two-bumps)" || exit 1
bump "$R" 1.0.0 "Merge branch 'chore/bump-1.0.0'" > /dev/null && released "$R" 1.0.0
FIRST="$(bump "$R" 1.1.0 "Merge branch 'chore/bump-1.1.0'")"
merge "$R" feat/a 'Merge pull request #7 from feat/a' > /dev/null
SECOND="$(bump "$R" 1.2.0 'Merge pull request #8 from chore/bump-1.2.0 into main')"
merge "$R" feat/b 'Merge pull request #9 from feat/b' > /dev/null
run_release "$R" refs/heads/main
assert_eq "both bumps are collected, oldest first" "1.1.0=$FIRST 1.2.0=$SECOND" "$BATCHED"
assert_eq "two tags, oldest first, each on its own commit" "1.1.0@$FIRST 1.2.0@$SECOND" "$REQUESTS"
assert_true "each tag carries its own version's notes" \
  "notes_of 1 | grep -q 'notes for 1.1.0' && ! notes_of 1 | grep -q 'notes for 1.2.0' && notes_of 2 | grep -q 'notes for 1.2.0'"
assert_eq "the step succeeds" "0" "$TAG_EXIT"

R="$(new_repo two-bumps-head)" || exit 1
bump "$R" 1.0.0 'chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" 1.0.0
FIRST="$(bump "$R" 1.1.0 'Merged PR 201: chore(bump): bumped version to 1.1.0')"
merge "$R" feat/a 'Merged PR 202: feat: added a' > /dev/null
SECOND="$(bump "$R" 1.2.0 'Merged PR 203: chore(bump): bumped version to 1.2.0')"
run_release "$R" refs/heads/main
assert_eq "with HEAD the second bump, HEAD keeps its version" "1.2.0" "$VERSION_SET"
assert_eq "...and only the bump below it is collected" "1.1.0=$FIRST" "$BATCHED"
assert_eq "...and both are tagged, the older first" "1.1.0@$FIRST 1.2.0@$SECOND" "$REQUESTS"

R="$(new_repo two-bumps-prefix)" || exit 1
bump "$R" 1.0.0 'Merged PR 301: chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" v1.0.0
FIRST="$(bump "$R" 1.1.0 'Merged PR 302: chore(bump): bumped version to 1.1.0')"
SECOND="$(bump "$R" 1.2.0 'Merged PR 303: chore(bump): bumped version to 1.2.0')"
merge "$R" feat/a 'Merged PR 304: feat: added a' > /dev/null
run_release "$R" refs/heads/main v
assert_eq "a tag prefix applies to every tag" "v1.1.0@$FIRST v1.2.0@$SECOND" "$REQUESTS"

echo ""
echo "=== The tag already exists: a no-op ==="
R="$(new_repo exists-head)" || exit 1
bump "$R" 1.0.0 'Merged PR 101: chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" 1.0.0
HEAD_SHA="$(bump "$R" 1.1.0 'Merged PR 102: chore(bump): bumped version to 1.1.0')"
CURL_STUB_EXISTING='1.1.0' run_release "$R" refs/heads/main
assert_eq "HEAD's tag is asked for once, as before" "1.1.0@$HEAD_SHA" "$REQUESTS"
assert_eq "...and the 409 is a success" "0" "$TAG_EXIT"
assert_true "...that says so" "grep -q \"Tag '1.1.0' already exists (HTTP 409)\" '$TAG_OUT'"

R="$(new_repo exists-below)" || exit 1
bump "$R" 1.0.0 'Merged PR 101: chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" 1.0.0
bump "$R" 1.1.0 'Merged PR 102: chore(bump): bumped version to 1.1.0' > /dev/null && released "$R" 1.1.0
merge "$R" feat/a 'Merged PR 103: feat: added a' > /dev/null
run_release "$R" refs/heads/main
assert_eq "a bump below HEAD that is already tagged is not collected" "" "$BATCHED"
assert_eq "...and nothing is asked for" "" "$REQUESTS"
assert_true "...the step skips as before" "grep -q 'because no bump commit was detected' '$TAG_OUT'"
assert_eq "...and succeeds" "0" "$TAG_EXIT"

R="$(new_repo exists-tag-run)" || exit 1
bump "$R" 1.0.0 'Merged PR 101: chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" 1.0.0
bump "$R" 1.0.5 'Merged PR 102: chore(bump): bumped version to 1.0.5' > /dev/null
HEAD_SHA="$(bump "$R" 1.1.0 'Merged PR 103: chore(bump): bumped version to 1.1.0')" && released "$R" 1.1.0
CURL_STUB_EXISTING='1.1.0' run_release "$R" refs/tags/1.1.0
assert_eq "a tag run takes its version from the tag" "1.1.0" "$VERSION_SET"
assert_eq "...walks nothing, even past an untagged bump" "" "$BATCHED"
assert_eq "...asks for its own tag only" "1.1.0@$HEAD_SHA" "$REQUESTS"
assert_eq "...and the 409 is a success" "0" "$TAG_EXIT"

echo ""
echo "=== No bump since the last tag: a no-op ==="
R="$(new_repo no-bump)" || exit 1
bump "$R" 1.0.0 'Merged PR 101: chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" 1.0.0
merge "$R" feat/a 'Merged PR 102: feat: added a' > /dev/null
merge "$R" feat/b 'Merged PR 103: feat: added b' > /dev/null
run_release "$R" refs/heads/main
assert_eq "nothing is collected" "" "$BATCHED"
assert_eq "nothing is asked for" "" "$REQUESTS"
assert_true "the step skips with today's message" "grep -q \"Skipping tag creation for prefix '' because no bump commit was detected.\" '$TAG_OUT'"
assert_eq "...and succeeds" "0" "$TAG_EXIT"

echo ""
echo "=== What the walk leaves alone ==="
R="$(new_repo no-tags)" || exit 1
bump "$R" 1.1.0 'Merged PR 101: chore(bump): bumped version to 1.1.0' > /dev/null
merge "$R" feat/a 'Merged PR 102: feat: added a' > /dev/null
run_release "$R" refs/heads/main
assert_eq "a repository with no version tag at all collects nothing (a first release is unchanged)" "" "$REQUESTS"

R="$(new_repo older-than-newest)" || exit 1
bump "$R" 1.0.0 'Merged PR 101: chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" 1.0.0
bump "$R" 1.1.0 'Merged PR 102: chore(bump): bumped version to 1.1.0' > /dev/null
bump "$R" 1.2.0 'Merged PR 103: chore(bump): bumped version to 1.2.0' > /dev/null && released "$R" v1.2.0
merge "$R" feat/a 'Merged PR 104: feat: added a' > /dev/null
run_release "$R" refs/heads/main
assert_eq "the walk stops at the newest release, in any tag form, and an older untagged bump stays untagged" "" "$REQUESTS"

R="$(new_repo duplicate)" || exit 1
bump "$R" 1.0.0 'Merged PR 101: chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" 1.0.0
bump "$R" 1.1.0 'Merged PR 102: chore(bump): bumped version to 1.1.0' chore/bump-1.1.0-first > /dev/null
merge "$R" feat/a 'Merged PR 103: feat: added a' > /dev/null
AGAIN="$(bump "$R" 1.1.0 'Merged PR 104: chore(bump): bumped version to 1.1.0' chore/bump-1.1.0-again)"
merge "$R" feat/b 'Merged PR 105: feat: added b' > /dev/null
run_release "$R" refs/heads/main
assert_eq "a version bumped twice is tagged once, on its newest bump" "1.1.0@$AGAIN" "$REQUESTS"

R="$(new_repo inner-commit)" || exit 1
bump "$R" 1.0.0 'Merged PR 101: chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" 1.0.0
MERGED="$(bump "$R" 1.1.0 'Merged PR 102: chore(bump): bumped version to 1.1.0')"
INNER="$(git -C "$R" rev-parse "$MERGED^2")"
merge "$R" feat/a 'Merged PR 103: feat: added a' > /dev/null
run_release "$R" refs/heads/main
assert_eq "the merge commit on the branch is tagged, not the bump commit inside the pull request" "1.1.0@$MERGED" "$REQUESTS"
assert_true "...whose message also says chore(bump)" "[[ '$INNER' != '$MERGED' ]] && git -C '$R' log -1 --format=%s '$INNER' | grep -q 'chore(bump)'"

echo ""
echo "=== Failures stay loud, and messages stay out of the log ==="
R="$(new_repo failure)" || exit 1
bump "$R" 1.0.0 'Merged PR 101: chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" 1.0.0
FIRST="$(bump "$R" 1.1.0 'Merged PR 102: chore(bump): bumped version to 1.1.0')"
bump "$R" 1.2.0 'Merged PR 103: chore(bump): bumped version to 1.2.0' > /dev/null
CURL_STUB_STATUS=500 run_release "$R" refs/heads/main
assert_true "a tag the API keeps refusing fails the step" "[[ '$TAG_EXIT' -ne 0 ]]"
assert_eq "...after its retries, before HEAD's tag is asked for" \
  "1.1.0@$FIRST 1.1.0@$FIRST 1.1.0@$FIRST 1.1.0@$FIRST 1.1.0@$FIRST" "$REQUESTS"

R="$(new_repo injection)" || exit 1
bump "$R" 1.0.0 'Merged PR 101: chore(bump): bumped version to 1.0.0' > /dev/null && released "$R" 1.0.0
bump "$R" 1.1.0 'Merged PR 102: chore(bump): bumped version to 1.1.0' > /dev/null
merge "$R" feat/a $'Merged PR 103: feat: added a\n\n##vso[task.setvariable variable=INJECTED]boom' > /dev/null
merge "$R" feat/b 'Merged PR 104: feat: added b' > /dev/null
run_release "$R" refs/heads/main
assert_eq "the walk itself succeeds" "0" "$EXTRACT_EXIT"
assert_true "no commit message the walk reads reaches the log" "! grep -q 'variable=INJECTED' '$EXTRACT_OUT' '$TAG_OUT'"

echo ""
echo "Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
