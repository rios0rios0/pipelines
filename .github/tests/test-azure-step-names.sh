#!/usr/bin/env bash
set -e

# Hold the Azure DevOps step-name contract across the whole repository.
#
# Why a dedicated regression test exists:
#
# Azure DevOps rejects a job whose expanded step list declares the same `name:`
# twice:
#
#   The step name Scripts appears more than once. Step names must be unique
#   within a job.
#
# It is a COMPILE-time error, so the job never starts -- nothing in it runs, and
# the failure is attributed to the job rather than to the template that caused
# it. Five abstracts here include `global/abstracts/scripts-repo.yaml`, whose
# step is `name: 'Scripts'`. A job that includes one of those abstracts AND
# includes `scripts-repo` directly therefore declares `Scripts` twice.
#
# That is easy to write and impossible to see: the second include reads as
# making a dependency explicit, both lines are individually correct, and neither
# file is wrong on its own -- the defect only exists in their COMBINATION, which
# no single file shows. It has already happened four times: `sca:govulncheck`
# on the Go template, then `style:tflint`, `test:all` and `test:validate` on the
# terra template.
#
# Nothing else in CI can catch it. The YAML is valid, ShellCheck does not read
# it, and this repository is a template library -- no pipeline here ever runs,
# so the first execution is always in a consumer's project. The templates must
# therefore be EXPANDED and checked here, which is what this test does.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPTS_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# assert_empty <description> <captured-output>
#
# Passes when the output is empty; the offending job is printed on failure, so
# the message names what to fix rather than only that something is wrong.
assert_empty() {
  local description="$1"
  local output="$2"
  if [ -z "$output" ]; then
    echo -e "${GREEN}  PASS: $description${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}  FAIL: $description${NC}"
    echo "$output" | sed 's/^/         /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# The expansion is shared by both assertions, so it runs once and each
# assertion selects from its output. `python3` with PyYAML is already a
# dependency of this suite (test-lambda-templates.sh parses templates the same
# way), so this adds no new tooling.
EXPANSION="$(/usr/bin/env python3 - <<'PY'
import json, os, sys
try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML is required to expand the Azure templates\n")
    sys.exit(2)
from collections import Counter

ROOT = os.path.abspath(".")
AZ = os.path.join(ROOT, "azure-devops")
SCRIPTS_REPO = os.path.join(AZ, "global/abstracts/scripts-repo.yaml")

cache = {}


def load(path):
    if path not in cache:
        try:
            with open(path, encoding="utf-8") as fh:
                cache[path] = yaml.safe_load(fh)
        except Exception:
            cache[path] = None
    return cache[path]


def resolve(ref, base):
    # `path@repo` names another repository resource, which cannot be expanded
    # from here; the path half is still the right thing to resolve locally.
    ref = str(ref).split("@", 1)[0]
    return os.path.normpath(os.path.join(os.path.dirname(base), ref))


def flatten(entries):
    """Yield real entries, unwrapping `${{ if ... }}:` and `${{ each ... }}:`.

    Those wrappers are ordinary YAML keys, so a naive walk sees a one-key dict
    where a job or a step should be and skips the whole block -- which is how
    `test:validate`, the only one of the three defects sitting inside an
    `${{ if }}`, hid from the first version of this check.
    """
    if not isinstance(entries, list):
        return
    for entry in entries:
        if isinstance(entry, dict) and len(entry) == 1:
            (key, value), = entry.items()
            if isinstance(key, str) and key.strip().startswith("${{"):
                if isinstance(value, list):
                    for inner in flatten(value):
                        yield inner
                elif isinstance(value, dict):
                    yield value
                continue
        if isinstance(entry, dict):
            yield entry


def uncommented_strings(node):
    """Yield every string in a step, with whole-line shell comments removed.

    Applied to the RAW strings, never to a serialised step: `json.dumps` escapes
    a `script:` body's newlines into one physical line, so splitting that on
    "\n" finds no comment lines at all and strips nothing. That is not a
    theoretical distinction -- it is the difference between this assertion
    passing and it reporting a job that is perfectly correct.

    Without the stripping, an abstract that merely EXPLAINS
    `$(Scripts.Directory)` in a comment counts as using it:
    `terraform/abstracts/terra-terraform.yaml` says "there is no
    $(Scripts.Directory) to source the manifest from yet", which is a comment
    about the variable's ABSENCE. Same reason test-supply-chain.sh strips
    comments before matching -- this repository documents what it forbids at
    length, so a naive check is failed by its own explanation.
    """
    if isinstance(node, str):
        yield "\n".join(
            line for line in node.splitlines()
            if not line.lstrip().startswith("#")
        )
    elif isinstance(node, dict):
        for key, value in node.items():
            yield str(key)
            for item in uncommented_strings(value):
                yield item
    elif isinstance(node, list):
        for value in node:
            for item in uncommented_strings(value):
                yield item
    else:
        yield str(node)


def expand(steps, base, chain):
    """Yield (kind, payload) for a job's fully expanded step list.

    kind is 'tpl' (a resolved template path) or 'step' (a real step).
    """
    for step in flatten(steps):
        template = step.get("template")
        if template:
            path = resolve(template, base)
            yield "tpl", path
            if path in chain:          # a cycle would otherwise recurse forever
                continue
            doc = load(path)
            if isinstance(doc, dict) and "steps" in doc:
                for item in expand(doc["steps"], path, chain | {path}):
                    yield item
            continue
        yield "step", step


def collect(node, base, out):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "jobs" and isinstance(value, list):
                for entry in flatten(value):
                    if "job" in entry:
                        items = list(expand(entry.get("steps", []), base, {base}))
                        names = [
                            s.get("name") for kind, s in items
                            if kind == "step" and isinstance(s.get("name"), str) and s.get("name")
                        ]
                        body = "\n".join(
                            text
                            for kind, s in items if kind == "step"
                            for text in uncommented_strings(s)
                        )
                        out.append({
                            "file": os.path.relpath(base, ROOT),
                            "job": entry.get("job"),
                            "duplicates": {n: c for n, c in Counter(names).items() if c > 1},
                            "has_scripts_repo": any(
                                kind == "tpl" and p == SCRIPTS_REPO for kind, p in items
                            ),
                            "uses_scripts_dir": "$(Scripts.Directory)" in body,
                        })
                    elif "template" in entry:
                        path = resolve(entry["template"], base)
                        doc = load(path)
                        if doc is not None:
                            collect(doc, path, out)
            else:
                collect(value, base, out)
    elif isinstance(node, list):
        for item in node:
            collect(item, base, out)


out = []
for dirpath, _, filenames in os.walk(AZ):
    for filename in sorted(filenames):
        if not filename.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(dirpath, filename)
        doc = load(path)
        if doc is not None:
            collect(doc, path, out)

# A job reachable from more than one entry template is collected more than
# once; the findings are identical, so they are de-duplicated for the report.
seen = set()
for job in out:
    key = json.dumps(job, sort_keys=True)
    if key in seen:
        continue
    seen.add(key)
    print(json.dumps(job, sort_keys=True))
PY
)"

