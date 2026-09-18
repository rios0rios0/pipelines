#!/usr/bin/env bash
set -e

# Hold the Azure DevOps secret-passing contract across the whole repository.
#
# Why a dedicated regression test exists:
#
# Azure Pipelines injects NON-SECRET pipeline variables into every step's
# process environment automatically, and NEVER injects secret ones. A step that
# reads a credential ambiently therefore works perfectly while the variable is
# stored in plaintext and silently stops receiving it the moment somebody marks
# it secret -- which is the one thing everybody is eventually told to do.
#
# The failure is invisible in both directions. Marking the variable secret is a
# Library UI change in the CONSUMER's project, with no diff and no relationship
# to this repository; the pipeline then goes on passing, because the scanners
# that lose their credential are `continueOnError: true`. So the template keeps
# a plaintext credential alive indefinitely and the project that tries to fix
# its own hygiene finding is the one that gets punished for it.
#
# `sca:safety` shipped exactly that way and blocked three separate projects from
# marking `SAFETY_API_KEY` secret until the step mapped it explicitly.
#
# Which step consumes which credential is established two different ways,
# because the defect hides in two different places:
#
#   1. DERIVED. A step that runs one of this repository's own scripts is checked
#      against what that script actually reads. This is mechanical and needs no
#      list to maintain.
#
#   2. DECLARED. A step that runs a third-party tool which reads its credential
#      STRAIGHT FROM THE ENVIRONMENT has no textual reference to the variable
#      anywhere -- not in the YAML, not in a script, nowhere. `safety` is the
#      archetype, and that invisibility is precisely why the bug survived review:
#      grepping the repository for `SAFETY_API_KEY` returned nothing at all. Such
#      a consumer cannot be derived and must be declared below.
#
# A third assertion keeps those tables honest: every credential-shaped variable
# the Azure templates and their scripts mention must be classified, so a new one
# forces a decision here instead of silently joining the ambient-and-broken group.
#
# The fourth holds the other direction of the same rule: a credential travels in
# the ENVIRONMENT, never in the script text. Azure expands the macro form
# everywhere in a script body, comments included, so merely DOCUMENTING the
# macro substitutes the real key into the file on the agent -- which is exactly
# how the comment above the guard was first written.
#
# The fifth asserts the other half of the safety fix, which is easy to lose in a
# later edit: the mapping delivers the macro text itself when the variable is
# undefined, so a mapping added without a guard converts "this project has no
# key" into "this project has a bogus key" -- trading a scan that degraded
# quietly for one that fails. It runs the shipped step body, not a copy.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPTS_DIR" || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

# assert_empty <description> <captured-output>
#
# Passes when the output is empty; the offending step is printed on failure, so
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

FINDINGS="$(/usr/bin/env python3 - <<'PY'
import json, os, re, sys
try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML is required to expand the Azure templates\n")
    sys.exit(2)

ROOT = os.path.abspath(".")
AZ = os.path.join(ROOT, "azure-devops")

# A credential is recognised by its NAME. Suffix matching rather than a
# substring: `SONAR_PROJECT_KEY`, `S3_KEY_PREFIX` and `*_REPORT_PATH` are
# configuration, not credentials, and a substring match on "KEY" drowns the
# real findings in them.
CREDENTIAL = re.compile(
    r"^[A-Z][A-Z0-9_]*(?:TOKEN|API_KEY|SECRET|PASSWORD|PASSWD|CREDENTIALS?)$"
)

# Credentials whose names the suffix rule cannot reach. `AWS_SECRET_ACCESS_KEY`
# carries "SECRET" in the middle and ends in the same `_KEY` that
# `SONAR_PROJECT_KEY` does, so no suffix rule separates them; they are named
# instead of loosening the rule and drowning the findings in configuration.
EXTRA_CREDENTIALS = {
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "GPG_PRIVATE_KEY",
    "SSH_PRIVATE_KEY",
}


def is_credential(name):
    return bool(CREDENTIAL.match(name)) or name in EXTRA_CREDENTIALS

# Credentials consumed by a tool that reads the environment directly, so no
# script in this repository ever names them. Each entry names the step that
# must map it: (file, displayName) -> variable.
DECLARED = {
    ("azure-devops/python/stages/20-security/pdm.yaml",
     "Run Safety dependency check"): ["SAFETY_API_KEY"],
}

