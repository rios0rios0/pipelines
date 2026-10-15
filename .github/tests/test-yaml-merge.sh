#!/usr/bin/env bash
set -e

# Test script for golangci-lint/run.sh: the YAML config merge (TESTS 1-9), the timeout of the lint
# run it hands the merged config to (TEST 10), and how the script obtains the golangci-lint binary
# and checks it against the Go toolchain (TESTS 11-18).
#
# The merge tests drive the real `run.sh` through its `GOLANGCI_LINT_MERGE_ONLY` hook rather than
# keeping a second copy of the merge. The copy is what allowed the defect these tests now cover:
# it merged project settings into the v1 `linters-settings` key while `run.sh` merged into the v2
# `linters.settings`, so every assertion below passed against a shape production never emitted.
#
# The binary tests run the whole script against stubs of `curl`, `go` and `golangci-lint`, so no
# release is downloaded and no Go toolchain is needed.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPTS_DIR
RUN_SH="$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/run.sh"
DEFAULT_CONFIG="$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/.golangci.yml"
TEST_DIR="$(mktemp -d)" || exit 1

# `yq` is two unrelated programs sharing a name, and which one answers is decided by the machine:
# GitHub's `ubuntu-latest` preinstalls mikefarah/yq, while Debian and Ubuntu's own `yq` package
# and `pip install yq` are kislyuk's, which reads the expression as a FILENAME and rejects `eval`.
# These assertions used to call a bare `yq`, so this suite passed on GitHub's runners and failed
# on any Debian-ish workstation -- with `can't open '.linters.enable[]'`, which looks like a
# broken test rather than the wrong program. `make test` is what CONTRIBUTING tells people to run
# before submitting, so it has to mean the same thing everywhere. Resolved through the same helper
# the production script uses, so there is one implementation rather than two that can disagree.
. "$SCRIPTS_DIR/global/scripts/shared/pinned-versions.sh"
. "$SCRIPTS_DIR/global/scripts/shared/verify-download.sh"
. "$SCRIPTS_DIR/global/scripts/shared/resolve-yq.sh"

YQ=""

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

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Resolved AFTER the trap is installed: the binary is downloaded into TEST_DIR when the machine
# has no mikefarah/yq, and a failure between mktemp and the trap would otherwise leak the
# directory on exactly the path that already went wrong.
resolve_yq "$TEST_DIR/yqbin" \
  || { echo "could not resolve mikefarah/yq; cannot run this suite" >&2; exit 1; }

# Runs the production merge in an isolated working directory and copies the result out.
# `extra_path` is prepended to PATH when given, so a test can control which `yq` is found first.
merge_yaml() {
  local repo_file="$1"
  local output_file="$2"
  local extra_path="${3:-}"

  # Created under TEST_DIR so the EXIT trap reclaims it. A standalone mktemp would leak on every
  # failure path, because `set -e` aborts the script before the explicit cleanup below is reached.
  local workdir
  workdir="$(mktemp -d "$TEST_DIR/work.XXXXXX")" || exit 1
  if [[ -f "$repo_file" ]]; then
    cp "$repo_file" "$workdir/.golangci.yml"
  fi

  # The script's own output is kept and echoed when it fails. Discarding it is how a merge that
  # aborted (an undownloadable yq, an unreadable config) became indistinguishable from a merge
  # that silently produced the wrong result -- the assertions fail identically, and the reason
  # only exists in the output that was thrown away.
  local log="$workdir/run.log"
  if ! (
    cd "$workdir" || exit 1
    if [[ -n "$extra_path" ]]; then
      export PATH="$extra_path:$PATH"
    fi
    GOLANGCI_LINT_MERGE_ONLY=1 sh "$RUN_SH"
  ) > "$log" 2>&1; then
    echo "    (run.sh exited non-zero; output follows)"
    sed 's/^/    | /' "$log"
  fi

  cp "$workdir/merged.yml" "$output_file"
  rm -rf "$workdir"
}