echo "1. Step names are unique within every expanded job"
DUPLICATE_NAMES="$(
  echo "$EXPANSION" | /usr/bin/env python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    job = json.loads(line)
    for name, count in sorted(job["duplicates"].items()):
        print("%s: job %s declares the step name %r %d times"
              % (job["file"], job["job"], name, count))
'
)"
assert_empty "no job declares the same step name twice" "$DUPLICATE_NAMES"
echo ""

echo "2. Every job using \$(Scripts.Directory) checks the scripts out"
# The opposite failure, and the reason the duplicate is so tempting to add: a
# job that references $(Scripts.Directory) without including `scripts-repo`
# gets an EMPTY string, so the command becomes `/global/scripts/...` and the
# job fails with exit 127. That error names neither the variable nor the
# missing template, so the obvious fix -- add the include -- is exactly what
# creates the duplicate this file's first assertion catches. Both directions
# have to hold at once, which is why they are asserted together.
MISSING_SCRIPTS_REPO="$(
  echo "$EXPANSION" | /usr/bin/env python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    job = json.loads(line)
    if job["uses_scripts_dir"] and not job["has_scripts_repo"]:
        print("%s: job %s uses $(Scripts.Directory) but never includes scripts-repo"
              % (job["file"], job["job"]))
'
)"
assert_empty "every job using \$(Scripts.Directory) includes scripts-repo" "$MISSING_SCRIPTS_REPO"
echo ""

echo "=============================="
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ] && echo -e "${GREEN}Azure DevOps step-name contract holds${NC}"
[ "$TESTS_FAILED" -eq 0 ]
