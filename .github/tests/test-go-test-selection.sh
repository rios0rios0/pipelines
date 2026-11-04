#!/usr/bin/env bash
# Tests for the Go runner's test selection (GO_TEST_SELECTION, selection.sh).
#
# `affected` runs only the packages a change can reach: the packages whose files
# it touched and every package whose dependency closure holds one of them. Every
# case drives the real run.sh against a fixture module of three packages,
# a <- b <- c (b imports a, c imports b), committed to a git repository whose
# `main` is the base, and asserts on what actually ran: the test cases in the
# merged junit.xml, each unit test named TestUnit<package> and each integration
# test TestInteg<package> (an untagged unit test also runs in the integration
# phase of a package that phase selects, so the names are compared as a set).
# The last checks pin the `test_selection` input that
# carries the mode on GitHub Actions.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_SH="$SCRIPT_DIR/global/scripts/languages/golang/test/run.sh"
EXIT_CODE=0
PASSED=0

echo "[test-go-test-selection] testing the Go runner's test selection..." >&2

if ! command -v go > /dev/null 2>&1; then
    echo "[test-go-test-selection] SKIP: go is not on PATH." >&2
    exit 0
fi

SANDBOX="$(mktemp -d)" || exit 1
trap '[ -n "${KEEP_SANDBOX:-}" ] || rm -rf "$SANDBOX"' EXIT

pass() { PASSED=$((PASSED + 1)); echo "[test-go-test-selection] PASS: $1" >&2; }
fail() { EXIT_CODE=1; echo "[test-go-test-selection] FAIL: $1" >&2; }

check() {
    local description="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description"
        echo "    expected: [$expected]" >&2
        echo "    actual:   [$actual]" >&2
    fi
}

# A fixture commit must not depend on the machine: no identity, signing key or
# commit hook of the user's own configuration.
fixture_git() { git -C "$FIXTURE" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null -c init.defaultBranch=main "$@"; }

FIXTURE="$SANDBOX/module"
mkdir -p "$FIXTURE/internal/a/data" "$FIXTURE/internal/b" "$FIXTURE/internal/c"
cat > "$FIXTURE/go.mod" << 'EOF'
module example.com/selection

go 1.25
EOF
printf '# fixture\n' > "$FIXTURE/README.md"
printf 'one\n' > "$FIXTURE/internal/a/data/greeting.txt"
cat > "$FIXTURE/internal/a/a.go" << 'EOF'
package a

import _ "embed"

//go:embed data/greeting.txt
var greeting string

func A() string { return greeting }
EOF
cat > "$FIXTURE/internal/b/b.go" << 'EOF'
package b

import "example.com/selection/internal/a"

func B() string { return a.A() }
EOF
cat > "$FIXTURE/internal/c/c.go" << 'EOF'
package c

import "example.com/selection/internal/b"

func C() string { return b.B() }
EOF
for package in a b c; do
    upper="$(printf '%s' "$package" | tr '[:lower:]' '[:upper:]')"
    cat > "$FIXTURE/internal/$package/${package}_test.go" << EOF
package ${package}

import "testing"

func TestUnit${upper}(t *testing.T) {
	if ${upper}() == "" {
		t.Fatal("empty")
	}
}
EOF
done
# Integration tests in a and c only, so the integration phase's own narrowing
# (packages that gain files under the tag) meets the selection.
for package in a c; do
    upper="$(printf '%s' "$package" | tr '[:lower:]' '[:upper:]')"
    cat > "$FIXTURE/internal/$package/${package}_integration_test.go" << EOF
//go:build integration

package ${package}

import "testing"

func TestInteg${upper}(t *testing.T) {
	if ${upper}() == "" {
		t.Fatal("empty")
	}
}
EOF
done
# Two documents a test pins to the code: b's tests name the runbook by its path
# from the repository's top, c's name the handbook by its bare file name. The
# README is named by no test.
mkdir -p "$FIXTURE/.docs" "$FIXTURE/docs/guide"
printf '# runbook\n' > "$FIXTURE/.docs/runbook.md"
printf '# handbook\n' > "$FIXTURE/docs/guide/handbook.md"
cat > "$FIXTURE/internal/b/doc_test.go" << 'EOF'
package b

import "testing"

func TestDocB(t *testing.T) {
	if len(".docs/runbook.md") == 0 {
		t.Fatal("empty")
	}
}
EOF
cat > "$FIXTURE/internal/c/doc_test.go" << 'EOF'
package c

import "testing"

func TestDocC(t *testing.T) {
	if len("handbook.md") == 0 {
		t.Fatal("empty")
	}
}
EOF
# Documentation inside packages: a golden file under a's testdata/, which a test
# would open by a path relative to its package, and c's own README.
mkdir -p "$FIXTURE/internal/a/testdata"
printf '# golden\n' > "$FIXTURE/internal/a/testdata/golden.md"
printf '# package c\n' > "$FIXTURE/internal/c/README.md"
EVERY_TEST="TestDocB TestDocC TestIntegA TestIntegC TestUnitA TestUnitB TestUnitC"
fixture_git init -q
fixture_git add -A
fixture_git commit -q -m 'base'

