#!/usr/bin/env python3
"""Emit a SonarQube *generic coverage* report for a Terraform module tree.

WHY THIS EXISTS ALONGSIDE `terra-coverage.xml`

The sibling `run.sh` already writes a Cobertura file, but its entire coverage
logic is one `printf`: a module scores `hits="1"` when it has a `tests/`
directory at all. That answers "which modules have a test file", which is a
breadth signal, not coverage -- every block of a 40-block module counts as
covered because one smoke test exists next to it.

This tool answers the narrower, honest question instead: *which declared
blocks are reachable from an assertion that `terraform test` actually ran?*
It writes a second, separate report; `terra-coverage.xml` stays byte
compatible.

WHY STATIC PARSING, NOT `terraform test -json`

Investigated and settled: `terraform test -json` does not report which
assertions ran or what they evaluated. A passing run emits only
`test_run {path, run, progress, status}`; only a FAILING run carries
`diagnostic.snippet.values[].traversal`. So a green suite -- the normal case
-- yields no runtime signal at all. `-verbose` does not help either: it emits
`test_plan`, the plan JSON, and plan presence must never count as coverage
because every module that compiles appears in the plan. That is exactly the
defect this tool exists to undo. The measurement therefore comes from reading
the HCL.

THE MEASUREMENT

    Denominator D  every top level `resource` / `data` / `module` / `output` /
                   `check` block under each module (test code excluded).
    Seeds S        the addresses that EXECUTED assertions name: assert
                   conditions and `expect_failures` entries in
                   `tests/*.tftest.hcl` (the same non-recursive glob `run.sh`
                   selects on), the module's own `check` blocks,
                   and `lifecycle { pre|postcondition }` guards.
    Graph R        `local.x`, `output.x` and `var.x` are indirections, not
                   destinations: each expands to the traversals of its value
                   (or, for a variable, of its `validation` conditions).
    Covered C      transitive closure of S over R, intersected with D.

`check` is in the denominator because it is a behavioural guard that is
genuinely either exercised or not. `variable`, `locals`, `terraform`,
`provider`, `moved`, `import` and `removed` are not: they declare, they do not
behave.

CAVEAT, STATED NOT HIDDEN

Granularity is the BLOCK, not the line. A 220 line resource counts as covered
off a single attribute assertion. That is inherent to measuring Terraform this
way and is not fixable here, so it is spelled out in the XML header and on
stdout rather than disguised behind a line count that would look more precise
than it is.

Usage:
    terra_coverage.py [--repo-dir DIR] [--output FILE] [--quiet]

Exit status is 0 on every normal outcome, including "nothing to measure" --
this is a reporting tier, it must never break a build. Only an internal error
exits non-zero. Stdlib only, so it runs on a bare CI agent with nothing but
`python3`, matching the sibling `tftest-gen`, `order-check` and `var-catalog`.
"""

from __future__ import annotations

import argparse
import bisect
import re
import sys
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

DEFAULT_OUTPUT = "build/reports/terra-coverage-generic.xml"

# Vendored/derived trees. Excluded EVERYWHERE -- the file walk and module
# discovery alike -- and at ANY depth, because they are copies of modules that
# already live in the source tree: counting them inflates the denominator AND
# duplicates the successes, which once made one module appear six times at
# 100%. Measured on the reference repos, `.terraform` copies were 62 of 98
# `.tf` files in one and 122 of 443 in the other.
VENDORED_DIRS = {".terraform", ".terragrunt-cache", ".external_modules", ".git"}

# Pruned from the FILE WALK only. An `examples/` tree is example USAGE of a
# module, not module code. In the root layout -- the common published module
# layout, where the repository itself IS the module -- it would otherwise land
# in the denominator and deflate every module that ships examples. It is
# deliberately NOT excluded from module discovery: a module legitimately named
# `modules/examples/` is a module, and silently skipping it would be the same
# invisibility bug the root-layout case exists to fix.
PRUNED_DIRS = VENDORED_DIRS | {"examples"}

