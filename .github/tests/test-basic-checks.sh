#!/usr/bin/env bash
# Test script for the changelog validation logic in
# azure-devops/global/stages/10-code-check/basic-checks.yaml
# and in global/scripts/shared/changelog-check.sh.
#
# Exercises chlog-based (fragment), chlog release/bump (CHANGELOG.md updated),
# automation-branch (autoupdate's dedupe: a new entry OR one already pending on
# the target branch), and legacy (direct CHANGELOG.md edit) changelog validation
# by creating temporary git repos that simulate PR diffs.
#
# EVERY fixture is run twice: once against the extracted template logic below,
# and once against the real `global/scripts/shared/changelog-check.sh` on disk.
# That second run is the point of the pairing. The rule is implemented four
# times -- once per platform template, plus the standalone script -- because the
# `quality:basic-checks` job runs in a minimal image with only the consumer's
# repository on disk and cannot reach the scripts repo (see the comment at the
# top of `changelog-check.sh`). Four implementations of one rule drift silently:
# the script was left non-chlog-aware for the whole life of the templates' chlog
# support, and it therefore FAILED a legitimate fragment-only branch while the
# three templates passed it. Asserting the same expectation against both here is
# what makes that divergence loud instead of invisible.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Create a standalone script that mirrors the changelog validation logic from
# azure-devops/global/stages/10-code-check/basic-checks.yaml. The script expects
# TARGET_BRANCH to be set and is executed from the repo root.
CHANGELOG_SCRIPT="$(mktemp)"
trap 'rm -f "$CHANGELOG_SCRIPT"; rm -rf /tmp/basic-checks-test-*' EXIT

cat > "$CHANGELOG_SCRIPT" << 'EXTRACTED'
#!/usr/bin/env bash
set -euo pipefail

# In CI the source branch is provided by the platform; for this test harness we
# derive it from the checked-out branch when SOURCE_BRANCH is not set.
SOURCE_BRANCH="${SOURCE_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}"

echo ""
echo "=== Changelog Check ==="

# The prefix autoupdate names its aggregate branch with: `aggregate_branch_prefix`
# in autoupdate's own configuration, `chore/autoupdate-` by default. Set
# AUTOUPDATE_BRANCH_PREFIX in the consumer's CI variables for a repository that
# customised it.
AUTOUPDATE_PREFIX="${AUTOUPDATE_BRANCH_PREFIX:-chore/autoupdate-}"

