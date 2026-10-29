# Render the Markdown coverage summary a pull request shows. Run by
# `lcov-to-markdown.sh`, after `common.awk` and `lcov.awk`; see the script for
# the contract.
#
# Two phases, chosen by DART_MD_PHASE:
#
#   base    print DART_COVERAGE_DIFF_BASE stripped, and read nothing -- the
#           script needs it before it can list the changed files with git;
#   render  read the tracefile on stdin and write the summary to
#           DART_MD_OUTPUT, using the git results the script left in
#           DART_MD_WORK when DART_MD_BASE is set.

BEGIN {
    if (ENVIRON["DART_MD_PHASE"] == "base") {
        common_init()
        if (FAILED == "") printf "%s", py_strip(ENVIRON["DART_COVERAGE_DIFF_BASE"])
        BASE_PHASE = 1
        exit 0
    }
    lcov_init()
    OUT = ENVIRON["DART_MD_OUTPUT"]

    # The same vocabulary `vitest-coverage-report-action` paints on the
    # JavaScript pipelines' pull requests, so the two clients of one product
    # read alike.
    ICON_PASS = "🟢"     # U+1F7E2: at or above the threshold
    ICON_FAIL = "🔴"     # U+1F534: below it
    ICON_NONE = "🔵"     # U+1F535: no threshold to judge against
    ICON_TARGET = "🎯"   # U+1F3AF: the threshold marker

    # A pull request touching more instrumented sources than this is summarised
    # rather than listed: a GitHub comment is capped at 65,536 characters, and
    # a table nobody scrolls to the end of is no better than a count.
    FILE_ROWS_MAX = 100
    # Ranges of uncovered lines shown per file before the rest is folded into a
    # count. Enough to point at the gap; not enough to become the file.
    UNCOVERED_RANGES_MAX = 12
}

END {
    if (FAILED != "") exit FAILED
    if (BASE_PHASE) exit 0
    lcov_finish()
    lcov_threshold()

    # Rendered in memory first: the git results decide the last section, and
    # the document's directory is only created once there is a document.
    DOC_LINES = 0
    emit("## Coverage Report")
    emit("")
    render_totals()

    notes = "Measured over " fmt_int(LCOV_NKEPT) " file(s)."
    if (LCOV_PATTERNS) notes = notes " " fmt_int(LCOV_NDROPPED) " file(s) excluded by `DART_COVERAGE_EXCLUDE` (`" LCOV_PATTERN_TEXT "`)."
    if (!TOTAL_BV) notes = notes " Branch coverage is not in the tracefile; `--branch-coverage` on the test command adds it."
    emit("")
    emit(notes)

    BASE = ENVIRON["DART_MD_BASE"]
    if (BASE != "") {
        CHANGED_OK = changed_files()
        if (!CHANGED_OK) printf "WARNING: could not list the files changed since %s: %s\n", BASE, REASON > "/dev/stderr"
        render_files()
    }
    lcov_open_output(OUT)
    if (FAILED != "") exit FAILED
    for (i = 1; i <= DOC_LINES; i++) printf "%s\n", DOC[i] > OUT
    close(OUT)
    # Named as the caller gave it, not as the script may have spelled it for awk.
    printf "Coverage summary written to '%s'.\n", ENVIRON["DART_MD_OUTPUT_NAME"]
    exit 0
}

function emit(line) {
    DOC[++DOC_LINES] = line
}

# Two decimals, the spelling of the `COVERAGE_PERCENT=` line the GitLab
# templates scrape, so the comment and the job log show one number.
function format_percent(value) {
    return sprintf("%.2f%%", value)
}

function format_threshold(    text) {
    text = py_fixed(LCOV_THRESHOLD_KIND, LCOV_THRESHOLD, LCOV_THRESHOLD_NEGZERO, 2)
    sub(/0+$/, "", text)
    sub(/\.+$/, "", text)
    return text "%"
}

