#!/bin/bash

REPO_URL="https://github.com/rios0rios0/pipelines.git"
CLONE_PATH="$HOME/Development/github.com/rios0rios0"

clone_repository() {
    if [ -d "$CLONE_PATH" ]; then
        echo "Base directory found in $CLONE_PATH..."

        if [ -d "$CLONE_PATH" ]; then
            echo "The repository exists locally at $CLONE_PATH..."
        else
            echo "The repository not found locally. Cloning in $CLONE_PATH..."
            git clone "$REPO_URL" "$CLONE_PATH"
        fi
    else
        echo "Base directory not found in $CLONE_PATH."
        echo "Make sure the base directory exists before cloning the repository..."
    fi
}

clone_repository