# Impersonates kislyuk/yq: a bare version banner, and no support for `eval`. Used by the tests
# that need run.sh to find an unusable `yq` first on PATH.
mkdir -p "$TEST_DIR/fakebin"
cat > "$TEST_DIR/fakebin/yq" << 'SHIM'
#!/usr/bin/env sh
if [ "$1" = "--version" ]; then
  echo "yq 3.4.3"
  exit 0
fi
echo "yq: error: argument files: can't open '$2'" >&2
exit 2
SHIM
chmod +x "$TEST_DIR/fakebin/yq"

# =============================================================================
# Test 1: No custom config - should use default as-is
# =============================================================================
echo "TEST 1: No custom config (default fallback)"
merge_yaml "$TEST_DIR/does-not-exist.yml" "$TEST_DIR/merged.yml"
assert_true "merged file created" "[ -s '$TEST_DIR/merged.yml' ]"
assert_true "default linters present" \
  "\"$YQ\" eval '.linters.enable | contains([\"errcheck\", \"govet\", \"staticcheck\"])' '$TEST_DIR/merged.yml' | grep -q true"

# With no config there is nothing to merge and `$YQ` is never read, so the script must not reach
# for a binary at all. Asserted with the unusable shim first on PATH: if the resolution were not
# gated, that shim would force a download, and `./bin/yq` would exist afterwards.
noconfig_dir="$(mktemp -d "$TEST_DIR/noconfig.XXXXXX")" || exit 1
(
  cd "$noconfig_dir" || exit 1
  export PATH="$TEST_DIR/fakebin:$PATH"
  GOLANGCI_LINT_MERGE_ONLY=1 sh "$RUN_SH"
) > /dev/null 2>&1
assert_true "no yq downloaded when the repo has no .golangci.yml" \
  "[ ! -e '$noconfig_dir/bin/yq' ]"
assert_true "the default config is still produced without yq" \
  "[ -s '$noconfig_dir/merged.yml' ]"

# =============================================================================
# Test 2: Custom config with additional enabled linters
# =============================================================================
echo "TEST 2: Custom enabled linters"
cat > "$TEST_DIR/repo.yml" << 'YAML'
linters:
  enable:
    - exhaustruct
    - ginkgolinter
YAML
merge_yaml "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
assert_true "new linters added" \
  "\"$YQ\" eval '.linters.enable | contains([\"exhaustruct\", \"ginkgolinter\"])' '$TEST_DIR/merged.yml' | grep -q true"
assert_true "default linters preserved" \
  "\"$YQ\" eval '.linters.enable | contains([\"errcheck\", \"govet\"])' '$TEST_DIR/merged.yml' | grep -q true"

# =============================================================================
# Test 3: Custom config with disabled linters
# =============================================================================
echo "TEST 3: Disabled linters"
cat > "$TEST_DIR/repo.yml" << 'YAML'
linters:
  disable:
    - staticcheck
    - cyclop
YAML
merge_yaml "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
assert_true "staticcheck removed" \
  "! \"$YQ\" eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx staticcheck"
assert_true "cyclop removed" \
  "! \"$YQ\" eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx cyclop"
assert_true "other linters preserved" \
  "\"$YQ\" eval '.linters.enable | contains([\"errcheck\", \"govet\"])' '$TEST_DIR/merged.yml' | grep -q true"

# =============================================================================
# Test 4: Custom linter settings
#
# Asserted against the v2 `linters.settings` key, which is what golangci-lint v2 reads and what
# run.sh writes. The previous suite asserted the v1 `linters-settings` key and so proved nothing.
# =============================================================================
echo "TEST 4: Linter settings merge"
cat > "$TEST_DIR/repo.yml" << 'YAML'
linters-settings:
  errcheck:
    check-blank: true
  custom-linter:
    option-a: hello
YAML
merge_yaml "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
assert_true "custom setting merged" \
  "\"$YQ\" eval '.linters.settings.errcheck.check-blank' '$TEST_DIR/merged.yml' | grep -qx true"
