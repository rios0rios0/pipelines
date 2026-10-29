# Helpers shared by the Dart report converters, loaded ahead of each one:
#
#   LC_ALL=C awk -f common.awk [-f test/lcov.awk] -f <converter>.awk
#
# Loaded, never executed -- so no shebang and no executable bit, the same
# contract as `common.sh` beside it.
#
# The converters replaced Python helpers, and every report they write is read
# by something that takes it literally: Azure DevOps and GitLab parse the
# Cobertura, a pull request shows the Markdown, `dorny/test-reporter` parses the
# event stream, and the GitLab templates scrape a log line. So each helper here
# reproduces the Python behaviour it replaced rather than an approximation of
# it: the whitespace `str.strip()` removes, the `int()` and `float()` grammars,
# UTF-8 decoding with `errors="replace"`, the ASCII escaping of `json.dumps` and
# the quoting of `xml.sax.saxutils`. A difference here is a byte that differs in
# a published report, which nothing downstream reports.
#
# Every caller runs awk under LC_ALL=C, and everything below depends on it: the
# programs work on BYTES, so `length`, `substr` and `index` count bytes, string
# comparison is byte order (which, for UTF-8, is code point order -- the order
# Python's `sorted()` uses), and `printf` writes a `.` decimal point whatever
# the runner's locale. Wherever Python would see one code point, the code below
# handles the UTF-8 sequence explicitly.
#
# POSIX awk only -- verified under mawk (the awk of Debian, Ubuntu and their CI
# images) and BusyBox awk (Alpine). Two traps shaped it, and both are silent:
#
#   - `%d` overflows above 2^31 in BusyBox and clamps in older mawk, and older
#     mawk converts 2^31 to "2.14748e+09" when a number becomes a string or an
#     array subscript. So every integer is printed with `%.0f` (`fmt_int`), and
#     no number is ever converted to a string implicitly.
#   - older mawk and BusyBox convert strings with `strtod`, which reads `0x1A`,
#     `inf` and `nan` as numbers. So a string is checked against Python's own
#     grammar BEFORE it is converted (`py_int`, `py_float`).

# common_init
#
# Build the byte tables everything else uses. Must run first, from BEGIN.
function common_init(    i) {
    for (i = 1; i < 256; i++) {
        CHR[i] = sprintf("%c", i)
        ORD[CHR[i]] = i
    }
    # An awk that is not byte-oriented under LC_ALL=C (one that decodes UTF-8
    # regardless of the locale) would make every table below wrong; refuse it
    # rather than write reports that are subtly corrupt.
    if (length(CHR[200]) != 1) {
        fail(2, "ERROR: this awk does not treat strings as bytes under LC_ALL=C, which the Dart report converters require.")
        return
    }
    FFFD = CHR[239] CHR[191] CHR[189]
    HIGH_BYTE_RE = "[" CHR[128] "-" CHR[255] "]"
    CONTROL_RE = "[" CHR[1] "-" CHR[31] CHR[127] "-" CHR[255] "]"

    # Python's whitespace (`str.isspace()`), which is what `str.strip()` and
    # `str.split()` remove: the ASCII six, the four information separators, and
    # the Unicode spaces, held as the UTF-8 sequences they arrive as.
    split("9 10 11 12 13 28 29 30 31 32", WS_TMP, " ")
    for (i = 1; i <= 10; i++) WS1[CHR[WS_TMP[i] + 0]] = 1
    WS2[CHR[194] CHR[133]] = 1                 # U+0085
    WS2[CHR[194] CHR[160]] = 1                 # U+00A0
    WS3[CHR[225] CHR[154] CHR[128]] = 1        # U+1680
    for (i = 128; i <= 138; i++) WS3[CHR[226] CHR[128] CHR[i]] = 1   # U+2000 to U+200A
    WS3[CHR[226] CHR[128] CHR[168]] = 1        # U+2028
    WS3[CHR[226] CHR[128] CHR[169]] = 1        # U+2029
    WS3[CHR[226] CHR[128] CHR[175]] = 1        # U+202F
    WS3[CHR[226] CHR[129] CHR[159]] = 1        # U+205F
    WS3[CHR[227] CHR[128] CHR[128]] = 1        # U+3000

    # The line boundaries `str.splitlines()` splits on, beyond `\n` and `\r`.
    LB1[CHR[10]] = 1; LB1[CHR[11]] = 1; LB1[CHR[12]] = 1; LB1[CHR[13]] = 1
    LB1[CHR[28]] = 1; LB1[CHR[29]] = 1; LB1[CHR[30]] = 1
    LB2[CHR[194] CHR[133]] = 1                 # U+0085
    LB3[CHR[226] CHR[128] CHR[168]] = 1        # U+2028
    LB3[CHR[226] CHR[128] CHR[169]] = 1        # U+2029

    # The short escapes `json.dumps` writes; every other control character
    # becomes `\u00XX`.
    JSON_SHORT[CHR[8]] = "\\b"
    JSON_SHORT[CHR[9]] = "\\t"
    JSON_SHORT[CHR[10]] = "\\n"
    JSON_SHORT[CHR[12]] = "\\f"
    JSON_SHORT[CHR[13]] = "\\r"

    # The escapes `repr()` writes for the ASCII controls it names.
    REPR_SHORT[CHR[9]] = "\\t"
    REPR_SHORT[CHR[10]] = "\\n"
    REPR_SHORT[CHR[13]] = "\\r"
}

