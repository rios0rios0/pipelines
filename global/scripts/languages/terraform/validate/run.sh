#!/usr/bin/env sh
set -eu

# GitLab CI/CD leverages this variable to source shared helpers from the
# pipelines checkout. Matches the preamble used by every other run.sh.
if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*pipelines\).*|\1|')"
  export SCRIPTS_DIR
fi

# Runs `terraform validate` over every root module in the repository and
# publishes the results as JUnit XML.
#
# WHY THIS TIER EXISTS, given three test tiers already ship here. None of them
# resolves a reference:
#
#   terra-test    runs `terraform test` over `modules/*/tests/*.tftest.hcl`.
#                 Only covers reusable modules, and only those that have a test
#                 file. A root module is never its subject.
#   terratest     a Go suite that parses HCL offline. A parser answers "is this
#                 syntactically valid HCL", not "does this identifier exist" --
#                 it has no evaluation context, no module graph, no schema.
#   structural    bash convention assertions. Same limitation by construction.
#
# So a root module can reference a module, variable, resource or output that
# does not exist and every tier stays green. The class of defect this catches:
#
#   Error: Reference to undeclared module
#   Error: Reference to undeclared resource
#   Error: Unsupported argument / Missing required argument
#
# These are not subtle at runtime -- they fail EVERY plan and apply of that root
# module, for every target, before a single resource is touched. They are simply
# invisible to a parser. The usual way one lands is a rename or deletion that
# updates the definition and the obvious call sites but misses one file.
#
# `-backend=false` is what makes this affordable as a test rather than a
# deployment step: no backend credentials, no state access, no cloud login. It
# still needs to download providers, and to resolve module sources -- which for
# private sources means the caller must have configured credentials first (the
# pipeline stage exposes a pre-steps hook for exactly that).
#
# Skipped silently (exit 0) when the configured roots do not exist, matching the
# opt-in contract of the sibling `terra-test`, `terratest` and `structural`
# runners -- a consumer without root modules does not see a broken stage.

REPORT_PATH="${REPORT_PATH:-build/reports}"
JUNIT="${REPORT_PATH}/junit-validate.xml"

# Space-separated list of directories to search for root modules. Defaults to
# `stacks`, the conventional home for root modules in a repository that also
# keeps reusable modules under `modules/`. Reusable modules are deliberately NOT
# validated by default: they are covered by `terra-test`, they are numerous, and
# each one costs its own provider download.
VALIDATE_ROOTS="${VALIDATE_ROOTS:-stacks}"

mkdir -p "${REPORT_PATH}"

emit_empty_junit() {
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="validate"/>\n' > "${JUNIT}"
}

if ! command -v terraform > /dev/null 2>&1; then
  echo "ERROR: terraform not found on PATH; cannot run the validate tier." >&2
  exit 1
fi

# Collect candidate root modules: any directory holding at least one `.tf` file.
# `.terraform` is excluded because `terraform init` vendors module sources there
# -- validating those would re-validate every dependency, from a directory the
# consumer does not own.
existing_roots=''
for root in ${VALIDATE_ROOTS}; do
  if [ -d "${root}" ]; then
    existing_roots="${existing_roots} ${root}"
  fi
done

if [ -z "${existing_roots}" ]; then
  echo "None of the configured roots (${VALIDATE_ROOTS}) exist; skipping validate runner."
  emit_empty_junit
  exit 0
fi

# shellcheck disable=SC2086 # word splitting is intended: these are separate paths
directories="$(find ${existing_roots} -type f -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; | sort -u)"

if [ -z "${directories}" ]; then
  echo "No root modules found under ${VALIDATE_ROOTS}; skipping validate runner."
  emit_empty_junit
  exit 0
fi

# One shared provider cache across every root module IN THIS RUN. Without it each
# directory re-downloads the same providers, which dominates the runtime of this
# tier -- a repository with dozens of root modules pulling the same handful of
# providers would otherwise spend minutes on redundant network I/O.
#
# The default is deliberately WORKSPACE-relative and not `$HOME`-relative.
# Terraform's plugin cache is NOT safe for concurrent use, and `$HOME` is exactly
# the directory that is shared when a CI host runs more than one job at a time:
# self-hosted runners commonly place several agents side by side under a single
# service account, so two agents on one machine get separate workspaces but
# the same `$HOME`. Two jobs initialising at once then write the same provider
# binary, and both fail in ways that do not name the cause --
#
#   Error: Failed to install provider ... : text file busy
#   Error: ... the cached package for ... does not match any of the checksums
#          recorded in the dependency lock file
#
# -- the first when one process execs a binary another is still copying, the
# second when a partially-written cache entry is linked into `.terraform`.
# Neither mentions the cache, so the failure reads as a corrupt lock file or a
# flaky registry. Keeping the cache inside the checkout means concurrent jobs
# cannot collide, while every root module in a single run still shares it, which
# is where the saving actually came from.
#
# An explicitly exported `TF_PLUGIN_CACHE_DIR` still wins, so an operator who
# knows their jobs are serialised can point it at a durable shared location.
if [ -z "${TF_PLUGIN_CACHE_DIR:-}" ]; then
  TF_PLUGIN_CACHE_DIR="$(pwd)/build/.terraform-plugin-cache"
  export TF_PLUGIN_CACHE_DIR
fi
mkdir -p "${TF_PLUGIN_CACHE_DIR}"

# Escape the five XML predefined entities so a Terraform diagnostic containing
# `<`, `&` or a quote cannot produce a malformed report. The ampersand must be
# replaced FIRST -- doing it after would re-escape the ampersands introduced by
# the other replacements and render `&amp;lt;` instead of `&lt;`.
escape_xml() {
  sed -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

total=0
failed=0
cases_file="$(mktemp)"
trap 'rm -f "${cases_file}"' EXIT

for directory in ${directories}; do
  total=$((total + 1))
  printf 'Validating %s ... ' "${directory}"

  output_file="$(mktemp)"
  if terraform -chdir="${directory}" init -backend=false -input=false -no-color > "${output_file}" 2>&1 \
    && terraform -chdir="${directory}" validate -no-color >> "${output_file}" 2>&1; then
    echo 'ok'
    printf '    <testcase classname="validate" name="%s"/>\n' \
      "$(printf '%s' "${directory}" | escape_xml)" >> "${cases_file}"
  else
    echo 'FAILED'
    failed=$((failed + 1))
    # Echo the diagnostic to the job log as well as the report: a reader
    # scanning the log should not have to open an artifact to see the reason.
    cat "${output_file}"
    {
      printf '    <testcase classname="validate" name="%s">\n' \
        "$(printf '%s' "${directory}" | escape_xml)"
      printf '      <failure message="terraform validate failed"><![CDATA[\n'
      # `]]>` inside the diagnostic would close the CDATA section early; split it
      # across two sections, which is the only way to represent it.
      sed 's/]]>/]]]]><![CDATA[>/g' "${output_file}"
      printf '\n]]></failure>\n    </testcase>\n'
    } >> "${cases_file}"
  fi
  rm -f "${output_file}"
done

{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<testsuites name="validate" tests="%s" failures="%s">\n' "${total}" "${failed}"
  printf '  <testsuite name="validate" tests="%s" failures="%s">\n' "${total}" "${failed}"
  cat "${cases_file}"
  printf '  </testsuite>\n'
  printf '</testsuites>\n'
} > "${JUNIT}"

echo "Validated ${total} root module(s): $((total - failed)) passed, ${failed} failed."
echo "JUnit report: ${JUNIT}"

if [ "${failed}" -gt 0 ]; then
  exit 1
fi
