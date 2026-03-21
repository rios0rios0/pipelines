# CI/CD Pipeline Templates Repository

**ALWAYS FOLLOW THESE INSTRUCTIONS FIRST.** Only fallback to additional search and context gathering if the information in these instructions is incomplete or found to be in error.

This repository provides comprehensive SDLC pipeline templates for GitHub Actions, GitLab CI, and Azure DevOps across multiple programming languages including GoLang, Java, Python, JavaScript, PHP, Ruby, and .NET.

## Quick Reference

**Essential Commands:**
- `make test` - Run all validation tests
- `make test-go-script` - Test Go script changes specifically
- `make test-yaml-merge` - Test YAML merge validation specifically
- `bash global/scripts/shared/cleanup.sh` - Clean up build reports
- `docker --version && make --version && go version` - Check dependencies

**Common Pipeline Usage:**
- **GitHub Actions:** Use `.github/workflows/go-docker.yaml@main`, `pdm-docker.yaml@main`, `java-docker.yaml@main`, `java-maven-docker.yaml@main`, `javascript-docker.yaml@main`, `javascript-npm-docker.yaml@main`, `php-docker.yaml@main`, `ruby-docker.yaml@main`, `dotnet-docker.yaml@main`
- **GitLab CI:** Include `gitlab/golang/go-docker.yaml`, `gitlab/terraform/terra.yaml` from this repo
- **Azure DevOps:** Template `azure-devops/golang/go-docker.yaml@pipelines`

**SAST Tools:** Gitleaks, CodeQL, Semgrep, Hadolint, Trivy IaC
**SCA Tools:** Trivy SCA (all languages), govulncheck (Go), Safety (Python), OWASP Dependency-Check (Java), yarn npm audit (JavaScript/Yarn), npm audit (JavaScript/npm), Composer Audit (PHP), bundler-audit (Ruby)
**Quality Tools:** SonarQube, Dependency Track
**Performance:** Security scans 2-10min, Container builds 5-30min
**Architecture:** 5-stage pipeline (Code Check [lint + basic-checks] → Security → Tests → Management → Delivery)

## Working Effectively

### Bootstrap and Setup
- **Using the clone script (recommended, idempotent -- clones or pulls):**
  ```bash
  curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash
  ```

- **Manual clone:**
  ```bash
  mkdir -p $HOME/Development/github.com/rios0rios0
  cd $HOME/Development/github.com/rios0rios0
  git clone https://github.com/rios0rios0/pipelines.git
  ```

- **Makefile integration (for downstream projects):**
  ```makefile
  SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
  -include $(SCRIPTS_DIR)/makefiles/golang.mk
  -include $(SCRIPTS_DIR)/makefiles/common.mk
  ```

### Core Commands That Work
- **Basic dependency check:**
  ```bash
  docker --version  # Available - 0.01s
  make --version    # Available - 0.04s
  python3 --version # Available - 0.002s
  go version        # Available - 0.67s
  ```

- **Working scripts (all require proper environment setup):**
  ```bash
  # Clean up build reports directory
  bash global/scripts/shared/cleanup.sh  # Works - 0.004s

  # Run GoLang linting (downloads and runs golangci-lint)
  bash global/scripts/languages/golang/golangci-lint/run.sh  # Works - 1.8s, exits with code 7 (no Go modules)

  # Run security scanning with Gitleaks
  bash global/scripts/tools/gitleaks/run.sh  # Works - 2.0s (downloads Docker image)
  ```

- **Container building:**
  ```bash
  # Build specific containers (may fail due to SSL in sandbox environments)
  make build-and-push NAME=awscli TAG=latest  # Requires Docker registry authentication

  # Local build test (will likely fail on SSL certificate issues in sandbox)
  docker build -t test-image -f global/containers/awscli.latest/Dockerfile global/containers/awscli.latest/
  ```

### Working Go Example
- **The repository contains a working Go application for testing:**
  ```bash
  cd global/containers/tor-proxy.latest/health
  go mod tidy      # Downloads dependencies - 2.2s
  go build -o health main.go  # Builds successfully - 11.6s
  ```