# fail <code> <message>
#
# Report an error on stderr and stop. `exit` from a function still runs the END
# rules, so every program's END starts with `if (FAILED != "") exit FAILED`.
function fail(code, message) {
    printf "%s\n", message > "/dev/stderr"
    FAILED = code
    exit code
}

# fmt_int <number>
#
# An integer as Python's `str(int)` writes it. `%.0f` rather than `%d`: see the
# header for the overflow it avoids.
function fmt_int(x,    s) {
    s = sprintf("%.0f", x)
    return (s == "-0") ? "0" : s
}

# ws_len <string> <position>
#
# The byte length of the Python whitespace character starting at <position>,
# or 0 when the character there is not whitespace. Byte-wise scanning is safe:
# every whitespace sequence starts with a byte that never continues a UTF-8
# character.
function ws_len(s, i) {
    if ((substr(s, i, 1)) in WS1) return 1
    if ((substr(s, i, 2)) in WS2) return 2
    if ((substr(s, i, 3)) in WS3) return 3
    return 0
}

# py_strip <string>
#
# `str.strip()`: Python's whitespace removed from both ends.
function py_strip(s,    i, n, w) {
    n = length(s)
    i = 1
    while (i <= n && (w = ws_len(s, i)) > 0) i += w
    if (i > 1) s = substr(s, i)
    n = length(s)
    while (n > 0) {
        if ((substr(s, n, 1)) in WS1) n -= 1
        else if (n >= 2 && ((substr(s, n - 1, 2)) in WS2)) n -= 2
        else if (n >= 3 && ((substr(s, n - 2, 3)) in WS3)) n -= 3
        else break
    }
    return substr(s, 1, n)
}

# py_split <string> <separator> <array>
#
# `str.split(separator)`: always at least one field, empty fields kept. awk's
# own `split` returns no field at all for an empty string.
function py_split(s, sep, arr,    n, i, l) {
    n = 0
    l = length(sep)
    while ((i = index(s, sep)) > 0) {
        arr[++n] = substr(s, 1, i - 1)
        s = substr(s, i + l)
    }
    arr[++n] = s
    return n
}

# py_split_ws <string> <array>
#
# `str.split()` with no separator: runs of whitespace separate, and no field is
# ever empty.
function py_split_ws(s, arr,    n, i, len, start, w) {
    n = 0
    len = length(s)
    i = 1
    while (i <= len) {
        while (i <= len && (w = ws_len(s, i)) > 0) i += w
        if (i > len) break
        start = i
        while (i <= len && ws_len(s, i) == 0) i++
        arr[++n] = substr(s, start, i - start)
    }
    return n
}

