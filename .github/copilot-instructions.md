# CI/CD Pipeline Templates Repository

Start from these instructions. When they disagree with the code, the root `Makefile` or the suites in `.github/tests/`, the code is right and this file is stale.

This repository provides comprehensive SDLC pipeline templates for GitHub Actions, GitLab CI, and Azure DevOps across multiple programming languages including GoLang, Java, Python, JavaScript, PHP, Ruby, .NET, Dart/Flutter, and Terraform/Terra.

## Quick Reference

**Essential Commands:**
- `make test` - Run every validation suite; the prerequisites of the root `Makefile`'s `test` target are the authoritative list
- `make test-<suite>` - Run one suite; each target runs one script in `.github/tests/` (`AGENTS.md` lists every target with what it covers)
- `make test ONLY=go-helpers` - Run the Go helpers' unit tests (`go test ./...` over the root module; offline)
- `make lint` - Lint the Go helpers with the shared golden golangci-lint configuration (downloads the pinned golangci-lint)
- `make check-dependency-updates` - Report which pinned dependencies have a newer release (hits the network)
- `make apply-dependency-updates` - Rewrite every stale pin in the working tree, digests and inline copies included -- what the scheduled pull request carries (hits the network; commits nothing)
- `bash global/scripts/shared/cleanup.sh` - Clean up build reports

**Common Pipeline Usage:**
- **GitHub Actions:** Use `.github/workflows/go-docker.yaml@main`, `pdm-docker.yaml@main`, `gradle-docker.yaml@main`, `maven-docker.yaml@main`, `yarn-docker.yaml@main`, `npm-docker.yaml@main`, `composer-docker.yaml@main`, `bundler-docker.yaml@main`, `dotnet-docker.yaml@main`
- **GitLab CI:** Include `gitlab/golang/go-docker.yaml`, `gitlab/terraform/terra.yaml` from this repo
- **Azure DevOps:** Template `azure-devops/golang/go-docker.yaml@pipelines`

**SAST Tools:** Gitleaks, CodeQL, Semgrep, Hadolint, ShellCheck, Checkov (IaC misconfiguration, Terraform pipelines; advisory unless `CHECKOV_BLOCKING` is `true`)
**SCA Tools:** govulncheck (Go), Safety (Python), OWASP Dependency-Check (Java), yarn npm audit (JavaScript/Yarn), npm audit (JavaScript/npm), Composer Audit (PHP), bundler-audit (Ruby), OSV-Scanner (Dart, and container image rebuilds in the dependency-update checks)
**Quality Tools:** SonarQube, Dependency Track
**Performance:** Security scans 2-10min, Container builds 5-30min
**Architecture:** numbered stages 10 Code Check [lint + basic-checks] → 20 Security → 30 Tests → 35 Management → 40 Delivery → 50 Deployment

## Supply-Chain Pinning (non-negotiable)

Everything the pipelines execute is pinned, and `make test ONLY=supply-chain` fails the build if it is not:

- **GitHub Actions** — full 40-character commit SHA plus a trailing `# vX.Y.Z` comment. Never a bare tag.
  First-party references are the exception, in two forms that `test-workflow-composition.sh` (Test 7)
  holds: `rios0rios0/pipelines/...@main`, which moves on purpose, and `$/path/to/action`, which
  resolves at the exact commit of the running workflow (runner 2.336.0+; unavailable on GitHub
  Enterprise Server) and is required in the Yarn Semgrep chain. Never replace `$/` with `@main`.
- **Container images** — `tag@sha256:<digest>`, in `image:` keys (a scalar, or the `name:` of an `image:` mapping, both of which `dependency-updates` reads and re-pins) and Dockerfile `FROM` lines. An image whose tag names one exact build that is never rebuilt (the SonarQube scanner) also gets a pin in `pinned-versions.sh` with `# image: <repository>`; every copy follows that pin.
- **Downloaded binaries** — add the version and SHA-256 to `global/scripts/shared/pinned-versions.sh` and
  fetch through `download_verified` from `verify-download.sh`. Never `curl | sh`, and never an unverified
  `curl`/`wget` of a release artifact.
- **Packages** — `go install …@<version>`, `pip install "pkg==<version>"`, `gem install pkg -v <version>`,
  `npx --yes pkg@<version>`. Never `@latest` and never a bare package name.

To bump a tool: change its `*_PINNED_VERSION`, replace every `*_SHA256_*` from the upstream checksum
manifest (never carry an old digest forward), and run `make test ONLY=supply-chain`. The scheduled
`dependency-updates.yaml` workflow does exactly this twice a week and opens a pull request with the
result; it merges nothing.

Every pin carries a `# upstream: <kind> <coordinate>` annotation naming where its releases come from,
and every `*_SHA256*` an `# asset: <url with {version}>` annotation naming the file it is of (plus a
`# checksums:` manifest where the publisher ships one). Adding a pin or digest without its annotation
FAILS `make test ONLY=dependency-updates` — that is deliberate, because coverage otherwise shrinks one
forgotten annotation at a time while the job stays green, and a digest with no `# asset:` could never
be bumped. Write the `# asset:` URL exactly as the installer composes its download, then run
`./global/scripts/tools/dependency-updates/run.sh --verify-assets`: the automated bump refuses a pin
whose template does not reproduce the committed digest. A value written a second time in a template
with no `SCRIPTS_DIR` needs a row in `InlineCopies`
(`global/scripts/tools/dependency-updates/internal/domain/entities/scanning.go`), or the bump leaves it
behind. A binary also needs `# osv: <ecosystem> <package>` (or `# osv: none`) naming where its
advisories are published, or it fails as untracked.

The checker is Go (`go.mod` at the repository root), built from the checkout on every run by
`global/scripts/shared/go-helper.sh`; no Python helper remains in it. It never proposes a release that
introduces a known vulnerability or is a known malicious publication (OSV.dev), forces the fix of a
vulnerable pin in use, holds everything else for a seven-day cooldown, and scans every container image
rebuild against the image it replaces with OSV-Scanner. Go itself is a pin per release line
(`# upstream: go-toolchain golang.org/toolchain track=1.27`, `# osv: Go stdlib toolchain`), and every
`go-version:`, `GoTool@0` input and `golang:<release>` image is a copy of the pin of its line --
`internal/domain/entities/toolchain.go`. `dependency-updates-verify.yaml`
(`run.sh verify --base-dir <base> --repo-dir <head>`) re-proves every pin a pull request moves from its
diff; `security > verify:dependency-updates` is meant to be a required check, so a pull request that
moves no pin must keep asking the network nothing -- `test-dependency-updates.sh` runs it live with every
connection refused.

## Working Effectively

### Bootstrap and Setup
- **`make setup` in a consumer project** that includes `makefiles/common.mk` clones this repository
  into `$(PIPELINES_HOME)` or fast-forwards it, running `git` directly. This repository's own root
  `Makefile` does not include `makefiles/*.mk`, so it has no `setup` target.

