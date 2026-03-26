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

### Added

- added automatic derivation of `sonar.projectKey` and `sonar.projectName` from CI platform variables (GitHub, Azure DevOps, GitLab), enabling zero-config SonarQube enrollment for new projects
- added test suite for SonarQube auto-derivation logic covering `normalize_sonar_key`, per-platform derivation, env var overrides, and existing property preservation

### Fixed

- fixed inconsistent SonarQube project key sanitization in GitLab templates — now uses full character sanitization matching `run.sh` and Azure DevOps templates

## [4.1.0] - 2026-03-24

### Added

- added `major.minor` Docker tag (e.g., `:1.2`) alongside the full SemVer tag on tag pushes

### Fixed

- fixed Docker delivery composite action failing with `Password required` by adding `actions/checkout@v6`, defaulting `github_token` to `github.token`, and computing image tags via `docker/metadata-action@v5` when not provided
- fixed Docker delivery not publishing SemVer tags (`:X.Y.Z`, `:X.Y`) on bump commits by chaining `delivery-docker` after `delivery-release` and computing Docker tags from the release version
- fixed Docker delivery skipping on `workflow_dispatch` events by adding the event to the `delivery-docker` condition
- fixed Docker delivery tagging with the branch name instead of `latest` on default branch builds

## [4.0.0] - 2026-03-23

### Added

- added Claude Code Review workflow (`claude-code-review.yaml`) for automated PR code review on open/sync/reopen events
- added Claude Code workflow (`claude.yaml`) for AI-assisted issue and PR comment handling via `@claude` mentions
- added JaCoCo XML report auto-detection for Gradle and Maven in `sonarqube/run.sh`
- added Python composite actions (`pdm-lint`, `safety`, `tests/all`) under `github/python/stages/`, replacing inline workflow steps and matching Go's composite action pattern
- added coverage reporting and test results to `go.yaml` via `dorny/test-reporter@v1` and `actions/upload-artifact@v4`
- added coverage reporting and test results to `gradle.yaml` via `dorny/test-reporter@v1` and `actions/upload-artifact@v4` with JaCoCo detection
- added coverage reporting and test results to `maven.yaml` via `dorny/test-reporter@v1` and `actions/upload-artifact@v4` with JaCoCo detection
- added coverage reporting to `npm.yaml` via `davelosert/vitest-coverage-report-action@v2`, `dorny/test-reporter@v1`, and `actions/upload-artifact@v4`, matching `yarn.yaml` features
- added optional SonarQube management stage to `go.yaml` with `sonar_host` input and `sonar_token` secret, matching `yarn.yaml` features
- added optional SonarQube management stage to `gradle.yaml` with `sonar_host` input and `sonar_token` secret, matching `yarn.yaml` features
- added optional SonarQube management stage to `maven.yaml` with `sonar_host` input and `sonar_token` secret, matching `yarn.yaml` features
- added optional SonarQube management stage to `npm.yaml` with `sonar_host` input and `sonar_token` secret, matching `yarn.yaml` features
- added workflow to auto-update major version tags (e.g., `v3`) when a new SemVer release is published, enabling downstream repos to pin to stable `@v3` refs

### Changed