# Each case branches off main, commits its change, and runs the runner with the
# mode and base given. Prints the test cases junit.xml recorded, sorted.
run_case() { # run_case <case> <mode> <base> <change command...>
    local name="$1" mode="$2" base="$3" log="$SANDBOX/$1.log"
    shift 3
    fixture_git checkout -q main
    fixture_git checkout -q -b "case-$name"
    (cd "$FIXTURE" && "$@") || { fail "the change of case $name could not be made"; return; }
    fixture_git add -A
    fixture_git commit -q -m "$name" --allow-empty
    (cd "$FIXTURE" && GO_TEST_SELECTION="$mode" GO_TEST_SELECTION_BASE="$base" "$RUN_SH") > "$log" 2>&1
    echo "$?" > "$SANDBOX/$name.rc"
    # What the run left behind is read from copies: the next case starts clean.
    cp "$FIXTURE/junit.xml" "$SANDBOX/$name.junit" 2> /dev/null || : > "$SANDBOX/$name.junit"
    cp "$FIXTURE/go-test-selection.txt" "$SANDBOX/$name.selection" 2> /dev/null || :
    fixture_git clean -qfdx
}
ran() { grep -o 'testcase[^>]*name="Test[A-Za-z]*"' "$SANDBOX/$1.junit" 2> /dev/null \
    | sed 's/.*name="//; s/"$//' | sort -u | tr '\n' ' ' | sed 's/ $//'; }
rc() { cat "$SANDBOX/$1.rc"; }

echo "== a change in a reaches every package that depends on it ==" >&2
run_case change-a affected main sh -c 'printf "func Extra() int { return 1 }\n" >> internal/a/a.go'
check "a change in a runs the unit and integration tests of a, b and c" \
    "$(ran change-a)" "$EVERY_TEST"
check "the runner passes when a changes" "$(rc change-a)" "0"
check "the runner logs the package the change touches" \
    "$(grep -A1 'Packages the change touches:$' "$SANDBOX/change-a.log" | tail -1)" \
    "  example.com/selection/internal/a"
check "the runner logs three packages affected in the unit phase" \
    "$(grep -c '^Test selection: 3 package(s) affected in the unit phase$' "$SANDBOX/change-a.log")" "1"
check "the runner logs two packages affected in the integration phase" \
    "$(grep -c '^Test selection: 2 package(s) affected in the integration phase$' "$SANDBOX/change-a.log")" "1"
check "the runner says the partial coverage is not enforced" \
    "$(grep -c 'no coverage threshold is enforced' "$SANDBOX/change-a.log")" "1"
check "the runner records the narrowed run for the coverage gate" \
    "$(cat "$SANDBOX/change-a.selection" 2> /dev/null)" "affected"

echo "== a change in c reaches c alone ==" >&2
run_case change-c affected main sh -c 'printf "func Extra() int { return 1 }\n" >> internal/c/c.go'
check "a change in c runs the tests of c alone" "$(ran change-c)" "TestDocC TestIntegC TestUnitC"

echo "== a file a package embeds belongs to that package ==" >&2
run_case embed affected main sh -c 'printf "two\n" > internal/a/data/greeting.txt'
check "a change to a's embedded file runs a, b and c" \
    "$(ran embed)" "$EVERY_TEST"

echo "== a go.mod change runs everything ==" >&2
run_case go-mod affected main sh -c 'printf "\n// a comment\n" >> go.mod'
check "a go.mod change runs every test" \
    "$(ran go-mod)" "$EVERY_TEST"
check "the runner says why everything ran" \
    "$(grep -c '^Test selection: all packages (go.mod changes the module definition)$' "$SANDBOX/go-mod.log")" "1"
check "an unnarrowed run leaves no record for the coverage gate" \
    "$([ -e "$SANDBOX/go-mod.selection" ] && echo present || echo absent)" "absent"

echo "== a file outside every package runs everything ==" >&2
run_case outside affected main sh -c 'printf "key: value\n" > settings.yaml'
check "a file outside every package runs every test" \
    "$(ran outside)" "$EVERY_TEST"

echo "== a documentation change runs nothing and passes ==" >&2
run_case docs affected main sh -c 'printf "more\n" >> README.md && mkdir -p .changes && printf "x\n" > .changes/note.yaml'
check "a documentation change runs no test" "$(ran docs)" ""
check "the runner passes on a documentation change" "$(rc docs)" "0"
check "the runner says the unread document selects nothing" \
    "$(grep -c '^  not code, selects nothing: README.md$' "$SANDBOX/docs.log")" "1"
check "the runner says the change touches no package" \
    "$(grep -c 'The change touches no Go package' "$SANDBOX/docs.log")" "1"
