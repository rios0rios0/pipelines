# Tools

This directory contains **language-agnostic** security and quality tools used across all project types. Each tool has its own subdirectory with a `run.sh` script and optional configuration files (e.g., false-positive lists, ignore patterns).

## Contents

| Tool                | Purpose                                                            |
|---------------------|--------------------------------------------------------------------|
| `codeql/`           | Static Application Security Testing (SAST)                         |
| `dependency-track/` | Software Composition Analysis (SCA) tracking                       |
| `gitleaks/`         | Secret and credential detection in Git history                     |
| `hadolint/`         | Dockerfile linting and best practices                              |
| `semgrep/`          | Pattern-based static analysis (OWASP, secrets, best practices)     |
| `sonarqube/`        | Code quality and security analysis                                 |
| `trivy/`            | Infrastructure-as-Code misconfiguration and vulnerability scanning |

## Convention

- Each tool directory contains a `run.sh` entry point.
- Configuration files (e.g., `.gitleaks.toml`, `.hadolint.yaml`, `.trivyignore`) are stored alongside the script.
- These tools are invoked by CI pipelines (GitHub Actions, GitLab CI, Azure DevOps) and by local Makefiles.

For **language-specific** tools (e.g., golangci-lint, checkstyle, goreleaser), see [`../languages/`](../languages/).
