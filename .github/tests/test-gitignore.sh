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
#   * the pipeline a project's CI imports selects fragments too, on all three platforms,
#     and every language directory and reusable workflow is the same recorded decision

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_SH="$SCRIPTS_DIR/global/scripts/tools/gitignore/run.sh"
TEST_DIR="$(mktemp -d)" || exit 1

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

# Build a consumer repo at $1 with no Makefile, whose CI file $2 holds $3.
ci_repo() {
  local repo="$1" file="$2" content="$3"
  mkdir -p "$repo/$(dirname "$file")"
  printf '%s\n' "$content" > "$repo/$file"
  git -C "$repo" init -q .
}

# Whether $1 is a word of the list $2.
is_listed() {
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

# The fragments a run of the generator on $1 reports it wrote, comma-separated.
fragments_of() {
  gi "$1" | sed -n 's/.*fragments: //p; s/^Already up to date: \.gitignore (\(.*\))$/\1/p'
}

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
  # The scripts write to `$PREFIX$REPORT_PATH`. A PREFIX of `.` joined `./reports` into
  # `../reports`, so a local run wrote outside the project and this entry ignored nothing.
  printf 'include %s\nprint-report-root: ; @printf %%s "$(PREFIX)$(REPORT_PATH)"\n' \
    "$SCRIPTS_DIR/makefiles/$lang.mk" > "$TEST_DIR/report-root-$lang.mk"
  report_root="$(cd "$OVERRIDER" && env -u PREFIX -u REPORT_PATH \
    make -s -f "$TEST_DIR/report-root-$lang.mk" print-report-root SCRIPTS_DIR="$SCRIPTS_DIR")"
  assert_true "$lang writes its reports where that entry points: \$PREFIX\$REPORT_PATH is ./reports" \
    "[ '$report_root' = './reports' ]"
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
#
# `php` and `ruby` have no `.mk`, but a project's CI can still import their pipelines, and
# then the same question applies: their one script each (`phpmd/run.sh`, `debride/run.sh`)
# writes under REPORT_PATH, so they need nothing either.
WRITES_ONLY_REPORTS='dotnet java javascript php ruby'
for mk in "$SCRIPTS_DIR"/makefiles/*.mk; do
  lang="$(basename "$mk" .mk)"
  case " $WRITES_ONLY_REPORTS " in *" $lang "*) continue ;; esac
  assert_true "$lang ships a fragment, or belongs on the writes-only-reports list" \
    "[ -f '$SCRIPTS_DIR/global/gitignore/$lang' ]"
done

echo ""
echo "Fragment selection from the pipeline the CI imports"
# The Makefile is only one place a project names its language. Many name it only in their
# CI -- no Makefile at all, or one that includes `common.mk` alone -- and those stages write
# the same files as `make` does, so the pipeline the CI imports selects fragments too.
GHA="$TEST_DIR/github-reusable-workflow"
ci_repo "$GHA" .github/workflows/default.yaml "jobs:
  default:
    uses: 'rios0rios0/pipelines/.github/workflows/go-binary.yaml@main'"
gi "$GHA" > /dev/null
assert_true "a GitHub reusable workflow names its language, with no Makefile" \
  "grep -qxF '/junit-unit.xml' '$GHA/.gitignore'"

GHC="$TEST_DIR/github-composite-action"
ci_repo "$GHC" .github/workflows/ci.yml "steps:
  - uses: rios0rios0/pipelines/github/python/stages/10-code-check/pdm-lint@main"
gi "$GHC" > /dev/null
assert_true "a GitHub composite action names its language by its directory" \
  "grep -qxF '__pycache__/' '$GHC/.gitignore'"

ADO="$TEST_DIR/azure-devops-template"
ci_repo "$ADO" azure-pipelines.yml "stages:
  - template: 'azure-devops/terra/terra.yaml@pipelines'"
gi "$ADO" > /dev/null
assert_true "an Azure Pipelines template names its language by its directory" \
  "grep -qxF '/build/.terraform-plugin-cache/' '$ADO/.gitignore'"

ADOALIAS="$TEST_DIR/azure-devops-other-alias"
ci_repo "$ADOALIAS" azure-pipelines.yaml "stages:
  - template: azure-devops/golang/go-docker.yml@shared"
assert_true "whatever alias the repository resource has, and with no quotes" \
  "[ \"\$(fragments_of '$ADOALIAS')\" = 'common,golang' ]"

GLR="$TEST_DIR/gitlab-remote-include"
ci_repo "$GLR" .gitlab-ci.yml "include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/dart/dart-library.yaml'"
gi "$GLR" > /dev/null
assert_true "a GitLab remote include names its language by its directory" \
  "grep -qxF '/coverage/' '$GLR/.gitignore'"

GLP="$TEST_DIR/gitlab-project-include"
ci_repo "$GLP" .gitlab-ci.yml "include:
  - project: 'rios0rios0/pipelines'
    file: '/gitlab/terraform/terra.yaml'"
assert_true "and so does a GitLab project include, by its file path" \
  "[ \"\$(fragments_of '$GLP')\" = 'common,terraform' ]"

NEUTRAL="$TEST_DIR/language-neutral-ci"
ci_repo "$NEUTRAL" .github/workflows/default.yaml "jobs:
  checks:
    uses: 'rios0rios0/pipelines/.github/workflows/checks.yaml@main'
  review:
    uses: 'rios0rios0/pipelines/.github/workflows/reusable-claude-review.yaml@main'
  release:
    steps:
      - uses: 'rios0rios0/pipelines/github/global/stages/40-delivery/release@main'"
assert_true "a CI that imports no language pipeline gets common alone" \
  "[ \"\$(fragments_of '$NEUTRAL')\" = 'common' ]"

DEFINES="$TEST_DIR/defines-a-pipeline"
ci_repo "$DEFINES" .github/workflows/go.yaml "on:
  workflow_call:
jobs:
  lint:
    steps:
      - uses: 'rios0rios0/pipelines/github/golang/stages/10-code-check/golangci-lint@main'"
assert_true "a reusable workflow defines a pipeline rather than importing one, so it names nothing" \
  "[ \"\$(fragments_of '$DEFINES')\" = 'common' ]"

BOTH="$TEST_DIR/makefile-and-ci"
make_repo "$BOTH" python
mkdir -p "$BOTH/.github/workflows"
printf '%s\n' "jobs:" "  default:" "    uses: 'rios0rios0/pipelines/.github/workflows/go-docker.yaml@main'" \
  > "$BOTH/.github/workflows/default.yaml"
assert_true "the Makefile and the CI add up, in name order after common" \
  "[ \"\$(fragments_of '$BOTH')\" = 'common,golang,python' ]"
assert_true "and the result is stable" \
  "gi '$BOTH' | grep -q '^Already up to date'"

SAME="$TEST_DIR/ci-adds-nothing"
make_repo "$SAME" golang
ci_repo "$SAME" .github/workflows/default.yaml "jobs:
  default:
    uses: 'rios0rios0/pipelines/.github/workflows/go-binary.yaml@main'"
cp "$REPO/.gitignore" "$TEST_DIR/makefile-only"
sed -i '/^# <<< pipelines:end$/q' "$TEST_DIR/makefile-only"
gi "$SAME" > /dev/null
assert_true "a CI naming the Makefile's language leaves the block exactly as the Makefile alone made it" \
  "cmp -s '$SAME/.gitignore' '$TEST_DIR/makefile-only'"

echo ""
echo "Every CI language directory and reusable workflow is a recorded decision"
# A language directory names its language directly, and a fragment-less language is skipped as
# silently as a fragment-less `.mk`, so each directory has to be the same decision written
# down: a fragment, the writes-only-reports list above, or this one. `global` holds the shared
# stages, and Argo CD, Helm and Logstash are deployment pipelines rather than languages, which
# write nothing outside `build/reports/` either.
NOT_A_LANGUAGE='global argocd helm logstash'
for directory in "$SCRIPTS_DIR"/github/*/ "$SCRIPTS_DIR"/azure-devops/*/ "$SCRIPTS_DIR"/gitlab/*/; do
  lang="$(basename "$directory")"
  platform="$(basename "$(dirname "$directory")")"
  is_listed "$lang" "$NOT_A_LANGUAGE $WRITES_ONLY_REPORTS" && continue
  assert_true "$platform/$lang ships a fragment, or belongs on the not-a-language or writes-only-reports list" \
    "[ -f '$SCRIPTS_DIR/global/gitignore/$lang' ]"
done

# A reusable workflow is named by toolchain instead, so its language comes from the
# generator's TOOLCHAIN_LANGUAGES, which a new workflow can be missing from. Each one must
# name a language there, or be on this list of the reusable workflows that are not a
# language pipeline: the language-neutral checks, the release, the dependency-update and
# major-version-tag maintenance, and the Claude reviews, whose `reusable-` is a marker
# rather than a toolchain (`STANDALONE` in `test-workflow-composition.sh`).
NOT_A_TOOLCHAIN='checks dependency release reusable update'
TOOLCHAINS="$(sed -n "s/^TOOLCHAIN_LANGUAGES='\(.*\)'\$/\1/p" "$RUN_SH")"
assert_true "the generator's toolchain list can be read" "[ -n '$TOOLCHAINS' ]"
for workflow in "$SCRIPTS_DIR"/.github/workflows/*.yaml; do
  grep -Eq '^[[:space:]]*workflow_call:' "$workflow" || continue
  name="$(basename "$workflow" .yaml)"
  toolchain="${name%%-*}"
  is_listed "$toolchain" "$NOT_A_TOOLCHAIN" && continue
  lang=''
  for pair in $TOOLCHAINS; do
    [ "${pair%%:*}" = "$toolchain" ] && lang="${pair#*:}"
  done
  assert_true "$name.yaml names a language through its toolchain ($toolchain), or belongs on the not-a-toolchain list" \
    "[ -n '$lang' ]"
  [ -f "$SCRIPTS_DIR/global/gitignore/$lang" ] || continue
  CALLER="$TEST_DIR/calls-$name"
  ci_repo "$CALLER" .github/workflows/ci.yaml "jobs:
  default:
    uses: 'rios0rios0/pipelines/.github/workflows/$name.yaml@main'"
  assert_true "a project calling $name.yaml gets the $lang fragment" \
    "[ \"\$(fragments_of '$CALLER')\" = 'common,$lang' ]"
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
# `.semgrepignore` is not a report: the Semgrep runner copies its default into the
# project root when the project ships none, and four install-failure paths -- plus any
# interruption of the scan -- return before the line that removes it again. It then sits
# there untracked, waiting for a `git add -A`, which is how it came close to being
# committed in a consumer.
for artifact in build/reports/x.json reports/x.json .codeql-db/x .semgrepignore .ansible/collections/x coverage.out \
                coverage.txt coverage.xml cobertura.xml junit.xml junit-unit.xml \
                junit-integration.xml unit_coverage.txt integration_coverage.txt go-test-selection.txt \
                bin/golangci-lint bin/.golangci-lint.Ab12Cd .go/pkg/mod/cache/download/x; do
  assert_true "git ignores $artifact" \
    "git -C '$REPO' check-ignore -q --no-index '$artifact'"
done

# `make lint` installs golangci-lint into `./bin`, but the rest of `bin/` is the project's own:
# a Go service builds its binaries there, and whether it tracks them is not the block's call.
# Asked of a Go project with no entries of its own, since the one above ignores `bin` itself.
BINREPO="$TEST_DIR/go-bin-project"
make_repo "$BINREPO" golang
gi "$BINREPO" > /dev/null
assert_true "a Go project ignores the golangci-lint that make lint installs" \
  "git -C '$BINREPO' check-ignore -q --no-index bin/golangci-lint"
assert_true "and the name it stages the binary under while it installs" \
  "git -C '$BINREPO' check-ignore -q --no-index bin/.golangci-lint.Ab12Cd"
assert_true "but not the project's own bin/ output" \
  "! git -C '$BINREPO' check-ignore -q --no-index bin/service"

# A project that wants to track its OWN `.semgrepignore` must still be able to, since the
# runner copies its default only when the file is absent.
printf '\n!.semgrepignore\n' >> "$REPO/.gitignore"
assert_true "a project can still track its own .semgrepignore" \
  "! git -C '$REPO' check-ignore -q --no-index .semgrepignore"
sed -i '/^!\.semgrepignore$/d' "$REPO/.gitignore"

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
echo "A python project ignores what an instrumented run leaves behind"
# The three entries below were written by hand in a consumer before they lived here, which
# is the signal that they belong to the language rather than to that repository. `.coverage`
# is the one that bites: `pytest-cov` writes it to the working directory, not under
# REPORT_PATH, so the `/reports/` entry above does not reach it and `git add -A` after a
# test run stages a binary SQLite database.
PYREPO="$TEST_DIR/python-artefacts"
make_repo "$PYREPO" "python"
gi "$PYREPO" > /dev/null 2>&1
mkdir -p "$PYREPO/helper/__pycache__"
: > "$PYREPO/helper/__pycache__/mod.cpython-312.pyc"
: > "$PYREPO/.coverage"
: > "$PYREPO/.coverage.host.1234.567"

assert_true "bytecode under any __pycache__ is ignored" \
  "git -C '$PYREPO' check-ignore -q helper/__pycache__/mod.cpython-312.pyc"
assert_true "the pytest-cov database is ignored" \
  "git -C '$PYREPO' check-ignore -q .coverage"
assert_true "and so are the per-process files xdist writes beside it" \
  "git -C '$PYREPO' check-ignore -q .coverage.host.1234.567"
assert_true "nothing in the python block reaches a project that is not python" \
  "! git -C '$REPO' check-ignore -q --no-index .coverage"

echo ""
echo "======================================"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All tests passed."
