#!/usr/bin/env bash
set -e

# Hold the Azure DevOps secret-passing contract across the whole repository.
#
# Why a dedicated regression test exists:
#
# Azure Pipelines injects NON-SECRET pipeline variables into every step's
# process environment automatically, and NEVER injects secret ones. A step that
# reads a credential ambiently therefore works perfectly while the variable is
# stored in plaintext and silently stops receiving it the moment somebody marks
# it secret -- which is the one thing everybody is eventually told to do.
#
# The failure is invisible in both directions. Marking the variable secret is a
# Library UI change in the CONSUMER's project, with no diff and no relationship
# to this repository; the pipeline then goes on passing, because the scanners
# that lose their credential are `continueOnError: true`. So the template keeps
# a plaintext credential alive indefinitely and the project that tries to fix
# its own hygiene finding is the one that gets punished for it.
#
# `sca:safety` shipped exactly that way and blocked three separate projects from
# marking `SAFETY_API_KEY` secret until the step mapped it explicitly.
#
# Which step consumes which credential is established two different ways,
# because the defect hides in two different places:
#
#   1. DERIVED. A step that runs one of this repository's own scripts is checked
#      against what that script actually reads. This is mechanical and needs no
#      list to maintain.
#
#   2. DECLARED. A step that runs a third-party tool which reads its credential
#      STRAIGHT FROM THE ENVIRONMENT has no textual reference to the variable
#      anywhere -- not in the YAML, not in a script, nowhere. `safety` is the
#      archetype, and that invisibility is precisely why the bug survived review:
#      grepping the repository for `SAFETY_API_KEY` returned nothing at all. Such
#      a consumer cannot be derived and must be declared below.
#
# A third assertion keeps those tables honest: every credential-shaped variable
# the Azure templates and their scripts mention must be classified, so a new one
# forces a decision here instead of silently joining the ambient-and-broken group.
#
# The fourth holds the other direction of the same rule: a credential travels in
# the ENVIRONMENT, never in the script text. Azure expands the macro form
# everywhere in a script body, comments included, so merely DOCUMENTING the
# macro substitutes the real key into the file on the agent -- which is exactly
# how the comment above the guard was first written.
#
# The fifth asserts the other half of the safety fix, which is easy to lose in a
# later edit: the mapping delivers the macro text itself when the variable is
# undefined, so a mapping added without a guard converts "this project has no
# key" into "this project has a bogus key" -- trading a scan that degraded
# quietly for one that fails. It runs the shipped step body, not a copy.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPTS_DIR" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# assert_empty <description> <captured-output>
#
# Passes when the output is empty; the offending step is printed on failure, so
# the message names what to fix rather than only that something is wrong.
assert_empty() {
  local description="$1"
  local output="$2"
  if [ -z "$output" ]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    echo "$output" | sed 's/^/         /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# The checks are Go test support (`internal/testsuites/azuresecretenv`, where
# each rule's reasoning lives beside its code), built from this checkout for
# this run. A checker that does not build stops the suite: the assertions below
# would otherwise run against nothing and pass for it.
TOOL_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TOOL_DIR"' EXIT
CHECKER="$TOOL_DIR/azuresecretenv"
if ! CGO_ENABLED=0 GOFLAGS=-mod=readonly GOWORK=off \
  go build -C "$SCRIPTS_DIR" -trimpath -o "$CHECKER" ./internal/testsuites/azuresecretenv; then
  echo -e "${RED}could not build ./internal/testsuites/azuresecretenv, so no assertion can run${NC}"
  exit 1
fi

# One `<assertion>\t<finding>` line per violation; each assertion below selects
# its own.
FINDINGS="$("$CHECKER" check)"

select_findings() {
  printf '%s\n' "$FINDINGS" | awk -F '\t' -v group="$1" '$1 == group { sub(/^[^\t]*\t/, ""); print }'
}

# Reported FIRST because it invalidates everything below: a template that does
# not parse expands to no steps, so the assertions find nothing to complain
# about and the suite goes green precisely when it has stopped looking.
echo "1. Every Azure template parses"
assert_empty "every template under azure-devops/ parses" "$(select_findings parse)"
echo ""

echo "2. Every step consuming a credential maps it through \`env:\`"
assert_empty "no step reads a credential ambiently" "$(select_findings unmapped)"
echo ""

echo "3. Every credential-shaped variable is classified"
assert_empty "the declared table is current and nothing is unclassified" "$(select_findings classified)"
echo ""

echo "4. No credential is macro-expanded into a script body"
assert_empty "every credential travels through \`env:\`, never through the script text" "$(select_findings macro)"
echo ""

echo "5. The \`sca:safety\` step survives an undefined SAFETY_API_KEY"
# Azure DevOps substitutes nothing for an undefined variable, so `env:` hands
# the step the LITERAL `$(SAFETY_API_KEY)`. Without the guard this fix would
# regress every project that has no key at all -- turning "no credential" into
# "a bogus credential", which fails instead of degrading. The step's real body
# is extracted and run with the scan replaced by a probe, so this asserts on
# the shipped shell rather than on a copy of it.
BODY="$("$CHECKER" step-script azure-devops/python/stages/20-security/pdm.yaml sca_safety 'Run Safety dependency check')"
PROBE="$(printf '%s' "$BODY" | sed 's|pdm run safety-scan|if [ -n "${SAFETY_API_KEY+x}" ]; then printf %s "$SAFETY_API_KEY"; fi|')"

GUARD_RESULT=""
# An empty extraction is a FINDING, not a skip. Renaming the step or the job
# would otherwise leave this assertion running against nothing at all and
# passing for it -- the same silent-pass shape assertion 1 exists to prevent.
if [ -z "$BODY" ]; then
  GUARD_RESULT="could not extract the sca:safety step body -- the job or displayName moved, so the guard is unverified
"
fi
# An unset variable arrives as the literal macro and must be discarded.
ACTUAL="$(SAFETY_API_KEY='$(SAFETY_API_KEY)' sh -c "$PROBE")"
[ -z "$ACTUAL" ] || GUARD_RESULT="${GUARD_RESULT}an undefined variable reached safety as '$ACTUAL'
"
# A real key must survive untouched -- the entire point of the `env:` mapping.
ACTUAL="$(SAFETY_API_KEY='fixture-token-placeholder' sh -c "$PROBE")"
[ "$ACTUAL" = 'fixture-token-placeholder' ] || GUARD_RESULT="${GUARD_RESULT}a real key did not survive the guard (got '$ACTUAL')
"
assert_empty "the macro guard discards \$(SAFETY_API_KEY) and passes a real key" "$GUARD_RESULT"
echo ""

echo "=============================="
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ] && echo -e "${GREEN}Azure DevOps secret-passing contract holds${NC}"
[ "$TESTS_FAILED" -eq 0 ]