# py_splitlines <string> <array>
#
# `str.splitlines()`: every Python line boundary separates, `\r\n` counts as
# one, and a trailing boundary adds no empty field.
function py_splitlines(s, arr,    n, i, len, start, w) {
    n = 0
    len = length(s)
    i = 1
    start = 1
    while (i <= len) {
        if ((substr(s, i, 1)) in LB1) w = (substr(s, i, 2) == CHR[13] CHR[10]) ? 2 : 1
        else if ((substr(s, i, 2)) in LB2) w = 2
        else if ((substr(s, i, 3)) in LB3) w = 3
        else {
            i++
            continue
        }
        arr[++n] = substr(s, start, i - start)
        i += w
        start = i
    }
    if (start <= len) arr[++n] = substr(s, start)
    return n
}

# replace_all <string> <from> <to>
#
# Literal replacement of every occurrence, as `str.replace` does. Written with
# `index` rather than `gsub`, whose replacement text treats `&` and `\` as
# special in ways that differ between awks.
function replace_all(s, from, to,    out, i, l) {
    if (!index(s, from)) return s
    out = ""
    l = length(from)
    while ((i = index(s, from)) > 0) {
        out = out substr(s, 1, i - 1) to
        s = substr(s, i + l)
    }
    return out s
}

# utf8_sanitize <string>
#
# Decode as Python does with `errors="replace"`: each maximal ill-formed
# subsequence becomes one U+FFFD, and well-formed text is returned unchanged.
function utf8_sanitize(s,    out, i, n, b, need, lo, hi, j, c) {
    if (s !~ HIGH_BYTE_RE) return s
    out = ""
    n = length(s)
    i = 1
    while (i <= n) {
        b = ORD[substr(s, i, 1)]
        if (b < 128) {
            out = out substr(s, i, 1)
            i++
            continue
        }
        lo = 128
        hi = 191
        if (b >= 194 && b <= 223) need = 1
        else if (b == 224) { need = 2; lo = 160 }
        else if ((b >= 225 && b <= 236) || b == 238 || b == 239) need = 2
        else if (b == 237) { need = 2; hi = 159 }
        else if (b == 240) { need = 3; lo = 144 }
        else if (b >= 241 && b <= 243) need = 3
        else if (b == 244) { need = 3; hi = 143 }
        else {
            out = out FFFD
            i++
            continue
        }
        for (j = 1; j <= need; j++) {
            if (i + j > n) break
            c = ORD[substr(s, i + j, 1)]
            if (j == 1) {
                if (c < lo || c > hi) break
            } else if (c < 128 || c > 191) break
        }
        if (j > need) {
            out = out substr(s, i, need + 1)
            i += need + 1
        } else {
            out = out FFFD
            i += j
        }
    }
    return out
}

# utf8_chars <string> <array>
#
# Split well-formed UTF-8 into its characters, one per element.
function utf8_chars(s, arr,    n, i, len, b, w) {
    n = 0
    len = length(s)
    i = 1
    while (i <= len) {
        b = ORD[substr(s, i, 1)]
        w = (b < 192) ? 1 : (b < 224) ? 2 : (b < 240) ? 3 : 4
        arr[++n] = substr(s, i, w)
        i += w
    }
    return n
}

# utf8_codepoint <character>
function utf8_codepoint(ch,    n, b) {
    n = length(ch)
    b = ORD[substr(ch, 1, 1)]
    if (n <= 1) return b + 0
    if (n == 2) return (b - 192) * 64 + ORD[substr(ch, 2, 1)] - 128
    if (n == 3) return ((b - 224) * 64 + ORD[substr(ch, 2, 1)] - 128) * 64 + ORD[substr(ch, 3, 1)] - 128
    return (((b - 240) * 64 + ORD[substr(ch, 2, 1)] - 128) * 64 + ORD[substr(ch, 3, 1)] - 128) * 64 + ORD[substr(ch, 4, 1)] - 128
}

# utf8_length <string>
#
# The length Python's `len()` reports: characters, not bytes.
function utf8_length(s,    chars) {
    return utf8_chars(s, chars)
}

