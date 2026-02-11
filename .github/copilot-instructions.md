# CI/CD Pipeline Templates Repository

**ALWAYS FOLLOW THESE INSTRUCTIONS FIRST.** Only fallback to additional search and context gathering if the information in these instructions is incomplete or found to be in error.

This repository provides comprehensive SDLC pipeline templates for GitHub Actions, GitLab CI, and Azure DevOps across multiple programming languages including GoLang, Java, Python, JavaScript, and .NET.

## Quick Reference

**Essential Commands:**
- `make test` - Run all validation tests
- `make test-go-script` - Test Go script changes specifically
- `bash global/scripts/shared/cleanup.sh` - Clean up build reports
- `docker --version && make --version && go version` - Check dependencies

**Common Pipeline Usage:**
- **GitHub Actions:** Use `.github/workflows/go-docker.yaml@main`
- **GitLab CI:** Include `gitlab/golang/go-docker.yaml` from this repo
- **Azure DevOps:** Template `azure-devops/golang/go-docker.yaml@pipelines`

**Security Tools:** Gitleaks, CodeQL, Semgrep, Hadolint, Trivy, SonarQube, Dependency Track
**Performance:** Security scans 2-10min, Container builds 5-30min
**Architecture:** 5-stage pipeline (Code Check → Security → Tests → Management → Delivery)

## Working Effectively

### Bootstrap and Setup
- **Clone the repository locally:**
  ```bash
  mkdir -p $HOME/Development/github.com/rios0rios0
  cd $HOME/Development/github.com/rios0rios0
  git clone https://github.com/rios0rios0/pipelines.git
  ```