assert_true "new linter settings added" \
  "\"$YQ\" eval '.linters.settings.custom-linter.option-a' '$TEST_DIR/merged.yml' | grep -qx hello"
assert_true "existing default settings preserved" \
  "\"$YQ\" eval '.linters.settings.cyclop.max-complexity' '$TEST_DIR/merged.yml' | grep -qx 30"

# =============================================================================
# Test 5: Complex config (enable + disable + settings)
# =============================================================================
echo "TEST 5: Complex combined config"
cat > "$TEST_DIR/repo.yml" << 'YAML'
linters:
  enable:
    - exhaustruct
  disable:
    - staticcheck

linters-settings:
  exhaustruct:
    exclude:
      - '^net/http\.Client$'
YAML
merge_yaml "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
assert_true "exhaustruct enabled" \
  "\"$YQ\" eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx exhaustruct"
assert_true "staticcheck disabled" \
  "! \"$YQ\" eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx staticcheck"
assert_true "exhaustruct settings applied" \
  "\"$YQ\" eval '.linters.settings.exhaustruct.exclude | length' '$TEST_DIR/merged.yml' | grep -q '[0-9]'"

# =============================================================================
# Test 6: Empty custom config
# =============================================================================
echo "TEST 6: Empty custom config"
touch "$TEST_DIR/empty.yml"
merge_yaml "$TEST_DIR/empty.yml" "$TEST_DIR/merged.yml"
default_count=$("$YQ" eval '.linters.enable | length' "$DEFAULT_CONFIG")
merged_count=$("$YQ" eval '.linters.enable | length' "$TEST_DIR/merged.yml")
assert_true "linter count unchanged" "[ '$default_count' = '$merged_count' ]"

# =============================================================================
# Test 7: Duplicate linters not re-added
# =============================================================================
echo "TEST 7: Duplicate linter handling"
cat > "$TEST_DIR/repo.yml" << 'YAML'
linters:
  enable:
    - errcheck
    - govet
    - exhaustruct
YAML
merge_yaml "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml"
expected_count=$((default_count + 1))
actual_count=$("$YQ" eval '.linters.enable | length' "$TEST_DIR/merged.yml")
assert_true "only 1 new linter added (no dupes)" "[ '$actual_count' = '$expected_count' ]"

# =============================================================================
# Test 8: The wrong `yq` on PATH must not silently void the project config
#
# `yq` is two programs: mikefarah/yq (Go) speaks `yq eval '<expr>' <file>`, while kislyuk/yq
# (a jq wrapper, shipped by pip and several distributions) treats the expression as a filename
# and exits non-zero. run.sh used to swallow that with `2>/dev/null || true`, silently dropping
# every project override and reporting the shared defaults as violations of the project's code.
# The shim below impersonates kislyuk/yq; run.sh must notice and fetch a usable binary.
# =============================================================================
echo "TEST 8: Wrong yq flavour on PATH"
cat > "$TEST_DIR/repo.yml" << 'YAML'
linters:
  disable:
    - recvcheck

linters-settings:
  dupl:
    threshold: 300
YAML
merge_yaml "$TEST_DIR/repo.yml" "$TEST_DIR/merged.yml" "$TEST_DIR/fakebin"
assert_true "recvcheck still disabled despite wrong yq on PATH" \
  "! \"$YQ\" eval '.linters.enable[]' '$TEST_DIR/merged.yml' | grep -qx recvcheck"
assert_true "settings still merged despite wrong yq on PATH" \
  "\"$YQ\" eval '.linters.settings.dupl.threshold' '$TEST_DIR/merged.yml' | grep -qx 300"

