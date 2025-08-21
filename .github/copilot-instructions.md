# CI/CD Pipeline Templates Repository

**ALWAYS FOLLOW THESE INSTRUCTIONS FIRST.** Only fallback to additional search and context gathering if the information in these instructions is incomplete or found to be in error.

This repository provides comprehensive SDLC pipeline templates for GitHub Actions, GitLab CI, and Azure DevOps across multiple programming languages including GoLang, Java, Python, JavaScript, and .NET.

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
  bash global/scripts/golangci-lint/run.sh  # Works - 1.8s, exits with code 7 (no Go modules)
  
  # Run security scanning with Gitleaks  
  bash global/scripts/gitleaks/run.sh  # Works - 2.0s (downloads Docker image)
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
- **horusec/run.sh** - Exits with code 101 if no horusec config files present
- **dependency-track/run.sh** - Requires `DEPENDENCY_TRACK_TOKEN` and `DEPENDENCY_TRACK_HOST_URL`
- **sonarqube/run.sh** - Requires `sonar-scanner` installed and SonarQube environment
- **semgrep/run.sh** - May run for 10+ minutes, downloads large Docker image
- **golang/test/run.sh** - Requires Go project with cmd/, pkg/, or internal/ directories

## Repository Structure

### Key Directories
- `.github/workflows/` - Reusable GitHub Actions workflows
- `gitlab/` - GitLab CI pipeline templates  
- `azure-devops/` - Azure DevOps pipeline templates
- `global/scripts/` - Shared scripts for linting, security scanning, testing
- `global/containers/` - Docker container definitions
- `global/configs/` - Configuration files

### Pipeline Templates Available
- **GitHub Actions:** `go.yaml`, `go-docker.yaml`, `go-binary.yaml`, `python.yaml`, `python-docker.yaml`
- **GitLab CI:** GoLang, Java, Python, JavaScript, .NET pipelines
- **Azure DevOps:** GoLang, Java, Python, JavaScript, .NET, Terraform pipelines

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
```

**Azure DevOps:**
```yaml
resources:
  repositories:
    - repository: pipelines
      type: github
      name: rios0rios0/pipelines
stages:
  - template: azure-devops/golang/go-arm.yaml@pipelines
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
$SCRIPTS_DIR/global/scripts/golangci-lint/run.sh

# Link golangci-lint config globally
ln -s $SCRIPTS_DIR/global/scripts/golangci-lint/.golangci.yml ~/.golangci.yml
```

## Validation and Testing

### Critical Testing Requirements
- **NEVER CANCEL long-running commands** - Some operations take 10+ minutes
- **Always test across all three platforms** (GitHub, GitLab, Azure DevOps)
- **Validate security scanning tools work** in target environments
- **Test container builds** with proper authentication

### Manual Validation Steps
1. **Clone repository using provided scripts**
2. **Test script execution** in isolated environment
3. **Validate pipeline templates** by including them in test projects
4. **Verify Docker container builds** (may require network access)
5. **Check security scanning tools** download and run correctly

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

Always validate changes by testing the pipeline templates in actual projects rather than testing the repository in isolation.