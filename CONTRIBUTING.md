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

## Cross-Platform Compatibility

When modifying pipeline templates or scripts, ensure changes remain compatible with:

- **GitHub Actions**
- **GitLab CI**
- **Azure DevOps Pipelines**