# Blocks that BEHAVE at apply time, so "was it exercised?" is a real question.
DENOM_KINDS = {"resource", "data", "module", "output", "check"}

# Nodes that merely forward a reference. Only these expand during the closure;
# a resource/data/module/check address is terminal, so the closure never walks
# a whole dependency chain and call it coverage.
LOCAL_PREFIX = "local."
EXPANDING_PREFIXES = (LOCAL_PREFIX, "output.", "var.")

# Prefixes that are never a resource type. All are underscore free, so the
# `rtype` branch of TRAVERSAL_RE cannot match them anyway -- the set is kept
# as an explicit guard so a future loosening of that branch stays correct.
RESERVED_PREFIXES = {
    "each", "count", "self", "path", "terraform", "local", "var",
    "module", "data", "output", "check", "run", "provider",
}

# `<kind> ["label" ...] {`. Matched against the ORIGINAL source (the mask below
# blanks string contents, which would eat the labels); the caller verifies the
# `{` is a real one by checking the same offset in the masked text.
HEADER_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_-]*)((?:[ \t]+"[^"\n]*")*)[ \t]*\{')
LABEL_RE = re.compile(r'"([^"\n]*)"')
# `name =`, excluding `==`, `=>` and `=~`.
ATTR_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_-]*)[ \t]*=(?![=~>])[ \t]*")
HEREDOC_RE = re.compile(r"<<-?([A-Za-z_]\w*)[ \t]*\r?\n", re.ASCII)

# Traversal forms, in the precedence the spec fixes. The leading lookbehind
# stops a match in the middle of a longer chain, so `data.aws_ami.this` yields
# `data.aws_ami.this` and not also `aws_ami.this`. Each name part stops at the
# first non-identifier character, so `aws_rds_cluster_instance.main[0].id`
# yields `aws_rds_cluster_instance.main`.
TRAVERSAL_RE = re.compile(
    r"(?<![\w.])"
    r"(?:"
    r"local\.(?P<local>[A-Za-z_][A-Za-z0-9_-]*)"
    r"|var\.(?P<var>[A-Za-z_][A-Za-z0-9_-]*)"
    r"|data\.(?P<dtype>[A-Za-z_][A-Za-z0-9_-]*)\.(?P<dname>[A-Za-z_][A-Za-z0-9_-]*)"
    r"|module\.(?P<mod>[A-Za-z_][A-Za-z0-9_-]*)"
    r"|check\.(?P<chk>[A-Za-z_][A-Za-z0-9_-]*)"
    r"|output\.(?P<out>[A-Za-z_][A-Za-z0-9_-]*)"
    # A bare resource type: lowercase, at least one underscore (`aws_s3_bucket`,
    # `null_resource`). The underscore requirement is what keeps `each.value`,
    # `self.id` and `p.name` out.
    r"|(?P<rtype>[a-z][a-z0-9]*(?:_[a-z0-9]+)+)\.(?P<rname>[A-Za-z_][A-Za-z0-9_-]*)"
    r")"
)


# --------------------------------------------------------------------------- #
# Masking: one comment- and string-aware pass, offsets preserved
# --------------------------------------------------------------------------- #
# Everything downstream reads the MASKED text. That is the load-bearing part of
# this tool, and the sibling `var-catalog` learned it the expensive way: a naive
# scan treats the `//` in `"https://api.example/${var.env}"` as a comment start
# and loses the interpolation after it, while a comment that merely MENTIONS
# `aws_s3_bucket.foo` invents a reference that does not exist. Masking is done
# in place, character for character, so every offset in the masked text is the
# same offset in the original and line numbers need no translation.


