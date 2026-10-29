#!/usr/bin/env bash
#
# Validation for the step that resolves `build_env_vars` in the Cloudflare deployment workflows
# (`npm-cloudflare.yaml`, `yarn-cloudflare.yaml`, `dart-cloudflare.yaml`).
#
# The step turns `KEY=VARIABLE_NAME` lines into `KEY=<value>` lines in GITHUB_ENV, reading the
# values from `toJSON(vars)` in the job that declares the environment -- the only place an
# environment-scoped variable can be read at all. It was a Python heredoc that no suite ever ran;
# it is now bash and `jq`, and this suite runs the step EXTRACTED FROM EACH WORKFLOW, so what is
# tested is what the workflows execute, and a fourth copy cannot drift from the other three.
#
# Asserts:
#   1. the three workflows carry one identical step, wired to `toJSON(vars)` and the input;
#   2. what it writes and prints, case by case -- the expectations are what the Python it
#      replaced produced on the same inputs, byte for byte;
#   3. a runner without `jq` is refused by name, and the step runs no Python.
#
# Runs OFFLINE: it needs bash, `jq` and mikefarah/yq (to read the step out of the workflows).

set -u

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOWS=(npm-cloudflare yarn-cloudflare dart-cloudflare)

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}  PASS: $1${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}  FAIL: $1${NC}"; [[ -n "${2:-}" ]] && echo "        $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
assert_eq() { # assert_eq <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "expected $(printf '%q' "$2"), got $(printf '%q' "$3")"
  fi
}

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

YQ="$(
  # shellcheck source=/dev/null
  . "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
  # shellcheck source=/dev/null
  . "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"
  # shellcheck source=/dev/null
  . "$SCRIPTS_DIR/global/scripts/shared/resolve-yq.sh"
  resolve_yq "$WORK/yq" >&2 && printf '%s' "$YQ"
)"
[[ -n "$YQ" ]] || { echo "could not resolve mikefarah/yq; cannot run this suite" >&2; exit 1; }

# The step is the one gated on the input; every other step of these workflows has another `if:`.
STEP_SELECTOR='.jobs[].steps[] | select(.if == "inputs.build_env_vars != '"''"'")'

echo "=========================================="
echo "build_env_vars resolution validation"
echo "=========================================="

echo ""
echo "--- 1. One step, in all three workflows ---"

for workflow in "${WORKFLOWS[@]}"; do
  file="$SCRIPTS_DIR/.github/workflows/$workflow.yaml"
  "$YQ" eval "$STEP_SELECTOR | .run" "$file" > "$WORK/$workflow.sh" 2> /dev/null
  if [[ -s "$WORK/$workflow.sh" ]]; then
    pass "$workflow.yaml resolves build_env_vars in a step of its own"
  else
    fail "$workflow.yaml resolves build_env_vars in a step of its own" "no step is gated on inputs.build_env_vars"
  fi
  assert_eq "...run by bash" "bash" "$("$YQ" eval "$STEP_SELECTOR | .shell" "$file" 2> /dev/null)"
  assert_eq "...reading the variables of the job's environment" '${{ toJSON(vars) }}' \
    "$("$YQ" eval "$STEP_SELECTOR | .env.ALL_VARS" "$file" 2> /dev/null)"
  assert_eq "...and the input through env:, never spliced into the script" '${{ inputs.build_env_vars }}' \
    "$("$YQ" eval "$STEP_SELECTOR | .env.BUILD_ENV_VARS" "$file" 2> /dev/null)"
done
for workflow in yarn-cloudflare dart-cloudflare; do
  if cmp -s "$WORK/npm-cloudflare.sh" "$WORK/$workflow.sh"; then
    pass "$workflow.yaml runs exactly the step npm-cloudflare.yaml runs"
  else
    fail "$workflow.yaml runs exactly the step npm-cloudflare.yaml runs" \
      "$(diff "$WORK/npm-cloudflare.sh" "$WORK/$workflow.sh" | head -n 5)"
  fi
done

echo ""
echo "--- 2. What it writes ---"

# The repository and environment variables `toJSON(vars)` hands the step: a URL carrying `=`
# signs, an empty value, a value padded with spaces, non-ASCII text and a value on two lines.
VARS='{"API_URL":"https://api.example.com/v1?a=b=c","EMPTY":"","SPACED":"  padded  ","SENTRY":"dsn=x=y","UNI":"café ☃","ML":"line1\nline2"}'

