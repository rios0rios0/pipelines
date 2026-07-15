#!/usr/bin/env bash
set -euo pipefail

BINARY_NAME="${1:?Binary name is required as the first argument}"
BINARY_PATH="${2:-.}" # Optional, defaults to "."

if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
fi

TEMPLATE="$SCRIPTS_DIR/global/scripts/languages/golang/goreleaser/.goreleaser.yaml"
PROJECT_ROOT="$(realpath "$PWD")"

# Renders a package directory the way GoReleaser wants it: relative to the
# project root, prefixed with "./". Absolute directories (what `go list` prints)
# are made relative, and the project root itself collapses to "." — so neither
# "././cmd/app" nor "./." can be emitted.
to_package_path() {
  local path="${1%/}"
  path="${path#./}"

  if [ "$path" != "${path#/}" ]; then
    path="$(realpath --relative-to="$PROJECT_ROOT" "$path" 2>/dev/null || printf '%s' "$path")"
  fi

  if [ -z "$path" ] || [ "$path" = "." ]; then
    printf '.'
  else
    printf './%s' "$path"
  fi
}

# Lists the directory of every `main` package by asking the Go toolchain, which
# is the only trustworthy source. It reads the package clause and skips test
# files and `testdata/`, so — unlike a text search — it cannot be fooled by a
# `func main()` that lives inside a raw string literal. Repositories whose tests
# build sample programs as fixtures do contain exactly that.
list_main_dirs_with_go() {
  go list -e -f '{{if eq .Name "main"}}{{.Dir}}{{end}}' ./... 2>/dev/null | grep -v '^$' || true
}

# Fallback for when the Go toolchain is unavailable. Still far stricter than a
# bare `func main()` search: test files, `testdata/` and `vendor/` are skipped,
# and the file must actually declare `package main` — in any shape the compiler
# accepts, so padding, a CRLF line ending and a trailing comment all count, while
# `package maintenance` does not. The clause has to start at column 0 though:
# gofmt guarantees that for real code, and withholding it is what keeps an
# indented sample program inside a raw string literal from passing for one.
list_main_dirs_with_grep() {
  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$file" in
      *_test.go) continue ;;
    esac
    if grep -qE '^package[[:space:]]+main([[:space:]]|//|/\*|$)' "$file"; then
      dirname "$file"
    fi
  done <<< "$(grep -rl '^func main()' --include='*.go' --exclude-dir='testdata' --exclude-dir='vendor' . 2>/dev/null || true)"
}

# A repository may ship several binaries (./cmd/api, ./cmd/worker, ...). Release
# the one named after the binary being built, and fall back to the first found.
pick_main_dir() {
  local candidates="$1"
  local preferred=""
  local dir=""

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ "$(basename "$dir")" = "$BINARY_NAME" ]; then
      printf '%s' "$dir"
      return 0
    fi
    [ -n "$preferred" ] || preferred="$dir"
  done <<< "$candidates"

  printf '%s' "$preferred"
}

# Step 1: Check if project already has a goreleaser config
if [ -f ".goreleaser.yaml" ] || [ -f ".goreleaser.yml" ]; then
  echo "Project has its own .goreleaser config, using it as-is."
  exit 0
fi

# Step 2: Auto-detect the main package unless the caller pinned one
if [ "$BINARY_PATH" = "." ]; then
  CANDIDATES=""
  if command -v go > /dev/null 2>&1 && [ -f "go.mod" ]; then
    CANDIDATES="$(list_main_dirs_with_go)"
  fi
  if [ -z "$CANDIDATES" ]; then
    CANDIDATES="$(list_main_dirs_with_grep)"
  fi

  MAIN_DIR="$(pick_main_dir "$CANDIDATES")"
  if [ -n "$MAIN_DIR" ]; then
    BINARY_PATH="$(to_package_path "$MAIN_DIR")"
    echo "Auto-detected main package at: $BINARY_PATH"
  else
    echo "Warning: Could not detect main package, using root (.)"
    BINARY_PATH="."
  fi
else
  BINARY_PATH="$(to_package_path "$BINARY_PATH")"
fi

# Step 3: Copy template and replace placeholders
cp "$TEMPLATE" .goreleaser.yaml
sed -i "s|__BINARY_NAME__|$BINARY_NAME|g" .goreleaser.yaml
sed -i "s|__BINARY_PATH__|$BINARY_PATH|g" .goreleaser.yaml

# Step 4: Exclude generated file from git
mkdir -p .git/info
echo '.goreleaser.yaml' >> .git/info/exclude

echo "Generated .goreleaser.yaml for '$BINARY_NAME' (main: $BINARY_PATH)"
