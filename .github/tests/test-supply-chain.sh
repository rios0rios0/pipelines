#!/usr/bin/env bash
set -e

# Hold the supply-chain pinning contract across the whole repository.
#
# Why a dedicated regression test exists:
#
# Pinning is not a state you reach, it is a state you keep. Every one of the
# findings below was introduced by someone acting reasonably -- copying a
# vendor's documented install one-liner, adding an action the way GitHub's
# marketplace prints it, reaching for `:latest` because it is what the README
# said. None of them looks wrong in review, and every one of them is invisible
# in a diff unless you already know to look for it.
#
# Each assertion therefore encodes a failure mode that has ALREADY happened
# here, and would otherwise reappear one commit at a time:
#
#   - an unpinned action → a tag is mutable, so a compromised or retagged
#     release runs with the job's token, in every consumer's pipeline at once;
#   - an unpinned image → the build environment changes without a diff, and a
#     red build cannot be reproduced;
#   - a `curl | sh` install → the runner's credentials are handed to whatever
#     that URL returns at that moment;
#   - an unverified download → the same, one step removed;
#   - a `@latest` / unversioned package install → the tool that decides whether
#     the code is safe to ship is chosen by whoever published most recently.
#
# The assertions are deliberately written against the FILES, not against a
# resolved pipeline: a violation must fail here, before it is merged, rather
# than in whichever consumer happens to run the affected stage first.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPTS_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# assert_empty <description> <captured-output>
#
# Passes when the output is empty. Every finding below is expressed as "list
# the violations", so the offending file:line is printed with the failure
# instead of leaving the reader to re-run a grep by hand.
assert_empty() {
  local description="$1"
  local findings="$2"
  if [[ -z "$findings" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "         $line"
    done <<< "$findings"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

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

# active_uses_ref <file> <expected-ref>
#
# Matches only an executable YAML `uses:` key. Documentation and commented-out
# examples must not be able to satisfy a regression assertion.
active_uses_ref() {
  local file="$1"
  local expected_ref="$2"
  awk -v expected_ref="$expected_ref" '
    /^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      quote = substr(value, 1, 1)
      if ((quote == sprintf("%c", 39) || quote == "\"") && substr(value, length(value), 1) == quote) {
        value = substr(value, 2, length(value) - 2)
      }
      if (value == expected_ref) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

# drop_comments
#
# Filters a `grep -Hn` result down to lines where the match is real code, not
# prose. This repository documents the patterns it forbids at length -- the
# comment above `npx --yes knip@6.32.2` explains what `npx --yes knip` used to
# do -- so a check that forbids a pattern would otherwise be failed by its own
# explanation. Matches `file:line:` followed by optional indent, an optional
# YAML list dash, then `#`.
drop_comments() {
  grep -vE ':[0-9]+:[[:space:]]*(-[[:space:]]*)?#' || true
}

# Keep first-party moving references explicit rather than exempting an owner.
# The two organization-wide Claude workflows are centrally managed policy;
# internal pipeline actions are governed by the workflow-composition contract.
drop_allowed_first_party_refs() {
  grep -vE "^[^:]+:[0-9]+:[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*['\"]?rios0rios0/pipelines/[^'\"[:space:]#]+@main['\"]?([[:space:]]+#.*)?$" \
    | grep -vE "^[^:]+:[0-9]+:[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*['\"]?rios0rios0/\.github/\.github/workflows/(claude|claude-code-review)\.yaml@main['\"]?([[:space:]]+#.*)?$"
}

# `-not -path './.changes/*'` on every scan below is `drop_comments` for a
# different shape of prose. The changelog is now kept as chlog fragments, which
# are YAML files under `.changes/unreleased/`, so this repository's own
# changelog sits inside the name filter for the first time -- and a changelog
# describes call sites for a living ("pinned every `go install ...@latest`
# (`govulncheck`, ...)"). Scanning it reports the description of a fix as the
# violation it fixed. It is excluded for exactly the reason `./.github/tests/*`
# already is: prose ABOUT a call site is not a call site.

# Every YAML file in the repository, excluding the consumer-facing examples
# (checked separately, with a different rule) and git internals.
# `"$@"` is load-bearing: callers pass `-print0`, and a function that drops it
# leaves `find` printing newline-separated paths into an `xargs -0` that then
# treats the whole list as ONE filename. grep fails, the output is empty, and
# the assertion passes without having examined anything. Three of the checks
# below were silently vacuous this way until a deliberate violation was used to
# prove each assertion actually fires.
yaml_files() {
  find . -type f \( -name '*.yaml' -o -name '*.yml' \) \
    -not -path './.git/*' \
    -not -path './.changes/*' \
    -not -path './.docs/examples/*' "$@"
}

echo "=========================================="
echo "Supply-chain pinning contract"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
echo "1. GitHub Actions are pinned to immutable commits"
# ---------------------------------------------------------------------------
# A tag is a label the publisher can move at any time, so `@v4` is a promise
# rather than a pin. Only a 40-character commit SHA is immutable.
#
# `rios0rios0/pipelines/...@main` is excluded on purpose: those are explicitly
# moving SAME-REPOSITORY references whose policy is enforced separately by
# `test-workflow-composition.sh` Test 7. A `$/path/to/action` self-repository
# reference is excluded for the opposite reason: runner 2.336.0+ resolves it
# from the exact repository and commit of the running workflow or composite,
# so it is already immutable without a circular hard-coded SHA.
# The two exact `rios0rios0/.github` Claude workflow paths are separately
# allowlisted above as intentionally moving organization-owned policy. No other
# repository under the same owner inherits that exception.
#
# A LOCAL PATH (`uses: ./path/to/action`) is excluded for the same reason, only
# more so: it is not a reference to another repository at all, it is this very
# commit's own tree. There is no publisher who could move it and no SHA that
# would make it more immutable than it already is -- a SHA would in fact be
# *looser*, since it could name a different commit than the one being tested.
# It is what `.github/workflows/codeql.yaml` uses so the repository scans itself
# with the action as it stands in the pull request rather than as published.
# Anchored to a real YAML key (`^ indent [- ] uses:`), not a bare "uses:"
# anywhere on the line. This repository's comments discuss `uses:` jobs at
# length -- "evaluated in the caller's `uses:` job", "consumed as
# `uses: owner/repo/...@vN`" -- and an unanchored match reads those as
# unpinned actions.
UNPINNED_ACTIONS="$(
  yaml_files -print0 2>/dev/null | xargs -0 grep -HnE "^[[:space:]]*(-[[:space:]]*)?uses:" 2>/dev/null \
    | drop_comments \
    | drop_allowed_first_party_refs \
    | grep -vE "uses: *'?\./" \
    | grep -vE "uses: *'?\\\$/" \
    | grep -vE "uses: *'?[^'@]+@[0-9a-f]{40}'?" \
    || true
)"
assert_empty "every third-party action is pinned to a 40-character commit SHA" "$UNPINNED_ACTIONS"

# The exclusion above must stay narrow: only a path that genuinely starts `./`
# is local. `uses: 'some/action@v4'` must still fail, and so must anything that
# merely mentions a relative path further along the line.
assert_empty "third-party and similarly named actions would still be reported" \
  "$(printf "%s\n" \
    "x.yaml:1:  - uses: 'some/action@v4'" \
    "x.yaml:2:  - uses: 'rios0rios0/another-action@main'" \
    "x.yaml:3:  - uses: 'rios0rios0/pipelines-evil/action@main'" \
    "x.yaml:4:  - uses: 'rios0rios0/.github/.github/workflows/claude-evil.yaml@main'" \
    "x.yaml:5:  - uses: 'rios0rios0/.github/.github/workflows/claude.yaml@feature'" \
    "x.yaml:6:  - uses: 'rios0rios0/.github/.github/workflows/claude.yaml@main-evil'" \
    "x.yaml:7:  - uses: 'rios0rios0/.github/.github/workflows/claude.yaml@main'" \
    "x.yaml:8:  - uses: 'rios0rios0/pipelines/action@feature'" \
    "x.yaml:9:  - uses: 'some/action@v1' # uses: 'rios0rios0/pipelines/action@main'" \
    "x.yaml:10: - uses: 'rios0rios0/pipelines/action@main'" \
    | drop_allowed_first_party_refs \
    | grep -vE "uses: *'?\\./" \
    | grep -vE "uses: *'?[^'@]+@[0-9a-f]{40}'?" \
    | grep -c . | grep -qE '^8$' && true || echo 'a first-party exclusion swallowed an unapproved action')"

# The new exact-commit self-reference must be accepted without widening the
# exclusion above to an arbitrary unpinned action.
assert_empty "an exact-commit self-repository action is accepted" \
  "$(printf "x.yaml:1:  - uses: '\$/path/to/action'\n" | drop_allowed_first_party_refs | grep -vE "uses: *'?\\./" | grep -vE "uses: *'?\\\$/" | grep -vE "uses: *'?[^'@]+@[0-9a-f]{40}'?" || true)"

# A bare SHA is unreadable and unmaintainable; the trailing comment is what
# lets a human (and Dependabot/Renovate) see which version is deployed.
SHA_NO_VERSION="$(
  yaml_files -print0 2>/dev/null | xargs -0 grep -HnE "^[[:space:]]*(-[[:space:]]*)?uses:" 2>/dev/null \
    | drop_comments \
    | grep -E "@[0-9a-f]{40}" \
    | grep -vE "@[0-9a-f]{40}'? +# *v?[0-9]" \
    || true
)"
assert_empty "every SHA-pinned action records its version in a trailing comment" "$SHA_NO_VERSION"
echo ""