- **BREAKING CHANGE:** changed `dotnet.yaml` to stages 1-3 only, moving `delivery-release` to `dotnet-docker.yaml` following Go/PDM pattern
- **BREAKING CHANGE:** changed `java-maven.yaml` to `maven.yaml` and `java-maven-docker.yaml` to `maven-docker.yaml`, matching the toolchain naming convention
- **BREAKING CHANGE:** changed `java.yaml` to `gradle.yaml` and `java-docker.yaml` to `gradle-docker.yaml`, matching the toolchain naming convention
- **BREAKING CHANGE:** changed `javascript-npm.yaml` to `npm.yaml` and `javascript-npm-docker.yaml` to `npm-docker.yaml`, matching the toolchain naming convention
- **BREAKING CHANGE:** changed `javascript.yaml` to `yarn.yaml` and `javascript-docker.yaml` to `yarn-docker.yaml`, matching the toolchain naming convention
- **BREAKING CHANGE:** changed `php.yaml` to `composer.yaml` and `php-docker.yaml` to `composer-docker.yaml`, matching the toolchain naming convention
- **BREAKING CHANGE:** changed `ruby.yaml` to `bundler.yaml` and `ruby-docker.yaml` to `bundler-docker.yaml`, matching the toolchain naming convention
- changed Go cross-compile CI job to run 6 OS/arch targets in parallel via GitHub Actions matrix strategy instead of sequentially
- changed Go cross-compile script to support single-target mode via `CROSS_GOOS`/`CROSS_GOARCH` environment variables and parallel execution for all-targets mode
- changed `bundler.yaml` to stages 1-3 only, moving `delivery-release` to variant workflows following Go/PDM pattern
- changed `composer.yaml` to stages 1-3 only, moving `delivery-release` to variant workflows following Go/PDM pattern
- changed `go-docker.yaml`, `go-binary.yaml`, and `go-library.yaml` to declare and forward `sonar_host` input and `sonar_token` secret to the inner `go.yaml` workflow
- changed `gradle-docker.yaml` to declare and forward `sonar_host` input and `sonar_token` secret to the inner `gradle.yaml` workflow
- changed `gradle.yaml` to stages 1-3 only (code check, security, tests), moving `delivery-release` to variant workflows following Go/PDM pattern
- changed `maven-docker.yaml` to declare and forward `sonar_host` input and `sonar_token` secret to the inner `maven.yaml` workflow
- changed `maven.yaml` to stages 1-3 only, moving `delivery-release` to variant workflows following Go/PDM pattern
- changed `npm-docker.yaml` to declare and forward `sonar_host` input and `sonar_token` secret to the inner `npm.yaml` workflow
- changed `npm.yaml` to stages 1-3 only, moving `delivery-release` to variant workflows following Go/PDM pattern
- changed `pdm-docker.yaml` to call `pdm.yaml` via `uses:` and add delivery jobs, matching the standard `-docker.yaml` composition pattern used by Go and all other languages
- changed `pdm.yaml` `tests-test_all` dependency chain to include all security jobs (SAST + SCA), matching Go's behavior
- changed `pdm.yaml` to stages 1-3 only (code check, security, tests), moving `delivery-release` to variant workflows following Go's pattern
- changed `pdm.yaml` to use composite actions instead of inline container-based steps, migrating from `python:3.10-pdm-bullseye` container to `actions/setup-python@v6` with Python `3.13`
- changed `python.yaml` to `pdm.yaml` and `python-docker.yaml` to `pdm-docker.yaml`, matching the Azure DevOps and GitLab naming convention (package manager prefix, not language)
- changed `sonarqube/run.sh` to detect JaCoCo coverage reports at Gradle and Maven standard paths
- changed `yarn-docker.yaml` to declare and forward `sonar_host` input and `sonar_token` secret to the inner `yarn.yaml` workflow
- changed `yarn.yaml` to stages 1-3 only (code check, security, tests, management), moving `delivery-release` to variant workflows following Go/PDM pattern

### Fixed

- fixed Zig setup action failing with HTTP 404 when downloading Zig `0.15.2` by upgrading `mlugg/setup-zig` from `v1` to `v2`
- fixed `pdm-docker.yaml` skipping all code check, security, and test stages when used standalone
- fixed `pdm.yaml` display names for `flake8` and `mypy` jobs from `style:` to `quality:` to match their job IDs
- fixed `yarn.yaml` and `npm.yaml` SonarQube job failing at workflow parse time by removing `secrets.sonar_token` from job-level `if` condition (GitHub Actions does not allow `secrets` context in reusable workflow job `if` expressions)
- fixed missing `continue-on-error: true` on `mypy` and `safety` jobs to match Azure DevOps golden standard