- **Manual clone:**
  ```bash
  mkdir -p $HOME/Development/github.com/rios0rios0
  cd $HOME/Development/github.com/rios0rios0
  git clone https://github.com/rios0rios0/pipelines.git
  ```

- **Makefile integration (for downstream projects):**
  ```makefile
  SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
  -include $(SCRIPTS_DIR)/makefiles/golang.mk
  -include $(SCRIPTS_DIR)/makefiles/common.mk
  ```

### Running Scripts Locally
- **Scripts (all require proper environment setup):**
  ```bash
  # Clean up build reports directory
  bash global/scripts/shared/cleanup.sh

  # Run GoLang linting (downloads the pinned golangci-lint; needs a Go module in the current directory)
  bash global/scripts/languages/golang/golangci-lint/run.sh

  # Run security scanning with Gitleaks
  bash global/scripts/tools/gitleaks/run.sh  # downloads the pinned Gitleaks static binary
  ```

- **Container building:**
  ```bash
  # Build specific containers (may fail due to SSL in sandbox environments)
  make build-and-push NAME=awscli TAG=latest  # Requires Docker registry authentication
  make build NAME=awscli TAG=latest           # Build both architectures, publish nothing (no authentication)

  # Local build test (will likely fail on SSL certificate issues in sandbox)
  docker build -t test-image -f global/containers/awscli.latest/Dockerfile global/containers/awscli.latest/
  ```

### Scripts That Require Environment Variables
- **codeql/run.sh** - Requires language argument (e.g., go, python, java, javascript, csharp). For `go`, the `go` on PATH must be at least the module's `go` directive, because the autobuilder builds the module with it: the GitLab CI Go stage runs `sast:codeql` in the `.go` image, and the Azure DevOps Go stage passes the pinned `GoTool@0` through the CodeQL template's `PRE_STEPS`. The pinned bundle's extractor must read that directive too (every bundle from `codeql-bundle-v2.26.4` reads `go 1.27`); `make test ONLY=go-module-toolchain` holds both. `CODEQL_BUILD_MODE` (`none` or `autobuild`; unset by default, which keeps the CLI's autobuild) is passed to `database create` as `--build-mode`; GitLab CI's C# job sets `none`, because its .NET templates build .NET Framework projects that the Linux autobuilder cannot. Every language's GitLab CI `sast:codeql` runs in a glibc image with what its extractor needs, and every Azure DevOps language stage passes its toolchain through `PRE_STEPS`: see AGENTS.md, "Every Language's CodeQL Has What Its Extractor Needs", held by `make test ONLY=codeql-runtime`
- **hadolint/run.sh** - Auto-discovers Dockerfiles (`Dockerfile`, `Dockerfile.*`, `*.Dockerfile`, `*.dockerfile`), skips gracefully if none found
- **dependency-track/run.sh** - Requires `DEPENDENCY_TRACK_TOKEN` and `DEPENDENCY_TRACK_HOST_URL`; retries an upload the server answered with no response, `408`, `429` or `5xx`, waiting longer each time (`DEPENDENCY_TRACK_ATTEMPTS`, default 5; `DEPENDENCY_TRACK_RETRY_DELAY`, default 30 seconds), and fails at once on any other answer
- **sonarqube/run.sh** - Requires `sonar-scanner` installed and SonarQube environment; derives project key/name and the `githubactions:S7637` ignore rules for first-party workflow references (owners from `SONAR_FIRST_PARTY_OWNERS`, else the owner of `GITHUB_REPOSITORY`) for every key absent from `sonar-project.properties`, plus the test classification (`sonar.sources`, `sonar.tests`, `sonar.test.inclusions`, `sonar.exclusions`) as one unit, only when the file declares none of the four -- they are a partition, and an overlap aborts the scanner with "can't be indexed twice"; runs `sonar-scanner` again when its output shows the server was unreachable or answered 5xx, never after a quality gate verdict (`SONARQUBE_ATTEMPTS`, default 5; `SONARQUBE_RETRY_DELAY`, default 30 seconds, growing per attempt)
- **semgrep/run.sh** - May run for 10+ minutes, installs Semgrep from PyPI into a virtualenv
- **checkov/run.sh** - Scans Terraform under `CHECKOV_DIRECTORIES` (default `.`); advisory unless `CHECKOV_BLOCKING=true`; installs the pinned, digest-verified wheel into a virtualenv; skips gracefully when there is no Terraform
- **golang/test/run.sh** - Tests `cmd/`, `pkg/` and `internal/` when present, otherwise the whole module (`./...`)

## Available Tools & Scripts

### Security & Analysis Tools

#### SAST Tools

| Tool          | Purpose                       | Script Location                     | Configuration    |
|---------------|-------------------------------|-------------------------------------|------------------|
| **Gitleaks**  | Secret detection              | `global/scripts/tools/gitleaks/`    | `.gitleaks.toml` |
| **CodeQL**    | SAST security scanning        | `global/scripts/tools/codeql/`      | Auto-configured  |
| **Semgrep**   | Static analysis               | `global/scripts/tools/semgrep/`     | Auto-configured  |
| **Hadolint**  | Dockerfile linting            | `global/scripts/tools/hadolint/`    | `.hadolint.yaml` |
| **ShellCheck** | Shell script linting          | `global/scripts/tools/shellcheck/`  | Auto-configured  |
| **Checkov**   | IaC misconfiguration (Terraform) | `global/scripts/tools/checkov/`  | `.checkov.yaml`, inline `#checkov:skip=<ID>:<reason>` |

#### SCA Tools

| Tool                       | Purpose                           | Languages  | Script / Integration                           |
|----------------------------|-----------------------------------|------------|------------------------------------------------|
| **govulncheck**            | Go vulnerability scanning         | Go         | `global/scripts/languages/golang/govulncheck/` |
| **Safety**                 | Python dependency scanning        | Python     | `pdm run safety-scan`                          |
| **OWASP Dependency-Check** | Java dependency scanning          | Java       | `global/scripts/languages/java/dependency-check/` |
| **yarn npm audit**         | JS/Node.js dependency scanning    | JavaScript | `yarn npm audit --recursive`                   |
| **npm audit**              | JS/Node.js dependency scanning    | JavaScript | `npm audit --audit-level=high`                 |
| **Composer Audit**         | PHP dependency scanning           | PHP        | `composer audit`                               |
| **bundler-audit**          | Ruby dependency scanning          | Ruby       | `bundle-audit check --update`                  |

#### Quality & Management Tools

