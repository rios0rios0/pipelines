#!/usr/bin/env bash
set -e

# Test script for the shared .gitignore block generator.
# Exercises global/scripts/tools/gitignore/run.sh against synthetic consumer
# repositories and asserts:
#   * the block is generated, with the fragments the project's Makefile implies
#   * the project's own entries survive, and the block sits ABOVE them so a
#     `!` negation below still wins (gitignore is last-match-wins)
#   * regeneration is idempotent, including over an existing block
#   * --check exits 0 when current, 1 when stale or absent
#   * the artifacts the pipeline writes are genuinely ignored, per git itself
#   * every `makefiles/*.mk` is a recorded decision: it ships a fragment, or is named
#     as writing nothing outside the default `build/reports/`

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_SH="$SCRIPTS_DIR/global/scripts/tools/gitignore/run.sh"
TEST_DIR="$(mktemp -d)"

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

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

gi() { SCRIPTS_DIR="$SCRIPTS_DIR" "$RUN_SH" "$@"; }

# Build a consumer repo at $1 including the language fragment named in $2.
make_repo() {
  local repo="$1" lang="$2"
  mkdir -p "$repo"
  {
    echo 'SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines'
    echo '-include $(SCRIPTS_DIR)/makefiles/common.mk'
    [ -n "$lang" ] && echo "-include \$(SCRIPTS_DIR)/makefiles/$lang.mk"
  } > "$repo/Makefile"
  git -C "$repo" init -q .
}

echo "Testing the shared .gitignore block generator..."
echo ""

echo "Generation"
REPO="$TEST_DIR/go-project"
make_repo "$REPO" golang
printf 'bin\nbuild\n' > "$REPO/.gitignore"
gi "$REPO" > /dev/null

assert_true "writes the begin marker" \
  "grep -qxF '# >>> pipelines:begin' '$REPO/.gitignore'"
assert_true "writes the end marker" \
  "grep -qxF '# <<< pipelines:end' '$REPO/.gitignore'"
assert_true "includes the common fragment" \
  "grep -qxF '.codeql-db/' '$REPO/.gitignore'"
assert_true "includes the golang fragment the Makefile implies" \
  "grep -qxF '/junit-unit.xml' '$REPO/.gitignore'"
assert_true "keeps the project's own entries" \
  "grep -qxF 'bin' '$REPO/.gitignore' && grep -qxF 'build' '$REPO/.gitignore'"
assert_true "puts the block above the project's entries" \
  "[ \"\$(grep -n 'pipelines:end' '$REPO/.gitignore' | cut -d: -f1)\" -lt \"\$(grep -n '^bin\$' '$REPO/.gitignore' | cut -d: -f1)\" ]"

echo ""
echo "Fragment selection"
PLAIN="$TEST_DIR/plain-project"
make_repo "$PLAIN" ""
gi "$PLAIN" > /dev/null
assert_true "a project with no language fragment still gets common" \
  "grep -qxF 'build/reports/' '$PLAIN/.gitignore'"
assert_true "and does not get another language's entries" \
  "! grep -qxF '/junit-unit.xml' '$PLAIN/.gitignore'"

NOMAKE="$TEST_DIR/no-makefile"
mkdir -p "$NOMAKE" && git -C "$NOMAKE" init -q .
gi "$NOMAKE" > /dev/null
assert_true "a project with no Makefile still gets common" \
  "grep -qxF '.codeql-db/' '$NOMAKE/.gitignore'"

echo ""
echo "Every language that overrides REPORT_PATH is covered"
# `common` ignores the DEFAULT report directory, `build/reports/`. Three .mk fragments
# override REPORT_PATH to `./reports`, and each needs its own fragment saying so. Dart and
# Python were both missed on the first pass, so this asserts the property rather than the
# list: whatever `makefiles/` overrides, `global/gitignore/` must cover.
for lang in $(grep -rl 'REPORT_PATH *?*= *\./reports' "$SCRIPTS_DIR/makefiles/" \
              | sed 's|.*/||; s|\.mk$||' | sort); do
  OVERRIDER="$TEST_DIR/overrider-$lang"
  make_repo "$OVERRIDER" "$lang"
  gi "$OVERRIDER" > /dev/null 2>&1
  mkdir -p "$OVERRIDER/reports" && : > "$OVERRIDER/reports/tool.json"
  assert_true "$lang overrides REPORT_PATH to ./reports, and ./reports/ is ignored" \
    "git -C '$OVERRIDER' check-ignore -q reports/tool.json"
