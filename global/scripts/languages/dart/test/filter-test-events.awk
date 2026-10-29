# Keep the package:test events of a `dart test` / `flutter test` machine stream.
# Run by `filter-test-events.sh`, after `common.awk`; see the script for the
# contract.
#
# A line is kept when it is a JSON document that is an object whose `type` is a
# string -- which is the whole protocol -- judged the way Python's `json.loads`
# judged it, since that is what decided until now. The grammar below is the one
# CPython's scanner accepts, not merely RFC 8259's: `NaN`, `Infinity` and
# `-Infinity` are values, a `\u` escape may name a lone surrogate (Dart's
# `jsonEncode` writes one for a string cut in half of an emoji), a raw control
# character inside a string is an error, and only space, tab, newline and
# carriage return are whitespace. jq is not used for this on purpose: its
# grammar varies by version (1.8 rejects a lone surrogate; it also accepts
# `01`, `.5`, `nan` and a leading byte order mark, which Python rejects), and
# a filter that disagrees with the old one on what an event is would drop real
# events or keep noise without a word.
#
# Kept lines are written to DART_EVENTS_KEPT_FILE as they were read (stripped,
# and with any malformed UTF-8 replaced, as Python decoded them); the counts go
# to stdout as `<kept> <dropped>`.

BEGIN {
    common_init()
    KEPT_FILE = ENVIRON["DART_EVENTS_KEPT_FILE"]
    KEPT = 0
    DROPPED = 0
    # Precompiled: a whole string token, and a number token, at the start of
    # what remains of the line.
    HEX = "[0-9A-Fa-f]"
    HEX_DIGITS = "0123456789abcdef"
    STRING_RE = "^\"([^\"\\\\" CHR[1] "-" CHR[31] "]|\\\\[\"\\\\/bfnrt]|\\\\u" HEX HEX HEX HEX ")*\""
    NUMBER_RE = "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][-+]?[0-9]+)?"
    # The parser recurses once per nested container, and BusyBox awk overflows
    # its stack a few thousand levels down. A test event nests about five
    # levels, so a line nested deeper than this is dropped rather than parsed;
    # Python's parser gave up near the same depth, in its 3.11 that the GitLab
    # job ran, by crashing the whole filter.
    JSON_MAX_DEPTH = 1000
}

# A lone carriage return ends a line too, as it did for Python's universal
# newlines; the empty piece `\r\n` leaves behind is skipped like a blank line.
{
    if (FAILED != "") next
    filter_record($0)
}

function filter_record(record,    parts, n, i, line) {
    n = split(record, parts, CHR[13])
    for (i = 1; i <= n; i++) {
        line = py_strip(utf8_sanitize(parts[i]))
        if (line == "") continue
        if (is_test_event(line)) {
            KEPT++
            printf "%s\n", line > KEPT_FILE
        } else DROPPED++
    }
}

END {
    if (FAILED != "") exit FAILED
    if (KEPT) close(KEPT_FILE)
    printf "%s %s\n", fmt_int(KEPT), fmt_int(DROPPED)
}

# is_test_event <line>
#
# Whether <line> is one JSON document, an object, whose last `type` member (a
# repeated key keeps its last value, as a dict does) is a string. Any other
# document -- an array, a string, invalid JSON -- is dropped, so a line that
# does not even open with `{` is decided without being parsed.
function is_test_event(line) {
    J = line
    JP = 1
    JN = length(line)
    JTYPE = ""
    if (substr(J, 1, 1) != "{") return 0
    if (!json_value(0)) return 0
    json_ws()
    return JP > JN && JTYPE == "string"
}

function json_ws(    c) {
    while (JP <= JN) {
        c = substr(J, JP, 1)
        if (c != " " && c != "\t" && c != "\n" && c != "\r") return
        JP++
    }
}

# json_value <depth>
#
# Consume one value at JP. <depth> 0 is the document itself.
function json_value(depth,    c) {
    if (JP > JN || depth > JSON_MAX_DEPTH) return 0
    c = substr(J, JP, 1)
    if (c == "{") return json_object(depth)
    if (c == "[") return json_array(depth)
    if (c == "\"") return json_string()
    if (c == "n") return json_literal("null")
    if (c == "t") return json_literal("true")
    if (c == "f") return json_literal("false")
    if (c == "N") return json_literal("NaN")
    if (c == "I") return json_literal("Infinity")
    if (c == "-" && substr(J, JP, 9) == "-Infinity") return json_literal("-Infinity")
    if (!match(substr(J, JP), NUMBER_RE)) return 0
    JP += RLENGTH
    return 1
}

function json_literal(word) {
    if (substr(J, JP, length(word)) != word) return 0
    JP += length(word)
    return 1
}

# json_string
#
# Consume one string token; JSTRING is left holding its raw text, quotes
# excluded.
function json_string() {
    if (!match(substr(J, JP), STRING_RE)) return 0
    JSTRING = substr(J, JP + 1, RLENGTH - 2)
    JP += RLENGTH
    return 1
}

function json_object(depth,    key, c, is_string) {
    JP++
    json_ws()
    if (substr(J, JP, 1) == "}") {
        JP++
        return 1
    }
    while (1) {
        if (substr(J, JP, 1) != "\"" || !json_string()) return 0
        key = JSTRING
        json_ws()
        if (substr(J, JP, 1) != ":") return 0
        JP++
        json_ws()
        is_string = (substr(J, JP, 1) == "\"")
        if (!json_value(depth + 1)) return 0
        if (depth == 0 && json_key_is_type(key)) JTYPE = is_string ? "string" : "other"
        json_ws()
        c = substr(J, JP, 1)
        JP++
        if (c == "}") return 1
        if (c != ",") return 0
        json_ws()
    }
}

function json_array(depth,    c) {
    JP++
    json_ws()
    if (substr(J, JP, 1) == "]") {
        JP++
        return 1
    }
    while (1) {
        if (!json_value(depth + 1)) return 0
        json_ws()
        c = substr(J, JP, 1)
        JP++
        if (c == "]") return 1
        if (c != ",") return 0
        json_ws()
    }
}

# json_key_is_type <raw key>
#
# Whether a key's text, once its escapes are decoded, is `type`. Of the escapes
# only `\u00XX` can spell one of its letters -- a `t` written as the escape of
# U+0074 still makes the key `type` -- so any other one rules the key out
# without being decoded.
function json_key_is_type(raw,    out, i, n, c, hex, v) {
    if (!index(raw, "\\")) return raw == "type"
    out = ""
    n = length(raw)
    for (i = 1; i <= n; i++) {
        c = substr(raw, i, 1)
        if (c != "\\") {
            out = out c
            continue
        }
        if (substr(raw, i + 1, 1) != "u") return 0
        hex = tolower(substr(raw, i + 2, 4))
        i += 5
        if (substr(hex, 1, 2) != "00") return 0
        v = (index(HEX_DIGITS, substr(hex, 3, 1)) - 1) * 16 + index(HEX_DIGITS, substr(hex, 4, 1)) - 1
        if (v < 32 || v > 126) return 0
        out = out CHR[v]
    }
    return out == "type"
}
