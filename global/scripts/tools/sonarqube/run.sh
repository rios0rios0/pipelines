#!/usr/bin/env sh
set -e

version=$(git describe --tags --abbrev=0) || true
if [ -z "$version" ]; then version="latest"; echo "No version tag found in the repository, setting version to $version"; fi
echo "sonar.projectVersion=$version" >> sonar-project.properties
echo "Updated sonar.projectVersion to $version"

sonar-scanner
