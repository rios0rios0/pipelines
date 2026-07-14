#!/usr/bin/env bash
# Regression test for global/scripts/languages/golang/goreleaser/prepare.sh.
#
# The script chooses the package GoReleaser builds. It used to do that with
# `grep -rl "^func main()" | head -1` — a text search that cannot tell a real
# entry point apart from a `func main()` sitting inside a raw string literal. In
# a repository whose tests build sample programs as fixtures it therefore picked
# the test's package, and the delivery stage failed with "does not contain a main
# function" *after* the release stage had already published the tag and the
# GitHub Release, leaving a version with no binaries attached to it.
#
# Runs the real script against fixture project trees and asserts on the `main:`
# entry it writes into .goreleaser.yaml.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREPARE="$REPO_ROOT/global/scripts/languages/golang/goreleaser/prepare.sh"
WORKSPACE="$(mktemp -d)"
trap 'rm -rf "$WORKSPACE"' EXIT

export SCRIPTS_DIR="$REPO_ROOT"
export GOTOOLCHAIN='local' # keep the fixtures hermetic: never download a toolchain

new_project() {
  local name="$1"
  local dir="$WORKSPACE/$name"
  mkdir -p "$dir"
  printf 'module example.com/%s\n\ngo 1.21\n' "$name" > "$dir/go.mod"
  printf '%s' "$dir"
}

write_main_package() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/main.go" << 'EOF'
package main

func main() {}
EOF
}

# A package whose *test* embeds a whole sample program as a fixture. This is the
# shape that broke autobump: both `package main` and `func main()` appear in the
# file, but only inside a raw string literal.
write_package_with_embedded_program() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/commands.go" << 'EOF'
package commands

func UpdateVersion() {}
EOF
  cat > "$dir/update_version_test.go" << 'EOF'
package commands

import "testing"

func TestUpdateSwaggerVersion(t *testing.T) {
	mainGoContent := `package main

// @title Example API
// @version 1.2.3
func main() {}
`
	if mainGoContent == "" {
		t.Fatal("unreachable")
	}
}
EOF
}

# Reads back the package GoReleaser was told to build.
configured_main() {
  sed -n "s/^[[:space:]]*-[[:space:]]*main:[[:space:]]*'\(.*\)'[[:space:]]*\$/\1/p" "$1/.goreleaser.yaml" | head -1
}

# Runs the real script inside a project and echoes the `main:` it generated.
generated_main() {
  local dir="$1"
  shift
  (cd "$dir" && "$PREPARE" "$@" > /dev/null)
  configured_main "$dir"
}

assert_main() {
  local description="$1"
  local expected="$2"
  local actual="$3"

  if [ "$actual" = "$expected" ]; then
    echo -e "${GREEN}PASS${NC} $description"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}FAIL${NC} $description (expected='$expected', actual='$actual')"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

echo "=== GoReleaser main package detection ==="

# The regression itself: `internal/` is walked before `cmd/`, so a `head -1` text
# search picks the test fixture and never even sees the real entry point.
PROJECT="$(new_project 'autobump')"
write_main_package "$PROJECT/cmd/autobump"
write_package_with_embedded_program "$PROJECT/internal/domain/commands"
assert_main "ignores a func main() embedded in a test fixture" \
  './cmd/autobump' "$(generated_main "$PROJECT" 'autobump')"

# The same tree without a go.mod, so the toolchain cannot be used and the text
# search runs as a fallback. It must reach the same conclusion.
PROJECT="$(new_project 'autobump-no-module')"
rm "$PROJECT/go.mod"
write_main_package "$PROJECT/cmd/autobump"
write_package_with_embedded_program "$PROJECT/internal/domain/commands"
assert_main "ignores the fixture in the fallback text search too" \
  './cmd/autobump' "$(generated_main "$PROJECT" 'autobump')"

PROJECT="$(new_project 'rooted')"
write_main_package "$PROJECT"
assert_main "detects a main package at the repository root" \
  '.' "$(generated_main "$PROJECT" 'rooted')"

PROJECT="$(new_project 'multi')"
write_main_package "$PROJECT/cmd/api"
write_main_package "$PROJECT/cmd/worker"
assert_main "prefers the main package named after the binary" \
  './cmd/worker' "$(generated_main "$PROJECT" 'worker')"

PROJECT="$(new_project 'pinned')"
write_main_package "$PROJECT/cmd/pinned"
assert_main "honours an explicit binary path" \
  './cmd/pinned' "$(generated_main "$PROJECT" 'pinned' './cmd/pinned')"

PROJECT="$(new_project 'unprefixed')"
write_main_package "$PROJECT/cmd/unprefixed"
assert_main "normalizes an explicit path given without a ./ prefix" \
  './cmd/unprefixed' "$(generated_main "$PROJECT" 'unprefixed' 'cmd/unprefixed')"

PROJECT="$(new_project 'headless')"
assert_main "falls back to the root when there is no main package" \
  '.' "$(generated_main "$PROJECT" 'headless')"

# No real entry point anywhere, only the sample program embedded in a fixture.
# The embedded program is the sole `func main()` in the tree, so a text search
# cannot help but select it — which pins the bug independently of the order the
# filesystem happens to hand directories back in.
PROJECT="$(new_project 'fixture-only')"
write_package_with_embedded_program "$PROJECT/internal/domain/commands"
assert_main "never treats a fixture's embedded program as the entry point" \
  '.' "$(generated_main "$PROJECT" 'fixture-only')"

# A project shipping its own config must be left exactly as it is.
PROJECT="$(new_project 'owned')"
write_main_package "$PROJECT/cmd/owned"
printf "version: 2\nproject_name: 'owned'\nbuilds:\n  - main: './cmd/custom'\n" > "$PROJECT/.goreleaser.yaml"
(cd "$PROJECT" && "$PREPARE" 'owned' > /dev/null)
assert_main "keeps a project's own .goreleaser.yaml" \
  './cmd/custom' "$(configured_main "$PROJECT")"

echo ""
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
