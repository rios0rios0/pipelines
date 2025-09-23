# GoLang Binary Release and Bump Example

This example demonstrates how to use the enhanced GoLang binary pipeline with automatic version bumping and cross-platform releases.

## Basic Usage

Create a workflow file in your repository (e.g., `.github/workflows/release.yaml`):

```yaml
name: 'GoLang Binary Release'

on:
  push:
    branches: [ main ]
    tags: [ 'v*' ]
  pull_request:
    branches: [ main ]
  workflow_dispatch:
    inputs:
      bump_type:
        description: 'Version bump type'
        required: true
        default: 'patch'
        type: choice
        options:
          - patch
          - minor
          - major

permissions:
  contents: write      # Required for creating releases and tags
  packages: write      # Required for GitHub packages

jobs:
  release:
    uses: 'rios0rios0/pipelines/.github/workflows/go-binary.yaml@main'
    with:
      binary_name: 'myapp'           # Your binary name (must match cmd/myapp/)
      bump_type: '${{ inputs.bump_type || "patch" }}'
      use_goreleaser: true           # Use GoReleaser for cross-platform builds
```

## Project Structure

Your Go project should follow this structure:

```
your-project/
├── cmd/
│   └── myapp/           # Your binary name
│       └── main.go
├── pkg/
│   └── ...              # Your packages
├── internal/
│   └── ...              # Internal packages
├── go.mod
├── go.sum
└── .github/
    └── workflows/
        └── release.yaml
```

## How It Works

### 1. Manual Version Bump

When you trigger the workflow manually (workflow_dispatch):
1. The pipeline runs tests and security checks
2. Creates a new version tag (v1.2.3)
3. Pushes the tag to trigger the release build

### 2. Automatic Release on Tags

When a tag is pushed (either manually or via bump):
1. GoReleaser builds binaries for multiple platforms:
   - Linux (amd64, arm64)
   - macOS (amd64, arm64)
   - Windows (amd64)
2. Creates a GitHub release
3. Uploads all binaries and checksums to the release

### 3. Cross-Platform Binaries

With `use_goreleaser: true`, you get:
- `myapp_Linux_x86_64.tar.gz`
- `myapp_Linux_arm64.tar.gz`
- `myapp_Darwin_x86_64.tar.gz`
- `myapp_Darwin_arm64.tar.gz`
- `myapp_Windows_x86_64.zip`
- `checksums.txt`

## Configuration Options

### GoReleaser Configuration

The pipeline automatically creates a `.goreleaser.yaml` file if none exists. You can customize it by creating your own:

```yaml
# .goreleaser.yaml
project_name: myapp

builds:
  - id: myapp
    main: ./cmd/myapp
    binary: myapp
    goos:
      - linux
      - darwin
      - windows
    goarch:
      - amd64
      - arm64
    env:
      - CGO_ENABLED=0
    ldflags:
      - -s -w
      - -X main.version={{.Version}}
      - -X main.commit={{.Commit}}
      - -X main.date={{.Date}}

archives:
  - name_template: >-
      {{ .ProjectName }}_
      {{- title .Os }}_
      {{- if eq .Arch "amd64" }}x86_64
      {{- else }}{{ .Arch }}{{ end }}
    format_overrides:
      - goos: windows
        format: zip

changelog:
  sort: asc
  filters:
    exclude:
      - '^docs:'
      - '^test:'
```

### Simple Binary Build

If you prefer single-platform builds, set `use_goreleaser: false`:

```yaml
jobs:
  release:
    uses: 'rios0rios0/pipelines/.github/workflows/go-binary.yaml@main'
    with:
      binary_name: 'myapp'
      use_goreleaser: false    # Uses simple go build
```

## Version Injection

The pipeline automatically injects version information into your binary. Add these variables to your `main.go`:

```go
package main

import (
    "fmt"
    "os"
)

var (
    version = "dev"
    commit  = "none"
    date    = "unknown"
)

func main() {
    if len(os.Args) > 1 && os.Args[1] == "--version" {
        fmt.Printf("%s version %s (commit: %s, built: %s)\n", 
            os.Args[0], version, commit, date)
        return
    }
    
    // Your application logic here
    fmt.Println("Hello, World!")
}
```

## Release Notes

The pipeline automatically generates release notes from your git commit messages. For better release notes, follow conventional commits:

```
feat: add new feature
fix: resolve bug in authentication
docs: update README
```

## Manual Tag Creation

You can also create tags manually:

```bash
git tag v1.2.3
git push origin v1.2.3
```

This will trigger the release build without the bump step.