#!/usr/bin/env python3
"""Render an LCOV tracefile as the Markdown coverage summary a pull request shows.

The JavaScript pipelines post a coverage table on every pull request through
`vitest-coverage-report-action`, which reads the Istanbul JSON that Jest and
Vitest emit.  Dart emits LCOV and nothing else, and no LCOV comment action fits
this library: the maintained ones shell out to an `lcov` binary a runner has to
`apt-get` (which a self-hosted runner without sudo cannot), or run as a Docker
container action (which a fleet without job-container support cannot start), and
every one of them reads the RAW tracefile -- so it would count the generated
sources `DART_COVERAGE_EXCLUDE` drops and paint a number the
`DART_COVERAGE_MINIMUM` gate never saw.  A comment that disagrees with the gate
beside it sends whoever reads it looking for the discrepancy.

So the runner renders the summary itself, from the same parse the Cobertura
converter uses (`lcov_to_cobertura.py`, imported below), against the same
exclusions and the same threshold.  Standard library only, for the same reason
that converter is: an offline `make test` can exercise it, and a Dart job needs
no Python toolchain beyond the `python3` it already requires.

The output has two parts:

  1. A totals table -- Lines always, Branches when the tracefile carries `BRDA`
     rows (`flutter test` and `dart test` only emit them with
     `--branch-coverage`).  The threshold marker and the status icon follow the
     LINE percentage, because that is the only figure the gate evaluates.

  2. A collapsed per-file table for the source files the change TOUCHES, which
     is what a reviewer wants to see on a pull request: the coverage of what is
     being merged, not of the whole tree.  `DART_COVERAGE_DIFF_BASE` names the
     commit to diff against (the pull request's base SHA on GitHub); empty
     omits the section, which is what a push build gets.

This is a REPORT, never a gate.  It exits 0 below the threshold -- the converter
already fails the job for that -- and it exits 0 when the changed files cannot
be listed, printing why instead of failing a green suite over a comment.
"""

from __future__ import annotations

import os
import subprocess
import sys

# The converter lives beside this file and owns the parse, the exclusion rules
# and the threshold spelling; importing it is what keeps the two reports from
# ever disagreeing about what was measured.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lcov_to_cobertura import FileCoverage, apply_exclusions, exclude_patterns, parse_lcov  # noqa: E402

# The same vocabulary `vitest-coverage-report-action` paints on the JavaScript
# pipelines' pull requests, so the two clients of one product read alike.
ICON_PASS = "\U0001F7E2"  # green circle: at or above the threshold
ICON_FAIL = "\U0001F534"  # red circle: below it
ICON_NONE = "\U0001F535"  # blue circle: no threshold to judge against
ICON_TARGET = "\U0001F3AF"  # the threshold marker

# A pull request touching more instrumented sources than this is summarised
# rather than listed: a GitHub comment is capped at 65,536 characters, and a
# table nobody scrolls to the end of is no better than a count.
FILE_ROWS_MAX = 100
# Ranges of uncovered lines shown per file before the rest is folded into a
# count. Enough to point at the gap; not enough to become the file.
UNCOVERED_RANGES_MAX = 12


def read_threshold() -> float | None:
    """`DART_COVERAGE_MINIMUM`, read exactly as the converter reads it."""
    raw = os.environ.get("DART_COVERAGE_MINIMUM", "").strip()
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        print(
            "WARNING: DART_COVERAGE_MINIMUM={!r} is not a number; ignoring.".format(raw),
            file=sys.stderr,
        )
        return None


def percent(covered: int, valid: int) -> float:
    return (covered / valid * 100.0) if valid else 0.0


def format_percent(value: float) -> str:
    # Two decimals, the spelling of the `COVERAGE_PERCENT=` line the GitLab
    # templates scrape, so the comment and the job log show one number.
    return "{:.2f}%".format(value)


def format_threshold(threshold: float) -> str:
    text = "{:.2f}".format(threshold).rstrip("0").rstrip(".")
    return "{}%".format(text)


def status_icon(value: float, threshold: float | None) -> str:
    if threshold is None:
        return ICON_NONE
    # The same tolerance the converter's gate applies, so the icon and the
    # exit code cannot disagree at the boundary.
    return ICON_PASS if value + 1e-9 >= threshold else ICON_FAIL