# utf8_prefix <string> <count>
#
# The first <count> characters, as Python's `s[:count]` slices them.
function utf8_prefix(s, count,    chars, n, i, out) {
    n = utf8_chars(s, chars)
    out = ""
    for (i = 1; i <= n && i <= count; i++) out = out chars[i]
    return out
}

# py_int <string>
#
# Whether <string> is something Python's `int()` accepts, setting PY_INT to its
# value when it is: optional whitespace, an optional sign, and decimal digits
# that may be grouped by single underscores.
function py_int(s) {
    s = py_strip(s)
    if (s !~ /^[-+]?[0-9](_?[0-9])*$/) return 0
    gsub(/_/, "", s)
    PY_INT = s + 0
    if (PY_INT == 0) PY_INT = 0
    return 1
}

# py_float <string>
#
# What Python's `float()` makes of <string>: "" when it raises ValueError,
# otherwise "num" (value in PY_FLOAT, PY_FLOAT_NEGZERO set for -0.0), "inf",
# "-inf" or "nan". The special values are kept apart because awks print and
# compare them inconsistently, and Python writes them as `inf` and `nan`.
function py_float(s,    t) {
    s = py_strip(s)
    t = tolower(s)
    if (t ~ /^[-+]?nan$/) return "nan"
    if (t ~ /^[+]?inf(inity)?$/) return "inf"
    if (t ~ /^-inf(inity)?$/) return "-inf"
    if (s !~ /^[-+]?(([0-9](_?[0-9])*)?\.[0-9](_?[0-9])*|[0-9](_?[0-9])*\.?)([eE][-+]?[0-9](_?[0-9])*)?$/) return ""
    gsub(/_/, "", s)
    PY_FLOAT = s + 0
    PY_FLOAT_NEGZERO = 0
    if (PY_FLOAT == 0) {
        PY_FLOAT = 0
        PY_FLOAT_NEGZERO = (substr(s, 1, 1) == "-")
    } else if (PY_FLOAT == 2 * PY_FLOAT) {
        return (PY_FLOAT > 0) ? "inf" : "-inf"
    }
    return "num"
}

# py_fixed <kind> <value> <negzero> <digits>
#
# `"{:.<digits>f}".format(value)` for a value `py_float` classified.
function py_fixed(kind, value, negzero, digits) {
    if (kind == "nan") return "nan"
    if (kind == "inf") return "inf"
    if (kind == "-inf") return "-inf"
    if (value == 0) return (negzero ? "-" : "") sprintf("%." digits "f", 0)
    return sprintf("%." digits "f", value)
}

# py_repr <string>
#
# `repr()` of a str, exact for ASCII: single quotes unless the text holds a
# single quote and no double one, backslashes and the quote escaped, and the
# ASCII controls written as `\t`, `\n`, `\r` or `\xNN`. Of the characters
# outside ASCII, the Latin-1 ones Python does not print (C1 controls, NBSP,
# soft hyphen) and the Unicode spaces and format characters are escaped too.
function py_repr(s,    q, out, chars, n, i, ch, cp) {
    q = (index(s, "'") && !index(s, "\"")) ? "\"" : "'"
    out = q
    n = utf8_chars(utf8_sanitize(s), chars)
    for (i = 1; i <= n; i++) {
        ch = chars[i]
        cp = utf8_codepoint(ch)
        if (ch == "\\" || ch == q) out = out "\\" ch
        else if (ch in REPR_SHORT) out = out REPR_SHORT[ch]
        else if (cp < 32 || cp == 127 || (cp >= 128 && cp <= 160) || cp == 173) out = out sprintf("\\x%02x", cp)
        else if (cp == 5760 || (cp >= 8192 && cp <= 8207) || (cp >= 8232 && cp <= 8239) || (cp >= 8287 && cp <= 8303) || cp == 12288 || cp == 65279) out = out sprintf("\\u%04x", cp)
        else out = out ch
    }
    return out q
}

