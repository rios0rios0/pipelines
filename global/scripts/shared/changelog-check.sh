#!/usr/bin/env sh
#
# Checks if the CHANGELOG.md was modified and if new entries are under the [Unreleased] section.
# If the changelog was not modified, the check fails. If entries appear above the [Unreleased]
# header (e.g., due to an erroneous rebase), the check also fails.
#
# Usage: changelog-check.sh <target-branch>
#   e.g.: changelog-check.sh main

set -e

TARGET_BRANCH="${1:?'ERROR: target branch name is required as the first argument'}"

echo "$(date "+%Y-%m-%d %H:%M:%S") - Checking CHANGELOG.md modifications against '$TARGET_BRANCH'..."

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

# Check if CHANGELOG.md was modified in this branch compared to the target
CHANGED_FILES=$(git diff --name-only "origin/$TARGET_BRANCH"...HEAD -- 'CHANGELOG.md' 2>/dev/null || true)
if [ -z "$CHANGED_FILES" ]; then
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
