#!/usr/bin/env sh

# Sourced, never executed: the one definition of which ROOT modules
# `TERRA_TEST_ROOTS` adds to the terra-test tier, and of which of them it must
# refuse to run. `terra-test/run.sh` runs what this lists and `test-all/run.sh`
# asks it whether tier 1 has anything to run, so the two cannot disagree -- the
# orchestrator never detects a test the runner then skips, nor skips a
# repository whose only tests the runner would have run.

# Prints one root module per line, sorted and de-duplicated: every directory at
# any depth under the space-separated `TERRA_TEST_ROOTS` that holds a
# `*.tftest.hcl` DIRECTLY in its `tests/` directory. Prints nothing when the
# variable is empty or names nothing that exists.
#
# - Directly, because `tests/` is the directory `terraform test` reads, and it is
#   the same non-recursive rule the module loop applies to
#   `modules/<name>/tests/`. A `tests/e2e/*.tftest.hcl` is an apply-time suite
#   this tier never runs; a pattern that matched it would hand the runner the
#   test FILE as a root. (`terraform test` also reads `*.tftest.hcl` sitting
#   beside the root's `.tf` files; they do not select a root, but once one is
#   selected they run too, which is why `terra_test_root_apply_runs` reads them.)
# - Vendored and derived trees are pruned at any depth -- `terraform init`
#   copies module sources into `.terraform/`, and Terragrunt copies whole
#   stacks, `tests/` included, into `.terragrunt-cache/`. Same set as
#   `VENDORED_DIRS` in `terra_coverage.py`.
# - A leading `./` is stripped, so `.`, `./stacks` and `stacks` name a root the
#   same way. The runner names each JUnit file after this path.
# - `modules/<name>` is dropped: the module loop already runs it, so a broad
#   root such as `.` cannot run a module's tests twice.
terra_test_root_dirs() {
  # shellcheck disable=SC2086 # word splitting is intended: these are separate paths
  for terra_test_search_root in ${TERRA_TEST_ROOTS:-}; do
    [ -d "${terra_test_search_root}" ] || continue
    find "${terra_test_search_root}" \
      \( -name .terraform -o -name .terragrunt-cache -o -name .external_modules -o -name .git \) -prune \
      -o -type f -name '*.tftest.hcl' -print
  done \
    | sed -n 's|/tests/[^/]*\.tftest\.hcl$||p' \
    | sed -e 's|^\(\./\)*||' -e '/^modules\/[^/]*$/d' \
    | sort -u
}

