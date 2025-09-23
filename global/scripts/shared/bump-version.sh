#!/usr/bin/env bash
set -e

# Script to bump version and create git tags
# Usage: ./bump-version.sh [patch|minor|major]

BUMP_TYPE=${1:-patch}

# Validate bump type
if [[ ! "$BUMP_TYPE" =~ ^(patch|minor|major)$ ]]; then
    echo "Error: Invalid bump type. Use patch, minor, or major"
    exit 1
fi

# Get current version from git tags
CURRENT_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")

# Remove 'v' prefix if present
CURRENT_VERSION=${CURRENT_VERSION#v}

# Split version into components
IFS='.' read -ra VERSION_PARTS <<< "$CURRENT_VERSION"
MAJOR=${VERSION_PARTS[0]:-0}
MINOR=${VERSION_PARTS[1]:-0}
PATCH=${VERSION_PARTS[2]:-0}

# Bump version based on type
case $BUMP_TYPE in
    "major")
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    "minor")
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    "patch")
        PATCH=$((PATCH + 1))
        ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"
NEW_TAG="v$NEW_VERSION"

echo "Current version: $CURRENT_VERSION"
echo "New version: $NEW_VERSION"
echo "New tag: $NEW_TAG"

# Create and push new tag
git tag "$NEW_TAG"
echo "Created tag: $NEW_TAG"

# If in CI environment, push the tag
if [[ -n "${GITHUB_ACTIONS}" || -n "${CI}" ]]; then
    git push origin "$NEW_TAG"
    echo "Pushed tag: $NEW_TAG"
fi

echo "Version bumped successfully!"
echo "NEW_VERSION=$NEW_VERSION" >> $GITHUB_OUTPUT
echo "NEW_TAG=$NEW_TAG" >> $GITHUB_OUTPUT