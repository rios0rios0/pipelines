# The LCOV parse both coverage converters share, loaded after `common.awk`:
#
#   LC_ALL=C awk -f ../common.awk -f lcov.awk -f lcov-to-<format>.awk < lcov.info
#
# One parse, one set of exclusions and one threshold reading for the Cobertura
# report, the Markdown summary and the `DART_COVERAGE_MINIMUM` gate, which is
# what keeps the three from ever disagreeing about what was measured.
#
# LCOV is a line-oriented format; only the records that carry information the
# reports can represent are read:
#
#     SF:<path>                       start of a file record
#     DA:<line>,<hits>[,<checksum>]   per-line execution count
#     BRDA:<line>,<block>,<branch>,<taken|->
#     end_of_record
#
# `LF`/`LH`/`BRF`/`BRH` totals are deliberately ignored and recomputed from the
# `DA`/`BRDA` rows instead. They are summaries the producer is free to get wrong
# (and merged tracefiles routinely do), whereas the per-line rows are the data
# every consumer actually renders.
#
# Records for the same source file are MERGED rather than replaced. A Dart
# project that runs more than one test entry point produces several `SF:`
# records for the same library, and taking the last one would silently discard
# every hit the other suites contributed -- reporting a real 90% as whatever the
# final suite happened to touch.
#
# `DART_COVERAGE_EXCLUDE` drops whole source files from the reports AND the
# gate. It exists because generated Dart is near-universal -- `build_runner`,
# `freezed` and `json_serializable` all emit `*.g.dart` / `*.freezed.dart`
# beside their sources -- and a generator's output moves the total without
# saying anything about whether the project is tested: one real catalogue
# generator emitting a string literal per line took a project from 82.8% to
# 38.2%. A floor a code generator can move is not measuring what it was put
# there to protect.
#
# Reads from the environment: DART_LCOV_CWD (the physical working directory,
# `pwd -P`) and DART_COVERAGE_EXCLUDE.

function lcov_init(    i) {
    common_init()
    LCOV_CWD = ENVIRON["DART_LCOV_CWD"]
    LCOV_FILES = 0
    LCOV_OPEN = 0
    LCOV_RECORD = 0

    # Either separator, because the three platforms spell lists differently: a
    # GitHub Actions input and an Azure DevOps variable are single strings a
    # caller naturally comma-separates, while a GitLab `variables:` entry is as
    # naturally written space-separated. Taking both removes a class of silent
    # misconfiguration where the whole value is read as one pattern that
    # matches nothing.
    LCOV_PATTERNS = py_split_ws(replace_all(ENVIRON["DART_COVERAGE_EXCLUDE"], ",", " "), LCOV_PATTERN)
    LCOV_PATTERN_TEXT = ""
    for (i = 1; i <= LCOV_PATTERNS; i++) {
        fnmatch_compile(i, LCOV_PATTERN[i])
        LCOV_PATTERN_TEXT = (i > 1) ? LCOV_PATTERN_TEXT " " LCOV_PATTERN[i] : LCOV_PATTERN[i]
    }
}

# Every input line. A lone carriage return ends a line too, as it does for
# Python's universal newlines; the empty piece `\r\n` leaves behind is skipped
# like any blank line.
{
    lcov_record($0)
}

function lcov_record(record,    parts, n, i) {
    if (FAILED != "") return
    LCOV_RECORD++
    n = split(record, parts, CHR[13])
    for (i = 1; i <= n; i++) lcov_line(parts[i])
}

