#!/usr/bin/env python3
"""Turn `dart analyze --format=machine` output into CI-consumable reports.

Reads the machine format on stdin and writes a JSON report and a JUnit XML
report, then prints a grouped human summary and exits with the gate's verdict.

Why the machine format and not the default one
----------------------------------------------
`dart analyze` has three output formats (`default`, `json`, `machine`).  The
default one is explicitly documented as unstable ("the format is not specified
and can change"), so parsing it would be building on sand.  `machine` is the
stable line-oriented contract:

    SEVERITY|TYPE|ERROR_CODE|FILE_PATH|LINE|COLUMN|LENGTH|ERROR_MESSAGE

with `|` and `\\` backslash-escaped inside the path and message fields.  The
unescaping below is the whole reason this is a parser rather than an `awk`
one-liner: a lint message containing a pipe (they do -- anything quoting an
operator or a shell snippet) splits into the wrong number of fields otherwise,
and the row silently lands in the report attributed to the wrong file.

`flutter analyze` is deliberately not used even for Flutter projects: it has no
`--format` option at all (flutter/flutter#95090), so it can only be scraped.
The Flutter SDK's bundled `dart` runs the same analyzer over the same
`analysis_options.yaml`, which is why `common.sh` symlinks it.

Gating
------
Errors always fail.  Warnings fail unless `DART_FATAL_WARNINGS=false`.  Infos
(which is where every lint from `package:lints` / `package:flutter_lints`
lands) fail only when `DART_FATAL_INFOS=true`, because a repository adopting a
stricter lint set should be able to see the findings before it has to fix all
of them.
"""

from __future__ import annotations

import json
import os
import sys
from xml.sax.saxutils import escape, quoteattr

SEVERITY_ORDER = ("ERROR", "WARNING", "INFO")


def _truthy(value: str | None, default: bool = False) -> bool:
    if value is None or value == "":
        return default
    return value.strip().lower() in ("true", "1", "yes")


def _split_machine_line(line: str) -> list[str] | None:
    """Split one machine-format row on unescaped pipes.

    Returns None for anything that is not a diagnostic row, which covers the
    progress and summary lines `dart analyze` still prints on stderr/stdout in
    some SDK versions.
    """
    fields: list[str] = []
    current: list[str] = []
    escaped = False
    for char in line:
        if escaped:
            current.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == "|":
            fields.append("".join(current))
            current = []
        else:
            current.append(char)
    fields.append("".join(current))

    if len(fields) < 8:
        return None
    if fields[0] not in SEVERITY_ORDER:
        return None
    # The trailing message may itself contain pipes that were NOT escaped by
    # older SDKs; rejoin any surplus fields back into it rather than dropping
    # them.
    if len(fields) > 8:
        fields = fields[:7] + ["|".join(fields[7:])]
    return fields


def parse(stream) -> list[dict]:
    diagnostics = []
    for raw in stream:
        line = raw.rstrip("\n").rstrip("\r")
        if not line.strip():
            continue
        fields = _split_machine_line(line)
        if fields is None:
            continue
        severity, kind, code, path, line_no, column, length, message = fields
        diagnostics.append(
            {
                "severity": severity,
                "type": kind,
                "code": code,
                "file": path,
                "line": int(line_no) if line_no.isdigit() else 0,
                "column": int(column) if column.isdigit() else 0,
                "length": int(length) if length.isdigit() else 0,
                "message": message,
            }
        )
    return diagnostics


def report_path(report_dir: str, filename: str) -> str:
    """Join a report file name onto the report directory, refusing to escape it.

    The directory itself is the CALLER's choice and may legitimately be absolute
    -- `run.sh` passes `$DART_TOOL_REPORT_PATH`, and the validation suite passes
    a temporary directory -- so this deliberately does not confine it to the
    working tree. What it does confine is the part this script constructs: the
    resolved file must still sit inside the directory it was given, so a name
    carrying `..` cannot write somewhere the caller never named.
    """
    base = os.path.realpath(report_dir)
    resolved = os.path.realpath(os.path.join(base, filename))
    if resolved != base and not resolved.startswith(base + os.sep):
        raise SystemExit(
            "refusing to write '{name}' outside the report directory '{dir}'".format(
                name=filename, dir=report_dir
            )
        )
    return resolved