# Steps that run a script which NAMES a credential on a code path they never
# take. The derived check reads a script as one body and cannot see which
# branch a job's variables select, so the exemption carries the reason.
EXEMPT_STEPS = {
    # `publish:validate` sets DART_PUBLISH_DRY_RUN, and publish/run.sh exits at
    # that check -- above everything that touches PUB_TOKEN. Mapping the token
    # into a job that must never publish would hand a release credential to the
    # one job that runs on every main build.
    ("azure-devops/dart/stages/40-delivery/dart-library.yaml",
     "Validate the package (dry run)"): ["PUB_TOKEN"],
}

# Classified and deliberately NOT asserted. Each needs a reason, so an
# exemption is a decision on the record rather than an omission.
EXEMPT = {
    # Generated per run by global/scripts/languages/golang/test/database.sh
    # (openssl rand). Never a pipeline variable, so nothing can withhold it.
    "POSTGRES_PASSWORD": "generated per run inside the script, not a pipeline variable",
    # Supplied by the Azure DevOps AWS service connection through
    # `AWSShellScript@1`, which injects them itself. The keys-in-variables
    # fallback is a separate, deliberate design decision: its steps GUARD on
    # the variables being absent and fail with an actionable message, and
    # mapping them through `env:` would defeat that guard, because an
    # undefined `$(AWS_ACCESS_KEY_ID)` arrives non-empty. Changing it is a
    # deployment-path change with its own test surface -- tracked separately.
    "AWS_ACCESS_KEY_ID": "service connection injects it; the variables fallback guards on absence",
    "AWS_SECRET_ACCESS_KEY": "service connection injects it; the variables fallback guards on absence",
    "AWS_SESSION_TOKEN": "service connection injects it; the variables fallback guards on absence",
    # Azure's own predefined secret, mapped from $(System.AccessToken) rather
    # than from a variable group of the same name.
    "SYSTEM_ACCESSTOKEN": "mapped from the predefined $(System.AccessToken)",
    # GitLab predefined variables. GitLab injects every CI/CD variable into the
    # job environment, including masked ones, so the defect class does not
    # exist there.
    "CI_JOB_TOKEN": "GitLab predefined; GitLab injects masked variables too",
    "CI_REGISTRY_PASSWORD": "GitLab predefined; GitLab injects masked variables too",
    # Consumed only by GitHub Actions workflows, where a secret is never
    # ambient and must always be passed explicitly -- a different contract,
    # enforced by the workflows themselves.
    "CLAUDE_CODE_OAUTH_TOKEN": "GitHub Actions only; secrets are never ambient there",
    "GH_TOKEN": "GitHub Actions only; no Azure consumer",
    "GITHUB_TOKEN": "GitHub Actions only; no Azure consumer",
    "SSH_PRIVATE_KEY": "documentation example in a GitLab comment, not a consumed variable",
    "GPG_PRIVATE_KEY": "GitHub Actions release signing only; no Azure consumer",
    # Passed to Gradle as a `-P` property through a task input. Task inputs
    # resolve secret variables, so the ambient-environment defect does not
    # apply to this path.
    "JAVA_PASSWORD": "reaches Gradle through a task input, which resolves secrets",
}

findings = []


def strip_comments(text):
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def credentials_in(text):
    """Every credential-shaped variable READ by a shell body."""
    found = set()
    for match in re.finditer(r"\$\{?([A-Z][A-Z0-9_]*)\b", strip_comments(text)):
        if is_credential(match.group(1)):
            found.add(match.group(1))
    return found


# --- what each of this repository's scripts reads -------------------------
script_reads = {}
for dirpath, _, filenames in os.walk(os.path.join(ROOT, "global", "scripts")):
    for filename in filenames:
        if not filename.endswith(".sh"):
            continue
        path = os.path.join(dirpath, filename)
        with open(path, encoding="utf-8", errors="replace") as handle:
            names = credentials_in(handle.read())
        if names:
            script_reads[os.path.relpath(path, ROOT)] = names


def walk_steps(node, path, out):
    """Yield every step-shaped mapping in a template, wrappers included.

    `${{ if }}:` / `${{ each }}:` blocks are ordinary YAML keys, so a walk that
    only follows known keys skips whatever they contain. Recursing through
    every value instead means a step inside a conditional is still seen.
    """
    if isinstance(node, dict):
        if "script" in node or ("task" in node and "inputs" in node):
            out.append((path, node))
            inputs = node.get("inputs")
            if isinstance(inputs, dict):
                # A task carries its shell under `inlineScript:`/`script:`, which
                # Azure macro-expands exactly like a bare `script:` step.
                inline = inputs.get("inlineScript") or inputs.get("script")
                if isinstance(inline, str):
                    out.append((path, {"script": inline,
                                       "displayName": node.get("displayName"),
                                       "env": node.get("env") or {}}))
        for value in node.values():
            walk_steps(value, path, out)
    elif isinstance(node, list):
        for value in node:
            walk_steps(value, path, out)


