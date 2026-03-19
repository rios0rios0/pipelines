#!/usr/bin/env bash
# Cross-compile check: type-checks the module for all target platforms to catch
# platform-specific type errors (e.g., syscall.Handle vs int on Windows).
# Uses "go vet" instead of "go build" to perform type-checking without linking,
# which is faster while still catching the same class of compilation errors.
set -euo pipefail

TARGETS=(
  "linux/amd64"
  "linux/arm64"
  "darwin/amd64"
  "darwin/arm64"
  "windows/amd64"
  "windows/arm64"
)

FAILED=0
for target in "${TARGETS[@]}"; do
  IFS='/' read -r os arch <<< "$target"
  echo "=== Type-checking for ${os}/${arch} ==="
  if ! CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go vet ./...; then
    echo "FAIL: ${os}/${arch}"
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo "Cross-compilation check failed for one or more targets"
  exit 1
fi
echo "Cross-compilation check passed for all targets"
