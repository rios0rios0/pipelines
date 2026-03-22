#!/usr/bin/env bash
# Cross-compile check: validates the module for all target platforms to catch
# platform-specific type errors (e.g., syscall.Handle vs int on Windows).
# Uses "go vet" instead of "go build" — this performs full type-checking without
# linking (faster), and additionally runs vet diagnostics (printf, structtag, etc.)
# which may surface issues beyond pure compilation errors.
set -euo pipefail

TARGETS=(
  "linux/amd64"
  "linux/arm64"
  "darwin/amd64"
  "darwin/arm64"
  "windows/amd64"
  "windows/arm64"
  "android/amd64"
  "android/arm64"
)

# Targets that require cgo (external linking). These are checked with CGO_ENABLED=1
# and skipped when no C cross-compiler is available.
CGO_REQUIRED_OS="android"

FAILED=0
for target in "${TARGETS[@]}"; do
  IFS='/' read -r os arch <<< "$target"
  echo "=== Type-checking for ${os}/${arch} ==="

  cgo_enabled=0
  if [[ "$os" == "$CGO_REQUIRED_OS" ]]; then
    cgo_enabled=1
  fi

  output=$(CGO_ENABLED="$cgo_enabled" GOOS="$os" GOARCH="$arch" go vet ./... 2>&1) || {
    if [[ "$cgo_enabled" -eq 1 ]] && echo "$output" | grep -q "requires external (cgo) linking"; then
      echo "SKIP: ${os}/${arch} (requires cgo; no C cross-compiler available)"
    else
      echo "$output"
      echo "FAIL: ${os}/${arch}"
      FAILED=1
    fi
  }
done

if [ "$FAILED" -ne 0 ]; then
  echo "Cross-compilation check failed for one or more targets"
  exit 1
fi
echo "Cross-compilation check passed for all targets"
