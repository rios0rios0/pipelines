# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

When a new release is proposed:

1. Create a new branch `bump/x.x.x` (this isn't a long-lived branch!!!);
2. The Unreleased section on `CHANGELOG.md` gets a version number and date;
3. Open a Pull Request with the bump version changes targeting the `main` branch;
4. When the Pull Request is merged, a new Git tag must be created using [GitHub environment](https://github.com/rios0rios0/pipelines/tags).

Releases to productive environments should run from a tagged version.
Exceptions are acceptable depending on the circumstances (critical bug fixes that can be cherry-picked, etc.).

## [Unreleased]

## [3.4.0] - 2026-03-19

### Added

- added optional LCOV coverage artifact publishing to JavaScript Azure DevOps test stage and downloading in the SonarQube management step, enabling JS/TS coverage reporting in SonarQube

### Changed

- changed Helm chart builds from mutable `0.0.0-latest` to immutable `0.0.0-<commit>` versioning, ensuring each push produces a unique, traceable chart version
- changed the java pipeline version from 21 to 25
- changed the terraform pipeline version from 1.9.3 to 1.14.7
- changed Go cross-compile script to use `go vet` instead of `go build` for type-checking without linking, plus vet diagnostics
- changed `go-binary.yaml` to disable cross-compile check since GoReleaser already handles multi-platform builds in the delivery stage

### Fixed

- fixed JavaScript Azure DevOps SonarQube step downloading the wrong artifact name `cobertura-coverage` instead of `coverage-cobertura` as published by the test stage

## [3.3.0] - 2026-03-18

### Added

- added code check stage (10) to Helm Azure DevOps pipeline with `helm lint` and `helm template` validation
- added cross-compilation check step to Go pipeline that builds for `linux`, `darwin`, and `windows` (`amd64` + `arm64`) to catch platform-specific type errors at PR time
- added security stage (20) to Helm Azure DevOps pipeline with Semgrep, Gitleaks, Hadolint, and Trivy
- added trap-based cleanup for temporary files in the Go test script ensuring reliable removal on exit

### Changed

- changed Go test script to defer exit on test failure, ensuring all phases (unit tests, integration tests, coverage reports) run to completion before returning the final exit code
- changed Helm chart delivery to always push `0.0.0-latest` and additionally push the tag-derived version on tag builds, matching Docker's dual-tag strategy
- replaced `go-junit-report` with `gotestsum --junitfile` for native JUnit XML generation, merging unit and integration reports into a single `junit.xml`
- replaced raw `go test` with `gotestsum` in the Go test script, providing compact per-package output (`--format pkgname`) and automatic failure summaries at the end of each test phase

## [3.2.0] - 2026-03-14

### Added

- added NVD database caching to Dependency-Check jobs in GitHub Actions and Azure DevOps to avoid re-downloading on every run
- added optional `NVD_API_KEY` secret support to OWASP Dependency-Check jobs across GitHub Actions, GitLab CI, and Azure DevOps Java pipelines

### Changed

- changed `actions/setup-java` from `v4` to `v5` to support Node.js 24 runners

### Fixed

- fixed NVD database cache for Dependency-Check: corrected Maven property from `-DdependencyCheck.dataDirectory` to `-DdataDirectory` and added weekly cache key rotation to prevent stale empty caches

## [3.1.0] - 2026-03-12

### Added

- added .NET/C# pipeline for GitHub Actions with `dotnet.yaml` (testing/quality) and `dotnet-docker.yaml` (Docker delivery) reusable workflows
- added Java (Gradle) pipeline for GitHub Actions with `java.yaml` (testing/quality) and `java-docker.yaml` (Docker delivery) reusable workflows
- added Java (Maven) pipeline for GitHub Actions with `java-maven.yaml` (testing/quality) and `java-maven-docker.yaml` (Docker delivery) reusable workflows
- added JavaScript/Node.js (Yarn) pipeline for GitHub Actions with `javascript.yaml` (testing/quality) and `javascript-docker.yaml` (Docker delivery) reusable workflows
- added JavaScript/Node.js (npm) pipeline for GitHub Actions with `javascript-npm.yaml` (testing/quality) and `javascript-npm-docker.yaml` (Docker delivery) reusable workflows
- added OWASP Dependency-Check SCA job to GitHub Actions and Azure DevOps Java security stages (previously only in GitLab)
- added PHP (Composer) pipeline for GitHub Actions with `php.yaml` (testing/quality) and `php-docker.yaml` (Docker delivery) reusable workflows
- added Ruby (Bundler) pipeline for GitHub Actions with `ruby.yaml` (testing/quality) and `ruby-docker.yaml` (Docker delivery) reusable workflows
- added Safety SCA job to Azure DevOps Python security stage (previously only in GitHub Actions and GitLab)
- added Terraform pipeline for GitLab CI with `terra.yaml` including code check (terraform fmt, TFLint), security (Semgrep, Hadolint, Trivy), and management stages
- added Trivy SCA dependency vulnerability scanning (`trivy fs --scanners vuln`) as a unified SCA layer across all languages and all providers (GitHub Actions, GitLab CI, Azure DevOps)
- added `config.sh` loading to CodeQL for GoLang across all pipelines (GitHub Actions, GitLab CI, Azure DevOps) to support project-level build configuration before analysis
- added `global/scripts/languages/golang/govulncheck/run.sh` shared script for Go vulnerability scanning
- added `global/scripts/shared/changelog-check.sh` standalone script for changelog validation
- added `global/scripts/tools/trivy/run-sca.sh` shared script for Trivy dependency vulnerability scanning
- added `govulncheck` as Go-specific SCA tool across all providers (GitHub Actions, GitLab CI, Azure DevOps) using the official Go vulnerability scanner with call-graph analysis
- added `lint` target to `makefiles/terra.mk` using TFLint for recursive Terraform linting
- added `makefiles/common.mk` and `makefiles/golang.mk` includable Makefile fragments for local pipeline tool usage in downstream projects
- added `terra` CLI pipeline templates for all providers (GitHub Actions `terra.yaml`, GitLab CI `terra/terra.yaml`, Azure DevOps `terra/terra.yaml`) with code check, security, tests, and management stages using the [terra CLI](https://github.com/rios0rios0/terra) wrapper for Terraform/Terragrunt
- added `test-lambda` target to Makefile so `test-lambda-templates.sh` is now part of `make test`
- added `validate` target to `makefiles/terra.mk` that runs format, lint, and test in sequence
- added `yarn npm audit` as JavaScript-specific SCA tool across all providers (GitHub Actions, GitLab CI, Azure DevOps) for dependency vulnerability scanning
