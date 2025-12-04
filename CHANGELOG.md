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

- added `make test` and `make test-go-script` targets for automated testing
- added complete test validation suite with `test-go-validation.sh` script
- added optional RESOLVE_S3 flag to Azure DevOps Go SAM delivery to support bucket auto resolving
- added support for building golang 1.25

### Changed

- **BREAKING CHANGE:** changed the structure on Azure DevOps to have files for each step inside each stage
- changed the Node version from `18.19.0` to `20.18.3` on Azure DevOps modules
- changed the OSD version to `3.2.0` due to an upgrade request on Azure DevOps modules
- enhanced coverage accuracy by using `-coverpkg` with all packages when tests are available
- updated GoLang version to `1.24.5` on Azure DevOps modules
- updated GoLang version to `1.25.0` on all pipelines and modules

### Fixed

- fixed deployment issue to deploy an AWS Lambda with SAM CLI
- fixed Go `1.25.1` compatibility issue in `global/scripts/golang/test/run.sh` by implementing comprehensive coverage reporting
- fixed coverage reporting to include all packages with Go files, not just packages with tests
- fixed synthetic coverage generation for projects with packages but no tests
- fixed the `Cache` task in `azure-devops/global/stages/40-delivery/docker.yaml` to create the Buildx cache
- fixed untested packages now appear as 0% covered instead of being excluded from coverage reports
- fixed workflow and delivery for GitHub Python Docker
- updated `CONTRIBUTING.md` and `copilot-instructions.md` with mandatory testing requirements
- fixed multi-platform builds failing for go1.x-awscli containers
- fixed Azure DevOps Go SAM delivery to normalize `RESOLVE_S3` booleans so `--resolve-s3` works with Azure True/False values

### Removed

- removed Cache task from `database.yaml` template in Azure DevOps GoLang pipeline since it was failing to restore cache with readonly files

## [2.2.0] - 2025-04-16

### Added

- added Azure global `docker.yaml` delivery template to be used by all languages
- added `arm-container.yaml` to run a container in Azure Container Instance
- added `arm-parameters.yaml` to generically construct `ARM` parameters from library variables
- added `checkstyle.xml` config file for Azure DevOps Java pipeline
- added a new optional parameter called `CUSTOM_PARAMETERS` in `go-arm-az-function` to add custom parameters in resource group deployment
- added a new pipeline in Azure DevOps for .NET Core (C#)
- added a new pipeline in Azure DevOps for Terraform
- added a new rule to ignore the Swagger comments to godot linter in `golangci-lint`
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
- changed a task that publishes artifact from `PublishBuildArtifact` to `PublishPipelineArtifact` in Azure DevOps JS's `execute-command-opensearch-dashboards.yaml` template
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
- fixed the error in `global/scripts/golang/test/run.sh` where `cmd` and `internal` folders were both required at the same time
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