# The same tolerance the gate applies, so the icon and the exit code cannot
# disagree at the boundary.
function status_icon(value) {
    if (LCOV_THRESHOLD_KIND == "") return ICON_NONE
    if (LCOV_THRESHOLD_KIND == "-inf") return ICON_PASS
    if (LCOV_THRESHOLD_KIND != "num") return ICON_FAIL
    return (value + 1e-9 >= LCOV_THRESHOLD) ? ICON_PASS : ICON_FAIL
}

# A totals table: Lines always, Branches when the tracefile carries `BRDA` rows
# (`flutter test` and `dart test` only emit them with `--branch-coverage`). The
# threshold marker and the status icon follow the LINE percentage, because that
# is the only figure the gate evaluates.
function render_totals(    i, f, line_percent, shown) {
    TOTAL_LV = TOTAL_LC = TOTAL_BV = TOTAL_BC = 0
    for (i = 1; i <= LCOV_NKEPT; i++) {
        f = LCOV_KEPT[i]
        TOTAL_LV += LCOV_LV[f]
        TOTAL_LC += LCOV_LC[f]
        TOTAL_BV += LCOV_BV[f]
        TOTAL_BC += LCOV_BC[f]
        KEPT_PATH[LCOV_PATH[f]] = f
    }
    line_percent = lcov_percent(TOTAL_LC, TOTAL_LV)
    shown = format_percent(line_percent)
    if (LCOV_THRESHOLD_KIND != "") shown = shown " (" ICON_TARGET " " format_threshold() ")"

    emit("| Status | Category | Percentage | Covered / Total |")
    emit("| :---: | :--- | :--- | :--- |")
    emit("| " status_icon(line_percent) " | Lines | " shown " | " fmt_int(TOTAL_LC) " / " fmt_int(TOTAL_LV) " |")
    # No threshold marker: the gate evaluates lines alone, and an icon that
    # judged branches against a line floor would claim a check nothing runs.
    if (TOTAL_BV) emit("| " ICON_NONE " | Branches | " format_percent(lcov_percent(TOTAL_BC, TOTAL_BV)) " | " fmt_int(TOTAL_BC) " / " fmt_int(TOTAL_BV) " |")
}

# changed_files
#
# Read the results of the git commands `lcov-to-markdown.sh` ran, the way the
# Python renderer read its own: fills CHANGED[1..NCHANGED] with the paths the
# change touches, relative to the package root, or sets REASON and returns 0.
function changed_files(    work, status, prefix, lines, n, i, path) {
    work = ENVIRON["DART_MD_WORK"]
    status = ENVIRON["DART_MD_PREFIX_STATUS"] + 0
    if (status != 0) {
        REASON = last_line(read_file(work "/prefix.err"), "not a git repository")
        return 0
    }
    prefix = py_strip(read_file(work "/prefix.out"))

    # A fetch that fails is expected (no remote, no network, a base already
    # present) and the diff reports its own error; a fetch that RUNS OUT OF
    # TIME is not, and is named as such.
    if (ENVIRON["DART_MD_FETCH_STATUS"] + 0 == 124) {
        REASON = read_file(work "/fetch.err")
        return 0
    }

    status = ENVIRON["DART_MD_DIFF_STATUS"] + 0
    if (status != 0) {
        REASON = last_line(read_file(work "/diff.err"), "git diff exited " fmt_int(status > 128 ? 128 - status : status))
        return 0
    }

    NCHANGED = 0
    n = py_splitlines(read_file(work "/diff.out"), lines)
    for (i = 1; i <= n; i++) {
        path = py_strip(lines[i])
        if (path == "" || substr(path, 1, length(prefix)) != prefix) continue
        CHANGED[++NCHANGED] = replace_all(substr(path, length(prefix) + 1), "\\", "/")
    }
    return 1
}

function last_line(text, fallback,    lines, n) {
    n = py_splitlines(py_strip(text), lines)
    return n ? lines[n] : fallback
}