def line_ranges(numbers: list[int]) -> list[str]:
    """Fold sorted line numbers into `a-b` ranges: [4, 5, 6, 9] -> ['4-6', '9']."""
    ranges: list[str] = []
    start = previous = None
    for number in sorted(numbers):
        if start is None:
            start = previous = number
        elif number == previous + 1:
            previous = number
        else:
            ranges.append(str(start) if start == previous else "{}-{}".format(start, previous))
            start = previous = number
    if start is not None:
        ranges.append(str(start) if start == previous else "{}-{}".format(start, previous))
    return ranges


def format_uncovered(entry: FileCoverage) -> str:
    missed = [number for number, hits in entry.lines.items() if hits == 0]
    if not missed:
        return "none"
    ranges = line_ranges(missed)
    shown = ", ".join(ranges[:UNCOVERED_RANGES_MAX])
    if len(ranges) > UNCOVERED_RANGES_MAX:
        shown += ", ... and {} more".format(len(ranges) - UNCOVERED_RANGES_MAX)
    return shown


# A runner has no terminal, and a fetch that finds no credential must fail
# there and then rather than wait for a prompt nobody can answer: the deadline
# is the difference between a summary that says "unavailable" and a test job
# that hangs until its timeout kills it.
GIT_FETCH_TIMEOUT_SECONDS = 180
GIT_LOCAL_TIMEOUT_SECONDS = 60