def _mask_literal(out: list[str], text: str, a: int, b: int) -> None:
    """Blank a string/heredoc body in `[a, b)` but KEEP `${...}` interpolations.

    A traversal inside an interpolation is a real reference; the surrounding
    literal text is not. The `${` and its matching `}` are blanked so the
    interpolation cannot change brace depth for the block scanner.
    """
    k = a
    while k < b:
        if text.startswith("${", k) or text.startswith("%{", k):
            close = _match_brace(text, k + 1, b)
            out[k] = " "
            out[k + 1] = " "
            if close < b:
                out[close] = " "
                k = close + 1
                continue
            # Unterminated interpolation: leave the remainder as code rather
            # than silently swallowing it.
            return
        if text[k] != "\n":
            out[k] = " "
        k += 1


def _blank(out: list[str], lo: int, hi: int, keep_newlines: bool = True) -> None:
    """Blank `[lo, hi)` to spaces, leaving newlines so offsets keep their line."""
    for k in range(lo, hi):
        if not keep_newlines or out[k] != "\n":
            out[k] = " "


def _mask_line_comment(out: list[str], text: str, i: int, n: int) -> int:
    """`#` or `//` to the end of the line."""
    j = text.find("\n", i)
    j = n if j < 0 else j
    _blank(out, i, j, keep_newlines=False)
    return j


def _mask_block_comment(out: list[str], text: str, i: int, n: int) -> int:
    """`/* ... */`, which may span lines."""
    j = text.find("*/", i + 2)
    j = n if j < 0 else j + 2
    _blank(out, i, j)
    return j


def _heredoc_terminator(text: str, tag: str, body: int, n: int) -> tuple[int, int]:
    """Where the terminator line starts and ends, or `(n, n)` if unterminated.

    The terminator is the first line whose content is exactly the tag;
    everything between is body, not code.
    """
    pos = body
    while pos < n:
        eol = text.find("\n", pos)
        line_end = n if eol < 0 else eol
        if text[pos:line_end].strip() == tag:
            return pos, line_end
        pos = n if eol < 0 else eol + 1
    return n, n


def _mask_heredoc(out: list[str], text: str, i: int, n: int, hd: re.Match[str]) -> int:
    """`<<TAG ... TAG`, keeping the interpolations inside the body."""
    body = hd.end()
    term_start, term_end = _heredoc_terminator(text, hd.group(1), body, n)

    _blank(out, i, body)  # the `<<-TAG` marker itself
    _mask_literal(out, text, body, term_start)
    _blank(out, term_start, term_end, keep_newlines=False)  # the terminator line

    # Stand the marker and terminator in as a bracket pair. A heredoc is ONE
    # attribute value spanning many lines, and the expression scanner stops at
    # the first newline seen at depth 0 -- without this, `policy = <<-EOT ...
    # EOT` would read as an empty value and every reference interpolated in the
    # body would be lost. Brackets are invisible to the block scanner, which
    # counts only braces.
    out[i] = "("
    if term_end > term_start:
        out[term_end - 1] = ")"
    return term_end


def _string_end(text: str, i: int, n: int) -> int:
    """Index of the quote closing the literal opened at `i`, or the line end.

    A quote inside an open `${...}` does NOT end the literal: HCL
    interpolations routinely carry their own strings, and
    `"${join(",", [aws_s3_bucket.b.id])}"` is the common shape. Ending at the
    first `"` would close the literal on the separator, blank the rest as
    literal text, and lose every reference after it -- the block would read as
    uncovered on the strength of its punctuation. So track interpolation depth
    and only an unnested quote terminates.

    KNOWN LIMITS, both of which over-credit rather than under-credit, and both
    rare enough not to warrant a real HCL parser here: a string nested inside
    the interpolation is kept as code rather than re-masked, so
    `"${lookup(m, "aws_s3_bucket.foo")}"` yields a reference that is really a
    lookup key, and a `}` inside such a nested string unbalances the counter;
    and `$${`, the escape for a literal `${`, is read as opening an
    interpolation.
    """
    j = i + 1
    interpolation = 0
    while j < n:
        if text[j] == "\\":
            j += 2
            continue
        if text[j] == "\n":
            break
        if text[j] in "$%" and j + 1 < n and text[j + 1] == "{":
            interpolation += 1
            j += 2
            continue
        if interpolation > 0:
            # Braces of any kind nest, so an object literal inside the
            # interpolation cannot close it early.
            if text[j] == "{":
                interpolation += 1
            elif text[j] == "}":
                interpolation -= 1
            j += 1
            continue
        if text[j] == '"':
            break
        j += 1
    return j


