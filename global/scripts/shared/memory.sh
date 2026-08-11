#!/usr/bin/env sh

# Shared memory-ceiling detection for tools that have to be TOLD how much RAM
# they may use.
#
# A process inside a container sees the HOST's `/proc/meminfo`, not the limit
# its own cgroup imposes. Anything that sizes a heap from "total system memory"
# therefore either over-commits and gets OOM-killed by the kernel, or -- when a
# runtime applies its own conservative fraction to a number it never trusted in
# the first place -- under-commits badly. Read the cgroup limit first (v2, then
# v1) and fall back to `/proc/meminfo` only when the process is genuinely
# unconstrained.
#
# Usage:
#   . "$SCRIPTS_DIR/global/scripts/shared/memory.sh"
#   limit_mb="$(detect_memory_limit_mb)" || limit_mb=""
#
# Echoes the ceiling in MB and returns 0, or returns 1 having printed nothing
# when no ceiling can be established. The three source paths are overridable so
# the behaviour is testable against fixtures without a container.

: "${CGROUP_V2_MEMORY_MAX:=/sys/fs/cgroup/memory.max}"
: "${CGROUP_V1_MEMORY_LIMIT:=/sys/fs/cgroup/memory/memory.limit_in_bytes}"
: "${PROC_MEMINFO:=/proc/meminfo}"

# An unlimited cgroup v1 reports a sentinel near 2^63 rather than a real
# ceiling. Treat anything at or above ~8 EiB as "no limit set" -- no real
# machine has that much RAM, so there is no ambiguity.
MEMORY_UNLIMITED_THRESHOLD='9223372036854000000'

detect_memory_limit_mb() {
  _mem_bytes=''

  if [ -r "$CGROUP_V2_MEMORY_MAX" ]; then
    _mem_bytes="$(cat "$CGROUP_V2_MEMORY_MAX" 2> /dev/null)"
    # cgroup v2 spells "no limit" as the literal string `max`.
    if [ "$_mem_bytes" = 'max' ]; then
      _mem_bytes=''
    fi
  fi

  if [ -z "$_mem_bytes" ] && [ -r "$CGROUP_V1_MEMORY_LIMIT" ]; then
    _mem_bytes="$(cat "$CGROUP_V1_MEMORY_LIMIT" 2> /dev/null)"
  fi

  # Discard anything non-numeric (an empty read, a truncated file) and the
  # "unlimited" sentinel, so both fall through to the /proc/meminfo branch.
  case "$_mem_bytes" in
    '' | *[!0-9]*)
      _mem_bytes=''
      ;;
    *)
      if [ "$_mem_bytes" -ge "$MEMORY_UNLIMITED_THRESHOLD" ]; then
        _mem_bytes=''
      fi
      ;;
  esac

  if [ -n "$_mem_bytes" ]; then
    echo $((_mem_bytes / 1024 / 1024))
    return 0
  fi

  # Unconstrained, or the cgroup files are unreadable: the machine's own total
  # is the real ceiling.
  if [ -r "$PROC_MEMINFO" ]; then
    _mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' "$PROC_MEMINFO" 2> /dev/null)"
    case "$_mem_kb" in
      '' | *[!0-9]*) ;;
      *)
        echo $((_mem_kb / 1024))
        return 0
        ;;
    esac
  fi

  return 1
}