function lcov_line(raw,    line, source, parts, n, f, key, hits, taken, comma) {
    # Nearly every line of a tracefile is a `DA:` or `BRDA:` row of plain
    # digits, so those two shapes are read directly; each means exactly what
    # the general path below would make of it, and anything else --
    # whitespace, a sign, an underscore, a checksum field -- takes that path.
    if (raw ~ /^DA:[0-9]+,[0-9]+$/) {
        if (!LCOV_OPEN) return
        comma = index(raw, ",")
        lcov_add_line(LCOV_CURRENT, lcov_line_key(substr(raw, 4, comma - 4)), substr(raw, comma + 1) + 0)
        return
    }
    if (raw ~ /^BRDA:[0-9]+,[0-9]+,[0-9]+,([0-9]+|-)$/) {
        if (!LCOV_OPEN) return
        split(substr(raw, 6), parts, ",")
        key = lcov_line_key(parts[1]) "," length(parts[2]) ":" parts[2] "," parts[3]
        lcov_add_branch(LCOV_CURRENT, key, (parts[4] == "-") ? 0 : parts[4] + 0)
        return
    }

    line = py_strip(utf8_sanitize(raw))
    if (line == "") return

    if (substr(line, 1, 3) == "SF:") {
        source = py_strip(substr(line, 4))
        # LCOV paths may be absolute (format_coverage emits them that way for
        # some inputs). Cobertura consumers match findings against the
        # repository tree, so they are made relative to the working directory.
        if (substr(source, 1, 1) == "/") source = py_relpath(source, LCOV_CWD)
        source = replace_all(source, "\\", "/")
        if (!(source in LCOV_INDEX)) {
            LCOV_INDEX[source] = ++LCOV_FILES
            LCOV_PATH[LCOV_FILES] = source
            LCOV_NLINES[LCOV_FILES] = LCOV_LC[LCOV_FILES] = 0
            LCOV_NBRANCHES[LCOV_FILES] = LCOV_BC[LCOV_FILES] = 0
        }
        LCOV_CURRENT = LCOV_INDEX[source]
        LCOV_OPEN = 1
        return
    }
    if (line == "end_of_record") {
        LCOV_OPEN = 0
        return
    }
    if (!LCOV_OPEN) return
    f = LCOV_CURRENT

    if (substr(line, 1, 3) == "DA:") {
        n = py_split(substr(line, 4), ",", parts)
        if (n < 2 || py_strip(parts[1]) !~ /^[0-9]+$/) return
        hits = py_int(parts[2]) ? PY_INT : 0
        lcov_add_line(f, lcov_line_key(py_strip(parts[1])), hits)
    } else if (substr(line, 1, 5) == "BRDA:") {
        n = py_split(substr(line, 6), ",", parts)
        if (n < 4 || py_strip(parts[1]) !~ /^[0-9]+$/) return
        # The block and branch ids are compared as the text they are, and
        # length-prefixed so that no two different pairs build the same key.
        key = lcov_line_key(py_strip(parts[1])) "," length(parts[2]) ":" parts[2] "," parts[3]
        if (parts[4] == "-" || parts[4] == "") taken = 0
        else if (py_int(parts[4])) taken = PY_INT
        else {
            # A count that is neither a number nor `-` is a corrupt tracefile,
            # and no report written from it would be right: stop, write
            # nothing, and fail -- the job's own verdict then says so.
            fail(1, "ERROR: line " LCOV_RECORD " of the tracefile is a malformed BRDA record: the taken count " py_repr(parts[4]) " is neither a number nor '-'.")
            return
        }
        lcov_add_branch(f, key, taken)
    }
}

# lcov_line_key <digits>
#
# A line number as the one string every spelling of it maps to, as Python's
# `int()` would: `007` is line 7. Digits with no leading zero already are that
# string, which spares a conversion on nearly every line.
function lcov_line_key(digits) {
    if (length(digits) > 15 || (length(digits) > 1 && substr(digits, 1, 1) == "0")) return fmt_int(digits + 0)
    return digits
}

# lcov_add_line <file> <line key> <hits>
#
# Add a `DA:` row to the file's merged record, keeping its covered count
# (LCOV_LC) current: a later record can move a line either way, since a count
# may be negative. LCOV_UNSORTED marks a file whose lines did not arrive in
# ascending order -- every Dart producer writes them in order, and a file that
# keeps to it is written without being sorted.
function lcov_add_line(f, key, hits,    before) {
    if ((f, key) in LCOV_HITS) before = LCOV_HITS[f, key]
    else {
        before = 0
        if (LCOV_NLINES[f] && key + 0 < LCOV_LINE[f, LCOV_NLINES[f]] + 0) LCOV_UNSORTED[f] = 1
        LCOV_LINE[f, ++LCOV_NLINES[f]] = key
    }
    LCOV_HITS[f, key] = before + hits
    if (before > 0) {
        if (before + hits <= 0) LCOV_LC[f]--
    } else if (before + hits > 0) LCOV_LC[f]++
}

# lcov_add_branch <file> <branch key> <taken>
#
# The same for a `BRDA:` row: the distinct branches (LCOV_NBRANCHES) and those
# taken at least once (LCOV_BC).
function lcov_add_branch(f, key, taken,    before) {
    if ((f, key) in LCOV_TAKEN) before = LCOV_TAKEN[f, key]
    else {
        before = 0
        LCOV_NBRANCHES[f]++
    }
    LCOV_TAKEN[f, key] = before + taken
    if (before > 0) {
        if (before + taken <= 0) LCOV_BC[f]--
    } else if (before + taken > 0) LCOV_BC[f]++
}