def mask(text: str) -> str:
    """Return `text` with comments and literal string bodies blanked to spaces.

    Same length, same newlines, so `offset -> line` is unchanged. Handles `#`
    and `//` line comments, `/* */` blocks, `"..."` with backslash escapes, and
    `<<EOT` / `<<-EOT` heredocs whose terminator sits on a line of its own.
    """
    out = list(text)
    n = len(text)
    i = 0
    while i < n:
        ch = text[i]
        if ch == "#" or text.startswith("//", i):
            i = _mask_line_comment(out, text, i, n)
            continue
        if text.startswith("/*", i):
            i = _mask_block_comment(out, text, i, n)
            continue
        hd = HEREDOC_RE.match(text, i) if ch == "<" else None
        if hd:
            i = _mask_heredoc(out, text, i, n, hd)
            continue
        if ch == '"':
            j = _string_end(text, i, n)
            _mask_literal(out, text, i + 1, min(j, n))
            i = min(j + 1, n)
            continue
        i += 1
    return "".join(out)


def _match_brace(text: str, open_idx: int, hi: int) -> int:
    """Index of the `}` matching the `{` at `open_idx`, or `hi - 1` if absent."""
    depth = 0
    for k in range(open_idx, hi):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                return k
    return hi - 1


# --------------------------------------------------------------------------- #
# Block / attribute walking
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Block:
    kind: str
    labels: tuple[str, ...]
    start: int
    open_idx: int
    close_idx: int


def iter_blocks(masked: str, original: str, lo: int, hi: int) -> Iterator[Block]:
    """Yield the blocks declared DIRECTLY in `[lo, hi)`, skipping their bodies."""
    i = lo
    while i < hi:
        ch = masked[i]
        if ch == "{":
            i = _match_brace(masked, i, hi) + 1
            continue
        if ch.isalpha() or ch == "_":
            m = HEADER_RE.match(original, i)
            if m and m.end() <= hi and masked[m.end() - 1] == "{":
                close = _match_brace(masked, m.end() - 1, hi)
                yield Block(
                    m.group(1),
                    tuple(LABEL_RE.findall(m.group(2))),
                    i,
                    m.end() - 1,
                    close,
                )
                i = close + 1
                continue
            while i < hi and (masked[i].isalnum() or masked[i] in "_-"):
                i += 1
            continue
        i += 1


def iter_blocks_deep(
    masked: str, original: str, lo: int, hi: int
) -> Iterator[Block]:
    for blk in iter_blocks(masked, original, lo, hi):
        yield blk
        yield from iter_blocks_deep(masked, original, blk.open_idx + 1, blk.close_idx)


