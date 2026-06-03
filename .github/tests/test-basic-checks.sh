#!/usr/bin/env bash
# Test script for the changelog validation logic in
# azure-devops/global/stages/10-code-check/basic-checks.yaml.
#
# Exercises both chlog-based (fragment) and legacy (direct CHANGELOG.md edit)
# changelog validation by creating temporary git repos that simulate PR diffs.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Extract the changelog check block from basic-checks.yaml into a standalone
# script that can be sourced inside each test repo. The block expects
# TARGET_BRANCH to be set and runs from the repo root.
CHANGELOG_SCRIPT="$(mktemp)"
trap 'rm -f "$CHANGELOG_SCRIPT"; rm -rf /tmp/basic-checks-test-*' EXIT

cat > "$CHANGELOG_SCRIPT" << 'EXTRACTED'
#!/usr/bin/env bash
set -euo pipefail

echo ""
echo "=== Changelog Check ==="

if [ -f ".chlog.yaml" ]; then
  echo "Detected chlog-based changelog (found .chlog.yaml)."
  echo "Checking for new fragments in '.changes/unreleased/'..."

  NEW_FRAGMENTS=$(git diff --name-only --diff-filter=A "origin/$TARGET_BRANCH"...HEAD -- '.changes/unreleased/' 2>/dev/null || true)
  if [ -z "$NEW_FRAGMENTS" ]; then
    echo ""
    echo "============================================================"
    echo "  ERROR: No changelog fragment was added."
    echo "============================================================"
    echo ""
    exit 1
  fi

  echo "Found changelog fragment(s):"
  echo "$NEW_FRAGMENTS"
else
  echo "Checking CHANGELOG.md modifications against '$TARGET_BRANCH'..."

  CHANGED_FILES=$(git diff --name-only "origin/$TARGET_BRANCH"...HEAD -- 'CHANGELOG.md' 2>/dev/null || true)
  if [ -z "$CHANGED_FILES" ]; then
    echo ""
    echo "============================================================"
    echo "  ERROR: CHANGELOG.md was NOT modified."
    echo "============================================================"
    echo ""
    exit 1
  fi

  echo "CHANGELOG.md was modified. Validating entry placement..."

  CHANGELOG_CONTENT=$(git show HEAD:CHANGELOG.md 2>/dev/null || true)
  if [ -z "$CHANGELOG_CONTENT" ]; then
    echo "WARNING: could not read CHANGELOG.md from HEAD, skipping placement check."
    exit 0
  fi

  UNRELEASED_LINE=$(echo "$CHANGELOG_CONTENT" | grep -n '^##[[:space:]]*\[Unreleased\]' | head -1 | cut -d: -f1)

  if [ -z "$UNRELEASED_LINE" ]; then
    echo ""
    echo "============================================================"
    echo "  ERROR: CHANGELOG.md does not contain an [Unreleased] section."
    echo "============================================================"
    echo ""
    exit 1
  fi

  NEXT_VERSION_LINE=$(echo "$CHANGELOG_CONTENT" | grep -n '^##[[:space:]]*\[' | grep -v '\[Unreleased\]' | head -1 | cut -d: -f1)

  DIFF_LINES=$(git diff "origin/$TARGET_BRANCH"...HEAD -- 'CHANGELOG.md' 2>/dev/null || true)
  HUNK_POSITIONS=$(echo "$DIFF_LINES" | grep '^@@' | sed 's/.*+\([0-9]*\).*/\1/' || true)

  HAS_VALID_ENTRIES=false
  HAS_INVALID_ENTRIES=false

  for HUNK_START in $HUNK_POSITIONS; do
    if [ "$HUNK_START" -ge "$UNRELEASED_LINE" ]; then
      if [ -n "$NEXT_VERSION_LINE" ] && [ "$HUNK_START" -ge "$NEXT_VERSION_LINE" ]; then
        HAS_INVALID_ENTRIES=true
      else
        HAS_VALID_ENTRIES=true
      fi
    else
      HAS_VALID_ENTRIES=true
    fi
  done

  if [ "$HAS_INVALID_ENTRIES" = true ] && [ "$HAS_VALID_ENTRIES" = false ]; then
    echo ""
    echo "============================================================"
    echo "  ERROR: CHANGELOG.md entries are NOT under [Unreleased]."
    echo "============================================================"
    echo ""
    exit 1
  fi

  echo "CHANGELOG.md entries are correctly placed under [Unreleased]."
fi
EXTRACTED
chmod +x "$CHANGELOG_SCRIPT"

# Helper: create a bare "origin" repo and a working clone with a main branch
# containing a base CHANGELOG.md. Returns the working repo path.
setup_repo() {
  local test_name="$1"
  local bare_dir="/tmp/basic-checks-test-${test_name}-bare"
  local work_dir="/tmp/basic-checks-test-${test_name}"

  rm -rf "$bare_dir" "$work_dir"

  git init --bare -b main "$bare_dir" >/dev/null 2>&1
  git clone "$bare_dir" "$work_dir" >/dev/null 2>&1
  cd "$work_dir"
  git config user.name "test" >/dev/null 2>&1
  git config user.email "test@test" >/dev/null 2>&1
  git checkout -b main >/dev/null 2>&1

  cat > CHANGELOG.md << 'CHANGELOG'
# Changelog

## [Unreleased]

## [1.0.0] - 2026-01-01

### Added

- initial release
CHANGELOG

  git add CHANGELOG.md
  git commit -m "initial commit" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1

  echo "$work_dir"
}

