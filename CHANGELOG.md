# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

When a new release is proposed:

1. Create a new branch `bump/x.x.x` (this isn't a long-lived branch!!!);
2. The Unreleased section on `CHANGELOG.md` gets a version number and date;
3. Open a Pull Request with the bump version changes targeting the `main` branch;
4. When the Pull Request is merged, the `release.yaml` workflow automatically creates a Git tag and GitHub Release.

Releases to productive environments should run from a tagged version.
Exceptions are acceptable depending on the circumstances (critical bug fixes that can be cherry-picked, etc.).

## [Unreleased]

### Added

- added `global/scripts/languages/terraform/terra-test/run.sh` — a shared test runner that iterates `modules/*/tests/*.tftest.hcl`, invokes `terraform test -junit-xml=<path>` per module (requires Terraform `1.11+`, already pinned by `terra install`), aggregates every per-module JUnit into a single `<testsuites>` bundle at `build/reports/terra-tests.xml`, and emits a coverage summary at `build/reports/terra-coverage.{md,json}`. Coverage measures *breadth* (`tested_modules / total_modules`) plus aggregate case counts (passed / failed / errored) because Terraform has no native line-coverage concept — a plan/apply exercises every expression or none. Skips modules without a `tests/` directory (or with an empty `tests/` that would trip `terraform test` with "no test files found") so consumers onboard incrementally instead of all-at-once
- added `global/scripts/languages/terraform/terratest/run.sh` — a shared [Terratest](https://terratest.gruntwork.io/) runner that drives the consumer's Go test suite under `tests/terratest/` and publishes the results as JUnit XML at `build/reports/junit-terratest.xml`. Complements the `terra-test` runner by covering what native `terraform test` can't: stacks and environments that reference private git-SSH modules or resolve `dependency.*.outputs.*` (where a real `terraform validate` would need credentials), plus cross-module invariants that are awkward to express in a `.tftest.hcl` file. Auto-installs `go-junit-report` on first run so agents don't need it pre-provisioned. No-op when the consumer has no `tests/terratest/` directory — opt-in by creating the directory
- added `test-terratest` target to `makefiles/terra.mk` — calls the Terratest runner. The existing `test` target still covers `terraform test` (modules); `test-terratest` is the complementary call for stack/environment / cross-module coverage. The `validate` composite target now chains `format lint test test-terratest` so both tiers run from `make validate`
- added a second job `test_terratest` to `azure-devops/terra/stages/30-tests/terra.yaml` that pins Go 1.23 via `GoTool@0`, runs the Terratest runner, and publishes the JUnit via `PublishTestResults@2` (`failTaskOnFailedTests: true`). `dependsOn: []` so it runs in parallel with the `test_all` job for fast feedback
- added `coverage` target to `makefiles/terra.mk` — reuses both runners (terra-test + terratest) but wraps each in `|| true` so operators can pull the full report off a red branch without masking CI failures. `REPORT_PATH` is overridable (defaults to `build/reports`)
- added Cobertura emission to `global/scripts/languages/terraform/terra-test/run.sh` — writes `build/reports/terra-coverage.xml` alongside the existing Markdown + JSON summaries. Each module is one `<class>` with one `<line>`: `hits=1` when the module has `tests/*.tftest.hcl`, `hits=0` when it doesn't. `lines-valid = total_modules`, `lines-covered = tested_modules`, so the `line-rate` attribute matches the breadth percentage
- added `PublishCodeCoverageResults@2` task to `azure-devops/terra/stages/30-tests/terra.yaml` pointing at `terra-coverage.xml`. Azure DevOps renders the **Code Coverage** tab on every build showing `tested / total` modules as a percentage — no bespoke dashboard required. Terraform has no line-coverage concept, so the runner deliberately maps its breadth metric onto the Cobertura schema; there's nothing else meaningful to measure at plan time

### Changed

- changed `makefiles/terra.mk` `test` target to delegate to the new shared runner instead of an inline shell loop. Adds JUnit + coverage generation as a side effect of `make test`; existing consumers continue to work because the runner still exits non-zero when any module fails its `terraform test`
- changed `azure-devops/terra/stages/30-tests/terra.yaml` to call the new runner, then publish the aggregated JUnit via `PublishTestResults@2` (surfaces per-case results in the build's Tests tab with `failTaskOnFailedTests: true`) and the whole `build/reports/` directory as the `terra-coverage` pipeline artifact via `PublishPipelineArtifact@1`. Both publish tasks use `condition: always()` so a red module still publishes everything green alongside it; the runner's non-zero exit code is what fails the job

### Fixed

- fixed `global/scripts/languages/terraform/terra-test/run.sh` to skip the phantom iteration when `modules/` exists without subdirectories. POSIX `sh` has no `nullglob`, so `for mod in modules/*/` previously ran once with the literal glob and recorded a fake module named `*`, producing incorrect coverage and module lists
- fixed `azure-devops/terra/stages/30-tests/terra.yaml` `PublishPipelineArtifact@1` input key from `artifact` to `artifactName` for consistency with every other Azure DevOps template in the repo (e.g., `azure-devops/global/stages/20-security/codeql.yaml`). Prevents the task from silently ignoring the artifact name
- added the standard `SCRIPTS_DIR` auto-detection preamble to `global/scripts/languages/terraform/terra-test/run.sh` and `global/scripts/languages/terraform/terratest/run.sh` to match the convention used by every other `run.sh` script in the repo (per `CLAUDE.md` Script Conventions)
- fixed `azure-devops/global/stages/40-delivery/release.yaml` silently swallowing failures from the Azure DevOps `annotatedtags` REST call. `curl` exits `0` on HTTP `4xx`/`5xx` unless `--fail` is passed, and `set -e` reacts only to non-zero exits — so a throttled, unauthorized, or 5xx response from `POST .../annotatedtags?api-version=7.1-preview.1` left the bump commit untagged while the release job reported green. Observed impact: on `2026-03-03` a coordinated `AutoBump` cycle merged 24 `chore(bump)` PRs across `terraform-modules/*` within a minute; 5 of the 24 module tags (`azm-k8s-cluster/1.3.3`, `azm-storage-account/1.1.1`, `azm-watcher-flow-log/1.0.1`, `k8s-deployment/1.0.1`, `kck-idp-oidc/1.2.2`) were never created, most likely because of Azure DevOps REST throttling when many pipelines POST to the same endpoint concurrently. Added `--fail --show-error --retry 5 --retry-delay 5 --retry-all-errors` so transient failures are retried and non-transient failures fail the release step visibly

## [4.6.2] - 2026-04-21

### Changed

- changed the terraform pipeline version from `1.14.8` to `1.14.9`

### Fixed

- fixed `global/scripts/tools/gitleaks/run.sh` silently overwriting and deleting any project-local `.gitleaks.toml` during the second (GitLab-rule) pass, so consumers had no way to keep their own rules + allowlist across both passes. The wrapper now mounts the bundled GitLab config read-only into the container and selects it via `--config` for the second pass, leaving the project's working tree untouched. Both passes still auto-discover the project's `.gitleaksignore` (fingerprint allowlist) at the source root, so suppressed findings stay suppressed in both passes.

## [4.6.1] - 2026-04-19

### Fixed

- fixed `.github/workflows/update-major-version-tag.yaml` leaving the rolling major-version GitHub Release (e.g., `v4`) with a stale `publishedAt`, a concatenated `body`, and — once exercised end-to-end — stealing the "Latest" badge from the SemVer release. `softprops/action-gh-release@v2` cannot refresh `publishedAt` on an existing release and was appending another `generate_release_notes` block on every bump (four concatenated "What's Changed" sections by `4.6.0`). Recreating the release via `gh release create --latest=false` was not enough either: GitHub resolves the repo's Latest release dynamically by newest `created_at`, so the fresh major-version release displaced the SemVer one in the UI and at `/releases/latest`. The workflow now (a) deletes the existing major-version release with `gh release delete --yes` without `--cleanup-tag` so the force-pushed tag is preserved, (b) recreates it via `gh release create --latest=false --generate-notes`, and (c) PATCHes the SemVer release with `make_latest=true` to re-assert it as Latest. Also added `fetch-depth: 0` to `actions/checkout@v4` and anchored the major tag to the SemVer tag's commit (`git tag -fa $MAJOR $SEMVER`) so the tag is always at the exact SemVer commit regardless of which ref triggered the workflow, and added a `workflow_dispatch` trigger so maintainers can manually re-run the flow for a specific SemVer tag.
- fixed `azure-devops/global/stages/35-management/sonarqube.yaml` downloading the coverage artifact to the repo root, causing Python's `cobertura.xml` (published from `build/reports/`) to land flat at `$(Build.SourcesDirectory)/cobertura.xml` instead of `build/reports/cobertura.xml` where `sonar.python.coverage.reportPaths` expects it, resulting in 0% coverage on every Python pipeline run. Added a `COVERAGE_ARTIFACT_TARGET_PATH` parameter (default: `$(Build.SourcesDirectory)`) and overrode it to `$(Build.SourcesDirectory)/build/reports` in `azure-devops/python/stages/35-management/pdm.yaml`. Also added `build/reports/cobertura.xml` to the coverage-detection loop in `global/scripts/tools/sonarqube/run.sh` and to the inline GitLab CI loop in `gitlab/global/stages/35-management/abstracts.yaml` so neither pipeline clears `sonar.python.coverage.reportPaths` when the report exists at the standard Python path.
- fixed the `report:dependency-track` job failing with `HTTP 401` on every Azure DevOps consumer whose `DEPENDENCY_TRACK_TOKEN` pipeline variable is marked `isSecret: true`. Azure Pipelines deliberately gates secret variables from the script step's process environment — the `$(DEPENDENCY_TRACK_TOKEN)` macro is substituted at task-parse time but the shell's `$DEPENDENCY_TRACK_TOKEN` is **empty** unless explicitly mapped via the step's `env:` block. Without the mapping, `global/scripts/tools/dependency-track/run.sh` sends `X-Api-Key:` with no value and DT rejects the upload. Added the explicit `env:` mapping (`DEPENDENCY_TRACK_TOKEN` + `DEPENDENCY_TRACK_HOST_URL`) on every Azure DevOps invocation of the script: `azure-devops/terra/stages/35-management/terra.yaml`, `azure-devops/terraform/stages/35-management/terra.yaml`, `azure-devops/golang/stages/35-management/go.yaml`, `azure-devops/python/stages/35-management/pdm.yaml`, `azure-devops/dotnet/stages/35-management/core.yaml`, and `azure-devops/javascript/stages/35-management/steps/dependency-track.yaml`. GitLab CI is unaffected (masked variables are still process-env-exposed); GitHub Actions has no DT integration in this repo.

## [4.6.0] - 2026-04-17

### Added

- added `DOWNLOAD_COVERAGE_ARTIFACT` (boolean, default `true`) and `COVERAGE_ARTIFACT_NAME` (string, default `coverage`) parameters to `azure-devops/global/stages/35-management/sonarqube.yaml`, so consumers without a coverage-producing test stage (Terraform, infrastructure-only projects) can skip the `Download Coverage File` task entirely instead of reporting `##[error]Artifact coverage was not found`. Both the `azure-devops/terra/stages/35-management/terra.yaml` and `azure-devops/terraform/stages/35-management/terra.yaml` wrappers now pass `DOWNLOAD_COVERAGE_ARTIFACT: false` by default.
- added `global/scripts/languages/terraform/cyclonedx/run.sh`, a CycloneDX BOM generator for Terraform projects that delegates to `trivy filesystem --format cyclonedx`, captures provider pins from `.terraform.lock.hcl` and module `source =` references (including private `git@...` remotes when upstream SSH setup is wired), and post-processes `metadata.component.{name,version}` via `jq` from `DT_PROJECT_NAME` / `DT_PROJECT_VERSION` env vars (falling back to the git remote basename and the latest git tag). Matches the placement and shape of the existing Go (`global/scripts/languages/golang/cyclonedx/run.sh`) and Python (`global/scripts/languages/python/cyclonedx/run.sh`) scripts.
- added a `generate CycloneDX BOM` step before the `upload BOM to Dependency-Track` step in `azure-devops/terra/stages/35-management/terra.yaml` so Terra consumers get the BOM automatically, resolving the long-standing `TODO: Missing CycloneDX for Terraform` marker. Also removed that TODO echo step now that it is addressed.
- added a `pre_script` input to the GitHub Actions `docker-semgrep` and `trivy` composite actions and to the `terra.yaml` reusable workflow, mirroring the Azure DevOps `PRE_STEPS` hook so consumers can configure SSH before the Terraform SAST scanners run
- added a `PRE_STEPS` `stepList` parameter to `azure-devops/terra/terra.yaml`, forwarded through `stages/20-security/terra.yaml` into the `sast:trivy` (`azure-devops/global/stages/20-security/trivy.yaml`) and `sast:semgrep` (`azure-devops/global/stages/20-security/docker.yaml`) jobs, so consumers with private Terraform modules can inject SSH setup before the scanners parse `source = "git@..."` references — previously Trivy and Semgrep failed to clone remote modules and `sast:*` jobs reported `succeededWithIssues` on every build
- added a `SAST_PRE_SCRIPT` variable hook to the GitLab CI `sast:semgrep` and `sast:trivy` jobs, mirroring the Azure DevOps `PRE_STEPS` hook so consumers can configure SSH before the Terraform SAST scanners run
- added SSH config and `SSH_AUTH_SOCK` forwarding to `global/scripts/tools/semgrep/run.sh` so that `PRE_STEPS`-based SSH setup propagates into the Semgrep Docker container, enabling private Terraform module cloning during scans

### Fixed

- fixed `gitlab/global/stages/20-security/trivy.yaml` collecting only `trivy.sarif` as an artifact, which would produce missing-artifact warnings for GitLab consumers now that `trivy.json` is the primary output; the job now collects both `trivy.json` (always produced) and `trivy.sarif` (best-effort).
- fixed `global/scripts/tools/dependency-track/run.sh` failing the `report:dependency-track` job on consumers without a CycloneDX BOM generator. The script now exits `0` cleanly with a `No CycloneDX BOM at … — skipping Dependency-Track upload.` message when `build/reports/bom.json` does not exist, instead of `cat` erroring and the downstream `curl` returning HTTP `401` on an empty upload. Applies to Terraform/Terra consumers (`azure-devops/terra/stages/35-management/terra.yaml` carries a `TODO: Missing CycloneDX for Terraform` marker) and any other consumer whose language track has no BOM generator wired.
- fixed `global/scripts/tools/trivy/run.sh` crashing with a nil-URL `SIGSEGV` in `pkg/report/sarif.go:103` when Terraform `source =` pins reference an SSH remote like `git@host:path/repo?ref=x` (Go's `net/url` rejects the colon in the first path segment). The script continues to produce `trivy.json` as the primary report via `--format json` (aligned with `trivy-sca.json`, `govulncheck.json`, and the other tool outputs), and still runs `trivy convert --format sarif` to preserve `trivy.sarif` for consumers that publish to GitHub Code Scanning. To stop `trivy convert` from hitting the same shared `SarifWriter` panic path, it now pre-processes a *copy* of `trivy.json` with `jq`'s `walk` (redefined inline for `jq` versions older than `1.6`), rewriting every `git@host:path` string to the equivalent valid RFC 3986 URL `ssh://git@host/path` before conversion runs, while leaving `trivy.json` untouched as the authoritative artifact. `trivy.sarif` is therefore produced without flooding the build logs with the stack trace, while the fallback `|| echo "SARIF conversion failed; trivy.json is authoritative."` remains as a safety net for unrelated convert failures.

## [4.5.0] - 2026-04-15

### Added

- added `azure-devops/terraform/stages/40-delivery/terra.yaml` wiring the shared `release.yaml` tag-creation job into the Azure DevOps Terraform pipeline, so that merges of `chore/bump-X.Y.Z` branches automatically create an annotated Git tag — previously the `40-delivery` stage was commented out in `azure-devops/terraform/terra.yaml` and the directory was empty, leaving Terraform module bumps without any automatic tagging

### Changed

- changed `azure-devops/terraform/terra.yaml` to include the new `stages/40-delivery/terra.yaml` stage (previously commented out)
- changed the GitLab CI and the global `golang.1.26-awscli` container Go version from `1.26.1` to `1.26.2` to align with the Azure DevOps bump in 4.4.1

### Fixed

- fixed `update-major-version-tag.yaml` silently skipping on every bump release — the previous `github.event_name == 'workflow_call'` guard never matched because reusable workflows inherit the caller's `event_name` (e.g. `push`), so the `v4` tag had been stuck at `4.1.0` since PR #327; now detects `workflow_call` via the `inputs.tag_name` presence check

## [4.4.1] - 2026-04-14

### Changed

- changed the Azure DevOps GoLang version from `1.26.1` to `1.26.2`

## [4.4.0] - 2026-04-03

### Added

- added ShellCheck platform integration stage files for GitHub Actions, GitLab CI, and Azure DevOps under `20-security`
- added ShellCheck tool at `global/scripts/tools/shellcheck/run.sh` with auto-installation when the binary is not available locally, following the same pattern as Hadolint

## [4.3.0] - 2026-04-01

### Added

- added default PMD ruleset with unused code rules at `global/scripts/languages/java/pmd/pmd-ruleset.xml` for downstream Gradle/Maven projects
- added whole-project unused code detection (stage 10, code-check) for Python (`vulture`), JavaScript/TypeScript (`knip`), Java (ProGuard `-printusage`), Ruby (`debride`), and PHP (`phpmd`) — integrated into `make lint` and CI pipelines across GitHub Actions, GitLab CI, and Azure DevOps

### Changed

- changed Azure DevOps `sonar.projectName` derivation to use `project/repository` format instead of just the repository name
- changed Go unused code detection to rely on existing `golangci-lint` linters (`unused`, `unparam`, `wastedassign`) instead of a standalone `deadcode` tool

### Fixed

- fixed `golangci-lint` script to use a local binary when available (v2+) before attempting to download, improving portability for environments like Android/Termux
- fixed `vulture` scanning `.venv` directory contents by adding `--exclude .venv` to all invocation points (run.sh, Azure DevOps, GitLab CI)
- fixed major version tag (e.g. `v4`) not updating on automated releases — `GITHUB_TOKEN` events don't cascade to other workflows, so `release.yaml` now calls `update-major-version-tag.yaml` as a reusable workflow via `workflow_call`

## [4.2.0] - 2026-03-26

### Added

- added `release.yaml` workflow to automatically create GitHub Releases and tags when bump PRs are merged, enabling the `update-major-version-tag.yaml` chain
- added automatic derivation of `sonar.projectKey` and `sonar.projectName` from CI platform variables (GitHub, Azure DevOps, GitLab), enabling zero-config SonarQube enrollment for new projects
- added test suite for SonarQube auto-derivation logic covering `normalize_sonar_key`, per-platform derivation, environment variable overrides, and existing property preservation

### Changed

- changed the Terraform pipeline version from `1.14.7` to `1.14.8`

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
- added coverage reporting and test results to `go.yaml` via `dorny/test-reporter@v1` and `actions/upload-artifact@v4`
- added coverage reporting and test results to `gradle.yaml` via `dorny/test-reporter@v1` and `actions/upload-artifact@v4` with JaCoCo detection
- added coverage reporting and test results to `maven.yaml` via `dorny/test-reporter@v1` and `actions/upload-artifact@v4` with JaCoCo detection
- added coverage reporting to `npm.yaml` via `davelosert/vitest-coverage-report-action@v2`, `dorny/test-reporter@v1`, and `actions/upload-artifact@v4`, matching `yarn.yaml` features
- added JaCoCo XML report auto-detection for Gradle and Maven in `sonarqube/run.sh`
- added optional SonarQube management stage to `go.yaml` with `sonar_host` input and `sonar_token` secret, matching `yarn.yaml` features
- added optional SonarQube management stage to `gradle.yaml` with `sonar_host` input and `sonar_token` secret, matching `yarn.yaml` features
- added optional SonarQube management stage to `maven.yaml` with `sonar_host` input and `sonar_token` secret, matching `yarn.yaml` features
- added optional SonarQube management stage to `npm.yaml` with `sonar_host` input and `sonar_token` secret, matching `yarn.yaml` features
- added Python composite actions (`pdm-lint`, `safety`, `tests/all`) under `github/python/stages/`, replacing inline workflow steps and matching Go's composite action pattern
- added workflow to auto-update major version tags (e.g., `v3`) when a new SemVer release is published, enabling downstream repos to pin to stable `@v3` refs

### Changed

- **BREAKING CHANGE:** changed `dotnet.yaml` to stages 1-3 only, moving `delivery-release` to `dotnet-docker.yaml` following Go/PDM pattern
- **BREAKING CHANGE:** changed `java-maven.yaml` to `maven.yaml` and `java-maven-docker.yaml` to `maven-docker.yaml`, matching the toolchain naming convention
- **BREAKING CHANGE:** changed `java.yaml` to `gradle.yaml` and `java-docker.yaml` to `gradle-docker.yaml`, matching the toolchain naming convention
- **BREAKING CHANGE:** changed `javascript-npm.yaml` to `npm.yaml` and `javascript-npm-docker.yaml` to `npm-docker.yaml`, matching the toolchain naming convention
- **BREAKING CHANGE:** changed `javascript.yaml` to `yarn.yaml` and `javascript-docker.yaml` to `yarn-docker.yaml`, matching the toolchain naming convention
- **BREAKING CHANGE:** changed `php.yaml` to `composer.yaml` and `php-docker.yaml` to `composer-docker.yaml`, matching the toolchain naming convention
- **BREAKING CHANGE:** changed `ruby.yaml` to `bundler.yaml` and `ruby-docker.yaml` to `bundler-docker.yaml`, matching the toolchain naming convention
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
- changed Go cross-compile CI job to run 6 OS/arch targets in parallel via GitHub Actions matrix strategy instead of sequentially
- changed Go cross-compile script to support single-target mode via `CROSS_GOOS`/`CROSS_GOARCH` environment variables and parallel execution for all-targets mode

### Fixed

- fixed `pdm-docker.yaml` skipping all code check, security, and test stages when used standalone
- fixed `pdm.yaml` display names for `flake8` and `mypy` jobs from `style:` to `quality:` to match their job IDs
- fixed `yarn.yaml` and `npm.yaml` SonarQube job failing at workflow parse time by removing `secrets.sonar_token` from job-level `if` condition (GitHub Actions does not allow `secrets` context in reusable workflow job `if` expressions)
- fixed missing `continue-on-error: true` on `mypy` and `safety` jobs to match Azure DevOps golden standard
- fixed Zig setup action failing with HTTP 404 when downloading Zig `0.15.2` by upgrading `mlugg/setup-zig` from `v1` to `v2`

### Removed

- removed Android targets (`android/amd64`, `android/arm64`) from Go cross-compile check, CI matrix, and GoReleaser template because Zig does not bundle Android bionic `libc` headers (see [ziglang/zig#23906](https://github.com/ziglang/zig/issues/23906))
- removed Zig setup step from cross-compile composite action (no longer needed without Android targets)

## [3.4.0] - 2026-03-20

### Added

- added optional LCOV coverage artifact publishing to JavaScript Azure DevOps test stage and downloading in the SonarQube management step, enabling JS/TS coverage reporting in SonarQube

### Changed

- changed `go-binary.yaml` to disable cross-compile check since GoReleaser already handles multi-platform builds in the delivery stage
- changed Go cross-compile script to use `go vet` instead of `go build` for type-checking without linking, plus vet diagnostics
- changed Helm chart builds from mutable `0.0.0-latest` to immutable `0.0.0-<commit>` versioning, ensuring each push produces a unique, traceable chart version
- changed the java pipeline version from 21 to 25
- changed the terraform pipeline version from 1.9.3 to 1.14.7

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
- added Java (Gradle) pipeline for GitHub Actions with `java.yaml` (testing/quality) and `java-docker.yaml` (Docker delivery) reusable workflows
- added Java (Maven) pipeline for GitHub Actions with `java-maven.yaml` (testing/quality) and `java-maven-docker.yaml` (Docker delivery) reusable workflows
- added JavaScript/Node.js (npm) pipeline for GitHub Actions with `javascript-npm.yaml` (testing/quality) and `javascript-npm-docker.yaml` (Docker delivery) reusable workflows
- added JavaScript/Node.js (Yarn) pipeline for GitHub Actions with `javascript.yaml` (testing/quality) and `javascript-docker.yaml` (Docker delivery) reusable workflows
- added new container to support Golang version `1.26.0`
- added optional K8s deployment stage to `azure-devops/golang/go-docker.yaml` - automatically deploys with commit SHA label when `K8S_DEPLOYMENT_NAME` variable is set
- added OWASP Dependency-Check SCA job to GitHub Actions and Azure DevOps Java security stages (previously only in GitLab)
- added per-provider usage examples in `.docs/examples/` for GitHub Actions, GitLab CI, and Azure DevOps (Go with Docker)
- added PHP (Composer) pipeline for GitHub Actions with `php.yaml` (testing/quality) and `php-docker.yaml` (Docker delivery) reusable workflows
- added rebase-check quality gate to the code-check stage across all providers (GitHub Actions, GitLab CI, Azure DevOps) and all languages, failing the pipeline when a PR/MR branch is not rebased on the default branch
- added Ruby (Bundler) pipeline for GitHub Actions with `ruby.yaml` (testing/quality) and `ruby-docker.yaml` (Docker delivery) reusable workflows
- added Safety SCA job to Azure DevOps Python security stage (previously only in GitHub Actions and GitLab)
- added symbolic links under `github/` for all importable GitHub Actions workflows (javascript, java, php, ruby, dotnet, terra) to match the existing golang/python pattern
- added Terraform pipeline for GitLab CI with `terra.yaml` including code check (terraform fmt, TFLint), security (Semgrep, Hadolint, Trivy), and management stages
- added Trivy SCA dependency vulnerability scanning (`trivy fs --scanners vuln`) as a unified SCA layer across all languages and all providers (GitHub Actions, GitLab CI, Azure DevOps)

### Changed

- changed `cleanup.sh` to accept a `TOOL_NAME` variable, scoping report cleanup to `build/reports/<tool>/` instead of wiping the entire `build/reports/` directory
- changed artifact publish paths across all providers (Azure DevOps `targetPath`, GitHub Actions `path`) to reference tool-specific subdirectories instead of the shared `build/reports/` root
- changed Azure DevOps JavaScript Kubernetes deployment step to patch `app.kubernetes.io/version` with `$(Build.SourceVersion)` and wait for `rollout status` (`--timeout=300s`) instead of forcing a restart
- changed Golang version to `1.26.0` on lambda files
- consolidated `.github/workflows/ci.yaml` into 2 focused jobs (`validate` + `lint-scripts`), removing superficial security and documentation checks
- moved test scripts from root to `.github/tests/` directory to reduce clutter for downstream users
- renamed `rebase-check` step to `basic-checks` across all pipeline vendors (GitHub Actions, GitLab CI, Azure DevOps)
- renamed the existing `lint` target in `makefiles/terra.mk` to `format` to accurately reflect its purpose (`terra format`)
- rewrote `clone.sh` as idempotent installer with `PIPELINES_HOME` support, auto-directory creation, and `git pull` on subsequent runs

### Fixed

- fixed `dependency-track` execution
- fixed `global/scripts/tools/sonarqube/run.sh` by adding `coverage.txt` in coverage file patterns
- fixed `make sast` aggregate target aborting on the first tool failure by adding the `-` prefix to all SAST tool recipes in `makefiles/common.mk`
- fixed `makefiles/terra.mk` `format` target error message that incorrectly suggested running `make lint` instead of `make format`
- fixed changelog validation crashing when the changelog has no versioned sections (only `[Unreleased]`), caused by `grep -v` returning exit code 1 under `bash -e -o pipefail`
- fixed Go library workflow (`go-library.yaml`) default `tag_prefixes` from `[""]` to `["", "v"]` so it creates both `X.Y.Z` and `vX.Y.Z` tags as documented
- fixed JavaScript Azure DevOps SonarQube step failing when `cobertura-coverage` artifact does not exist by adding `continueOnError: true` to the download step
- fixed lambda template test failures by adding missing example files and documentation
- fixed Python CycloneDX BOM generation using an independent `BOM_PATH` variable instead of `$PREFIX$REPORT_PATH`, causing `dependency-track` upload to fail with "No such file or directory" because the BOM was written to a different path than expected
- fixed rebase check false positive when the PR was merged while CI was still running
- fixed SAST tool report cleanup deleting reports from other tools by isolating each tool's output into its own `build/reports/<tool>/` subdirectory
- fixed ShellCheck warnings in `golang/test/run.sh` (SC2046) and `semgrep/run.sh` (SC2140)
- fixed SonarQube failing on Azure DevOps and GitLab when projects have no test coverage by detecting missing coverage files and clearing coverage report path properties before running `sonar-scanner`
- fixed test execution for `terra` pipeline
- fixed Yarn Berry compatibility in `javascript.yaml` by moving `corepack enable` before `actions/setup-node` cache step, which failed when projects declared `packageManager: yarn@4.x` in `package.json`

## [3.0.0] - 2026-02-10

### Added

- added `github/global/stages/20-security/codeql/action.yaml` composite action using the official `github/codeql-action`
- added `github/global/stages/20-security/hadolint/action.yaml` and `github/global/stages/20-security/trivy/action.yaml` composite actions
- added `gitlab/global/stages/20-security/codeql.yaml` and `azure-devops/global/stages/20-security/codeql.yaml` as standalone templates separated from Docker-based tools
- added `gitlab/global/stages/20-security/hadolint.yaml` and `azure-devops/global/stages/20-security/hadolint.yaml` templates for Dockerfile linting
- added `gitlab/global/stages/20-security/trivy.yaml` and `azure-devops/global/stages/20-security/trivy.yaml` templates for IaC misconfiguration scanning
- added `global/scripts/tools/codeql/run.sh` script that downloads CodeQL CLI bundle and runs security-and-quality analysis
- added `global/scripts/tools/hadolint/run.sh` script that downloads Hadolint binary and lints `Dockerfiles` with SARIF output
- added `global/scripts/tools/trivy/run.sh` script that downloads Trivy and scans for IaC misconfigurations with SARIF output
- added `go-library.yaml` pipeline with Azure DevOps to deliver Go libraries
- added `make test` and `make test-go-script` targets for automated testing
- added a generic configuration to run CycloneDX for Python projects
- added Azure DevOps global K8s deployment template (`azure-devops/global/stages/50-deployment/k8s-deployment.yaml`)
- added CodeQL as SAST security scanning tool with native CLI support for Go, Python, Java, JavaScript, and C#
- added complete test validation suite with `.github/tests/test-go-validation.sh` script
- added Hadolint as `Dockerfile` linting tool with auto-discovery of `Dockerfiles` across all pipelines (GitHub Actions, GitLab CI, Azure DevOps)
- added K8s deployment template that patches deployments with commit SHA label (`app.kubernetes.io/version`) for observability in Grafana/Prometheus via `kube_pod_labels` metric
- added OCI image labels to Azure DevOps Docker builds for traceability (`org.opencontainers.image.revision`, `org.opencontainers.image.ref.name`, `org.opencontainers.image.created`, `org.opencontainers.image.source`)
- added optional `IMAGE_NAME` parameter to Azure DevOps global docker delivery template to allow custom image names (defaults to repository name if not provided)
- added optional `RESOLVE_S3` flag to Azure DevOps Go SAM delivery to support bucket auto resolving
- added Trivy as IaC misconfiguration scanner for Terraform, Kubernetes, and `Dockerfiles` across all pipelines (GitHub Actions, GitLab CI, Azure DevOps)
- updated GitLab K8s deployment to include commit SHA label in pod template

### Changed

- changed Go pipeline with GitHub to use GoReleaser instead of manually build
- changed Python version from `3.13` to `3.14` on Azure DevOps modules
- changed the lambda deployment to use env vars instead of parameters in delivery and deployment steps
- changed the Node version from `18.19.0` to `20.18.3` on Azure DevOps modules
- changed the structure on Azure DevOps to have files for each step inside each stage
- enhanced coverage accuracy by using `-coverpkg` with all packages when tests are available
- refactored `docker.yaml` security templates to only contain Docker-based tools (Semgrep, Gitleaks), with CodeQL in its own `codeql.yaml` template
- replaced Horusec SAST tool with CodeQL across all pipelines (GitHub Actions, GitLab CI, Azure DevOps) due to Horusec being unmaintained
- updated `CONTRIBUTING.md` and `copilot-instructions.md` with mandatory testing requirements
- updated GoLang version to `1.25.7` on all pipelines and modules

### Fixed

- fixed Azure DevOps Go SAM delivery to normalize `RESOLVE_S3` booleans so `--resolve-s3` works with Azure `True/False` (capitalized) values
- fixed coverage reporting to include all packages with Go files, not just packages with tests
- fixed deployment issue to deploy an AWS Lambda with SAM CLI
- fixed GoLang `1.25.1` compatibility issue in `global/scripts/languages/golang/test/run.sh` by implementing comprehensive coverage reporting
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

- added `arm-container.yaml` to run a container in Azure Container Instance
- added `arm-parameters.yaml` to generically construct `ARM` parameters from library variables
- added `checkstyle.xml` config file for Azure DevOps Java pipeline
- added a new optional parameter called `CUSTOM_PARAMETERS` in `go-arm-az-function` to add custom parameters in resource group deployment
- added a new pipeline in Azure DevOps for .NET Core (C#)
- added a new pipeline in Azure DevOps for Terraform
- added a new rule to ignore the docs folder in `golangci-lint`
- added a new rule to ignore the Swagger comments to `godot` linter in `golangci-lint`
- added another stage's template `acr-container-deployment.yaml`, introduced new test steps' template: `test.yaml` and new test stage: `acr.yaml` to the GoLang pipeline to log in into ACR before running tests
- added Azure global `docker.yaml` delivery template to be used by all languages
- added messages to show application states in the `test_e2e` job
- added new language support for Java in Azure DevOps pipelines
- added new parameters: `RUN_BEFORE_BUILD` and `DOCKER_BUILD_ARGS` to Azure DevOps GoLang delivery stage template to allow running a script before the build and passing arguments to the Docker build command
- added the `go1.23.4.yaml` template to the GoLang Docker delivery stage

### Changed

- changed `azure-devops/global/stages/50-deployment/database.yaml` cache keys to include subfolders
- changed `docker.yaml` Azure's GoLang delivery stage to use the global `docker.yaml` template and removed unnecessary execution of the `./config.sh` script since it's already done by the `go1.23.4.yaml` template
- changed `docker.yaml` Azure's JavaScript delivery stage to use the global `docker.yaml` template since it was being repeated
- changed `execute-command-opensearch-dashboards.yaml` Yarn cache keys to use the `yarn.lock` of OSD and plugin
- changed `go.yaml` GoLang's test stage to use `test.yaml` template
- changed `PIPELINE_FIREWALL_NAME` from a pipeline parameter to a job variable
- changed cache strategy for JavaScript projects using Azure DevOps pipelines
- changed GitLeaks inside Azure DevOps to clone the full repository instead of just a shallow clone
- changed the `.golangci.yml` configuration file to upgrade the `@maratori`'s configuration to `v1.64.7`
- changed the `azure-devops/javascript/stages/50-deployment/k8s.yaml` to run an external Kubernetes file
- changed the dynamic deployment to `PublishPipelineArtifact` the files to deploy the Azure Function
- changed the OSD version to `2.19.1` due to an upgrade request
- corrected miss-used template files for .NET in Azure DevOps pipelines
- updated `.golangci.yml` to the new version format
- updated the image tag for the GoLang Docker delivery stage to retrieve the complete tag name from an environment variable

### Fixed

- fixed dynamic variable `CONTAINER_IMAGE` for production and development environment
- fixed dynamic variable `CONTAINER_IMAGE` to get value from the delivery stage
- fixed GoLang pipeline to work with dynamic deployment
- fixed Java pipeline for Azure DevOps by setting up local `gradle.properties` file
- fixed JavaScript delivery and deployment stages in Azure DevOps by inserting the name for the build and push step
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
- added Python pipelines for GitHub actions

### Changed

- changed a task that publishes artifact from `PublishBuildArtifact` to `PublishPipelineArtifact` in Azure DevOps JavaScript `execute-command-opensearch-dashboards.yaml` template
- changed all display names and conditions to obey a certain position for all Azure DevOps tasks
- changed GitLab `yarn.yaml` Node image version to `18.17.1`
- changed GoLang pipeline for Azure DevOps to use caching in the delivery stage
- changed GoLang test script to install docker used by test containers in integration tests
- changed GoLang test script to run integration tests separately and one per time
- changed GoLang to version `1.23.4`
- changed JavaScript pipeline for Azure DevOps to publish the code coverage in Sonarqube
- changed stages for GoLang in Azure DevOps to be called after configuration
- changed the Azure DevOps to execute the migrations and seeders in different tasks
- changed the binary copy process in the delivery stage of Azure DevOps to a more generic approach
- changed the C# pipeline to run tests with the debug configuration instead of release
- changed the end-to-end test job to receive a different pool
- changed the Horusec JSON configuration file to ignore `pipelines_*` directory created by GitHub Actions
- changed the OSD version to `2.18.0` due to an upgrade request
- changed the search location of the folder generated by Cypress
- changed the validation to create or update the Resource Group for dynamic Azure functions
- changed the way to validate the `AZURE_DEPLOY_CACHE_HIT` in the deployment stage in Azure DevOps
- corrected SonarQube scanning tag versions and blame information for Azure DevOps and GitLab
- updated the GoLangCI-Lint pipeline to use a tweaked version of `@maratori`'s config
- upgraded `actions/checkout@v3` that was using a deprecated Node.js version

### Fixed

- fixed artifact generation for end-to-end tests
- fixed cache keys in the GoLang delivery stage for Azure DevOps
- fixed Dependency Track to avoid creating many of the same projects
- fixed GoLang delivery stage for Azure DevOps only to execute a task when previous tasks are successful
- fixed Golang delivery to register multiple functions using `api*/` wildcard
- fixed GoLang pipeline for GitHub Actions missing permissions to install dependencies
- fixed GoLang test script to set the `GOPATH` variable just when it's not set (it was preventing cache in Azure DevOps)
- fixed Python management step to adjust for commands for the non-Debian image
- fixed Python management step to install the necessary package before executing the command
- fixed the Azure DevOps delivery stage for GoLang by adding a `goose-db` version table hash for the migrations and seeders caches to work based on properly versioning
- fixed the Azure DevOps delivery stages by adding one more condition to run only when previous stages succeeded
- fixed the Azure DevOps delivery stages conditions to run only when there were no errors in the earlier stages instead of checking for success
- fixed the dependency track stage in the GoLang Azure DevOps pipeline to set up the correct environment
- fixed the error in `global/scripts/languages/golang/test/run.sh` where `cmd` and `internal` folders were both required at the same time
- fixed the GoLang building step in the Azure DevOps delivery step to create an output directory before compiling
- fixed the GoLang Debian pipeline failing to upload the `.deb` file to the GitLab releases
- fixed the GoLang delivery stage for Azure DevOps by adding the `GOPATH` environment variable
- fixed the GoLang for Azure DevOps stages to use the `config.sh` script as a source from each project
- fixed the GoLang pipeline for Azure DevOps to use an optional cache in the delivery stage
- fixed the GoLang test script to test the `pkg` directory to avoid excluding lib-only directories from testing
- fixed the incorrect string concatenation of the `PREFIX` and `REPORT_PATH` variables
- fixed the task for Azure DevOps GoLang to avoid failing if there's no function or resource group deployed
- fixed the task in the delivery stage for JavaScript in Azure DevOps to download the artifact to the correct directory
- fixed the task in the GoLang delivery stage to retrieve only the last function app

### Removed

- removed duplicated code of SonarQube and DependencyTrack for GitLab and Azure DevOps
- removed the explicit installation of Azure CLI version `2.56` to use the pre-installed LTS version
- removed unused variables in the template for fixed and dynamic Azure functions

## [2.0.0] - 2024-08-07

### Added

- added `musl-tools` in the `goreleaser` pipeline to support building with `musl`
- added `pdm-prod.yaml` to only install production and test dependencies
- added a new env variable for Java to avoid `out-of-memory` error inside the security step
- added a new step to replace the environment variables contained inside the `yaml` file
- added a script into the GoLang delivery to get the new `siteName` variable
- added a script into the GoLang delivery to seed the database using `Goose`
- added a task in GoLang stage delivery to replace the value of Azure function settings variables with library variables
- added Alibaba `access-key-id` regex to `allowlist`
- added Azure DevOps support for JavaScript
- added condition to Jobs in Azure DevOps Pipelines to only proceed if the previous job was successful
- added Dependency Track and SonarQube for GoLang projects
- added Java support on the .NET pipeline
- added Kubernetes deployment for all languages in GitLab CI
- added Maven support for Java projects
- added option to override a Semgrep rule
- added Python steps for building and delivery via `PDM` in Azure DevOps
- added Python steps for security and code-check in Azure DevOps
- added skeleton for .NET project pipelines with basic steps
- added SonarQube for Java and Python projects
- added step to create and delete firewall rule to run migrations
- added step to run migrations in Azure Pipelines
- added tasks to publish all security reports as Azure artifacts in Azure DevOps
- added the `goreleaser` pipelines
- added the binary release feature for GoLang pipelines
- added the code check step for GoLang inside the GitHub Actions provider - [#19](https://github.com/rios0rios0/pipelines/issues/19)
- added the exposure for the coverage in Python projects
- added the JavaScript rules to test, monitor, and deploy
- added the missing configuration to Azure DevOps deployment with JavaScript

### Changed

- **BREAKING CHANGE:** changed the structure to support more than one CI/CD platform
- changed JavaScript deployment to continue tasks with error
- changed release code at every step to have a regex more flexible to catch in any merge case
- changed Semgrep only to use the default `.semgrepignore` file if custom is not available
- changed SonarQube to be inside the management step instead of the delivery step
- changed the `pdm-prod` abstract to use its cache
- changed the `SETTINGS` variable in Azure DevOps GoLang delivery
- changed the directory of migrations into the GoLang delivery
- changed the GoLang code to have multiple standards to run testing
- changed the GoLang linter configuration to use the project-specific config
- changed the GoLang pipeline to match with the GitHub merge commit message
- changed the GoLang pipeline to remove the redundant make command
- changed the GoLang version from `1.19.9` to `1.22`
- changed the GoLang version in Azure DevOps from `1.20` to `1.22.0`
- changed the Gradle version from `8.1` to `8.7`
- changed the Java projects to have deployment using Kubernetes environments
- changed the Node version from `16.20.0` to `18.19.0`
- changed the OSD version to `2.15.0` due to an upgrade request
- changed the position of the script to get pipeline variables and added a new variable to be re-used in all code
- changed the publish function task in Azure DevOps GoLang delivery to use Azure CLI version `2.56.0` instead of Azure Task because after this version GoLang Azure Function is having time-out problems
- changed the Python pipeline to fix the dependency track stage by making sure the required packages are installed before executing the script
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
- corrected all the structures to have segregated caches and numbered step-by-step jobs
- corrected GitLeaks script condition to test if there was an error
- corrected GoLang images to detect the right `$GOPATH`
- corrected GoLang tests step to avoid issues when there's no test at all in the application

### Removed

- removed Alpine images from GoLang stages because it doesn't work without `gcc` and `g++`
