# Languages

This directory contains **language-specific** tools organized by programming language. Each language subdirectory holds tool-specific folders with scripts and configuration files.

## Structure

```
languages/
  golang/
    golangci-lint/    # Go linter with merged configuration
    goreleaser/       # Go binary release with template config
    govulncheck/      # Go vulnerability checker
    cyclonedx/        # Go SBOM generation
    init/             # Go module initialization
    test/             # Go test runner with coverage
  java/
    checkstyle/       # Java style checking (Google style)
  python/
    cyclonedx/        # Python SBOM generation
```

## Convention

- Each tool directory contains a `run.sh` entry point and any configuration files the tool needs (e.g., `.golangci.yml`, `.goreleaser.yaml`).
- Configuration files stored here serve as **defaults**. If the consuming project has its own configuration file, the script either merges it (golangci-lint) or skips generation (goreleaser).
- These tools are invoked by CI pipelines and by local Makefiles.

For **language-agnostic** tools (e.g., CodeQL, Semgrep, Gitleaks, Trivy), see [`../tools/`](../tools/).
