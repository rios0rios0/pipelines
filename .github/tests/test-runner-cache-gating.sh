#!/usr/bin/env bash
set -e

# Asserts that no GitHub Actions cache in this library restores into a `$HOME`
# path on a self-hosted runner.
#
# WHY THIS EXISTS
#
# GitHub's cache service is designed for a runner that starts empty. A
# self-hosted runner does not: `$HOME` survives every job on that host, so a
# restore into `~/…` untars an archive over files that are already there. That
# is not a redundant copy, it is a FAILED one -- `tar` exits 2, the action logs
# `Failed to restore`, and the whole download is discarded after it has been
# paid for. Both observed shapes are the same defect wearing different errnos:
#
#   go     `Cannot open: File exists`      the module cache is deliberately
#                                          read-only, so tar cannot replace it
#   dart   `Cannot mkdir: Permission denied`   the unpacked SDK directory is
#                                          already there and not writable
#
# Measured on a 12-vCPU self-hosted runner, one workflow run each:
#
#   go     263-286 MB, 47-68s restore + 33-78s post-job save, PER JOB, four
#          jobs -- against 1s when a job happens to MISS the cache
#   dart   1.67 GB, 214-358s restore + 87-102s save, PER JOB, five jobs. On
#          `style:format` that is 314s of cache around 17.6s of work
#
# The dart number is the one that settles the argument. The single job whose
# restore SUCCEEDED still paid 308s for it, while a cold install of the same
# SDK straight from Google's archive took 126s in the same run. A cache slower
# than the download it replaces is not a cache.
#
# Nothing else in CI can see any of this: every one of those files is valid
# YAML, every job stayed GREEN, and the cost shows up only as a pipeline that
# is slow for no stated reason. The library had five of the six Go call sites
# fixed and the sixth (`40-delivery/binary`) missed, which is exactly the shape
# an assertion catches and review does not.
#
# WHAT IT DELIBERATELY DOES NOT CHECK
#
# `actions/setup-node` (yarn/npm) and `actions/setup-java` (maven/gradle) are
# left ON. Their caches target `$HOME` too, but their files are writable, so the
# restore SUCCEEDS -- measured at ~9s for a 58 MB yarn cache across ten jobs of
# two runs, with no failure and no post-job save. That is a genuine cache
# seeding a cold host, not a broken one, and disabling it would be a change with
# no measurement behind it. If one is ever observed failing, it belongs here.
#
# Two `actions/cache` steps are outside the rule by their PATH rather than by
# exemption, and the rule is written so that stays true without a list:
#
#   golang 30-tests/all   `${{ env.GO_BIN_DIR }}` -- 7 MB of test-tool binaries.
#                         It resolves under `$HOME`, but the files are writable
#                         and it saves a `go install` chain on every run
#   java   dependency-check  `.owasp` -- inside the workspace, which every
#                         platform wipes per job. This one is load-bearing:
#                         rebuilding the NVD database costs hours
#
# WHAT IT DOES NOT DO
#
# It does not parse YAML with a library -- PyYAML is not assumed present here,
# the same constraint `order-check`, `var-catalog` and
# `test-workflow-composition` work under. It reads the files as indented text,
# which is sufficient because every assertion is about a step's own keys. A
# step written in flow style would slip past it; none is.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPTS_DIR

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

