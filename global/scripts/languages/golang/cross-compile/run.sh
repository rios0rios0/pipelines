#!/usr/bin/env bash
# Cross-compile check: validates the module for all target platforms to catch
# platform-specific type errors (e.g., syscall.Handle vs int on Windows).
# Uses "go vet" instead of "go build" — this performs full type-checking without
# linking (faster), and additionally runs vet diagnostics (printf, structtag, etc.)
# which may surface issues beyond pure compilation errors.
#
# All targets use CGO_ENABLED=0 (pure Go, no C toolchain needed).
#
# Usage:
#   Run all targets in parallel (local development):
#     ./run.sh
#   Run a single target (CI matrix mode):
#     CROSS_GOOS=linux CROSS_GOARCH=amd64 ./run.sh
set -euo pipefail

TARGETS=(
  "linux/amd64"
  "linux/arm64"
  "darwin/amd64"
  "darwin/arm64"
  "windows/amd64"
  "windows/arm64"
)

vet_target() {
  local os="$1" arch="$2"
  echo "=== Type-checking for ${os}/${arch} ==="

  CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go vet ./... 2>&1

  echo "PASS: ${os}/${arch}"
}

# Single-target mode: when CROSS_GOOS and CROSS_GOARCH are both set,
# check only that one target and exit. Used by CI matrix jobs.
if [ -n "${CROSS_GOOS:-}" ] && [ -n "${CROSS_GOARCH:-}" ]; then
  vet_target "$CROSS_GOOS" "$CROSS_GOARCH"
  exit $?
fi

# All-targets mode: run every target in parallel (for local development).
PIDS=()
TARGETS_MAP=()
for target in "${TARGETS[@]}"; do
  IFS='/' read -r os arch <<< "$target"
  vet_target "$os" "$arch" &
  PIDS+=($!)
  TARGETS_MAP+=("$target")
done

FAILED=0
for i in "${!PIDS[@]}"; do
  if ! wait "${PIDS[$i]}"; then
    echo "FAIL: ${TARGETS_MAP[$i]}"
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo "Cross-compilation check failed for one or more targets"
  exit 1
fi
echo "Cross-compilation check passed for all targets"