| Tool                 | Purpose                   | Script Location                          | Configuration         |
|----------------------|---------------------------|------------------------------------------|-----------------------|
| **Basic Checks**     | PR/MR rebase and changelog verification | `global/scripts/shared/rebase-check.sh`, `changelog-check.sh` | Auto-configured       |
| **SonarQube**        | Code quality & security   | `global/scripts/tools/sonarqube/`        | Project settings      |
| **Dependency Track** | SBOM tracking             | `global/scripts/tools/dependency-track/` | Environment variables |

### Language-Specific Tools

#### Go Tools

| Tool               | Purpose               | Script Location                                  |
|--------------------|-----------------------|--------------------------------------------------|
| **golangci-lint**  | Go linting suite      | `global/scripts/languages/golang/golangci-lint/` |
| **Go Test Runner** | Comprehensive testing | `global/scripts/languages/golang/test/`          |
| **CycloneDX**      | SBOM generation       | `global/scripts/languages/golang/cyclonedx/`     |
| **GoReleaser**     | Binary release builds | `global/scripts/languages/golang/goreleaser/`    |

#### Java Tools

| Tool            | Purpose                      | Script Location                               |
|-----------------|------------------------------|-----------------------------------------------|
| **Checkstyle**  | Java code style enforcement  | `global/scripts/languages/java/checkstyle/`   |

#### Dart / Flutter Tools

One set of scripts serves both toolchains: `dart_detect_toolchain` reads the project's `pubspec.yaml` and picks `flutter` when it finds a `flutter:\n    sdk: flutter` dependency, `dart` otherwise (`DART_TOOLCHAIN` overrides). The SDK is installed from Google's release archive rather than pulled as a Docker image, so no anonymous Docker Hub rate limit can fail the job. Every runner honours `DART_DRY_RUN=true`, which resolves and records commands without installing or executing anything — that is what makes the family testable offline.

| Tool             | Purpose                                                     | Script Location                                |
|------------------|-------------------------------------------------------------|------------------------------------------------|
| **setup**        | Installs the Dart or Flutter SDK                            | `global/scripts/languages/dart/setup/run.sh`     |
| **format**       | `dart format` gate (`--fix` rewrites in place)              | `global/scripts/languages/dart/format/run.sh`    |
| **analyze**      | `dart analyze` → JUnit + JSON, configurable severity gate    | `global/scripts/languages/dart/analyze/run.sh`   |
| **test**         | Tests + coverage → JUnit, Cobertura, LCOV, Markdown summary, filtered test events | `global/scripts/languages/dart/test/run.sh` |
| **unused**       | Unused code and unused file detection                        | `global/scripts/languages/dart/unused/run.sh`    |
| **sca**          | OSV-Scanner over `pubspec.lock`                              | `global/scripts/languages/dart/sca/run.sh`       |
| **build**        | Release artifacts (APK, AAB, web, exe, …)                    | `global/scripts/languages/dart/build/run.sh`     |
| **publish**      | pub.dev publication with a validation gate                   | `global/scripts/languages/dart/publish/run.sh`   |

**Four gaps in the standard stack for Dart are handled deliberately — do not "restore consistency" with the other languages:**

