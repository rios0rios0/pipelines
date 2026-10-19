#!/usr/bin/env bash
# Validation for the terra CLI installer (`global/scripts/languages/terraform/terra/install.sh`).
#
# Asserts:
#   1. the pin check reads `terra version` from STDERR, where terra writes it, so a machine that
#      already has the pinned terra downloads nothing. It read stdout, never saw a version, and
#      reinstalled terra in every job;
#   2. a stale terra is replaced by the verified download, and no scratch directory is left;
#   3. installs that start together against ONE `$HOME` all succeed and leave a runnable terra.
#      That is how a self-hosted Azure DevOps machine runs its agents, and a pipeline's parallel
#      jobs reach the install together. Staged at shared, fixed paths, one job moved a file
#      another job was still writing, and running terra failed with `Text file busy`;
#   4. a download that fails verification leaves the installed terra as it was;
#   5. the Azure DevOps step stops at a failed install, as GitHub (`shell: bash`) and GitLab
#      (one command per line) already do. It ran without `-e`, so a failed install fell through
#      to `terra install` and `terra version`, and the step passed when the last line did.
#
# Runs OFFLINE. curl is a stub that serves release tarballs built here, and the "terra" inside
# them is a shell script that answers `version` as the real binary does: logrus lines on stderr.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$SCRIPTS_DIR/global/scripts/languages/terraform/terra/install.sh"
AZURE_STEP="$SCRIPTS_DIR/azure-devops/terra/abstracts/terra.yaml"

GREEN='\033[0;32m'
RED='\033[0;31m'
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

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

# --- Stubs -----------------------------------------------------------------------------------
# curl writes the tarball it is pointed at to the `-o` destination and logs one line per call.
STUBS="$WORK/stubs"
mkdir -p "$STUBS" || exit 1
cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env sh
destination=''
previous=''
for argument in "$@"; do
  [ "$previous" = "-o" ] && destination="$argument"
  previous="$argument"
done
printf 'download\n' >> "$TERRA_STUB_CURL_LOG"
cat "$TERRA_STUB_TARBALL" > "$destination"
STUB
chmod +x "$STUBS/curl"

# release <version>: builds `$WORK/release-<version>/terra` and its tarball. The script is padded
# to 8 MiB, about the size of the real binary, because the race lives in the time `tar` spends
# writing it; a few bytes would be written before another job could get in the way.
release() {
  local dir="$WORK/release-$1"
  mkdir -p "$dir" || return 1
  {
    printf '#!/bin/sh\n'
    printf 'if [ "$1" = version ]; then\n'
    printf '  printf "\\033[36mINFO\\033[0m[0000] Terra version: %s                                \\n" >&2\n' "$1"
    printf '  printf "\\033[36mINFO\\033[0m[0000] Terraform version: 1.16.6                          \\n" >&2\n'
    printf '  printf "\\033[36mINFO\\033[0m[0000] Terragrunt version: 1.1.6                          \\n" >&2\n'
    printf 'fi\n'
    printf 'exit 0\n'
    head -c 8388608 /dev/zero | tr '\0' '#'
    printf '\n'
  } > "$dir/terra"
  chmod 755 "$dir/terra"
  tar -czf "$dir/terra.tar.gz" -C "$dir" terra
}
release 1.0.0 || exit 1
release 9.9.9 || exit 1
NEW_SHA256="$(sha256sum "$WORK/release-9.9.9/terra.tar.gz" | awk '{print $1}')"

# home <name> <version>: a fresh `$HOME` with that version of terra already installed.
home() {
  local dir="$WORK/$1"
  mkdir -p "$dir/.local/bin" || return 1
  cp "$WORK/release-$2/terra" "$dir/.local/bin/terra" || return 1
  : > "$dir/curl.log"
}

