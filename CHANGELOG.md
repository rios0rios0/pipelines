# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

When a new release is proposed:

1. Create a new branch `bump/x.x.x` (this isn't a long-lived branch!!!);
2. The Unreleased section on `CHANGELOG.md` gets a version number and date;
3. Open a Pull Request with the bump version changes targeting the `main` branch;
4. When the Pull Request is merged, a new git tag must be created using [GitHub environment](https://github.com/rios0rios0/pipelines/tags).

Releases to productive environments should run from a tagged version.
Exceptions are acceptable depending on the circumstances (critical bug fixes that can be cherry-picked, etc.).

## [Unreleased]

### Added

- added Python pipelines for GitHub actions
- added `clone.sh` script into the root to help local development
- added artifact upload for SAST pipelines in GitHub Actions
- added building tests for GoLang inside GitLab pipelines
- added command to run `e2e` tests for JS projects
- added command to run rename_vars.sh file
- added management step for Azure DevOps environment
- added a new step to publish the code coverage for `azure-devops`

### Changed

- changed GitHub `python.yaml` to run stage with custom Docker image
- changed GoLang pipelines using GitLab to version to `1.23.1`
- changed GoLang test script to install docker used by test containers in integration tests
- changed GoLang test script to run integration tests separately and one per time
- changed `Horusec` JSON configuration file to ignore `pipelines_*` directory created by GitHub Actions
- changed `global/scripts/golang/test/run.sh` to execute `go test` for all folders instead for `main` or `cmd`
- changed the CSharp pipeline to run tests with the Debug configuration instead of Release
- changed the OSD version to 2.17.0 due to an upgrade request
- updated the golangci-lint pipeline to use a tweaked version of @maratori's config
- upgraded `actions/checkout@v3` uses a deprecated Node.js version
- changed Gitlab `yarn.yaml` node image version to `18.17.1`
- changed the binary copy process in the `delivery` stage of `azure-devops` to a more generic approach
- changed `javascript` pipeline for `azure-devops` to publish the code coverage in `sonarqube`

### Fixed

- added two missing linters to the `golangci-lint` pipeline
- fixed GoLang Debian pipeline failing to upload the `.deb` file to the GitLab releases
- fixed GoLang pipeline for GitHub Actions missing permissions to install dependencies
- fixed argument passing errors in `global/scripts/golang/test/run.sh`
- fixed the error in `global/scripts/golang/test/run.sh` to execute the `go test` only for `main`, `cmd` and `internal`
- fixed the error in `global/scripts/golang/test/run.sh` where `cmd` and `internal` folders were both required at the same time
- fixed `python management` step to install necessary package before executing the command
- fixed `python management` step to adjust for commands for the non-debian image

## [2.0.0] - 2024-08-07

### Added

- added Alibaba `AccessKey ID` regex to `allowlist`
- added Azure DevOps support for JavaScript
- added Dependency Track and SonarQube for GoLang projects
- added Java support on the .NET pipeline
- added K8s deployment for all languages in GitLab CI
- added Maven support for Java projects
- added SonarQube for Java and Python projects
- added `musl-tools` in the `goreleaser` pipeline to support building with `musl`
- added `pdm-prod.yaml` to only install production and tests dependencies
- added `python` steps for building and delivery via `PDM` in `azure-devops`
- added `python` steps for security and code-check in `azure-devops`
- added a new env variable for Java to avoid `out-of-memory` error inside the security step
- added a new step to replace the environment variables contained inside the `yaml` file
- added a script into the Golang `delivery` to get the new `siteName` variable
- added a script into the Golang `delivery` to seed the database using `Goose`
- added option to override a Semgrep rule
- added skeleton for .NET project pipelines with basic steps
- added step to create and delete firewall rule to run migrations
- added step to run migrations in Azure Pipelines
- added task in GoLang stage `delivery` to replace the value of Azure function settings variables with library variables
- added tasks to publish all security reports as Azure artifacts in `azure-devops`
- added the JavaScript rules to test, monitor, and deploy
- added the `goreleaser` pipelines
- added the binary release feature for GoLang pipelines
- added the code check step for GoLang inside the GitHub Actions provider - [#19](https://github.com/rios0rios0/pipelines/issues/19)
- added the exposure for the coverage in Python projects
- added the missing configuration to Azure DevOps deployment with JavaScript

### Changed

- **BREAKING CHANGE:** changed the structure to support more than one CI/CD platform
- changed GoLang version in `azure-devops` from `1.20` to `1.22.0`
- changed Javascript deployment to continue tasks with error
- changed Node version from 16.20.0 to 18.19.0
- changed Semgrep only to use the default `.semgrepignore` file if custom is not available
- changed SonarQube to be inside the `management` step instead of the `delivery` step
- changed `release` code in every step to have a regex more flexible to catch in any merge case
- changed gradle version from `8.1` to `8.7`
- changed the GoLang code to have multiple standards to run testing
- changed the GoLang linter configuration to use the project-specific config
- changed the GoLang pipeline to match with the GitHub merge commit message
- changed the GoLang pipeline to remove the redundant make command
- changed the Java projects to have deployment using Kubernetes environments
- changed the OSD version to 2.15.0 due to an upgrade request
- changed the Python pipeline to fix the dependency track stage by making sure the required packages are installed before executing the script
- changed the `SETTINGS` variable in `azure-devops/golang` `delivery`
- changed the `golang` version from `1.19.9` to `1.22`
- changed the `pdm-prod` abstract to use its cache
- changed the directory of migrations into Golang `delivery`
- changed the position of the script to get pipeline variables and added a new variable to be re-used in all code
- changed the publish function task in `azure-devops/golang` `delivery` to use Azure CLI version 2.56.0 instead of Azure Task because after this version Golang Azure Function is having time-out problems
- changed the version of the container `GoLang` to `1.19`
- corrected GoLang delivery and deployment to have the default image and the proper format
- corrected Horusec issue with the Docker version
- corrected Semgrep to add the ability to merge the ignored rules files
- corrected the coverage artifact to be uploaded with the XML report
- corrected the way the delivery and deployment steps are skipped or not in Azure DevOps
- corrected typos in the shell script
- corrected use of `stageDependencies` in the deployment stage
- refactor firewall rules for migrations in the delivery stage
- simplified the patching mechanism in the `deployments` step for JavaScript projects

### Removed

- removed `after_script` from the JavaScript code check step

### Fixed

- fixed Golang delivery script not exiting with a non-zero exit code when the test fails
- fixed Golang test script not exiting with a non-zero exit code when the test fails
- fixed Gradle pipeline for Java projects in library mode which was missing the artifact for the management step
- fixed the JS pipeline to output the right tag in the delivery step
- fixed the regex matching the merge commit messages
- fixed the wrong Java JRE package

## [1.0.0] - 2023-01-02

### Added

- added GoLang support with the formatting basic checking
- added SAM delivery and deployment as independent approaches
- added the capability to merge config files in the `golanglint-ci`
- added the capability to run customized scripts in Debian-based images

### Changed

- changed the GoLang configuration linter to disable the `depguard` rules
- changed the structure to support two package managers in the Java category
- corrected GitLeaks script condition to test if there was an error
- corrected GoLang images to detect the right `$GOPATH`
- corrected GoLang tests step to avoid issues when there's no test at all in the application
- corrected all the structures to have segregated caches and numbered step-by-step jobs

### Removed

- removed Alpine images from GoLang stages because it doesn't work without `gcc` and `g++`
