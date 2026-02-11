# Azure DevOps -- Go with Docker Example

Minimal example showing how to use the Go + Docker pipeline template from `rios0rios0/pipelines` via Azure DevOps template references.

## Files

| File | Purpose |
|------|---------|
| `azure-pipelines.yml` | References the shared Go Docker pipeline template |
| `Makefile` | Local development with pipeline tools via `makefiles/` includes |

## Setup

1. Copy `azure-pipelines.yml` into your repository root.
2. In Azure DevOps, create a **GitHub service connection** that points to `rios0rios0/pipelines`.
3. Replace `YOUR_GITHUB_SERVICE_CONNECTION` in the pipeline file with your service connection name.
4. Create variable groups (`production-variables`, `development-variables`) with your Docker registry credentials.
5. Create a new pipeline in Azure DevOps pointing to `azure-pipelines.yml`.

## Local Development

```bash
# First-time setup -- clone the pipelines repository
curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash

# Then use the Makefile targets
make lint       # Run golangci-lint with auto-fix
make test       # Run Go tests with coverage
make sast       # Run CodeQL security analysis
make security   # Run all security tools at once
```

## What the Pipeline Does

1. **Code Check** -- golangci-lint
2. **Security** -- CodeQL, Semgrep, Gitleaks, Hadolint, Trivy
3. **Tests** -- Go test with coverage reporting
4. **Management** -- SonarQube, Dependency Track, CycloneDX SBOM
5. **Delivery** -- Docker image build and push