# =============================================================================
# Test 9: No test script calls a bare `yq`
# =============================================================================
# The defect this suite was blind to for as long as it existed: the assertions ABOVE resolved
# whichever `yq` the machine happened to provide, so they were green on GitHub's runners and red
# on a Debian-ish workstation. Nothing failed on the runner where it was wrong, which is why it
# survived. A bare invocation is easy to reintroduce -- it is what every yq example on the
# internet looks like -- so it is asserted against rather than left to review.
#
# Matched on the invocation shapes only (`yq eval`, `yq -e`, `yq '...'`, `yq "..."`), so prose
# like "no yq downloaded when ..." and the kislyuk shim's own banner do not count as calls.
# COMMENT LINES ARE DROPPED FIRST, for the same reason test-supply-chain.sh drops them: this
# repository documents the patterns it forbids at length, so a check that bans a bare `yq eval`
# is otherwise failed by the paragraph explaining why -- including this one.
echo "TEST 9: No test script calls a bare yq"
bare_yq="$(grep -nE "(^|[^A-Za-z_./$\"'-])yq +(eval|-e|['\"])" "$SCRIPTS_DIR"/.github/tests/*.sh \
  | grep -vE ':[0-9]+: *#' \
  | grep -v '\$YQ' || true)"
assert_true "no test script invokes a bare yq (it must go through \$YQ)" \
  "[ -z \"\$bare_yq\" ]"
if [ -n "$bare_yq" ]; then
  echo "$bare_yq" | sed 's/^/    | /'
fi

# =============================================================================
# Test 10: The lint run's timeout
#
# This suite already drives the real run.sh, so it also holds what the script hands golangci-lint
# besides the merged config. The timeout was a fixed 10m, and with about twenty runs sharing one
# self-hosted host a clean analysis outran it and exited 4. Nobody saw that where the lint job was
# advisory, and it would be a red build once a failed lint fails the run there too (#725).
# So the default is 30m, `GOLANGCI_LINT_TIMEOUT` overrides it, and exit 4 -- golangci-lint's
# timeout -- says it is not a finding.
#
# A stub stands in for golangci-lint. It reports the pinned version, so run.sh takes it instead of
# downloading one, records its arguments, and exits with the code it is told to.
# =============================================================================
echo "TEST 10: The lint run's timeout"
mkdir -p "$TEST_DIR/stubbin"
cat > "$TEST_DIR/stubbin/golangci-lint" << STUB
#!/usr/bin/env sh
if [ "\$1" = "version" ]; then
  echo "golangci-lint has version ${GOLANGCI_LINT_VERSION} built with go1.99.0 from stub"
  exit 0
fi
echo "\$*" > "\$STUB_ARGS"
exit "\${STUB_EXIT:-0}"
STUB
chmod +x "$TEST_DIR/stubbin/golangci-lint"
STUB_LOG="$TEST_DIR/stub.args"
LINT_OUT="$TEST_DIR/lint.out"

# Runs run.sh in a fresh project with the stub first on PATH, and also at ./bin, where run.sh
# installs a binary, so the stub is found however the script resolves one. Writes the combined
# output to LINT_OUT and returns run.sh's exit code.
lint_with_stub() {
  local stub_exit="$1"
  local timeout="${2:-}"
  local workdir
  workdir="$(mktemp -d "$TEST_DIR/lint.XXXXXX")" || exit 1
  mkdir -p "$workdir/bin"
  cp "$TEST_DIR/stubbin/golangci-lint" "$workdir/bin/golangci-lint"
  rm -f "$STUB_LOG"
  (
    cd "$workdir" || exit 1
    export PATH="$TEST_DIR/stubbin:$PATH" STUB_ARGS="$STUB_LOG" STUB_EXIT="$stub_exit"
    if [[ -n "$timeout" ]]; then
      export GOLANGCI_LINT_TIMEOUT="$timeout"
    else
      unset GOLANGCI_LINT_TIMEOUT
    fi
    sh "$RUN_SH"
  ) > "$LINT_OUT" 2>&1
}

rc=0
lint_with_stub 0 || rc=$?
assert_true "a clean lint exits 0" "[ '$rc' = 0 ]"
assert_true "the timeout defaults to 30m" "grep -q -- '--timeout 30m' '$STUB_LOG'"

rc=0
lint_with_stub 0 45m || rc=$?
assert_true "GOLANGCI_LINT_TIMEOUT overrides the timeout" "grep -q -- '--timeout 45m' '$STUB_LOG'"

rc=0
lint_with_stub 4 || rc=$?
assert_true "a timeout keeps golangci-lint's exit code 4" "[ '$rc' = 4 ]"
assert_true "a timeout says no finding caused it" "grep -q 'ran out of time' '$LINT_OUT'"

rc=0
lint_with_stub 1 || rc=$?
assert_true "findings keep exit code 1" "[ '$rc' = 1 ]"
assert_true "findings are not reported as a timeout" "! grep -q 'ran out of time' '$LINT_OUT'"

# =============================================================================
# Binary resolution and the toolchain guard (TESTS 11-18)
#
# run.sh past the merge: which golangci-lint it runs, how it installs one, and whether that binary
# can analyse code for the Go toolchain on PATH. Every external program it reaches is a stub:
#
#   curl           records the URL and destination it was given, and writes the fixture archive
#   go             answers `go env GOVERSION` with STUB_GO_VERSION, and fails when that is empty
#   golangci-lint  answers `version` with a chosen release and build Go, and records each `run`
#
# The stubbed release is 9.9.9, which does not exist, so a real golangci-lint on the machine's
# PATH can never match it and change which binary a test runs.
# =============================================================================
STUB_VERSION='9.9.9'
# Not Test 10's `stubbin`: this directory goes on PATH, and sharing it would put Test 10's
# golangci-lint stub on PATH in every test below.
STUB_BIN="$TEST_DIR/binary-stubs"
LINT_TMP="$TEST_DIR/linttmp"
mkdir -p "$STUB_BIN" "$LINT_TMP"

cat > "$STUB_BIN/curl" << 'STUB'
#!/usr/bin/env sh
url=''
dest=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$url" "$dest" >> "$STUB_LOG/curl"
cp "$STUB_ARCHIVE" "$dest"
STUB
cat > "$STUB_BIN/go" << 'STUB'
#!/usr/bin/env sh
if [ "$1" = 'env' ] && [ "$2" = 'GOVERSION' ]; then
  [ -n "$STUB_GO_VERSION" ] || exit 1
  printf '%s\n' "$STUB_GO_VERSION"
fi
STUB
chmod +x "$STUB_BIN/curl" "$STUB_BIN/go"

# make_golangci_stub <path> <label> <release> <built-with Go> <run mode>
#
# The label is what the stub records when it runs, so a test can tell which of several binaries
# the script chose. Run modes: `ok` (no issues), `findings` (one ordinary issue, exit 1),
# `export-data` (the real message of a binary that cannot read the toolchain's export data,
# exit 1) and `exit:<n>`.
make_golangci_stub() {
  local path="$1" label="$2" release="$3" built_with="$4" mode="$5"
  mkdir -p "$(dirname "$path")"
  cat > "$path" << STUB
#!/usr/bin/env sh
if [ "\$1" = 'version' ]; then
  echo 'golangci-lint has version $release built with go$built_with from 0000000 on 2026-01-01T00:00:00Z'
  exit 0
fi
echo '$label' >> "\$STUB_LOG/ran"
case '$mode' in
  ok) echo '0 issues.'; exit 0 ;;
  findings) echo 'main.go:5:2: Error return value is not checked (errcheck)'; exit 1 ;;
  export-data)
    echo 'probe.go:3:8: could not import fmt (-: could not load export data: internal error in importing "internal/goarch" (cannot decode "internal/goarch", export data version 5 is greater than maximum supported version 4); please report an issue) (typecheck)'
    exit 1 ;;
  exit:*) exit '${mode#exit:}' ;;
esac
STUB
  chmod +x "$path"
}

# The release archive the stubbed curl serves: the layout of a real one, holding a stub binary.
case "$(uname -m)" in
  x86_64) STUB_ARCH='amd64' ;;
  aarch64 | arm64) STUB_ARCH='arm64' ;;
  *) STUB_ARCH='' ;;
esac
STUB_ARCHIVE="$TEST_DIR/golangci-lint.tar.gz"
archive_root="$(mktemp -d "$TEST_DIR/archive.XXXXXX")" || exit 1
make_golangci_stub "$archive_root/golangci-lint-$STUB_VERSION-linux-$STUB_ARCH/golangci-lint" \
  downloaded "$STUB_VERSION" 1.27.0 ok
tar -czf "$STUB_ARCHIVE" -C "$archive_root" "golangci-lint-$STUB_VERSION-linux-$STUB_ARCH"
if command -v sha256sum > /dev/null 2>&1; then
  STUB_SHA256="$(sha256sum "$STUB_ARCHIVE" | awk '{print $1}')"
else
  STUB_SHA256="$(shasum -a 256 "$STUB_ARCHIVE" | awk '{print $1}')"
fi

new_workdir() {
  local dir
  dir="$(mktemp -d "$TEST_DIR/lint.XXXXXX")" || exit 1
  mkdir -p "$dir/.stub"
  printf '%s\n' "$dir"
}

# run_lint <workdir> <go version> [extra PATH]
#
# Runs the whole of run.sh in `workdir` against the stubs, with TMPDIR pointed at LINT_TMP so the
# private directories it creates can be inspected. Sets LAST_STATUS; the output is kept in
# `<workdir>/run.log` and echoed when a test needs it.
run_lint() {
  local workdir="$1" go_version="$2" extra_path="${3:-}"
  local path="$STUB_BIN:$PATH"
  if [[ -n "$extra_path" ]]; then
    path="$extra_path:$path"
  fi
  LAST_STATUS=0
  (
    cd "$workdir" || exit 1
    PATH="$path" TMPDIR="$LINT_TMP" STUB_LOG="$workdir/.stub" STUB_ARCHIVE="$STUB_ARCHIVE" \
      STUB_GO_VERSION="$go_version" GOLANGCI_LINT_VERSION="$STUB_VERSION" \
      GOLANGCI_LINT_SHA256_OVERRIDE="$STUB_SHA256" sh "$RUN_SH"
  ) > "$workdir/run.log" 2>&1 || LAST_STATUS=$?
}

show_log() {
  sed 's/^/    | /' "$1/run.log"
}

# =============================================================================
# Test 11: A ./bin/golangci-lint that reports the pinned release is used, with no download
# =============================================================================
echo "TEST 11: A matching ./bin/golangci-lint is reused"
work="$(new_workdir)" || exit 1
make_golangci_stub "$work/bin/golangci-lint" bin "$STUB_VERSION" 1.27.0 ok
run_lint "$work" go1.27.2
assert_true "the run succeeds" "[ $LAST_STATUS -eq 0 ]"
assert_true "the ./bin binary is the one that runs" "[ \"\$(cat '$work/.stub/ran' 2> /dev/null)\" = bin ]"
assert_true "nothing is downloaded" "[ ! -e '$work/.stub/curl' ]"
[ "$LAST_STATUS" -eq 0 ] || show_log "$work"

# =============================================================================
# Test 12: A ./bin/golangci-lint of another release is replaced by the pinned one
# =============================================================================
echo "TEST 12: A ./bin/golangci-lint of another release is replaced"
work="$(new_workdir)" || exit 1
make_golangci_stub "$work/bin/golangci-lint" stale 1.0.0 1.27.0 ok
run_lint "$work" go1.27.2
assert_true "the run succeeds" "[ $LAST_STATUS -eq 0 ]"
assert_true "the pinned release is downloaded once" "[ \"\$(wc -l < '$work/.stub/curl' 2> /dev/null)\" -eq 1 ]"
assert_true "the downloaded binary is the one that runs" "[ \"\$(cat '$work/.stub/ran' 2> /dev/null)\" = downloaded ]"
assert_true "./bin/golangci-lint now reports the pinned release" \
  "'$work/bin/golangci-lint' version | grep -q 'version $STUB_VERSION '"
assert_true "the installed binary is executable" "[ -x '$work/bin/golangci-lint' ]"
[ "$LAST_STATUS" -eq 0 ] || show_log "$work"

# =============================================================================
# Test 13: Each install works in its own private directory, removed when the run ends
#
# Two runs used to share one archive path and one extraction directory, and each run's `rm -rf`
# could delete the other's files mid-install. Asserted on what the stubbed curl was told: the
# destination must sit in a directory under TMPDIR that belongs to that run alone and is gone
# afterwards. No staged copy may be left beside the installed binary either.
# =============================================================================
echo "TEST 13: Installs never share a temporary path"
work_a="$(new_workdir)" || exit 1
work_b="$(new_workdir)" || exit 1
run_lint "$work_a" go1.27.2
status_a=$LAST_STATUS
run_lint "$work_b" go1.27.2
status_b=$LAST_STATUS
dest_a="$(awk '{print $2}' "$work_a/.stub/curl" 2> /dev/null)"
dest_b="$(awk '{print $2}' "$work_b/.stub/curl" 2> /dev/null)"
assert_true "both runs succeed" "[ $status_a -eq 0 ] && [ $status_b -eq 0 ]"
assert_true "the first download lands under TMPDIR" "[[ '$dest_a' == '$LINT_TMP'/?*/* ]]"
assert_true "the second download lands under TMPDIR" "[[ '$dest_b' == '$LINT_TMP'/?*/* ]]"
assert_true "the two runs use different directories" \
  "[ -n '$dest_a' ] && [ \"\$(dirname '$dest_a')\" != \"\$(dirname '$dest_b')\" ]"
