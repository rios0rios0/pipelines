#!/usr/bin/env bash
set -e

# Script to build cross-platform Go binaries using GoReleaser
# This script will be used by the GitHub Actions workflow

# GitLab CI/CD steps/jobs leverages this variable to perform other commands
if [ -z "$SCRIPTS_DIR" ]; then
  export SCRIPTS_DIR="$(echo $(dirname "$(realpath "$0")") | sed 's|\(.*pipelines\).*|\1|')"
fi

GORELEASER_VERSION=${GORELEASER_VERSION:-"1.26.2"}
BINARY_NAME=${BINARY_NAME:-"app"}

echo "Installing GoReleaser version $GORELEASER_VERSION..."

# Install GoReleaser
if ! command -v goreleaser &> /dev/null; then
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        curl -sL "https://github.com/goreleaser/goreleaser/releases/download/v${GORELEASER_VERSION}/goreleaser_${GORELEASER_VERSION}_amd64.deb" -o /tmp/goreleaser.deb
        sudo dpkg -i /tmp/goreleaser.deb
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        brew install goreleaser/tap/goreleaser
    else
        # Fallback to binary installation
        curl -sL "https://github.com/goreleaser/goreleaser/releases/download/v${GORELEASER_VERSION}/goreleaser_Linux_x86_64.tar.gz" | tar -xz -C /tmp
        sudo mv /tmp/goreleaser /usr/local/bin/
    fi
fi

# Create GoReleaser config if it doesn't exist
if [ ! -f .goreleaser.yaml ] && [ ! -f .goreleaser.yml ]; then
    echo "Creating default .goreleaser.yaml configuration..."
    cat > .goreleaser.yaml << EOF
project_name: $BINARY_NAME

before:
  hooks:
    - go mod tidy
    - go generate ./...

builds:
  - id: $BINARY_NAME
    main: ./cmd/$BINARY_NAME
    binary: $BINARY_NAME
    goos:
      - linux
      - darwin
      - windows
    goarch:
      - amd64
      - arm64
    ignore:
      - goos: windows
        goarch: arm64
    env:
      - CGO_ENABLED=0
    flags:
      - -trimpath
    ldflags:
      - -s -w
      - -X main.version={{.Version}}
      - -X main.commit={{.Commit}}
      - -X main.date={{.Date}}

archives:
  - id: $BINARY_NAME
    builds:
      - $BINARY_NAME
    name_template: >-
      {{ .ProjectName }}_
      {{- title .Os }}_
      {{- if eq .Arch "amd64" }}x86_64
      {{- else if eq .Arch "386" }}i386
      {{- else }}{{ .Arch }}{{ end }}
      {{- if .Arm }}v{{ .Arm }}{{ end }}
    format_overrides:
      - goos: windows
        format: zip

checksum:
  name_template: 'checksums.txt'

snapshot:
  name_template: "{{ incpatch .Version }}-next"

changelog:
  sort: asc
  filters:
    exclude:
      - '^docs:'
      - '^test:'

release:
  github:
    owner: '{{ .Env.GITHUB_REPOSITORY_OWNER }}'
    name: '{{ .Env.GITHUB_REPOSITORY_NAME }}'
  name_template: "Release {{.Tag}}"
  draft: false
  prerelease: auto
  mode: replace
EOF
fi

echo "Building cross-platform binaries with GoReleaser..."
if [[ -n "${GITHUB_ACTIONS}" ]]; then
    # In GitHub Actions, use the token for releases
    export GITHUB_TOKEN="${GITHUB_TOKEN}"
    goreleaser release --clean
else
    # For local development or other CI
    goreleaser build --clean --snapshot
fi

echo "GoReleaser build completed successfully!"