- **Alternative: Use the provided clone script:**
  ```bash
  mkdir -p $HOME/Development/github.com/rios0rios0
  curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash
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

| Tool                 | Purpose                          | Script Location                    | Configuration         |
|----------------------|----------------------------------|------------------------------------|-----------------------|
| **Gitleaks**         | Secret detection                 | `global/scripts/tools/gitleaks/`         | `.gitleaks.toml`      |
| **CodeQL**           | SAST security scanning           | `global/scripts/tools/codeql/`           | Auto-configured       |
| **Semgrep**          | Static analysis                  | `global/scripts/tools/semgrep/`          | Auto-configured       |
| **Hadolint**         | Dockerfile linting               | `global/scripts/tools/hadolint/`         | `.hadolint.yaml`      |
| **Trivy**            | IaC misconfiguration scanning    | `global/scripts/tools/trivy/`            | `.trivyignore`        |
| **SonarQube**        | Code quality & security          | `global/scripts/tools/sonarqube/`        | Project settings      |
| **Dependency Track** | SCA analysis                     | `global/scripts/tools/dependency-track/` | Environment variables |

### Language-Specific Tools

#### Go Tools

| Tool               | Purpose               | Script Location                    |
|--------------------|-----------------------|------------------------------------|
| **golangci-lint**  | Go linting suite      | `global/scripts/languages/golang/golangci-lint/`    |
| **Go Test Runner** | Comprehensive testing | `global/scripts/languages/golang/test/`      |
| **CycloneDX**      | SBOM generation       | `global/scripts/languages/golang/cyclonedx/` |

### Container Images

**Available Pre-built Images:**

| Image                      | Purpose                         | Registry                       |
|----------------------------|---------------------------------|--------------------------------|
| `golang.1.18-awscli`       | Go 1.18 + AWS CLI               | `ghcr.io/rios0rios0/pipelines` |
| `golang.1.19-awscli`       | Go 1.19 + AWS CLI               | `ghcr.io/rios0rios0/pipelines` |
| `python.3.9-pdm-buster`    | Python 3.9 + PDM                | `ghcr.io/rios0rios0/pipelines` |
| `python.3.10-pdm-bullseye` | Python 3.10 + PDM               | `ghcr.io/rios0rios0/pipelines` |
| `awscli.latest`            | AWS CLI tools                   | `ghcr.io/rios0rios0/pipelines` |
| `tor-proxy.latest`         | Network proxy with health check | `ghcr.io/rios0rios0/pipelines` |

### Key Directories
- `.github/workflows/` - Reusable GitHub Actions workflows
- `gitlab/` - GitLab CI pipeline templates
- `azure-devops/` - Azure DevOps pipeline templates
- `global/scripts/` - Shared scripts for linting, security scanning, testing
- `global/containers/` - Docker container definitions
- `global/configs/` - Configuration files

## Repository Structure
```
pipelines/
├── .github/workflows/          # GitHub Actions reusable workflows
│   ├── go-docker.yaml         # Go with Docker delivery
│   ├── go-binary.yaml         # Go binary compilation
│   ├── python-docker.yaml     # Python with Docker
│   └── ...
├── gitlab/                     # GitLab CI pipeline templates
│   ├── golang/                # Go language pipelines
│   ├── java/                  # Java language pipelines
│   ├── python/                # Python language pipelines
│   ├── javascript/            # JavaScript/Node.js pipelines
│   ├── dotnet/                # .NET language pipelines
│   └── global/                # Shared GitLab configurations
├── azure-devops/              # Azure DevOps pipeline templates
│   ├── golang/                # Go language pipelines
│   ├── java/                  # Java language pipelines
│   ├── python/                # Python language pipelines
│   ├── javascript/            # JavaScript/Node.js pipelines
│   ├── dotnet/                # .NET language pipelines
│   ├── terraform/             # Terraform pipelines
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
│   │   │   ├── golang/        # Go scripts (test, cyclonedx, golangci-lint, init)
│   │   │   └── python/        # Python scripts (cyclonedx)
│   │   └── shared/            # Common utilities
│   ├── containers/            # Custom Docker images
│   │   ├── golang.*/          # Go development images
│   │   ├── python.*/          # Python development images
│   │   ├── awscli.latest/     # AWS CLI tools
│   │   └── tor-proxy.latest/  # Network proxy tools
│   └── configs/               # Configuration files
└── docs/                      # Documentation and examples
```

### Pipeline Architecture

Each platform follows a consistent **5-stage pipeline architecture**:

1. **🔍 Code Check (Style/Quality)** - Linting, formatting, code quality
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
| Language               | GitHub Actions | GitLab CI | Azure DevOps | Features                       |
|------------------------|----------------|-----------|--------------|--------------------------------|
| **GoLang**             | ✅              | ✅         | ✅            | Binary, Docker, ARM deployment |
| **Python**             | ✅              | ✅         | ✅            | PDM, Docker, K8s deployment    |
| **Java**               | ❌              | ✅         | ✅            | Maven, Gradle, Docker          |
| **JavaScript/Node.js** | ❌              | ✅         | ✅            | Yarn, Docker, K8s deployment   |
| **.NET/C#**            | ❌              | ✅         | ✅            | Framework, Core, Docker        |
| **Terraform**          | ❌              | ❌         | ✅            | Infrastructure as Code         |

**Pipeline Templates Available:**
- **GitHub Actions:** `go.yaml`, `go-docker.yaml`, `go-binary.yaml`, `python.yaml`, `python-docker.yaml`
- **GitLab CI:** `go-docker.yaml`, `go-debian.yaml`, `go-sam.yaml`, `gradle-docker.yaml`, `maven-docker.yaml`, `pdm-docker.yaml`, `yarn-docker.yaml`, `framework.yaml`
- **Azure DevOps:** `go-docker.yaml`, `go-arm.yaml`, `go-function-arm.yaml`, `gradle-docker.yaml`, `maven-docker.yaml`, `pdm-docker.yaml`, `yarn-docker.yaml`, `framework.yaml`, plus Terraform templates

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
6. **Run test suite**: Execute `make test-go-script` for Go script changes

### Test Suite Usage
```bash
# Run all validation tests
make test

# Run Go script validation specifically
make test-go-script

# Validate changes manually
./test-go-validation.sh
```

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
| SonarQube analysis          | 2-10 minutes      | Depends on codebase size               |

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
- **Solution:** Ensure network access to download CodeQL CLI bundle; supported languages: go, python, java, javascript, csharp

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