# A collapsed per-file table for the source files the change TOUCHES, which is
# what a reviewer wants to see on a pull request: the coverage of what is being
# merged, not of the whole tree.
function render_files(    short_base, total, seen, touched, ntouched, i, path, summary, not_measured, f) {
    short_base = (utf8_length(BASE) == 40) ? utf8_prefix(BASE, 7) : BASE
    if (!CHANGED_OK) {
        emit("")
        emit("File coverage for the files changed since `" short_base "` is unavailable: " REASON ".")
        return
    }

    total = 0
    ntouched = 0
    for (i = 1; i <= NCHANGED; i++) {
        path = CHANGED[i]
        if (path in seen) continue
        seen[path] = 1
        total++
        if (path in KEPT_PATH) touched[++ntouched] = path
    }
    sort_strings(touched, ntouched)

    # The summary counts the instrumented files AGAINST all the changed ones,
    # and the explanation never says "more" over an empty table: a docs-only
    # pull request once read "0 changed file(s)" above "6 more changed file(s)
    # are not in the tracefile", as if six were listed.
    if (!total) summary = "no file changed since <code>" short_base "</code>"
    else if (ntouched) summary = fmt_int(ntouched) " of " fmt_int(total) " changed file(s) since <code>" short_base "</code>"
    else summary = "none of the " fmt_int(total) " changed file(s) since <code>" short_base "</code> is instrumented"
    not_measured = "tests, assets, excluded generated sources and anything outside the instrumented directories are not measured"

    emit("")
    emit("<details>")
    emit("<summary>File coverage &mdash; " summary "</summary>")
    emit("")
    if (ntouched && total - ntouched) {
        emit(fmt_int(total - ntouched) " other changed file(s) are not in the tracefile: " not_measured ".")
        emit("")
    }
    if (ntouched) {
        emit("| File | Status | Lines | Covered / Total | Uncovered lines |")
        emit("| :--- | :---: | ---: | ---: | :--- |")
        for (i = 1; i <= ntouched && i <= FILE_ROWS_MAX; i++) {
            f = KEPT_PATH[touched[i]]
            emit("| `" touched[i] "` | " status_icon(lcov_percent(LCOV_LC[f], LCOV_LV[f])) " | " format_percent(lcov_percent(LCOV_LC[f], LCOV_LV[f])) " | " fmt_int(LCOV_LC[f]) " / " fmt_int(LCOV_LV[f]) " | " format_uncovered(f) " |")
        }
        if (ntouched > FILE_ROWS_MAX) emit("| ... and " fmt_int(ntouched - FILE_ROWS_MAX) " more file(s) | | | | |")
    } else if (total) {
        emit("Nothing to list: " not_measured ", and this change touches nothing else.")
    } else {
        emit("Nothing to list.")
    }
    emit("")
    emit("</details>")
}

# Fold the lines that were never hit into `a-b` ranges: 4, 5, 6, 9 -> `4-6, 9`.
function format_uncovered(f,    missed, n, k, ranges, nr, start, previous, shown) {
    n = 0
    for (k = 1; k <= LCOV_NLINES[f]; k++)
        if (LCOV_HITS[f, LCOV_LINE[f, k]] == 0) missed[++n] = LCOV_LINE[f, k]
    if (!n) return "none"
    if (LCOV_UNSORTED[f]) sort_numbers(missed, n)
    nr = 0
    start = previous = missed[1]
    for (k = 2; k <= n; k++) {
        if (missed[k] + 0 == previous + 1) {
            previous = missed[k]
            continue
        }
        ranges[++nr] = (start == previous) ? start : start "-" previous
        start = previous = missed[k]
    }
    ranges[++nr] = (start == previous) ? start : start "-" previous
    shown = ranges[1]
    for (k = 2; k <= nr && k <= UNCOVERED_RANGES_MAX; k++) shown = shown ", " ranges[k]
    if (nr > UNCOVERED_RANGES_MAX) shown = shown ", ... and " fmt_int(nr - UNCOVERED_RANGES_MAX) " more"
    return shown
}