# ---------------------------------------------------------------------------
echo "2. Container images are pinned to immutable digests"
# ---------------------------------------------------------------------------
# A tag can be repointed at new content; only `@sha256:` names the bytes.
UNPINNED_IMAGES="$(
  yaml_files -print0 2>/dev/null | xargs -0 grep -HnE "^[[:space:]]*(-[[:space:]]*)?image:[[:space:]]*['\"]?[a-zA-Z0-9]" 2>/dev/null \
    | grep -v '@sha256:' \
    | grep -v '!reference' \
    || true
)"
assert_empty "every 'image:' in a CI template is digest-pinned" "$UNPINNED_IMAGES"

UNPINNED_FROM="$(
  find . -type f -name 'Dockerfile*' -not -path './.git/*' -print0 2>/dev/null \
    | xargs -0 grep -Hn '^FROM' 2>/dev/null \
    | grep -v '@sha256:' \
    || true
)"
assert_empty "every Dockerfile 'FROM' is digest-pinned" "$UNPINNED_FROM"
echo ""

# ---------------------------------------------------------------------------
echo "3. No remote script is piped into a shell"
# ---------------------------------------------------------------------------
# `curl ... | sh` hands the runner -- holding the repository token, and often
# cloud credentials -- to whatever that URL returns at that moment, with no
# pin, no checksum and no opportunity to review. Comments are stripped before
# matching so the prose documenting the rejected pattern (which is extensive,
# and deliberately so) does not fail the check that forbids it.
PIPE_TO_SHELL="$(
  find . -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' -o -name '*.mk' -o -name 'Makefile' \) \
    -not -path './.git/*' -not -path './.changes/*' -not -path './.github/tests/*' -print0 2>/dev/null \
    | xargs -0 grep -HnE '(curl|wget)[^|#]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' 2>/dev/null \
    | drop_comments \
    || true
)"
assert_empty "no executable path pipes a downloaded script into a shell" "$PIPE_TO_SHELL"
echo ""

# ---------------------------------------------------------------------------
echo "4. Downloaded binaries are checksum-verified"
# ---------------------------------------------------------------------------
# The shared helpers are what every installer routes through.
assert_true "the pinned-version manifest exists" \
  "[ -f global/scripts/shared/pinned-versions.sh ]"
assert_true "the verifying downloader exists" \
  "[ -f global/scripts/shared/verify-download.sh ]"

# Sourced files must not be executable -- the repository's convention for
# "this is a library, not an entry point".
assert_true "pinned-versions.sh is sourced, not executed (no +x)" \
  "[ ! -x global/scripts/shared/pinned-versions.sh ]"
assert_true "verify-download.sh is sourced, not executed (no +x)" \
  "[ ! -x global/scripts/shared/verify-download.sh ]"

# A digest must be a real SHA-256, not a placeholder someone meant to fill in.
BAD_DIGESTS="$(
  grep -nE '^[A-Z0-9_]+_SHA256[A-Z0-9_]*=' global/scripts/shared/pinned-versions.sh \
    | grep -vE '="[0-9a-f]{64}"$' \
    || true
)"
assert_empty "every committed digest is 64 lower-case hex characters" "$BAD_DIGESTS"

# Every pinned version must have a matching *_PINNED_VERSION constant, which is
# what `pinned_digest` compares against to decide whether the committed digest
# still applies to the version actually requested.
MISSING_PINNED="$(
  grep -oE '^[A-Z0-9_]+_VERSION=' global/scripts/shared/pinned-versions.sh \
    | sed 's/_VERSION=$//' | grep -v '_PINNED$' | sort -u \
    | while read -r tool; do
        grep -q "^${tool}_PINNED_VERSION=" global/scripts/shared/pinned-versions.sh \
          || echo "${tool}: has ${tool}_VERSION but no ${tool}_PINNED_VERSION"
      done
)"
assert_empty "every overridable version has a pinned constant to compare against" "$MISSING_PINNED"

# Any script that downloads an executable must route through the verifier.
#
# Checked PER URL, not per file. This was a `grep -q download_verified` over the
# whole file, which meant ONE verified download anywhere cleared every other
# download in it -- and that is not hypothetical: golangci-lint/run.sh fetched
# golangci-lint through the helper on one line and `yq` through a bare `curl` a
# hundred lines above, and this assertion reported the file as compliant for as
# long as both were true. A per-file answer cannot express "this file has two
# downloads and one of them is unverified".
#
# Matched on the URL line and a small window ABOVE it, not on `curl ... <url>`
# on one line: the helper takes the URL as an argument, so in every converted
# installer the call and the URL sit on different lines.
#
# Two shapes are accepted besides the canonical call, because both appear here
# and neither is a hole:
#   - a URL assigned to a variable that is later passed to `download_verified`
#     (dart/common.sh resolves the Flutter archive name first, then downloads it
#     ten lines further on, so no fixed window would cover it);
#   - a `.json` document, which is PARSED and never executed -- the Flutter
#     release manifest is fetched to find out which archive to verify against.
#
# The helper and the manifest are excluded because they define the contract
# rather than consume it.
URL_RE='https://[^ "'"'"']*/(releases|download)/'
UNVERIFIED_DOWNLOADS="$(
  for f in $(grep -rlE "$URL_RE" \
      --include='*.sh' global/scripts 2>/dev/null \
      | grep -v 'shared/verify-download.sh' \
      | grep -v 'shared/pinned-versions.sh'); do
    awk -v file="$f" -v urlre="$URL_RE" '
      { line[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          if (line[i] !~ urlre) continue
          if (line[i] ~ /\.json"?[[:space:]]*\\?[[:space:]]*$/) continue
          ok = 0
          start = (i > 3) ? i - 3 : 1
          for (j = start; j <= i; j++) if (line[j] ~ /download_verified/) ok = 1
          if (!ok && line[i] ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/) {
            v = line[i]
            sub(/^[[:space:]]*/, "", v)
            sub(/=.*$/, "", v)
            for (j = 1; j <= NR; j++)
              if (line[j] ~ ("download_verified.*[$][{]?" v)) ok = 1
          }
          if (!ok)
            printf "%s:%d: release artifact fetched without download_verified\n", file, i
        }
      }' "$f"
  done
)"
assert_empty "every release-artifact download routes through download_verified" "$UNVERIFIED_DOWNLOADS"
echo ""