# py_relpath <absolute-path> <absolute-start>
#
# `os.path.relpath`: both sides normalised lexically (no symlink is resolved),
# the common leading components dropped, and the rest of <start> climbed out
# of with `..`.
function py_relpath(path, start,    pp, sp, np, ns, common, out, k) {
    np = py_normparts(path, pp)
    ns = py_normparts(start, sp)
    common = 0
    while (common < np && common < ns && (pp[common + 1] "") == (sp[common + 1] "")) common++
    out = ""
    for (k = common + 1; k <= ns; k++) out = (out == "") ? ".." : out "/.."
    for (k = common + 1; k <= np; k++) out = (out == "") ? pp[k] : out "/" pp[k]
    return (out == "") ? "." : out
}

# py_normparts <absolute-path> <array>
#
# The components of `os.path.normpath(<absolute-path>)`: empty and `.`
# components dropped, `..` removing the one before it (and nothing at the
# root).
function py_normparts(path, parts,    raw, n, i, m) {
    n = py_split(path, "/", raw)
    m = 0
    for (i = 1; i <= n; i++) {
        if (raw[i] == "" || raw[i] == ".") continue
        if (raw[i] == "..") {
            if (m > 0) m--
            continue
        }
        parts[++m] = raw[i]
    }
    return m
}

# lcov_finish
#
# Called from END, after the last record: orders the files by path, splits them
# into kept (LCOV_KEPT[1..LCOV_NKEPT]) and excluded (LCOV_DROPPED[1..
# LCOV_NDROPPED]) file indexes, and sets each file's counts: LCOV_LV/LCOV_LC
# (lines valid/covered) and LCOV_BV/LCOV_BC (branches).
function lcov_finish(    order, i, j, f, chars, n, excluded) {
    for (i = 1; i <= LCOV_FILES; i++) order[i] = LCOV_PATH[i]
    sort_strings(order, LCOV_FILES)
    LCOV_NKEPT = 0
    LCOV_NDROPPED = 0
    for (i = 1; i <= LCOV_FILES; i++) {
        f = LCOV_INDEX[order[i]]
        LCOV_LV[f] = LCOV_NLINES[f]
        LCOV_BV[f] = LCOV_NBRANCHES[f]

        excluded = 0
        if (LCOV_PATTERNS) {
            n = utf8_chars(LCOV_PATH[f], chars)
            for (j = 1; j <= LCOV_PATTERNS && !excluded; j++) excluded = fnmatch_match(j, chars, n)
        }
        if (excluded) LCOV_DROPPED[++LCOV_NDROPPED] = f
        else LCOV_KEPT[++LCOV_NKEPT] = f
    }
}

# lcov_threshold
#
# Read DART_COVERAGE_MINIMUM as the converter always has: stripped, then
# Python's `float()`. Sets LCOV_THRESHOLD_KIND ("" when unset or not a number,
# else what `py_float` returned) with LCOV_THRESHOLD / LCOV_THRESHOLD_NEGZERO,
# and returns 0 only when the value is set but is not a number -- after printing
# the warning both converters print for it.
function lcov_threshold(    raw) {
    LCOV_THRESHOLD_KIND = ""
    raw = py_strip(ENVIRON["DART_COVERAGE_MINIMUM"])
    if (raw == "") return 1
    LCOV_THRESHOLD_KIND = py_float(raw)
    if (LCOV_THRESHOLD_KIND == "") {
        printf "WARNING: DART_COVERAGE_MINIMUM=%s is not a number; ignoring.\n", py_repr(raw) > "/dev/stderr"
        return 0
    }
    LCOV_THRESHOLD = PY_FLOAT
    LCOV_THRESHOLD_NEGZERO = PY_FLOAT_NEGZERO
    return 1
}

# lcov_below_threshold <percent>
#
# The gate's comparison, `percent + 1e-9 < threshold`, with the tolerance that
# keeps a percentage printed as the floor from failing it.
function lcov_below_threshold(p) {
    if (LCOV_THRESHOLD_KIND == "inf") return 1
    if (LCOV_THRESHOLD_KIND != "num") return 0
    return p + 1e-9 < LCOV_THRESHOLD
}

# lcov_percent <covered> <valid>
#
# `covered / valid * 100.0`, in that order of operations, so that the double
# -- and therefore every rounded figure printed from it -- is Python's.
function lcov_percent(covered, valid) {
    return valid ? covered / valid * 100.0 : 0.0
}

