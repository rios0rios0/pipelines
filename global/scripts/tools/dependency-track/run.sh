#!/usr/bin/env sh
# Set DEBUG=1 to print curl validation logs (URLs, project UUID, and form params).

DT_RESPONSE_FILE=$(mktemp)
trap 'rm -f "$DT_RESPONSE_FILE"' EXIT

bomFile="$PREFIX$REPORT_PATH/bom.json"
projectName=$(cat "$bomFile" | jq -r '.metadata.component.name' | sed 's/\//-/g')
projectVersion=$(cat "$bomFile" | jq -r '.metadata.component.version')

echo "[INFO] bomFile=$bomFile (exists=$([ -f "$bomFile" ] && echo yes || echo no))"
echo "[INFO] projectName=$projectName"
echo "[INFO] projectVersion=$projectVersion"
echo "[INFO] BOM metadata.component:"
jq '.metadata.component' "$bomFile"

export requestApiKey="X-Api-Key: $DEPENDENCY_TRACK_TOKEN"

# normalize base URL (strip trailing slash and trailing /api to avoid /api/api)
baseUrl="${DEPENDENCY_TRACK_HOST_URL%/}"
baseUrl="${baseUrl%/api}"
echo "[INFO] baseUrl=$baseUrl"

# get project UUID from the JSON response
getProjectUrl="$baseUrl/api/v1/project/latest/$projectName"
[ -n "${DEBUG:-}" ] && echo "[DEBUG] GET project: url=$getProjectUrl projectName=$projectName" >&2
httpStatus=$(curl --insecure -s -w '%{http_code}' -o "$DT_RESPONSE_FILE" \
  --request 'GET' "$getProjectUrl" \
  -H 'Content-Type: application/json' -H "$requestApiKey")

if [ "$httpStatus" -ge 400 ]; then
  echo "[WARN] GET $getProjectUrl returned HTTP $httpStatus (project may not exist yet)" >&2
  [ -n "${DEBUG:-}" ] && echo "[DEBUG] GET response body:" >&2 && cat "$DT_RESPONSE_FILE" >&2
  projectUuid=""
else
  projectUuid=$(jq -r '.uuid' "$DT_RESPONSE_FILE")
  [ -n "${DEBUG:-}" ] && echo "[DEBUG] GET project response body:" >&2 && cat "$DT_RESPONSE_FILE" >&2
fi

# guard against jq returning the literal string "null"
if [ "$projectUuid" = "null" ] || [ -z "$projectUuid" ]; then
  projectUuid=""
fi
[ -n "${DEBUG:-}" ] && echo "[DEBUG] projectUuid=${projectUuid:-<empty>}" >&2

requestContentType="Content-Type: multipart/form-data"

bomUploadUrl="$baseUrl/api/v1/bom"

# check if project UUID is not empty
if [ -n "$projectUuid" ]; then
  echo "[INFO] Uploading BOM for existing project (uuid=$projectUuid)"
  [ -n "${DEBUG:-}" ] && echo "[DEBUG] POST bom (existing project): url=$bomUploadUrl projectUuid=$projectUuid projectVersion=$projectVersion bomFile=$bomFile" >&2
  httpStatus=$(curl --insecure -s -w '%{http_code}' -o "$DT_RESPONSE_FILE" \
    --request 'POST' "$bomUploadUrl" \
    -H "$requestContentType" -H "$requestApiKey" \
    -F "project=$projectUuid" \
    -F "projectVersion=$projectVersion" \
    -F 'autoCreate=true' \
    -F 'isLatest=true' \
    -F "bom=@$bomFile")
else
  echo "[INFO] Uploading BOM for new project (name=$projectName)"
  [ -n "${DEBUG:-}" ] && echo "[DEBUG] POST bom (new project): url=$bomUploadUrl projectName=$projectName projectVersion=$projectVersion bomFile=$bomFile" >&2
  httpStatus=$(curl --insecure -s -w '%{http_code}' -o "$DT_RESPONSE_FILE" \
    --request 'POST' "$bomUploadUrl" \
    -H "$requestContentType" -H "$requestApiKey" \
    -F "projectName=$projectName" \
    -F "projectVersion=$projectVersion" \
    -F 'autoCreate=true' \
    -F 'isLatest=true' \
    -F "bom=@$bomFile")
fi

if [ "$httpStatus" -ge 400 ]; then
  echo "[ERROR] POST $bomUploadUrl returned HTTP $httpStatus" >&2
  echo "[ERROR] Response body:" >&2
  cat "$DT_RESPONSE_FILE" >&2
  exit 1
fi

echo "[INFO] POST $bomUploadUrl returned HTTP $httpStatus"
[ -n "${DEBUG:-}" ] && echo "[DEBUG] POST response body:" >&2 && cat "$DT_RESPONSE_FILE" >&2
