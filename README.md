# CI/CD Pipeline Templates Repository

Welcome to the **Pipelines Project**! This repository provides comprehensive, enterprise-grade Software Development Life
Cycle (SDLC) pipeline templates for **GitHub Actions**, **GitLab CI**, and **Azure DevOps**. Our templates include
security scanning (SAST), dependency analysis (SCA), supply chain security (SSCA), testing, and deployment automation
for multiple programming languages.

## 🚀 Quick Start

Choose your platform and language:

- **[GitHub Actions](#github-actions)** - Modern, cloud-native CI/CD
- **[GitLab CI](#gitlab-ci)** - Integrated DevOps platform
- **[Azure DevOps](#azure-devops)** - Enterprise Microsoft ecosystem

## 📋 Table of Contents

- [Supported Platforms & Languages](#supported-platforms--languages)
- [Project Structure](#project-structure)
- [Platform Usage](#platform-usage)
- [Available Tools & Scripts](#available-tools--scripts)
- [Container Images](#container-images)
- [Development & Local Usage](#development--local-usage)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

## 🛠 Supported Platforms & Languages

### Platforms

| Platform           | Status         | Documentation                  |
|--------------------|----------------|--------------------------------|
| **GitHub Actions** | ✅ Full Support | [Usage Guide](#github-actions) |
| **GitLab CI**      | ✅ Full Support | [Usage Guide](#gitlab-ci)      |
| **Azure DevOps**   | ✅ Full Support | [Usage Guide](#azure-devops)   |

### Programming Languages

| Language               | GitHub Actions | GitLab CI | Azure DevOps | Features                       |
|------------------------|----------------|-----------|--------------|--------------------------------|
| **GoLang**             | ✅              | ✅         | ✅            | Binary, Docker, ARM deployment |
| **Python**             | ✅              | ✅         | ✅            | PDM, Docker, K8s deployment    |
| **Java**               | ✅              | ✅         | ✅            | Maven, Gradle, Docker          |
| **JavaScript/Node.js** | ✅              | ✅         | ✅            | Yarn, Docker, K8s deployment   |
| **.NET/C#**            | ✅              | ✅         | ✅            | Framework, Core, Docker        |
| **Terraform**          | ❌              | ✅         | ✅            | Infrastructure as Code         |

## 📁 Project Structure

```
pipelines/
├── .github/workflows/          # GitHub Actions reusable workflows
│   ├── go-docker.yaml         # Go with Docker delivery
│   ├── go-binary.yaml         # Go binary compilation
│   ├── python-docker.yaml     # Python with Docker
│   ├── java-docker.yaml       # Java with Docker delivery
│   ├── javascript-docker.yaml # JavaScript with Docker delivery
│   ├── dotnet-docker.yaml     # .NET with Docker delivery
│   └── ...
├── gitlab/                     # GitLab CI pipeline templates
│   ├── golang/                # Go language pipelines
│   ├── java/                  # Java language pipelines
│   ├── python/                # Python language pipelines
│   ├── javascript/            # JavaScript/Node.js pipelines
│   ├── dotnet/                # .NET language pipelines
│   ├── terraform/             # Terraform pipelines
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
├── makefiles/                  # Includable Makefile fragments for local usage
│   ├── common.mk              # Security tools (sast) and setup
│   ├── golang.mk              # Go targets (lint, test)
│   ├── python.mk              # Python/PDM targets (lint, test)
│   ├── java.mk                # Java/Gradle targets (lint, test)
│   ├── javascript.mk          # JavaScript/Yarn targets (lint, test)
│   ├── dotnet.mk              # .NET/C# targets (lint, test)
│   └── terraform.mk           # Terraform targets (lint, test)
├── .docs/                      # Documentation and examples
│   └── examples/              # Per-provider usage examples
└── .github/tests/              # Validation scripts for this repository
```

### Pipeline Architecture

Each platform follows a consistent **5-stage pipeline architecture**:

1. **🔍 Code Check (Style/Quality)** - Linting, formatting, code quality
2. **🔒 Security (SCA/SAST)** - Vulnerability scanning, secret detection
3. **🧪 Tests** - Unit tests, integration tests, coverage reporting
4. **📊 Management** - Dependency tracking, SBOM generation
5. **🚀 Delivery** - Build artifacts, container images, deployments

## 💻 Platform Usage

### GitHub Actions

GitHub Actions workflows are located in `.github/workflows/` and can be used as reusable workflows.

#### Available Workflows

| Workflow                  | Purpose                                    | Languages      |
|---------------------------|--------------------------------------------|----------------|
| `go.yaml`                 | Go testing and quality checks              | Go             |
| `go-docker.yaml`          | Go with Docker image delivery              | Go             |
| `go-binary.yaml`          | Go binary compilation and release          | Go             |
| `python.yaml`             | Python testing and quality checks          | Python         |
| `python-docker.yaml`      | Python with Docker image delivery          | Python         |
| `java.yaml`               | Java/Gradle testing and quality checks     | Java           |
| `java-docker.yaml`        | Java/Gradle with Docker image delivery     | Java           |
| `javascript.yaml`         | JavaScript/Yarn testing and quality checks | JavaScript     |
| `javascript-docker.yaml`  | JavaScript/Yarn with Docker image delivery | JavaScript     |
| `dotnet.yaml`             | .NET testing and quality checks            | C#             |
| `dotnet-docker.yaml`      | .NET with Docker image delivery            | C#             |

#### Usage Example (Go with Docker)

```yaml
name: 'CI/CD Pipeline'

on:
  push:
    branches: [ main ]
    tags: [ '*' ]
  pull_request:
    branches: [ main ]

permissions:
  checks: write      # Required for test results
  contents: write    # Required for releases
  packages: write    # Required for container registry

jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/go-docker.yaml@main'
```

#### Usage Example (Python with Docker)

```yaml
name: 'CI/CD Pipeline'

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/python-docker.yaml@main'
```

#### Usage Example (Java with Docker)

```yaml
name: 'CI/CD Pipeline'

on:
  push:
    branches: [ main ]
    tags: [ '*' ]
  pull_request:
    branches: [ main ]

permissions:
  security-events: write
  contents: write
  packages: write

jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/java-docker.yaml@main'
```

#### Usage Example (JavaScript with Docker)

```yaml
name: 'CI/CD Pipeline'

on:
  push:
    branches: [ main ]
    tags: [ '*' ]
  pull_request:
    branches: [ main ]

permissions:
  security-events: write
  contents: write
  packages: write

jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/javascript-docker.yaml@main'
```

#### Usage Example (.NET with Docker)

```yaml
name: 'CI/CD Pipeline'

on:
  push:
    branches: [ main ]
    tags: [ '*' ]
  pull_request:
    branches: [ main ]

permissions:
  security-events: write
  contents: write
  packages: write

jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/dotnet-docker.yaml@main'
```

![GitHub Actions Example](.docs/github-golang.png)

### GitLab CI

GitLab CI templates use remote includes and are organized by language in the `gitlab/` directory.

#### Available Templates

| Language        | Template             | Purpose                    |
|-----------------|----------------------|----------------------------|
| **Go**          | `go-docker.yaml`     | Go with Docker delivery    |
| **Go**          | `go-debian.yaml`     | Go Debian-based pipeline   |
| **Go**          | `go-sam.yaml`        | Go with AWS SAM deployment |
| **Java**        | `gradle-docker.yaml` | Gradle with Docker         |
| **Java**        | `maven-docker.yaml`  | Maven with Docker          |
| **Python**      | `pdm-docker.yaml`    | Python PDM with Docker     |
| **JavaScript**  | `yarn-docker.yaml`   | Node.js Yarn with Docker   |
| **.NET**        | `framework.yaml`     | .NET Framework pipeline    |
| **Terraform**   | `terra.yaml`         | Terraform IaC pipeline     |

#### Usage Example (Go with Docker)

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
```

#### Usage Example (Python PDM)

```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/python/pdm-docker.yaml'

variables:
  PYTHON_VERSION: "3.11"  # Optional: specify a Python version
```

#### Usage Example (Terraform)

```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/terraform/terra.yaml'
```

#### Required GitLab Variables

Configure these in your GitLab project settings:

| Variable          | Description                    | Required For    |
|-------------------|--------------------------------|-----------------|
| `SONAR_HOST_URL`  | SonarQube server URL           | Code quality    |
| `SONAR_TOKEN`     | SonarQube authentication token | Code quality    |
| `DOCKER_REGISTRY` | Container registry URL         | Docker delivery |
| `DOCKER_USERNAME` | Registry username              | Docker delivery |
| `DOCKER_PASSWORD` | Registry password              | Docker delivery |

![GitLab CI Example](.docs/gitlab-java.png)

### Azure DevOps

Azure DevOps templates are located in the `azure-devops/` directory and use template references.

#### Available Templates

| Language        | Template               | Purpose                           |
|-----------------|------------------------|-----------------------------------|
| **Go**          | `go-docker.yaml`       | Go with Docker delivery           |
| **Go**          | `go-arm.yaml`          | Go with Azure ARM deployment      |
| **Go**          | `go-function-arm.yaml` | Go Azure Functions                |
| **Go**          | `go-lambda.yaml`       | Go AWS Lambda deployment (ZIP)    |
| **Go**          | `go-lambda-sam.yaml`   | Go AWS Lambda deployment (SAM)    |
| **Java**        | `kotlin-gradle.yaml`   | Kotlin/Gradle with Docker         |
| **Python**      | `pdm-docker.yaml`      | Python PDM with Docker            |
| **JavaScript**  | `yarn-docker.yaml`     | Node.js Yarn with Docker          |
| **.NET**        | `core.yaml`            | .NET Core pipeline                |
| **Terraform**   | `terra.yaml`           | Infrastructure as Code pipeline   |

#### Usage Example (Go with Docker)

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
    - repository: 'pipelines'
      type: 'github'
      name: 'rios0rios0/pipelines'
      endpoint: 'YOUR_GITHUB_SERVICE_CONNECTION'  # Configure this

stages:
  - template: 'azure-devops/golang/go-docker.yaml@pipelines'
```

#### Usage Example (Go with ARM Deployment)

```yaml
resources:
  repositories:
    - repository: 'pipelines'
      type: 'github'
      name: 'rios0rios0/pipelines'
      endpoint: 'YOUR_GITHUB_SERVICE_CONNECTION'

stages:
  - template: 'azure-devops/golang/go-arm.yaml@pipelines'
    parameters:
      DOCKER_BUILD_ARGS: '--build-arg VERSION=$(Build.BuildNumber)'
      RUN_BEFORE_BUILD: 'echo "Preparing build environment"'
```

#### Usage Example (Go with AWS Lambda)

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
    - repository: 'pipelines'
      type: 'github'
      name: 'rios0rios0/pipelines'
      endpoint: 'YOUR_GITHUB_SERVICE_CONNECTION'

stages:
  - template: 'azure-devops/golang/go-lambda.yaml@pipelines'
    parameters:
      LAMBDA_FUNCTION_NAME: 'my-go-lambda-function'
      AWS_REGION: 'us-east-1'
      AWS_SERVICE_CONNECTION: 'AWS-Service-Connection'  # Configure in Azure DevOps
      DEPLOY_STRATEGY: 'zip'  # or 'sam'
      GOARCH: 'amd64'  # or 'arm64'
      LAMBDA_TIMEOUT: '30'
      LAMBDA_MEMORY_SIZE: '128'
```

**For SAM-based deployments:**

```yaml
stages:
  - template: 'azure-devops/golang/go-lambda-sam.yaml@pipelines'
    parameters:
      S3_BUCKET: 'my-deployment-bucket'
      AWS_REGION: 'us-east-1'
      AWS_SERVICE_CONNECTION: 'AWS-Service-Connection'
      SAM_CONFIG_ENV: 'default'  # References samconfig.toml environment
```

#### Required Variable Groups

Create these variable groups in Azure DevOps Library:

**Shared Variables (All Projects):**
| Variable | Description |
|----------|-------------|
| `SONAR_HOST_URL` | SonarQube server URL |
| `SONAR_TOKEN` | SonarQube authentication token |

**Project-Specific Variables (.NET Example):**
| Variable | Description |
|----------|-------------|
| `SONAR_PROJECT_NAME` | SonarQube project display name |
| `SONAR_PROJECT_KEY` | SonarQube project unique key |

**AWS Lambda Deployment Variables (Optional):**
| Variable | Description | Required For |
|----------|-------------|--------------|
| `AWS_ACCESS_KEY_ID` | AWS access key (if not using service connection) | Lambda deployment |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key (if not using service connection) | Lambda deployment |
| `LAMBDA_ROLE_ARN` | IAM role ARN for Lambda function | Creating new functions |

**Note:** For AWS deployments, it's recommended to use Azure DevOps AWS Service Connection instead of storing credentials in variable groups. Configure the service connection in Azure DevOps Project Settings → Service Connections.

![Azure DevOps Example](.docs/azure-devops-golang.png)

## 🔧 Available Tools & Scripts

Our pipeline templates include a comprehensive suite of tools for security, quality, and testing:

### Security & Analysis Tools

| Tool                 | Purpose                       | Script Location                          | Configuration         |
|----------------------|-------------------------------|------------------------------------------|-----------------------|
| **Gitleaks**         | Secret detection              | `global/scripts/tools/gitleaks/`         | `.gitleaks.toml`      |
| **CodeQL**           | SAST security scanning        | `global/scripts/tools/codeql/`           | Auto-configured       |
| **Semgrep**          | Static analysis               | `global/scripts/tools/semgrep/`          | Auto-configured       |
| **Hadolint**         | Dockerfile linting            | `global/scripts/tools/hadolint/`         | `.hadolint.yaml`      |
| **Trivy**            | IaC misconfiguration scanning | `global/scripts/tools/trivy/`            | `.trivyignore`        |
| **SonarQube**        | Code quality & security       | `global/scripts/tools/sonarqube/`        | Project settings      |
| **Dependency Track** | SCA analysis                  | `global/scripts/tools/dependency-track/` | Environment variables |

### Language-Specific Tools

#### Go Tools

| Tool               | Purpose               | Script Location                                  |
|--------------------|-----------------------|--------------------------------------------------|
| **golangci-lint**  | Go linting suite      | `global/scripts/languages/golang/golangci-lint/` |
| **Go Test Runner** | Comprehensive testing | `global/scripts/languages/golang/test/`          |
| **CycloneDX**      | SBOM generation       | `global/scripts/languages/golang/cyclonedx/`     |

### Usage Examples

#### Run Security Scanning Locally (via Makefile)

The fastest way to run pipeline tools locally is through the Makefile includes. See the [Makefile Integration](#makefile-integration) section below for setup details.

```bash
make setup      # Clone/update pipelines repo
make lint       # Run golangci-lint
make test       # Run Go tests with coverage
make security   # Run all security tools (CodeQL, Gitleaks, Hadolint, Trivy, Semgrep)
```

#### Configure Go Linting Globally

```bash
# Symlink the shared golangci-lint config for IDE integration
SCRIPTS_DIR=$HOME/Development/github.com/rios0rios0/pipelines
ln -s $SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/.golangci.yml ~/.golangci.yml
```

## 🐳 Container Images

We provide pre-built container images optimized for CI/CD environments:

### Available Images

| Image                      | Purpose                         | Registry                       |
|----------------------------|---------------------------------|--------------------------------|
| `golang.1.18-awscli`       | Go 1.18 + AWS CLI               | `ghcr.io/rios0rios0/pipelines` |
| `golang.1.19-awscli`       | Go 1.19 + AWS CLI               | `ghcr.io/rios0rios0/pipelines` |
| `python.3.9-pdm-buster`    | Python 3.9 + PDM                | `ghcr.io/rios0rios0/pipelines` |
| `python.3.10-pdm-bullseye` | Python 3.10 + PDM               | `ghcr.io/rios0rios0/pipelines` |
| `awscli.latest`            | AWS CLI tools                   | `ghcr.io/rios0rios0/pipelines` |
| `tor-proxy.latest`         | Network proxy with health check | `ghcr.io/rios0rios0/pipelines` |

### Building Custom Images

```bash
# Build and push a custom container
make build-and-push NAME=awscli TAG=latest

# Local build for testing
docker build -t my-image -f global/containers/awscli.latest/Dockerfile global/containers/awscli.latest/
```

## 💻 Development & Local Usage

### Installation & Setup

The `clone.sh` script is an idempotent installer: it clones the repository on first run, and pulls the latest changes on subsequent runs. It is designed to be used in project Makefiles so that teams can run linting, SAST, and all pipeline tools locally before pushing.

#### Quick Installation

```bash
curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash
```

You can override the installation location with the `PIPELINES_HOME` environment variable:

```bash
PIPELINES_HOME=/opt/pipelines curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash
```

#### Manual Installation

```bash
mkdir -p $HOME/Development/github.com/rios0rios0
cd $HOME/Development/github.com/rios0rios0
git clone https://github.com/rios0rios0/pipelines.git
```

### Makefile Integration

The recommended way to use this repository locally is through the includable `.mk` files. GNU Make's `-include` directive imports targets from the pipelines repository, so your project Makefile only needs to declare `SCRIPTS_DIR` and the includes:

**Before** (repeated in every project):

```makefile
SCRIPTS_DIR = $(HOME)/Development/github.com/rios0rios0/pipelines

.PHONY: lint
lint:
	${SCRIPTS_DIR}/global/scripts/languages/golang/golangci-lint/run.sh --fix .

.PHONY: test
test:
	${SCRIPTS_DIR}/global/scripts/languages/golang/test/run.sh .

.PHONY: sast
sast:
	${SCRIPTS_DIR}/global/scripts/tools/codeql/run.sh "go"
```

**After** (include once, get all targets):

```makefile
# Pipeline targets: setup, sast, lint, test
SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
-include $(SCRIPTS_DIR)/makefiles/common.mk
-include $(SCRIPTS_DIR)/makefiles/golang.mk

build:
	go build -o bin/app .

run:
	go run .
```

This gives you the following targets for free:

| Target       | Source            | Description                              |
|--------------|-------------------|------------------------------------------|
| `make setup` | `common.mk`       | Clone or update the pipelines repository |
| `make sast`  | `common.mk`       | Run all security SAST tools              |
| `make lint`  | `<language>.mk`   | Run language-specific linter             |
| `make test`  | `<language>.mk`   | Run language-specific tests              |

Available language files:

| File            | Language          | `lint`                                | `test`             |
|-----------------|-------------------|---------------------------------------|--------------------|
| `golang.mk`     | Go                | `golangci-lint --fix`                 | Go test + coverage |
| `python.mk`     | Python (PDM)      | `isort` + `black` + `flake8` + `mypy` | `pytest`           |
| `java.mk`       | Java (Gradle)     | `./gradlew check`                     | `./gradlew test`   |
| `javascript.mk` | JavaScript (Yarn) | `yarn lint`                           | `yarn test`        |
| `dotnet.mk`     | .NET/C#           | `dotnet format`                       | `dotnet test`      |
| `terraform.mk`  | Terraform         | `terraform fmt` + `validate`          | `terraform plan`   |

The `-include` prefix means Make silently skips the includes if the repository is not cloned yet. Run `make setup` (or `curl ... | bash`) to bootstrap.

See the [`.docs/examples/`](.docs/examples) directory for complete per-provider examples including Makefiles.

### Direct Script Usage

If you prefer calling scripts directly without Makefile includes:

```bash
export SCRIPTS_DIR=$HOME/Development/github.com/rios0rios0/pipelines

# Go linting
$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/run.sh --fix

# Go tests
$SCRIPTS_DIR/global/scripts/languages/golang/test/run.sh

# Security scans
$SCRIPTS_DIR/global/scripts/tools/gitleaks/run.sh
$SCRIPTS_DIR/global/scripts/tools/codeql/run.sh go
$SCRIPTS_DIR/global/scripts/tools/hadolint/run.sh
$SCRIPTS_DIR/global/scripts/tools/trivy/run.sh
$SCRIPTS_DIR/global/scripts/tools/semgrep/run.sh
```

### Testing Pipeline Changes

When developing pipeline modifications, you can test it against development branches:

#### Switch to Development Branch

```bash
export BRANCH=your-feature-branch-name

# Update all pipeline references to use your branch
find . -type f -name "*.yaml" -exec sed -i.bak -E "s|(remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/)[^/]+(/.*)|\\1$BRANCH\\2|g" {} +
```

#### Test Your Changes

```bash
# Update your project's pipeline reference
# Before:
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/golang/go-docker.yaml'

# After:
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/your-feature-branch/gitlab/golang/go-docker.yaml'
```

### Validation & Testing

#### Run Repository Tests

```bash
# Run all validation tests (Go test script + Lambda template validation)
make test

# Run individual test suites
make test-go-script
make test-lambda
```

#### Build Container Images

```bash
# Test container builds locally
make build-and-push NAME=awscli TAG=latest

# Build specific image for testing
docker build -t test-image -f global/containers/awscli.latest/Dockerfile global/containers/awscli.latest/
```

## 🐛 Troubleshooting

### Common Issues & Solutions

#### Pipeline Failures

**Issue: "No directories found to test it" (Go projects)**

- **Cause:** Go project structure doesn't match the expected layout
- **Solution:** Ensure your project has `cmd/`, `pkg/`, or `internal/` directories
- **Alternative:** Modify a test script to include your custom directories

**Issue: "golangci-lint: command not found"**

- **Cause:** golangci-lint not installed or not in PATH
- **Solution:** The script automatically downloads golangci-lint, ensure Docker is available

**Issue: Docker build fails with SSL certificate errors**

- **Cause:** Network restrictions in CI environment
- **Solution:** This is expected in restricted environments; contact your platform administrator

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

**Issue: Hadolint skips analysis**

- **Cause:** No Dockerfiles found in the project
- **Solution:** This is expected for projects without Dockerfiles; Hadolint auto-skips gracefully

**Issue: Trivy IaC scan finds false positives**

- **Cause:** Trivy flags misconfigurations in Terraform, Kubernetes, or Dockerfiles
- **Solution:** Add entries to `.trivyignore` in the project root to suppress known false positives

#### Platform-Specific Issues

**GitHub Actions:**

- **Issue:** Workflow doesn't trigger
- **Solution:** Check repository permissions, ensure workflow file is in `.github/workflows/`

**GitLab CI:**

- **Issue:** "Remote file could not be fetched"
- **Solution:** Verify the remote URL is accessible, check branch name in URL

**Azure DevOps:**

- **Issue:** "Template not found"
- **Solution:** Ensure GitHub service connection is configured correctly

### Environment Requirements

**Minimum Requirements:**

- Docker (for container builds and security tools)
- Git (for repository operations)
- Network access (for downloading tools and dependencies)

**Language-Specific Requirements:**

- **Go:** Go 1.18+ (automatically installed in CI)
- **Python:** Python 3.8+ (automatically managed in CI)
- **Java:** JDK 11+ (automatically managed in CI)
- **Node.js:** Node 16+ (automatically managed in CI)

### Performance Expectations

| Operation         | Expected Duration | Notes                                  |
|-------------------|-------------------|----------------------------------------|
| Script downloads  | 1-5 seconds       | First-time tool downloads              |
| Go linting        | 10-30 seconds     | Depends on codebase size               |
| Security scanning | 2-10 minutes      | Depends on tools and project size      |
| Container builds  | 5-30 minutes      | Depends on base image and dependencies |
| Semgrep analysis  | 5-15 minutes      | Downloads large rule sets              |

**Important:** Never cancel operations that appear to be hanging - they may be downloading large Docker images or rule
sets.

### Getting Help

1. **Check the logs:** Most scripts provide detailed output about what they're doing
2. **Verify environment:** Ensure Docker is running and network access is available
3. **Check examples:** Review the working examples in this README
4. **Review CONTRIBUTING.md:** For development and contribution guidelines
5. **Open an issue:** For bugs or feature requests on GitHub

## 📚 Additional Resources

- **[Contributing Guidelines](CONTRIBUTING.md)** - How to contribute to this project
- **[Changelog](CHANGELOG.md)** - Version history and changes
- **[License](LICENSE)** - MIT License details
- **Examples in `.docs/`** - Screenshots and detailed examples

## 🤝 Contributing

We welcome contributions! This project follows enterprise security and testing standards:

### Before Contributing

1. **Read [CONTRIBUTING.md](CONTRIBUTING.md)** for detailed guidelines
2. **Run tests:** Execute `make test` before submitting changes
3. **Test across platforms:** Validate changes on GitHub, GitLab, and Azure DevOps
4. **Update documentation:** Keep README and changelogs current

### Key Contribution Areas

- Adding support for new programming languages
- Improving security tool integration
- Enhancing container images
- Adding new platform features
- Improving documentation and examples

## 📄 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

---

> **Note:** This repository provides **pipeline templates and automation scripts**, not a runnable application. Users
> consume these templates in their own projects to establish comprehensive CI/CD pipelines with security, quality, and
> testing automation.
