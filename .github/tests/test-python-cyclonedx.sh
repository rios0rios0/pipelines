#!/usr/bin/env bash
# Exercise SBOM version resolution without installing PDM or accessing a registry.
# The handwritten PDM double supplies CycloneDX output and build-backend results;
# jq and the production shell script still run normally.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINES_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CYCLONEDX_SCRIPT="$PIPELINES_ROOT/global/scripts/languages/python/cyclonedx/run.sh"
TEST_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"

cat > "$TEST_DIR/bin/pdm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1 ${2:-}" in
  'info --python') printf '/usr/bin/python3\n' ;;
  'run cyclonedx-py')
    if [[ "${CYCLONEDX_STATUS:-0}" != 0 ]]; then
      echo 'fixture: CycloneDX generation failed' >&2
      exit "$CYCLONEDX_STATUS"
    fi
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == '-o' ]]; then
        cp "$BOM_FIXTURE" "$2"
        exit 0
      fi
      shift
    done
    exit 2
    ;;
  'show --version')
    if [[ "${PDM_VERSION_STATUS:-0}" != 0 ]]; then
      echo '[PdmUsageError]: This project is not a library' >&2
      exit "$PDM_VERSION_STATUS"
    fi
    printf '%s\n' "${PDM_VERSION:-}"
    ;;
  *) echo "Unexpected PDM invocation: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/pdm"

new_project() {
  local project
  project="$(mktemp -d "$TEST_DIR/project-XXXXXX")" || exit 1
  cat > "$project/pyproject.toml" <<'TOML'
[project]
name = "fixture-application"
version = "1.2.3"
dependencies = []
[tool.pdm]
distribution = false
TOML
  cat > "$project/fixture.json" <<'JSON'
{
  "metadata": {"component": {"name": "fixture-application", "type": "application", "bom-ref": "root", "version": "1.2.3"}},
  "components": [{"name": "fixture-dependency", "bom-ref": "dependency", "version": "2.0.0", "type": "library"}],
  "dependencies": [{"ref": "root", "dependsOn": ["dependency"]}]
}
JSON
  printf '%s\n' "$project"
}

run_generator() {
  local project="$1"
  (
    cd "$project" || exit 1
    PATH="$TEST_DIR/bin:$PATH" \
      SCRIPTS_DIR="$PIPELINES_ROOT" PREFIX='' REPORT_PATH='build/reports' \
      BOM_FIXTURE="$project/fixture.json" \
      sh "$CYCLONEDX_SCRIPT" > "$project/output.log" 2>&1
  )
}

# given a script-only project whose PDM metadata command refuses to run
project="$(new_project)"
# when the generator supplies the static PEP 621 version
PDM_VERSION_STATUS=1 run_generator "$project"
# then its identity, graph and components survive without calling PDM metadata
diff -u <(jq -S . "$project/fixture.json") <(jq -S . "$project/build/reports/bom.json")
echo 'PASS: should preserve the static version when the project is not a distribution'

# given a library whose generated SBOM carries a static version
project="$(new_project)"
sed -i 's/distribution = false/distribution = true/' "$project/pyproject.toml"
# when PDM would return a different installed version
PDM_VERSION=9.9.9 run_generator "$project"
# then the declared project version remains authoritative
jq -e '.metadata.component.version == "1.2.3"' "$project/build/reports/bom.json" > /dev/null
echo 'PASS: should retain the declared static version when PDM reports another version'

for absent_version in 'del(.metadata.component.version)' '.metadata.component.version = null' '.metadata.component.version = ""'; do
  # given a backend-versioned library without a version in CycloneDX metadata
  project="$(new_project)"
  sed -i -e 's/version = "1.2.3"/dynamic = ["version"]/' -e 's/distribution = false/distribution = true/' "$project/pyproject.toml"
  jq "$absent_version" "$project/fixture.json" > "$project/dynamic.json"
  mv "$project/dynamic.json" "$project/fixture.json"
  # when the backend resolves its version
  PDM_VERSION=4.5.6 run_generator "$project"
  # then only the root version changes
  diff -u <(jq -S '.metadata.component.version = "4.5.6"' "$project/fixture.json") \
    <(jq -S . "$project/build/reports/bom.json")
  echo "PASS: should resolve a dynamic version when $absent_version"
done

# given a project whose backend cannot resolve a missing version
project="$(new_project)"
jq 'del(.metadata.component.version)' "$project/fixture.json" > "$project/dynamic.json"
mv "$project/dynamic.json" "$project/fixture.json"
# when PDM fails
if PDM_VERSION_STATUS=1 run_generator "$project"; then
  echo 'FAIL: an unresolved version was accepted' >&2
  exit 1
fi
# then the original cause and actionable version error remain visible
grep -Fq '[PdmUsageError]: This project is not a library' "$project/output.log"
grep -Fq 'could not resolve the SBOM project version' "$project/output.log"
echo 'PASS: should report the backend error when version resolution fails'

for empty_version in '' '   '; do
  # given no version in the generated metadata
  project="$(new_project)"
  jq 'del(.metadata.component.version)' "$project/fixture.json" > "$project/dynamic.json"
  mv "$project/dynamic.json" "$project/fixture.json"
  # when the backend exits successfully without a usable version
  if PDM_VERSION="$empty_version" run_generator "$project"; then
    echo 'FAIL: an empty version was accepted' >&2
    exit 1
  fi
  # then no unversioned upload can proceed
  grep -Fq 'the SBOM project version is empty' "$project/output.log"
  echo 'PASS: should reject an empty or whitespace-only backend version'
done

# given a failing CycloneDX generator
project="$(new_project)"
# when generation fails before version resolution
if CYCLONEDX_STATUS=7 run_generator "$project"; then
  echo 'FAIL: generation failure was ignored' >&2
  exit 1
fi
# then generation remains fatal and no BOM is published
grep -Fq 'fixture: CycloneDX generation failed' "$project/output.log"
test ! -e "$project/build/reports/bom.json"
echo 'PASS: should fail when CycloneDX cannot generate the BOM'
