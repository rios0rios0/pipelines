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

- added the goreleaser pipelines
- added the exposure for the coverage in Python projects
- added SonarQube for Java and Python projects
- added Maven support for Java projects
- added Azure Devops support for JavaScript
- added option to override a Semgrep rule

### Changed

- **BREAKING CHANGE**: changed the structure to support more than one CI/CD platform
- changed SonarQube to be inside the `management` step instead of the `delivery` step
- corrected Horusec issue with the Docker version
- corrected the coverage artifact to be uploaded with the XML report
- corrected typos in the shell script
- added the JS rules to test, monitor and deploy
- corrected Semgrep to add the capability to merge the ignore files
- changed the version of the container `GoLang` to `1.19`

### Removed

-

### Fixed

- fixed the regex matching the merge commit messages

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