steps = []
for dirpath, _, filenames in os.walk(AZ):
    for filename in sorted(filenames):
        if not filename.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(dirpath, filename)
        try:
            with open(path, encoding="utf-8") as handle:
                doc = yaml.safe_load(handle)
        except Exception as exc:
            # A template that does not parse expands to no steps, so every
            # assertion below would pass for the worst possible reason.
            findings.append({
                "kind": "unparseable",
                "file": os.path.relpath(path, ROOT),
                "detail": " ".join(str(exc).split()),
            })
            continue
        walk_steps(doc, path, steps)

mentioned = set()
mapped_anywhere = set()

for path, step in steps:
    relative = os.path.relpath(path, ROOT)
    body = step.get("script") or ""
    if not isinstance(body, str):
        body = json.dumps(body)
    inputs = step.get("inputs") or {}
    body = body + "\n" + json.dumps(inputs, sort_keys=True)
    mapped = set(step.get("env") or {})
    mapped_credentials = {name for name in mapped if is_credential(name)}
    mapped_anywhere |= mapped_credentials
    mentioned |= mapped_credentials

    needed = set()

    # 1. DERIVED -- credentials read by a script this step runs, plus any the
    #    step's own inline body reads.
    for script, names in script_reads.items():
        if script in body:
            needed |= names
    needed |= credentials_in(body)

    # 2. DECLARED -- credentials a third-party tool reads from the environment.
    needed |= set(DECLARED.get((relative, step.get("displayName")), []))

    mentioned |= needed
    allowed = set(EXEMPT_STEPS.get((relative, step.get("displayName")), []))
    for name in sorted(needed - mapped - allowed):
        if name in EXEMPT:
            continue
        findings.append({
            "kind": "unmapped",
            "file": relative,
            "detail": "step %r reads %s but never maps it through `env:`"
                      % (step.get("displayName") or "<unnamed>", name),
        })

# --- a credential must never be macro-expanded INTO a script body ---------
# Azure expands `$(NAME)` everywhere in a step's script, comments included, and
# writes the result to a file on the agent. Naming a credential that way puts
# its VALUE in the script text rather than in the environment -- the same
# exposure `-DnvdApiKeyEnvironmentVariable` and `dart pub token add --env-var`
# exist to avoid. It is easiest to do by accident while DOCUMENTING the macro,
# which is how this check came to be written.
for path, step in steps:
    body = step.get("script")
    if not isinstance(body, str):
        continue
    for match in re.finditer(r"\$\(([A-Za-z_][A-Za-z0-9_.]*)\)", body):
        if is_credential(match.group(1)):
            findings.append({
                "kind": "macro in body",
                "file": os.path.relpath(path, ROOT),
                "detail": "step %r spells %s inside its script, so Azure "
                          "substitutes the credential's VALUE into the script "
                          "text -- pass it through `env:` and read it as a shell "
                          "variable instead"
                          % (step.get("displayName") or "<unnamed>", match.group(0)),
            })

# --- every declared entry must point at a step that still exists ----------
known_steps = {(os.path.relpath(p, ROOT), s.get("displayName")) for p, s in steps}
for key in DECLARED:
    if key not in known_steps:
        findings.append({
            "kind": "stale declaration",
            "file": key[0],
            "detail": "no step named %r -- the declared table names a step that "
                      "no longer exists, so its credential is unchecked" % key[1],
        })

# --- the classification must cover everything Azure could pass ambiently --
# Scoped to the Azure templates and the scripts they run, because that is where
# the defect lives: GitLab injects masked variables and GitHub never makes a
# secret ambient, so neither platform can reproduce it.
for base in (AZ, os.path.join(ROOT, "global", "scripts")):
    for dirpath, _, filenames in os.walk(base):
        for filename in filenames:
            if not filename.endswith((".yaml", ".yml", ".sh")):
                continue
            path = os.path.join(dirpath, filename)
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = strip_comments(handle.read())
            for match in re.finditer(r"\b([A-Z][A-Z0-9_]*)\b", text):
                if is_credential(match.group(1)):
                    mentioned.add(match.group(1))