def _expr_end(masked: str, start: int, hi: int) -> int:
    """End of a balanced expression starting at `start`.

    Aware of `()`, `[]` and `{}`; strings and comments are already neutralised
    by `mask`, and `${...}` bodies carry no unbalanced delimiter. Stops at the
    first newline seen at depth 0, which is where an HCL attribute ends.

    This is the fix for the truncation defect: a non greedy `assert { ... }`
    regex stops at the first nested `}` and loses every reference after it --
    and real conditions are full of `[for p in x.y : p if ...]`.
    """
    depth = 0
    i = start
    while i < hi:
        ch = masked[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif ch == "\n" and depth == 0:
            break
        i += 1
    return i


def _attr_at(
    masked: str, original: str, i: int, hi: int
) -> tuple[tuple[str, int, int] | None, int]:
    """The attribute starting at `i`, if it is one, and where to resume.

    Three things start with an identifier and only one of them is an attribute:
    a nested block header, which is skipped whole; a `name =` attribute, which
    is the hit; and a bare word, which is stepped over. Returning the next
    index with the result keeps that decision in one place -- `iter_attrs` is a
    generator, so it cannot delegate by calling and returning.
    """
    blk = HEADER_RE.match(original, i)
    if blk and blk.end() <= hi and masked[blk.end() - 1] == "{":
        return None, _match_brace(masked, blk.end() - 1, hi) + 1

    am = ATTR_RE.match(masked, i)
    if am:
        end = _expr_end(masked, am.end(), hi)
        return (am.group(1), am.end(), end), max(end, am.end() + 1)

    # A bare word: step past it, never standing still.
    j = i
    while j < hi and (masked[j].isalnum() or masked[j] in "_-"):
        j += 1
    return None, j


def iter_attrs(
    masked: str, original: str, lo: int, hi: int
) -> Iterator[tuple[str, int, int]]:
    """Yield `(name, expr_start, expr_end)` for attributes DIRECTLY in `[lo, hi)`."""
    i = lo
    while i < hi:
        ch = masked[i]
        if ch == "{":
            i = _match_brace(masked, i, hi) + 1
            continue
        if ch.isalpha() or ch == "_":
            attr, i = _attr_at(masked, original, i, hi)
            if attr is not None:
                yield attr
            continue
        i += 1


def iter_attrs_deep(
    masked: str, original: str, lo: int, hi: int
) -> Iterator[tuple[str, int, int]]:
    yield from iter_attrs(masked, original, lo, hi)
    for blk in iter_blocks(masked, original, lo, hi):
        yield from iter_attrs_deep(masked, original, blk.open_idx + 1, blk.close_idx)


def attr_expr(masked: str, original: str, lo: int, hi: int, name: str) -> str | None:
    for found, a, b in iter_attrs(masked, original, lo, hi):
        if found == name:
            return masked[a:b]
    return None


def traversals(expr: str | None) -> set[str]:
    """Addresses referenced by an expression (already masked)."""
    if not expr:
        return set()
    found: set[str] = set()
    for m in TRAVERSAL_RE.finditer(expr):
        if m.group("local"):
            found.add(LOCAL_PREFIX + m.group("local"))
        elif m.group("var"):
            found.add("var." + m.group("var"))
        elif m.group("dtype"):
            found.add(f"data.{m.group('dtype')}.{m.group('dname')}")
        elif m.group("mod"):
            found.add("module." + m.group("mod"))
        elif m.group("chk"):
            found.add("check." + m.group("chk"))
        elif m.group("out"):
            found.add("output." + m.group("out"))
        elif m.group("rtype") and m.group("rtype") not in RESERVED_PREFIXES:
            found.add(f"{m.group('rtype')}.{m.group('rname')}")
    return found


# The namespace of a file declared directly in the module root, and the one a
# `tests/*.tftest.hcl` resolves against: `terraform test` evaluates a test
# against the module root directory, not against the `tests/` directory itself.
ROOT_NS = "."


def qualify(address: str, namespace: str) -> str:
    """Scope an address to the directory that declared it.

    An HCL address is only unique within one directory: two nested submodules
    may each declare `aws_s3_bucket.this`, and while addresses were global to
    the whole module scan they shared one coverage entry, so an assertion on one
    marked the other covered. `namespace` is the declaring directory relative to
    the module root, so blocks in different directories can never collide, while
    a single-directory module is unaffected (every address gets the same `@.`).
    `@` cannot appear in an HCL identifier, and the address stays in FRONT so
    `EXPANDING_PREFIXES` still matches a qualified node.
    """
    return f"{address}@{namespace}"


def qualify_all(addresses: set[str], namespace: str) -> set[str]:
    return {qualify(address, namespace) for address in addresses}


def block_address(blk: Block) -> str | None:
    if blk.kind == "resource" and len(blk.labels) >= 2:
        return f"{blk.labels[0]}.{blk.labels[1]}"
    if blk.kind == "data" and len(blk.labels) >= 2:
        return f"data.{blk.labels[0]}.{blk.labels[1]}"
    if blk.kind in ("module", "output", "check") and blk.labels:
        return f"{blk.kind}.{blk.labels[0]}"
    return None


# --------------------------------------------------------------------------- #
# Scanning a module
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Declared:
    path: str  # relative to --repo-dir, forward slashes
    line: int  # 1-based declaration line
    address: str


@dataclass
class ModuleScan:
    declared: list[Declared] = field(default_factory=list)
    graph: dict[str, set[str]] = field(default_factory=dict)
    seeds: set[str] = field(default_factory=set)


def line_of(line_starts: list[int], offset: int) -> int:
    return bisect.bisect_right(line_starts, offset)


def line_index(text: str) -> list[int]:
    starts = [0]
    for m in re.finditer("\n", text):
        starts.append(m.end())
    return starts


def _entries(path: Path) -> list[Path]:
    """Directory contents, sorted; empty for one that cannot be listed."""
    try:
        return sorted(path.iterdir())
    except OSError:
        return []


def _is_pruned(entry: Path, skip_tests: bool) -> bool:
    """A directory the walk never descends into."""
    return entry.name in PRUNED_DIRS or (skip_tests and entry.name == "tests")


def walk_files(root: Path, pattern: str, skip_tests: bool) -> Iterator[Path]:
    """Yield files matching `pattern`, pruning vendored dirs (and `tests/`)."""
    stack = [root]
    while stack:
        for entry in _entries(stack.pop()):
            if entry.is_symlink():
                continue
            if entry.is_dir():
                if not _is_pruned(entry, skip_tests):
                    stack.append(entry)
            elif entry.name.endswith(pattern):
                yield entry


def add_edge(graph: dict[str, set[str]], node: str, targets: set[str]) -> None:
    if targets:
        graph.setdefault(node, set()).update(targets)


def _read_text(path: Path) -> str | None:
    """File contents, or None after warning. Unreadable is never a failure."""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"warning: cannot read {path}: {exc}", file=sys.stderr)
        return None