# json_quote <string>
#
# A JSON string literal exactly as `json.dumps` writes it with its default
# `ensure_ascii=True`: printable ASCII as is, `"` and `\` escaped, the five
# short escapes, every other control character and everything beyond ASCII as
# lowercase `\uXXXX`, characters outside the BMP as a surrogate pair.
function json_quote(s,    out, chars, n, i, ch, cp) {
    if (!index(s, "\"") && !index(s, "\\") && s !~ CONTROL_RE) return "\"" s "\""
    out = ""
    n = utf8_chars(utf8_sanitize(s), chars)
    for (i = 1; i <= n; i++) {
        ch = chars[i]
        if (ch == "\"" || ch == "\\") {
            out = out "\\" ch
            continue
        }
        if (ch in JSON_SHORT) {
            out = out JSON_SHORT[ch]
            continue
        }
        cp = utf8_codepoint(ch)
        if (cp >= 32 && cp < 127) out = out ch
        else if (cp < 65536) out = out sprintf("\\u%04x", cp)
        else {
            cp -= 65536
            out = out sprintf("\\u%04x\\u%04x", 55296 + int(cp / 1024), 56320 + cp % 1024)
        }
    }
    return "\"" out "\""
}

# xml_escape <string>
#
# `xml.sax.saxutils.escape`: `&`, `>` and `<`, in that order.
function xml_escape(s) {
    s = replace_all(s, "&", "&amp;")
    s = replace_all(s, ">", "&gt;")
    return replace_all(s, "<", "&lt;")
}

# xml_quoteattr <string>
#
# `xml.sax.saxutils.quoteattr`: the value escaped, newlines, carriage returns
# and tabs as character references, and quoted with whichever quote it does not
# contain -- double quotes, with `"` written `&quot;`, when it contains both.
function xml_quoteattr(s) {
    s = xml_escape(s)
    s = replace_all(s, CHR[10], "&#10;")
    s = replace_all(s, CHR[13], "&#13;")
    s = replace_all(s, CHR[9], "&#9;")
    if (index(s, "\"")) {
        if (index(s, "'")) return "\"" replace_all(s, "\"", "&quot;") "\""
        return "'" s "'"
    }
    return "\"" s "\""
}

# sort_strings <array> <count>
#
# Sort elements 1..count in byte order, which is Python's `sorted()` order for
# UTF-8 text. Heapsort: POSIX awk has no sort of its own. Each operand is
# concatenated with "" so that two values that look numeric are still compared
# as strings.
function sort_strings(a, n,    i, t) {
    for (i = int(n / 2); i >= 1; i--) sift_strings(a, i, n)
    for (i = n; i > 1; i--) {
        t = a[1]
        a[1] = a[i]
        a[i] = t
        sift_strings(a, 1, i - 1)
    }
}

function sift_strings(a, i, n,    c, t) {
    while ((c = 2 * i) <= n) {
        if (c < n && (a[c] "") < (a[c + 1] "")) c++
        if ((a[i] "") >= (a[c] "")) return
        t = a[i]
        a[i] = a[c]
        a[c] = t
        i = c
    }
}

# sort_numbers <array> <count>
#
# The same, in numeric order.
function sort_numbers(a, n,    i, t) {
    for (i = int(n / 2); i >= 1; i--) sift_numbers(a, i, n)
    for (i = n; i > 1; i--) {
        t = a[1]
        a[1] = a[i]
        a[i] = t
        sift_numbers(a, 1, i - 1)
    }
}

function sift_numbers(a, i, n,    c, t) {
    while ((c = 2 * i) <= n) {
        if (c < n && a[c] + 0 < a[c + 1] + 0) c++
        if (a[i] + 0 >= a[c] + 0) return
        t = a[i]
        a[i] = a[c]
        a[c] = t
        i = c
    }
}

# read_file <path>
#
# The whole content of <path>, lines joined by "\n" (the final newline, if any,
# is not kept). Empty when the file is missing or unreadable.
function read_file(path,    content, line, first) {
    content = ""
    first = 1
    if (path == "") return ""
    while ((getline line < path) > 0) {
        content = first ? line : content "\n" line
        first = 0
    }
    close(path)
    return content
}
