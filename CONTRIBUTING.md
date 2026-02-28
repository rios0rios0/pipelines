# Contributing

Contributions are welcome. By participating, you agree to maintain a respectful and constructive environment.

For coding standards, testing patterns, architecture guidelines, commit conventions, and all
development practices, refer to the **[Development Guide](https://github.com/rios0rios0/guide/wiki)**.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) 20.10+ (for building and pushing container images)
- [GNU Make](https://www.gnu.org/software/make/)
- [ShellCheck](https://www.shellcheck.net/) (for linting shell scripts)
- [Python 3](https://www.python.org/downloads/) with `pyyaml` (for YAML validation)
- [Go](https://go.dev/dl/) 1.25+ (for Go validation tests)

## Development Workflow

1. Fork and clone the repository
2. Create a branch: `git checkout -b feat/my-change`
3. Ensure all shell scripts are executable:
   ```bash
   chmod +x global/scripts/**/run.sh
   ```
4. Validate YAML syntax across all providers:
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('<template>'))"
   ```
5. Lint shell scripts with ShellCheck:
   ```bash
   shellcheck --severity=warning global/scripts/**/*.sh
   ```
6. Run all validation tests:
   ```bash
   make test
   ```
7. Build and push a container image (if modifying containers):
   ```bash
   make build-and-push NAME=<image-name> TAG=<tag>
   ```
8. Commit following the [commit conventions](https://github.com/rios0rios0/guide/wiki/Life-Cycle/Git-Flow)
9. Open a pull request against `main`