# run_installer <home> <log> [<sha256>]: one run of the installer, asked for 9.9.9, in a clean
# environment: no terra of the host's on PATH, and the release built above verified through
# `TERRA_SHA256_OVERRIDE`, which is how a version other than the committed pin stays verified.
run_installer() {
  env -i HOME="$1" PATH="$STUBS:/usr/bin:/bin" SCRIPTS_DIR="$SCRIPTS_DIR" \
    TERRA_VERSION='9.9.9' TERRA_SHA256_OVERRIDE="${3:-$NEW_SHA256}" \
    TERRA_STUB_TARBALL="$WORK/release-9.9.9/terra.tar.gz" TERRA_STUB_CURL_LOG="$1/curl.log" \
    "$INSTALLER" > "$2" 2>&1
}

# version_in <home>: the version the terra installed there reports, read the way terra writes it.
version_in() {
  "$1/.local/bin/terra" version 2>&1 | awk '/Terra version:/{print $NF; exit}'
}

downloads() { wc -l < "$1/curl.log" | tr -d ' '; }
leftovers() { find "$1/.local/bin" -mindepth 1 -name '.terra*'; }

echo "=== terra installer ==="
echo ""

echo "Test 1: a terra already at the pinned version is kept"
home pinned 9.9.9 || exit 1
run_installer "$WORK/pinned" "$WORK/pinned.log"
PINNED_EXIT=$?
assert_true "the installer exits 0" "[ $PINNED_EXIT -eq 0 ]"
assert_true "it reports terra as already installed" "grep -q 'terra 9.9.9 is already installed' '$WORK/pinned.log'"
assert_true "nothing is downloaded" "[ \"\$(downloads '$WORK/pinned')\" = 0 ]"
echo ""

echo "Test 2: a stale terra is replaced"
home stale 1.0.0 || exit 1
run_installer "$WORK/stale" "$WORK/stale.log"
STALE_EXIT=$?
assert_true "the installer exits 0" "[ $STALE_EXIT -eq 0 ]"
assert_true "terra 9.9.9 is what runs afterwards" "[ \"\$(version_in '$WORK/stale')\" = 9.9.9 ]"
assert_true "the release is downloaded once" "[ \"\$(downloads '$WORK/stale')\" = 1 ]"
assert_true "no scratch directory is left beside it" "[ -z \"\$(leftovers '$WORK/stale')\" ]"
echo ""

echo "Test 3: installs that start together on one HOME all succeed"
home shared 1.0.0 || exit 1
PIDS=()
for job in 1 2 3 4 5 6 7 8; do
  run_installer "$WORK/shared" "$WORK/shared-$job.log" &
  PIDS+=("$!")
done
FAILED_JOBS=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || FAILED_JOBS=$((FAILED_JOBS + 1))
done
assert_true "all 8 installers exit 0" "[ $FAILED_JOBS -eq 0 ]"
assert_true "none of them hit 'Text file busy'" "! grep -qi 'text file busy' '$WORK'/shared-*.log"
assert_true "none of them lost its file to another job" "! grep -qE 'cannot (stat|access)|No such file' '$WORK'/shared-*.log"
assert_true "none of them reported an error" "! grep -q 'ERROR' '$WORK'/shared-*.log"
assert_true "terra 9.9.9 is what runs afterwards" "[ \"\$(version_in '$WORK/shared')\" = 9.9.9 ]"
assert_true "no scratch directory is left beside it" "[ -z \"\$(leftovers '$WORK/shared')\" ]"
echo ""

echo "Test 4: a download that fails verification changes nothing"
home tampered 1.0.0 || exit 1
run_installer "$WORK/tampered" "$WORK/tampered.log" "$(printf '%064d' 0)"
TAMPERED_EXIT=$?
assert_true "the installer fails" "[ $TAMPERED_EXIT -ne 0 ]"
assert_true "it names the checksum mismatch" "grep -q 'checksum mismatch' '$WORK/tampered.log'"
assert_true "the installed terra is still 1.0.0" "[ \"\$(version_in '$WORK/tampered')\" = 1.0.0 ]"
assert_true "no scratch directory is left beside it" "[ -z \"\$(leftovers '$WORK/tampered')\" ]"
echo ""

echo "Test 5: the Azure DevOps step stops at a failed install"
assert_true "its script starts with 'set -e'" \
  "grep -A1 -E '^[[:space:]]+- script: [|]\$' '$AZURE_STEP' | grep -qE '^[[:space:]]+set -e\$'"
echo ""

echo "=== Summary ==="
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
