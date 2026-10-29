#!/usr/bin/env bash
#
# This repository runs no Python of its own.
#
# Its scripts run in every consumer's CI, so a helper here is code every consumer executes. Large
# Python helpers that change rarely are a weakness there -- an interpreter and a standard library
# nobody here pins, and code nobody here type-checks -- and they were all rewritten: the helpers
# are Go (the root module, built from the checkout on every run by
# `global/scripts/shared/go-helper.sh`) or POSIX shell, and this suite keeps it that way.
#
# Python stays where it is really needed, and nowhere else:
#
#   * the Python PIPELINES -- the templates, scripts, makefile and images that build consumers'
#     Python projects (PDM, Safety, vulture, cyclonedx-py). Python is what they build;
#   * Semgrep and Checkov, Python programs with no binary release. Each runner creates a
#     virtualenv of its own (`python3 -m venv`) and installs the pinned release into it with that
#     virtualenv's pip;
#   * one question to Checkov's HCL parser, bc-python-hcl2, which exists only as a Python library
#     inside Checkov's virtualenv: where it stopped in a file it could not parse.
#
# The last two are listed below line by line, so a new use of Python in those runners fails here
# as it would anywhere else, and a listed line that no longer exists fails too, so the list cannot
# outlive what it excuses.
#
# Asserts:
#   1. no tracked Python source (`*.py`, `*.pyi`, `*.pyw`, `*.ipynb`) and no Python shebang;
#   2. no interpreter run, no pip / pipx / uv install and no OS package of Python, in any tracked
#      file outside the Python pipelines but the listed lines -- comments and prose aside;
#   3. the question to Checkov's parser stays a question: a short heredoc, asked once;
#   4. every check fires: each runs against fixtures that break it, and against prose that must
#      not trip it.

set -u

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}  PASS: $1${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}  FAIL: $1${NC}"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/        /'; TESTS_FAILED=$((TESTS_FAILED + 1)); }
assert_empty() { # assert_empty <description> <findings>
  if [[ -z "$2" ]]; then pass "$1"; else fail "$1" "$2"; fi
}
assert_contains() { # assert_contains <description> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "no '$3' in: $2"; fi
}
assert_not_contains() { # assert_not_contains <description> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "unexpected '$3' in: $2"; fi
}

# The pipelines that build consumers' Python projects: Python is their subject.
PYTHON_PIPELINES='^(gitlab|azure-devops|github)/python/|^makefiles/python\.mk$|^global/scripts/languages/python/|^global/containers/python\.[^/]+/|^global/gitignore/python$|^\.github/workflows/pdm(-[a-z]+)?\.yaml$|^\.github/tests/test-python-cyclonedx\.sh$'

# Files that only describe: prose, the changelog and its fragments, and this suite, whose
# fixtures are the very patterns it forbids.
DESCRIPTIVE='\.md$|^\.changes/|^CHANGELOG\.md$|^LICENSE$|^\.github/tests/test-no-python\.sh$'

# Running Python, in a line of shell, YAML, a Makefile or a Dockerfile: an interpreter given an
# argument (a flag, a quoted or `$` path, a redirect, a path, a `.py` file) or fed a pipe; a
# virtualenv's interpreter or pip; a pip, pipx or uv install; Python installed as an OS package.
# Prose naming the interpreter ("install python3 and re-run", `command -v python3`) is not an
# argument list, so it does not match.
INVOCATION='(^|[^[:alnum:]_./-])python[0-9.]*[[:space:]]+(-|"|'"'"'|\$|<|[^[:space:]]*/|[^[:space:]]*\.py([[:space:]]|$))'
INVOCATION+='|\|[[:space:]]*python[0-9.]*([[:space:]]|$)'
INVOCATION+='|bin/(python|pip)[0-9.]*([^[:alnum:]_.-]|$)'
INVOCATION+='|(^|[^[:alnum:]_-])(pip[0-9.]*|pipx)[[:space:]]+(install|run)'
INVOCATION+='|(^|[^[:alnum:]_-])uvx[[:space:]]|(^|[^[:alnum:]_-])uv[[:space:]]+(pip|run|tool)'
INVOCATION+='|(apt-get|apt|apk|dnf|yum|brew)[[:space:]][^#]*[[:space:]]python[0-9.]*(-[[:alnum:]]+)?([[:space:]]|$)'

