#!/usr/bin/env python3
"""Convert an LCOV tracefile into a Cobertura XML report.

Dart and Flutter emit coverage as LCOV and nothing else: `flutter test
--coverage` writes `coverage/lcov.info`, and `package:coverage`'s
`format_coverage --lcov` produces the same shape for pure Dart packages.  Two of
the three platforms this repository targets cannot read that format --
Azure DevOps' `PublishCodeCoverageResults@2` takes Cobertura or JaCoCo, and
GitLab CI's coverage visualisation takes Cobertura -- so something has to
convert it.

This is that converter, written against the standard library only, for the same
reason `check_order.py` and `gen_smoke_tests.py` are: the alternative is a pip
install (`lcov_cobertura`) inside a Dart job, which means a Python toolchain, a
virtualenv and a network round-trip on a runner that otherwise needs none of
them -- and an offline `make test` could not exercise it.

LCOV is a line-oriented format; only the records that carry information
Cobertura can represent are read:

    SF:<path>                       start of a file record
    DA:<line>,<hits>[,<checksum>]   per-line execution count
    BRDA:<line>,<block>,<branch>,<taken|->
    end_of_record

`LF`/`LH`/`BRF`/`BRH` totals are deliberately ignored and recomputed from the
`DA`/`BRDA` rows instead.  They are summaries the producer is free to get wrong
(and merged tracefiles routinely do), whereas the per-line rows are the data
every consumer actually renders.

`DART_COVERAGE_EXCLUDE` drops whole source files from BOTH the document and the
`DART_COVERAGE_MINIMUM` gate, so the report and the gate never disagree about
what was measured.  It exists because generated Dart is near-universal --
`build_runner`, `freezed` and `json_serializable` all emit `*.g.dart` /
`*.freezed.dart` beside their sources -- and a generator's output moves the total
without saying anything about whether the project is tested: one real catalogue
generator emitting a string literal per line took a project from 82.8% to 38.2%.
A floor a code generator can move is not measuring what it was put there to
protect.
"""

from __future__ import annotations

import fnmatch
import os
import sys
import time
from xml.sax.saxutils import quoteattr

# How many excluded paths to name before summarising the rest. The count above
# them is the signal that matters; naming a few makes a wrong pattern obvious
# without turning an over-broad one into a thousand lines of log.
EXCLUDED_PREVIEW = 10


class FileCoverage:
    __slots__ = ("path", "lines", "branches")

    def __init__(self, path: str) -> None:
        self.path = path
        # line number -> hits
        self.lines: dict[int, int] = {}
        # (line, block, branch) -> taken count
        self.branches: dict[tuple[int, str, str], int] = {}

    @property
    def lines_valid(self) -> int:
        return len(self.lines)

    @property
    def lines_covered(self) -> int:
        return sum(1 for hits in self.lines.values() if hits > 0)

    @property
    def branches_valid(self) -> int:
        return len(self.branches)

    @property
    def branches_covered(self) -> int:
        return sum(1 for taken in self.branches.values() if taken > 0)

    @property
    def line_rate(self) -> float:
        return (self.lines_covered / self.lines_valid) if self.lines_valid else 0.0

    @property
    def branch_rate(self) -> float:
        return (self.branches_covered / self.branches_valid) if self.branches_valid else 0.0


def parse_lcov(path: str) -> list[FileCoverage]:
    """Parse a tracefile into per-source-file coverage.

    Records for the same source file are MERGED rather than replaced.  A Dart
    project that runs more than one test entry point produces several `SF:`
    records for the same library, and taking the last one would silently discard
    every hit the other suites contributed -- reporting a real 90% as whatever
    the final suite happened to touch.
    """
    files: dict[str, FileCoverage] = {}
    current: FileCoverage | None = None

    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue

            if line.startswith("SF:"):
                source = line[3:].strip()
                # LCOV paths may be absolute (format_coverage emits them that
                # way for some inputs). Cobertura consumers match findings
                # against the repository tree, so make them relative to the
                # working directory when we can.
                if os.path.isabs(source):
                    try:
                        source = os.path.relpath(source, os.getcwd())
                    except ValueError:
                        pass
                source = source.replace("\\", "/")
                current = files.setdefault(source, FileCoverage(source))
            elif line == "end_of_record":
                current = None
            elif current is None:
                continue
            elif line.startswith("DA:"):
                parts = line[3:].split(",")
                if len(parts) < 2 or not parts[0].strip().isdigit():
                    continue
                number = int(parts[0])
                try:
                    hits = int(parts[1])
                except ValueError:
                    hits = 0
                current.lines[number] = current.lines.get(number, 0) + hits
            elif line.startswith("BRDA:"):
                parts = line[5:].split(",")
                if len(parts) < 4 or not parts[0].strip().isdigit():
                    continue
                key = (int(parts[0]), parts[1], parts[2])
                taken = 0 if parts[3] == "-" else int(parts[3] or 0)
                current.branches[key] = current.branches.get(key, 0) + taken

    return [files[key] for key in sorted(files)]