# fnmatch_compile <index> <pattern>
#
# Compile a `DART_COVERAGE_EXCLUDE` pattern with Python's `fnmatch` semantics,
# which are the contract: matched against the whole relative path, `*` crossing
# `/` -- unlike a shell glob -- so `*.g.dart` matches
# `lib/presentation/i18n/catalog.g.dart` at any depth, with no `**/` prefix.
# `?` is one character, `[...]` and `[!...]` are sets, and there is no escape
# character. The translation is the one `fnmatch.translate` performs, token by
# token, so that patterns Python treats unusually (an unclosed `[`, a set
# opening with `]`, a reversed range) are treated the same way here.
#
# Token types in FN_TYPE[p, t]: "*", "?", "c" (FN_LIT[p, t]), "set" (FN_NEG and
# FN_NR ranges FN_LO/FN_HI, as code points) and "none" (a set nothing can
# match).
function fnmatch_compile(p, pattern,    pc, m, i, j, t, c) {
    m = utf8_chars(utf8_sanitize(pattern), pc)
    t = 0
    i = 1
    while (i <= m) {
        c = pc[i++]
        if (c == "*") {
            if (t == 0 || FN_TYPE[p, t] != "*") FN_TYPE[p, ++t] = "*"
        } else if (c == "?") {
            FN_TYPE[p, ++t] = "?"
        } else if (c == "[") {
            j = i
            if (j <= m && pc[j] == "!") j++
            if (j <= m && pc[j] == "]") j++
            while (j <= m && pc[j] != "]") j++
            if (j > m) {
                FN_TYPE[p, ++t] = "c"
                FN_LIT[p, t] = "["
            } else {
                fnmatch_set(p, ++t, pc, i, j)
                i = j + 1
            }
        } else {
            FN_TYPE[p, ++t] = "c"
            FN_LIT[p, t] = c
        }
    }
    FN_NTOK[p] = t
}

# fnmatch_set <index> <token> <chars> <first> <close>
#
# The set between pc[first] and the `]` at pc[close]: built into the regular
# expression `fnmatch.translate` would write, then read back the way Python's
# `re` reads a character class.
function fnmatch_set(p, t, pc, i, j,    k, hyphen, chunk, nch, ci, kk, stuff, x, q, sc, ns, neg, nr, code1, code2) {
    hyphen = 0
    for (k = i; k < j; k++) if (pc[k] == "-") hyphen = 1

    if (!hyphen) {
        stuff = ""
        for (k = i; k < j; k++) stuff = (pc[k] == "\\") ? stuff "\\\\" : stuff pc[k]
    } else {
        # Chunks between the hyphens that make ranges. A hyphen right after the
        # `[` (or `[!`) is literal, and so is one right after a range's end.
        nch = 0
        ci = i
        k = (pc[i] == "!") ? i + 2 : i + 1
        while (1) {
            kk = k
            while (kk < j && pc[kk] != "-") kk++
            if (kk >= j) break
            chunk[++nch] = fnmatch_join(pc, ci, kk)
            ci = kk + 1
            k = kk + 3
        }
        if (ci < j) chunk[++nch] = fnmatch_join(pc, ci, j)
        else chunk[nch] = chunk[nch] "-"
        # Remove empty ranges: a range whose start is after its end is dropped
        # along with the two characters that made it.
        for (k = nch; k >= 2; k--) {
            if (utf8_codepoint(fnmatch_last(chunk[k - 1])) > utf8_codepoint(fnmatch_first(chunk[k]))) {
                chunk[k - 1] = fnmatch_but_last(chunk[k - 1]) fnmatch_but_first(chunk[k])
                for (x = k; x < nch; x++) chunk[x] = chunk[x + 1]
                nch--
            }
        }
        stuff = ""
        for (k = 1; k <= nch; k++) {
            x = replace_all(replace_all(chunk[k], "\\", "\\\\"), "-", "\\-")
            stuff = (k > 1) ? stuff "-" x : x
        }
    }
    # The set operations `&&`, `~~` and `||` are escaped too.
    stuff = replace_all(replace_all(replace_all(stuff, "&", "\\&"), "~", "\\~"), "|", "\\|")

    if (stuff == "") {
        FN_TYPE[p, t] = "none"
        return
    }
    if (stuff == "!") {
        FN_TYPE[p, t] = "?"
        return
    }
    neg = 0
    if (substr(stuff, 1, 1) == "!") {
        neg = 1
        stuff = substr(stuff, 2)
    }

    # Read the class back as Python's `re` does: `\x` is the character x, and a
    # `-` between two characters is a range unless it is the last character.
    ns = utf8_chars(stuff, sc)
    nr = 0
    q = 1
    while (q <= ns) {
        if (sc[q] == "\\" && q < ns) code1 = utf8_codepoint(sc[++q])
        else code1 = utf8_codepoint(sc[q])
        q++
        if (q <= ns && sc[q] == "-" && q < ns) {
            q++
            if (sc[q] == "\\" && q < ns) code2 = utf8_codepoint(sc[++q])
            else code2 = utf8_codepoint(sc[q])
            q++
            if (code2 < code1) {
                # `re` rejects such a range ("bad character range"), so Python
                # would stop here with a traceback; it cannot be produced by the
                # translation above, which removes reversed ranges.
                fail(1, "ERROR: DART_COVERAGE_EXCLUDE pattern " py_repr(LCOV_PATTERN[p]) " builds a reversed character range.")
                return
            }
        } else if (q == ns && sc[q] == "-") {
            # A trailing `-` is literal, after the character before it.
            nr++
            FN_LO[p, t, nr] = code1
            FN_HI[p, t, nr] = code1
            code1 = utf8_codepoint("-")
            code2 = code1
            q++
        } else code2 = code1
        nr++
        FN_LO[p, t, nr] = code1
        FN_HI[p, t, nr] = code2
    }
    FN_TYPE[p, t] = "set"
    FN_NEG[p, t] = neg
    FN_NR[p, t] = nr
}

