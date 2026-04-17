#!/usr/bin/env sh
# Set DEBUG=1 to print curl validation logs (URLs, project UUID, and form params).

# read and sanitize project name
bomFile="$PREFIX$REPORT_PATH/bom.json"

# Skip the upload cleanly when no CycloneDX BOM was produced. This happens
# for consumers without a language-specific BOM generator (e.g., Terraform
# — see `azure-devops/terra/stages/35-management/terra.yaml` where the
# job still carries a `TODO: Missing CycloneDX for Terraform` marker).
# Without this guard, `cat` errored with `No such file or directory` and
# the downstream `curl` failed with HTTP 401 on an empty upload, turning
# the job red on every build.
if [ ! -f "$bomFile" ]; then
  echo "No CycloneDX BOM at $bomFile — skipping Dependency-Track upload."
  exit 0
fi

projectName=$(cat "$bomFile" | jq -r '.metadata.component.name' | sed 's/\//-/g')
projectVersion=$(cat "$bomFile" | jq -r '.metadata.component.version')

export requestApiKey="X-Api-Key: $DEPENDENCY_TRACK_TOKEN"

# normalize base URL (strip trailing slash and trailing /api to avoid /api/api)
baseUrl="${DEPENDENCY_TRACK_HOST_URL%/}"
baseUrl="${baseUrl%/api}"

# get project UUID from the JSON response
getProjectUrl="$baseUrl/api/v1/project/latest/$projectName"
[ -n "${DEBUG:-}" ] && echo "[DEBUG] GET project: url=$getProjectUrl projectName=$projectName" >&2
projectUuid=$(curl --insecure --fail --request 'GET' "$getProjectUrl" \
  -H 'Content-Type: application/json' -H "$requestApiKey" | jq -r '.uuid')
[ -n "${DEBUG:-}" ] && echo "[DEBUG] GET project response: projectUuid=${projectUuid:-<empty>}" >&2

requestContentType="Content-Type: multipart/form-data"

bomUploadUrl="$baseUrl/api/v1/bom"

# check if project UUID is not empty
if [ -n "$projectUuid" ]; then
  [ -n "${DEBUG:-}" ] && echo "[DEBUG] POST bom (existing project): url=$bomUploadUrl projectUuid=$projectUuid projectVersion=$projectVersion bomFile=$bomFile" >&2
  curl --insecure --fail --request 'POST' "$bomUploadUrl" \
    -H "$requestContentType" -H "$requestApiKey" \
    -F "project=$projectUuid" \
    -F "projectVersion=$projectVersion" \
	  -F 'autoCreate=true' \
    -F 'isLatest=true' \
    -F "bom=@$bomFile"
else
  [ -n "${DEBUG:-}" ] && echo "[DEBUG] POST bom (new project): url=$bomUploadUrl projectName=$projectName projectVersion=$projectVersion bomFile=$bomFile" >&2
  curl --insecure --fail --request 'POST' "$bomUploadUrl" \
    -H "$requestContentType" -H "$requestApiKey" \
    -F "projectName=$projectName" \
    -F "projectVersion=$projectVersion" \
    -F 'autoCreate=true' \
	  -F 'isLatest=true' \
    -F "bom=@$bomFile"
fi
