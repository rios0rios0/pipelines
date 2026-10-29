# Turn `dart analyze --format=machine` output into the JSON and JUnit reports,
# print the grouped summary and exit with the gate's verdict. Run by
# `analyze-report.sh`, after `common.awk`; see the script for the contract.
#
# Reads from the environment: DART_ANALYZE_JSON and DART_ANALYZE_JUNIT (the
# files to write; an empty DART_ANALYZE_JUNIT writes the JSON alone and prints
# nothing), DART_FATAL_WARNINGS and DART_FATAL_INFOS.

BEGIN {
    common_init()
    JSON_OUT = ENVIRON["DART_ANALYZE_JSON"]
    JUNIT_OUT = ENVIRON["DART_ANALYZE_JUNIT"]
    LEVELS = 3
    LEVEL[1] = "ERROR"
    LEVEL[2] = "WARNING"
    LEVEL[3] = "INFO"
    for (i = 1; i <= LEVELS; i++) {
        IS_LEVEL[LEVEL[i]] = 1
        COUNT[LEVEL[i]] = 0
    }
    # Errors always fail. Warnings fail unless DART_FATAL_WARNINGS says
    # otherwise. Infos -- which is where every lint from `package:lints` /
    # `package:flutter_lints` lands -- fail only when DART_FATAL_INFOS asks,
    # because a repository adopting a stricter lint set should be able to see
    # the findings before it has to fix all of them.
    FATAL["ERROR"] = 1
    if (truthy(ENVIRON["DART_FATAL_WARNINGS"], 1)) FATAL["WARNING"] = 1
    if (truthy(ENVIRON["DART_FATAL_INFOS"], 0)) FATAL["INFO"] = 1
    N = 0
}

{
    if (FAILED == "") parse_line($0)
}

# truthy <value> <default>
#
# Unset or empty is <default>; otherwise only `true`, `1` and `yes` (any case,
# surrounding whitespace ignored) are true -- so `false`, `no` and a typo are
# all false.
function truthy(value, fallback) {
    if (value == "") return fallback
    value = tolower(py_strip(value))
    return value == "true" || value == "1" || value == "yes"
}

# parse_line <line>
#
# One row of the machine format:
#
#     SEVERITY|TYPE|ERROR_CODE|FILE_PATH|LINE|COLUMN|LENGTH|ERROR_MESSAGE
#
# with `|` and `\` backslash-escaped inside the path and message fields. The
# unescaping is the whole reason this is a parser rather than a field split: a
# lint message containing a pipe (they do -- anything quoting an operator or a
# shell snippet) splits into the wrong number of fields otherwise, and the row
# silently lands in the report attributed to the wrong file. Anything that is
# not a diagnostic row -- the progress and summary lines `dart analyze` still
# prints in some SDK versions -- is skipped.
function parse_line(line,    fields, n, i, c, current, escaped, message) {
    while (substr(line, length(line)) == CHR[13]) line = substr(line, 1, length(line) - 1)
    if (py_strip(line) == "") return
    line = utf8_sanitize(line)

    if (!index(line, "\\")) n = py_split(line, "|", fields)
    else {
        n = 0
        current = ""
        escaped = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (escaped) {
                current = current c
                escaped = 0
            } else if (c == "\\") escaped = 1
            else if (c == "|") {
                fields[++n] = current
                current = ""
            } else current = current c
        }
        fields[++n] = current
    }
    if (n < 8 || !(fields[1] in IS_LEVEL)) return

    # The trailing message may itself contain pipes that were NOT escaped by
    # older SDKs; any surplus fields are joined back into it rather than
    # dropped.
    message = fields[8]
    for (i = 9; i <= n; i++) message = message "|" fields[i]

    N++
    D_SEVERITY[N] = fields[1]
    D_TYPE[N] = fields[2]
    D_CODE[N] = fields[3]
    D_FILE[N] = fields[4]
    D_LINE[N] = number(fields[5])
    D_COLUMN[N] = number(fields[6])
    D_LENGTH[N] = number(fields[7])
    D_MESSAGE[N] = message
    COUNT[fields[1]]++
}

# A position field that is not all digits is reported as 0.
function number(field) {
    return (field ~ /^[0-9]+$/) ? fmt_int(field + 0) : "0"
}

