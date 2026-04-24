# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A CI/CD pipeline templates library providing reusable workflows for **GitHub Actions**, **GitLab CI**, and **Azure DevOps** across Go, Python, Java, JavaScript, PHP, Ruby, .NET, Terraform, and Terra CLI. This is **not a runnable application** — it provides templates and scripts consumed by other projects.

## Commands

```bash
make test              # Run all validation tests (Go + Lambda)
make test-go-script    # Test Go validation script only
make test-lambda       # Test Lambda template validation only
make build-and-push NAME=<image> TAG=<tag>  # Build and push a container image
```

Test scripts live in `.github/tests/`. The CI workflow (`.github/workflows/ci.yaml`) validates YAML syntax, script permissions, and runs ShellCheck on all shell scripts.

## Architecture

### 5-Stage Pipeline Model

All platforms follow consistent numbered stages:
1. **10 - Code Check** — Linting, formatting, basic checks (rebase verification, changelog validation)
2. **20 - Security** — SAST (CodeQL, Semgrep, Gitleaks, Hadolint, Trivy) and SCA
3. **30 - Tests** — Unit/integration tests, coverage
4. **35 - Management** — SBOM generation, dependency tracking
5. **40 - Delivery** — Artifact builds, container images
6. **50 - Deployment** — Azure DevOps only (ARM, Lambda, K8s)

### Directory Layout

- `.github/workflows/` — GitHub Actions reusable workflows (e.g., `go-docker.yaml`, `pdm-docker.yaml`)
- `gitlab/<language>/` — GitLab CI templates with `stages/`, `scripts/`, `abstracts/` subdirs
- `azure-devops/<language>/` — Azure DevOps templates, same structure as GitLab
- `global/scripts/tools/` — Platform-agnostic security tools (codeql, gitleaks, semgrep, hadolint, trivy, sonarqube, dependency-track)
- `global/scripts/languages/` — Language-specific scripts (golang, python, terraform). Most `run.sh` scripts follow shared conventions, but the Terraform helpers below are documented exceptions: they write reports directly under `build/reports/` and do not rely on the common `cleanup.sh` / Docker-in-Docker pattern.
  - `terraform/terra-test/` — `terraform test` runner over `modules/*/tests/*.tftest.hcl` (emits JUnit + Markdown/JSON/Cobertura coverage under `build/reports/`)
  - `terraform/terratest/` — Go Terratest runner over `tests/terratest/*.go` (emits JUnit under `build/reports/`)
  - `terraform/test-all/` — unified orchestrator for the first two tiers; runs both when present, merges JUnits into `build/reports/junit-terra-all.xml`, exits `0` when neither tier has tests (stack-only repos)
  - `terraform/structural/` — third tier runner for `tests/structural.sh` (repo-convention assertions the consumer owns); emits `build/reports/junit-structural.xml` (empty-but-valid on skip). Runs on its own parallel job (`test:structural`) instead of through `test-all` because the shell tier is offline and deps-free and shouldn't block on the heavier tiers
- `global/scripts/shared/` — Shared utilities (cleanup.sh, rebase-check.sh, changelog-check.sh)
- `global/containers/` — Docker image definitions for CI environments
- `makefiles/` — Includable `.mk` fragments for downstream projects (`common.mk`, `golang.mk`, `python.mk`, etc.)
- `.docs/examples/` — Complete per-platform usage examples

### Workflow Naming Convention

GitHub Actions workflow files (`.github/workflows/`) are named by **package manager or toolchain**, not by language. The language context is already provided by the directory structure (`github/<language>/stages/`). This matches the naming used in Azure DevOps and GitLab.

