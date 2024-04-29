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

- added `musl-tools` in the goreleaser pipeline to support building with musl
- added the `goreleaser` pipelines
- added the exposure for the coverage in Python projects
- added SonarQube for Java and Python projects
- added Maven support for Java projects
- added Azure Devops support for JavaScript
- added option to override a Semgrep rule
- added step to run migrations in Azure Pipelines
- added step to create and delete firewall rule to run migrations
- added the missing configuration to Azure DevOps deployment with JS
- added a new step to replace the environment variables contained inside the `yaml` file
- added a script into the Golang `delivery` to get the new `siteName` variable
- added the code check step for GoLang inside the GitHub Actions provider - [#19](https://github.com/rios0rios0/pipelines/issues/19)
- added the binary release feature for GoLang pipelines
- added a script into the Golang `delivery` to seed the database using `Goose`
- added Dependency Track and SonarQube for GoLang projects
- added K8s deployment for all languages in GitLab CI
- added `Alibaba AccessKey ID` regex to `allowlist`
- added task in `golang` stage `delivery` to replace the value of Azure function settings variables by library variables
- added skeleton for .NET project pipelines with basic steps

### Changed

- **BREAKING CHANGE**: changed the structure to support more than one CI/CD platform
- changed SonarQube to be inside the `management` step instead of the `delivery` step
- corrected Horusec issue with the Docker version
- corrected the coverage artifact to be uploaded with the XML report
- corrected typos in the shell script
- added the JS rules to test, monitor and deploy
- corrected Semgrep to add the ability to merge the ignored rules files
- changed the version of the container `GoLang` to `1.19`
- changed `release` code in every step to have a regex more flexible to catch in any merge case
- changed `semgrep` to only use default `.semgrepignore` file if custom is not available
- changed the GoLang code to have multiple standards to run testing
- refactor firewall rules for migrations in delivery stage
- corrected the way the delivery and deployment steps are skipped or not in Azure DevOps
- corrected GoLang delivery and deployment to have the default image and the proper format
- changed Javascript deployment to continue tasks with error
- corrected use of `stageDependencies` in the deployment stage
- changed GoLang pipeline to match with the GitHub merge commit message
- simplified the patching mechanism in the `deployments` step for JS
- changed directory of migrations into Golang `delivery`
- changed the Java projects to have deployment using Kubernetes environments
- changed the GoLang pipeline to remove the redundant make command
- changed the Python pipeline to fix the dependancy track stage by making sure the required packages are installed before executing the script
- changed the 
- changed the publish function task in `azure-devops/golang` `delivery` to use Azure CLI version 2.56.0 instead Azure Task because after this version Golang Azure Function is having time-out problems 
- changed the position of the script to get pipeline variables and added a new variable to be re-used in all code
- changed gradle version from `8.1` to `8.7`

### Removed

-

### Fixed

- fixed the regex matching the merge commit messages
- fixed the JS pipeline to output the right tag in the delivery step

## [1.0.0] - 2023-01-02

### Added

- added GoLang support with the formatting basic checking
- added SAM delivery and deployment as a separated approaches
- added the capability to merge config files in the `golanglint-ci`
- added the capability to run customized scripts in Debian-based images

### Changed

- changed the GoLang configuration linter to disable the `depguard` rules
- changed the structure to support two package managers in the Java category
- corrected GitLeaks Shell condition to test if there was an error
- corrected GoLang images to detect the right `$GOPATH`
- corrected GoLang tests step to avoid issues when there's no test at all in the application
- corrected all the structures to have segregated caches and numbered step-by-step jobs

### Removed

- removed Alpine images from GoLang stages because it doesn't work without `gcc` and `g++`
