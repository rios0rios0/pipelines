#!/usr/bin/env sh

# Run the project's integration tests through its own `make test-integration`.
#
# Called by the opt-in `test:integration` step of the Azure DevOps PDM test
# stage, after the unit tests. What an integration test needs (a database in a
# container, a message broker, a fixture server) differs per project, so the
# pipeline does not try to know it: the project's Makefile does, and this script
# only decides whether that target exists.
#
# The target is looked up in make's printed database (`-p`) with question mode
# (`-q`) and an empty goal (`:`), which parses the Makefile and its includes
# without running a single recipe -- `make -n test-integration` would still run
# every line that calls `$(MAKE)`, which is exactly where a target that starts
# containers puts its work. A name make prints under `# Not a target:` is only a
# prerequisite of something else, never a rule of its own, and does not count.
#
# A missing Makefile or target is a warning, not a failure: the consumer opted
# in, so the log says why nothing ran, but a project that has no integration
# tests yet must not turn red for it.

TARGET="test-integration"

if make -pRrq : 2> /dev/null | awk -v target="$TARGET" '
  /^# Not a target/ { skip = 1; next }
  /^[^#[:space:]][^=]*:/ {
    name = $0
    sub(/:.*/, "", name)
    if (!skip && name == target) found = 1
    skip = 0
  }
  END { exit !found }
'; then
  echo "Running integration tests: make $TARGET"
  exec make "$TARGET"
fi

message="integration tests were enabled, but no Makefile here defines a '$TARGET' target; skipped"
if [ -n "$TF_BUILD" ]; then
  echo "##vso[task.logissue type=warning]$message"
else
  echo "WARNING: $message"
fi