function fnmatch_join(pc, from, to,    s, k) {
    s = ""
    for (k = from; k < to; k++) s = s pc[k]
    return s
}

function fnmatch_first(s,    chars) {
    if (s == "") return ""
    utf8_chars(s, chars)
    return chars[1]
}

function fnmatch_last(s,    chars, n) {
    n = utf8_chars(s, chars)
    return n ? chars[n] : ""
}

function fnmatch_but_first(s) {
    return substr(s, length(fnmatch_first(s)) + 1)
}

function fnmatch_but_last(s) {
    return substr(s, 1, length(s) - length(fnmatch_last(s)))
}

# fnmatch_match <index> <chars> <count>
#
# Whether the path held in chars[1..count] matches pattern <index>. Every token
# but `*` matches exactly one character, so the classic single-backtrack
# wildcard match is exact: on a mismatch, the most recent `*` absorbs one more
# character and the match resumes after it.
function fnmatch_match(p, nc, n,    nt, ti, ni, st, sn) {
    nt = FN_NTOK[p]
    ti = 1
    ni = 1
    st = 0
    sn = 0
    while (ni <= n) {
        if (ti <= nt && FN_TYPE[p, ti] == "*") {
            st = ti
            sn = ni
            ti++
        } else if (ti <= nt && fnmatch_one(p, ti, nc[ni])) {
            ti++
            ni++
        } else if (st) {
            ti = st + 1
            ni = ++sn
        } else return 0
    }
    while (ti <= nt && FN_TYPE[p, ti] == "*") ti++
    return ti > nt
}

function fnmatch_one(p, t, ch,    type, cp, r, inside) {
    type = FN_TYPE[p, t]
    if (type == "?") return 1
    if (type == "c") return ch == FN_LIT[p, t]
    if (type == "none") return 0
    cp = utf8_codepoint(ch)
    inside = 0
    for (r = 1; r <= FN_NR[p, t] && !inside; r++)
        if (cp >= FN_LO[p, t, r] && cp <= FN_HI[p, t, r]) inside = 1
    return FN_NEG[p, t] ? !inside : inside
}

# py_dirname / py_basename / lcov_package
#
# `os.path.dirname` and `os.path.basename`, and the Cobertura package a file
# belongs to: its directory with `/` written `.`, or `.` for a file with none.
function py_dirname(p,    head) {
    if (!match(p, /\/[^\/]*$/)) return ""
    head = substr(p, 1, RSTART)
    if (head !~ /^\/+$/) sub(/\/+$/, "", head)
    return head
}

function py_basename(p) {
    if (!match(p, /\/[^\/]*$/)) return p
    return substr(p, RSTART + 1)
}

function lcov_package(p,    d) {
    d = py_dirname(p)
    return (d == "") ? "." : replace_all(d, "/", ".")
}

# lcov_open_output <path>
#
# Create the directory the report goes into, right before it is written: a
# tracefile that turns out to be corrupt leaves nothing behind, not even an
# empty directory.
function lcov_open_output(path,    dir) {
    dir = py_dirname(path)
    if (dir == "" || system("mkdir -p -- '" replace_all(dir, "'", "'\\''") "'") == 0) return
    fail(1, "ERROR: could not create the directory for '" path "'.")
}
