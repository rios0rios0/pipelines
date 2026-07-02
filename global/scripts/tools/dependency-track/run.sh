#!/usr/bin/env sh
# Set DEBUG=1 to print curl validation logs (URL and form params).

bomFile="$PREFIX$REPORT_PATH/bom.json"

# Skip the upload cleanly when no CycloneDX BOM was produced. This happens
# for consumers without a language-specific BOM generator. Without this
# guard `jq`/`curl` would error on the missing file and red the job.
if [ ! -f "$bomFile" ]; then
  echo "No CycloneDX BOM at $bomFile — skipping Dependency-Track upload."
  exit 0
fi

projectName=$(jq -r '.metadata.component.name' "$bomFile" | sed 's/\//-/g')
projectVersion=$(jq -r '.metadata.component.version' "$bomFile")

# normalize base URL (strip trailing slash and trailing /api to avoid /api/api)
baseUrl="${DEPENDENCY_TRACK_HOST_URL%/}"
baseUrl="${baseUrl%/api}"
bomUploadUrl="$baseUrl/api/v1/bom"

# Upload via the projectName + projectVersion + autoCreate path (an
# idempotent upsert). Dependency-Track's `/api/v1/bom` treats `project`
# (a project UUID) and `projectName`/`projectVersion` as MUTUALLY EXCLUSIVE
# — since 4.12 a request carrying both is rejected with HTTP 400. The
# previous implementation looked up the existing project's UUID and then
# POSTed it *together with* `projectVersion`, so every build after the
# project's first upload failed with 400 (the UUID lookup only misses on
# the very first run, which is why the job was "always breaking"). Sending
# only `projectName` + `projectVersion` with `autoCreate=true` creates the
# project on the first upload and updates it on every subsequent one, while
# `isLatest` flags this version as the collection's latest.
[ -n "${DEBUG:-}" ] && echo "[DEBUG] POST bom: url=$bomUploadUrl projectName=$projectName projectVersion=$projectVersion bomFile=$bomFile" >&2

# Capture the HTTP status and response body instead of `curl --fail`, which
# hides Dependency-Track's error message and leaves only a bare
# `curl: (22) ... 400` in the log. On failure the body is echoed so the
# actual rejection reason is visible in the pipeline output.
responseFile="${TMPDIR:-/tmp}/dependency-track-response.$$"
httpStatus=$(curl --insecure --silent --show-error \
  --output "$responseFile" --write-out '%{http_code}' \
  --request POST "$bomUploadUrl" \
  -H "X-Api-Key: $DEPENDENCY_TRACK_TOKEN" \
  -F "projectName=$projectName" \
  -F "projectVersion=$projectVersion" \
  -F 'autoCreate=true' \
  -F 'isLatest=true' \
  -F "bom=@$bomFile")

# `--write-out` always prints a status; `000` means curl never received an
# HTTP response (DNS/TLS/connection failure).
if [ "${httpStatus:-000}" -ge 200 ] && [ "${httpStatus:-000}" -lt 300 ]; then
  echo "Uploaded BOM to Dependency-Track (projectName=$projectName projectVersion=$projectVersion, HTTP $httpStatus)."
  rm -f "$responseFile"
else
  echo "ERROR: Dependency-Track rejected the BOM upload (HTTP $httpStatus). Response body:" >&2
  [ -s "$responseFile" ] && sed 's/^/  | /' "$responseFile" >&2
  rm -f "$responseFile"
  exit 1
fi
