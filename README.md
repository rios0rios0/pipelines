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

## Cloning the Repository

To clone this repository and use it in your projects, run the following command:

```bash
curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash
```

## Contributing

We welcome contributions! Please read our [Contributing Guidelines](CONTRIBUTING.md) for more information.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