# Prints one line per test block that would make `terraform test` APPLY the root
# module $1 with its real providers -- `<file>:<line>: run "<name>" ...` --
# and nothing when there is none. Always returns 0; the runner refuses a root
# for which anything is printed, and never calls this for `modules/<name>`.
#
# Why: a `run` block that sets no `command` defaults to `apply`, and a root
# module carries its real provider configuration. The tier initialises a root
# `-backend=false`, so whatever such a run creates is recorded only inside the
# test process: a cancelled job, an evicted runner or a failure before the
# implicit destroy orphans it, with no state left to destroy it from.
#
# Reads what `terraform test` reads from a root: `*.tftest.hcl` beside its
# `.tf` files and in its `tests/`. A finding is a `run` block whose own
# `command` is absent or `apply`, in a file that declares no `mock_provider`
# (one anywhere in the file is taken as the file's word that its runs are
# mocked). The scan tokenizes rather than greps, so how a file is written does
# not change the answer:
# - `#`, `//` and `/* */` comments are skipped: a commented-out
#   `command = plan` or `mock_provider` counts for nothing;
# - quoted strings (escapes and `${ }` templates included) and heredoc bodies
#   are skipped: a brace, a `//` or a `run "x" {` inside one is not structure;
# - braces are counted: only a `command` at the run block's OWN top level
#   counts, never one inside a nested block such as `variables { }`;
# - `command=plan` and `command = plan` are the same statement.
# A `*.tftest.json` is reported, not read -- this check parses HCL only -- and
# a file that cannot be read is reported too, so the check fails closed.
terra_test_root_apply_runs() {
  for terra_test_file in "$1"/*.tftest.hcl "$1"/tests/*.tftest.hcl; do
    [ -f "${terra_test_file}" ] || continue
    # shellcheck disable=SC2094 # only read: the name reaches awk for the report, nothing writes the file
    TERRA_TEST_FILE="${terra_test_file}" LC_ALL=C awk '
      function token(kind, text) {
        if (kind == "newline") {
          if (paren == 0) { at_start = 1; header_step = 0; command_step = 0 }
          return
        }
        # `run <label> {` and `mock_provider <label> {`, at the top level only.
        if (header_step == 1) {
          header_step = 0
          if (kind == "word" || kind == "string") { header_label = text; header_step = 2; return }
        } else if (header_step == 2) {
          header_step = 0
          if (kind == "{" && header == "run") {
            in_run = 1; run_name = header_label; run_line = header_line; run_command = ""
          } else if (kind == "{") {
            mocked = 1
          }
        }
        # `command = <keyword>`, at the top level of a run block body only.
        if (command_step == 1) {
          command_step = 0
          if (kind == "=") { command_step = 2; return }
        } else if (command_step == 2) {
          command_step = 0
          if (kind == "word" || kind == "string") { run_command = text; return }
        }
        if (kind == "{") { depth++; at_start = 1; return }
        if (kind == "}") {
          if (depth > 0) depth--
          if (in_run && depth == 0) close_run()
          at_start = 0
          return
        }
        if (kind == "word" && at_start && paren == 0) {
          if (depth == 0 && (text == "run" || text == "mock_provider")) {
            header = text; header_step = 1; header_line = NR; at_start = 0
            return
          }
          if (in_run && depth == 1 && text == "command") { command_step = 1; at_start = 0; return }
        }
        at_start = 0
      }

      function close_run() {
        if (run_command == "") {
          found++
          finding[found] = file ":" run_line ": run \"" run_name "\" sets no command, so it applies"
        } else if (run_command == "apply") {
          found++
          finding[found] = file ":" run_line ": run \"" run_name "\" sets command = apply"
        }
        in_run = 0
      }

      BEGIN { file = ENVIRON["TERRA_TEST_FILE"]; at_start = 1; sp = 0; mode[0] = 0 }

      {
        line = $0
        sub(/\r$/, "", line)
        if (heredoc != "") {
          marker = line
          gsub(/^[ \t]+|[ \t]+$/, "", marker)
          if (marker == heredoc) { heredoc = ""; if (sp == 0) token("newline") }
          next
        }
        n = length(line)
        i = 1
        while (i <= n) {
          c = substr(line, i, 1)
          d = substr(line, i + 1, 1)
          if (in_comment) {
            if (c == "*" && d == "/") { in_comment = 0; i += 2 } else i++
            continue
          }
          # mode 1: inside a quoted string. Only the outermost string is kept,
          # as a block label is one.
          if (mode[sp] == 1) {
            if (c == "\\" || ((c == "$" || c == "%") && d == c)) {
              if (sp == 1) buffer = buffer c d
              i += 2
              continue
            }
            if ((c == "$" || c == "%") && d == "{") { sp++; mode[sp] = 2; braces[sp] = 1; i += 2; continue }
            if (c == "\"") { sp--; i++; if (sp == 0) token("string", buffer); continue }
            if (sp == 1) buffer = buffer c
            i++
            continue
          }
          # code: mode 0 at the top, mode 2 inside a template interpolation.
          if (c == "#" || (c == "/" && d == "/")) break
          if (c == "/" && d == "*") { in_comment = 1; i += 2; continue }
          if (c == "\"") { sp++; mode[sp] = 1; if (sp == 1) buffer = ""; i++; continue }
          if (c == "<" && d == "<") {
            rest = substr(line, i + 2)
            if (rest ~ /^-?[A-Za-z_][A-Za-z0-9_-]*[ \t]*$/) {
              sub(/^-/, "", rest)
              sub(/[ \t]+$/, "", rest)
              heredoc = rest
              if (sp == 0) token("other")
              break
            }
          }
          if (mode[sp] == 2) {
            if (c == "{") braces[sp]++
            if (c == "}") { braces[sp]--; if (braces[sp] == 0) sp-- }
            i++
            continue
          }
          if (c ~ /[A-Za-z0-9_.-]/) {
            j = i + 1
            while (j <= n && substr(line, j, 1) ~ /[A-Za-z0-9_.-]/) j++
            token("word", substr(line, i, j - i))
            i = j
            continue
          }
          if (((c == "=" || c == "!" || c == "<" || c == ">") && d == "=") || (c == "=" && d == ">")) {
            token("other")
            i += 2
            continue
          }
          if (c == "{" || c == "}" || c == "=") token(c)
          else if (c == "(" || c == "[") { paren++; token("other") }
          else if (c == ")" || c == "]") { if (paren > 0) paren--; token("other") }
          else if (c != " " && c != "\t") token("other")
          i++
        }
        if (heredoc == "" && sp == 0 && !in_comment) token("newline")
      }

      END {
        if (in_run) close_run()
        if (!mocked) for (k = 1; k <= found; k++) print finding[k]
      }
    ' < "${terra_test_file}" || printf '%s: could not be read\n' "${terra_test_file}"
  done
  for terra_test_file in "$1"/*.tftest.json "$1"/tests/*.tftest.json; do
    [ -f "${terra_test_file}" ] || continue
    printf '%s: a JSON test file, which this check cannot read; write it as .tftest.hcl\n' "${terra_test_file}"
  done
  return 0
}
