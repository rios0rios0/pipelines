# Pipelines Project

## Getting Started with GitHub

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

## Getting Started with GitLab

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

## Getting Started with Azure DevOps

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

## Contributing


## License

This project is licensed under the MIT License.