assert_empty() {
  local description="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo -e "${RED}        $line${NC}"
    done <<< "$value"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_reports() {
  local description="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (the check did not fire)${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# `assert_reports` alone is not enough for a fixture that trips MORE THAN ONE rule.
# The inverted-gate fixtures below are also, by construction, `setup-go` steps that
# are not gated -- so the positive rule reports them too, and a bare non-empty check
# would pass with the anti-gate branch permanently dead. This asserts the count of
# findings that actually came from the branch under test.
assert_reports_n() {
  local description="$1"
  local value="$2"
  local pattern="$3"
  local want="$4"
  local got
  got="$(printf '%s\n' "$value" | grep -c -- "$pattern" || true)"
  if [[ "$got" == "$want" ]]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description (matched $got, expected $want)${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# The checker. Prints one `<file>:<line>: <finding>` per violation and nothing
# at all when the tree is clean, so the same program serves the real tree and
# the deliberate-violation fixtures below.
CHECKER="$(mktemp)"
FIXTURES="$(mktemp -d)"
trap 'rm -rf "$CHECKER" "$FIXTURES"' EXIT

cat > "$CHECKER" <<'PY'
import os
import re
import sys

# `runner.environment` is `github-hosted` or `self-hosted`. The gate is written
# against `self-hosted` on purpose: a context that resolves to neither (an empty
# string on an older runner, a future third value) must keep the cache ON for
# hosted consumers rather than silently disabling it for everyone.
GATE = "runner.environment != 'self-hosted'"
# Either quote style. GitHub Actions expressions only accept SINGLE quotes -- the
# double-quoted form is a parse error, so it cannot ship silently -- but matching both
# costs one character class and keeps the diagnostic honest about what it looks for.
ANTI_GATE = re.compile(r'runner\.environment\s*==\s*[\'"]github-hosted[\'"]')

SETUP_GO = re.compile(r"actions/setup-go@")
CACHE = re.compile(r"actions/cache(?:/restore|/save)?@")
# A `~/…` or `$HOME/…` entry -- the paths a self-hosted runner keeps between
# jobs. A path that resolves there through a variable is not matched and does
# not need to be: see the two documented cases in the header.
HOME_PATH = re.compile(r"^\s*(?:-\s*)?['\"]?(?:~|\$HOME|\$\{HOME\})/")


def indent_of(line):
    return len(line) - len(line.lstrip(' '))


def steps(lines):
    """Yield (dash_index, end_index, key_indent) for each YAML sequence item."""
    for i, line in enumerate(lines):
        match = re.match(r'^(\s*)-\s+\S', line)
        if not match:
            continue
        dash_indent = len(match.group(1))
        end = len(lines)
        for j in range(i + 1, len(lines)):
            nxt = lines[j]
            if not nxt.strip() or nxt.lstrip().startswith('#'):
                continue
            if indent_of(nxt) <= dash_indent:
                end = j
                break
        yield i, end, dash_indent + 2


def step_keys(lines, start, end, key_indent):
    """Map the step's own top-level keys to their raw value text."""
    keys = {}
    # `- uses: 'x'` puts the first key on the dash line itself.
    head = re.match(r'^\s*-\s+([A-Za-z_-]+):\s*(.*)$', lines[start])
    if head:
        keys[head.group(1)] = head.group(2).strip()
    for j in range(start + 1, end):
        line = lines[j]
        if indent_of(line) != key_indent:
            continue
        match = re.match(r'^\s*([A-Za-z_-]+):\s*(.*)$', line)
        if match:
            keys[match.group(1)] = match.group(2).strip()
    return keys


def with_block(lines, start, end, key_indent):
    """Return (key -> value, key -> [block lines]) for the step's `with:`."""
    values, blocks = {}, {}
    for j in range(start + 1, end):
        if indent_of(lines[j]) == key_indent and lines[j].lstrip().startswith('with:'):
            break
    else:
        return values, blocks
    inner = key_indent + 2
    current = None
    for k in range(j + 1, end):
        line = lines[k]
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if indent_of(line) < inner:
            break
        if indent_of(line) == inner:
            match = re.match(r'^\s*([A-Za-z_.-]+):\s*(.*)$', line)
            if match:
                current = match.group(1)
                values[current] = match.group(2).strip()
                blocks[current] = []
                continue
        if current is not None:
            blocks[current].append(line)
    return values, blocks


def scan(root):
    findings = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != '.git']
        for filename in sorted(filenames):
            if not filename.endswith(('.yaml', '.yml')):
                continue
            path = os.path.join(dirpath, filename)
            rel = os.path.relpath(path, root)
            with open(path, encoding='utf-8') as handle:
                lines = handle.read().splitlines()

            for start, end, key_indent in steps(lines):
                keys = step_keys(lines, start, end, key_indent)
                uses = keys.get('uses', '')
                if not uses:
                    continue
                values, blocks = with_block(lines, start, end, key_indent)
                where = '%s:%d' % (rel, start + 1)

                if SETUP_GO.search(uses):
                    cache = values.get('cache')
                    if cache is None:
                        findings.append(
                            '%s: actions/setup-go leaves `cache` at its default (on), so a '
                            'self-hosted runner downloads GOMODCACHE over itself and discards '
                            'it. Set `cache: ${{ %s }}`.' % (where, GATE))
                    elif cache != 'false' and GATE not in cache:
                        findings.append(
                            '%s: actions/setup-go has `cache: %s`, which is neither `false` '
                            'nor gated on `%s`.' % (where, cache, GATE))

                if CACHE.search(uses):
                    body = [values.get('path', '')] + blocks.get('path', [])
                    if any(HOME_PATH.match(entry) for entry in body if entry):
                        gate = keys.get('if', '')
                        if GATE not in gate:
                            findings.append(
                                '%s: actions/cache names a $HOME path but is not gated -- add '
                                '`if: "%s"`.' % (where, GATE))

                for label, text in (('if', keys.get('if', '')),
                                    ('cache', values.get('cache', ''))):
                    if text and ANTI_GATE.search(text):
                        findings.append(
                            "%s: gated on `== 'github-hosted'` (%s), which disables the cache "
                            'for every consumer whose runner reports neither value. Write '
                            "`!= 'self-hosted'`." % (where, label))
    return findings


if __name__ == '__main__':
    for finding in scan(sys.argv[1]):
        print(finding)
PY

echo "=========================================="
echo "Self-hosted runner cache gating"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
echo "1. no cache in this library restores into \$HOME on a self-hosted runner"
# ---------------------------------------------------------------------------
assert_empty "github/ and .github/workflows/ are clean" \
  "$(python3 "$CHECKER" "$SCRIPTS_DIR/github"; python3 "$CHECKER" "$SCRIPTS_DIR/.github/workflows")"
echo ""

# ---------------------------------------------------------------------------
echo "2. the assertions fire against a deliberate violation"
# ---------------------------------------------------------------------------
# Every assertion above passes trivially on a tree with nothing in it, and an
# assertion that has never been seen to fail is a comment. Each shape below is
# the exact regression the rule exists to prevent.

mkdir -p "$FIXTURES/ungated-go"
cat > "$FIXTURES/ungated-go/action.yaml" <<'YAML'
runs:
  using: 'composite'
  steps:
    - name: 'Setup Go'
      uses: 'actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16' # v6.5.0
      with:
        go-version-file: 'go.mod'
        cache-dependency-path: 'go.sum'
YAML
assert_reports "an actions/setup-go with no \`cache:\` at all is reported" \
  "$(python3 "$CHECKER" "$FIXTURES/ungated-go")"

mkdir -p "$FIXTURES/cache-true"
cat > "$FIXTURES/cache-true/action.yaml" <<'YAML'
runs:
  using: 'composite'
  steps:
    - uses: 'actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16' # v6.5.0
      with:
        cache: true
YAML
assert_reports "an actions/setup-go pinned to \`cache: true\` is reported" \
  "$(python3 "$CHECKER" "$FIXTURES/cache-true")"

mkdir -p "$FIXTURES/ungated-cache"
cat > "$FIXTURES/ungated-cache/action.yaml" <<'YAML'
runs:
  using: 'composite'
  steps:
    - name: 'Cache the SDK'
      uses: 'actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830' # v4.3.0
      with:
        path: |
          ~/.local/share/flutter
          ~/.pub-cache
        key: 'sdk'
YAML
assert_reports "an ungated actions/cache naming a \$HOME path is reported" \
  "$(python3 "$CHECKER" "$FIXTURES/ungated-cache")"

# Both quote styles. Only the single-quoted form is valid GitHub Actions expression
# syntax -- the double-quoted one is a parse error and cannot ship silently -- but the
# diagnostic should not depend on the author having written the version that parses.
mkdir -p "$FIXTURES/anti-gate"
cat > "$FIXTURES/anti-gate/action.yaml" <<'YAML'
runs:
  using: 'composite'
  steps:
    - uses: 'actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16' # v6.5.0
      with:
        cache: ${{ runner.environment == 'github-hosted' }}

    - name: 'Cache the SDK'
      if: '${{ runner.environment == "github-hosted" }}'
      uses: 'actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830' # v4.3.0
      with:
        path: |
          ~/.pub-cache
        key: 'sdk'
YAML
ANTI_GATE_OUT="$(python3 "$CHECKER" "$FIXTURES/anti-gate")"
assert_reports_n "the inverted \`== 'github-hosted'\` gate is reported in both quote styles" \
  "$ANTI_GATE_OUT" 'disables the cache for every consumer' 2
echo ""

# ---------------------------------------------------------------------------
echo "3. the assertions do NOT fire on the shapes that are correct"
# ---------------------------------------------------------------------------
# The mirror of section 2, and just as necessary: a checker that reports
# everything would pass section 2 while making section 1 impossible to satisfy,
# and the first person to hit it would delete the rule rather than the defect.

mkdir -p "$FIXTURES/ok"
cat > "$FIXTURES/ok/action.yaml" <<'YAML'
runs:
  using: 'composite'
  steps:
    - name: 'Setup Go'
      uses: 'actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16' # v6.5.0
      with:
        go-version-file: 'go.mod'
        cache: ${{ runner.environment != 'self-hosted' }}

    - name: 'Set up Go for the analysis'
      uses: 'actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16' # v6.5.0
      with:
        cache: false

    - name: 'Cache the SDK'
      if: "runner.environment != 'self-hosted'"
      uses: 'actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830' # v4.3.0
      with:
        path: |
          ~/.local/share/flutter
        key: 'sdk'

    - name: 'Cache the NVD database'
      uses: 'actions/cache/restore@0057852bfaa89a56745cba8c7296529d2fc39830' # v4.3.0
      with:
        path: '.owasp'
        key: 'owasp-nvd'

    - name: 'Setup Node.js'
      uses: 'actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38' # v6.5.0
      with:
        cache: 'yarn'
YAML
assert_empty "a gated setup-go, \`cache: false\`, a gated \$HOME cache, an in-workspace cache and setup-node all pass" \
  "$(python3 "$CHECKER" "$FIXTURES/ok")"
echo ""

echo "=========================================="
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
  exit 1
fi
echo "All self-hosted cache gating tests passed!"