def _condition_refs(masked: str, original: str, blk: Block, ns: str) -> set[str]:
    """Addresses the `condition` of a guard block names, already qualified.

    `assert`, `precondition` and `postcondition` are three spellings of the
    same thing to this tool: a boolean the test run really evaluates, whose
    traversals are therefore exercised.
    """
    return qualify_all(
        traversals(attr_expr(masked, original, blk.open_idx + 1, blk.close_idx, "condition")),
        ns,
    )


def _guard_seeds(
    scan: ModuleScan, masked: str, original: str, body_span: tuple[int, int],
    qaddress: str, ns: str, kinds: tuple[str, ...],
) -> None:
    """Seed the block and everything its guards name, for the guard kinds given."""
    for sub in iter_blocks_deep(masked, original, *body_span):
        if sub.kind in kinds:
            scan.seeds.add(qaddress)
            scan.seeds |= _condition_refs(masked, original, sub, ns)


def _scan_declarations(
    scan: ModuleScan, masked: str, original: str, starts: list[int],
    rel: str, ns: str, has_tests: bool,
) -> None:
    """Record every declared block in one file, and the edges out of it."""
    for blk in iter_blocks(masked, original, 0, len(masked)):
        address = block_address(blk)
        body_span = (blk.open_idx + 1, blk.close_idx)

        if blk.kind == "locals":
            for name, a, b in iter_attrs(masked, original, *body_span):
                add_edge(scan.graph, qualify(LOCAL_PREFIX + name, ns),
                         qualify_all(traversals(masked[a:b]), ns))
            continue

        if blk.kind == "variable" and blk.labels:
            refs: set[str] = set()
            for sub in iter_blocks_deep(masked, original, *body_span):
                if sub.kind == "validation":
                    refs |= _condition_refs(masked, original, sub, ns)
            add_edge(scan.graph, qualify("var." + blk.labels[0], ns), refs)
            continue

        if address is None or blk.kind not in DENOM_KINDS:
            continue

        qaddress = qualify(address, ns)
        scan.declared.append(Declared(rel, line_of(starts, blk.start), qaddress))

        if blk.kind == "output":
            add_edge(scan.graph, qaddress, qualify_all(
                traversals(attr_expr(masked, original, *body_span, "value")), ns))

        if not has_tests:
            continue

        # `check "X" { assert { condition } }` -- a behavioural guard that
        # `terraform test` really evaluates. The check itself is exercised,
        # and so is everything its condition names.
        if blk.kind == "check":
            scan.seeds.add(qaddress)
            _guard_seeds(scan, masked, original, body_span, qaddress, ns, ("assert",))

        # `lifecycle { pre|postcondition { condition } }` -- the guard runs
        # as part of the containing block, so the block is exercised.
        _guard_seeds(scan, masked, original, body_span, qaddress, ns,
                     ("precondition", "postcondition"))