def exclude_patterns() -> list[str]:
    """Read `DART_COVERAGE_EXCLUDE` into a list of glob patterns.

    Accepts either separator, because the three platforms spell lists
    differently: a GitHub Actions input and an Azure DevOps variable are single
    strings a caller naturally comma-separates, while a GitLab `variables:` entry
    is as naturally written space-separated.  Taking both removes a class of
    silent misconfiguration where the whole value is read as one pattern that
    matches nothing.
    """
    raw = os.environ.get("DART_COVERAGE_EXCLUDE", "")
    return [pattern for pattern in raw.replace(",", " ").split() if pattern]


def apply_exclusions(
    files: list[FileCoverage], patterns: list[str]
) -> tuple[list[FileCoverage], list[FileCoverage]]:
    """Split parsed records into kept and excluded.

    Matching is `fnmatch` against the whole relative path, whose `*` crosses `/`
    -- unlike a shell glob.  That is what makes the useful pattern short:
    `*.g.dart` matches `lib/presentation/i18n/catalog.g.dart` at any depth, with
    no `**/` prefix and no per-directory pattern.  It is also why an over-broad
    pattern is easy to write by accident, which is what the count printed below
    is for.
    """
    if not patterns:
        return files, []

    kept: list[FileCoverage] = []
    dropped: list[FileCoverage] = []
    for entry in files:
        target = dropped if any(fnmatch.fnmatch(entry.path, p) for p in patterns) else kept
        target.append(entry)
    return kept, dropped


def package_name(source: str) -> str:
    """Cobertura's `package` is a grouping label; use the source directory."""
    directory = os.path.dirname(source)
    return directory.replace("/", ".") if directory else "."


