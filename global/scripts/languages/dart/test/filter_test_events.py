#!/usr/bin/env python3
"""Keep only the test events in a `dart test` / `flutter test` machine stream.

`dart test --reporter json` and `flutter test --machine` both write the
package:test JSON protocol to stdout, one object per line, and that stream is
what the GitHub `Test Results` check reads through `dorny/test-reporter`'s
`dart-json` parser -- which `JSON.parse`s EVERY non-empty line and fails the
whole report on the first one it cannot.

The stream is not clean.  `flutter test` shares its stdout with pub's own
progress when it resolves packages itself ("Resolving dependencies...", "Got
dependencies!", the outdated-package summary -- ten lines on one real run), and
flutter_tools emits its own machine events as JSON ARRAYS
(`[{"event":"test.startedProcess",...}]`), which are not test events at all.
`tojunit` tolerates both, so the JUnit report never showed the problem; the
check run would have failed on line 1.

This keeps exactly the lines that are JSON objects carrying a string `type`,
which is the whole protocol, writes them verbatim, and reports what it dropped
-- so a stream that turns out to be all noise is a warning in the log and no
output file, rather than an empty check.  A report, never a gate: whatever the
stream holds it exits 0, because the suite's own verdict was already recorded
by the runner; only a missing file or a bad invocation is an error, and
`run.sh` reports even that as a warning.
"""

from __future__ import annotations

import json
import os
import sys


def is_test_event(line: str) -> bool:
    try:
        event = json.loads(line)
    except ValueError:
        return False
    return isinstance(event, dict) and isinstance(event.get("type"), str)


def main() -> int:
    if len(sys.argv) < 3:
        print("Usage: filter_test_events.py <test-events.json> <test-results.json>", file=sys.stderr)
        return 2

    source, output = sys.argv[1], sys.argv[2]
    if not os.path.isfile(source):
        print("ERROR: no event stream at '{}'.".format(source), file=sys.stderr)
        return 1

    kept: list[str] = []
    dropped = 0
    with open(source, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            if is_test_event(line):
                kept.append(line)
            else:
                dropped += 1

    # A stale file from an earlier run must not be read as this run's suite.
    if os.path.isfile(output):
        os.remove(output)

    if not kept:
        print(
            "WARNING: '{}' carries no test event ({} non-event line(s)); writing no '{}'.".format(
                source, dropped, output
            ),
            file=sys.stderr,
        )
        return 0

    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    with open(output, "w", encoding="utf-8") as handle:
        handle.write("\n".join(kept) + "\n")
    print("TEST_EVENTS_KEPT={} (dropped {} non-event line(s))".format(len(kept), dropped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
