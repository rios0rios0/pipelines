#!/usr/bin/env sh
#
# reconcile-releases.sh — detect "release cut-off" gaps.
#
# A bump PR that merges to main but whose main-branch run fails the quality gate
# leaves CHANGELOG.md carrying a version heading that has no git tag / release
# (the `delivery-release` job never ran). This script diffs the released
# CHANGELOG versions against the existing tags and, for every gap, resolves the
# commit that should carry the tag (the bump commit).
#
# Read-only. Prints one TSV row per gap to stdout:
#
#     <version><TAB><commit-sha-or-dash><TAB><status>
#
# where <status> is "recoverable" (a bump commit was found — push the tag to let
# the tag-push delivery path re-cut the release) or "needs-review" (no bump
# commit found — a human should investigate). Empty output means no gaps.
#
# Usage: reconcile-releases.sh [REPO_DIR] [CHANGELOG_PATH]
set -eu

REPO_DIR="${1:-.}"
CHANGELOG="${2:-CHANGELOG.md}"

cd "$REPO_DIR"

if [ ! -f "$CHANGELOG" ]; then
  echo "reconcile: no ${CHANGELOG} in ${REPO_DIR}, nothing to do" >&2
  exit 0
fi

# Released versions = "## [X.Y.Z] - <date>" headings. Requiring the "- " date
# separator excludes "## [Unreleased]" and any heading not yet dated/released.
# The optional fourth segment covers the fork variant (X.Y.Z.N / X.Y.Z-N).
versions="$(grep -oE '^##[[:space:]]+\[[0-9]+\.[0-9]+\.[0-9]+([.-][0-9]+)?\][[:space:]]+-[[:space:]]' "$CHANGELOG" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([.-][0-9]+)?' || true)"

tags="$(git tag 2>/dev/null || true)"

# A version is present if either the bare "X.Y.Z" or the "vX.Y.Z" tag exists.
tag_exists() {
  escaped="$(printf '%s' "$1" | sed 's/[.]/\\./g')"
  printf '%s\n' "$tags" | grep -qxE "v?${escaped}"
}

# Resolve the commit that should carry the tag for a version: the bump commit,
# identified by its message, falling back to the commit that first introduced
# the changelog heading. The "($|[^0-9])" boundary stops "2.32.1" from matching
# a "2.32.14" bump.
find_bump_commit() {
  v="$1"
  escaped="$(printf '%s' "$v" | sed 's/[.]/\\./g')"
  sha="$(git log --format='%H' -E --grep="chore/bump-${escaped}(\$|[^0-9])" -n 1 2>/dev/null || true)"
  if [ -z "$sha" ]; then
    sha="$(git log --format='%H' -E --grep="version to ${escaped}(\$|[^0-9])" -n 1 2>/dev/null || true)"
  fi
  if [ -z "$sha" ]; then
    sha="$(git log --reverse --format='%H' -S"## [${v}]" -- "$CHANGELOG" 2>/dev/null | head -n 1 || true)"
  fi
  printf '%s' "$sha"
}

printf '%s\n' "$versions" | while IFS= read -r v; do
  [ -n "$v" ] || continue
  if tag_exists "$v"; then
    continue
  fi
  sha="$(find_bump_commit "$v")"
  if [ -n "$sha" ]; then
    printf '%s\t%s\trecoverable\n' "$v" "$sha"
  else
    printf '%s\t%s\tneeds-review\n' "$v" "-"
  fi
done
