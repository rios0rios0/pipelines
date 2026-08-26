#!/usr/bin/env sh
#
# Checks that the branch carries its changelog entry, in whichever form the repository uses.
#
#   - chlog repository (a `.chlog.yaml` / `.chlog.yml`, or a `.changes/unreleased/` directory):
#     an ordinary branch must ADD a fragment under `.changes/unreleased/`. A `bump/*` /
#     `chore/bump-*` branch carries no fragment -- `chlog merge` has already folded the pending
#     ones into CHANGELOG.md -- so the requirement flips to a modified CHANGELOG.md.
#   - every other repository: CHANGELOG.md must be modified, and the new entries must sit under
#     the [Unreleased] section. Entries below an existing version section (e.g., after an
#     erroneous rebase) fail the check.
#
# THE AUTOMATION EXEMPTION (`$AUTOUPDATE_BRANCH_PREFIX`, default `chore/autoupdate-`):
#
# autoupdate does not restate an entry the target branch already records as pending. It runs
# unattended, on a schedule, against the same repositories, so without that check yesterday's
# bullet is written again verbatim on every run until a release moves it away. The consequence
# reaches this check: a correct autoupdate pull request can carry NO fragment and no CHANGELOG.md
# edit -- a Go dependency bump whose one-line entry was already sitting in the unreleased set is
# exactly that -- and the strict rule above fails it. So for a branch carrying the automation
# prefix the requirement becomes: a new entry, OR an entry already pending on the target branch.
# That is the half of autoupdate's rule
# this check can verify from a diff; it cannot know WHICH statement was suppressed, only that
# suppressing one was possible. Nothing added with nothing pending still fails -- that is a real
# miss, or a dedupe that broke.
#
# The exemption is deliberately NOT extended to human branches. "It was already pending" is a
# defence only for a producer that actually compared; for a person who forgot the entry it is a
# coincidence, and catching that is what this check is for.
#
# THIS SCRIPT MIRRORS THE THREE BASIC-CHECKS TEMPLATES AND MUST MOVE WITH THEM:
#
#   github/global/stages/10-code-check/basic-checks/action.yaml
#   gitlab/global/stages/10-code-check/basic-checks.yaml
#   azure-devops/global/stages/10-code-check/basic-checks.yaml
#
# A second, divergent implementation of a check is a defect this repository has already paid
# for once (the GitLab inline Dependency-Track upload, which normalised project names
# differently from the shared script and quietly produced two projects for one application).
# The templates cannot call this file, which is why the duplication exists rather than being an
# oversight: `quality:basic-checks` runs in a minimal image with ONLY the consumer's repository
# on disk -- `alpine/git` on GitLab, `checkout: self` on Azure DevOps -- and none of the three
# jobs bootstraps `.scripts-repo`. Routing them here would add a clone of this repository to
# every merge-request build, to run a check that is pure git plumbing. So they stay inline, and
# a change to the rule has to be made in four places. `.github/tests/test-basic-checks.sh`
# asserts the chlog behaviour of all four, which is what keeps them honest.
#
# Usage: changelog-check.sh <target-branch> [source-branch]
#   e.g.: changelog-check.sh main
#         changelog-check.sh main chore/bump-1.2.3
#
# The source branch decides only the bump-branch flip above. It defaults to the checked-out
# branch name, which is empty on the detached HEAD most CI checkouts produce -- pass it
# explicitly from the CI's own variable when the flip matters.

set -e

TARGET_BRANCH="${1:?'ERROR: target branch name is required as the first argument'}"
SOURCE_BRANCH="${2:-}"
if [ -z "$SOURCE_BRANCH" ]; then
  SOURCE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  [ "$SOURCE_BRANCH" = "HEAD" ] && SOURCE_BRANCH=""
fi

echo "$(date "+%Y-%m-%d %H:%M:%S") - Checking changelog modifications against '$TARGET_BRANCH'..."

# Ensure we have the target branch available for comparison
git fetch origin "$TARGET_BRANCH" --no-tags 2>/dev/null || {
  echo "WARNING: could not fetch 'origin/$TARGET_BRANCH', skipping changelog check."
  exit 0
}