### Scripts That Require Environment Variables
- **codeql/run.sh** - Requires language argument (e.g., go, python, java, javascript, csharp)
- **hadolint/run.sh** - Auto-discovers Dockerfiles, skips gracefully if none found
- **trivy/run.sh** - Scans IaC misconfigurations (Terraform, Kubernetes, Dockerfiles)
- **dependency-track/run.sh** - Requires `DEPENDENCY_TRACK_TOKEN` and `DEPENDENCY_TRACK_HOST_URL`
- **sonarqube/run.sh** - Requires `sonar-scanner` installed and SonarQube environment
- **semgrep/run.sh** - May run for 10+ minutes, downloads large Docker image
- **golang/test/run.sh** - Requires Go project with cmd/, pkg/, or internal/ directories

## Available Tools & Scripts

### Security & Analysis Tools

#### SAST Tools

| Tool          | Purpose                       | Script Location                     | Configuration    |
|---------------|-------------------------------|-------------------------------------|------------------|
| **Gitleaks**  | Secret detection              | `global/scripts/tools/gitleaks/`    | `.gitleaks.toml` |
| **CodeQL**    | SAST security scanning        | `global/scripts/tools/codeql/`      | Auto-configured  |
| **Semgrep**   | Static analysis               | `global/scripts/tools/semgrep/`     | Auto-configured  |
| **Hadolint**  | Dockerfile linting            | `global/scripts/tools/hadolint/`    | `.hadolint.yaml` |
| **Trivy IaC** | IaC misconfiguration scanning | `global/scripts/tools/trivy/run.sh` | `.trivyignore`   |

#### SCA Tools

| Tool                       | Purpose                           | Languages  | Script / Integration                           |
|----------------------------|-----------------------------------|------------|------------------------------------------------|
| **Trivy SCA**              | Dependency vulnerability scanning | All        | `global/scripts/tools/trivy/run-sca.sh`        |
| **govulncheck**            | Go vulnerability scanning         | Go         | `global/scripts/languages/golang/govulncheck/` |
| **Safety**                 | Python dependency scanning        | Python     | `pdm run safety-scan`                          |
| **OWASP Dependency-Check** | Java dependency scanning          | Java       | `./gradlew dependencyCheckAnalyze`             |
| **yarn npm audit**         | JS/Node.js dependency scanning    | JavaScript | `yarn npm audit --recursive`                   |
| **npm audit**              | JS/Node.js dependency scanning    | JavaScript | `npm audit --audit-level=high`                 |
| **Composer Audit**         | PHP dependency scanning           | PHP        | `composer audit`                               |
| **bundler-audit**          | Ruby dependency scanning          | Ruby       | `bundle-audit check --update`                  |

#### Quality & Management Tools

| Tool                 | Purpose                   | Script Location                          | Configuration         |
|----------------------|---------------------------|------------------------------------------|-----------------------|
| **Basic Checks**     | PR/MR rebase and changelog verification | `global/scripts/shared/rebase-check.sh`, `changelog-check.sh` | Auto-configured       |
| **SonarQube**        | Code quality & security   | `global/scripts/tools/sonarqube/`        | Project settings      |
| **Dependency Track** | SBOM tracking             | `global/scripts/tools/dependency-track/` | Environment variables |

### Language-Specific Tools

#### Go Tools

| Tool               | Purpose               | Script Location                                  |
|--------------------|-----------------------|--------------------------------------------------|
| **golangci-lint**  | Go linting suite      | `global/scripts/languages/golang/golangci-lint/` |
| **Go Test Runner** | Comprehensive testing | `global/scripts/languages/golang/test/`          |
| **CycloneDX**      | SBOM generation       | `global/scripts/languages/golang/cyclonedx/`     |
| **GoReleaser**     | Binary release builds | `global/scripts/languages/golang/goreleaser/`    |

#### Java Tools

| Tool            | Purpose                      | Script Location                               |
|-----------------|------------------------------|-----------------------------------------------|
| **Checkstyle**  | Java code style enforcement  | `global/scripts/languages/java/checkstyle/`   |

### Container Images

**Available Pre-built Images:**

