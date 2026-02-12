#!/usr/bin/env sh
#
# Checks if the current branch is rebased on top of the target branch.
# If the target branch HEAD is NOT an ancestor of the current HEAD, the branch
# needs rebasing and this script exits with a non-zero code.
#
# Usage: rebase-check.sh <target-branch>
#   e.g.: rebase-check.sh main

set -e

TARGET_BRANCH="${1:?'ERROR: target branch name is required as the first argument'}"

echo "$(date "+%Y-%m-%d %H:%M:%S") - Checking if branch is rebased on top of '$TARGET_BRANCH'..."

# Fetch the target branch from origin (shallow fetch is enough for the check)
git fetch origin "$TARGET_BRANCH" --no-tags 2>/dev/null || {
  echo "WARNING: could not fetch 'origin/$TARGET_BRANCH', skipping rebase check."
  exit 0
}

# Check if the target branch HEAD is an ancestor of the current HEAD.
# If it IS an ancestor, the branch is properly rebased (exit 0).
# If it is NOT an ancestor, the branch is behind and needs rebasing (exit 1).
if git merge-base --is-ancestor "origin/$TARGET_BRANCH" HEAD; then
  echo "$(date "+%Y-%m-%d %H:%M:%S") - Branch is up-to-date with '$TARGET_BRANCH'. No rebase needed."
else
  BEHIND_COUNT=$(git rev-list HEAD.."origin/$TARGET_BRANCH" --count 2>/dev/null || echo "unknown")
  echo ""
  echo "============================================================"
  echo "  ERROR: Branch is NOT rebased on top of '$TARGET_BRANCH'."
  echo "  The branch is $BEHIND_COUNT commit(s) behind."
  echo ""
  echo "  Please rebase your branch:"
  echo "    git fetch origin $TARGET_BRANCH"
  echo "    git rebase origin/$TARGET_BRANCH"
  echo "    git push --force-with-lease"
  echo "============================================================"
  echo ""
  exit 1
fi