# resolve <BUILD_ENV_VARS> [PATH] -- runs the extracted step as the runner does (`bash -eo
# pipefail`); leaves its output in OUT, its status in RC and what it appended to GITHUB_ENV in ENV
# (`<none>` when it never opened the file).
resolve() {
  rm -f "$WORK/github-env"
  RC=0
  OUT="$(env -i PATH="${2:-$PATH}" HOME="$WORK" ALL_VARS="$VARS" BUILD_ENV_VARS="$1" \
    GITHUB_ENV="$WORK/github-env" "$BASH" -eo pipefail "$WORK/npm-cloudflare.sh" 2>&1)" || RC=$?
  ENV='<none>'
  [[ -f "$WORK/github-env" ]] && ENV="$(cat "$WORK/github-env"; printf '.')" && ENV="${ENV%.}"
}

resolve 'NEXT_PUBLIC_API=API_URL'
assert_eq "a name resolves to its value, '=' signs and all" 'NEXT_PUBLIC_API=https://api.example.com/v1?a=b=c'$'\n' "$ENV"
assert_eq "...and the step says how many it resolved" 'resolved 1 variable(s) for the build' "$OUT"
assert_eq "...and succeeds" 0 "$RC"

resolve $'A=API_URL\nB=SENTRY\n\n  C = SPACED  '
assert_eq "several lines resolve in order; blank lines are skipped and each half is trimmed, the value never" \
  'A=https://api.example.com/v1?a=b=c'$'\n''B=dsn=x=y'$'\n''C=  padded  '$'\n' "$ENV"
assert_eq "...counting every line it resolved" 'resolved 3 variable(s) for the build' "$OUT"

resolve $'A=MISSING\nB=EMPTY\nC=API_URL'
assert_eq "an unset name and an empty value are both missing, and both are named at once" \
  '::error::these variables are not set for this environment: MISSING, EMPTY' "$OUT"
assert_eq "...failing the step" 1 "$RC"
assert_eq "...before anything is exported -- not even the name that did resolve" '<none>' "$ENV"

resolve 'NOEQUALS'
assert_eq "a line with no '=' names no variable, and is missing" \
  '::error::these variables are not set for this environment: ' "$OUT"
assert_eq "...failing the step" 1 "$RC"

resolve 'K=A=B'
assert_eq "a line splits on its FIRST '=' only" '::error::these variables are not set for this environment: A=B' "$OUT"

resolve $'   \n\t\n'
assert_eq "an input of blank lines resolves nothing, and says so" 'resolved 0 variable(s) for the build' "$OUT"
assert_eq "...appending only a newline, as before" $'\n' "$ENV"

resolve $'X=UNI\r'
assert_eq "a CRLF line ending is trimmed from the name, and non-ASCII values pass through" 'X=café ☃'$'\n' "$ENV"

resolve $'A = API_URL \nD=ML'
assert_eq "a value on two lines is written as it is" \
  'A=https://api.example.com/v1?a=b=c'$'\n''D=line1'$'\n''line2'$'\n' "$ENV"

resolve '=API_URL'
assert_eq "an empty key is written, and left for the runner to refuse" '=https://api.example.com/v1?a=b=c'$'\n' "$ENV"

echo ""
echo "--- 3. What it needs ---"

mkdir -p "$WORK/no-jq" || exit 1
resolve 'NEXT_PUBLIC_API=API_URL' "$WORK/no-jq"
assert_eq "a runner without jq is refused by name" '::error::resolving build_env_vars needs jq on the runner' "$OUT"
assert_eq "...failing the step before anything is exported" "1 <none>" "$RC $ENV"

mkdir -p "$WORK/no-python" || exit 1
for interpreter in python3 python; do
  printf '#!/bin/sh\necho "python was run" >&2\nexit 99\n' > "$WORK/no-python/$interpreter"
  chmod +x "$WORK/no-python/$interpreter"
done
resolve 'NEXT_PUBLIC_API=API_URL' "$WORK/no-python:$PATH"
assert_eq "the step runs no Python" "0 resolved 1 variable(s) for the build" "$RC $OUT"

echo ""
echo "=========================================="
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}build_env_vars resolution validation FAILED${NC}"
  exit 1
fi
echo -e "${GREEN}build_env_vars resolution validation passed${NC}"
exit 0
