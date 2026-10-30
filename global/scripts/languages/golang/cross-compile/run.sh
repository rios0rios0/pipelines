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
#   Run every target, as many at once as the machine has CPUs (CI and local development):
#     ./run.sh
#   Cap how many run at once (each holds a type-checked copy of the module in memory):
#     CROSS_COMPILE_JOBS=2 ./run.sh
#   Run a single target:
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

# Single-target mode: when CROSS_GOOS and CROSS_GOARCH are both set, check only that one target
# and exit.
if [ -n "${CROSS_GOOS:-}" ] && [ -n "${CROSS_GOARCH:-}" ]; then
  vet_target "$CROSS_GOOS" "$CROSS_GOARCH"
  exit $?
fi

# All-targets mode, which is what CI runs: ONE job for the six targets rather than a runner per
# target, because each target is a `go vet` of the same module that takes seconds and a runner of
# its own spent more on checkout, Go and the module download than on the check.
#
# The targets run in batches of at most CROSS_COMPILE_JOBS (default: the CPUs the machine has),
# not all six at once, because every `go vet` holds a type-checked copy of the module in memory and
# a hosted runner for a private repository has two CPUs and 7 GB. Each target's output is held back
# and printed whole once it finishes, so a failure reads as one block instead of being interleaved
# with five others, and every failing target is named at the end.
LIMIT="${CROSS_COMPILE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
case "$LIMIT" in
  '' | *[!0-9]* | 0) LIMIT=1 ;;
esac

LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

FAILED_TARGETS=()
start=0
while [ "$start" -lt "${#TARGETS[@]}" ]; do
  PIDS=()
  BATCH=()
  for target in "${TARGETS[@]:$start:$LIMIT}"; do
    IFS='/' read -r os arch <<< "$target"
    vet_target "$os" "$arch" > "$LOG_DIR/${os}-${arch}.log" 2>&1 &
    PIDS+=($!)
    BATCH+=("$target")
  done
  for i in "${!PIDS[@]}"; do
    target="${BATCH[$i]}"
    status=0
    wait "${PIDS[$i]}" || status=$?
    cat "$LOG_DIR/${target%/*}-${target#*/}.log"
    if [ "$status" -ne 0 ]; then
      echo "FAIL: ${target}"
      FAILED_TARGETS+=("$target")
    fi
  done
  start=$((start + LIMIT))
done

if [ "${#FAILED_TARGETS[@]}" -ne 0 ]; then
  echo "Cross-compilation check failed for: ${FAILED_TARGETS[*]}"
  exit 1
fi
echo "Cross-compilation check passed for all targets"
