# GitHub Actions -- Go with Docker Example

Minimal example showing how to use the reusable Go + Docker workflow from `rios0rios0/pipelines`.

## Files

| File | Purpose |
|------|---------|
| `.github/workflows/ci.yaml` | Calls the reusable `go-docker.yaml` workflow |
| `Makefile` | Local development with pipeline tools via `makefiles/` includes |

## Setup

1. Copy `.github/workflows/ci.yaml` into your repository.
2. Ensure the repository has the required permissions (see the `permissions` block).
3. Push to `main` or open a pull request to trigger the pipeline.

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
4. **Delivery** -- Docker image build and push to `ghcr.io`
