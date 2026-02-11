#!/usr/bin/env bash
# clone.sh -- Idempotent installer for the rios0rios0/pipelines repository.
#
# This script is designed to be used in project Makefiles to bootstrap local
# access to pipeline scripts (linting, SAST, testing, etc.) before pushing.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash
#
# Environment variables:
#   PIPELINES_HOME  Override the default clone location
#                   (default: $HOME/Development/github.com/rios0rios0/pipelines)
#
# Behavior:
#   - First run:  clones the repository to PIPELINES_HOME
#   - Subsequent: pulls the latest changes (fast-forward only)

set -euo pipefail

REPO_URL="https://github.com/rios0rios0/pipelines.git"
CLONE_DIR="${PIPELINES_HOME:-$HOME/Development/github.com/rios0rios0/pipelines}"

if [ -d "$CLONE_DIR/.git" ]; then
  echo "Updating pipelines repository at $CLONE_DIR..."
  git -C "$CLONE_DIR" pull --ff-only
else
  echo "Cloning pipelines repository to $CLONE_DIR..."
  mkdir -p "$(dirname "$CLONE_DIR")"
  git clone "$REPO_URL" "$CLONE_DIR"
fi

echo ""
echo "Done. Add the following to your project Makefile:"
echo ""
echo "  SCRIPTS_DIR ?= $CLONE_DIR"
echo "  -include \$(SCRIPTS_DIR)/makefiles/common.mk"
echo "  -include \$(SCRIPTS_DIR)/makefiles/golang.mk  # or another language"
