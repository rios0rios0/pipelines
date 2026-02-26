# Contributing

Contributions are welcome. By participating, you agree to maintain a respectful and constructive environment.

For coding standards, testing patterns, architecture guidelines, commit conventions, and all
development practices, refer to the **[Development Guide](https://github.com/rios0rios0/guide/wiki)**.

## Prerequisites

- [Make](https://www.gnu.org/software/make/)
- [Docker](https://docs.docker.com/get-docker/) and [Docker Compose](https://docs.docker.com/compose/install/) v2+
- [Bash](https://www.gnu.org/software/bash/) 4+

## Development Workflow

1. Fork and clone the repository
2. Create a branch: `git checkout -b feat/my-change`
3. Make your changes
4. Run the test suite:
   ```bash
   make test
   ```
5. For Go script changes specifically:
   ```bash
   make test-go-script
   ```
6. Validate across platforms (GitHub Actions, GitLab CI, Azure DevOps) when modifying templates
7. Update `CHANGELOG.md` under `[Unreleased]`
8. Commit following the [commit conventions](https://github.com/rios0rios0/guide/wiki/Life-Cycle/Git-Flow)
9. Open a pull request against `main`

## Testing Changes in a Real Repository

Since this is a templates library, `make test` only validates syntax and scripts. To verify your changes **end-to-end**, point a consuming repository at your branch before opening a PR.

### 1. Push your branch

```bash
git checkout -b feat/my-change
# make your changes
git push -u origin feat/my-change
```

### 2. Update the consuming repository

Pick any repository that already uses this pipeline and change its reference from `main` to your branch name:

**GitHub Actions** — in `.github/workflows/ci.yaml`:
```yaml
# before
uses: 'rios0rios0/pipelines/.github/workflows/go-docker.yaml@main'
# after
uses: 'rios0rios0/pipelines/.github/workflows/go-docker.yaml@feat/my-change'
```

**GitLab CI** — in `.gitlab-ci.yml`:
```yaml
# before
- remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/golang/go-docker.yaml'
# after
- remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/feat/my-change/gitlab/golang/go-docker.yaml'
```

**Azure DevOps** — in `azure-pipelines.yml`:
```yaml
resources:
  repositories:
    - repository: 'pipelines'
      type: 'github'
      name: 'rios0rios0/pipelines'
      ref: 'refs/heads/feat/my-change'    # add or change this line
      endpoint: 'YOUR_GITHUB_SERVICE_CONNECTION'
```

### 3. Run the pipeline

Trigger the CI pipeline in the consuming repository (push a commit, open a PR, or run manually). Confirm all stages pass with your changes.

### 4. Revert the consuming repository

Once validated, revert the reference back to `main` in the consuming repository. Do **not** merge the temporary branch pointer.

## Cross-Platform Compatibility

When modifying pipeline templates or scripts, ensure changes remain compatible with:

- **GitHub Actions**
- **GitLab CI**
- **Azure DevOps Pipelines**