# ---------------------------------------------------------------------------
echo "5. Package installs name a version"
# ---------------------------------------------------------------------------
# `@latest` and a bare package name both mean "whatever the registry serves
# now", which for a linter or scanner means the verdict on unchanged code can
# change overnight.
GO_LATEST="$(
  find . -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' \) \
    -not -path './.git/*' -not -path './.changes/*' -not -path './.github/tests/*' -print0 2>/dev/null \
    | xargs -0 grep -Hn 'go install' 2>/dev/null \
    | grep '@latest' \
    | drop_comments \
    || true
)"
assert_empty "no 'go install ...@latest'" "$GO_LATEST"

NPX_UNPINNED="$(
  find . -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' \) \
    -not -path './.git/*' -not -path './.changes/*' -not -path './.github/tests/*' -print0 2>/dev/null \
    | xargs -0 grep -HnE 'npx --yes [a-z@]' 2>/dev/null \
    | drop_comments \
    | grep -vE 'npx --yes "?\$?\{?[A-Z_]+' \
    | grep -vE 'npx --yes [a-z0-9@/.-]+@[0-9]' \
    || true
)"
assert_empty "every 'npx --yes <pkg>' names a version" "$NPX_UNPINNED"

PIP_UNPINNED="$(
  find . -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' \) \
    -not -path './.git/*' -not -path './.changes/*' -not -path './.github/tests/*' -print0 2>/dev/null \
    | xargs -0 grep -HnE 'pip install ' 2>/dev/null \
    | drop_comments \
    | grep -vE '(==|\$[A-Z_{])' \
    | grep -vE '\-\-upgrade pip' \
    || true
)"
assert_empty "every 'pip install' names a version" "$PIP_UNPINNED"

GEM_UNPINNED="$(
  find . -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' \) \
    -not -path './.git/*' -not -path './.changes/*' -not -path './.github/tests/*' -print0 2>/dev/null \
    | xargs -0 grep -Hn 'gem install' 2>/dev/null \
    | drop_comments \
    | grep -vE '(\-v |\$[A-Z_{])' \
    || true
)"
assert_empty "every 'gem install' names a version" "$GEM_UNPINNED"
echo ""

# ---------------------------------------------------------------------------
echo "6. A consumer's pin reaches the scripts, not just the templates"
# ---------------------------------------------------------------------------
# This is the finding that made all the others less useful than they looked.
# Each platform's scripts-repo abstract cloned the default branch with no ref,
# so a consumer pinning `@4.23.0` got the workflow file from the tag and every
# SCRIPT it executed from `main`. Pinning the entry point while the payload
# floats is worse than not pinning: it reads as covered.
for abstract in \
  'github/global/abstracts/scripts-repo/action.yaml' \
  'gitlab/global/abstracts/scripts-repo.yaml' \
  'azure-devops/global/abstracts/scripts-repo.yaml'; do
  assert_true "$(basename "$(dirname "$abstract")")/$(basename "$abstract"): checks out an explicit ref" \
    "grep -qE 'PIPELINES_REF|action_ref' '$abstract'"
  assert_true "$(basename "$(dirname "$abstract")")/$(basename "$abstract"): no ref-less 'git clone' of the scripts repo" \
    "! grep -qE 'git clone( --depth 1)? \"?\\\$?\{?(SCRIPTS_REPO|PIPELINES_REPO)|git clone --depth 1 https://github.com/rios0rios0/pipelines' '$abstract'"
done

# The Yarn Semgrep chain is the first first-party GitHub path that promises
# end-to-end immutability from a consumer's reusable-workflow SHA. Both edges
# must use GitHub's exact-running-commit self reference; either edge falling
# back to `@main` makes a rerun of an unchanged consumer execute new code.
assert_true "yarn.yaml: Semgrep composite follows the reusable-workflow commit" \
  "active_uses_ref '.github/workflows/yarn.yaml' '\$/github/global/stages/20-security/semgrep'"
assert_true "semgrep/action.yaml: scripts checkout follows the composite commit" \
  "active_uses_ref 'github/global/stages/20-security/semgrep/action.yaml' '\$/github/global/abstracts/scripts-repo'"
echo ""

# ---------------------------------------------------------------------------
echo "7. The documented consumer path pins too"
# ---------------------------------------------------------------------------
# The examples are what people copy. An example that says `@main` teaches every
# consumer to track a moving branch, which is the same exposure this whole
# change exists to remove -- and no assertion above covers them, because they
# are deliberately excluded from `yaml_files`.
EXAMPLES_ON_MAIN="$(
  find .docs/examples -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null \
    | xargs -0 grep -Hn "rios0rios0/pipelines" 2>/dev/null \
    | grep '@main' \
    || true
)"
assert_empty "no example tells consumers to track '@main'" "$EXAMPLES_ON_MAIN"
echo ""

echo "=========================================="
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
echo "=========================================="

if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi

echo -e "${GREEN}Supply-chain pinning contract holds${NC}"