# A credential is classified once something states how it travels: an explicit
# `env:` mapping somewhere in the Azure templates, a DECLARED entry, or an
# EXEMPT reason. Anything left is a name nobody has decided about, which is the
# state `SAFETY_API_KEY` was in.
declared_names = {n for names in DECLARED.values() for n in names}
for name in sorted(mentioned):
    if name in mapped_anywhere or name in declared_names or name in EXEMPT:
        continue
    findings.append({
        "kind": "unclassified",
        "file": ".github/tests/test-azure-secret-env.sh",
        "detail": "%s is credential-shaped but no Azure step maps it, and it is "
                  "neither declared nor exempt -- classify it so it cannot be "
                  "passed ambiently by accident" % name,
    })

for finding in findings:
    print(json.dumps(finding, sort_keys=True))
PY
)"

# Reported FIRST because it invalidates everything below: a template that does
# not parse expands to no steps, so the assertions find nothing to complain
# about and the suite goes green precisely when it has stopped looking.
echo "1. Every Azure template parses"
assert_empty "every template under azure-devops/ parses" "$(
  echo "$FINDINGS" | /usr/bin/env python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    f = json.loads(line)
    if f["kind"] == "unparseable":
        print("%s: %s" % (f["file"], f["detail"]))
'
)"
echo ""

echo "2. Every step consuming a credential maps it through \`env:\`"
assert_empty "no step reads a credential ambiently" "$(
  echo "$FINDINGS" | /usr/bin/env python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    f = json.loads(line)
    if f["kind"] == "unmapped":
        print("%s: %s" % (f["file"], f["detail"]))
'
)"
echo ""

echo "3. Every credential-shaped variable is classified"
assert_empty "the declared table is current and nothing is unclassified" "$(
  echo "$FINDINGS" | /usr/bin/env python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    f = json.loads(line)
    if f["kind"] in ("unclassified", "stale declaration"):
        print("%s: %s" % (f["file"], f["detail"]))
'
)"
echo ""

echo "4. No credential is macro-expanded into a script body"
assert_empty "every credential travels through \`env:\`, never through the script text" "$(
  echo "$FINDINGS" | /usr/bin/env python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    f = json.loads(line)
    if f["kind"] == "macro in body":
        print("%s: %s" % (f["file"], f["detail"]))
'
)"
echo ""

echo "5. The \`sca:safety\` step survives an undefined SAFETY_API_KEY"
# Azure DevOps substitutes nothing for an undefined variable, so `env:` hands
# the step the LITERAL `$(SAFETY_API_KEY)`. Without the guard this fix would
# regress every project that has no key at all -- turning "no credential" into
# "a bogus credential", which fails instead of degrading. The step's real body
# is extracted and run with the scan replaced by a probe, so this asserts on
# the shipped shell rather than on a copy of it.
BODY="$(/usr/bin/env python3 -c '
import yaml, sys
doc = yaml.safe_load(open("azure-devops/python/stages/20-security/pdm.yaml"))
for stage in doc["stages"]:
    for job in stage.get("jobs", []):
        if job.get("job") != "sca_safety":
            continue
        for step in job.get("steps", []):
            if step.get("displayName") == "Run Safety dependency check":
                sys.stdout.write(step["script"])
')"
PROBE="$(printf '%s' "$BODY" | sed 's|pdm run safety-scan|if [ -n "${SAFETY_API_KEY+x}" ]; then printf %s "$SAFETY_API_KEY"; fi|')"

GUARD_RESULT=""
# An empty extraction is a FINDING, not a skip. Renaming the step or the job
# would otherwise leave this assertion running against nothing at all and
# passing for it -- the same silent-pass shape assertion 1 exists to prevent.
if [ -z "$BODY" ]; then
  GUARD_RESULT="could not extract the sca:safety step body -- the job or displayName moved, so the guard is unverified
"
fi
# An unset variable arrives as the literal macro and must be discarded.
ACTUAL="$(SAFETY_API_KEY='$(SAFETY_API_KEY)' sh -c "$PROBE")"
[ -z "$ACTUAL" ] || GUARD_RESULT="${GUARD_RESULT}an undefined variable reached safety as '$ACTUAL'
"
# A real key must survive untouched -- the entire point of the `env:` mapping.
ACTUAL="$(SAFETY_API_KEY='fixture-token-placeholder' sh -c "$PROBE")"
[ "$ACTUAL" = 'fixture-token-placeholder' ] || GUARD_RESULT="${GUARD_RESULT}a real key did not survive the guard (got '$ACTUAL')
"
assert_empty "the macro guard discards \$(SAFETY_API_KEY) and passes a real key" "$GUARD_RESULT"
echo ""

echo "=============================="
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
echo "=============================="
[ "$TESTS_FAILED" -eq 0 ] && echo -e "${GREEN}Azure DevOps secret-passing contract holds${NC}"
[ "$TESTS_FAILED" -eq 0 ]
