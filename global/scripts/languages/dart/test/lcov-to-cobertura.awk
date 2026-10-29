# Write the Cobertura XML report for an LCOV tracefile, and evaluate the
# `DART_COVERAGE_MINIMUM` gate. Run by `lcov-to-cobertura.sh`, after
# `common.awk` and `lcov.awk`; see the script for the contract.
#
# Reads from the environment: DART_COBERTURA_OUTPUT (the file to write),
# DART_COBERTURA_SOURCES (the `<source>` root), DART_COBERTURA_TIMESTAMP, and
# the variables `lcov.awk` reads.

BEGIN {
    lcov_init()
    OUT = ENVIRON["DART_COBERTURA_OUTPUT"]
}

END {
    if (FAILED != "") exit FAILED
    lcov_finish()

    # Reported BEFORE the document is written, and the excluded files are kept
    # out of the document too: a report that still lists a file the percentage
    # no longer counts sends whoever opens it looking for the discrepancy.
    if (LCOV_PATTERNS) {
        # Printed unconditionally when the variable is set -- including as `0
        # of N`, which is how a typo'd pattern announces itself -- and always
        # ahead of the COVERAGE_PERCENT line, so a consumer scraping the last
        # match still lands on the percentage.
        printf "COVERAGE_EXCLUDED=%s of %s file(s) dropped by DART_COVERAGE_EXCLUDE (%s)\n", fmt_int(LCOV_NDROPPED), fmt_int(LCOV_FILES), LCOV_PATTERN_TEXT
        # How many excluded paths to name before summarising the rest. The
        # count above them is the signal that matters; naming a few makes a
        # wrong pattern obvious without turning an over-broad one into a
        # thousand lines of log.
        for (i = 1; i <= LCOV_NDROPPED && i <= 10; i++) printf "  excluded: %s\n", LCOV_PATH[LCOV_DROPPED[i]]
        if (LCOV_NDROPPED > 10) printf "  excluded: ... and %s more\n", fmt_int(LCOV_NDROPPED - 10)
    }

    lcov_open_output(OUT)
    if (FAILED != "") exit FAILED
    write_cobertura()

    percent = lcov_percent(TOTAL_LC, TOTAL_LV)
    # The exact spelling matters: the GitLab templates scrape this line with a
    # `coverage:` regex, so changing it silently drops coverage reporting on
    # that platform while every job stays green.
    printf "COVERAGE_PERCENT=%.2f%% (%s/%s lines across %s file(s))\n", percent, fmt_int(TOTAL_LC), fmt_int(TOTAL_LV), fmt_int(LCOV_NKEPT)

    if (!lcov_threshold()) exit 0
    if (LCOV_THRESHOLD_KIND != "" && lcov_below_threshold(percent)) {
        printf "ERROR: coverage %.2f%% is below the required %s%%.\n", percent, py_fixed(LCOV_THRESHOLD_KIND, LCOV_THRESHOLD, LCOV_THRESHOLD_NEGZERO, 2) > "/dev/stderr"
        exit 1
    }
    exit 0
}

function rate(covered, valid) {
    return sprintf("%.4f", valid ? covered / valid : 0.0)
}

function write_cobertura(    i, f, k, pkg, npkg, names, j, m, lc, lv, bc, bv) {
    TOTAL_LV = TOTAL_LC = TOTAL_BV = TOTAL_BC = 0
    npkg = 0
    for (i = 1; i <= LCOV_NKEPT; i++) {
        f = LCOV_KEPT[i]
        TOTAL_LV += LCOV_LV[f]
        TOTAL_LC += LCOV_LC[f]
        TOTAL_BV += LCOV_BV[f]
        TOTAL_BC += LCOV_BC[f]
        pkg = lcov_package(LCOV_PATH[f])
        if (!(pkg in PKG_SIZE)) {
            names[++npkg] = pkg
            PKG_SIZE[pkg] = 0
        }
        PKG_MEMBER[pkg, ++PKG_SIZE[pkg]] = f
    }
    sort_strings(names, npkg)

    printf "%s\n", "<?xml version=\"1.0\" ?>" > OUT
    # See the note in terraform/terra-test/run.sh: the DTD is a dead identifier
    # under either scheme and is never dereferenced.
    printf "%s\n", "<!DOCTYPE coverage SYSTEM 'https://cobertura.sourceforge.net/xml/coverage-04.dtd'>" > OUT
    printf "<coverage line-rate=\"%s\" branch-rate=\"%s\" lines-covered=\"%s\" lines-valid=\"%s\" branches-covered=\"%s\" branches-valid=\"%s\" complexity=\"0\" version=\"2.0.3\" timestamp=\"%s\">\n", rate(TOTAL_LC, TOTAL_LV), rate(TOTAL_BC, TOTAL_BV), fmt_int(TOTAL_LC), fmt_int(TOTAL_LV), fmt_int(TOTAL_BC), fmt_int(TOTAL_BV), ENVIRON["DART_COBERTURA_TIMESTAMP"] > OUT
    printf "  <sources>\n    <source>%s</source>\n  </sources>\n", ENVIRON["DART_COBERTURA_SOURCES"] > OUT
    printf "  <packages>\n" > OUT

    for (j = 1; j <= npkg; j++) {
        pkg = names[j]
        lv = lc = bv = bc = 0
        for (m = 1; m <= PKG_SIZE[pkg]; m++) {
            f = PKG_MEMBER[pkg, m]
            lv += LCOV_LV[f]
            lc += LCOV_LC[f]
            bv += LCOV_BV[f]
            bc += LCOV_BC[f]
        }
        # The package's branch rate is aggregated from its members' BRDA rows,
        # not hard-coded. A fixed `0.0` here would disagree with the branch
        # rates on the `<class>` elements inside this very package and with the
        # document-level totals, so any consumer that aggregates per package
        # (rather than per file) would read fully branch-covered code as having
        # none.
        printf "    <package name=%s line-rate=\"%s\" branch-rate=\"%s\" complexity=\"0\">\n      <classes>\n", xml_quoteattr(pkg), rate(lc, lv), rate(bc, bv) > OUT
        for (m = 1; m <= PKG_SIZE[pkg]; m++) write_class(PKG_MEMBER[pkg, m])
        printf "      </classes>\n    </package>\n" > OUT
    }

    printf "  </packages>\n</coverage>\n" > OUT
    close(OUT)
}

function write_class(f,    numbers, n, k) {
    printf "        <class name=%s filename=%s line-rate=\"%s\" branch-rate=\"%s\" complexity=\"0\">\n          <methods/>\n          <lines>\n", xml_quoteattr(py_basename(LCOV_PATH[f])), xml_quoteattr(LCOV_PATH[f]), rate(LCOV_LC[f], LCOV_LV[f]), rate(LCOV_BC[f], LCOV_BV[f]) > OUT
    n = LCOV_NLINES[f]
    for (k = 1; k <= n; k++) numbers[k] = LCOV_LINE[f, k]
    if (LCOV_UNSORTED[f]) sort_numbers(numbers, n)
    # `%.0f` as `fmt_int` would, without its call: a hit count is a sum that
    # starts at +0, so it is never the -0 that `fmt_int` guards against.
    for (k = 1; k <= n; k++) printf "            <line number=\"%s\" hits=\"%.0f\"/>\n", numbers[k], LCOV_HITS[f, numbers[k]] > OUT
    printf "          </lines>\n        </class>\n" > OUT
}
