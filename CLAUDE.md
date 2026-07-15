# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A CI/CD pipeline templates library providing reusable workflows for **GitHub Actions**, **GitLab CI**, and **Azure DevOps** across Go, Python, Java, JavaScript, PHP, Ruby, .NET, Terraform, and Terra CLI. This is **not a runnable application** — it provides templates and scripts consumed by other projects.

## Commands

```bash
make test              # Run all validation tests (Go, Lambda, YAML merge, Trivy merge, SonarQube, release tag, tftest-gen, order-check, docker-multi-arch, basic-checks, dependency-check)
make test-go-script    # Test Go validation script only
make test-lambda       # Test Lambda template validation only
make test-yaml-merge   # Test YAML merge validation only
make test-trivy-merge  # Test Trivy global+project .trivyignore merge only
make test-sonarqube    # Test SonarQube auto-derivation only
make test-release-tag-idempotency  # Test release tag idempotency only
make test-tftest-gen   # Test tftest-gen generator only
make test-order-check  # Test the Terragrunt file-ordering checker/fixer only
make test-docker-multi-arch  # Test 40-delivery/docker multi-arch contract only
make test-basic-checks # Test basic-checks changelog validation (chlog fragments + legacy CHANGELOG.md) only
make test-dependency-check  # Test the OWASP Dependency-Check NVD cache / API-key contract only
make test-goreleaser-prepare  # Test the GoReleaser main package detection only
make test-release-version-extraction  # Test release version extraction (tag ref + bump commit) only
make test-release-reconcile  # Test release reconciliation gap detection only
make build-and-push NAME=<image> TAG=<tag>  # Build and push a container image
```

Test scripts live in `.github/tests/`. The CI workflow (`.github/workflows/ci.yaml`) validates YAML syntax, script permissions, and runs ShellCheck on all shell scripts.

## Architecture

### 5-Stage Pipeline Model