done

echo ""
echo "Every consumable .mk is a recorded decision"
# Overriding REPORT_PATH is only ONE of the two ways a language escapes `build/reports/`.
# The other is writing outside REPORT_PATH altogether -- Go's root-level `junit-*.xml`,
# Dart's `/coverage/`, Terraform's `.terraform/` -- and the property above cannot see that
# class at all, because it asks only "does this language point REPORT_PATH somewhere else".
#
# That blind spot is not merely a missing assertion: `run.sh` skips a language with no
# fragment SILENTLY (`[ -f "$FRAGMENT_DIR/$name" ] || continue`), so `terra.mk` and
# `terraform.mk` shipped with none while `make gitignore-check` stayed green in every
# consumer. Nothing anywhere asked whether they had been considered.
#
# So every `.mk` a consumer can include has to be a decision someone wrote down: it either
# ships a fragment, or is named below as writing nothing outside the default
# `build/reports/`. A language added later fails here until one of the two is true.
WRITES_ONLY_REPORTS='dotnet java javascript'
for mk in "$SCRIPTS_DIR"/makefiles/*.mk; do
  lang="$(basename "$mk" .mk)"
  case " $WRITES_ONLY_REPORTS " in *" $lang "*) continue ;; esac
  assert_true "$lang ships a fragment, or belongs on the writes-only-reports list" \
    "[ -f '$SCRIPTS_DIR/global/gitignore/$lang' ]"
done

echo ""
echo "Idempotency"
cp "$REPO/.gitignore" "$TEST_DIR/first-run"
gi "$REPO" > /dev/null
assert_true "regenerating over an existing block changes nothing" \
  "cmp -s '$REPO/.gitignore' '$TEST_DIR/first-run'"
gi "$REPO" > /dev/null
assert_true "a third run is stable too" \
  "cmp -s '$REPO/.gitignore' '$TEST_DIR/first-run'"

echo ""
echo "Drift detection"
assert_true "--check exits 0 when the block is current" \
  "gi --check '$REPO' > /dev/null 2>&1"

printf 'bin\n' > "$REPO/.gitignore"
assert_true "--check exits 1 when the block is missing" \
  "! gi --check '$REPO' > /dev/null 2>&1"
assert_true "--check names the fix in its output" \
  "gi --check '$REPO' 2>&1 | grep -q 'make gitignore'"

gi "$REPO" > /dev/null
STALE="$TEST_DIR/stale-project"
make_repo "$STALE" golang
gi "$STALE" > /dev/null
# a fragment gaining an entry is the case this check exists for
sed -i 's|^\.codeql-db/$|.codeql-db/\nnewly-added-report.json|' "$STALE/.gitignore"
assert_true "--check exits 1 when the block has been edited by hand" \
  "! gi --check '$STALE' > /dev/null 2>&1"

NOFILE="$TEST_DIR/no-gitignore"
make_repo "$NOFILE" golang
assert_true "--check exits 1 when there is no .gitignore at all" \
  "! gi --check '$NOFILE' > /dev/null 2>&1"
gi "$NOFILE" > /dev/null
assert_true "generation creates the file when absent" \
  "[ -f '$NOFILE/.gitignore' ]"

echo ""
echo "Malformed markers are refused, never rewritten"
# A begin marker with no end made the removal read the rest of the file as block content and
# throw it away -- silent loss of the project's own entries, in the one place this script
# promises not to touch. The other shapes are recoverable only by guessing, so they refuse too.
MAL="$TEST_DIR/malformed"

mal_case() {
  local body="$1"
  rm -rf "$MAL"
  make_repo "$MAL" golang
  printf '%b' "$body" > "$MAL/.gitignore"
}

mal_case '# >>> pipelines:begin\nbuild/reports/\nnode_modules/\nsecrets.local\n'
assert_true "refuses a begin marker with no end" \
  "! gi '$MAL' > /dev/null 2>&1"
assert_true "and keeps the project's entries when it refuses" \
  "grep -qxF 'node_modules/' '$MAL/.gitignore' && grep -qxF 'secrets.local' '$MAL/.gitignore'"
assert_true "and says which markers it found" \
  "gi '$MAL' 2>&1 | grep -q 'must come as a pair'"

mal_case 'keep-me\n# <<< pipelines:end\nalso-keep\n'
assert_true "refuses an end marker with no begin" \
  "! gi '$MAL' > /dev/null 2>&1"

mal_case '# <<< pipelines:end\nkeep-me\n# >>> pipelines:begin\nx\n'
assert_true "refuses markers that are out of order" \
  "! gi '$MAL' > /dev/null 2>&1"
assert_true "and names the ordering as the reason" \
  "gi '$MAL' 2>&1 | grep -q 'comes before'"

mal_case '# >>> pipelines:begin\na\n# <<< pipelines:end\nkeep-me\n# >>> pipelines:begin\nb\n# <<< pipelines:end\n'
assert_true "refuses a duplicated block" \
  "! gi '$MAL' > /dev/null 2>&1"
assert_true "and keeps the entries between the two blocks" \
  "grep -qxF 'keep-me' '$MAL/.gitignore'"

mal_case '# >>> pipelines:begin\nkeep-me\n'
assert_true "--check reports malformed rather than merely stale" \
  "gi --check '$MAL' 2>&1 | grep -q 'malformed'"

echo ""
echo "Real gitignore semantics"
for artifact in build/reports/x.json reports/x.json .codeql-db/x coverage.out \
                coverage.txt coverage.xml cobertura.xml junit.xml junit-unit.xml \
                junit-integration.xml unit_coverage.txt integration_coverage.txt; do
  assert_true "git ignores $artifact" \
    "git -C '$REPO' check-ignore -q --no-index '$artifact'"
done

printf '\n!coverage.xml\n' >> "$REPO/.gitignore"
assert_true "a project can still re-include a shared entry below the block" \
  "! git -C '$REPO' check-ignore -q --no-index coverage.xml"

echo ""
echo "Terraform working-tree artifacts"
# `terraform init` runs from a different directory in each tier, so the artifact appears at
# three different depths -- per module, per root module, and at the repository root. Asked
# through `git check-ignore` rather than by matching the fragment text, so the answer is
# git's own.
TERRA="$TEST_DIR/terra-project"
make_repo "$TERRA" terra
gi "$TERRA" > /dev/null
for artifact in modules/vpc/.terraform/providers/p stacks/prod/.terraform/modules/m \
                .terraform/providers/p build/.terraform-plugin-cache/p; do
  assert_true "a terra project ignores $artifact" \
    "git -C '$TERRA' check-ignore -q --no-index '$artifact'"
done
# The lock file pins provider versions and is meant to be committed, so an over-broad
# `.terraform*` would be a regression rather than extra safety.
assert_true "a terra project does NOT ignore .terraform.lock.hcl" \
  "! git -C '$TERRA' check-ignore -q --no-index .terraform.lock.hcl"

TFMOD="$TEST_DIR/terraform-project"
make_repo "$TFMOD" terraform
gi "$TFMOD" > /dev/null
assert_true "a terraform project ignores .terraform/" \
  "git -C '$TFMOD' check-ignore -q --no-index .terraform/providers/p"
assert_true "a terraform project does NOT ignore .terraform.lock.hcl" \
  "! git -C '$TFMOD' check-ignore -q --no-index .terraform.lock.hcl"

echo ""
echo "======================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All tests passed."