| Language   | Toolchain     | Workflow Name       | NOT            |
|------------|---------------|---------------------|----------------|
| Go         | go            | `go-docker.yaml`    | —              |
| Python     | PDM           | `pdm-docker.yaml`   | ~~python-docker.yaml~~ |
| Java       | Gradle        | `gradle-docker.yaml` | ~~java-docker.yaml~~       |
| Java       | Maven         | `maven-docker.yaml`  | ~~java-maven-docker.yaml~~ |
| JavaScript | Yarn          | `yarn-docker.yaml`   | ~~javascript-docker.yaml~~     |
| JavaScript | npm           | `npm-docker.yaml`    | ~~javascript-npm-docker.yaml~~ |
| PHP        | Composer      | `composer-docker.yaml` | ~~php-docker.yaml~~          |
| Ruby       | Bundler       | `bundler-docker.yaml`  | ~~ruby-docker.yaml~~         |
| C#         | dotnet        | `dotnet-docker.yaml` | —              |

When adding a new language or toolchain, always use the toolchain name in the workflow file.

### How Platforms Consume Templates

**GitHub Actions** — Reusable workflows via `uses: 'rios0rios0/pipelines/.github/workflows/<workflow>@main'`

**GitLab CI** — Remote includes via `remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/<lang>/<template>.yaml'`

**Azure DevOps** — Template references via `template: 'azure-devops/<lang>/<template>.yaml@pipelines'` with a `resources.repositories` block

### Script Conventions

All `run.sh` scripts follow this pattern:
- Shebang: `#!/usr/bin/env sh` (POSIX sh, not bash)
- Auto-detect `SCRIPTS_DIR` if not set, using `dirname/realpath` with sed to find the pipelines root
- Source `cleanup.sh` to set up report directory cleanup
- Generate reports to `build/reports/<tool-name>/`
- Use Docker-in-Docker for tool isolation

### Terra Test Tiers

The Terra CLI pipeline test stage exposes two parallel jobs on every platform (Azure DevOps, GitLab CI, GitHub Actions):

1. **`test:all`** — the unified test job, delegates to `global/scripts/languages/terraform/test-all/run.sh` which orchestrates the two heavier tiers:

   | Tier          | Input                              | Tool                             | Output                          |
   |---------------|------------------------------------|----------------------------------|---------------------------------|
   | `terra-test`  | `modules/*/tests/*.tftest.hcl`     | `terraform test -junit-xml`      | `terra-tests.xml`, `terra-coverage.{md,json,xml}` |
   | `terratest`   | `tests/terratest/*.go`             | `go test ./...` + `go-junit-report` | `junit-terratest.xml`         |

2. **`test:structural`** — third-tier shell runner, delegates to `global/scripts/languages/terraform/structural/run.sh`:

   | Tier          | Input                              | Tool                             | Output                          |
   |---------------|------------------------------------|----------------------------------|---------------------------------|
   | `structural`  | `tests/structural.sh` (consumer-owned) | executes the script directly | `junit-structural.xml`          |

The merged JUnit (`junit-terra-all.xml`) is the portable contract for `test:all` — GitLab CI's `artifacts:reports:junit` and GitHub Actions' `upload-artifact` both only take one file. `test:structural` publishes its own `junit-structural.xml` on a separate pipeline surface because it runs on its own job. When a tier has no tests (e.g., a stack-only repo without `modules/`, `tests/terratest/`, or `tests/structural.sh`), the corresponding runner emits an empty-but-valid JUnit and exits `0` so the job passes without a bespoke opt-out. `test:structural` runs on a parallel job rather than through `test-all` because the shell tier is offline and deps-free — queuing it behind the heavier Go / Terraform tiers would waste feedback time.

### Makefile Include Pattern

Downstream projects include pipeline targets via:
```makefile
SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
-include $(SCRIPTS_DIR)/makefiles/common.mk    # setup, sast
-include $(SCRIPTS_DIR)/makefiles/golang.mk     # lint, test
```

The `-include` prefix makes includes optional (no error if pipelines not cloned).

## Contribution Requirements

- Changes **must** work across all three platforms (GitHub Actions, GitLab CI, Azure DevOps)
- Run `make test` before submitting
- **Mandatory updates**: CHANGELOG.md, relevant documentation, and test scenarios for new functionality
- Shell scripts must pass ShellCheck and must be executable (`chmod +x`)
- YAML indentation: 2 spaces, UTF-8, LF line endings (see `.editorconfig`)