def git(*args: str, timeout: int = GIT_LOCAL_TIMEOUT_SECONDS) -> subprocess.CompletedProcess:
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    try:
        return subprocess.run(
            ["git", *args], capture_output=True, text=True, check=False, env=env, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(
            ["git", *args], 124, "", "git {} timed out after {} s".format(args[0], timeout)
        )


def changed_files(base: str) -> tuple[list[str] | None, str]:
    """Source paths the change touches, relative to the package root.

    Compared as two TREES (`git diff <base> HEAD`), not as a history, because a
    CI checkout is shallow: on a GitHub pull request `HEAD` is the merge commit
    of the change onto its base, fetched at depth 1, so the base's own tree is
    the one object missing.  The single-commit fetch below supplies it; failing
    that (no remote, no network, a base already present) the diff is attempted
    regardless, and its own error is what gets reported.

    Diff paths are rooted at the REPOSITORY while the tracefile's are rooted at
    the package, and the two differ in a monorepo.  `git rev-parse --show-prefix`
    is the package's path inside the repository; it is stripped, and a file
    outside the package is dropped -- it is not in this tracefile either way.
    """
    prefix = git("rev-parse", "--show-prefix")
    if prefix.returncode != 0:
        return None, (prefix.stderr.strip().splitlines() or ["not a git repository"])[-1]
    package_prefix = prefix.stdout.strip()

    # Best effort by design: see the docstring. A fetch that fails is expected
    # (no remote, no network, a base already present) and the diff below reports
    # its own error; a fetch that RUNS OUT OF TIME is not, and is named as such.
    fetch = git(
        "fetch", "--quiet", "--depth=1", "--no-tags", "origin", base,
        timeout=GIT_FETCH_TIMEOUT_SECONDS,
    )
    if fetch.returncode == 124:
        return None, fetch.stderr

    diff = git("diff", "--name-only", "--diff-filter=ACMR", base, "HEAD")
    if diff.returncode != 0:
        reason = (diff.stderr.strip().splitlines() or ["git diff exited {}".format(diff.returncode)])[-1]
        return None, reason

    paths = []
    for path in diff.stdout.splitlines():
        path = path.strip()
        if not path or not path.startswith(package_prefix):
            continue
        paths.append(path[len(package_prefix):].replace("\\", "/"))
    return paths, ""


def render_totals(files: list[FileCoverage], threshold: float | None) -> list[str]:
    lines_valid = sum(f.lines_valid for f in files)
    lines_covered = sum(f.lines_covered for f in files)
    branches_valid = sum(f.branches_valid for f in files)
    branches_covered = sum(f.branches_covered for f in files)

    line_percent = percent(lines_covered, lines_valid)
    shown = format_percent(line_percent)
    if threshold is not None:
        shown += " ({} {})".format(ICON_TARGET, format_threshold(threshold))

    out = [
        "| Status | Category | Percentage | Covered / Total |",
        "| :---: | :--- | :--- | :--- |",
        "| {} | Lines | {} | {} / {} |".format(
            status_icon(line_percent, threshold), shown, lines_covered, lines_valid
        ),
    ]
    if branches_valid:
        # No threshold marker: the gate evaluates lines alone, and an icon that
        # judged branches against a line floor would claim a check nothing runs.
        out.append(
            "| {} | Branches | {} | {} / {} |".format(
                ICON_NONE,
                format_percent(percent(branches_covered, branches_valid)),
                branches_covered,
                branches_valid,
            )
        )
    return out


def render_files(
    files: list[FileCoverage],
    changed: list[str] | None,
    reason: str,
    base: str,
    threshold: float | None,
) -> list[str]:
    short_base = base[:7] if len(base) == 40 else base
    if changed is None:
        return [
            "",
            "File coverage for the files changed since `{}` is unavailable: {}.".format(
                short_base, reason
            ),
        ]

    by_path = {entry.path: entry for entry in files}
    total = len(set(changed))
    touched = sorted(path for path in set(changed) if path in by_path)
    unmeasured = total - len(touched)

    # The summary counts the instrumented files AGAINST all the changed ones, and
    # the explanation never says "more" over an empty table: a docs-only pull
    # request once read "0 changed file(s)" above "6 more changed file(s) are
    # not in the tracefile", as if six were listed.
    if not total:
        summary = "no file changed since <code>{}</code>".format(short_base)
    elif touched:
        summary = "{} of {} changed file(s) since <code>{}</code>".format(
            len(touched), total, short_base
        )
    else:
        summary = "none of the {} changed file(s) since <code>{}</code> is instrumented".format(
            total, short_base
        )
    not_measured = (
        "tests, assets, excluded generated sources and anything outside the "
        "instrumented directories are not measured"
    )

    out = ["", "<details>", "<summary>File coverage &mdash; {}</summary>".format(summary), ""]
    if touched and unmeasured:
        out += [
            "{} other changed file(s) are not in the tracefile: {}.".format(unmeasured, not_measured),
            "",
        ]
    if touched:
        out += [
            "| File | Status | Lines | Covered / Total | Uncovered lines |",
            "| :--- | :---: | ---: | ---: | :--- |",
        ]
        for path in touched[:FILE_ROWS_MAX]:
            entry = by_path[path]
            value = percent(entry.lines_covered, entry.lines_valid)
            out.append(
                "| `{}` | {} | {} | {} / {} | {} |".format(
                    path,
                    status_icon(value, threshold),
                    format_percent(value),
                    entry.lines_covered,
                    entry.lines_valid,
                    format_uncovered(entry),
                )
            )
        if len(touched) > FILE_ROWS_MAX:
            out.append(
                "| ... and {} more file(s) | | | | |".format(len(touched) - FILE_ROWS_MAX)
            )
    elif total:
        out.append(
            "Nothing to list: {}, and this change touches nothing else.".format(not_measured)
        )
    else:
        out.append("Nothing to list.")
    out += ["", "</details>"]
    return out


def render(
    files: list[FileCoverage],
    dropped: list[FileCoverage],
    patterns: list[str],
    threshold: float | None,
    base: str,
) -> str:
    out = ["## Coverage Report", ""]
    out += render_totals(files, threshold)

    notes = ["Measured over {} file(s).".format(len(files))]
    if patterns:
        notes.append(
            "{} file(s) excluded by `DART_COVERAGE_EXCLUDE` (`{}`).".format(
                len(dropped), " ".join(patterns)
            )
        )
    if not any(f.branches_valid for f in files):
        notes.append(
            "Branch coverage is not in the tracefile; `--branch-coverage` on the test "
            "command adds it."
        )
    out += ["", " ".join(notes)]

    if base:
        changed, reason = changed_files(base)
        if changed is None:
            print(
                "WARNING: could not list the files changed since {}: {}".format(base, reason),
                file=sys.stderr,
            )
        out += render_files(files, changed, reason, base, threshold)

    return "\n".join(out) + "\n"


def main() -> int:
    if len(sys.argv) < 3:
        print("Usage: lcov_to_markdown.py <lcov.info> <coverage.md>", file=sys.stderr)
        return 2

    lcov_path, output_path = sys.argv[1], sys.argv[2]
    if not os.path.isfile(lcov_path):
        print("ERROR: no LCOV tracefile at '{}'.".format(lcov_path), file=sys.stderr)
        return 1

    patterns = exclude_patterns()
    files, dropped = apply_exclusions(parse_lcov(lcov_path), patterns)
    base = os.environ.get("DART_COVERAGE_DIFF_BASE", "").strip()

    document = render(files, dropped, patterns, read_threshold(), base)

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write(document)
    print("Coverage summary written to '{}'.".format(output_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