check "the runner skips the unit phase with a reason" \
    "$(grep -c '^No affected package in the unit phase - nothing to run.$' "$SANDBOX/docs.log")" "1"

echo "== a document a test names by its path selects that test's package ==" >&2
run_case doc-path affected main sh -c 'printf "more\n" >> .docs/runbook.md'
check "a document b's tests name by path runs b and what depends on it" \
    "$(ran doc-path)" "TestDocB TestDocC TestIntegC TestUnitB TestUnitC"
check "the runner names the document and the package it selected" \
    "$(grep -c '^  read by tests, selects their packages: .docs/runbook.md -> example.com/selection/internal/b$' "$SANDBOX/doc-path.log")" "1"

echo "== a document a test names by its file name selects that test's package ==" >&2
run_case doc-name affected main sh -c 'printf "more\n" >> docs/guide/handbook.md'
check "a document c's tests name by file name runs c alone" \
    "$(ran doc-name)" "TestDocC TestIntegC TestUnitC"

echo "== a document under a package's testdata/ selects that package ==" >&2
run_case testdata-doc affected main sh -c 'printf "more\n" >> internal/a/testdata/golden.md'
check "a golden file under a's testdata/ narrows the run instead of running everything" \
    "$(grep -c '^Test selection: affected packages only. Packages the change touches:$' "$SANDBOX/testdata-doc.log")" "1"
check "the golden file selects a, the package that owns it" \
    "$(awk '/^Test selection: affected packages only. Packages the change touches:$/ { getline; print; exit }' \
        "$SANDBOX/testdata-doc.log")" "  example.com/selection/internal/a"
check "a golden file under a's testdata/ runs a and what depends on it" \
    "$(ran testdata-doc)" "$EVERY_TEST"

echo "== a package's own README selects that package ==" >&2
run_case package-readme affected main sh -c 'printf "more\n" >> internal/c/README.md'
check "c's own README runs c alone" \
    "$(ran package-readme)" "TestDocC TestIntegC TestUnitC"

echo "== without a merge base, everything runs ==" >&2
run_case no-base affected refs/heads/absent sh -c 'printf "func Extra() int { return 1 }\n" >> internal/c/c.go'
check "an unknown base runs every test" \
    "$(ran no-base)" "$EVERY_TEST"
check "the runner says there is no merge base" \
    "$(grep -c 'no merge base between' "$SANDBOX/no-base.log")" "1"

echo "== 'all' ignores the base ==" >&2
run_case mode-all all main sh -c 'printf "func Extra() int { return 1 }\n" >> internal/c/c.go'
check "'all' runs every test whatever changed" \
    "$(ran mode-all)" "$EVERY_TEST"

echo "== an unknown mode fails before any test ==" >&2
run_case bogus sometimes main true
check "an unknown GO_TEST_SELECTION fails the runner" "$(rc bogus)" "1"
check "the runner names the value it refused" \
    "$(grep -c "GO_TEST_SELECTION must be 'all' or 'affected', got 'sometimes'" "$SANDBOX/bogus.log")" "1"
check "an unknown mode stops the runner before the unit phase" \
    "$(grep -c 'PHASE 1' "$SANDBOX/bogus.log")" "0"

# ── the GitHub path carries the mode as an input ──────────────────────────────
# A caller's `env:` never reaches a reusable workflow, so the mode crosses as
# `test_selection`, and the action resolves the base from the pull request.
echo "== the GitHub path threads test_selection into GO_TEST_SELECTION ==" >&2
ACTION="$SCRIPT_DIR/github/golang/stages/30-tests/all/action.yaml"
check "the test action declares test_selection" \
    "$(grep -c '^  test_selection:$' "$ACTION")" "1"
# shellcheck disable=SC2016  # the single-quoted `${{ }}` is the action's expected TEXT, never an expansion
check "the test action maps test_selection onto GO_TEST_SELECTION" \
    "$(grep -cF 'GO_TEST_SELECTION: "${{ inputs.test_selection }}"' "$ACTION")" "1"
check "the test action hands the runner a base to compare with" \
    "$(grep -c 'GO_TEST_SELECTION_BASE' "$ACTION")" "2"
check "the coverage gate reads the runner's record of a narrowed run" \
    "$(grep -c 'go-test-selection.txt' "$ACTION")" "1"
for workflow in go go-docker go-flyio go-render; do
    file="$SCRIPT_DIR/.github/workflows/$workflow.yaml"
    check "$workflow.yaml declares test_selection" \
        "$(grep -c '^      test_selection:$' "$file")" "1"
    check "$workflow.yaml forwards test_selection" \
        "$(grep -cE '^ +test_selection: "?\$\{\{ inputs\.test_selection \}\}"?$' "$file")" "1"
done

echo "" >&2
if [ "$EXIT_CODE" -eq 0 ]; then
    echo "[test-go-test-selection] all $PASSED checks passed" >&2
else
    echo "[test-go-test-selection] failures detected ($PASSED checks passed)" >&2
fi
exit "$EXIT_CODE"