def write_json(diagnostics: list[dict], path: str, counts: dict) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(
            {"tool": "dart analyze", "summary": counts, "diagnostics": diagnostics},
            handle,
            indent=2,
        )
        handle.write("\n")


def write_junit(diagnostics: list[dict], path: str, fatal: set[str]) -> None:
    failures = [d for d in diagnostics if d["severity"] in fatal]
    total = len(diagnostics) or 1

    rows = []
    for diagnostic in diagnostics:
        name = "{code} {file}:{line}:{column}".format(**diagnostic)
        classname = diagnostic["file"].replace("/", ".").removesuffix(".dart")
        body = "{severity} {type} {code}: {message}".format(**diagnostic)
        if diagnostic["severity"] in fatal:
            inner = "      <failure message={message} type={kind}>{body}</failure>\n".format(
                message=quoteattr(diagnostic["message"]),
                kind=quoteattr(diagnostic["severity"]),
                body=escape(body),
            )
        else:
            # Non-fatal findings are recorded as skipped rather than omitted:
            # they stay visible in every platform's Tests tab (which is the
            # point of publishing this at all) without turning the job red.
            inner = "      <skipped message={message}/>\n".format(
                message=quoteattr(body)
            )
        rows.append(
            "    <testcase name={name} classname={classname}>\n{inner}    </testcase>\n".format(
                name=quoteattr(name), classname=quoteattr(classname or "dart"), inner=inner
            )
        )

    if not diagnostics:
        rows.append(
            '    <testcase name="dart analyze" classname="dart"/>\n'
        )

    with open(path, "w", encoding="utf-8") as handle:
        handle.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        handle.write(
            '<testsuites name="dart-analyze" tests="{tests}" failures="{failures}">\n'.format(
                tests=total, failures=len(failures)
            )
        )
        handle.write(
            '  <testsuite name="dart-analyze" tests="{tests}" failures="{failures}">\n'.format(
                tests=total, failures=len(failures)
            )
        )
        handle.writelines(rows)
        handle.write("  </testsuite>\n</testsuites>\n")


def main() -> int:
    report_dir = sys.argv[1] if len(sys.argv) > 1 else "build/reports/dart-analyze"
    os.makedirs(report_dir, exist_ok=True)

    diagnostics = parse(sys.stdin)

    fatal = {"ERROR"}
    if _truthy(os.environ.get("DART_FATAL_WARNINGS"), default=True):
        fatal.add("WARNING")
    if _truthy(os.environ.get("DART_FATAL_INFOS"), default=False):
        fatal.add("INFO")

    counts = {level: sum(1 for d in diagnostics if d["severity"] == level) for level in SEVERITY_ORDER}
    counts["total"] = len(diagnostics)

    write_json(diagnostics, report_path(report_dir, "analyze.json"), counts)
    write_junit(diagnostics, report_path(report_dir, "junit-analyze.xml"), fatal)

    print(
        "dart analyze found {total} issue(s): {ERROR} error(s), {WARNING} warning(s), "
        "{INFO} info(s).".format(**counts)
    )

    for level in SEVERITY_ORDER:
        rows = [d for d in diagnostics if d["severity"] == level]
        if not rows:
            continue
        marker = "FATAL" if level in fatal else "non-fatal"
        print("\n{level} ({count}, {marker}):".format(level=level, count=len(rows), marker=marker))
        for diagnostic in rows:
            print(
                "  - {file}:{line}:{column} [{code}] {message}".format(**diagnostic)
            )

    blocking = sum(counts[level] for level in fatal)
    if blocking:
        print(
            "\n{count} finding(s) at or above the configured severity gate; failing.".format(
                count=blocking
            ),
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