### Removed

- removed Android targets (`android/amd64`, `android/arm64`) from Go cross-compile check, CI matrix, and GoReleaser template because Zig does not bundle Android bionic `libc` headers (see [ziglang/zig#23906](https://github.com/ziglang/zig/issues/23906))
- removed Zig setup step from cross-compile composite action (no longer needed without Android targets)

## [3.4.0] - 2026-03-20

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
- added changelog validation to the basic checks step, verifying that `CHANGELOG.md` is modified and entries are under the `[Unreleased]` section
- added descriptive echo messages to `format` and `lint` targets in `makefiles/terra.mk` for better pipeline output readability
- added end-to-end testing instructions to `CONTRIBUTING.md` showing how to point a consuming repository at a feature branch for each platform
- added new container to support Golang version `1.26.0`
- added optional K8s deployment stage to `azure-devops/golang/go-docker.yaml` - automatically deploys with commit SHA label when `K8S_DEPLOYMENT_NAME` variable is set
- added per-provider usage examples in `.docs/examples/` for GitHub Actions, GitLab CI, and Azure DevOps (Go with Docker)
- added rebase-check quality gate to the code-check stage across all providers (GitHub Actions, GitLab CI, Azure DevOps) and all languages, failing the pipeline when a PR/MR branch is not rebased on the default branch
- added symbolic links under `github/` for all importable GitHub Actions workflows (javascript, java, php, ruby, dotnet, terra) to match the existing golang/python pattern

### Changed

- changed Azure DevOps JavaScript Kubernetes deployment step to patch `app.kubernetes.io/version` with `$(Build.SourceVersion)` and wait for `rollout status` (`--timeout=300s`) instead of forcing a restart
- changed Golang version to `1.26.0` on lambda files
- changed `cleanup.sh` to accept a `TOOL_NAME` variable, scoping report cleanup to `build/reports/<tool>/` instead of wiping the entire `build/reports/` directory
- changed artifact publish paths across all providers (Azure DevOps `targetPath`, GitHub Actions `path`) to reference tool-specific subdirectories instead of the shared `build/reports/` root
- consolidated `.github/workflows/ci.yaml` into 2 focused jobs (`validate` + `lint-scripts`), removing superficial security and documentation checks
- moved test scripts from root to `.github/tests/` directory to reduce clutter for downstream users
- renamed `rebase-check` step to `basic-checks` across all pipeline vendors (GitHub Actions, GitLab CI, Azure DevOps)
- renamed the existing `lint` target in `makefiles/terra.mk` to `format` to accurately reflect its purpose (`terra format`)
- rewrote `clone.sh` as idempotent installer with `PIPELINES_HOME` support, auto-directory creation, and `git pull` on subsequent runs

### Fixed

- fixed Go library workflow (`go-library.yaml`) default `tag_prefixes` from `[""]` to `["", "v"]` so it creates both `X.Y.Z` and `vX.Y.Z` tags as documented
- fixed JavaScript Azure DevOps SonarQube step failing when `cobertura-coverage` artifact does not exist by adding `continueOnError: true` to the download step
- fixed Python CycloneDX BOM generation using an independent `BOM_PATH` variable instead of `$PREFIX$REPORT_PATH`, causing `dependency-track` upload to fail with "No such file or directory" because the BOM was written to a different path than expected
- fixed SAST tool report cleanup deleting reports from other tools by isolating each tool's output into its own `build/reports/<tool>/` subdirectory
- fixed ShellCheck warnings in `golang/test/run.sh` (SC2046) and `semgrep/run.sh` (SC2140)
- fixed SonarQube failing on Azure DevOps and GitLab when projects have no test coverage by detecting missing coverage files and clearing coverage report path properties before running `sonar-scanner`
- fixed Yarn Berry compatibility in `javascript.yaml` by moving `corepack enable` before `actions/setup-node` cache step, which failed when projects declared `packageManager: yarn@4.x` in `package.json`
- fixed `dependency-track` execution
- fixed `global/scripts/tools/sonarqube/run.sh` by adding `coverage.txt` in coverage file patterns
- fixed `make sast` aggregate target aborting on the first tool failure by adding the `-` prefix to all SAST tool recipes in `makefiles/common.mk`
- fixed `makefiles/terra.mk` `format` target error message that incorrectly suggested running `make lint` instead of `make format`
- fixed changelog validation crashing when the changelog has no versioned sections (only `[Unreleased]`), caused by `grep -v` returning exit code 1 under `bash -e -o pipefail`
- fixed lambda template test failures by adding missing example files and documentation
- fixed rebase check false positive when the PR was merged while CI was still running
- fixed test execution for `terra` pipeline

## [3.0.0] - 2026-02-10

### Added

- added CodeQL as SAST security scanning tool with native CLI support for Go, Python, Java, JavaScript, and C#
- added Hadolint as `Dockerfile` linting tool with auto-discovery of `Dockerfiles` across all pipelines (GitHub Actions, GitLab CI, Azure DevOps)
- added OCI image labels to Azure DevOps Docker builds for traceability (`org.opencontainers.image.revision`, `org.opencontainers.image.ref.name`, `org.opencontainers.image.created`, `org.opencontainers.image.source`)
- added Trivy as IaC misconfiguration scanner for Terraform, Kubernetes, and `Dockerfiles` across all pipelines (GitHub Actions, GitLab CI, Azure DevOps)
- added `github/global/stages/20-security/codeql/action.yaml` composite action using the official `github/codeql-action`
- added `github/global/stages/20-security/hadolint/action.yaml` and `github/global/stages/20-security/trivy/action.yaml` composite actions
- added `gitlab/global/stages/20-security/codeql.yaml` and `azure-devops/global/stages/20-security/codeql.yaml` as standalone templates separated from Docker-based tools
- added `gitlab/global/stages/20-security/hadolint.yaml` and `azure-devops/global/stages/20-security/hadolint.yaml` templates for Dockerfile linting
- added `gitlab/global/stages/20-security/trivy.yaml` and `azure-devops/global/stages/20-security/trivy.yaml` templates for IaC misconfiguration scanning
- added `global/scripts/tools/codeql/run.sh` script that downloads CodeQL CLI bundle and runs security-and-quality analysis
- added `global/scripts/tools/hadolint/run.sh` script that downloads Hadolint binary and lints `Dockerfiles` with SARIF output
- added `global/scripts/tools/trivy/run.sh` script that downloads Trivy and scans for IaC misconfigurations with SARIF output
- added K8s deployment template that patches deployments with commit SHA label (`app.kubernetes.io/version`) for observability in Grafana/Prometheus via `kube_pod_labels` metric
- added Azure DevOps global K8s deployment template (`azure-devops/global/stages/50-deployment/k8s-deployment.yaml`)
- updated GitLab K8s deployment to include commit SHA label in pod template
- added `go-library.yaml` pipeline with Azure DevOps to deliver Go libraries
- added `make test` and `make test-go-script` targets for automated testing
- added a generic configuration to run CycloneDX for Python projects
- added complete test validation suite with `.github/tests/test-go-validation.sh` script
- added optional `IMAGE_NAME` parameter to Azure DevOps global docker delivery template to allow custom image names (defaults to repository name if not provided)
- added optional `RESOLVE_S3` flag to Azure DevOps Go SAM delivery to support bucket auto resolving

### Changed

- changed Go pipeline with GitHub to use GoReleaser instead of manually build
- changed Python version from `3.13` to `3.14` on Azure DevOps modules
- changed the Node version from `18.19.0` to `20.18.3` on Azure DevOps modules
- changed the lambda deployment to use env vars instead of parameters in delivery and deployment steps
- changed the structure on Azure DevOps to have files for each step inside each stage
- enhanced coverage accuracy by using `-coverpkg` with all packages when tests are available
- refactored `docker.yaml` security templates to only contain Docker-based tools (Semgrep, Gitleaks), with CodeQL in its own `codeql.yaml` template
- replaced Horusec SAST tool with CodeQL across all pipelines (GitHub Actions, GitLab CI, Azure DevOps) due to Horusec being unmaintained
- updated GoLang version to `1.25.7` on all pipelines and modules
- updated `CONTRIBUTING.md` and `copilot-instructions.md` with mandatory testing requirements

### Fixed

- fixed Azure DevOps Go SAM delivery to normalize `RESOLVE_S3` booleans so `--resolve-s3` works with Azure `True/False` (capitalized) values
- fixed GoLang `1.25.1` compatibility issue in `global/scripts/languages/golang/test/run.sh` by implementing comprehensive coverage reporting
- fixed coverage reporting to include all packages with Go files, not just packages with tests
- fixed deployment issue to deploy an AWS Lambda with SAM CLI
- fixed missing `Scripts.Directory` configuration in `pdm-python3.14.yaml` by including the required `scripts-repo.yaml` template
- fixed multi-platform builds failing for `go1.x-awscli` containers
- fixed synthetic coverage generation for projects with packages but no tests
- fixed the cache task in `azure-devops/global/stages/40-delivery/docker.yaml` to create the `buildx` cache
- fixed untested packages now appear as 0% covered instead of being excluded from coverage reports
- fixed workflow and delivery for GitHub inside Python Docker

### Removed

- **BREAKING CHANGE:** removed Horusec scripts (`global/scripts/horusec/`), configuration (`default.json`), and GitHub Action (`docker-horusec/`)
- removed cache task from `database.yaml` template in the Azure DevOps GoLang pipeline since it was failing to restore cache with readonly files

## [2.2.0] - 2025-04-16

### Added

- added Azure global `docker.yaml` delivery template to be used by all languages
- added `arm-container.yaml` to run a container in Azure Container Instance
- added `arm-parameters.yaml` to generically construct `ARM` parameters from library variables
- added `checkstyle.xml` config file for Azure DevOps Java pipeline
- added a new optional parameter called `CUSTOM_PARAMETERS` in `go-arm-az-function` to add custom parameters in resource group deployment
- added a new pipeline in Azure DevOps for .NET Core (C#)
- added a new pipeline in Azure DevOps for Terraform
- added a new rule to ignore the Swagger comments to `godot` linter in `golangci-lint`
- added a new rule to ignore the docs folder in `golangci-lint`
- added another stage's template `acr-container-deployment.yaml`, introduced new test steps' template: `test.yaml` and new test stage: `acr.yaml` to the GoLang pipeline to log in into ACR before running tests
- added messages to show application states in the `test_e2e` job
- added new language support for Java in Azure DevOps pipelines
- added new parameters: `RUN_BEFORE_BUILD` and `DOCKER_BUILD_ARGS` to Azure DevOps GoLang delivery stage template to allow running a script before the build and passing arguments to the Docker build command
- added the `go1.23.4.yaml` template to the GoLang Docker delivery stage

### Changed

- changed GitLeaks inside Azure DevOps to clone the full repository instead of just a shallow clone
- changed `PIPELINE_FIREWALL_NAME` from a pipeline parameter to a job variable
- changed `azure-devops/global/stages/50-deployment/database.yaml` cache keys to include subfolders
- changed `docker.yaml` Azure's GoLang delivery stage to use the global `docker.yaml` template and removed unnecessary execution of the `./config.sh` script since it's already done by the `go1.23.4.yaml` template
- changed `docker.yaml` Azure's JavaScript delivery stage to use the global `docker.yaml` template since it was being repeated
- changed `execute-command-opensearch-dashboards.yaml` Yarn cache keys to use the `yarn.lock` of OSD and plugin
- changed `go.yaml` GoLang's test stage to use `test.yaml` template
- changed cache strategy for JavaScript projects using Azure DevOps pipelines
- changed the OSD version to `2.19.1` due to an upgrade request
- changed the `.golangci.yml` configuration file to upgrade the `@maratori`'s configuration to `v1.64.7`
- changed the `azure-devops/javascript/stages/50-deployment/k8s.yaml` to run an external Kubernetes file
- changed the dynamic deployment to `PublishPipelineArtifact` the files to deploy the Azure Function
- corrected miss-used template files for .NET in Azure DevOps pipelines
- updated `.golangci.yml` to the new version format
- updated the image tag for the GoLang Docker delivery stage to retrieve the complete tag name from an environment variable

### Fixed

- fixed GoLang pipeline to work with dynamic deployment
- fixed Java pipeline for Azure DevOps by setting up local `gradle.properties` file
- fixed JavaScript delivery and deployment stages in Azure DevOps by inserting the name for the build and push step
- fixed dynamic variable `CONTAINER_IMAGE` for production and development environment
- fixed dynamic variable `CONTAINER_IMAGE` to get value from the delivery stage
- fixed node modules cache error of the Azure pipeline for JavaScript
- fixed script that kills processes created by OpenSearch Dashboards
- fixed the blank version error of `golangci-lint`
- fixed the seeders and migrations skip condition bug on the `database.yaml`
- fixed the wrong parameter usage by changing Runtime Expressions to Template Expressions for Azure's Global docker delivery template
- fixed wrong usage of CycloneDX library for GoLang

### Removed

- removed unused variable `DOCKER_CONTAINER_TAG`

## [2.1.0] - 2024-12-27

### Added

- added Python pipelines for GitHub actions
- added `clone.sh` script into the root to help local development
- added a command to run `rename_vars.sh` file
- added a new step to publish the code coverage for Azure DevOps
- added a new task in Azure DevOps for GoLang delivery to retrieve a list of outbound IP addresses
- added a new template to deploy an Azure Function in an existing Resource Group
- added a step to check if a database exists in the GoLang delivery pipeline before executing migration and seeder tasks
- added artifact generation for log files created in the end-to-end testing job
- added artifact upload for SAST pipelines in GitHub Actions
- added building tests for GoLang inside GitLab pipelines
- added cache for `execute-command-opensearch-dashboards.yaml` template to cache the node modules and speed up the pipeline
- added cache for tests and delivery stages in the Azure DevOps JavaScript pipeline
- added command to run end-to-end tests for JS projects
- added management step for Azure DevOps environment

### Changed

- changed GitLab `yarn.yaml` Node image version to `18.17.1`
- changed GoLang pipeline for Azure DevOps to use caching in the delivery stage
- changed GoLang test script to install docker used by test containers in integration tests
- changed GoLang test script to run integration tests separately and one per time
- changed GoLang to version `1.23.4`
- changed the Horusec JSON configuration file to ignore `pipelines_*` directory created by GitHub Actions
- changed JavaScript pipeline for Azure DevOps to publish the code coverage in Sonarqube
- changed all display names and conditions to obey a certain position for all Azure DevOps tasks
- changed the end-to-end test job to receive a different pool
- changed the search location of the folder generated by Cypress
- changed stages for GoLang in Azure DevOps to be called after configuration
- changed a task that publishes artifact from `PublishBuildArtifact` to `PublishPipelineArtifact` in Azure DevOps JavaScript `execute-command-opensearch-dashboards.yaml` template
- changed the Azure DevOps to execute the migrations and seeders in different tasks
- changed the C# pipeline to run tests with the debug configuration instead of release
- changed the OSD version to `2.18.0` due to an upgrade request
- changed the binary copy process in the delivery stage of Azure DevOps to a more generic approach
- changed the validation to create or update the Resource Group for dynamic Azure functions
- changed the way to validate the `AZURE_DEPLOY_CACHE_HIT` in the deployment stage in Azure DevOps
- corrected SonarQube scanning tag versions and blame information for Azure DevOps and GitLab
- updated the GoLangCI-Lint pipeline to use a tweaked version of `@maratori`'s config
- upgraded `actions/checkout@v3` that was using a deprecated Node.js version

### Fixed

- fixed Dependency Track to avoid creating many of the same projects
- fixed GoLang delivery stage for Azure DevOps only to execute a task when previous tasks are successful
- fixed GoLang pipeline for GitHub Actions missing permissions to install dependencies
- fixed GoLang test script to set the `GOPATH` variable just when it's not set (it was preventing cache in Azure DevOps)
- fixed Golang delivery to register multiple functions using `api*/` wildcard
- fixed Python management step to adjust for commands for the non-Debian image
- fixed Python management step to install the necessary package before executing the command
- fixed artifact generation for end-to-end tests
- fixed cache keys in the GoLang delivery stage for Azure DevOps
- fixed the dependency track stage in the GoLang Azure DevOps pipeline to set up the correct environment
- fixed the Azure DevOps delivery stage for GoLang by adding a `goose-db` version table hash for the migrations and seeders caches to work based on properly versioning
- fixed the Azure DevOps delivery stages by adding one more condition to run only when previous stages succeeded
- fixed the Azure DevOps delivery stages conditions to run only when there were no errors in the earlier stages instead of checking for success
- fixed the GoLang Debian pipeline failing to upload the `.deb` file to the GitLab releases
- fixed the GoLang building step in the Azure DevOps delivery step to create an output directory before compiling
- fixed the GoLang delivery stage for Azure DevOps by adding the `GOPATH` environment variable
- fixed the GoLang for Azure DevOps stages to use the `config.sh` script as a source from each project
- fixed the GoLang pipeline for Azure DevOps to use an optional cache in the delivery stage
- fixed the GoLang test script to test the `pkg` directory to avoid excluding lib-only directories from testing
- fixed the error in `global/scripts/languages/golang/test/run.sh` where `cmd` and `internal` folders were both required at the same time
- fixed the incorrect string concatenation of the `PREFIX` and `REPORT_PATH` variables
- fixed the task for Azure DevOps GoLang to avoid failing if there's no function or resource group deployed
- fixed the task in the GoLang delivery stage to retrieve only the last function app
- fixed the task in the delivery stage for JavaScript in Azure DevOps to download the artifact to the correct directory

### Removed

- removed duplicated code of SonarQube and DependencyTrack for GitLab and Azure DevOps
- removed the explicit installation of Azure CLI version `2.56` to use the pre-installed LTS version
- removed unused variables in the template for fixed and dynamic Azure functions

## [2.0.0] - 2024-08-07

### Added

- added Alibaba `access-key-id` regex to `allowlist`
- added Azure DevOps support for JavaScript
- added Dependency Track and SonarQube for GoLang projects
- added Java support on the .NET pipeline
- added Kubernetes deployment for all languages in GitLab CI
- added Maven support for Java projects
- added Python steps for building and delivery via `PDM` in Azure DevOps
- added Python steps for security and code-check in Azure DevOps
- added SonarQube for Java and Python projects
- added `musl-tools` in the `goreleaser` pipeline to support building with `musl`
- added `pdm-prod.yaml` to only install production and test dependencies
- added a new env variable for Java to avoid `out-of-memory` error inside the security step
- added a new step to replace the environment variables contained inside the `yaml` file
- added a script into the GoLang delivery to get the new `siteName` variable
- added a script into the GoLang delivery to seed the database using `Goose`
- added condition to Jobs in Azure DevOps Pipelines to only proceed if the previous job was successful
- added option to override a Semgrep rule
- added skeleton for .NET project pipelines with basic steps
- added step to create and delete firewall rule to run migrations
- added step to run migrations in Azure Pipelines
- added a task in GoLang stage delivery to replace the value of Azure function settings variables with library variables
- added tasks to publish all security reports as Azure artifacts in Azure DevOps
- added the JavaScript rules to test, monitor, and deploy
- added the `goreleaser` pipelines
- added the binary release feature for GoLang pipelines
- added the code check step for GoLang inside the GitHub Actions provider - [#19](https://github.com/rios0rios0/pipelines/issues/19)
- added the exposure for the coverage in Python projects
- added the missing configuration to Azure DevOps deployment with JavaScript

### Changed

- **BREAKING CHANGE:** changed the structure to support more than one CI/CD platform
- changed JavaScript deployment to continue tasks with error
- changed the Node version from `16.20.0` to `18.19.0`
- changed Semgrep only to use the default `.semgrepignore` file if custom is not available
- changed SonarQube to be inside the management step instead of the delivery step
- changed the Gradle version from `8.1` to `8.7`
- changed release code at every step to have a regex more flexible to catch in any merge case
- changed the GoLang code to have multiple standards to run testing
- changed the GoLang linter configuration to use the project-specific config
- changed the GoLang pipeline to match with the GitHub merge commit message
- changed the GoLang pipeline to remove the redundant make command
- changed the GoLang version from `1.19.9` to `1.22`
- changed the GoLang version in Azure DevOps from `1.20` to `1.22.0`
- changed the Java projects to have deployment using Kubernetes environments
- changed the OSD version to `2.15.0` due to an upgrade request
- changed the Python pipeline to fix the dependency track stage by making sure the required packages are installed before executing the script
- changed the `SETTINGS` variable in Azure DevOps GoLang delivery
- changed the `pdm-prod` abstract to use its cache
- changed the directory of migrations into the GoLang delivery
- changed the position of the script to get pipeline variables and added a new variable to be re-used in all code
- changed the publish function task in Azure DevOps GoLang delivery to use Azure CLI version `2.56.0` instead of Azure Task because after this version GoLang Azure Function is having time-out problems
- changed the version of the container GoLang to `1.19`
- corrected GoLang delivery and deployment to have the default image and the proper format
- corrected Horusec issue with the Docker version
- corrected Semgrep to add the ability to merge the ignored rules files
- corrected the coverage artifact to be uploaded with the XML report
- corrected the way the delivery and deployment steps are skipped or not in Azure DevOps
- corrected typos in the shell script
- corrected use of `stageDependencies` in the deployment stage
- refactor firewall rules for migrations in the delivery stage
- simplified the patching mechanism in the deployment step for JavaScript projects

### Removed

- removed `after_script` from the JavaScript code check step

### Fixed

- fixed GoLang delivery script not exiting with a non-zero exit code when the test fails
- fixed GoLang test script not exiting with a non-zero exit code when the test fails
- fixed Gradle pipeline for Java projects in library mode which was missing the artifact for the management step
- fixed the JS pipeline to output the right tag in the delivery step
- fixed the regex matching the merge commit messages
- fixed the wrong Java JRE package

## [1.0.0] - 2023-01-02

### Added

- added GoLang support with the formatting basic checking
- added SAM delivery and deployment as independent approaches
- added the ability to merge config files in the `golanglint-ci`
- added the ability to run customized scripts in Debian-based images

### Changed

- changed the GoLang configuration linter to disable the `depguard` rules
- changed the structure to support two package managers in the Java category
- corrected GitLeaks script condition to test if there was an error
- corrected GoLang images to detect the right `$GOPATH`
- corrected GoLang tests step to avoid issues when there's no test at all in the application
- corrected all the structures to have segregated caches and numbered step-by-step jobs

### Removed

- removed Alpine images from GoLang stages because it doesn't work without `gcc` and `g++`