| Image                       | Purpose                         | Registry                       |
|-----------------------------|---------------------------------|--------------------------------|
| `golang.1.18-awscli`        | Go 1.18 + AWS CLI               | `ghcr.io/rios0rios0/pipelines` |
| `golang.1.19-awscli`        | Go 1.19 + AWS CLI               | `ghcr.io/rios0rios0/pipelines` |
| `golang.1.25-awscli`        | Go 1.25 + AWS CLI               | `ghcr.io/rios0rios0/pipelines` |
| `golang.1.26-awscli`        | Go 1.26 + AWS CLI               | `ghcr.io/rios0rios0/pipelines` |
| `python.3.9-pdm-buster`     | Python 3.9 + PDM                | `ghcr.io/rios0rios0/pipelines` |
| `python.3.10-pdm-bullseye`  | Python 3.10 + PDM               | `ghcr.io/rios0rios0/pipelines` |
| `python.3.13-pdm-bullseye`  | Python 3.13 + PDM               | `ghcr.io/rios0rios0/pipelines` |
| `awscli.latest`             | AWS CLI tools                   | `ghcr.io/rios0rios0/pipelines` |
| `bfg.latest`                | BFG Repo-Cleaner                | `ghcr.io/rios0rios0/pipelines` |
| `mssql-tools18.latest`      | Microsoft SQL Server tools      | `ghcr.io/rios0rios0/pipelines` |
| `tor-proxy.latest`          | Network proxy with health check | `ghcr.io/rios0rios0/pipelines` |

### Key Directories
- `.github/workflows/` - Reusable GitHub Actions workflows
- `github/` - GitHub Actions pipeline templates (mirrors gitlab/ structure)
- `gitlab/` - GitLab CI pipeline templates
- `azure-devops/` - Azure DevOps pipeline templates
- `global/scripts/` - Shared scripts for linting, security scanning, testing
- `global/containers/` - Docker container definitions

## Repository Structure
```
pipelines/
├── .github/workflows/          # GitHub Actions reusable workflows
│   ├── go-docker.yaml         # Go with Docker delivery
│   ├── go-binary.yaml         # Go binary compilation
│   ├── go-library.yaml        # Go library publishing
│   ├── pdm-docker.yaml        # Python/PDM with Docker
│   ├── java-docker.yaml       # Java/Gradle with Docker delivery
│   ├── java-maven-docker.yaml # Java/Maven with Docker delivery
│   ├── javascript-docker.yaml # JavaScript/Yarn with Docker delivery
│   ├── javascript-npm-docker.yaml # JavaScript/npm with Docker delivery
│   ├── php-docker.yaml        # PHP with Docker delivery
│   ├── ruby-docker.yaml       # Ruby with Docker delivery
│   ├── dotnet-docker.yaml     # .NET with Docker delivery
│   └── ...
├── github/                     # GitHub Actions pipeline stage templates
│   ├── golang/                # Go language pipelines
│   ├── java/                  # Java language pipelines
│   ├── python/                # Python language pipelines
│   ├── javascript/            # JavaScript/Node.js pipelines
│   ├── dotnet/                # .NET language pipelines
│   ├── php/                   # PHP language pipelines
│   ├── ruby/                  # Ruby language pipelines
│   └── terra/                 # Terra CLI pipelines
├── gitlab/                     # GitLab CI pipeline templates
│   ├── golang/                # Go language pipelines
│   ├── java/                  # Java language pipelines
│   ├── python/                # Python language pipelines
│   ├── javascript/            # JavaScript/Node.js pipelines
│   ├── dotnet/                # .NET language pipelines
│   ├── logstash/              # Logstash pipelines
│   ├── terraform/             # Terraform pipelines
│   ├── terra/                 # Terra CLI pipelines
│   └── global/                # Shared GitLab configurations
├── azure-devops/              # Azure DevOps pipeline templates
│   ├── golang/                # Go language pipelines
│   ├── java/                  # Java language pipelines
│   ├── python/                # Python language pipelines
│   ├── javascript/            # JavaScript/Node.js pipelines
│   ├── dotnet/                # .NET language pipelines
│   ├── terraform/             # Terraform pipelines
│   ├── terra/                 # Terra CLI pipelines
│   └── global/                # Shared Azure DevOps templates
├── global/                     # Shared resources across platforms
│   ├── scripts/               # Automation scripts
│   │   ├── tools/             # Language-agnostic tools
│   │   │   ├── codeql/        # SAST security scanning (CodeQL)
│   │   │   ├── gitleaks/      # Secret scanning
│   │   │   ├── hadolint/      # Dockerfile linting
│   │   │   ├── semgrep/       # Static analysis
│   │   │   ├── sonarqube/     # Code quality
│   │   │   ├── trivy/         # IaC misconfiguration scanning
│   │   │   └── dependency-track/ # SCA analysis
│   │   ├── languages/         # Language-specific scripts
│   │   │   ├── golang/        # Go scripts (test, cyclonedx, golangci-lint, goreleaser, init)
│   │   │   ├── java/          # Java scripts (checkstyle)
│   │   │   └── python/        # Python scripts (cyclonedx)
│   │   └── shared/            # Common utilities
│   ├── containers/            # Custom Docker images
│   │   ├── golang.*/          # Go development images
│   │   ├── python.*/          # Python development images
│   │   ├── awscli.latest/     # AWS CLI tools
│   │   ├── bfg.latest/        # BFG Repo-Cleaner
│   │   ├── mssql-tools18.latest/ # Microsoft SQL Server tools
│   │   └── tor-proxy.latest/  # Network proxy tools
├── makefiles/                  # Includable Makefile fragments for local usage
│   ├── common.mk              # Security tools (sast, secrets, hadolint, trivy, semgrep)
│   ├── golang.mk              # Go-specific targets (lint, test)
│   ├── python.mk              # Python/PDM targets (lint, test)
│   ├── java.mk                # Java/Gradle targets (lint, test)
│   ├── javascript.mk          # JavaScript/Yarn targets (lint, test)
│   ├── dotnet.mk              # .NET/C# targets (lint, test)
│   ├── terra.mk               # Terra CLI targets (lint, test)
│   └── terraform.mk           # Terraform targets (lint, test)
├── .docs/                      # Documentation and examples
│   └── examples/              # Per-provider usage examples
└── .github/tests/              # Validation scripts for this repository
```

