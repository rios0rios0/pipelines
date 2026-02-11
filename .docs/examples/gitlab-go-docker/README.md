# GitLab CI -- Go with Docker Example

Minimal example showing how to use the Go + Docker pipeline template from `rios0rios0/pipelines` via GitLab remote includes.

## Files

| File | Purpose |
|------|---------|
| `.gitlab-ci.yml` | Includes the remote Go Docker pipeline template |
| `Makefile` | Local development with pipeline tools via `makefiles/` includes |

## Setup

1. Copy `.gitlab-ci.yml` into your repository root.
2. Configure the following CI/CD variables in your GitLab project settings:

| Variable | Description | Required For |
|----------|-------------|--------------|
| `SONAR_HOST_URL` | SonarQube server URL | Code quality |
| `SONAR_TOKEN` | SonarQube authentication token | Code quality |
| `DOCKER_REGISTRY` | Container registry URL | Docker delivery |
| `DOCKER_USERNAME` | Registry username | Docker delivery |
| `DOCKER_PASSWORD` | Registry password | Docker delivery |

3. Push to trigger the pipeline.

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