def write_cobertura(files: list[FileCoverage], output: str, sources_root: str) -> tuple[int, int]:
    lines_valid = sum(f.lines_valid for f in files)
    lines_covered = sum(f.lines_covered for f in files)
    branches_valid = sum(f.branches_valid for f in files)
    branches_covered = sum(f.branches_covered for f in files)
    line_rate = (lines_covered / lines_valid) if lines_valid else 0.0
    branch_rate = (branches_covered / branches_valid) if branches_valid else 0.0

    grouped: dict[str, list[FileCoverage]] = {}
    for entry in files:
        grouped.setdefault(package_name(entry.path), []).append(entry)

    out = [
        '<?xml version="1.0" ?>\n',
        "<!DOCTYPE coverage SYSTEM "
        "'http://cobertura.sourceforge.net/xml/coverage-04.dtd'>\n",
        '<coverage line-rate="{lr:.4f}" branch-rate="{br:.4f}" '
        'lines-covered="{lc}" lines-valid="{lv}" '
        'branches-covered="{bc}" branches-valid="{bv}" '
        'complexity="0" version="2.0.3" timestamp="{ts}">\n'.format(
            lr=line_rate,
            br=branch_rate,
            lc=lines_covered,
            lv=lines_valid,
            bc=branches_covered,
            bv=branches_valid,
            ts=int(time.time()),
        ),
        "  <sources>\n    <source>{}</source>\n  </sources>\n".format(sources_root),
        "  <packages>\n",
    ]

    for name in sorted(grouped):
        members = grouped[name]
        pkg_valid = sum(f.lines_valid for f in members)
        pkg_covered = sum(f.lines_covered for f in members)
        pkg_rate = (pkg_covered / pkg_valid) if pkg_valid else 0.0
        # Aggregated from the members' BRDA rows, not hard-coded. A fixed `0.0`
        # here would disagree with the branch rates on the `<class>` elements
        # inside this very package and with the document-level totals, so any
        # consumer that aggregates per package (rather than per file) would read
        # fully branch-covered code as having none.
        pkg_branches_valid = sum(f.branches_valid for f in members)
        pkg_branches_covered = sum(f.branches_covered for f in members)
        pkg_branch_rate = (
            (pkg_branches_covered / pkg_branches_valid) if pkg_branches_valid else 0.0
        )
        out.append(
            '    <package name={name} line-rate="{lr:.4f}" branch-rate="{br:.4f}" '
            'complexity="0">\n      <classes>\n'.format(
                name=quoteattr(name), lr=pkg_rate, br=pkg_branch_rate
            )
        )
        for entry in members:
            class_name = os.path.basename(entry.path)
            out.append(
                '        <class name={cn} filename={fn} line-rate="{lr:.4f}" '
                'branch-rate="{br:.4f}" complexity="0">\n'
                "          <methods/>\n          <lines>\n".format(
                    cn=quoteattr(class_name),
                    fn=quoteattr(entry.path),
                    lr=entry.line_rate,
                    br=entry.branch_rate,
                )
            )
            for number in sorted(entry.lines):
                out.append(
                    '            <line number="{n}" hits="{h}"/>\n'.format(
                        n=number, h=entry.lines[number]
                    )
                )
            out.append("          </lines>\n        </class>\n")
        out.append("      </classes>\n    </package>\n")

    out.append("  </packages>\n</coverage>\n")

    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    with open(output, "w", encoding="utf-8") as handle:
        handle.writelines(out)

    return lines_covered, lines_valid


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "Usage: lcov_to_cobertura.py <lcov.info> <cobertura.xml> [sources-root]",
            file=sys.stderr,
        )
        return 2

    lcov_path, output_path = sys.argv[1], sys.argv[2]
    sources_root = sys.argv[3] if len(sys.argv) > 3 else "."

    if not os.path.isfile(lcov_path):
        print("ERROR: no LCOV tracefile at '{}'.".format(lcov_path), file=sys.stderr)
        return 1

    files = parse_lcov(lcov_path)

    # Excluded BEFORE the document is written, not only before the gate is
    # evaluated: a report that still lists a file the percentage no longer counts
    # sends whoever opens it looking for the discrepancy.
    patterns = exclude_patterns()
    total = len(files)
    files, dropped = apply_exclusions(files, patterns)
    if patterns:
        # Printed unconditionally when the variable is set -- including as `0 of
        # N`, which is how a typo'd pattern announces itself -- and always ahead
        # of the COVERAGE_PERCENT line, so a consumer scraping the last match
        # still lands on the percentage.
        print(
            "COVERAGE_EXCLUDED={dropped} of {total} file(s) dropped by "
            "DART_COVERAGE_EXCLUDE ({patterns})".format(
                dropped=len(dropped), total=total, patterns=" ".join(patterns)
            )
        )
        for entry in dropped[:EXCLUDED_PREVIEW]:
            print("  excluded: {}".format(entry.path))
        if len(dropped) > EXCLUDED_PREVIEW:
            print("  excluded: ... and {} more".format(len(dropped) - EXCLUDED_PREVIEW))

    covered, valid = write_cobertura(files, output_path, sources_root)

    percent = (covered / valid * 100.0) if valid else 0.0
    # The exact spelling matters: the GitLab templates scrape this line with a
    # `coverage:` regex, so changing it silently drops coverage reporting on
    # that platform while every job stays green.
    print(
        "COVERAGE_PERCENT={percent:.2f}% ({covered}/{valid} lines across {files} file(s))".format(
            percent=percent, covered=covered, valid=valid, files=len(files)
        )
    )

    minimum = os.environ.get("DART_COVERAGE_MINIMUM", "").strip()
    if minimum:
        try:
            threshold = float(minimum)
        except ValueError:
            print(
                "WARNING: DART_COVERAGE_MINIMUM={!r} is not a number; ignoring.".format(minimum),
                file=sys.stderr,
            )
            return 0
        if percent + 1e-9 < threshold:
            print(
                "ERROR: coverage {:.2f}% is below the required {:.2f}%.".format(percent, threshold),
                file=sys.stderr,
            )
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