assert_true "each run removes its private directory" "[ -z \"\$(ls -A '$LINT_TMP')\" ]"
assert_true "no staged copy is left in ./bin" \
  "[ -z \"\$(find '$work_a/bin' '$work_b/bin' -name '.golangci-lint.*' 2> /dev/null)\" ]"
[ "$status_a" -eq 0 ] || show_log "$work_a"

# =============================================================================
# Test 14: A golangci-lint on PATH that reports the pinned release still wins
# =============================================================================
echo "TEST 14: A matching golangci-lint on PATH is used"
work="$(new_workdir)" || exit 1
make_golangci_stub "$TEST_DIR/pathbin/golangci-lint" path "$STUB_VERSION" 1.27.0 ok
run_lint "$work" go1.27.2 "$TEST_DIR/pathbin"
assert_true "the run succeeds" "[ $LAST_STATUS -eq 0 ]"
assert_true "the PATH binary is the one that runs" "[ \"\$(cat '$work/.stub/ran' 2> /dev/null)\" = path ]"
assert_true "nothing is downloaded or installed" "[ ! -e '$work/.stub/curl' ] && [ ! -e '$work/bin' ]"

# =============================================================================
# Test 15: A toolchain on a newer Go minor than the binary's build stops the run before linting
# =============================================================================
echo "TEST 15: A newer Go minor than the build stops the run"
work="$(new_workdir)" || exit 1
make_golangci_stub "$work/bin/golangci-lint" bin "$STUB_VERSION" 1.27.0 ok
run_lint "$work" go1.28.1
assert_true "the run fails" "[ $LAST_STATUS -ne 0 ]"
assert_true "the linter never runs" "[ ! -e '$work/.stub/ran' ]"
assert_true "the message names the binary's build Go" "grep -q 'built with go1.27.0' '$work/run.log'"
assert_true "the message names the toolchain" "grep -q 'go1.28.1 toolchain' '$work/run.log'"
assert_true "the message says to bump the pin" \
  "grep -q 'Bump GOLANGCI_LINT_VERSION in global/scripts/shared/pinned-versions.sh' '$work/run.log'"
