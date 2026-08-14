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
  dart/
    common.sh         # shared helpers (SOURCED, not executed)
    setup/            # Dart or Flutter SDK install from Google's archive
    format/           # dart format gate (--fix rewrites in place)
    analyze/          # dart analyze -> JUnit + JSON + severity gate
    test/             # tests + coverage -> JUnit, Cobertura, LCOV
    unused/           # unused code and unused file detection
    sca/              # OSV-Scanner over pubspec.lock
    cyclonedx/        # Dart SBOM generation
    build/            # release artifacts (APK, AAB, web, exe, ...)
    publish/          # pub.dev publication with a validation gate
```

The Dart family picks its toolchain (`dart` vs `flutter`) from the project's own
`pubspec.yaml`, so one set of scripts serves both. It also supports
`DART_DRY_RUN=true`, which resolves and records every command without installing
or executing anything -- that is what lets `make test` exercise the whole family
offline, with no SDK and no network.

## Convention

- Each tool directory contains a `run.sh` entry point and any configuration files the tool needs (e.g., `.golangci.yml`, `.goreleaser.yaml`).
- Configuration files stored here serve as **defaults**. If the consuming project has its own configuration file, the script either merges it (golangci-lint) or skips generation (goreleaser).
- These tools are invoked by CI pipelines and by local Makefiles.

For **language-agnostic** tools (e.g., CodeQL, Semgrep, Gitleaks, Trivy), see [`../tools/`](../tools/).