END {
    if (FAILED != "") exit FAILED
    FAILURES = 0
    for (i = 1; i <= N; i++) if (D_SEVERITY[i] in FATAL) FAILURES++

    write_json()
    if (JUNIT_OUT == "") exit 0
    write_junit()

    printf "dart analyze found %s issue(s): %s error(s), %s warning(s), %s info(s).\n", fmt_int(N), fmt_int(COUNT["ERROR"]), fmt_int(COUNT["WARNING"]), fmt_int(COUNT["INFO"])
    for (l = 1; l <= LEVELS; l++) {
        level = LEVEL[l]
        if (!COUNT[level]) continue
        printf "\n%s (%s, %s):\n", level, fmt_int(COUNT[level]), (level in FATAL) ? "FATAL" : "non-fatal"
        for (i = 1; i <= N; i++)
            if (D_SEVERITY[i] == level) printf "  - %s:%s:%s [%s] %s\n", D_FILE[i], D_LINE[i], D_COLUMN[i], D_CODE[i], D_MESSAGE[i]
    }

    blocking = 0
    for (l = 1; l <= LEVELS; l++) if (LEVEL[l] in FATAL) blocking += COUNT[LEVEL[l]]
    if (blocking) {
        printf "\n%s finding(s) at or above the configured severity gate; failing.\n", fmt_int(blocking) > "/dev/stderr"
        exit 1
    }
    exit 0
}

# write_json
#
# The layout `json.dump(..., indent=2)` writes, which is what every consumer of
# `analyze.json` has read so far.
function write_json(    i) {
    printf "{\n  \"tool\": \"dart analyze\",\n  \"summary\": {\n" > JSON_OUT
    printf "    \"ERROR\": %s,\n    \"WARNING\": %s,\n    \"INFO\": %s,\n    \"total\": %s\n  },\n", fmt_int(COUNT["ERROR"]), fmt_int(COUNT["WARNING"]), fmt_int(COUNT["INFO"]), fmt_int(N) > JSON_OUT
    if (!N) printf "  \"diagnostics\": []\n" > JSON_OUT
    else {
        printf "  \"diagnostics\": [\n" > JSON_OUT
        for (i = 1; i <= N; i++) {
            printf "    {\n      \"severity\": %s,\n      \"type\": %s,\n      \"code\": %s,\n      \"file\": %s,\n", json_quote(D_SEVERITY[i]), json_quote(D_TYPE[i]), json_quote(D_CODE[i]), json_quote(D_FILE[i]) > JSON_OUT
            printf "      \"line\": %s,\n      \"column\": %s,\n      \"length\": %s,\n      \"message\": %s\n    }%s\n", D_LINE[i], D_COLUMN[i], D_LENGTH[i], json_quote(D_MESSAGE[i]), (i < N) ? "," : "" > JSON_OUT
        }
        printf "  ]\n" > JSON_OUT
    }
    printf "}\n" > JSON_OUT
    close(JSON_OUT)
}

function write_junit(    i, name, classname, body, inner, total) {
    total = N ? N : 1
    printf "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" > JUNIT_OUT
    printf "<testsuites name=\"dart-analyze\" tests=\"%s\" failures=\"%s\">\n", fmt_int(total), fmt_int(FAILURES) > JUNIT_OUT
    printf "  <testsuite name=\"dart-analyze\" tests=\"%s\" failures=\"%s\">\n", fmt_int(total), fmt_int(FAILURES) > JUNIT_OUT
    for (i = 1; i <= N; i++) {
        name = D_CODE[i] " " D_FILE[i] ":" D_LINE[i] ":" D_COLUMN[i]
        classname = replace_all(D_FILE[i], "/", ".")
        if (substr(classname, length(classname) - 4) == ".dart" && length(classname) >= 5) classname = substr(classname, 1, length(classname) - 5)
        if (classname == "") classname = "dart"
        body = D_SEVERITY[i] " " D_TYPE[i] " " D_CODE[i] ": " D_MESSAGE[i]
        if (D_SEVERITY[i] in FATAL) inner = "      <failure message=" xml_quoteattr(D_MESSAGE[i]) " type=" xml_quoteattr(D_SEVERITY[i]) ">" xml_escape(body) "</failure>\n"
        # Non-fatal findings are recorded as skipped rather than omitted: they
        # stay visible in every platform's Tests tab (which is the point of
        # publishing this at all) without turning the job red.
        else inner = "      <skipped message=" xml_quoteattr(body) "/>\n"
        printf "    <testcase name=%s classname=%s>\n%s    </testcase>\n", xml_quoteattr(name), xml_quoteattr(classname), inner > JUNIT_OUT
    }
    if (!N) printf "    <testcase name=\"dart analyze\" classname=\"dart\"/>\n" > JUNIT_OUT
    printf "  </testsuite>\n</testsuites>\n" > JUNIT_OUT
    close(JUNIT_OUT)
}
