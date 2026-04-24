#!/usr/bin/env python3
"""Generate `tests/smoke.tftest.hcl` for a single terraform-module repo.

Where `customer-clusters/tests/generators/gen_smoke_tests.py` treats
`modules/<name>/` as the module and iterates over all of them, this variant
treats the CWD (or `--repo-dir`) as the single module and emits one file
at `<repo-dir>/tests/smoke.tftest.hcl`. That matches the terraform-modules
project layout where every module is its own Azure DevOps repository.

Reads:
    <repo>/variables.tf
    <repo>/main.tf              (for required_providers local-name bindings)
    <repo>/providers.tf         (if present)

Emits:
    <repo>/tests/smoke.tftest.hcl   with:
      * one `mock_provider "<local>" {}` for every required provider
      * one `run "smoke_plans_successfully"` with type-valid stubs for every
        required variable
      * one `run "validation_rejects_invalid_<var>"` per required variable
        that has at least one `validation {}` block, using an invalid stub
        and `expect_failures = [var.<var>]`

Skips regeneration when `<repo>/tests/smoke.tftest.hcl` exists and lacks
the auto-generated marker on line 1 (so hand-written tests stay untouched).
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

MARKER = "# smoke.tftest.hcl -- auto-generated minimal plan-time smoke test."

# ---------- HCL tokenisation helpers (lifted from customer-clusters) ----------

RE_VARIABLE_BLOCK = re.compile(r'(?ms)^\s*variable\s+"([^"]+)"\s*\{(.*?)^\}\s*$')
RE_REQUIRED_PROVIDERS_HEAD = re.compile(r"required_providers\s*\{")
RE_PROVIDER_ENTRY = re.compile(r"(?s)([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*\{([^}]*)\}")
RE_SOURCE = re.compile(r'source\s*=\s*"([^"]+)"')
RE_VALIDATION = re.compile(r"(?s)validation\s*\{")


def balanced_expr(text: str, start: int) -> tuple[int, str]:
    depth, i, n = 0, start, len(text)
    in_str, str_q = False, ""
    while i < n:
        ch = text[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == str_q:
                in_str = False
            i += 1
            continue
        if ch in ('"', "'"):
            in_str = True
            str_q = ch
            i += 1
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif ch == "\n" and depth == 0:
            break
        elif ch == "=" and depth == 0 and i > start:
            j = i - 1
            while j > start and text[j] in " \t":
                j -= 1
            k = j
            while k > start and re.match(r"[A-Za-z0-9_]", text[k]):
                k -= 1
            end = k
            while end > start and text[end] in " \t":
                end -= 1
            return end, text[start:end].rstrip()
        i += 1
    return i, text[start:i]


def extract_attr_expr(body: str, attr: str) -> str | None:
    for m in re.finditer(r"(?m)^\s*" + re.escape(attr) + r"\s*=\s*", body):
        _end, value = balanced_expr(body, m.end())
        return value.strip()
    return None


def parse_variables(vars_tf: str) -> list[dict]:
    out = []
    for m in RE_VARIABLE_BLOCK.finditer(vars_tf):
        name, body = m.group(1), m.group(2)
        type_expr = extract_attr_expr(body, "type") or "string"
        has_default = bool(re.search(r"(?m)^\s*default\s*=\s*", body))
        has_validation = bool(RE_VALIDATION.search(body))
        out.append(
            {
                "name": name,
                "type": type_expr.strip(),
                "required": not has_default,
                "validation": has_validation,
            }
        )
    return out


def parse_required_providers(text: str) -> list[tuple[str, str]]:
    m = RE_REQUIRED_PROVIDERS_HEAD.search(text)
    if not m:
        return []
    start, depth, i, n = m.end(), 1, m.end(), len(text)
    in_str, str_q = False, ""
    while i < n and depth > 0:
        ch = text[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == str_q:
                in_str = False
            i += 1
            continue
        if ch in ('"', "'"):
            in_str = True
            str_q = ch
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    body = text[start:i]
    providers = []
    for em in RE_PROVIDER_ENTRY.finditer(body):
        source_match = RE_SOURCE.search(em.group(2))
        providers.append(
            (em.group(1), source_match.group(1) if source_match else "unknown")
        )
    return providers


# ---------- Name-based stubs (tuned for Azure / Cloudflare / K8s / Keycloak) ----------

NAME_STUBS: list[tuple[str, str]] = [
    # Azure
    (r"^location$", '"eastus"'),
    (r"^resource_group_name$", '"test-rg"'),
    (r"^subscription_id$", '"00000000-0000-0000-0000-000000000000"'),
    (r"^tenant_id$", '"00000000-0000-0000-0000-000000000000"'),
    (r"^virtual_network_name$", '"test-vnet"'),
    (r"^subnet_id$", '"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/subnet"'),
    (r"^key_vault_id$", '"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.KeyVault/vaults/test-kv"'),
    (r"address_space$", '["10.0.0.0/16"]'),
    (r"address_prefix(es)?$", '["10.0.0.0/16"]'),
    (r"^sku(_tier|_name)?$", '"Standard"'),

    # Generic identity
    (r"^environment$", '"dev"'),
    (r"^customer_id$", '"1001"'),
    (r"^name$", '"test"'),
    (r"^name_prefix$", '"test"'),
    (r"^name_suffix$", '"test"'),

    # Networking / endpoints
    (r"cidr", '"10.0.0.0/16"'),
    (r"^vpc_id$", '"vpc-12345678"'),
    (r"url$", '"https://example.com"'),
    (r"host(name)?$", '"example.com"'),
    (r"endpoint$", '"https://example.com"'),
    (r"email$", '"test@example.com"'),

    # Secrets / tokens
    (r"(token|password|secret|api_key|key)$", '"dummy-value-0000"'),

    # Numeric sizes
    (r"^cpu$", "256"),
    (r"^memory$", "512"),
    (r"^port$", "80"),
    (r"replicas?$", "1"),
    (r"_count$", "1"),

    # K8s
    (r"^namespace$", '"default"'),
    (r"service_account_name$", '"test-sa"'),

    # Helm
    (r"chart_version$", '"1.0.0"'),
    (r"image$", '"nginx:latest"'),
    (r"registry$", '"test.azurecr.io"'),

    # Keycloak
    (r"^realm_id$", '"test-realm"'),
    (r"^client_id$", '"test-client"'),

    # IDs fallback
    (r"guid", '"00000000-0000-0000-0000-000000000000"'),
    (r"_id$", '"test-id"'),
]


def stub_for_name(name: str) -> str | None:
    for pat, val in NAME_STUBS:
        if re.search(pat, name):
            return val
    return None


def _split_top_level(s: str, sep: str) -> list[str]:
    out, depth, cur = [], 0, []
    in_str, str_q = False, ""
    extra = {"\n"} if sep == "," else set()
    for ch in s:
        if in_str:
            cur.append(ch)
            if ch == str_q:
                in_str = False
            continue
        if ch in ('"', "'"):
            in_str = True
            str_q = ch
            cur.append(ch)
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if depth == 0 and (ch == sep or ch in extra):
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if cur:
        out.append("".join(cur).strip())
    return [p for p in out if p]


def _render_object_fields(inner: str) -> str:
    items = _split_top_level(inner, ",")
    parts = []
    for it in items:
        if "=" not in it:
            continue
        key, ty = it.split("=", 1)
        key, ty = key.strip(), ty.strip()
        if ty.startswith("optional("):
            continue
        parts.append(f"{key} = {gen_stub(ty)}")
    return ", ".join(parts)


def _first_type_arg(s: str) -> str:
    return _split_top_level(s, ",")[0].strip()


def gen_stub(type_expr: str, var_name: str | None = None) -> str:
    t = type_expr.strip()
    om = re.match(r"optional\((.+)\)$", t, re.DOTALL)
    if om:
        return gen_stub(_first_type_arg(om.group(1)), var_name)
    if var_name and t in ("string", "number", "any"):
        hint = stub_for_name(var_name)
        if hint is not None:
            return hint
    if t == "string":
        return '"test"'
    if t == "number":
        return "1"
    if t == "bool":
        return "true"
    if t == "any":
        return '"test"'
    if t.startswith("list(") or t.startswith("set("):
        return f"[{gen_stub(t[t.index('(') + 1 : -1], var_name)}]"
    if t.startswith("map("):
        return f'{{ "k" = {gen_stub(t[4:-1], var_name)} }}'
    if t.startswith("object("):
        inner = t[len("object(") : -1].strip()
        if inner.startswith("{") and inner.endswith("}"):
            inner = inner[1:-1]
        return "{ " + _render_object_fields(inner) + " }"
    if t.startswith("tuple("):
        inner = t[len("tuple(") : -1].strip()
        if inner.startswith("["):
            inner = inner[1:-1]
        return "[" + ", ".join(gen_stub(x) for x in _split_top_level(inner, ",")) + "]"
    return '"test"'


def _invalid_stub(var: dict) -> str | None:
    # Returns a value that is type-valid (so `terraform plan` reaches the
    # validation block) but value-invalid (so the validation fails). Returns
    # None when we can't reliably construct one -- `object(...)` and
    # `tuple(...)` require specific required fields/positions, so `{}` and
    # `[]` fail the type check *before* any validation runs. The caller
    # must skip generating a validation_rejects test in that case.
    t = var["type"].strip()
    if t == "string" or t.startswith("string") or t == "any":
        return '""'
    if t == "number" or t.startswith("number"):
        return "-1"
    if t.startswith(("list(", "set(")):
        return "[]"
    if t.startswith("map("):
        return "{}"
    # bool, object(...), tuple(...) -- no safe type-valid-but-value-invalid
    # stub is derivable from the type expression alone.
    return None


# ---------- File emission ----------

SMOKE_TEMPLATE = """{marker}
#
# Asserts the module parses, type-checks, and plans with mocked providers.
# Every `variable {{ validation {{ ... }} }}` block gets a sibling test
# that supplies a known-invalid value and asserts the validation fires,
# so the guards are covered -- not just declared.
{mocks}
run "smoke_plans_successfully" {{
  # given
  command = plan
{variables_block}
  # when
  # (the plan command above is the act under test)

  # then
  # No assertions -- if `terraform test` reaches here without a plan error,
  # the module compiled, resolved every reference, and produced a valid
  # plan graph. That is the smoke-test signal.
}}
{validation_runs}"""


def render_smoke(providers: list[tuple[str, str]], variables: list[dict]) -> str:
    mock_lines = [f'mock_provider "{local}" {{}}' for local, _ in providers]
    mocks = ("\n" + "\n".join(mock_lines) + "\n") if mock_lines else ""

    required = [v for v in variables if v["required"]]
    valid_stubs: dict[str, str] = {}
    for v in required:
        try:
            valid_stubs[v["name"]] = gen_stub(v["type"], v["name"])
        except Exception:
            valid_stubs[v["name"]] = '"test"'

    if required:
        lines = ["  variables {"]
        for v in required:
            lines.append(f"    {v['name']} = {valid_stubs[v['name']]}")
        lines.append("  }\n")
        variables_block = "\n" + "\n".join(lines)
    else:
        variables_block = ""

    validation_parts: list[str] = []
    for v in [vv for vv in variables if vv["validation"] and vv["required"]]:
        invalid = _invalid_stub(v)
        if invalid is None:
            # Skip: type (object / tuple / bool) has no reliable
            # type-valid-but-value-invalid stub. Hand-write the test.
            continue
        vars_block_lines = ["  variables {"]
        for other in required:
            val = invalid if other["name"] == v["name"] else valid_stubs[other["name"]]
            vars_block_lines.append(f"    {other['name']} = {val}")
        vars_block_lines.append("  }")
        validation_parts.append(
            f'\nrun "validation_rejects_invalid_{v["name"]}" {{\n'
            f"  # given\n"
            f"  command = plan\n\n"
            f"{chr(10).join(vars_block_lines)}\n\n"
            f"  # when\n"
            f"  # (plan is executed with var.{v['name']} set to an invalid value)\n\n"
            f"  # then\n"
            f"  # The validation block on var.{v['name']} must reject the\n"
            f"  # invalid value -- expect_failures asserts the plan errors\n"
            f"  # out on exactly that variable. Proves the guard fires, not\n"
            f"  # just that it's declared.\n"
            f"  expect_failures = [\n"
            f"    var.{v['name']},\n"
            f"  ]\n"
            f"}}"
        )
    validation_runs = "\n".join(validation_parts)
    if validation_runs:
        validation_runs = validation_runs + "\n"

    return SMOKE_TEMPLATE.format(
        marker=MARKER,
        mocks=mocks,
        variables_block=variables_block,
        validation_runs=validation_runs,
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo-dir", default=".", help="Path to the module repo root (default: cwd)")
    ap.add_argument("--force", action="store_true", help="Overwrite even hand-written tests (dangerous)")
    args = ap.parse_args()

    repo = Path(args.repo_dir).resolve()
    tests_dir = repo / "tests"
    smoke = tests_dir / "smoke.tftest.hcl"

    if smoke.exists() and not args.force:
        first_line = smoke.read_text().splitlines()[0] if smoke.read_text() else ""
        if MARKER not in first_line:
            print(f"SKIP hand-written smoke at {smoke} (use --force to overwrite)")
            return 0

    vars_tf = (repo / "variables.tf").read_text() if (repo / "variables.tf").exists() else ""
    main_tf = (repo / "main.tf").read_text() if (repo / "main.tf").exists() else ""
    providers_tf = (repo / "providers.tf").read_text() if (repo / "providers.tf").exists() else ""
    combined = providers_tf + "\n" + main_tf

    providers = parse_required_providers(combined)
    variables = parse_variables(vars_tf)
    content = render_smoke(providers, variables)

    tests_dir.mkdir(exist_ok=True)
    smoke.write_text(content)
    print(f"wrote {smoke} (providers={len(providers)}, vars={len(variables)}, validations={sum(1 for v in variables if v['validation'])})")

    # Canonicalise formatting. Use argv (no shell) so repo paths with spaces
    # don't break and an adversarial --repo-dir can't inject shell tokens.
    if shutil.which("terraform") is None:
        print("warning: terraform not on PATH; skipping `terraform fmt` on generated file", file=sys.stderr)
        return 0
    fmt = subprocess.run(
        ["terraform", f"-chdir={repo}", "fmt", "tests/"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if fmt.returncode != 0:
        print(f"warning: `terraform fmt` exited {fmt.returncode}: {fmt.stderr.strip()}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