if [ -f ".chlog.yaml" ] || [ -f ".chlog.yml" ] || [ -d ".changes/unreleased" ]; then
  echo "Detected chlog-based changelog."

  case "$SOURCE_BRANCH" in
    chore/bump-*|bump/*)
      # Release/bump PRs run `chlog merge`, which moves the unreleased fragments
      # into CHANGELOG.md, so the requirement flips to CHANGELOG.md being updated.
      echo "Release/bump branch detected ('$SOURCE_BRANCH')."

      CHANGELOG_MODIFIED=$(git diff --name-only "origin/$TARGET_BRANCH"...HEAD -- 'CHANGELOG.md' 2>/dev/null || true)
      if [ -z "$CHANGELOG_MODIFIED" ]; then
        echo ""
        echo "============================================================"
        echo "  ERROR: Release/bump PR did not update CHANGELOG.md."
        echo "============================================================"
        echo ""
        exit 1
      fi

      echo "CHANGELOG.md was updated. OK."
      ;;
    dependabot/*)
      # Dependabot never writes an entry and cannot be made to (read-only token on
      # its branches), and autoupdate cannot take over because it skips SHA pins.
      echo "Dependency-bot branch detected; changelog fragment not required."
      ;;
    "$AUTOUPDATE_PREFIX"*)
      # autoupdate writes NO entry when the target branch already records the
      # statement it would have written. It runs unattended, on a schedule, against
      # the same repositories, so without that check yesterday's bullet is restated
      # verbatim on every run until a release moves it away. A correct run therefore
      # legitimately carries no fragment, and demanding one fails a pull request
      # that is right (rios0rios0/autoupdate, `newChangelogEntries`).
      #
      # The other half of that rule IS checkable, and is what is enforced here:
      # omitting the fragment is acceptable only BECAUSE one is already pending, so
      # something must be pending. Nothing added and nothing pending means the
      # change is written down nowhere -- a real miss, or a dedupe that broke -- and
      # still fails.
      echo "Automation branch detected ('$SOURCE_BRANCH')."

      NEW_FRAGMENTS=$(git diff --name-only --diff-filter=A "origin/$TARGET_BRANCH"...HEAD -- '.changes/unreleased/' 2>/dev/null || true)
      if [ -n "$NEW_FRAGMENTS" ]; then
        echo "Found changelog fragment(s):"
        echo "$NEW_FRAGMENTS"
      else
        # Only a .yaml/.yml file counts as pending. A .gitkeep holding the directory
        # open in git is not an entry, and accepting it would wave through every
        # automation branch in any repository that keeps one.
        PENDING_FRAGMENTS=$(git ls-tree -r --name-only "origin/$TARGET_BRANCH" -- '.changes/unreleased/' 2>/dev/null | grep -E '[.](yaml|yml)$' | head -1 || true)
        if [ -z "$PENDING_FRAGMENTS" ]; then
          echo ""
          echo "============================================================"
          echo "  ERROR: No changelog fragment was added, and none is pending."
          echo ""
          echo "  An automation branch may omit the fragment only when the"
          echo "  target branch already records the same statement as pending."
          echo "  '$TARGET_BRANCH' records none, so this change is written"
          echo "  down nowhere."
          echo ""
          echo "  Run: chlog new --kind <Kind> --body \"<description>\""
          echo "  See: https://github.com/luizjhonata/chlog"
          echo "============================================================"
          echo ""
          exit 1
        fi
        echo "No new fragment, and '$TARGET_BRANCH' already records pending fragment(s):"
        echo "$PENDING_FRAGMENTS"
      fi
      ;;
    *)
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
      ;;
  esac
else
  echo "Checking CHANGELOG.md modifications against '$TARGET_BRANCH'..."

  CHANGED_FILES=$(git diff --name-only "origin/$TARGET_BRANCH"...HEAD -- 'CHANGELOG.md' 2>/dev/null || true)
  if [ -z "$CHANGED_FILES" ]; then
    # The same exemption the chlog path above makes, for a repository that keeps a
    # hand-written CHANGELOG.md: autoupdate suppresses the entry when [Unreleased]
    # on the target branch already states it.
    case "$SOURCE_BRANCH" in
      dependabot/*)
        echo "Dependency-bot branch detected; CHANGELOG.md entry not required."
        exit 0
        ;;
    esac

    PENDING_ENTRIES=''
    case "$SOURCE_BRANCH" in
      "$AUTOUPDATE_PREFIX"*)
        PENDING_ENTRIES=$(git show "origin/$TARGET_BRANCH:CHANGELOG.md" 2>/dev/null | awk '/^##[[:space:]]*\[Unreleased\]/{inside=1;next} /^##[[:space:]]*\[/{inside=0} inside && /^[[:space:]]*[-*][[:space:]]/{print;exit}' || true)
        ;;
    esac

    if [ -n "$PENDING_ENTRIES" ]; then
      echo "Automation branch detected ('$SOURCE_BRANCH')."
      echo "No CHANGELOG.md change, and [Unreleased] on '$TARGET_BRANCH' already records entries. OK."
      exit 0
    fi

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
  # Throwaway repos must not inherit the developer's signing config. A machine with
  # `commit.gpgsign = true` globally -- and a signer that needs an unlocked agent -- fails every
  # commit below with `failed to write commit object`, which surfaces as `Error 128` from make and
  # reads like a bug in the fixture rather than like the local environment. Nothing here is
  # published, so a signature would prove nothing about anything.
  git config commit.gpgsign false >/dev/null 2>&1
  git config tag.gpgsign false >/dev/null 2>&1
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

# The real shared script, run from the fixture's working tree exactly as a
# consumer would run it. The source branch is passed explicitly so the bump-branch
# flip is exercised through the documented argument rather than through whatever
# the fixture happens to have checked out.
REAL_SCRIPT="$REPO_ROOT/global/scripts/shared/changelog-check.sh"

assert_script_pass() {
  local description="$1"
  local source_branch
  source_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if sh "$REAL_SCRIPT" main "$source_branch" >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC} changelog-check.sh: $description"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}FAIL${NC} changelog-check.sh: $description (expected pass, got fail)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# `assert_script_fail <description> <expected-message>` -- the second argument is
# NOT optional decoration. A script that rejects everything satisfies a bare
# "expected fail" on every negative fixture, which is precisely how the
# non-chlog-aware version of this script scored 9 of these 10 assertions while
# being wrong: it refused a legitimate fragment-only branch AND refused the
# invalid ones, for the same reason, and only the positive fixture noticed.
# Requiring the message pins WHICH branch of the check refused, so a negative
# assertion cannot be satisfied by the wrong code path.
assert_script_fail() {
  local description="$1"
  local expected="$2"
  local source_branch output
  source_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if output="$(sh "$REAL_SCRIPT" main "$source_branch" 2>&1)"; then
    echo -e "${RED}FAIL${NC} changelog-check.sh: $description (expected fail, got pass)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  elif ! printf '%s' "$output" | grep -qF "$expected"; then
    echo -e "${RED}FAIL${NC} changelog-check.sh: $description (failed for the wrong reason; expected \"$expected\")"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  else
    echo -e "${GREEN}PASS${NC} changelog-check.sh: $description"
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
assert_script_pass "chlog repo with fragment added"

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
assert_script_fail "chlog repo without fragment" "No changelog fragment was added"

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
assert_script_fail "chlog repo with only modified (not new) fragment" "No changelog fragment was added"

echo ""
echo "Test 4: chlog repo on bump branch with CHANGELOG.md updated (no fragment) → should pass"
WORK_DIR="$(setup_repo "chlog-bump-pass")"
cd "$WORK_DIR"
touch .chlog.yaml
mkdir -p .changes/unreleased
echo "kind: Added" > .changes/unreleased/frag.yaml
git add .chlog.yaml .changes/unreleased/frag.yaml
git commit -m "add chlog config and fragment" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
git checkout -b chore/bump-1.2.0 >/dev/null 2>&1
# simulate `chlog merge`: consume the fragment into CHANGELOG.md
git rm -q .changes/unreleased/frag.yaml
sed -i 's/## \[Unreleased\]/## [Unreleased]\n\n## [1.2.0] - 2026-01-02\n\n### Added\n\n- merged feature/' CHANGELOG.md
git add CHANGELOG.md
git commit -m "chore(bump): bumped version to 1.2.0" >/dev/null 2>&1
assert_pass "chlog repo on bump branch with CHANGELOG.md updated"
assert_script_pass "chlog repo on bump branch with CHANGELOG.md updated"

echo ""
echo "Test 5: chlog repo on bump branch without CHANGELOG.md update → should fail"
WORK_DIR="$(setup_repo "chlog-bump-fail")"
cd "$WORK_DIR"
touch .chlog.yaml
git add .chlog.yaml
git commit -m "add chlog config" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
git checkout -b chore/bump-1.2.0 >/dev/null 2>&1
echo "some change" > src.txt
git add src.txt
git commit -m "chore(bump): bump without changelog" >/dev/null 2>&1
assert_fail "chlog repo on bump branch without CHANGELOG.md update"
assert_script_fail "chlog repo on bump branch without CHANGELOG.md update" "Release/bump PR did not update CHANGELOG.md"

echo ""
echo "Test 6: chlog repo on 'bump/*' branch with CHANGELOG.md updated → should pass"
WORK_DIR="$(setup_repo "chlog-bump-slash-pass")"
cd "$WORK_DIR"
touch .chlog.yaml
mkdir -p .changes/unreleased
echo "kind: Added" > .changes/unreleased/frag.yaml
git add .chlog.yaml .changes/unreleased/frag.yaml
git commit -m "add chlog config and fragment" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
git checkout -b bump/1.2.0 >/dev/null 2>&1
git rm -q .changes/unreleased/frag.yaml
sed -i 's/## \[Unreleased\]/## [Unreleased]\n\n## [1.2.0] - 2026-01-02\n\n### Added\n\n- merged feature/' CHANGELOG.md
git add CHANGELOG.md
git commit -m "bump: bumped version to 1.2.0" >/dev/null 2>&1
assert_pass "chlog repo on 'bump/*' branch with CHANGELOG.md updated"
assert_script_pass "chlog repo on 'bump/*' branch with CHANGELOG.md updated"

# ── legacy mode ───────────────────────────────────────────────────────────────

echo ""
echo "── legacy mode ──"

echo ""
echo "Test 7: legacy repo with CHANGELOG.md modified under [Unreleased] → should pass"
WORK_DIR="$(setup_repo "legacy-pass")"
cd "$WORK_DIR"
git checkout -b feat/test >/dev/null 2>&1
sed -i 's/## \[Unreleased\]/## [Unreleased]\n\n### Added\n\n- new feature/' CHANGELOG.md
git add CHANGELOG.md
git commit -m "add changelog entry" >/dev/null 2>&1
assert_pass "legacy repo with CHANGELOG.md entry under [Unreleased]"
assert_script_pass "legacy repo with CHANGELOG.md entry under [Unreleased]"

echo ""
echo "Test 8: legacy repo without CHANGELOG.md modification → should fail"
WORK_DIR="$(setup_repo "legacy-fail")"
cd "$WORK_DIR"
git checkout -b feat/test >/dev/null 2>&1
echo "some change" > src.txt
git add src.txt
git commit -m "change without changelog" >/dev/null 2>&1
assert_fail "legacy repo without CHANGELOG.md modification"
assert_script_fail "legacy repo without CHANGELOG.md modification" "CHANGELOG.md was NOT modified"

echo ""
echo "Test 9: legacy repo with entry below version section (not under [Unreleased]) → should fail"
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
assert_script_fail "legacy repo with entry below version section" "entries are NOT under [Unreleased]"

echo ""
echo "Test 10: legacy repo with CHANGELOG.md missing [Unreleased] section → should fail"
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
assert_script_fail "legacy repo with CHANGELOG.md missing [Unreleased] section" "does not contain an [Unreleased] section"

# ── automation branches (autoupdate's dedupe) ─────────────────────────────────
#
# autoupdate does not restate an entry the target branch already records as
# pending -- it runs unattended on a schedule, so without that check yesterday's
# bullet is written again verbatim on every run. A correct autoupdate branch can
# therefore carry no entry at all, and the strict rules above fail it.
#
# For a branch carrying the automation prefix the requirement becomes "a new
# entry OR one already pending". The fixtures below pin both halves: the
# exemption applies, it is NOT a blanket skip (nothing pending still fails), and
# it does NOT extend to human branches -- for a person who forgot the entry,
# "something else was already pending" is a coincidence, not a defence.

echo ""
echo "── automation branches (autoupdate dedupe) ──"

echo ""
echo "Test 11: chlog repo, automation branch, no fragment, target has one pending -> should pass"
WORK_DIR="$(setup_repo "auto-chlog-pending")"
cd "$WORK_DIR"
touch .chlog.yaml
mkdir -p .changes/unreleased
echo "kind: 'Changed'" > .changes/unreleased/pending.yaml
git add .chlog.yaml .changes/unreleased/pending.yaml
git commit -m "add chlog config and a pending fragment" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
git checkout -b chore/autoupdate-2026-08-26 >/dev/null 2>&1
echo "require example.com/x v1.2.3" > go.mod
git add go.mod
git commit -m "chore(deps): update Go module dependencies" >/dev/null 2>&1
assert_pass "chlog repo, automation branch, entry already pending on target"
assert_script_pass "chlog repo, automation branch, entry already pending on target"

echo ""
echo "Test 12: chlog repo, automation branch, no fragment, nothing pending -> should fail"
WORK_DIR="$(setup_repo "auto-chlog-empty")"
cd "$WORK_DIR"
mkdir -p .changes/unreleased
# A .gitkeep is what holds the directory open in git; it is not an entry, and
# counting it would wave through every automation branch in such a repository.
touch .changes/unreleased/.gitkeep
git add .changes/unreleased/.gitkeep
git commit -m "add an empty unreleased directory" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
git checkout -b chore/autoupdate-2026-08-26 >/dev/null 2>&1
echo "require example.com/x v1.2.3" > go.mod
git add go.mod
git commit -m "chore(deps): update Go module dependencies" >/dev/null 2>&1
assert_fail "chlog repo, automation branch, nothing added and nothing pending"
assert_script_fail "chlog repo, automation branch, nothing added and nothing pending" \
  "No changelog fragment was added, and none is pending"

echo ""
echo "Test 13: chlog repo, automation branch, fragment added -> should pass"
WORK_DIR="$(setup_repo "auto-chlog-fragment")"
cd "$WORK_DIR"
touch .chlog.yaml
git add .chlog.yaml
git commit -m "add chlog config" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
git checkout -b chore/autoupdate-2026-08-26 >/dev/null 2>&1
mkdir -p .changes/unreleased
echo "kind: 'Changed'" > .changes/unreleased/new.yaml
git add .changes/unreleased/new.yaml
git commit -m "chore(deps): update Go module dependencies" >/dev/null 2>&1
assert_pass "chlog repo, automation branch, fragment added"
assert_script_pass "chlog repo, automation branch, fragment added"

echo ""
echo "Test 14: chlog repo, HUMAN branch, no fragment, target has one pending -> should fail"
WORK_DIR="$(setup_repo "auto-chlog-human")"
cd "$WORK_DIR"
touch .chlog.yaml
mkdir -p .changes/unreleased
echo "kind: 'Changed'" > .changes/unreleased/pending.yaml
git add .chlog.yaml .changes/unreleased/pending.yaml
git commit -m "add chlog config and a pending fragment" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
git checkout -b feat/test >/dev/null 2>&1
echo "some change" > src.txt
git add src.txt
git commit -m "change without fragment" >/dev/null 2>&1
assert_fail "chlog repo, human branch, pending fragment is not a defence"
assert_script_fail "chlog repo, human branch, pending fragment is not a defence" \
  "No changelog fragment was added"

echo ""
echo "Test 15: legacy repo, automation branch, no edit, [Unreleased] has entries -> should pass"
WORK_DIR="$(setup_repo "auto-legacy-pending")"
cd "$WORK_DIR"
sed -i 's/## \[Unreleased\]/## [Unreleased]\n\n### Changed\n\n- changed the Go module dependencies to their latest versions/' CHANGELOG.md
git add CHANGELOG.md
git commit -m "record a pending entry" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
git checkout -b chore/autoupdate-2026-08-26 >/dev/null 2>&1
echo "require example.com/x v1.2.3" > go.mod
git add go.mod
git commit -m "chore(deps): update Go module dependencies" >/dev/null 2>&1
assert_pass "legacy repo, automation branch, entry already under [Unreleased]"
assert_script_pass "legacy repo, automation branch, entry already under [Unreleased]"

echo ""
echo "Test 16: legacy repo, automation branch, no edit, [Unreleased] empty -> should fail"
WORK_DIR="$(setup_repo "auto-legacy-empty")"
cd "$WORK_DIR"
git checkout -b chore/autoupdate-2026-08-26 >/dev/null 2>&1
echo "require example.com/x v1.2.3" > go.mod
git add go.mod
git commit -m "chore(deps): update Go module dependencies" >/dev/null 2>&1
assert_fail "legacy repo, automation branch, nothing recorded anywhere"
assert_script_fail "legacy repo, automation branch, nothing recorded anywhere" \
  "CHANGELOG.md was NOT modified"

echo ""
echo "Test 17: legacy repo, HUMAN branch, no edit, [Unreleased] has entries -> should fail"
WORK_DIR="$(setup_repo "auto-legacy-human")"
cd "$WORK_DIR"
sed -i 's/## \[Unreleased\]/## [Unreleased]\n\n### Changed\n\n- an entry somebody else recorded/' CHANGELOG.md
git add CHANGELOG.md
git commit -m "record a pending entry" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
git checkout -b feat/test >/dev/null 2>&1
echo "some change" > src.txt
git add src.txt
git commit -m "change without changelog" >/dev/null 2>&1
assert_fail "legacy repo, human branch, pending entry is not a defence"
assert_script_fail "legacy repo, human branch, pending entry is not a defence" \
  "CHANGELOG.md was NOT modified"

# ── dependency bots ───────────────────────────────────────────────────────────
#
# Dependabot is exempted OUTRIGHT, where autoupdate's exemption above is
# conditional, and the asymmetry is the point: autoupdate can write an entry and
# merely declines to restate one already pending, while Dependabot cannot write
# one at all. Its branches carry a read-only token, so nothing running on them
# can commit a fragment back, and this organisation's own updater is not a
# substitute --- it deliberately skips SHA pins, which is exactly what these
# repositories pin with. Before the gate reached them, every merged Dependabot
# pull request carried no changelog entry of any kind.
#
# The fixtures pin both halves, as the autoupdate ones do: the exemption applies
# on the chlog path and the legacy path, and it does NOT extend to a human
# branch that merely happens to bump a dependency.

echo ""
echo "── dependency bots (unconditional exemption) ──"

echo ""
echo "Test 18: chlog repo, dependabot branch, no fragment -> should pass"
WORK_DIR="$(setup_repo "dependabot-chlog")"
cd "$WORK_DIR"
touch .chlog.yaml
mkdir -p .changes/unreleased
touch .changes/unreleased/.gitkeep
git add .chlog.yaml .changes/unreleased/.gitkeep
git commit -m "add chlog config" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
git checkout -b dependabot/github_actions/github-actions-7a5a078ad4 >/dev/null 2>&1
mkdir -p .github/workflows
echo "      - uses: actions/checkout@d23441a # v6.1.0" > .github/workflows/build.yaml
git add .github/workflows/build.yaml
git commit -m "chore(deps): bump actions/checkout" >/dev/null 2>&1
assert_pass "chlog repo, dependabot branch, no fragment"
assert_script_pass "chlog repo, dependabot branch, no fragment"

echo ""
echo "Test 19: legacy repo, dependabot branch, no CHANGELOG.md edit -> should pass"
WORK_DIR="$(setup_repo "dependabot-legacy")"
cd "$WORK_DIR"
git checkout -b dependabot/github_actions/github-actions-781e586a15 >/dev/null 2>&1
mkdir -p .github/workflows
echo "      - uses: actions/setup-go@924ae3a # v6.5.0" > .github/workflows/build.yaml
git add .github/workflows/build.yaml
git commit -m "chore(deps): bump actions/setup-go" >/dev/null 2>&1
assert_pass "legacy repo, dependabot branch, no CHANGELOG.md edit"
assert_script_pass "legacy repo, dependabot branch, no CHANGELOG.md edit"

echo ""
echo "Test 20: chlog repo, HUMAN branch bumping a dependency, no fragment -> should fail"
WORK_DIR="$(setup_repo "dependabot-human")"
cd "$WORK_DIR"
touch .chlog.yaml
mkdir -p .changes/unreleased
touch .changes/unreleased/.gitkeep
git add .chlog.yaml .changes/unreleased/.gitkeep
git commit -m "add chlog config" >/dev/null 2>&1
git push origin main >/dev/null 2>&1
git checkout -b feat/bump-actions-by-hand >/dev/null 2>&1
mkdir -p .github/workflows
echo "      - uses: actions/checkout@d23441a # v6.1.0" > .github/workflows/build.yaml
git add .github/workflows/build.yaml
git commit -m "chore(deps): bump actions/checkout by hand" >/dev/null 2>&1
assert_fail "chlog repo, human branch bumping a dependency, no fragment"
assert_script_fail "chlog repo, human branch bumping a dependency, no fragment" \
  "No changelog fragment was added"

# ── the four implementations must move together ───────────────────────────────
#
# The fixtures above run the rule twice: through the extracted Azure logic and
# through the real shared script. The GitHub and GitLab templates hold the same
# rule in their own inline copies and cannot be executed here (a composite
# action and a GitLab job body are not standalone scripts). This is the cheap
# tripwire for them: if a future edit drops the chlog branch from any one of the
# four, one of these fails and names the file. It is deliberately structural --
# it proves the code path still EXISTS, not that it behaves; behaviour is what
# the twenty assertions above are for.

echo ""
echo "── all four implementations carry the chlog path ──"

assert_contains() {
  local file="$1"
  local needle="$2"
  if grep -qF -- "$needle" "$REPO_ROOT/$file"; then
    echo -e "${GREEN}PASS${NC} $file mentions '$needle'"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}FAIL${NC} $file no longer mentions '$needle' -- the four changelog checks have drifted"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

for impl in \
  'global/scripts/shared/changelog-check.sh' \
  'github/global/stages/10-code-check/basic-checks/action.yaml' \
  'gitlab/global/stages/10-code-check/basic-checks.yaml' \
  'azure-devops/global/stages/10-code-check/basic-checks.yaml'; do
  assert_contains "$impl" '.chlog.yaml'
  # The dependency-bot exemption is the newest of the four-way duplications and
  # so the easiest to drop from one copy while editing another.
  assert_contains "$impl" 'dependabot/*)'
  assert_contains "$impl" '.changes/unreleased/'
  # `--diff-filter=A` is the load-bearing half of the fragment rule: without it,
  # editing an entry somebody else already recorded counts as this change's entry.
  assert_contains "$impl" '--diff-filter=A'
  assert_contains "$impl" 'chore/bump-*|bump/*'
  # The automation exemption: autoupdate legitimately files no entry when the
  # target branch already records the statement, so dropping this arm turns every
  # scheduled dependency pull request red.
  assert_contains "$impl" 'AUTOUPDATE_BRANCH_PREFIX'
  assert_contains "$impl" '"$AUTOUPDATE_PREFIX"*)'
done

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results ==="
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]]
