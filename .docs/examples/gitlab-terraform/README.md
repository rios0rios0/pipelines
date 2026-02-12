# GitLab CI -- Terraform Example

Minimal example showing how to use the Terraform pipeline template from `rios0rios0/pipelines`.

## Files

| File | Purpose |
|------|---------|
| `.gitlab-ci.yml` | Includes the remote `terra.yaml` pipeline template |
| `Makefile` | Local development with pipeline tools via `makefiles/` includes |

## Setup

1. Copy `.gitlab-ci.yml` into your repository root.
2. Configure the required GitLab CI/CD variables in your project settings.
3. Push to `main` or open a merge request to trigger the pipeline.

## Local Development

```bash
# First-time setup -- clone the pipelines repository
curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash

# Then use the Makefile targets
make lint       # Run terraform fmt + validate
make test       # Run terraform plan
make sast       # Run security analysis
make security   # Run all security tools at once
```

## What the Pipeline Does

1. **Code Check** -- terraform fmt, TFLint
2. **Security** -- Semgrep, Gitleaks, Hadolint, Trivy
3. **Management** -- SonarQube, Dependency Track