assert_true "the merged config is still removed" "[ ! -e '$work/merged.yml' ]"

# =============================================================================
# Test 16: A newer patch release, or an older toolchain, does not stop the run
#
# golangci-lint 2.13.2 and 2.14.0 were both built with go1.27.0, and only 2.13.2 fails on
# go1.27.2's export data, so a newer patch says nothing about the binary in advance. Blocking it
# would stop the pinned release on every go1.27.2 consumer while it works.
# =============================================================================
echo "TEST 16: A newer patch, or an older toolchain, runs normally"
work="$(new_workdir)" || exit 1
make_golangci_stub "$work/bin/golangci-lint" bin "$STUB_VERSION" 1.27.0 ok
run_lint "$work" go1.27.2
assert_true "go1.27.2 against a go1.27.0 build runs" "[ $LAST_STATUS -eq 0 ] && [ -e '$work/.stub/ran' ]"
assert_true "the log names both versions" \
  "grep -q 'built with go1.27.0) with Go toolchain go1.27.2' '$work/run.log'"
work="$(new_workdir)" || exit 1
make_golangci_stub "$work/bin/golangci-lint" bin "$STUB_VERSION" 1.27.0 ok
run_lint "$work" go1.26.9
assert_true "go1.26.9 against a go1.27.0 build runs" "[ $LAST_STATUS -eq 0 ] && [ -e '$work/.stub/ran' ]"
for unknown in '' 'devel go1.28-0123abc Tue Sep 1 00:00:00 2026 +0000'; do
  work="$(new_workdir)" || exit 1
  make_golangci_stub "$work/bin/golangci-lint" bin "$STUB_VERSION" 1.27.0 ok
  run_lint "$work" "$unknown"
  assert_true "an unknown toolchain ('${unknown:-go env fails}') does not block the run" \
    "[ $LAST_STATUS -eq 0 ] && [ -e '$work/.stub/ran' ]"
