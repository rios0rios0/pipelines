#!/usr/bin/env bash
# Decide which `global/containers/<NAME>.<TAG>` folders the Container Images
# workflow must build, and emit the job matrix for them.
#
# Inputs (environment):
#   EVENT_NAME    GitHub event name (`push` or `workflow_dispatch`).
#   INPUT_FOLDER  `workflow_dispatch` only: one folder name, or empty for all.
#   BEFORE/AFTER  `push` only: the commit range GitHub reported for the push.
#   CONTAINERS_DIR  Folder holding the image folders (default `global/containers`).
#
# Outputs, one `key=value` per line on stdout (the workflow appends them to
# `$GITHUB_OUTPUT`): `has_changes=true|false` and `matrix=<json>`.
#
# A folder is only ever built if it EXISTS at the commit being built. A push that
# deletes or renames a folder still lists the old path in `git diff`, and building
# it fails with `unable to prepare context: path ... not found`; that is exactly
# what happened when `python.3.10-pdm-bullseye` became `python.3.10-pdm-bookworm`.
# A dispatch naming a folder that does not exist fails fast with a clear message
# instead of a buildx context error.
set -euo pipefail

CONTAINERS_DIR="${CONTAINERS_DIR:-global/containers}"
EVENT_NAME="${EVENT_NAME:-push}"
INPUT_FOLDER="${INPUT_FOLDER:-}"
BEFORE="${BEFORE:-}"
AFTER="${AFTER:-HEAD}"

list_all_folders() {
  find "${CONTAINERS_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -u
}

if [ "${EVENT_NAME}" = "workflow_dispatch" ]; then
  if [ -n "${INPUT_FOLDER}" ]; then
    if [ ! -d "${CONTAINERS_DIR}/${INPUT_FOLDER}" ]; then
      echo "ERROR: '${CONTAINERS_DIR}/${INPUT_FOLDER}' does not exist; pick one of:" >&2
      list_all_folders | sed 's/^/  - /' >&2
      exit 1
    fi
    CHANGED_DIRS="${INPUT_FOLDER}"
  else
    CHANGED_DIRS="$(list_all_folders)"
  fi
elif [ -z "${BEFORE}" ] || [ "${BEFORE}" = "0000000000000000000000000000000000000000" ]; then
  # First push of a branch: there is no parent to diff against, build everything.
  CHANGED_DIRS="$(list_all_folders)"
else
  CHANGED_DIRS="$(git diff --name-only "${BEFORE}" "${AFTER}" -- "${CONTAINERS_DIR}/" \
    | awk -F'/' '{if ($3 != "") print $3}' | sort -u)"
fi

# Drop folders that no longer exist (deleted or renamed in this push).
EXISTING_DIRS=""
for DIR in ${CHANGED_DIRS}; do
  if [ -d "${CONTAINERS_DIR}/${DIR}" ]; then
    EXISTING_DIRS="${EXISTING_DIRS}${DIR}"$'\n'
  else
    echo "Skipping '${DIR}': folder no longer exists at ${AFTER}." >&2
  fi
done
CHANGED_DIRS="$(printf '%s' "${EXISTING_DIRS}" | sed '/^$/d')"

if [ -z "${CHANGED_DIRS}" ]; then
  echo "No container changes detected." >&2
  echo "has_changes=false"
  echo 'matrix={"include":[]}'
  exit 0
fi

# Folder naming convention is NAME.TAG: everything before the first dot is the
# image name, everything after it is the tag.
MATRIX_JSON='{"include":['
FIRST=true
for DIR in ${CHANGED_DIRS}; do
  NAME="${DIR%%.*}"
  TAG="${DIR#*.}"
  if [ "${FIRST}" = true ]; then FIRST=false; else MATRIX_JSON+=','; fi
  MATRIX_JSON+="{\"name\":\"${NAME}\",\"tag\":\"${TAG}\"}"
done
MATRIX_JSON+=']}'

echo "Detected container changes: ${MATRIX_JSON}" >&2
echo "has_changes=true"
echo "matrix=${MATRIX_JSON}"
