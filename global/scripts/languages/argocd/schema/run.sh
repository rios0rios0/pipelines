#!/usr/bin/env sh
set -eu

# GitLab CI/CD leverages this variable to source shared helpers from the
# pipelines checkout. Matches the preamble used by every other run.sh.
if [ -z "${SCRIPTS_DIR:-}" ]; then
  SCRIPTS_DIR="$(echo "$(dirname "$(realpath "$0")")" | sed 's|\(.*\)/global/scripts/.*|\1|')"
  export SCRIPTS_DIR
fi

# Validates the manifests the `render` runner wrote, plus plain manifests
# committed outside any chart, against Kubernetes' and Argo CD's schemas with
# kubeconform, in strict mode: a field the schema does not have is an error,
# which is how a misspelt key in an `Application` is caught before Argo CD
# ignores it. A template can render and still be nothing a cluster would accept.
#
#   ARGOCD_MANIFEST_DIRS        directories of plain manifests, space-separated,
#                               such as `bootstrap`; empty by default. One that
#                               does not exist fails: it was asked for by name
#   ARGOCD_KUBERNETES_VERSION   the Kubernetes version the core kinds are read
#                               for: `1.33.0`, or `master` (the default)
#   ARGOCD_SCHEMA_LOCATIONS     kubeconform schema locations, space-separated,
#                               replacing the two pinned below
#
# A kind no location has a schema for is skipped, not failed, because a chart
# may install any custom resource and no catalog holds them all. That is also
# how this check would go quiet: a location that stops resolving reads as "no
# schema", for everything it served, and the job stays green having validated
# nothing. So before the real run, a small fixed set of resources goes through
# the same locations with skipping OFF, and a kind this family exists to check
# that fails to resolve fails the job.
#
# Reports land in build/reports/argocd-schema/, as `junit-schema.xml`.

# Read before `cleanup.sh` points REPORT_PATH at this tool's own directory.
RENDERED_DIR="${REPORT_PATH:-build/reports}/argocd-render/rendered"

REPORT_PATH="${REPORT_PATH:-}"
TOOL_NAME="argocd-schema" . "${SCRIPTS_DIR}/global/scripts/shared/cleanup.sh"
. "${SCRIPTS_DIR}/global/scripts/shared/pinned-versions.sh"

ARGOCD_MANIFEST_DIRS="${ARGOCD_MANIFEST_DIRS:-}"
ARGOCD_KUBERNETES_VERSION="${ARGOCD_KUBERNETES_VERSION:-master}"

# Assigned apart from the default below because a `}` would end the `${...:-...}`.
PINNED_SCHEMA_LOCATIONS="https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${KUBERNETES_JSON_SCHEMA_VERSION}/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
PINNED_SCHEMA_LOCATIONS="${PINNED_SCHEMA_LOCATIONS} https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRDS_CATALOG_VERSION}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
ARGOCD_SCHEMA_LOCATIONS="${ARGOCD_SCHEMA_LOCATIONS:-${PINNED_SCHEMA_LOCATIONS}}"

# Everything to validate. A repository of plain manifests needs no chart, so a
# render that never ran is only fatal when it leaves nothing to read.
if [ -d "${RENDERED_DIR}" ]; then
  set -- "${RENDERED_DIR}"
else
  set --
  echo "No rendered manifests at ${RENDERED_DIR}: render/run.sh writes them."
fi
for manifest_dir in ${ARGOCD_MANIFEST_DIRS}; do
  if [ ! -d "${manifest_dir}" ]; then
    echo "ERROR: the manifest directory '${manifest_dir}' does not exist." >&2
    exit 1
  fi
  set -- "$@" "${manifest_dir}"
done
if [ "$#" -eq 0 ]; then
  echo "ERROR: nothing to validate: run render/run.sh first, or set ARGOCD_MANIFEST_DIRS." >&2
  exit 1
fi

"${SCRIPTS_DIR}/global/scripts/languages/argocd/kubeconform/install.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

LOCATION_FLAGS=''
for location in ${ARGOCD_SCHEMA_LOCATIONS}; do
  LOCATION_FLAGS="${LOCATION_FLAGS} -schema-location ${location}"
done

# The cache is what lets every run below after the first ask nothing of the
# network. It lives and dies with this job, so it cannot outlive a pin.
run_kubeconform() {
  # shellcheck disable=SC2086 # word splitting is intended: each flag is one word
  kubeconform -strict -kubernetes-version "${ARGOCD_KUBERNETES_VERSION}" -cache "${WORK_DIR}" ${LOCATION_FLAGS} "$@"
}

mkdir -p "${WORK_DIR}/resolves"
cat > "${WORK_DIR}/resolves/resources.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: resolves
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: resolves
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: resolves
spec:
  generators: []
  template:
    metadata: {}
    spec:
      project: default
      destination:
        server: https://kubernetes.default.svc
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: resolves
spec: {}
EOF
if ! run_kubeconform "${WORK_DIR}/resolves/resources.yaml"; then
  echo "ERROR: the schema locations cannot validate the kinds this check exists for, so it would skip them and pass." >&2
  echo "       Locations:          ${ARGOCD_SCHEMA_LOCATIONS}" >&2
  echo "       Kubernetes version: ${ARGOCD_KUBERNETES_VERSION}" >&2
  exit 1
fi

verdict=0
run_kubeconform -ignore-missing-schemas -summary "$@" || verdict=$?

# The same run again for the report: kubeconform writes one output format per
# run, and the log needs the text one. The verdict is the run above.
run_kubeconform -ignore-missing-schemas -output junit "$@" > "${REPORT_PATH}/junit-schema.xml" || true
echo "JUnit report: ${REPORT_PATH}/junit-schema.xml"

exit "${verdict}"