assert_pass() {
  local description="$1"
  shift
  if TARGET_BRANCH=main bash "$CHANGELOG_SCRIPT" >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC} $description"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}FAIL${NC} $description (expected pass, got fail)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

assert_fail() {
  local description="$1"
  shift
  if TARGET_BRANCH=main bash "$CHANGELOG_SCRIPT" >/dev/null 2>&1; then
    echo -e "${RED}FAIL${NC} $description (expected fail, got pass)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    echo -e "${GREEN}PASS${NC} $description"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  fi
}

echo "=== Basic-checks changelog validation ==="

# ── chlog mode ────────────────────────────────────────────────────────────────

echo ""
echo "── chlog mode ──"

echo ""
echo "Test 1: chlog repo with fragment added → should pass"
WORK_DIR="$(setup_repo "chlog-pass")"
cd "$WORK_DIR"
git checkout -b feat/test >/dev/null 2>&1
touch .chlog.yaml
mkdir -p .changes/unreleased
echo "kind: Added" > .changes/unreleased/fragment-1.yaml
git add .chlog.yaml .changes/unreleased/fragment-1.yaml
git commit -m "add fragment" >/dev/null 2>&1
assert_pass "chlog repo with fragment added"

echo ""
echo "Test 2: chlog repo without fragment → should fail"
WORK_DIR="$(setup_repo "chlog-fail")"
cd "$WORK_DIR"
git checkout -b feat/test >/dev/null 2>&1
touch .chlog.yaml
echo "some change" > src.txt
git add .chlog.yaml src.txt
git commit -m "change without fragment" >/dev/null 2>&1
assert_fail "chlog repo without fragment"

echo ""
echo "Test 3: chlog repo with only pre-existing fragment (not newly added) → should fail"
WORK_DIR="$(setup_repo "chlog-old-fragment")"
cd "$WORK_DIR"
touch .chlog.yaml
mkdir -p .changes/unreleased
echo "kind: Added" > .changes/unreleased/old-fragment.yaml
git add .chlog.yaml .changes/unreleased/old-fragment.yaml
git commit -m "add chlog config and old fragment" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
git checkout -b feat/test >/dev/null 2>&1
# modify the old fragment instead of adding a new one
echo "kind: Changed" > .changes/unreleased/old-fragment.yaml
git add .changes/unreleased/old-fragment.yaml
git commit -m "modify existing fragment" >/dev/null 2>&1
assert_fail "chlog repo with only modified (not new) fragment"

# ── legacy mode ───────────────────────────────────────────────────────────────

echo ""
echo "── legacy mode ──"

echo ""
echo "Test 4: legacy repo with CHANGELOG.md modified under [Unreleased] → should pass"
WORK_DIR="$(setup_repo "legacy-pass")"
cd "$WORK_DIR"
git checkout -b feat/test >/dev/null 2>&1
sed -i 's/## \[Unreleased\]/## [Unreleased]\n\n### Added\n\n- new feature/' CHANGELOG.md
git add CHANGELOG.md
git commit -m "add changelog entry" >/dev/null 2>&1
assert_pass "legacy repo with CHANGELOG.md entry under [Unreleased]"

echo ""
echo "Test 5: legacy repo without CHANGELOG.md modification → should fail"
WORK_DIR="$(setup_repo "legacy-fail")"
cd "$WORK_DIR"
git checkout -b feat/test >/dev/null 2>&1
echo "some change" > src.txt
git add src.txt
git commit -m "change without changelog" >/dev/null 2>&1
assert_fail "legacy repo without CHANGELOG.md modification"

echo ""
echo "Test 6: legacy repo with entry below version section (not under [Unreleased]) → should fail"
WORK_DIR="$(setup_repo "legacy-wrong-section")"
cd "$WORK_DIR"
git checkout -b feat/test >/dev/null 2>&1
cat > CHANGELOG.md << 'CHANGELOG'
# Changelog

## [Unreleased]

## [1.0.0] - 2026-01-01

### Added

- initial release
- entry in wrong section
CHANGELOG
git add CHANGELOG.md
git commit -m "add entry in wrong section" >/dev/null 2>&1
assert_fail "legacy repo with entry below version section"

echo ""
echo "Test 7: legacy repo with CHANGELOG.md missing [Unreleased] section → should fail"
WORK_DIR="$(setup_repo "legacy-no-unreleased")"
cd "$WORK_DIR"
git checkout -b feat/test >/dev/null 2>&1
cat > CHANGELOG.md << 'CHANGELOG'
# Changelog

## [1.0.0] - 2026-01-01

### Added

- initial release
- new entry without unreleased section
CHANGELOG
git add CHANGELOG.md
git commit -m "modify changelog without unreleased" >/dev/null 2>&1
assert_fail "legacy repo with CHANGELOG.md missing [Unreleased] section"

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results ==="
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]]