done

# =============================================================================
# Test 17: An export-data failure is named as a tooling mismatch
# =============================================================================
echo "TEST 17: An export-data failure is named as a tooling mismatch"
work="$(new_workdir)" || exit 1
make_golangci_stub "$work/bin/golangci-lint" bin "$STUB_VERSION" 1.27.0 export-data
run_lint "$work" go1.27.2
assert_true "the run fails" "[ $LAST_STATUS -eq 1 ]"
assert_true "the linter's own output is still shown" "grep -q 'could not load export data' '$work/run.log'"
assert_true "the failure is named a tooling mismatch, not findings" \
  "grep -q '::error::golangci-lint v$STUB_VERSION (built with go1.27.0) could not read the export data of Go toolchain go1.27.2' '$work/run.log'"
assert_true "the message says to bump the pin" \
  "grep -q 'Bump GOLANGCI_LINT_VERSION in global/scripts/shared/pinned-versions.sh' '$work/run.log'"

# =============================================================================
# Test 18: Findings get no mismatch message, and the exit status is the linter's own
# =============================================================================
echo "TEST 18: Ordinary findings and exit statuses pass through"
work="$(new_workdir)" || exit 1
make_golangci_stub "$work/bin/golangci-lint" bin "$STUB_VERSION" 1.27.0 findings
run_lint "$work" go1.27.2
assert_true "findings fail the run" "[ $LAST_STATUS -eq 1 ]"
assert_true "findings are not called a tooling mismatch" "! grep -q 'tooling mismatch' '$work/run.log'"
work="$(new_workdir)" || exit 1
make_golangci_stub "$work/bin/golangci-lint" bin "$STUB_VERSION" 1.27.0 exit:3
run_lint "$work" go1.27.2
assert_true "the linter's exit status is kept (3)" "[ $LAST_STATUS -eq 3 ]"
assert_true "the merged config is removed after the run" "[ ! -e '$work/merged.yml' ]"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ]