def _scan_test_file(scan: ModuleScan, masked: str, original: str) -> None:
    """Seeds a single `*.tftest.hcl` contributes."""
    for blk in iter_blocks_deep(masked, original, 0, len(masked)):
        if blk.kind == "assert":
            scan.seeds |= _condition_refs(masked, original, blk, ROOT_NS)

    for name, a, b in iter_attrs_deep(masked, original, 0, len(masked)):
        if name != "expect_failures":
            continue
        # The entries ARE addresses, taken as written -- `expect_failures`
        # is how a test asserts a guard fires, and dropping it discarded
        # real behavioural tests.
        for entry in re.split(r"[,\n]", masked[a:b].strip().strip("[]")):
            entry = entry.strip().strip("[],")
            if entry:
                scan.seeds.add(qualify(entry, ROOT_NS))


def scan_module(module_dir: Path, repo_dir: Path) -> ModuleScan:
    scan = ModuleScan()

    test_files = sorted(
        path for path in (module_dir / "tests").glob("*.tftest.hcl")
        if path.is_file() and not path.is_symlink()
    )
    has_tests = bool(test_files)

    for tf in sorted(walk_files(module_dir, ".tf", skip_tests=True)):
        original = _read_text(tf)
        if original is None:
            continue
        masked = mask(original)
        _scan_declarations(
            scan, masked, original, line_index(original),
            tf.relative_to(repo_dir).as_posix(),
            tf.parent.relative_to(module_dir).as_posix(),
            has_tests,
        )

    for tft in test_files:
        original = _read_text(tft)
        if original is None:
            continue
        _scan_test_file(scan, mask(original), original)

    return scan


def closure(seeds: set[str], graph: dict[str, set[str]]) -> set[str]:
    """Transitive closure of `seeds` over `graph`, cycle safe.

    Only `local.*`, `output.*` and `var.*` nodes have outgoing edges, so a
    resource address is terminal and the walk cannot drag in a whole dependency
    chain and call it covered.
    """
    seen: set[str] = set()
    stack = list(seeds)
    while stack:
        node = stack.pop()
        if node in seen:
            continue
        seen.add(node)
        if node.startswith(EXPANDING_PREFIXES):
            stack.extend(graph.get(node, ()))
    return seen


# --------------------------------------------------------------------------- #
# Discovery and rendering
# --------------------------------------------------------------------------- #


def discover_modules(repo_dir: Path) -> list[Path]:
    """Module directories, handling BOTH repository layouts.

    `modules/<name>/` is the monorepo layout. When there is no such tree but
    the repo root itself holds `*.tf`, the repo IS the module -- that is the
    `terraform-modules` layout where every module is its own Azure DevOps
    repository (see `tftest-gen/gen_smoke_tests.py`). Missing that case scored
    a whole published module `0/0` instead of measuring it.
    """
    modules_root = repo_dir / "modules"
    if modules_root.is_dir():
        found = sorted(
            d for d in modules_root.iterdir()
            if d.is_dir() and not d.is_symlink() and d.name not in VENDORED_DIRS
        )
        if found:
            return found
    if any(repo_dir.glob("*.tf")):
        return [repo_dir]
    return []