- **CodeQL is omitted from every Dart template.** It ships no Dart extractor ([dart-lang/sdk#52953](https://github.com/dart-lang/sdk/issues/52953)); a `sast:codeql` job could only fail. `makefiles/dart.mk` leaves `CODEQL_LANGUAGE` unset and `common.mk` skips the target with an explanation.
- **The Semgrep Registry publishes no Dart rules** (`p/dart` is HTTP 404, `r/dart` returns an empty `rules: []`). `semgrep/run.sh` probes the registry (retrying an inconclusive answer) and skips a missing pack — passing one is fatal to the whole invocation — then loads this repository's own ruleset from `global/scripts/tools/semgrep/rules/dart.yaml`.
- **OWASP Dependency-Check has no pub analyzer**, so OSV-Scanner is the only Dart SCA — it queries the Pub advisory database directly.
- **pub has no native CycloneDX generator** (`package:sbom` emits SPDX; `cdxgen` needs a Node.js toolchain), so there is **no SBOM job for Dart**. The BOM used to come from Trivy, which has been removed from this repository.

`.github/tests/test-dart-pipeline.sh` fails if any of these decisions is reverted.

The report converters the **analyze** and **test** runners call (`analyze/analyze-report.sh`, `test/lcov-to-cobertura.sh`, `test/lcov-to-markdown.sh`, `test/filter-test-events.sh`) are POSIX sh around awk programs loaded with the shared `common.awk`, run under `LC_ALL=C`, so a Dart job needs no Python. They reproduce the Python converters they replaced byte for byte, and the suite's section 7d holds every report against output recorded from those; the suite itself reads YAML and XML through `internal/testsuites/dartpipeline` (Go) and JSON through `jq`, and runs every script with a HOME, PUB_CACHE and PATH of its own, so a developer's activated `junitreport`, `coverage` or `dart_code_linter` cannot change its verdict.

#### Terraform / Terra Tools

The Terra CLI pipeline test stage exposes parallel jobs on every platform (Azure DevOps, GitLab CI, GitHub Actions) — two always on, one opt-in. `test:all` delegates to `test-all/run.sh`, which auto-detects which of the two heavier tiers the consumer has, runs only those, merges the JUnit outputs into `build/reports/junit-terra-all.xml`, and exits `0` when neither has tests so stack-only repos pass without a bespoke opt-out. `test:structural` and the opt-in `test:validate` each run on their own parallel job with their own JUnit. Only `validate` **resolves** references (`terraform validate`) — the other three tiers parse, so a root module referencing an undeclared module/variable/resource/output stays green everywhere else while failing every plan. `test:validate` is off by default (`ENABLE_VALIDATE` / `enable_validate`) because it needs the network for provider downloads and, for private module sources, credentials; each platform reuses its existing pre-script hook (`PRE_STEPS` / `VALIDATE_PRE_SCRIPT` / `pre_script`) and `VALIDATE_ROOTS` (default `stacks`) overrides the search. Root modules' own `tests/*.tftest.hcl` join `terra-test` only through `TERRA_TEST_ROOTS` (empty by default; Azure DevOps parameter or pipeline variable, GitLab CI variable, GitHub Actions `terra_test_roots` input), and a root whose test would apply with its real providers — a `run` block without `command = plan`, in a file with no `mock_provider` — is refused and fails the job rather than run, because under `-backend=false` a cancelled job would orphan what it created; module tests are not checked.

| Tool                     | Purpose                                            | Script Location                                         |
|--------------------------|----------------------------------------------------|---------------------------------------------------------|
| **Terra Test (unified)** | Orchestrates both heavier tiers behind one `test:all` job | `global/scripts/languages/terraform/test-all/run.sh`    |
| **terra-test**           | `terraform test` over `modules/*/tests/*.tftest.hcl`, plus root modules under the opt-in `TERRA_TEST_ROOTS` (default empty, e.g. `stacks`), refusing a root whose test would apply with real providers | `global/scripts/languages/terraform/terra-test/run.sh`  |
| **Terratest**            | Go test suite under `tests/terratest/*.go`         | `global/scripts/languages/terraform/terratest/run.sh`   |
| **Structural**           | Third-tier runner for `tests/structural.sh` (own `test:structural` job) | `global/scripts/languages/terraform/structural/run.sh`  |
| **validate** (opt-in)    | Fourth-tier `terraform init -backend=false` + `terraform validate` over root modules under `VALIDATE_ROOTS` (own `test:validate` job) | `global/scripts/languages/terraform/validate/run.sh`    |
| **tftest-gen**           | Generates `tests/smoke.tftest.hcl` for modules     | `global/scripts/languages/terraform/tftest-gen/run.sh`  |
| **order-check**          | Checks/auto-fixes file ordering (deps, variables, providers, outputs) and reports dead terragrunt inputs (`inputs = {}` keys not declared as a stack `variable`; reported only, never auto-deleted); runs in `10-code-check` | `global/scripts/languages/terraform/order-check/run.sh` |
| **var-catalog**          | Generates `stacks/<stack>/variables-shared.tf` from one canonical body per shared `variable` in a per-repo `.terraform-var-catalog.hcl`; output is committed (not a Terragrunt `generate` block) and hand-written declarations are never overwritten. `--check` is the CI gate | `global/scripts/languages/terraform/var-catalog/run.sh`  |
| **Terraform CycloneDX**  | SBOM generation for Terraform projects             | `global/scripts/languages/terraform/cyclonedx/run.sh`   |

`order-check`, `tftest-gen`, `var-catalog` and the terra-test tier's generic coverage report (`terra-test/coverage/`) are standard-library-only Go helpers, built from the pipelines checkout on every run through `global/scripts/shared/go-helper.sh`: they need Go 1.25 or newer, the `go` directive of the root `go.mod`, and nothing else. Every template that runs one provisions that Go (`make test ONLY=go-module-toolchain` holds it per job), `test:structural` included, since a consumer's `tests/structural.sh` is where `var-catalog --check` runs; running one locally -- `run.sh --fix`, the `tftest-gen` generator -- needs Go on `PATH`.

### Container Images

**Available Pre-built Images:**

| Image                       | Purpose                         | Registry                       |
|-----------------------------|---------------------------------|--------------------------------|
| `golang.1.27-awscli`        | Go 1.27 + AWS CLI               | `ghcr.io/rios0rios0/pipelines` |
| `python.3.14-pdm-trixie`    | Python 3.14 + PDM               | `ghcr.io/rios0rios0/pipelines` |
| `awscli.latest`             | AWS CLI tools                   | `ghcr.io/rios0rios0/pipelines` |
| `bfg.latest`                | BFG Repo-Cleaner                | `ghcr.io/rios0rios0/pipelines` |
| `mssql-tools18.latest`      | Microsoft SQL Server tools      | `ghcr.io/rios0rios0/pipelines` |
| `tor-proxy.latest`          | Network proxy with health check | `ghcr.io/rios0rios0/pipelines` |

### Key Directories
- `.github/workflows/` - Reusable GitHub Actions workflows
- `github/` - GitHub Actions pipeline templates (mirrors gitlab/ structure)
- `gitlab/` - GitLab CI pipeline templates
- `azure-devops/` - Azure DevOps pipeline templates
- `global/scripts/` - Shared scripts for linting, security scanning, testing
- `global/containers/` - Docker container definitions

## Repository Structure
```
pipelines/
├── .github/workflows/          # GitHub Actions reusable workflows
│   ├── go-docker.yaml         # Go with Docker delivery
│   ├── go-binary.yaml         # Go binary compilation
│   ├── go-library.yaml        # Go library publishing
│   ├── pdm-docker.yaml        # Python/PDM with Docker
│   ├── gradle-docker.yaml     # Java/Gradle with Docker delivery
│   ├── maven-docker.yaml      # Java/Maven with Docker delivery
│   ├── yarn-docker.yaml       # JavaScript/Yarn with Docker delivery
│   ├── npm-docker.yaml        # JavaScript/npm with Docker delivery
│   ├── composer-docker.yaml   # PHP/Composer with Docker delivery
│   ├── bundler-docker.yaml    # Ruby/Bundler with Docker delivery
│   ├── dotnet-docker.yaml     # .NET with Docker delivery
│   └── ...
├── github/                     # GitHub Actions composite actions the reusable workflows call
│   ├── golang/                # Go stages
│   ├── java/                  # Java stages
│   ├── python/                # Python stages
│   ├── javascript/            # JavaScript/Node.js stages
│   ├── dart/                  # Dart/Flutter stages
│   ├── global/                # Language-agnostic stages (basic-checks, SAST, release, docker, 50-deployment)
│   └── terra/                 # `terra.yaml`, a symlink into .github/workflows/
├── gitlab/                     # GitLab CI pipeline templates
│   ├── golang/                # Go language pipelines
│   ├── java/                  # Java language pipelines
│   ├── python/                # Python language pipelines
│   ├── javascript/            # JavaScript/Node.js pipelines
│   ├── dotnet/                # .NET language pipelines
│   ├── logstash/              # Logstash pipelines
│   ├── terraform/             # Terraform pipelines
│   ├── terra/                 # Terra CLI pipelines
│   └── global/                # Shared GitLab configurations
├── azure-devops/              # Azure DevOps pipeline templates
│   ├── golang/                # Go language pipelines
│   ├── java/                  # Java language pipelines
│   ├── python/                # Python language pipelines
│   ├── javascript/            # JavaScript/Node.js pipelines
│   ├── dotnet/                # .NET language pipelines
│   ├── terraform/             # Terraform pipelines
│   ├── terra/                 # Terra CLI pipelines
│   └── global/                # Shared Azure DevOps templates
├── global/                     # Shared resources across platforms
│   ├── scripts/               # Automation scripts
│   │   ├── tools/             # Language-agnostic tools
│   │   │   ├── codeql/        # SAST security scanning (CodeQL)
│   │   │   ├── gitleaks/      # Secret scanning
│   │   │   ├── hadolint/      # Dockerfile linting
│   │   │   ├── checkov/       # IaC misconfiguration scanning (Terraform)
│   │   │   ├── semgrep/       # Static analysis
│   │   │   ├── sonarqube/     # Code quality
│   │   │   └── dependency-track/ # SCA analysis
│   │   ├── languages/         # Language-specific scripts
│   │   │   ├── golang/        # Go scripts (test, cyclonedx, golangci-lint, goreleaser, govulncheck, cross-compile, init)
│   │   │   ├── java/          # Java scripts (checkstyle, pmd)
│   │   │   ├── javascript/    # JavaScript scripts (unused-code detection)
│   │   │   ├── php/           # PHP scripts (unused-code detection)
│   │   │   ├── python/        # Python scripts (cyclonedx, unused-code detection)
│   │   │   ├── ruby/          # Ruby scripts (unused-code detection)
│   │   │   └── terraform/     # Terraform scripts (terra-test, terratest, test-all, structural, validate, cyclonedx, tftest-gen, order-check, var-catalog)
│   │   ├── deploy/            # MVP hosting providers for the 50-deployment stage
│   │   │   ├── common.sh      # Shared helpers (sourced, not executed)
│   │   │   ├── cloudflare/    # Cloudflare Pages + Workers (wrangler)
│   │   │   ├── vercel/        # Vercel (vercel CLI)
│   │   │   ├── render/        # Render (REST API, polled to a terminal state)
│   │   │   ├── netlify/       # Netlify (netlify-cli)
│   │   │   └── flyio/         # Fly.io (flyctl; a delivered image copied with crane, or a remote build)
│   │   └── shared/            # Common utilities
│   ├── containers/            # Custom Docker images
│   │   ├── golang.*/          # Go development images
│   │   ├── python.*/          # Python development images
│   │   ├── awscli.latest/     # AWS CLI tools
│   │   ├── bfg.latest/        # BFG Repo-Cleaner
│   │   ├── mssql-tools18.latest/ # Microsoft SQL Server tools
│   │   └── tor-proxy.latest/  # Network proxy tools
├── makefiles/                  # Includable Makefile fragments for local usage
│   ├── common.mk              # Security tools (sast, secrets, hadolint, semgrep) — every target FAILS on findings
│   ├── golang.mk              # Go-specific targets (lint, test)
│   ├── python.mk              # Python/PDM targets (lint, test)
│   ├── java.mk                # Java/Gradle targets (lint, test)
│   ├── javascript.mk          # JavaScript/Yarn targets (lint, test)
│   ├── dotnet.mk              # .NET/C# targets (lint, test)
│   ├── terra.mk               # Terra CLI targets (lint, test)
│   └── terraform.mk           # Terraform targets (lint, test)
├── .docs/                      # Documentation and examples
│   └── examples/              # Per-provider usage examples
├── internal/testsuites/        # Go test support the validation scripts build for their run
└── .github/tests/              # Validation scripts for this repository
```

### Pipeline Architecture

Each platform follows the same numbered stages (10, 20, 30, 35, 40, 50; GitHub Actions has no 35 stage):

1. **🔍 Code Check (Style/Quality)** - Linting, formatting, code quality, rebase verification
2. **🔒 Security (SCA/SAST)** - Vulnerability scanning, secret detection
3. **🧪 Tests** - Unit tests, integration tests, coverage reporting
4. **📊 Management** - Dependency tracking, SBOM generation
5. **🚀 Delivery** - Build artifacts, container images, deployments. On GitHub, `delivery > release` (`github/global/stages/40-delivery/release/action.yaml`) cuts the version tag from a bump merge on the commit the run verified — pushed from the job's own checkout at `github.sha`, never through the Releases API, which tags the branch's *current* head — then creates the GitHub Release on it and, with `promote_release`, dispatches the tag run. A tag that already exists on that commit is kept; one on another commit fails the job by name. See README "Release Promotion"
6. **🌐 Deployment** - Optional per-provider hosting deploys (see below)

### MVP Hosting Deployment Providers

The `50-deployment` stage ships jobs for the five platforms most worth using to host an MVP cheaply.
Each is wired identically on all three CI platforms and delegates to one shared script under
`global/scripts/deploy/<provider>/run.sh`:

| Provider       | Free tier (Aug 2026)                                                        | Deploys via                          |
|----------------|-----------------------------------------------------------------------------|--------------------------------------|
| **Cloudflare** | Permanent, commercial use allowed, unmetered Pages bandwidth; 100k req/day  | `wrangler` (Pages or Workers)        |
| **Vercel**     | 100 GB transfer, 1M edge requests — **non-commercial use only**             | `vercel` CLI                         |
| **Render**     | 512 MB web service, sleeps after 15 min; free Postgres **expires at 30 days** | REST API (polled to terminal state) |
| **Netlify**    | 300 credits/month (~20 deploys)                                             | `netlify-cli`                        |
| **Fly.io**     | **None** — withdrawn 2024; ~$2/mo always-on                                 | `flyctl` (delivered image or remote build) |

Two rules govern this family and must not be relaxed:

- **Credentials never go on argv.** Every CLI takes its token from an environment variable; Render
  uses `curl --config -` (stdin). Argv is readable via `ps` on shared runners AND the resolved
  command line is recorded into `command.txt`, which is published as a job artifact.
- **`DEPLOY_DRY_RUN=true` must stay hermetic** — no CLI install, no network. That is what lets
  `make test ONLY=deploy-providers` exercise all five offline.

On GitHub Actions each provider also gets a **composed workflow**, `<toolchain>-<provider>.yaml`,
so a consumer calls one `uses:` and writes no deployment job at all — `go-render.yaml`,
`dart-cloudflare.yaml`, `yarn-cloudflare.yaml`, `npm-cloudflare.yaml`. See the next section for the
rules those files follow; `make test ONLY=workflow-composition` enforces them.

### Workflow Composition Standard

Full rationale in [AGENTS.md](../AGENTS.md#workflow-composition-standard). The rules an agent is
most likely to break, in order of how expensive the mistake was:

1. **Never couple two workflows with `on: workflow_run:`.** It matches by DISPLAY NAME and naming a
   workflow that does not exist is not an error — it never fires, silently. A consumer lost four
   days of deployments this way with a green pipeline throughout. A deploy is a job with `needs:`.
2. **Never hand-write a deployment job in a consumer repository.** Call the composed workflow. A
   hand-written job has no `require-checks` gate, no shared script, no cross-platform twin, and no
   test asserting any of it.
3. **Name is `<toolchain>-<suffix>.yaml`**, where a deployment suffix must match a real directory
   under `github/global/stages/50-deployment/`.
4. **Compose, never re-declare** — `uses:` the sibling workflow rather than copying its jobs.
5. **Job names are an API**: `delivery > <target>`, `deployment > <provider>`. Consumers pass these
   strings to `require-checks`; renaming one renames a check for everyone downstream.
6. **Every deployment job declares `needs:`, `environment:` and `if:`**, under a `# fifth stage`
   comment.
7. **Secrets are passed as secrets, not inputs** — an input loses the caller's masking. And a
   step-level `if:` cannot read the `secrets` context at all; hoist it into a job-level `env:`.
8. **A `uses:` job cannot declare `environment:`**, so its `with:`/`secrets:` are evaluated with no
   environment selected — `vars.API_URL` there is the repository-level value, usually empty, with
   no error. Name environment-scoped variables through `build_env_vars`; environment-scoped secrets
   cannot cross at all (next rule).
9. **Environment-scoped SECRETS cannot reach a workflow in this repository — at all.** Not via
   `secrets: inherit` (this library is a different owner from its consumers, and `inherit` only
   works within one organization), not explicitly, not by declaring `environment:` on the called
   job. Environment VARIABLES *do* cross, which is why `build_env_vars` works and the secret path
   does not. Consumers must hold deploy credentials at REPOSITORY scope and pass them explicitly.
   Verified by probe matrix: same-repo callee sees them, cross-repo callee never does, regardless
   of whether `environment:` is a literal or an expression.
10. **A gate that calls a status function also refuses a cancelled run.** Write
    `!cancelled() && !failure() && (…)`, never `!failure()` alone: a cancelled job is not a failed
    one, so a run superseded by `cancel-in-progress` still delivers and deploys a commit whose
    checks never finished. Every `||` clause needs a `!cancelled()` or `success()` of its own.
11. **A composed workflow declares and forwards every runner input its base takes** — `runs_on`,
    and any `<purpose>_runs_on` such as `codeql_runs_on`. A dropped override is invisible: the job
    falls back to `runs_on`, which looks exactly like the default. A job with its own selector
    writes `fromJSON(inputs.<purpose>_runs_on || inputs.runs_on)`, with `runs_on` last and the
    override optional and empty by default, or the fallback never happens.
12. **A `code-check >` or `security >` job is never advisory at the job level.** A job-level
    `continue-on-error` passes the run whatever the check found, so a failed lint blocked nothing
    for hours. Tolerate a refused report upload at the upload step instead. A deliberate exception
    goes in Test 16's `ADVISORY` with its reason, and `UNREVIEWED` may only shrink.

### Platform and Language Support Matrix

**Platforms:**
| Platform           | Status         | Documentation                  |
|--------------------|----------------|--------------------------------|
| **GitHub Actions** | ✅ Full Support | [Usage Guide](#github-actions) |
| **GitLab CI**      | ✅ Full Support | [Usage Guide](#gitlab-ci)      |
| **Azure DevOps**   | ✅ Full Support | [Usage Guide](#azure-devops)   |

**Programming Languages:**
| Language               | GitHub Actions | GitLab CI | Azure DevOps | Features                                  |
|------------------------|----------------|-----------|--------------|-------------------------------------------|
| **GoLang**             | ✅              | ✅         | ✅            | Binary, Docker, K8s, ARM, Lambda, Library |
| **Python**             | ✅              | ✅         | ✅            | PDM, Docker, K8s deployment, Library      |
| **Java**               | ✅              | ✅         | ✅            | Maven, Gradle, Docker, K8s, Library       |
| **JavaScript/Node.js** | ✅              | ✅         | ✅            | npm, Yarn, Docker, K8s deployment         |
| **PHP**                | ✅              | ❌         | ❌            | Composer, Docker                          |
| **Ruby**               | ✅              | ❌         | ❌            | Bundler, Docker                           |
| **.NET/C#**            | ✅              | ✅         | ✅            | Framework, Core, Docker, PowerShell       |
| **Dart**               | ✅              | ✅         | ✅            | pub.dev publishing, Docker, native binary |
| **Flutter**            | ✅              | ✅         | ✅            | Web bundle, Android APK/AAB, Docker       |
| **Logstash**           | ❌              | ✅         | ❌            | Docker delivery                           |
| **Terraform**          | ❌              | ✅         | ✅            | Infrastructure as Code                    |
| **Terra CLI**          | ✅              | ✅         | ✅            | Terraform/Terragrunt wrapper              |

**Pipeline Templates Available:**
- **GitHub Actions:** `go.yaml`, `go-docker.yaml`, `go-binary.yaml`, `go-library.yaml`, `pdm.yaml`, `pdm-docker.yaml`, `pdm-library.yaml`, `gradle.yaml`, `gradle-docker.yaml`, `gradle-library.yaml`, `maven.yaml`, `maven-docker.yaml`, `maven-library.yaml`, `yarn.yaml`, `yarn-docker.yaml`, `yarn-library.yaml`, `npm.yaml`, `npm-docker.yaml`, `npm-library.yaml`, `composer.yaml`, `composer-docker.yaml`, `composer-library.yaml`, `bundler.yaml`, `bundler-docker.yaml`, `bundler-library.yaml`, `dotnet.yaml`, `dotnet-docker.yaml`, `dotnet-library.yaml`, `dart.yaml`, `dart-docker.yaml`, `dart-library.yaml`, `flutter-artifacts.yaml`, `terra.yaml`
- **GitLab CI:** `go-docker.yaml`, `go-binary.yaml`, `go-docker-k8s-deployment.yaml`, `go-sam.yaml`, `gradle-docker.yaml`, `gradle-docker-k8s-deployment.yaml`, `gradle-library.yaml`, `maven-docker.yaml`, `pdm-docker.yaml`, `pdm-docker-k8s-deployment.yaml`, `pdm-library.yaml`, `yarn-docker.yaml`, `yarn-docker-k8s-deployment.yaml`, `framework.yaml`, `powershell.yaml`, `logstash-docker.yaml`, `dart/dart-docker.yaml`, `dart/dart-library.yaml`, `dart/flutter-docker.yaml`, `dart/flutter-artifacts.yaml`, `terraform/terra.yaml`, `terra/terra.yaml`
- **Azure DevOps:** `go-docker.yaml`, `go-arm.yaml`, `go-docker-arm.yaml`, `go-docker-k8s.yaml`, `go-docker-with-registry.yaml`, `go-function-arm.yaml`, `go-lambda-sam.yaml`, `go-lambda.yaml`, `go-library.yaml`, `kotlin-gradle.yaml`, `pdm-docker.yaml`, `yarn-docker.yaml`, `core.yaml`, `dart/dart-docker.yaml`, `dart/dart-library.yaml`, `dart/flutter-docker.yaml`, `dart/flutter-artifacts.yaml`, `terraform/terra.yaml`, `terra/terra.yaml`

## Common Tasks

### Using Pipeline Templates in Your Project

**GitHub Actions:**
```yaml
name: 'default'
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
permissions:
  checks: write
  contents: write
jobs:
  default:
    uses: 'rios0rios0/pipelines/.github/workflows/go-docker.yaml@main'
```

**GitLab CI:**
```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/golang/go-docker.yaml'

# Optional: Override delivery stage for custom Docker build
.delivery:
  script:
    - docker build -t "$REGISTRY_PATH$IMAGE_SUFFIX:$TAG" -f .ci/stages/40-delivery/Dockerfile .
  cache:
    key: 'test:all'
    paths: !reference [ .go, cache, paths ]
    policy: 'pull'

# Required GitLab Variables (configure in project settings):
# SONAR_HOST_URL     - SonarQube server URL
# SONAR_TOKEN        - SonarQube authentication token
# DOCKER_REGISTRY    - Container registry URL
# DOCKER_USERNAME    - Registry username
# DOCKER_PASSWORD    - Registry password
```

**Azure DevOps:**
```yaml
trigger:
  branches:
    include: [ main ]
  tags:
    include: [ '*' ]

pool:
  vmImage: 'ubuntu-latest'

variables:
  - ${{ if startsWith(variables['Build.SourceBranch'], 'refs/tags/') }}:
      - group: 'production-variables'
  - ${{ else }}:
      - group: 'development-variables'

resources:
  repositories:
    - repository: pipelines
      type: github
      name: rios0rios0/pipelines
      endpoint: 'YOUR_GITHUB_SERVICE_CONNECTION'  # Configure this

stages:
  - template: azure-devops/golang/go-arm.yaml@pipelines
    parameters:
      DOCKER_BUILD_ARGS: '--build-arg VERSION=$(Build.BuildNumber)'
      RUN_BEFORE_BUILD: 'echo "Preparing build environment"'

# Required Variable Groups (create in Azure DevOps Library):
# Shared Variables: SONAR_HOST_URL, SONAR_TOKEN
# Project Variables: SONAR_PROJECT_NAME, SONAR_PROJECT_KEY
```

### Language-Specific Examples

#### Python with PDM (GitLab CI)
```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/python/pdm-docker.yaml'

variables:
  PYTHON_VERSION: "3.11"  # Optional: specify Python version
```

#### Java with Maven (GitLab CI)
```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/java/maven-docker.yaml'
```

#### JavaScript with Yarn (GitLab CI)
```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/javascript/yarn-docker.yaml'
```

#### Terraform (GitLab CI)
```yaml
include:
  - remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/terraform/terra.yaml'
```

#### Java/Gradle with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  security-events: write
  contents: write
  packages: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/gradle-docker.yaml@main'
```

#### JavaScript/Yarn with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  security-events: write
  contents: write
  packages: write
  pull-requests: write
  checks: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/yarn-docker.yaml@main'
```

#### .NET with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  security-events: write
  contents: write
  packages: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/dotnet-docker.yaml@main'
```

#### JavaScript/npm with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  security-events: write
  contents: write
  packages: write
  pull-requests: write
  checks: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/npm-docker.yaml@main'
```

#### Java/Maven with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  security-events: write
  contents: write
  packages: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/maven-docker.yaml@main'
```

#### PHP/Composer with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  contents: write
  packages: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/composer-docker.yaml@main'
```

#### Ruby/Bundler with Docker (GitHub Actions)
```yaml
name: 'CI/CD Pipeline'
on:
  push:
    branches: [main]
    tags: ['*']
  pull_request:
    branches: [main]
permissions:
  security-events: write
  contents: write
  packages: write
jobs:
  pipeline:
    uses: 'rios0rios0/pipelines/.github/workflows/bundler-docker.yaml@main'
```

### Testing Pipeline Changes in Development Branches
```bash
export BRANCH=your-feature-branch
find . -type f -name "*.yaml" -exec sed -i.bak -E "s|(remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/)[^/]+(/.*)|\\1$BRANCH\\2|g" {} +
```

### Local Script Usage
```bash
# Set up environment for local script usage
export SCRIPTS_DIR=/home/$USER/Development/github.com/rios0rios0/pipelines

# Run any script
$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/run.sh

# Link golangci-lint config globally
ln -s $SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/.golangci.yml ~/.golangci.yml
```

### Comprehensive Local Development Examples

#### Configure Go Development
```bash
# Link global Go linting configuration
ln -s $SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/.golangci.yml ~/.golangci.yml

# Run linting in your project
$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/run.sh

# Run with auto-fix
$SCRIPTS_DIR/global/scripts/languages/golang/golangci-lint/run.sh --fix
```

#### Run Security Scanning Locally
```bash
# Run secret detection
$SCRIPTS_DIR/global/scripts/tools/gitleaks/run.sh

# Run SAST security scanning with CodeQL
$SCRIPTS_DIR/global/scripts/tools/codeql/run.sh go

# Run Dockerfile linting
$SCRIPTS_DIR/global/scripts/tools/hadolint/run.sh

# Run static analysis (can take 10+ minutes)
$SCRIPTS_DIR/global/scripts/tools/semgrep/run.sh
```

#### Run Tests and Coverage
```bash
# Run comprehensive Go tests
$SCRIPTS_DIR/global/scripts/languages/golang/test/run.sh

# Generate SBOM for Go projects
$SCRIPTS_DIR/global/scripts/languages/golang/cyclonedx/run.sh
```

#### Build and Test Container Images
```bash
# Build specific containers (may fail due to SSL in sandbox environments)
make build-and-push NAME=awscli TAG=latest

# Build both architectures without publishing anything (the verification mode)
make build NAME=awscli TAG=latest

# Local build test
docker build -t test-image -f global/containers/awscli.latest/Dockerfile global/containers/awscli.latest/
```

`make build` and `make build-and-push` run the SAME buildx recipe; only the output
differs (`--output=type=cacheonly` vs `--push`). The `Container Images` workflow
(`.github/workflows/containers.yaml`) exposes the same choice: it publishes on every
push to `main` under `global/containers/**`, and its `workflow_dispatch` takes
`container_folder` (a folder name; empty means all) plus a `push` boolean that
defaults to `false`. So dispatching a branch PROVES a container change builds on
`linux/amd64` and `linux/arm64` before it is reviewed -- the registry login is
skipped in that mode, so the run cannot publish over a released tag. Tick `push`
only to republish by hand; pushes to `main` never read the input and publish either
way.

## Validation and Testing

### Critical Testing Requirements
- **NEVER CANCEL long-running commands** - Some operations take 10+ minutes
- **Always test across all three platforms** (GitHub, GitLab, Azure DevOps)
- **Validate security scanning tools work** in target environments
- **Test container builds** with proper authentication
- **Run validation tests**: Execute `make test` before submitting changes
- **Verify coverage completeness**: Ensure coverage includes all packages, not just tested ones

### Manual Validation Steps
1. **Clone repository using provided scripts**
2. **Test script execution** in isolated environment
3. **Validate pipeline templates** by including them in test projects
4. **Verify Docker container builds** (may require network access)
5. **Check security scanning tools** download and run correctly
6. **Run test suite**: Execute `make test` for all validation tests

### Test Suite Usage
```bash
make test                       # every suite (the Makefile's `test` prerequisites)
make test ONLY=workflow-composition  # one suite, e.g. before touching .github/workflows/
```

Test scripts are located in `.github/tests/`; the Quick Reference above covers the target families.

### Coverage Testing Requirements
- Coverage reports MUST include all packages with Go files
- Untested packages MUST appear as 0% covered in reports
- Overall coverage percentage MUST reflect complete codebase visibility
- Test scenarios MUST validate comprehensive coverage behavior

### Environment Requirements
- Docker (for container builds; the security tools install natively)
- Go 1.25+ (for GoLang pipelines, to build and test the Go helpers such as the dependency-update checker, and to build the test support several suites in `.github/tests/` run)
- Python 3 only for the Python pipelines and the Semgrep and Checkov installs: nothing else here runs Python, and `make test ONLY=no-python` keeps it so
- Make (for build automation)
- Network access (for downloading tools and dependencies)

## Important Notes

### This is NOT an Application
- This repository provides **pipeline templates and scripts**, not a runnable application
- Users **consume these templates** in their own projects
- **No traditional build/test/run cycle** exists for the repository itself
- **Validation involves testing the templates** in example projects

### Timeout and Performance Expectations
- Script downloads: **1-5 seconds**
- Security scanning: **2-10 minutes** depending on tool and project size
- Container builds: **5-30 minutes** depending on base image and dependencies
- **NEVER CANCEL** operations that appear to be hanging - they may be downloading large images

### Detailed Performance Table

| Operation                    | Expected Duration | Notes                                  |
|------------------------------|-------------------|----------------------------------------|
| Script downloads             | 1-5 seconds       | First-time tool downloads              |
| Go linting (golangci-lint)   | 10-30 seconds     | Depends on codebase size               |
| Security scanning (Gitleaks) | 2-5 minutes       | Depends on repository size             |
| Security scanning (CodeQL)   | 3-10 minutes      | SAST analysis                          |
| Security scanning (Semgrep)  | 5-15 minutes      | Downloads large rule sets              |
| Container builds             | 5-30 minutes      | Depends on base image and dependencies |
| Go testing with coverage     | 10-60 seconds     | Depends on test suite size             |
| SonarQube analysis           | 2-10 minutes      | Depends on codebase size               |

**Important:** Never cancel operations that appear to be hanging - they may be downloading large Docker images or security rule sets.

### Known Limitations in Sandbox Environments
- Container builds may fail due to SSL certificate issues
- Security tools download their pinned binaries, so they need network access
- Some scripts need specific environment variables set
- Network restrictions may prevent tool downloads

### Troubleshooting Common Issues
- If scripts fail with "command not found", check if required tools are installed
- If container builds fail with SSL errors, this is expected in restricted environments
- If security scans timeout, increase timeout values and wait for completion
- If Go scripts fail, ensure you're in a directory with proper Go module structure

#### Platform-Specific Issues

**GitHub Actions:**
- **Issue:** Workflow doesn't trigger
- **Solution:** Check repository permissions, ensure workflow file is in `.github/workflows/`
- **Required Permissions:** `checks: write`, `contents: write`, `packages: write`

**GitLab CI:**
- **Issue:** "Remote file could not be fetched"
- **Solution:** Verify the remote URL is accessible, check branch name in URL
- **Issue:** Pipeline variables not recognized
- **Solution:** Configure required variables in GitLab project settings

**Azure DevOps:**
- **Issue:** "Template not found"
- **Solution:** Ensure GitHub service connection is configured correctly
- **Issue:** Variable group not found
- **Solution:** Create required variable groups in Azure DevOps Library

#### Security Tool Issues

**Issue: CodeQL analysis fails**
- **Cause:** CodeQL CLI not installed or language not supported
- **Solution:** Ensure network access to download CodeQL CLI bundle; supported languages: go, python, java, javascript, csharp, ruby (PHP is not supported)

**Issue: Gitleaks takes too long or fails**
- **Cause:** Large repository or network issues
- **Solution:** Increase timeout values, ensure the pinned Gitleaks release can be downloaded

**Issue: Semgrep timeout or hangs**
- **Cause:** Large codebase, downloading security rules
- **Solution:** Allow 10+ minutes for completion, don't cancel the operation

**Issue: SonarQube analysis fails**
- **Cause:** Missing SonarQube configuration or network issues
- **Solution:** Verify `SONAR_HOST_URL` and `SONAR_TOKEN` are correctly configured

**Issue: Dependency Track fails**
- **Cause:** Missing environment variables
- **Solution:** Ensure `DEPENDENCY_TRACK_TOKEN` and `DEPENDENCY_TRACK_HOST_URL` are set

#### Pipeline-Specific Issues

**Issue: "golangci-lint: command not found"**
- **Cause:** golangci-lint not installed or not in PATH
- **Solution:** none required -- the script uses a `golangci-lint` on `PATH` or in `./bin` that reports the pinned version, and otherwise downloads, verifies and installs the pinned release into `./bin`

**Issue: every package fails `typecheck` with `could not load export data` (Go projects)**
- **Cause:** the pinned golangci-lint cannot read the export data the Go toolchain writes; the script names this as a tooling mismatch after the run, and stops before linting when the toolchain is on a newer Go minor line than the binary's build
- **Solution:** bump `GOLANGCI_LINT_VERSION` in `global/scripts/shared/pinned-versions.sh` to a release that supports the toolchain -- the findings are not in the code

**Issue: Docker build fails with SSL certificate errors**
- **Cause:** Network restrictions in CI environment
- **Solution:** This is expected in restricted environments; contact platform administrator

Always validate changes by testing the pipeline templates in actual projects rather than testing the repository in isolation.

<!-- chlog:start -->
## Changelog (chlog) — MANDATORY

If the repository you are working in uses chlog (a `.chlog.yaml` or `.chlog.yml`
config file, or a `.changes/` directory, exists at the project root), the
following is binding and ALWAYS applies: whenever you make ANY change, you MUST
create a changelog fragment as part of the same change — automatically, without
being asked, before committing.

- Do NOT edit CHANGELOG.md directly; it is generated from fragments.
- Create the fragment with:
  `chlog new --kind <Kind> --body '<past-tense description>'`
- Write an apostrophe inside the single-quoted body as `'\''`.
- Valid kinds: Added, Changed, Deprecated, Removed, Fixed, Security
- Choose the kind that best matches the change (e.g., new feature → Added,
  bug fix → Fixed, behavior change → Changed, removal → Removed, security fix → Security).
- If the change is backward-INCOMPATIBLE with the public API (a breaking
  change), you MUST add the `--breaking` flag:
  `chlog new --kind <Kind> --breaking --body '<past-tense description>'`.
  This is the ONLY thing that triggers a major version bump — the kind alone
  never does (per SemVer, major = incompatible change). When unsure whether a
  change breaks compatibility, ask the user instead of guessing.
- Fragments are YAML files in `.changes/unreleased/`; stage them with your commit.
- `chlog check` fails the build when a fragment is missing — never skip it.
<!-- chlog:end -->