All platforms follow consistent numbered stages:
1. **10 - Code Check** — Linting, formatting, basic checks (rebase verification, changelog validation). The `terra`/`terraform` templates add an **order-check** job here that enforces the file-ordering standard (dependency/inputs ordering in `root.hcl`, `// SET ON .HCL` / `// SET ON .ENV` grouping in `variables.tf`, heaviest→lightest `providers.tf`, `main*.tf`-ordered `outputs.tf`) and flags dead terragrunt inputs (`inputs = {}` keys not declared as a stack `variable`); see Terraform Ordering Standard below
2. **20 - Security** — SAST (CodeQL, Semgrep, Gitleaks, Hadolint, ShellCheck, Trivy) and SCA
3. **30 - Tests** — Unit/integration tests, coverage. For the Azure DevOps `terraform` template, this stage runs three opt-in test tiers as parallel jobs: a plan-time smoke job (`tests/*.tftest.hcl` via `terraform test` with `mock_provider`) and an apply-time e2e job that provisions a disposable [kind](https://kind.sigs.k8s.io/) cluster and runs both `tests/e2e/*.tftest.hcl` (via `terraform test`) and `tests/terratest/*.go` (via the shared `terratest/run.sh`). All tiers are blocking so a red apply-time regression prevents `35-management` and `40-delivery` from running. The earlier `45-e2e` design was merged into `30-test` so smoke and apply-time feedback land in the same stage.
4. **35 - Management** — SBOM generation, dependency tracking
5. **40 - Delivery** — Artifact builds, container images
6. **50 - Deployment** — Azure DevOps only (ARM, Lambda, K8s)

### Directory Layout

- `.github/workflows/` — GitHub Actions reusable workflows (e.g., `go-docker.yaml`, `pdm-docker.yaml`)
- `gitlab/<language>/` — GitLab CI templates with `stages/`, `scripts/`, `abstracts/` subdirs
- `azure-devops/<language>/` — Azure DevOps templates, same structure as GitLab
- `global/scripts/tools/` — Platform-agnostic security tools (codeql, gitleaks, semgrep, hadolint, shellcheck, trivy, sonarqube, dependency-track)
- `global/scripts/languages/` — Language-specific scripts (golang, java, javascript, php, python, ruby, terraform). Most `run.sh` scripts follow shared conventions, but the Terraform helpers below are documented exceptions: they write reports directly under `build/reports/` and do not rely on the common `cleanup.sh` report-directory pattern.
  - `terraform/terra-test/` — `terraform test` runner over `modules/*/tests/*.tftest.hcl` (emits JUnit + Markdown/JSON/Cobertura coverage under `build/reports/`)
  - `terraform/terratest/` — Go Terratest runner over `tests/terratest/*.go` (emits JUnit under `build/reports/`)
  - `terraform/test-all/` — unified orchestrator for the first two tiers; runs both when present, merges JUnits into `build/reports/junit-terra-all.xml`, exits `0` when neither tier has tests (stack-only repos)
  - `terraform/structural/` — third tier runner for `tests/structural.sh` (repo-convention assertions the consumer owns); emits `build/reports/junit-structural.xml` (empty-but-valid on skip). Runs on its own parallel job (`test:structural`) instead of through `test-all` because the shell tier is offline and deps-free and shouldn't block on the heavier tiers
  - `terraform/cyclonedx/` — CycloneDX BOM generator for Terraform projects (delegates to `trivy filesystem --format cyclonedx`)
  - `terraform/tftest-gen/` — generator that emits `tests/smoke.tftest.hcl` for single-module repos; parses `variables.tf` + `main.tf` / `providers.tf` and emits `mock_provider` blocks plus validation-rejection runs
  - `terraform/order-check/` — checks (and with `--fix` rewrites) the file-ordering standard across `environments/**/root.hcl`, `stacks/*/{variables,providers,outputs}.tf`, and `**/providers.tf`, and additionally reports **dead terragrunt inputs** (an `inputs = {}` key with no matching `variable` in the target stack — reported only, never auto-deleted); emits `build/reports/junit-order-check.xml`. Runs as the `order-check` / `style:order-check` job in the `10-code-check` stage. Stdlib-only `python3`; the `--fix` rewriter is round-trip-safe (parses to exact substrings, then only permutes). See Terraform Ordering Standard below
- `global/scripts/shared/` — Shared utilities (cleanup.sh, rebase-check.sh, changelog-check.sh, reconcile-releases.sh)
- `global/containers/` — Docker image definitions for CI environments
- `makefiles/` — Includable `.mk` fragments for downstream projects (`common.mk`, `golang.mk`, `python.mk`, etc.)
- `.docs/examples/` — Complete per-platform usage examples

### Workflow Naming Convention

GitHub Actions workflow files (`.github/workflows/`) are named by **package manager or toolchain**, not by language. The language context is already provided by the directory structure (`github/<language>/stages/`). This matches the naming used in Azure DevOps and GitLab.

| Language   | Toolchain     | Workflow Name       | NOT            |
|------------|---------------|---------------------|----------------|
| Go         | go            | `go-docker.yaml`    | —              |
| Python     | PDM           | `pdm-docker.yaml`   | ~~python-docker.yaml~~ |
| Java       | Gradle        | `gradle-docker.yaml` | ~~java-docker.yaml~~       |
| Java       | Maven         | `maven-docker.yaml`  | ~~java-maven-docker.yaml~~ |
| JavaScript | Yarn          | `yarn-docker.yaml`   | ~~javascript-docker.yaml~~     |
| JavaScript | npm           | `npm-docker.yaml`    | ~~javascript-npm-docker.yaml~~ |
| PHP        | Composer      | `composer-docker.yaml` | ~~php-docker.yaml~~          |
| Ruby       | Bundler       | `bundler-docker.yaml`  | ~~ruby-docker.yaml~~         |
| C#         | dotnet        | `dotnet-docker.yaml` | —              |

When adding a new language or toolchain, always use the toolchain name in the workflow file.

### How Platforms Consume Templates

**GitHub Actions** — Reusable workflows via `uses: 'rios0rios0/pipelines/.github/workflows/<workflow>@main'`

**GitLab CI** — Remote includes via `remote: 'https://raw.githubusercontent.com/rios0rios0/pipelines/main/gitlab/<lang>/<template>.yaml'`

**Azure DevOps** — Template references via `template: 'azure-devops/<lang>/<template>.yaml@pipelines'` with a `resources.repositories` block

### Script Conventions

All `run.sh` scripts follow this pattern:
- Shebang: `#!/usr/bin/env sh` (POSIX sh, not bash)
- Auto-detect `SCRIPTS_DIR` if not set, using `dirname/realpath` with sed to find the pipelines root
- Source `cleanup.sh` to set up report directory cleanup
- Generate reports to `build/reports/<tool-name>/`
- Install the tool's native binary on demand instead of running a Docker image: check `command -v <tool>`, and when the binary is absent download it from upstream and prepend its location to `PATH`

**Why native installs instead of `docker run`:** Docker Hub enforces a pull rate limit on anonymous (and free-tier authenticated) requests. A `docker run <tool>:latest` on a cache-cold CI runner can therefore fail the whole job with a `toomanyrequests` error — a failure mode outside the team's control and unrelated to the code under scan. Every tool is consequently fetched directly from its own upstream rather than pulled as a Docker image:

| Tool(s) | Install method |
|------------------------------------------------|------------------------------------------------------------------------------------|
| `codeql`, `gitleaks`, `hadolint`, `shellcheck` | self-contained release binary downloaded from the project's GitHub releases         |
| `trivy`                                        | upstream `install.sh` (retry-with-backoff loop, then a pinned-version fallback)     |
| `semgrep`                                      | installed from PyPI into an isolated `python3 -m venv` — Semgrep ships no binary    |
| `sonarqube`                                    | expects `sonar-scanner` to already be on the runner                                 |
| `dependency-track`                             | no tool binary — uploads the CycloneDX BOM with `curl`                              |

Because the tools run directly on the host, the consuming CI job only needs the tool's own runtime dependencies (e.g. `python3` for `semgrep`, `git`/`jq`/`curl` for `gitleaks`) — not a Docker-in-Docker service.

### OWASP Dependency-Check and the NVD

`global/scripts/languages/java/dependency-check/run.sh` is the one runner all three platforms call for the Java `sca:dependency-check` job. Dependency-Check scans against a local H2 copy of the NVD (~350k CVE records), and **building that copy is the only expensive part of the job** — the NVD API rate limits it per source IP (5 requests/30s anonymous, 50 with a key), and hosted runners share their egress IPs, so an unauthenticated bootstrap does not finish. Three non-obvious constraints shape the design; do not "simplify" any of them away:

| Constraint | Why |
|------------|-----|
| The API key must be passed as `-DnvdApiKeyEnvironmentVariable=NVD_API_KEY` (Maven) or written into the `dependencyCheck.nvd.apiKey` extension (Gradle) | **Neither plugin reads an `NVD_API_KEY` environment variable.** Exporting it is a no-op — the historical cause of hours-long unauthenticated runs. `-DnvdApiKey=<value>` does work but leaks the secret into `mvn -X` output ([GHSA-qqhq-8r2c-c3f5](https://github.com/advisories/GHSA-qqhq-8r2c-c3f5)), so the *variable name* is passed instead of the value |
| Gradle is configured with `--init-script` (`init.gradle`), not properties | The Gradle plugin reads its settings **only** from the `dependencyCheck` extension — it consults neither the environment nor system properties. An init script injects them without asking every consuming project to edit its `build.gradle`. It applies on `projectsEvaluated`, so it wins over a project's own `dependencyCheck { }` block |
| GitHub Actions uses split `actions/cache/restore` + `actions/cache/save` with `if: always()` | The all-in-one `actions/cache` saves in a post-job step that is **skipped on cancellation**. A cancelled Dependency-Check job therefore cached nothing, so the next run started cold and was cancelled again — a loop the cache could never escape |

With no API key the runner falls back to NIST's gzipped JSON data feeds (`nvdDatafeedUrl`), which are not rate limited, so a keyless project still gets a usable scan. `NVD_DATAFEED_URL` overrides this with a self-hosted [`vulnz`](https://github.com/jeremylong/open-vulnerability-cli) mirror. The database is pinned to `.owasp/` (both plugins require an absolute path and otherwise default it into `~/.m2` / `$GRADLE_USER_HOME`, where the pipelines were not caching it) and reused for 24h via `nvdValidForHours`. The job is capped at 30 minutes on every platform so a pathological download is bounded rather than trusted. Covered by `.github/tests/test-dependency-check.sh`, which runs the script against a stub build tool and asserts on the argv it actually produces.

### Terra Test Tiers

The Terra CLI pipeline test stage exposes two parallel jobs on every platform (Azure DevOps, GitLab CI, GitHub Actions):

1. **`test:all`** — the unified test job, delegates to `global/scripts/languages/terraform/test-all/run.sh` which orchestrates the two heavier tiers:

   | Tier          | Input                              | Tool                             | Output                          |
   |---------------|------------------------------------|----------------------------------|---------------------------------|
   | `terra-test`  | `modules/*/tests/*.tftest.hcl`     | `terraform test -junit-xml`      | `terra-tests.xml`, `terra-coverage.{md,json,xml}` |
   | `terratest`   | `tests/terratest/*.go`             | `go test ./...` + `go-junit-report` | `junit-terratest.xml`         |

2. **`test:structural`** — third-tier shell runner, delegates to `global/scripts/languages/terraform/structural/run.sh`:

   | Tier          | Input                              | Tool                             | Output                          |
   |---------------|------------------------------------|----------------------------------|---------------------------------|
   | `structural`  | `tests/structural.sh` (consumer-owned) | executes the script directly | `junit-structural.xml`          |

The merged JUnit (`junit-terra-all.xml`) is the portable contract for `test:all` — GitLab CI's `artifacts:reports:junit` and GitHub Actions' `upload-artifact` both only take one file. `test:structural` publishes its own `junit-structural.xml` on a separate pipeline surface because it runs on its own job. When a tier has no tests (e.g., a stack-only repo without `modules/`, `tests/terratest/`, or `tests/structural.sh`), the corresponding runner emits an empty-but-valid JUnit and exits `0` so the job passes without a bespoke opt-out. `test:structural` runs on a parallel job rather than through `test-all` because the shell tier is offline and deps-free — queuing it behind the heavier Go / Terraform tiers would waste feedback time.

### Terraform Ordering Standard

The `order-check` job (`global/scripts/languages/terraform/order-check/`, in the `10-code-check` stage of the `terra` and `terraform` templates on all three platforms) enforces the team's file-ordering convention for dense Terragrunt monorepos (numbered dependency layers under `environments/`, root modules under `stacks/`, leaf modules under `modules/`). The rules:

| File | Rule |
|------|------|
| `environments/**/root.hcl` | `dependency` blocks ordered ascending by the `environments/NN_` number in `config_path`; the `inputs` block groups `dependency.<name>.outputs.*` assignments by ascending dependency number (locals/`tags` first, static literals last) |
| `stacks/*/variables.tf` | a `// SET ON .HCL` section before a `// SET ON .ENV` section; inside `.HCL`, **dependency-derived** variables ordered by the dependency number they are fed from (looked up from the paired `root.hcl` inputs). `tags`/literals/feature-flags are unconstrained |
| `**/providers.tf` (stacks + modules) | `required_providers` entries and top-level `provider` blocks ordered heaviest→lightest by a built-in ranking (cloud → data → orchestration → network/PKI → app/utility → trivial like `null`/`random`/`local`) |
| `stacks/*/outputs.tf` | outputs ordered to follow the declaration position of the first `module`/`resource` their value references in `main*.tf` |
| `inputs = {}` in `root.hcl` / leaf `terragrunt.hcl` | every input key must be declared as a `variable` in the target stack; an undeclared input is **dead code** (Terraform silently drops the `TF_VAR_` Terragrunt exports for it, so the value is passed and never read) and is reported so it can be deleted before pushing. The target stack is resolved from the file's literal `source` (or, for a leaf, its included `root.hcl`'s), falling back to path convention (`environments/<p>` → `stacks/<p>`) when the source path is interpolated; a container dir with no `*.tf` of its own is skipped. This rule is **check-only — `--fix` never deletes a dead input** (deleting would break the "only ever permute" invariant, and the stack is resolved heuristically), so the finding names the exact keys for a human to remove |

Check mode is a CI gate (emits `build/reports/junit-order-check.xml`); `run.sh --fix` rewrites files into order (except dead inputs, which are only reported). Missing `SET ON` markers, providers absent from the ranking, and files whose target stack cannot be resolved are **warnings/skips** (non-fatal). The provider ranking and path ignores are overridable per-repo via an optional `.terraform-order.json` (`{"provider_order": [...], "ignore": ["glob", ...]}`). The `--fix` rewriter parses each region into exact substrings, verifies a byte-for-byte round-trip, then only permutes those substrings — so it can never drop or corrupt content (it leaves any file it cannot parse cleanly untouched and reports it). Reordering `root.hcl` inputs changes `=` alignment, so run `terra format` / `terragrunt hcl format` after `--fix`; the `.tf` reordering is already `fmt`-clean.

### Makefile Include Pattern

Downstream projects include pipeline targets via:
```makefile
SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
-include $(SCRIPTS_DIR)/makefiles/common.mk    # setup, sast
-include $(SCRIPTS_DIR)/makefiles/golang.mk     # lint, test
```

The `-include` prefix makes includes optional (no error if pipelines not cloned).

## Contribution Requirements

- Changes **must** work across all three platforms (GitHub Actions, GitLab CI, Azure DevOps)
- Run `make test` before submitting
- **Mandatory updates**: CHANGELOG.md, relevant documentation, and test scenarios for new functionality
- Shell scripts must pass ShellCheck and must be executable (`chmod +x`)
- YAML indentation: 2 spaces, UTF-8, LF line endings (see `.editorconfig`)
