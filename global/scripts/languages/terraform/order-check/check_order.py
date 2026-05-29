#!/usr/bin/env python3
"""Check (and optionally auto-fix) the Terragrunt file-ordering standard.

The team orders the dense `variables.tf` / `providers.tf` / `outputs.tf` /
`*.hcl` files of its Terragrunt monorepos (numbered dependency layers under
`environments/`, root modules under `stacks/`, leaf modules under `modules/`)
by a consistent convention. This tool encodes that convention as a CI gate
plus an idempotent formatter:

    A. environments/**/root.hcl  -- `dependency` blocks ascending by the
       `environments/NN_` number in each `config_path`.
    B. environments/**/root.hcl  -- the `inputs = {}` block groups
       `dependency.<name>.outputs.*` assignments by dependency, groups
       ascending by dependency number (locals/tags first, literals last).
    C. stacks/*/variables.tf     -- a `// SET ON .HCL` section before a
       `// SET ON .ENV` section; within `.HCL`, variables ordered by the
       dependency number they are fed from (derived from root.hcl inputs).
    D. **/providers.tf           -- `required_providers` entries and the
       top-level `provider` blocks ordered heaviest -> lightest by a
       built-in weight ranking (overridable via `.terraform-order.json`).
    E. stacks/*/outputs.tf       -- outputs ordered to follow the
       declaration position of the first module/resource their value
       references in `main*.tf`.

Usage:
    check_order.py [--fix] [--repo-dir DIR] [--config FILE] [--report DIR]

Exit status is 0 when no ordering errors remain (after `--fix` rewrites, if
requested) and 1 otherwise. The tool is stdlib-only so it runs on a bare CI
runner with nothing but `python3` -- matching the sibling `tftest-gen`.

Safety of `--fix`: every rewrite first parses the target region into a list
of *exact* substrings and verifies the concatenation reproduces the original
byte-for-byte (a round-trip). Only then are those substrings *permuted*. A
region that does not round-trip is left untouched and reported, so the
formatter can never drop, duplicate, or corrupt content.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

# --------------------------------------------------------------------------- #
# Provider weight ranking (heaviest/first -> lightest/last)
# --------------------------------------------------------------------------- #
# Derived from the observed convention across the reference repos and extended
# with the common HashiCorp/community providers. Teams override per-repo via
# `.terraform-order.json` -> {"provider_order": [...]}. Providers absent from
# the ranking are "unknown": the checker never flags an unknown provider as
# out of order (it has no defined weight) and the fixer refuses to reorder a
# block containing one -- both report it so the team can rank it explicitly.
DEFAULT_PROVIDER_ORDER: list[str] = [
    # cloud platforms (broadest blast radius)
    "azuread", "azurerm", "azapi", "aws", "google", "google-beta", "alicloud",
    "oci", "ibm",
    # data planes
    "opensearch", "elasticsearch", "elasticstack", "postgresql", "mysql",
    "mongodbatlas", "snowflake",
    # cluster orchestration
    "helm", "kubernetes", "kubectl", "docker",
    # network / DNS / PKI
    "tls", "cloudflare", "dns", "acme",
    # application / utility services
    "http-request", "vault", "onepassword", "keycloak", "external", "github",
    "gitlab", "datadog", "pagerduty", "grafana",
    # trivial / local-only helpers (lightest)
    "time", "tfe", "null", "http", "random", "local", "archive", "template",
]

SET_ON_HCL = "SET ON .HCL"
SET_ON_ENV = "SET ON .ENV"
NO_NUMBER = 9_999  # sentinel: sorts unmapped entries to the end of their group


# --------------------------------------------------------------------------- #
# Findings & reporting
# --------------------------------------------------------------------------- #
@dataclass
class Finding:
    rule: str          # short rule id, e.g. "providers"
    path: str          # repo-relative file path
    message: str       # human-readable description
    severity: str = "error"  # "error" fails CI; "warning" is informational


@dataclass
class FileResult:
    path: str
    findings: list[Finding] = field(default_factory=list)
    fixed: bool = False


def rel(repo: Path, p: Path) -> str:
    try:
        return str(p.relative_to(repo))
    except ValueError:
        return str(p)


# All file I/O funnels through these two helpers. This is a file-formatting CLI
# (like `terraform fmt` / `black` / `isort`): it deliberately reads and, with
# `--fix`, rewrites the `.tf` / `.hcl` files under the directory the user points
# it at via `--repo-dir`. SonarCloud's S2083 ("path injection") fires on every
# read/write because the path derives from a CLI argument -- but for a tool whose
# whole purpose is to operate on a user-chosen directory there is no
# trusted-vs-untrusted path boundary to enforce, so the finding is a false
# positive (the sibling `tftest-gen` shares the same pattern). The `# NOSONAR`
# markers suppress it at these two sink lines with that rationale.
def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")  # NOSONAR


def write_text(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")  # NOSONAR


# --------------------------------------------------------------------------- #
# Brace/quote-aware scanning helpers (same approach as tftest-gen)
# --------------------------------------------------------------------------- #
def find_matching_brace(text: str, open_index: int) -> int:
    """Return the index of the `}` matching the `{` at ``open_index``.

    Respects double/single-quoted strings and ``#`` / ``//`` line comments so
    braces inside them are ignored. Raises ``ValueError`` when unbalanced.
    """
    depth = 0
    i, n = open_index, len(text)
    in_str, quote = False, ""
    in_line_comment = False
    while i < n:
        ch = text[i]
        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            i += 1
            continue
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                in_str = False
            i += 1
            continue
        if ch in ('"', "'"):
            in_str, quote = True, ch
        elif ch == "#":
            in_line_comment = True
        elif ch == "/" and i + 1 < n and text[i + 1] == "/":
            in_line_comment = True
            i += 2
            continue
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("unbalanced braces")


@dataclass
class Block:
    """A top-level HCL block captured as an exact substring of the file."""
    name: str           # primary label (e.g. variable/output/provider name)
    start: int          # offset of the keyword (column 0)
    end: int            # offset just past the closing brace's newline


def find_top_level_blocks(text: str, keyword: str) -> list[Block]:
    """Find column-0 ``keyword "<name>" { ... }`` blocks (fmt-canonical files).

    Used for `variable`, `output`, `provider`, and `dependency` blocks, all of
    which `terraform fmt` / `terragrunt hcl format` anchor at column 0.
    """
    blocks: list[Block] = []
    pattern = re.compile(r'(?m)^' + re.escape(keyword) + r'\s+"([^"]+)"[^\n{]*\{')
    for m in pattern.finditer(text):
        open_brace = text.index("{", m.start())
        close = find_matching_brace(text, open_brace)
        end = close + 1
        if end < len(text) and text[end] == "\n":
            end += 1
        blocks.append(Block(name=m.group(1), start=m.start(), end=end))
    return blocks


@dataclass
class Item:
    """A reorderable unit: leading trivia (comments/blanks) + its block text."""
    key: tuple          # sort key
    text: str           # exact substring (trivia + block), preserved verbatim
    name: str


def build_items(text: str, region_start: int, region_end: int,
                blocks: list[Block], key_of) -> tuple[list[Item], str] | None:
    """Slice ``text[region_start:region_end]`` into items + a trailing suffix.

    Each item owns the trivia between the previous block and itself, so blank
    lines and attached comments travel with their block when reordered. Returns
    ``None`` when the region does not round-trip exactly (then the caller must
    not rewrite the file).
    """
    in_region = [b for b in blocks if region_start <= b.start < region_end]
    if not in_region:
        return None
    items: list[Item] = []
    cursor = region_start
    for b in in_region:
        chunk = text[cursor:b.end]
        items.append(Item(key=key_of(b), text=chunk, name=b.name))
        cursor = b.end
    suffix = text[cursor:region_end]
    # round-trip guarantee
    if "".join(it.text for it in items) + suffix != text[region_start:region_end]:
        return None
    return items, suffix


def reorder_region(text: str, region_start: int, region_end: int,
                   items: list[Item], suffix: str) -> str:
    ordered = sorted(items, key=lambda it: it.key)  # stable
    new_region = "".join(it.text for it in ordered) + suffix
    return text[:region_start] + new_region + text[region_end:]


def reorder_pinned_region(text: str, region_start: int, region_end: int,
                          blocks: list[Block], movable, key_of) -> str | None:
    """Sort only the *movable* blocks into the slots they occupy; pin the rest.

    Non-movable blocks (e.g. `tags`/literal variables, un-ranked providers)
    keep their absolute position, while movable blocks are stable-sorted into
    the positions movable blocks already held. Returns ``None`` when the region
    does not round-trip exactly, so the caller leaves the file untouched.
    """
    in_region = [b for b in blocks if region_start <= b.start < region_end]
    if not in_region:
        return None
    items: list[Item] = []
    cursor = region_start
    for b in in_region:
        items.append(Item(key=key_of(b), text=text[cursor:b.end], name=b.name))
        cursor = b.end
    suffix = text[cursor:region_end]
    if "".join(it.text for it in items) + suffix != text[region_start:region_end]:
        return None
    movable_idx = [i for i, b in enumerate(in_region) if movable(b)]
    movable_sorted = sorted((items[i] for i in movable_idx), key=lambda it: it.key)
    new_items = list(items)
    for slot, it in zip(movable_idx, movable_sorted):
        new_items[slot] = it
    new_region = "".join(it.text for it in new_items) + suffix
    return text[:region_start] + new_region + text[region_end:]


def is_sorted(keys: list) -> bool:
    return all(keys[i] <= keys[i + 1] for i in range(len(keys) - 1))


# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
@dataclass
class Config:
    provider_weight: dict[str, int]
    ignore: list[str]

    @staticmethod
    def load(repo: Path, explicit: Path | None) -> "Config":
        order = DEFAULT_PROVIDER_ORDER
        ignore: list[str] = []
        cfg_path = explicit or (repo / ".terraform-order.json")
        if cfg_path.is_file():
            data = json.loads(read_text(cfg_path))
            order = data.get("provider_order", order)
            ignore = data.get("ignore", [])
        return Config(provider_weight={p: i for i, p in enumerate(order)},
                      ignore=ignore)

    def is_ignored(self, repo_rel: str) -> bool:
        from fnmatch import fnmatch
        return any(fnmatch(repo_rel, pat) for pat in self.ignore)


# --------------------------------------------------------------------------- #
# root.hcl parsing (rules A & B)
# --------------------------------------------------------------------------- #
RE_ENV_NUM = re.compile(r"environments/(\d+)_")
RE_SOURCE_STACK = re.compile(r'source\s*=\s*"[^"]*stacks/([^"/]+)"')
RE_DEP_REF = re.compile(r"dependency\.([A-Za-z0-9_]+)\.outputs")


@dataclass
class RootHcl:
    path: Path
    text: str
    dep_to_num: dict[str, int]            # dependency name -> env number
    dep_block_order: list[tuple[str, int]]  # (name, num) in file order
    stack_name: str | None
    var_to_num: dict[str, int]            # input variable -> source dep number
    inputs_ref_order: list[tuple[str, int]]  # (dep, num) of dependency refs


def parse_root_hcl(path: Path) -> RootHcl:
    text = read_text(path)
    blocks = find_top_level_blocks(text, "dependency")
    dep_to_num: dict[str, int] = {}
    dep_block_order: list[tuple[str, int]] = []
    for b in blocks:
        body = text[b.start:b.end]
        m = RE_ENV_NUM.search(body)
        num = int(m.group(1)) if m else NO_NUMBER
        dep_to_num[b.name] = num
        dep_block_order.append((b.name, num))

    stack_m = RE_SOURCE_STACK.search(text)
    stack_name = stack_m.group(1) if stack_m else None

    var_to_num: dict[str, int] = {}
    inputs_ref_order: list[tuple[str, int]] = []
    inputs_m = re.search(r"(?m)^inputs\s*=\s*\{", text)
    if inputs_m:
        open_brace = text.index("{", inputs_m.start())
        body = text[open_brace + 1:find_matching_brace(text, open_brace)]
        for line in body.splitlines():
            am = re.match(r"\s*([A-Za-z0-9_]+)\s*=\s*(.+)", line)
            if not am:
                continue
            ref = RE_DEP_REF.search(am.group(2))
            if ref:
                num = dep_to_num.get(ref.group(1), NO_NUMBER)
                var_to_num[am.group(1)] = num
                inputs_ref_order.append((ref.group(1), num))
    return RootHcl(path, text, dep_to_num, dep_block_order, stack_name,
                   var_to_num, inputs_ref_order)


def check_root_hcl(rh: RootHcl, repo: Path, fix: bool) -> FileResult:
    res = FileResult(path=rel(repo, rh.path))
    text = rh.text
    changed = False

    # Rule A: dependency block order
    nums = [n for _, n in rh.dep_block_order]
    if not is_sorted(nums):
        if fix:
            blocks = find_top_level_blocks(text, "dependency")
            region_start, region_end = blocks[0].start, blocks[-1].end
            built = build_items(text, region_start, region_end, blocks,
                                key_of=lambda b: (rh.dep_to_num.get(b.name, NO_NUMBER),))
            if built:
                items, suffix = built
                text = reorder_region(text, region_start, region_end, items, suffix)
                changed = True
            else:
                res.findings.append(Finding("root-hcl-deps", res.path,
                    "dependency blocks out of order and could not be safely auto-fixed"))
        else:
            order_str = ", ".join(f"{d}({n:02d})" for d, n in rh.dep_block_order)
            res.findings.append(Finding("root-hcl-deps", res.path,
                f"dependency blocks not ascending by environments/NN number: {order_str}"))

    # Rule B: inputs grouped by dependency number
    input_nums = [n for _, n in rh.inputs_ref_order]
    if not is_sorted(input_nums):
        if fix:
            text, fixed_inputs, ok = fix_inputs_block(text, rh.dep_to_num)
            if fixed_inputs:
                changed = True
            elif not ok:
                res.findings.append(Finding("root-hcl-inputs", res.path,
                    "inputs block out of order and could not be safely auto-fixed"))
        else:
            seq = ", ".join(f"{d}({n:02d})" for d, n in rh.inputs_ref_order)
            res.findings.append(Finding("root-hcl-inputs", res.path,
                f"inputs not grouped by ascending dependency number: {seq}"))

    if fix and changed:
        write_text(rh.path, text)
        res.fixed = True
    return res


def fix_inputs_block(text: str, dep_to_num: dict[str, int]) -> tuple[str, bool, bool]:
    """Reorder dependency-referencing assignments inside the `inputs = {}` block.

    Only the assignments whose value references a dependency are reordered;
    they are stable-sorted by dependency number and placed back into the very
    positions they occupied, so leading locals/tags and trailing literals stay
    pinned. Returns (new_text, changed, parsed_ok).
    """
    inputs_m = re.search(r"(?m)^inputs\s*=\s*\{", text)
    if not inputs_m:
        return text, False, True
    open_brace = text.index("{", inputs_m.start())
    close = find_matching_brace(text, open_brace)
    body = text[open_brace + 1:close]

    # Split body into entries: each entry owns the trivia before it + a
    # `key = <balanced value>`. Round-trip verified before any reordering.
    entries: list[dict] = []
    i, n = 0, len(body)
    cursor = 0
    line_start = True
    while i < n:
        m = re.compile(r"(?m)^([ \t]*)([A-Za-z0-9_]+)\s*=\s*").match(body, i) if line_start else None
        if m:
            value_start = m.end()
            j = find_value_end(body, value_start)
            entry_text = body[cursor:j]
            ref = RE_DEP_REF.search(body[value_start:j])
            num = dep_to_num.get(ref.group(1), NO_NUMBER) if ref else None
            entries.append({"text": entry_text, "num": num})
            cursor = j
            i = j
            line_start = j > 0 and body[j - 1] == "\n"
            continue
        line_start = body[i] == "\n"
        i += 1
    suffix = body[cursor:]
    if "".join(e["text"] for e in entries) + suffix != body:
        return text, False, False  # could not parse safely

    dep_positions = [idx for idx, e in enumerate(entries) if e["num"] is not None]
    dep_entries = [entries[idx] for idx in dep_positions]
    ordered_dep = sorted(enumerate(dep_entries), key=lambda t: (t[1]["num"], t[0]))
    new_entries = list(entries)
    for slot, (_, entry) in zip(dep_positions, ordered_dep):
        new_entries[slot] = entry
    new_body = "".join(e["text"] for e in new_entries) + suffix
    if new_body == body:
        return text, False, True
    new_text = text[:open_brace + 1] + new_body + text[close:]
    return new_text, True, True


def find_value_end(body: str, start: int) -> int:
    """Return the offset just past a HCL value beginning at ``start``.

    Handles single-line scalars and multi-line bracketed values
    (objects/lists). Consumes the trailing newline so each entry is a clean
    line-aligned slice.
    """
    depth = 0
    i, n = start, len(body)
    in_str, quote = False, ""
    while i < n:
        ch = body[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                in_str = False
            i += 1
            continue
        if ch in ('"', "'"):
            in_str, quote = True, ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "\n" and depth == 0:
            return i + 1
        i += 1
    return n


# --------------------------------------------------------------------------- #
# variables.tf parsing (rule C)
# --------------------------------------------------------------------------- #
def check_variables_tf(path: Path, repo: Path, var_to_num: dict[str, int],
                       fix: bool) -> FileResult:
    res = FileResult(path=rel(repo, path))
    text = read_text(path)

    hcl_m = re.search(r"(?im)^[ \t]*(?://|#)[ \t]*" + re.escape(SET_ON_HCL), text)
    env_m = re.search(r"(?im)^[ \t]*(?://|#)[ \t]*" + re.escape(SET_ON_ENV), text)

    if not hcl_m and not env_m:
        res.findings.append(Finding("variables-markers", res.path,
            "missing `// SET ON .HCL` / `// SET ON .ENV` section markers",
            severity="warning"))
        return res
    if hcl_m and env_m and env_m.start() < hcl_m.start():
        res.findings.append(Finding("variables-sections", res.path,
            "`// SET ON .ENV` section appears before `// SET ON .HCL`"))
        return res  # ordering inside flipped sections is not meaningful

    # The .HCL section spans from the .HCL marker to the .ENV marker (or EOF).
    hcl_start = hcl_m.end() if hcl_m else 0
    hcl_end = env_m.start() if env_m else len(text)
    blocks = find_top_level_blocks(text, "variable")
    hcl_blocks = [b for b in blocks if hcl_start <= b.start < hcl_end]

    # Only dependency-derived variables are constrained. `tags` (a `local`-
    # sourced input), static literals (e.g. image tags), and defaulted feature
    # flags are not fed by a numbered dependency, so they may sit anywhere in
    # the .HCL section -- matching the user's rule "variables from dependency 03
    # before variables from dependency 04".
    mapped_seq = [(b.name, var_to_num[b.name]) for b in hcl_blocks if b.name in var_to_num]
    if is_sorted([n for _, n in mapped_seq]):
        return res

    if fix:
        new_text = reorder_pinned_region(
            text, hcl_blocks[0].start, hcl_blocks[-1].end, blocks,
            movable=lambda b: b.name in var_to_num,
            key_of=lambda b: (var_to_num.get(b.name, NO_NUMBER),))
        if new_text is not None:
            write_text(path, new_text)
            res.fixed = True
        else:
            res.findings.append(Finding("variables-order", res.path,
                ".HCL variables out of dependency-number order; could not be safely auto-fixed"))
    else:
        res.findings.append(Finding("variables-order", res.path,
            f"`.HCL` variables not ordered by dependency number ({first_regression(mapped_seq)})"))
    return res


def first_regression(seq: list[tuple[str, int]], unit: str = "dep") -> str:
    prev_label, prev_num = None, -1
    for label, num in seq:
        if num < prev_num:
            return f"'{label}'({unit} {num:02d}) after {unit} {prev_num:02d} ('{prev_label}')"
        prev_label, prev_num = label, num
    return "out of order"


# --------------------------------------------------------------------------- #
# providers.tf parsing (rule D)
# --------------------------------------------------------------------------- #
def check_providers_tf(path: Path, repo: Path, cfg: Config, fix: bool) -> FileResult:
    res = FileResult(path=rel(repo, path))
    text = read_text(path)
    weight = cfg.provider_weight
    changed = False

    # ---- required_providers entries (nested block) ----
    rp_m = re.search(r"required_providers\s*\{", text)
    if rp_m:
        rp_open = text.index("{", rp_m.start())
        rp_close = find_matching_brace(text, rp_open)
        inner = text[rp_open + 1:rp_close]
        entries = find_provider_entries(inner)
        names = [e.name for e in entries]
        unknown = [nm for nm in names if nm not in weight]
        keys = [weight.get(nm, NO_NUMBER) for nm in names]
        if unknown:
            res.findings.append(Finding("providers", res.path,
                f"providers not in the ranking (add to .terraform-order.json): {', '.join(sorted(set(unknown)))}",
                severity="warning"))
        if not is_sorted([weight[nm] for nm in names if nm in weight]):
            if fix:
                new_inner = reorder_provider_entries(inner, entries, weight)
                if new_inner is not None and new_inner != inner:
                    text = text[:rp_open + 1] + new_inner + text[rp_close:]
                    changed = True
                elif new_inner is None:
                    res.findings.append(Finding("providers", res.path,
                        "required_providers out of order; could not be safely auto-fixed"))
            else:
                res.findings.append(Finding("providers", res.path,
                    f"required_providers not ordered heaviest->lightest: {names}"))

    # ---- top-level provider blocks ----
    pblocks = find_top_level_blocks(text, "provider")
    if pblocks:
        pnames = [b.name for b in pblocks]
        if not is_sorted([weight[nm] for nm in pnames if nm in weight]):
            if fix:
                new_text = reorder_pinned_region(
                    text, pblocks[0].start, pblocks[-1].end, pblocks,
                    movable=lambda b: b.name in weight,
                    key_of=lambda b: (weight.get(b.name, NO_NUMBER),))
                if new_text is not None and new_text != text:
                    text = new_text
                    changed = True
                elif new_text is None:
                    res.findings.append(Finding("providers", res.path,
                        "provider blocks out of order; could not be safely auto-fixed"))
            else:
                res.findings.append(Finding("providers", res.path,
                    f"provider blocks not ordered heaviest->lightest: {pnames}"))

    if fix and changed:
        write_text(path, text)
        res.fixed = True
    return res


@dataclass
class ProviderEntry:
    name: str
    start: int
    end: int


def find_provider_entries(inner: str) -> list[ProviderEntry]:
    """Find ``name = { ... }`` entries inside a required_providers body."""
    out: list[ProviderEntry] = []
    for m in re.finditer(r"(?m)^[ \t]*([A-Za-z0-9_-]+)\s*=\s*\{", inner):
        open_brace = inner.index("{", m.start())
        close = find_matching_brace(inner, open_brace)
        end = close + 1
        if end < len(inner) and inner[end] == "\n":
            end += 1
        out.append(ProviderEntry(name=m.group(1), start=m.start(), end=end))
    return out


def reorder_provider_entries(inner: str, entries: list[ProviderEntry],
                             weight: dict[str, int]) -> str | None:
    """Reorder required_providers entries by weight, pinning un-ranked ones.

    Returns ``None`` when the body does not round-trip (then the caller leaves
    it untouched).
    """
    items: list[Item] = []
    cursor = entries[0].start
    prefix = inner[:cursor]
    for e in entries:
        items.append(Item(key=(weight.get(e.name, NO_NUMBER),),
                          text=inner[cursor:e.end], name=e.name))
        cursor = e.end
    suffix = inner[cursor:]
    if prefix + "".join(it.text for it in items) + suffix != inner:
        return None
    movable_idx = [i for i, e in enumerate(entries) if e.name in weight]
    movable_sorted = sorted((items[i] for i in movable_idx), key=lambda it: it.key)
    new_items = list(items)
    for slot, it in zip(movable_idx, movable_sorted):
        new_items[slot] = it
    return prefix + "".join(it.text for it in new_items) + suffix


# --------------------------------------------------------------------------- #
# outputs.tf parsing (rule E)
# --------------------------------------------------------------------------- #
RE_MODULE_DECL = re.compile(r'(?m)^module\s+"([^"]+)"\s*\{')
RE_RESOURCE_DECL = re.compile(r'(?m)^resource\s+"([^"]+)"\s+"([^"]+)"\s*\{')
RE_MODULE_REF = re.compile(r"\bmodule\.([A-Za-z0-9_]+)")
RE_RESOURCE_REF = re.compile(r"\b([a-z][a-z0-9_]+)\.([A-Za-z0-9_]+)")
_REF_KEYWORDS = {"var", "local", "module", "data", "each", "count", "self", "path", "terraform"}


def build_main_positions(stack_dir: Path) -> dict[str, int]:
    """Map ``module.<name>`` and ``<type>.<name>`` to a global declaration rank.

    Files are ordered with `main.tf` first, then other `main*.tf`
    alphabetically; within a file, by line. This mirrors the team convention
    of reading outputs in the order their backing modules appear in `main*.tf`.
    """
    main_files = sorted(stack_dir.glob("main*.tf"),
                        key=lambda p: (p.name != "main.tf", p.name))
    positions: dict[str, int] = {}
    rank = 0
    for f in main_files:
        body = read_text(f)
        decls: list[tuple[int, str]] = []
        for m in RE_MODULE_DECL.finditer(body):
            decls.append((m.start(), f"module.{m.group(1)}"))
        for m in RE_RESOURCE_DECL.finditer(body):
            decls.append((m.start(), f"{m.group(1)}.{m.group(2)}"))
        for _, token in sorted(decls):
            if token not in positions:
                positions[token] = rank
                rank += 1
    return positions


def output_anchor(value_body: str, positions: dict[str, int]) -> int | None:
    """Rank of the first module/resource the output value references, if any."""
    best: int | None = None
    best_off = None
    mm = RE_MODULE_REF.search(value_body)
    if mm and f"module.{mm.group(1)}" in positions:
        best, best_off = positions[f"module.{mm.group(1)}"], mm.start()
    for rm in RE_RESOURCE_REF.finditer(value_body):
        rtype = rm.group(1)
        if rtype in _REF_KEYWORDS:
            continue
        token = f"{rtype}.{rm.group(2)}"
        if token in positions and (best_off is None or rm.start() < best_off):
            best, best_off = positions[token], rm.start()
    return best


def check_outputs_tf(path: Path, repo: Path, stack_dir: Path, fix: bool) -> FileResult:
    res = FileResult(path=rel(repo, path))
    text = read_text(path)
    blocks = find_top_level_blocks(text, "output")
    if len(blocks) < 2:
        return res
    positions = build_main_positions(stack_dir)
    if not positions:
        return res

    # Effective anchor: an output with no module/resource ref inherits the
    # anchor of the preceding output, so passthrough (var/local) outputs ride
    # along with the group they currently follow instead of jumping around.
    anchors: list[int | None] = []
    running = -1
    raw_anchor: list[int | None] = []
    for b in blocks:
        a = output_anchor(text[b.start:b.end], positions)
        raw_anchor.append(a)
        if a is not None:
            running = a
        anchors.append(running)

    # Check only constrains anchored-vs-anchored outputs (conservative).
    anchored_seq = [(b.name, a) for b, a in zip(blocks, raw_anchor) if a is not None]
    if is_sorted([a for _, a in anchored_seq]):
        return res

    if fix:
        idx_key = {id(b): (anchors[i], i) for i, b in enumerate(blocks)}
        built = build_items(text, blocks[0].start, blocks[-1].end, blocks,
                            key_of=lambda b: idx_key[id(b)])
        if built:
            items, suffix = built
            new_text = reorder_region(text, blocks[0].start, blocks[-1].end, items, suffix)
            write_text(path, new_text)
            res.fixed = True
        else:
            res.findings.append(Finding("outputs", res.path,
                "outputs out of main.tf order; could not be safely auto-fixed"))
    else:
        res.findings.append(Finding("outputs", res.path,
            f"outputs not ordered by main*.tf module/resource declaration order ({first_regression(anchored_seq, unit='pos')})"))
    return res


# --------------------------------------------------------------------------- #
# Orchestration
# --------------------------------------------------------------------------- #
# Never descend into these: provider plugin caches, the repo's own VCS dir,
# and the `.pipelines` checkout the GitHub workflow clones the shared scripts
# into (a sibling under the consumer workspace -- scanning it would lint the
# pipelines repo instead of the consumer).
EXCLUDED_DIRS = {".terraform", ".git", ".pipelines"}


def _excluded(p: Path) -> bool:
    return bool(EXCLUDED_DIRS.intersection(p.parts))


def discover_root_hcls(repo: Path) -> list[Path]:
    env_dir = repo / "environments"
    base = env_dir if env_dir.is_dir() else repo
    return sorted(p for p in base.rglob("root.hcl") if not _excluded(p))


def discover_providers(repo: Path) -> list[Path]:
    return sorted(p for p in repo.rglob("providers.tf") if not _excluded(p))


def run(repo: Path, cfg: Config, fix: bool) -> list[FileResult]:
    results: list[FileResult] = []
    var_to_num_by_stack: dict[str, dict[str, int]] = {}

    # Rules A & B: root.hcl files (also builds var->dep-number maps for rule C).
    for rh_path in discover_root_hcls(repo):
        if cfg.is_ignored(rel(repo, rh_path)):
            continue
        rh = parse_root_hcl(rh_path)
        if rh.stack_name:
            var_to_num_by_stack[rh.stack_name] = rh.var_to_num
        results.append(check_root_hcl(rh, repo, fix))

        # Rule C: the paired stack's variables.tf.
        if rh.stack_name:
            vf = repo / "stacks" / rh.stack_name / "variables.tf"
            if vf.is_file() and not cfg.is_ignored(rel(repo, vf)):
                results.append(check_variables_tf(vf, repo, rh.var_to_num, fix))
            # Rule E: the paired stack's outputs.tf.
            of = repo / "stacks" / rh.stack_name / "outputs.tf"
            if of.is_file() and not cfg.is_ignored(rel(repo, of)):
                results.append(check_outputs_tf(of, repo, of.parent, fix))

    # Rule D: every providers.tf in the repo (stacks + modules + single-module).
    for pf in discover_providers(repo):
        if cfg.is_ignored(rel(repo, pf)):
            continue
        results.append(check_providers_tf(pf, repo, cfg, fix))

    return [r for r in results if r.findings or r.fixed]


# --------------------------------------------------------------------------- #
# JUnit + human output
# --------------------------------------------------------------------------- #
def write_junit(results: list[FileResult], report_dir: Path) -> None:
    report_dir.mkdir(parents=True, exist_ok=True)
    cases = []
    total = failures = 0
    for r in results:
        errors = [f for f in r.findings if f.severity == "error"]
        warns = [f for f in r.findings if f.severity == "warning"]
        total += 1
        name = xml_escape(r.path)
        if errors:
            failures += 1
            msg = xml_escape("; ".join(f"[{f.rule}] {f.message}" for f in errors))
            cases.append(f'    <testcase classname="order-check" name="{name}">'
                         f'<failure message="{msg}"/></testcase>')
        else:
            extra = ""
            if warns:
                wmsg = xml_escape("; ".join(f"[{f.rule}] {f.message}" for f in warns))
                extra = f'<system-out>{wmsg}</system-out>'
            cases.append(f'    <testcase classname="order-check" name="{name}">{extra}</testcase>')
    body = "\n".join(cases)
    xml = ('<?xml version="1.0" encoding="UTF-8"?>\n'
           f'<testsuites name="order-check" tests="{total}" failures="{failures}">\n'
           f'  <testsuite name="order-check" tests="{total}" failures="{failures}">\n'
           f'{body}\n'
           '  </testsuite>\n</testsuites>\n')
    write_text(report_dir / "junit-order-check.xml", xml)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Check/auto-fix Terragrunt file ordering.")
    parser.add_argument("--fix", action="store_true",
                        help="rewrite files into the canonical order instead of only reporting")
    parser.add_argument("--repo-dir", default=".", help="repository root to scan (default: cwd)")
    parser.add_argument("--config", default=None, help="path to .terraform-order.json")
    parser.add_argument("--report", default=os.environ.get("REPORT_PATH", "build/reports"),
                        help="directory for the JUnit report")
    args = parser.parse_args(argv)

    repo = Path(args.repo_dir).resolve()
    if not repo.is_dir():
        print(f"ERROR: repo dir not found: {repo}", file=sys.stderr)
        return 1
    cfg = Config.load(repo, Path(args.config) if args.config else None)

    results = run(repo, cfg, fix=args.fix)
    report_dir = (repo / args.report) if not os.path.isabs(args.report) else Path(args.report)
    write_junit(results, report_dir)

    errors = warnings = fixed = 0
    for r in results:
        for f in r.findings:
            line = f"  {f.severity.upper()}: [{f.rule}] {f.path}: {f.message}"
            print(line, file=sys.stderr if f.severity == "error" else sys.stdout)
            if f.severity == "error":
                errors += 1
            else:
                warnings += 1
        if r.fixed:
            fixed += 1
            print(f"  FIXED: {r.path}")

    if args.fix:
        print(f"\norder-check: rewrote {fixed} file(s); {errors} unfixable error(s), {warnings} warning(s).")
        if fixed:
            # Reordering `root.hcl` inputs changes per-group `=` alignment;
            # the `.tf` reordering is already fmt-clean. Defer alignment to the
            # repo's formatter (the same one the code-check stage enforces).
            print("  Tip: run your formatter to normalize alignment "
                  "(`terra format`, or `terraform fmt -recursive` + `terragrunt hcl format`).")
        # After a fix run, only genuinely unfixable errors should remain.
        return 1 if errors else 0
    if errors:
        print(f"\norder-check: {errors} ordering error(s) across "
              f"{len({r.path for r in results if any(f.severity == 'error' for f in r.findings)})} file(s). "
              f"Run with --fix to auto-sort. ({warnings} warning(s).)", file=sys.stderr)
        return 1
    print(f"order-check: no ordering errors. ({warnings} warning(s).)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