# A Go program running an interpreter.
GO_INVOCATION='exec\.Command(Context)?\([^)]*"(python|pip)[0-9.]*"'

# The lines that may touch Python outside the pipelines, each with the reason it has to, keyed by
# file and compared after leading whitespace is trimmed.
EXCUSED=(
  'global/scripts/tools/semgrep/run.sh|[ -x "$SEMGREP_VENV/bin/python" ] || return 1|Semgrep is a Python program: its virtualenv must exist'
  'global/scripts/tools/semgrep/run.sh|if [ ! -x "$SEMGREP_VENV/bin/pip" ] && ! python3 -m venv "$SEMGREP_VENV"; then|Semgrep ships no binary: it gets a virtualenv of its own'
  'global/scripts/tools/semgrep/run.sh|if ! _sg_pip_log=$("$SEMGREP_VENV/bin/pip" install --disable-pip-version-check --only-binary :all: "$SEMGREP_SPEC" 2>&1); then|...and the pinned release, binary-only'
  'global/scripts/tools/checkov/run.sh|if [ ! -x "$CHECKOV_VENV/bin/pip" ] && ! python3 -m venv "$CHECKOV_VENV"; then|Checkov ships no binary: it gets a virtualenv of its own'
  'global/scripts/tools/checkov/run.sh|if ! _ck_pip_log=$("$CHECKOV_VENV/bin/pip" install --disable-pip-version-check --only-binary :all: "$_ck_wheel" 2>&1); then|...and the verified wheel, binary-only'
  "global/scripts/tools/checkov/run.sh|\"\$CHECKOV_VENV/bin/python\" - \"\$@\" > \"\$_ck_diagnosis/records\" <<'PY'|the parser Checkov uses is a Python library in Checkov's virtualenv"
  ".github/tests/test-checkov.sh|cat > \"\$VENV/bin/python\" <<'STUB'|a stand-in for Checkov's interpreter, which runs no Python"
  ".github/tests/test-checkov.sh|cat > \"\$VENV/bin/pip\" <<'STUB'|a stand-in for Checkov's pip"
  '.github/tests/test-checkov.sh|chmod +x "$VENV/bin/python" "$VENV/bin/pip" "$VENV/bin/checkov" "$STUB_HOME/.local/bin/curl"|...made executable'
  ".github/tests/test-supply-chain.sh|| xargs -0 grep -HnE 'pip install ' 2>/dev/null \\|it searches for every pip install, to assert each is pinned"
  ".github/tests/test-supply-chain.sh|assert_empty \"every 'pip install' names a version\" \"\$PIP_UNPINNED\"|...and names what it found"
)

# The question to Checkov's parser: one heredoc, at most this many lines. Anything longer is no
# longer a question -- it is a helper, and belongs in Go or shell.
PARSER_QUESTION_MAX_LINES=30

# tracked_files <root> -- every file git tracks under <root>, one path per line, relative to it.
tracked_files() {
  git -C "$1" ls-files 2> /dev/null
}