# Guard: if HEAD is already merged into the target branch, skip the check
if git merge-base --is-ancestor HEAD "origin/$TARGET_BRANCH"; then
  echo "$(date "+%Y-%m-%d %H:%M:%S") - Branch HEAD is already part of '$TARGET_BRANCH' (likely merged). Skipping changelog check."
  exit 0
fi

# The prefix autoupdate names its aggregate branch with: `aggregate_branch_prefix`
# in autoupdate's own configuration, `chore/autoupdate-` by default. Set
# AUTOUPDATE_BRANCH_PREFIX in the consumer's CI variables for a repository that
# customised it. Both paths below read it.
AUTOUPDATE_PREFIX="${AUTOUPDATE_BRANCH_PREFIX:-chore/autoupdate-}"

# ---------------------------------------------------------------------------
# chlog repositories: the entry is a fragment, not a line in a shared file.
# ---------------------------------------------------------------------------
# A repository counts as a chlog user when it commits a config file OR when it
# merely carries the fragment directory: the config is optional, and chlog falls
# back to its built-in defaults when none is found. Testing only for .chlog.yaml
# made a repository that dropped the redundant config fall through to the plain
# CHANGELOG.md branch below, demanding a hand-edited changelog from a project that
# generates it from fragments. Mirrors AutoBump's DetectChlog so the two cannot
# disagree about whether a repository uses chlog.
if [ -f ".chlog.yaml" ] || [ -f ".chlog.yml" ] || [ -d ".changes/unreleased" ]; then
  echo "$(date "+%Y-%m-%d %H:%M:%S") - Detected chlog-based changelog."

  case "$SOURCE_BRANCH" in
    chore/bump-*|bump/*)
      # Release/bump PRs run `chlog merge`, which moves the unreleased
      # fragments into CHANGELOG.md. They carry no new fragment, so the
      # requirement flips: the PR must update CHANGELOG.md instead.
      echo "$(date "+%Y-%m-%d %H:%M:%S") - Release/bump branch detected ('$SOURCE_BRANCH')."
      echo "$(date "+%Y-%m-%d %H:%M:%S") - Verifying CHANGELOG.md was updated (fragments merged into it)..."

      CHANGELOG_MODIFIED=$(git diff --name-only "origin/$TARGET_BRANCH"...HEAD -- 'CHANGELOG.md' 2>/dev/null || true)
      if [ -z "$CHANGELOG_MODIFIED" ]; then
        echo ""
        echo "============================================================"
        echo "  ERROR: Release/bump PR did not update CHANGELOG.md."
        echo ""
        echo "  On a bump, chlog moves the unreleased fragments into"
        echo "  CHANGELOG.md. This PR must include the updated CHANGELOG.md."
        echo ""
        echo "  Run: chlog merge"
        echo "  See: https://github.com/luizjhonata/chlog"
        echo "============================================================"
        echo ""
        exit 1
      fi

      echo "$(date "+%Y-%m-%d %H:%M:%S") - CHANGELOG.md was updated. OK."
      exit 0
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
      exit 0
      ;;
    *)
      echo "$(date "+%Y-%m-%d %H:%M:%S") - Checking for new fragments in '.changes/unreleased/'..."

      # `--diff-filter=A` on purpose: editing an existing fragment is not an entry
      # for THIS change, it is a correction to one that was already recorded.
      NEW_FRAGMENTS=$(git diff --name-only --diff-filter=A "origin/$TARGET_BRANCH"...HEAD -- '.changes/unreleased/' 2>/dev/null || true)
      if [ -z "$NEW_FRAGMENTS" ]; then
        echo ""
        echo "============================================================"
        echo "  ERROR: No changelog fragment was added."
        echo ""
        echo "  This project uses chlog for changelog management."
        echo "  Every change must include a changelog fragment."
        echo ""
        echo "  Run: chlog new --kind <Kind> --body \"<description>\""
        echo "  Kinds: Added, Changed, Deprecated, Removed, Fixed, Security"
        echo ""
        echo "  See: https://github.com/luizjhonata/chlog"
        echo "============================================================"
        echo ""
        exit 1
      fi

      echo "$(date "+%Y-%m-%d %H:%M:%S") - Found changelog fragment(s):"
      echo "$NEW_FRAGMENTS"
      exit 0
      ;;
  esac
fi

# Check if CHANGELOG.md was modified in this branch compared to the target
CHANGED_FILES=$(git diff --name-only "origin/$TARGET_BRANCH"...HEAD -- 'CHANGELOG.md' 2>/dev/null || true)
if [ -z "$CHANGED_FILES" ]; then
  # The same exemption the chlog path above makes, for a repository that keeps a
  # hand-written CHANGELOG.md: autoupdate suppresses the entry when [Unreleased]
  # on the target branch already states it.
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
  echo ""
  echo "  Every change must include an entry in CHANGELOG.md"
  echo "  under the [Unreleased] section."
  echo ""
  echo "  See: https://keepachangelog.com/en/1.1.0/"
  echo "============================================================"
  echo ""
  exit 1
fi

echo "$(date "+%Y-%m-%d %H:%M:%S") - CHANGELOG.md was modified. Validating entry placement..."

# Get the diff of CHANGELOG.md to check where new lines were added
DIFF_OUTPUT=$(git diff "origin/$TARGET_BRANCH"...HEAD -- 'CHANGELOG.md' 2>/dev/null || true)

# Extract only added lines (starting with +) excluding the diff header lines (+++, @@)
ADDED_LINES=$(echo "$DIFF_OUTPUT" | grep '^+' | grep -v '^+++' | grep -v '^+$' || true)

if [ -z "$ADDED_LINES" ]; then
  echo "$(date "+%Y-%m-%d %H:%M:%S") - No new content lines added to CHANGELOG.md. Skipping placement check."
  exit 0
fi

# Get the CHANGELOG.md content from the branch being checked
CHANGELOG_CONTENT=$(git show HEAD:CHANGELOG.md 2>/dev/null || true)
if [ -z "$CHANGELOG_CONTENT" ]; then
  echo "WARNING: could not read CHANGELOG.md from HEAD, skipping placement check."
  exit 0
fi

# Find the line number of [Unreleased] section
UNRELEASED_LINE=$(echo "$CHANGELOG_CONTENT" | grep -n '^\#\#\s*\[Unreleased\]' | head -1 | cut -d: -f1)

if [ -z "$UNRELEASED_LINE" ]; then
  echo ""
  echo "============================================================"
  echo "  ERROR: CHANGELOG.md does not contain an [Unreleased] section."
  echo ""
  echo "  The changelog must have a '## [Unreleased]' header."
  echo "  All new entries must be added under this section."
  echo ""
  echo "  See: https://keepachangelog.com/en/1.1.0/"
  echo "============================================================"
  echo ""
  exit 1
fi

# Find the next version section after [Unreleased] (e.g., ## [1.0.0] - 2025-01-01)
NEXT_VERSION_LINE=$(echo "$CHANGELOG_CONTENT" | grep -n '^\#\#\s*\[' | grep -v '\[Unreleased\]' | head -1 | cut -d: -f1)

# Use git diff with line numbers to check where changes were made
# Get the diff with unified format showing line numbers in the new file
DIFF_LINES=$(git diff "origin/$TARGET_BRANCH"...HEAD -- 'CHANGELOG.md' 2>/dev/null || true)

# Parse the @@ hunk headers to find where additions were made
# Format: @@ -old_start,old_count +new_start,new_count @@
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
    # Changes above the [Unreleased] section header are acceptable
    # (e.g., modifying the changelog header or links)
    HAS_VALID_ENTRIES=true
  fi
done

if [ "$HAS_INVALID_ENTRIES" = true ] && [ "$HAS_VALID_ENTRIES" = false ]; then
  echo ""
  echo "============================================================"
  echo "  ERROR: CHANGELOG.md entries are NOT under [Unreleased]."
  echo ""
  echo "  New entries were found below an existing version section."
  echo "  This usually happens after an erroneous rebase."
  echo ""
  echo "  Please move your changelog entries under the"
  echo "  '## [Unreleased]' section."
  echo ""
  echo "  See: https://keepachangelog.com/en/1.1.0/"
  echo "============================================================"
  echo ""
  exit 1
fi

echo "$(date "+%Y-%m-%d %H:%M:%S") - CHANGELOG.md entries are correctly placed under [Unreleased]."
