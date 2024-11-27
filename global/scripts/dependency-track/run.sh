#!/usr/bin/env sh

# read and sanitize project name
bomFile="$PREFIX$REPORT_PATH/bom.json"
projectName=$(cat "$bomFile" | jq -r '.metadata.component.name' | sed 's/\//-/g')
projectVersion=$(cat "$bomFile" | jq -r '.metadata.component.version')

export requestApiKey="X-Api-Key: $DEPENDENCY_TRACK_TOKEN"

# get project UUID from the JSON response
projectUuid=$(curl --insecure --fail --request 'GET' "$DEPENDENCY_TRACK_HOST_URL/api/v1/project/latest/$projectName" \
  -H 'Content-Type: application/json' -H "$requestApiKey" | jq -r '.uuid')

requestContentType="Content-Type: multipart/form-data"

# check if project UUID is not empty
if [ -n "$projectUuid" ]; then
  curl --insecure --fail --request 'POST' "$DEPENDENCY_TRACK_HOST_URL/api/v1/bom" \
    -H "$requestContentType" -H "$requestApiKey" \
    -F "project=$projectUuid" \
    -F "projectVersion=$projectVersion" \
	  -F 'autoCreate=true' \
    -F 'isLatest=true' \
    -F "bom=@$bomFile"
else
  curl --insecure --fail --request 'POST' "$DEPENDENCY_TRACK_HOST_URL/api/v1/bom" \
    -H "$requestContentType" -H "$requestApiKey" \
    -F "projectName=$projectName" \
    -F "projectVersion=$projectVersion" \
    -F 'autoCreate=true' \
	  -F 'isLatest=true' \
    -F "bom=@$bomFile"
fi