# python_findings <root> -- one line per breach of rules 1 to 3 in the tree at <root>.
python_findings() {
  local root="$1" path line number text entry excuse_file excuse_line excused status
  declare -A seen=()

  while IFS= read -r path; do
    [[ -f "$root/$path" ]] || continue
    case "$path" in
      *.py | *.pyi | *.pyw | *.ipynb) echo "$path: a Python source file" ;;
    esac
    if head -n 1 "$root/$path" 2> /dev/null | grep -qE '^#!.*python'; then
      echo "$path: a Python shebang"
    fi
    if [[ "$path" =~ $PYTHON_PIPELINES || "$path" =~ $DESCRIPTIVE ]]; then
      continue
    fi
    if [[ "$path" == *.go ]]; then
      grep -I -n -E "$GO_INVOCATION" "$root/$path" 2> /dev/null | sed "s|^|$path:|;s|$| -- runs Python|"
      continue
    fi
    while IFS= read -r line; do
      number="${line%%:*}"
      text="${line#*:}"
      text="${text#"${text%%[![:space:]]*}"}"
      [[ "$text" == \#* ]] && continue
      excused=false
      for entry in "${EXCUSED[@]}"; do
        excuse_file="${entry%%|*}"
        excuse_line="${entry#*|}"
        excuse_line="${excuse_line%|*}"
        if [[ "$excuse_file" == "$path" && "$excuse_line" == "$text" ]]; then
          excused=true
          seen["$entry"]=1
        fi
      done
      [[ "$excused" == true ]] || echo "$path:$number: $text -- runs Python"
    done < <(grep -I -n -E "$INVOCATION" "$root/$path" 2> /dev/null)
  done < <(tracked_files "$root")

  # An excuse whose line is gone is reported, so the list cannot outlive what it excuses.
  for entry in "${EXCUSED[@]}"; do
    excuse_file="${entry%%|*}"
    excuse_line="${entry#*|}"
    excuse_line="${excuse_line%|*}"
    if [[ -f "$root/$excuse_file" && -z "${seen["$entry"]:-}" ]]; then
      echo "$excuse_file: the excused line '$excuse_line' is gone -- remove it from EXCUSED in .github/tests/test-no-python.sh"
    fi
  done

  # The question to Checkov's parser: one heredoc, short.
  if [[ -f "$root/global/scripts/tools/checkov/run.sh" ]]; then
    status="$(awk -v max="$PARSER_QUESTION_MAX_LINES" '
      /bin\/python" - .*<<.PY.$/ { inside = 1; questions++; next }
      inside && /^PY$/ { inside = 0; next }
      inside { lines++ }
      END {
        if (questions != 1) print "asks the parser " questions + 0 " times; the runner asks it once"
        else if (lines > max) print "asks the parser in " lines " lines of Python, over the " max " a question needs"
      }
    ' "$root/global/scripts/tools/checkov/run.sh")"
    [[ -n "$status" ]] && echo "global/scripts/tools/checkov/run.sh: $status"
  fi
}

echo "=========================================="
echo "No-Python validation"
echo "=========================================="

if ! tracked_files "$SCRIPTS_DIR" > /dev/null || [[ -z "$(tracked_files "$SCRIPTS_DIR")" ]]; then
  echo -e "${RED}This suite reads what git tracks, and $SCRIPTS_DIR is not a git work tree.${NC}"
  exit 1
fi

echo ""
echo "--- 1-3. The repository ---"

FINDINGS="$(python_findings "$SCRIPTS_DIR")"
assert_empty "no Python source, shebang or interpreter run outside the Python pipelines and the listed lines" "$FINDINGS"

echo ""
echo "--- 4. The checks fire ---"

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT
FIXTURE="$WORK/repo"
mkdir -p "$FIXTURE" || exit 1

# fixture <path> <content> -- a tracked file in the fixture repository
fixture() {
  mkdir -p "$(dirname "$FIXTURE/$1")" && printf '%s\n' "$2" > "$FIXTURE/$1" && git -C "$FIXTURE" add -- "$1"
}
git -C "$FIXTURE" init -q || exit 1

# Each of these breaks a rule, and must be named.
fixture 'helpers/report.py' 'print("a helper")'
fixture 'helpers/run' $'#!/usr/bin/env python3\nprint("a script")'
fixture 'scripts/inline.sh' "python3 -c 'import json'"
fixture 'scripts/heredoc.sh' $'python3 - "$DIR" <<\'PY\'\nprint(1)\nPY'
fixture 'scripts/piped.sh' 'echo "$data" | python3'
fixture 'scripts/venv.sh' '"$VENV/bin/python" -m json.tool < report.json'
fixture 'scripts/tool.sh' 'uvx yamllint .'
fixture 'scripts/run.mk' $'gen:\n\tpython3 tools/gen.py'
fixture '.github/workflows/ci.yaml' $'jobs:\n  x:\n    steps:\n      - run: sudo apt-get install -y python3 python3-yaml make\n      - run: pip install pyyaml'
fixture 'images/Dockerfile' 'RUN apk add --no-cache git python3'
fixture 'cmd/main.go' 'func main() { _ = exec.Command("python3", "-c", "x").Run() }'

# None of these does, and none may be named.
fixture 'scripts/prose.sh' $'# python3 -c is described in a comment\necho "ERROR: install python3 and re-run."\ncommand -v python3 > /dev/null || exit 1\nimage=python:3.13-slim\necho "sonar.python.coverage.reportPaths=" >> sonar-project.properties'
fixture 'gitlab/python/stages/lint.yaml' $'lint:\n  script:\n    - python -m pip install --user vulture'
fixture 'README.md' $'Run `python3 -c "print(1)"` -- or rather, do not.'
fixture 'tools/scan.go' 'var pins = regexp.MustCompile(`pip install[^"]*"pdm==([0-9.]+)"`)'

OUT="$(python_findings "$FIXTURE")"
for breach in 'helpers/report.py: a Python source file' 'helpers/run: a Python shebang' \
  'scripts/inline.sh:1:' 'scripts/heredoc.sh:1:' 'scripts/piped.sh:1:' 'scripts/venv.sh:1:' \
  'scripts/tool.sh:1:' 'scripts/run.mk:2:' '.github/workflows/ci.yaml:4:' '.github/workflows/ci.yaml:5:' \
  'images/Dockerfile:1:' 'cmd/main.go:1:'; do
  assert_contains "fires on '${breach%%:*}' (${breach#*: })" "$OUT" "$breach"
done
for innocent in 'scripts/prose.sh' 'gitlab/python/' 'README.md' 'tools/scan.go'; do
  assert_not_contains "does not fire on '$innocent'" "$OUT" "$innocent"
done

# The listed lines excuse exactly themselves: a new use of Python beside them is named, and a
# listed line that is gone is named too.
mkdir -p "$FIXTURE/global/scripts/tools/semgrep" "$FIXTURE/global/scripts/tools/checkov" || exit 1
cp "$SCRIPTS_DIR/global/scripts/tools/semgrep/run.sh" "$FIXTURE/global/scripts/tools/semgrep/run.sh"
cp "$SCRIPTS_DIR/global/scripts/tools/checkov/run.sh" "$FIXTURE/global/scripts/tools/checkov/run.sh"
git -C "$FIXTURE" add -- global
OUT="$(python_findings "$FIXTURE")"
assert_not_contains "the Semgrep and Checkov runners as they are need nothing but the listed lines" "$OUT" "global/scripts/tools/"
printf '%s\n' '_sg_version=$("$SEMGREP_VENV/bin/python" -c "import semgrep")' >> "$FIXTURE/global/scripts/tools/semgrep/run.sh"
OUT="$(python_findings "$FIXTURE")"
assert_contains "a new use of Python in a listed runner is named" "$OUT" 'global/scripts/tools/semgrep/run.sh:'
assert_contains "...as running Python" "$OUT" '-c "import semgrep") -- runs Python'
sed -i 's|! python3 -m venv "\$CHECKOV_VENV"|! python3 -m venv --upgrade-deps "$CHECKOV_VENV"|' "$FIXTURE/global/scripts/tools/checkov/run.sh"
OUT="$(python_findings "$FIXTURE")"
assert_contains "a listed line that changed is named, since it no longer matches its excuse" "$OUT" \
  'python3 -m venv --upgrade-deps "$CHECKOV_VENV"; then -- runs Python'
assert_contains "...and the excuse it outlived is named as stale" "$OUT" "the excused line 'if [ ! -x \"\$CHECKOV_VENV/bin/pip\" ] && ! python3 -m venv \"\$CHECKOV_VENV\"; then' is gone"

cp "$SCRIPTS_DIR/global/scripts/tools/checkov/run.sh" "$FIXTURE/global/scripts/tools/checkov/run.sh"
awk -v max="$PARSER_QUESTION_MAX_LINES" '{ print } /bin\/python" - .*<<.PY.$/ { for (i = 0; i <= max; i++) print "pass" }' \
  "$SCRIPTS_DIR/global/scripts/tools/checkov/run.sh" > "$FIXTURE/global/scripts/tools/checkov/run.sh"
OUT="$(python_findings "$FIXTURE")"
assert_contains "the question to Checkov's parser may not grow into a helper" "$OUT" "lines of Python, over the $PARSER_QUESTION_MAX_LINES a question needs"

echo ""
echo "=========================================="
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}No-Python validation FAILED${NC}"
  exit 1
fi
echo -e "${GREEN}No-Python validation passed${NC}"
exit 0