### Pipeline Architecture

Each platform follows a consistent **5-stage pipeline architecture**:

1. **🔍 Code Check (Style/Quality)** - Linting, formatting, code quality, rebase verification
2. **🔒 Security (SCA/SAST)** - Vulnerability scanning, secret detection
3. **🧪 Tests** - Unit tests, integration tests, coverage reporting
4. **📊 Management** - Dependency tracking, SBOM generation
5. **🚀 Delivery** - Build artifacts, container images, deployments

### Platform and Language Support Matrix

**Platforms:**
| Platform           | Status         | Documentation                  |
|--------------------|----------------|--------------------------------|
| **GitHub Actions** | ✅ Full Support | [Usage Guide](#github-actions) |
| **GitLab CI**      | ✅ Full Support | [Usage Guide](#gitlab-ci)      |
| **Azure DevOps**   | ✅ Full Support | [Usage Guide](#azure-devops)   |

**Programming Languages:**
| Language               | GitHub Actions | GitLab CI | Azure DevOps | Features                                  |
|------------------------|----------------|-----------|--------------|-------------------------------------------|
| **GoLang**             | ✅              | ✅         | ✅            | Binary, Docker, K8s, ARM, Lambda, Library |
| **Python**             | ✅              | ✅         | ✅            | PDM, Docker, K8s deployment, Library      |
| **Java**               | ✅              | ✅         | ✅            | Maven, Gradle, Docker, K8s, Library       |
| **JavaScript/Node.js** | ✅              | ✅         | ✅            | npm, Yarn, Docker, K8s deployment         |
| **PHP**                | ✅              | ❌         | ❌            | Composer, Docker                          |
| **Ruby**               | ✅              | ❌         | ❌            | Bundler, Docker                           |
| **.NET/C#**            | ✅              | ✅         | ✅            | Framework, Core, Docker, PowerShell       |
| **Logstash**           | ❌              | ✅         | ❌            | Docker delivery                           |
| **Terraform**          | ❌              | ✅         | ✅            | Infrastructure as Code                    |
| **Terra CLI**          | ✅              | ✅         | ✅            | Terraform/Terragrunt wrapper              |

**Pipeline Templates Available:**
- **GitHub Actions:** `go.yaml`, `go-docker.yaml`, `go-binary.yaml`, `go-library.yaml`, `pdm.yaml`, `pdm-docker.yaml`, `java.yaml`, `java-docker.yaml`, `java-maven.yaml`, `java-maven-docker.yaml`, `javascript.yaml`, `javascript-docker.yaml`, `javascript-npm.yaml`, `javascript-npm-docker.yaml`, `php.yaml`, `php-docker.yaml`, `ruby.yaml`, `ruby-docker.yaml`, `dotnet.yaml`, `dotnet-docker.yaml`, `terra.yaml`
- **GitLab CI:** `go-docker.yaml`, `go-binary.yaml`, `go-docker-k8s-deployment.yaml`, `go-sam.yaml`, `gradle-docker.yaml`, `gradle-docker-k8s-deployment.yaml`, `gradle-library.yaml`, `maven-docker.yaml`, `pdm-docker.yaml`, `pdm-docker-k8s-deployment.yaml`, `pdm-library.yaml`, `yarn-docker.yaml`, `yarn-docker-k8s-deployment.yaml`, `framework.yaml`, `powershell.yaml`, `logstash-docker.yaml`, `terraform/terra.yaml`, `terra/terra.yaml`
- **Azure DevOps:** `go-docker.yaml`, `go-arm.yaml`, `go-docker-arm.yaml`, `go-docker-k8s.yaml`, `go-docker-with-registry.yaml`, `go-function-arm.yaml`, `go-lambda-sam.yaml`, `go-lambda.yaml`, `go-library.yaml`, `kotlin-gradle.yaml`, `pdm-docker.yaml`, `yarn-docker.yaml`, `core.yaml`, `terraform/terra.yaml`, `terra/terra.yaml`

## Common Tasks

### Using Pipeline Templates in Your Project

**GitHub Actions:**
```yaml
name: 'default'
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
permissions:
  checks: write
  contents: write
jobs:
  default:
    uses: 'rios0rios0/pipelines/.github/workflows/go-docker.yaml@main'
```

**GitLab CI:**
```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/golang/go-docker.yaml'

# Optional: Override delivery stage for custom Docker build
.delivery:
  script:
    - docker build -t "$REGISTRY_PATH$IMAGE_SUFFIX:$TAG" -f .ci/stages/40-delivery/Dockerfile .
  cache:
    key: 'test:all'
    paths: !reference [ .go, cache, paths ]
    policy: 'pull'

# Required GitLab Variables (configure in project settings):
# SONAR_HOST_URL     - SonarQube server URL
# SONAR_TOKEN        - SonarQube authentication token
# DOCKER_REGISTRY    - Container registry URL
# DOCKER_USERNAME    - Registry username
# DOCKER_PASSWORD    - Registry password
```

**Azure DevOps:**
```yaml
trigger:
  branches:
    include: [ main ]
  tags:
    include: [ '*' ]

pool:
  vmImage: 'ubuntu-latest'

variables:
  - ${{ if startsWith(variables['Build.SourceBranch'], 'refs/tags/') }}:
      - group: 'production-variables'
  - ${{ else }}:
      - group: 'development-variables'

resources:
  repositories:
    - repository: pipelines
      type: github
      name: rios0rios0/pipelines
      endpoint: 'YOUR_GITHUB_SERVICE_CONNECTION'  # Configure this

stages:
  - template: azure-devops/golang/go-arm.yaml@pipelines
    parameters:
      DOCKER_BUILD_ARGS: '--build-arg VERSION=$(Build.BuildNumber)'
      RUN_BEFORE_BUILD: 'echo "Preparing build environment"'

# Required Variable Groups (create in Azure DevOps Library):
# Shared Variables: SONAR_HOST_URL, SONAR_TOKEN
# Project Variables: SONAR_PROJECT_NAME, SONAR_PROJECT_KEY
```

### Language-Specific Examples

#### Python with PDM (GitLab CI)
```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/python/pdm-docker.yaml'

variables:
  PYTHON_VERSION: "3.11"  # Optional: specify Python version
```

#### Java with Maven (GitLab CI)
```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/java/maven-docker.yaml'
```

#### JavaScript with Yarn (GitLab CI)
```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/javascript/yarn-docker.yaml'
```

#### Terraform (GitLab CI)
```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/terraform/terra.yaml'
```

#### Java with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  security-events: write
  contents: write
  packages: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/java-docker.yaml@main'
```

#### JavaScript with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  security-events: write
  contents: write
  packages: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/javascript-docker.yaml@main'
```

#### .NET with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  security-events: write
  contents: write
  packages: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/dotnet-docker.yaml@main'
```

#### JavaScript/npm with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  security-events: write
  contents: write
  packages: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/javascript-npm-docker.yaml@main'
```

#### Java/Maven with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  security-events: write
  contents: write
  packages: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/java-maven-docker.yaml@main'
```

#### PHP with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  contents: write
  packages: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/php-docker.yaml@main'
```

#### Ruby with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  security-events: write
  contents: write
  packages: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/ruby-docker.yaml@main'
```

### Testing Pipeline Changes in Development Branches
```bash
export BRANCH=your-feature-branch
find . -type f -name "*.yaml" -exec sed -i.bak -E "s|(remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/)[^/]+(/.*)|\\1$BRANCH\\2|g" {} +
```

### Local Script Usage
```bash
# Set up environment for local script usage
export SCRIPTS_DIR=/home/$USER/Development/github.com/rios0rios0/pipelines

# Run any script
$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/run.sh

# Link golangci-lint config globally
ln -s $SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/.golangci.yml ~/.golangci.yml
```

### Comprehensive Local Development Examples

#### Configure Go Development
```bash
# Link global Go linting configuration
ln -s $SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/.golangci.yml ~/.golangci.yml

# Run linting in your project
$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/run.sh

# Run with auto-fix
$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/run.sh --fix
```

#### Run Security Scanning Locally
```bash
# Run secret detection
$SCRIPTS_DIR/global/scripts/tools/gitleaks/run.sh

# Run SAST security scanning with CodeQL
$SCRIPTS_DIR/global/scripts/tools/codeql/run.sh go

# Run Dockerfile linting
$SCRIPTS_DIR/global/scripts/tools/hadolint/run.sh

# Run IaC misconfiguration scanning
$SCRIPTS_DIR/global/scripts/tools/trivy/run.sh

# Run static analysis (can take 10+ minutes)
$SCRIPTS_DIR/global/scripts/tools/semgrep/run.sh
```

#### Run Tests and Coverage
```bash
# Run comprehensive Go tests
$SCRIPTS_DIR/global/scripts/languages/golang/test/run.sh

# Generate SBOM for Go projects
$SCRIPTS_DIR/global/scripts/languages/golang/cyclonedx/run.sh
```

#### Build and Test Container Images
```bash
# Build specific containers (may fail due to SSL in sandbox environments)
make build-and-push NAME=awscli TAG=latest

# Local build test
docker build -t test-image -f global/containers/awscli.latest/Dockerfile global/containers/awscli.latest/
```

## Validation and Testing

### Critical Testing Requirements
- **NEVER CANCEL long-running commands** - Some operations take 10+ minutes
- **Always test across all three platforms** (GitHub, GitLab, Azure DevOps)
- **Validate security scanning tools work** in target environments
- **Test container builds** with proper authentication
- **Run validation tests**: Execute `make test` before submitting changes
- **Verify coverage completeness**: Ensure coverage includes all packages, not just tested ones

### Manual Validation Steps
1. **Clone repository using provided scripts**
2. **Test script execution** in isolated environment
3. **Validate pipeline templates** by including them in test projects
4. **Verify Docker container builds** (may require network access)
5. **Check security scanning tools** download and run correctly
6. **Run test suite**: Execute `make test` for all validation tests

### Test Suite Usage
```bash
# Run all validation tests (Go test script + Lambda templates + YAML merge)
make test

# Run individual test suites
make test-go-script
make test-lambda
make test-yaml-merge
```

Test scripts are located in `.github/tests/`.

### Coverage Testing Requirements
- Coverage reports MUST include all packages with Go files
- Untested packages MUST appear as 0% covered in reports
- Overall coverage percentage MUST reflect complete codebase visibility
- Test scenarios MUST validate comprehensive coverage behavior

### Environment Requirements
- Docker (for container builds and security tools)
- Go (for GoLang pipelines)
- Python 3 (for script dependencies and Python pipelines)
- Make (for build automation)
- Network access (for downloading tools and dependencies)

## Important Notes

### This is NOT an Application
- This repository provides **pipeline templates and scripts**, not a runnable application
- Users **consume these templates** in their own projects
- **No traditional build/test/run cycle** exists for the repository itself
- **Validation involves testing the templates** in example projects

### Timeout and Performance Expectations
- Script downloads: **1-5 seconds**
- Security scanning: **2-10 minutes** depending on tool and project size
- Container builds: **5-30 minutes** depending on base image and dependencies
- **NEVER CANCEL** operations that appear to be hanging - they may be downloading large images

### Detailed Performance Table

| Operation                    | Expected Duration | Notes                                  |
|------------------------------|-------------------|----------------------------------------|
| Script downloads             | 1-5 seconds       | First-time tool downloads              |
| Go linting (golangci-lint)   | 10-30 seconds     | Depends on codebase size               |
| Security scanning (Gitleaks) | 2-5 minutes       | Depends on repository size             |
| Security scanning (CodeQL)   | 3-10 minutes      | SAST analysis                          |
| Security scanning (Semgrep)  | 5-15 minutes      | Downloads large rule sets              |
| Container builds             | 5-30 minutes      | Depends on base image and dependencies |
| Go testing with coverage     | 10-60 seconds     | Depends on test suite size             |
| SonarQube analysis           | 2-10 minutes      | Depends on codebase size               |

**Important:** Never cancel operations that appear to be hanging - they may be downloading large Docker images or security rule sets.

### Known Limitations in Sandbox Environments
- Container builds may fail due to SSL certificate issues
- Security tools require Docker daemon access
- Some scripts need specific environment variables set
- Network restrictions may prevent tool downloads

### Troubleshooting Common Issues
- If scripts fail with "command not found", check if required tools are installed
- If container builds fail with SSL errors, this is expected in restricted environments
- If security scans timeout, increase timeout values and wait for completion
- If Go scripts fail, ensure you're in a directory with proper Go module structure

#### Platform-Specific Issues

**GitHub Actions:**
- **Issue:** Workflow doesn't trigger
- **Solution:** Check repository permissions, ensure workflow file is in `.github/workflows/`
- **Required Permissions:** `checks: write`, `contents: write`, `packages: write`

**GitLab CI:**
- **Issue:** "Remote file could not be fetched"
- **Solution:** Verify the remote URL is accessible, check branch name in URL
- **Issue:** Pipeline variables not recognized
- **Solution:** Configure required variables in GitLab project settings

**Azure DevOps:**
- **Issue:** "Template not found"
- **Solution:** Ensure GitHub service connection is configured correctly
- **Issue:** Variable group not found
- **Solution:** Create required variable groups in Azure DevOps Library

#### Security Tool Issues

**Issue: CodeQL analysis fails**
- **Cause:** CodeQL CLI not installed or language not supported
- **Solution:** Ensure network access to download CodeQL CLI bundle; supported languages: go, python, java, javascript, csharp, ruby (PHP is not supported)

**Issue: Gitleaks takes too long or fails**
- **Cause:** Large repository or network issues
- **Solution:** Increase timeout values, ensure Docker daemon is accessible

**Issue: Semgrep timeout or hangs**
- **Cause:** Large codebase, downloading security rules
- **Solution:** Allow 10+ minutes for completion, don't cancel the operation

**Issue: SonarQube analysis fails**
- **Cause:** Missing SonarQube configuration or network issues
- **Solution:** Verify `SONAR_HOST_URL` and `SONAR_TOKEN` are correctly configured

**Issue: Dependency Track fails**
- **Cause:** Missing environment variables
- **Solution:** Ensure `DEPENDENCY_TRACK_TOKEN` and `DEPENDENCY_TRACK_HOST_URL` are set

#### Pipeline-Specific Issues

**Issue: "No directories found to test it" (Go projects)**
- **Cause:** Go project structure doesn't match expected layout
- **Solution:** Ensure your project has `cmd/`, `pkg/`, or `internal/` directories

**Issue: "golangci-lint: command not found"**
- **Cause:** golangci-lint not installed or not in PATH
- **Solution:** The script automatically downloads golangci-lint, ensure Docker is available

**Issue: Docker build fails with SSL certificate errors**
- **Cause:** Network restrictions in CI environment
- **Solution:** This is expected in restricted environments; contact platform administrator

Always validate changes by testing the pipeline templates in actual projects rather than testing the repository in isolation.