XML_HEADER_COMMENT = """<!--
  Generated by global/scripts/languages/terraform/terra-test/terra_coverage.py
  in SonarQube's generic coverage format.

  One lineToCover per top level BLOCK (resource, data, module, output, check),
  placed on the block's declaration line. covered="true" means the block is
  reachable from an assertion `terraform test` actually executes: an assert
  condition or an expect_failures entry in tests/*.tftest.hcl, the module's
  own check blocks, or a lifecycle precondition/postcondition, followed through
  local, output and variable validation expressions.

  CAVEAT, BLOCK GRANULARITY: the unit of measurement is the block, not the
  line. A 220 line resource counts as covered off a single attribute
  assertion, so this report says which blocks are exercised at all, never how
  much of each block is exercised. Stated here on purpose instead of being
  hidden behind a line count that would look more precise than it is.
-->"""


def render(covered_lines: dict[str, dict[int, bool]]) -> str:
    out = ['<?xml version="1.0" encoding="UTF-8"?>', XML_HEADER_COMMENT]
    if not covered_lines:
        out.append('<coverage version="1"/>')
        return "\n".join(out) + "\n"
    out.append('<coverage version="1">')
    for path in sorted(covered_lines):
        out.append(f'  <file path="{xml_escape(path)}">')
        for line in sorted(covered_lines[path]):
            flag = "true" if covered_lines[path][line] else "false"
            out.append(f'    <lineToCover lineNumber="{line}" covered="{flag}"/>')
        out.append("  </file>")
    out.append("</coverage>")
    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-dir", default=".", help="Repository root (default: cwd)")
    parser.add_argument("--output", default=DEFAULT_OUTPUT,
                        help=f"Report path (default: {DEFAULT_OUTPUT})")
    parser.add_argument("--quiet", action="store_true", help="Suppress the summary lines")
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).resolve()

    # `--output` is confined to the repository being measured. The report
    # describes that tree, every caller writes it under `build/reports/` there,
    # and nothing has a use for writing it anywhere else -- so the safe
    # contract and the real one are the same contract.
    #
    # Without this, `--output ../../x` both writes through the repository root
    # and creates the directories on the way (`mkdir(parents=True)` below),
    # which is a path traversal for any caller that does not choose its own
    # arguments: a workflow interpolating a variable, or an agent driving this
    # as a tool. SonarQube pythonsecurity:S8707.
    requested = Path(args.output)
    output = (requested if requested.is_absolute() else repo_dir / requested).resolve()
    if not output.is_relative_to(repo_dir):
        print(
            f"terra generic coverage: --output must stay inside {repo_dir}, "
            f"got {output}",
            file=sys.stderr,
        )
        return 2

    # path -> line -> covered. Two blocks declared on one line (legal, rare)
    # collapse to one entry; covered wins, because the line IS exercised.
    lines: dict[str, dict[int, bool]] = {}
    total = 0
    covered = 0

    for module_dir in discover_modules(repo_dir):
        scan = scan_module(module_dir, repo_dir)
        reachable = closure(scan.seeds, scan.graph)
        for decl in scan.declared:
            total += 1
            is_covered = decl.address in reachable
            covered += 1 if is_covered else 0
            bucket = lines.setdefault(decl.path, {})
            bucket[decl.line] = bucket.get(decl.line, False) or is_covered

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(lines), encoding="utf-8")

    if not args.quiet:
        pct = (covered * 100 // total) if total else 0
        print(f"terra generic coverage: {covered}/{total} blocks ({pct}%) -> {output}")
        print("terra generic coverage: granularity is per BLOCK, not per line -- a "
              "220-line resource counts as covered off a single attribute assertion, "
              "so this is breadth of exercise, not depth.")
        if total == 0:
            print("terra generic coverage: nothing to measure (no module "
                  "directories with .tf files found); wrote an empty report.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
