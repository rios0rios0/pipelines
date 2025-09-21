# pipelines
Welcome to the Pipelines Project! This repository provides a comprehensive Software Development Life Cycle (SDLC) pipeline to help software engineers achieve a quick, free, and seamless development process. It includes pipelines for each application within this development group, featuring tools for Static Application Security Testing (SAST), Software Composition Analysis (SCA), Software Supply Chain Assurance (SSCA), and testing for various programming languages.

## Getting Started

### GitHub
To get started with GitHub, use the following workflow configuration:

```yaml
name: 'default'

on:
  push:
    branches:
      - 'main'
    tags:
      - '*'
  pull_request:
    branches:
      - 'main'
  workflow_dispatch:

permissions:
  checks: 'write' # code_check-style_golangci_lint
  contents: 'write' # delivery-release

jobs:
  default:
    uses: 'rios0rios0/pipelines/.github/workflows/go-docker.yaml@main'
```

Example for GoLang:

![github-golang](.docs/github-golang.png)

### GitLab
To get started with GitLab, include the following configuration:

```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/golang/go-docker.yaml'

.delivery:
  script:
    - docker build -t "$REGISTRY_PATH$IMAGE_SUFFIX:$TAG" -f .ci/40-delivery/Dockerfile .
  cache:
    key: 'test:all'
    paths: !reference [ .go, cache, paths ]
    policy: 'pull'
```

Example for Java:

![gitlab-java](.docs/gitlab-java.png)

### Azure DevOps
To get started with Azure DevOps, use the following pipeline configuration:

```yaml
trigger:
  branches:
    include:
      - 'main'
  tags:
    include:
      - '*'

pool:
  vmImage: 'ubuntu-latest'

variables:
  - ${{ if startsWith(variables['Build.SourceBranch'], 'refs/tags/') }}:
      - group: 'your-tag-group-for-production'
  - ${{ else }}:
      - group: 'your-tag-group-for-development'

resources:
  repositories:
    - repository: 'pipelines'
      type: 'github'
      name: 'rios0rios0/pipelines'
      endpoint: 'SVC_GITHUB'

stages:
  - template: 'azure-devops/golang/go-arm.yaml@pipelines'
```

#### Shared Environment Variables
Shared between all pipelines, and all projects:

| Variable Name    | Description         |
|------------------|---------------------|
| `SONAR_HOST_URL` | SonarQube host URL. |
| `SONAR_TOKEN`    | SonarQube token.    |

#### Specific Environment Variables (.NET)
Specific to a .NET project (not shared with other projects):

| Variable Name        | Description             |
|----------------------|-------------------------|
| `SONAR_PROJECT_NAME` | SonarQube project name. |
| `SONAR_PROJECT_KEY`  | SonarQube project key.  |

Example for GoLang:

![azure-devops-golang](.docs/azure-devops-golang.png)

## Cloning the Repository
To clone this repository and use it in your projects, run the following command:

```bash
curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash
```

## Tricks to use locally

```bash
curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash
ln -s $USER/Development/github.com/rios0rios0/pipelines/global/scripts/golangci-lint/.golangci.yml ~/.golangci.yml
```

or

```bash
curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash
export SCRIPTS_DIR=/home/$USER/Development/github.com/rios0rios0/pipelines
$SCRIPTS_DIR/global/scripts/golangci-lint/run.sh # or any other script

# Run golangci-lint with automatic fixing enabled
$SCRIPTS_DIR/global/scripts/golangci-lint/run.sh fix
# or alternatively
$SCRIPTS_DIR/global/scripts/golangci-lint/run.sh --fix
```

## Running Dev/Testing Branches
In the dev branch of pipelines, you can use the following command to replace all the references to the `main` branch:

```bash
export BRANCH=fix/golang
find . -type f -name "*.yaml" -exec sed -i.bak -E "s|(remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/)[^/]+(/.*)|\1$BRANCH\2|g" {} +
```

After you push these changes to the dev/testing branch, update the references in your repository to point to the new branch:

```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/$BRANCH/gitlab/golang/go-debian.yaml'
```

## Contributing
We welcome contributions! Please read our [Contributing Guidelines](CONTRIBUTING.md) for more information.

## License
This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
