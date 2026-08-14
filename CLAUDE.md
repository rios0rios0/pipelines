# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A CI/CD pipeline templates library providing reusable workflows for **GitHub Actions**, **GitLab CI**, and **Azure DevOps** across Go, Python, Java, JavaScript, PHP, Ruby, .NET, Dart/Flutter, Terraform, and Terra CLI. This is **not a runnable application** — it provides templates and scripts consumed by other projects.

## Commands

```bash
make test              # Run all validation tests (Go, CycloneDX main detection, Go cache trim, Lambda, YAML merge, Trivy merge, SonarQube, release tag, tftest-gen, order-check, var-catalog, terraform-validate, docker-multi-arch, basic-checks, dependency-check, goreleaser-prepare, release-version-extraction, release-reconcile, deploy-providers, dart-pipeline)
make test-go-script    # Test Go validation script only
make test-go-integration-scope  # Test which packages the Go runner's integration phase selects only
make test-lambda       # Test Lambda template validation only
make test-yaml-merge   # Test YAML merge validation only
make test-trivy-merge  # Test Trivy global+project .trivyignore merge only
make test-sonarqube    # Test SonarQube auto-derivation only
make test-release-tag-idempotency  # Test release tag idempotency only
make test-tftest-gen   # Test tftest-gen generator only
make test-order-check  # Test the Terragrunt file-ordering checker/fixer only
make test-var-catalog  # Test the shared variable-declaration generator only
make test-terraform-validate  # Test the root-module `terraform validate` tier only
make test-terraform-provider-mirror  # Test the local Terraform provider mirror only
make test-docker-multi-arch  # Test 40-delivery/docker multi-arch contract only
make test-basic-checks # Test basic-checks changelog validation (chlog fragments + legacy CHANGELOG.md) only
make test-dependency-check  # Test the OWASP Dependency-Check NVD cache / API-key contract only
make test-goreleaser-prepare  # Test the GoReleaser main package detection only
make test-release-version-extraction  # Test release version extraction (tag ref + bump commit) only
make test-release-reconcile  # Test release reconciliation gap detection only
make test-deploy-providers   # Test the MVP hosting deployment providers (Cloudflare, Vercel, Render, Netlify, Fly.io) only
make test-memory-detection  # Test the cgroup-aware memory ceiling detection only
make test-dart-pipeline # Test the Dart/Flutter pipeline (scripts, Semgrep rules, cross-platform wiring) only
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
6. **50 - Deployment** — two families with different platform coverage. The infrastructure targets (ARM, Lambda, K8s) remain **Azure DevOps only**; the **MVP hosting providers** (Cloudflare, Vercel, Render, Netlify, Fly.io) are wired on **all three platforms** — see MVP Hosting Providers below

### Directory Layout

- `.github/workflows/` — GitHub Actions reusable workflows (e.g., `go-docker.yaml`, `pdm-docker.yaml`)
- `gitlab/<language>/` — GitLab CI templates with `stages/`, `scripts/`, `abstracts/` subdirs
- `azure-devops/<language>/` — Azure DevOps templates, same structure as GitLab
- `global/scripts/tools/` — Platform-agnostic security tools (codeql, gitleaks, semgrep, hadolint, shellcheck, trivy, sonarqube, dependency-track)
- `global/scripts/languages/` — Language-specific scripts (golang, java, javascript, php, python, ruby, dart, terraform). Most `run.sh` scripts follow shared conventions, but the Terraform helpers below are documented exceptions: they write reports directly under `build/reports/` and do not rely on the common `cleanup.sh` report-directory pattern.
  - `dart/` — Dart and Flutter runners: `setup`, `format`, `analyze`, `test`, `unused`, `sca`, `cyclonedx`, `build`, `publish`, plus a sourced `common.sh` (not executable — it is sourced, never run). All honour `DART_DRY_RUN=true`, which resolves and records commands without installing or executing anything; that is what makes the whole family testable offline. See Dart & Flutter Support below
  - `terraform/terra-test/` — `terraform test` runner over `modules/*/tests/*.tftest.hcl` (emits JUnit + Markdown/JSON/Cobertura coverage under `build/reports/`)
  - `terraform/terratest/` — Go Terratest runner over `tests/terratest/*.go` (emits JUnit under `build/reports/`)
  - `terraform/test-all/` — unified orchestrator for the first two tiers; runs both when present, merges JUnits into `build/reports/junit-terra-all.xml`, exits `0` when neither tier has tests (stack-only repos)
  - `terraform/structural/` — third tier runner for `tests/structural.sh` (repo-convention assertions the consumer owns); emits `build/reports/junit-structural.xml` (empty-but-valid on skip). Runs on its own parallel job (`test:structural`) instead of through `test-all` because the shell tier is offline and deps-free and shouldn't block on the heavier tiers
  - `terraform/validate/` — fourth tier runner: `terraform init -backend=false` + `terraform validate` over every root module under `VALIDATE_ROOTS` (default `stacks`); emits `build/reports/junit-validate.xml` (empty-but-valid on skip). The only tier that RESOLVES references — the other three parse — so it is the only one that can see `Reference to undeclared module` / `Unsupported argument` in a root module. Runs on its own **opt-in** parallel job (`test:validate`), off by default because unlike its siblings it needs the network for provider downloads and, for private module sources, credentials
  - `terraform/cyclonedx/` — CycloneDX BOM generator for Terraform projects (delegates to `trivy filesystem --format cyclonedx`)
  - `terraform/tftest-gen/` — generator that emits `tests/smoke.tftest.hcl` for single-module repos; parses `variables.tf` + `main.tf` / `providers.tf` and emits `mock_provider` blocks plus validation-rejection runs
  - `terraform/order-check/` — checks (and with `--fix` rewrites) the file-ordering standard across `environments/**/root.hcl`, `stacks/*/{variables,providers,outputs}.tf`, and `**/providers.tf`, and additionally reports **dead terragrunt inputs** (an `inputs = {}` key with no matching `variable` in the target stack — reported only, never auto-deleted); emits `build/reports/junit-order-check.xml`. Runs as the `order-check` / `style:order-check` job in the `10-code-check` stage. Stdlib-only `python3`; the `--fix` rewriter is round-trip-safe (parses to exact substrings, then only permutes). See Terraform Ordering Standard below
  - `terraform/var-catalog/` — stdlib-only `python3` generator that keeps ONE canonical body per shared `variable` in a per-repo `.terraform-var-catalog.hcl` and writes the subset each stack actually uses into `stacks/<stack>/variables-shared.tf` (the same generic-script/repo-data split as `order-check`). Output is **committed**, not emitted by a Terragrunt `generate` block, because the order-check dead-input scan, the `terraform validate` tier, and AST-based tests all read `stacks/**/*.tf` from the source tree without invoking Terragrunt. It writes a sibling file rather than appending to `variables.tf` (so generated content is exempt from the `// SET ON` marker rule yet still seen by the dead-input glob) and **never overwrites a hand-written declaration** — a stack that already declares a catalogued name keeps its body and is reported. `run.sh --check` is the CI gate (fails if the committed output is stale); `--report` prints changes without writing
- `global/scripts/deploy/` — MVP hosting providers for the `50-deployment` stage: `cloudflare/` (Pages + Workers via `wrangler`), `vercel/`, `render/` (REST API, no CLI exists), `netlify/`, `flyio/`. Each is wired identically on all three platforms; `common.sh` is sourced, not executed, and holds the shared helpers. See MVP Hosting Providers below
- `global/scripts/shared/` — Shared utilities (cleanup.sh, rebase-check.sh, changelog-check.sh, reconcile-releases.sh, terraform-provider-mirror.sh). `terraform-provider-mirror.sh` is sourced by the `terra-test` and `validate` tiers: it points `terraform init` at provider stores this machine already populated (`TF_PROVIDER_MIRROR_DIR`, `TERRA_PROVIDER_CACHE_DIR`, the terra CLI's `~/.cache/terra/providers`, then the tier's own `TF_PLUGIN_CACHE_DIR`) via a `filesystem_mirror`, so a mirrored provider costs no registry query and no github.com checksum fetch. Falls back to the origin registry per directory, so a cold machine still works and pays one fetch per provider version instead of one per directory. `TF_PROVIDER_MIRROR=off` disables it
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
| Dart       | dart          | `dart-docker.yaml`   | ~~pub-docker.yaml~~ |
| Flutter    | flutter       | `flutter-artifacts.yaml` | ~~dart-flutter.yaml~~ |

Dart is the one language here with TWO toolchains sharing ONE package manager
(`pub`), so the workflow name follows the toolchain (`dart` / `flutter`) rather
than the package manager — the same precedent Go sets with `go.yaml`.

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
| The update mechanism is chosen by **database state**, not by whether a key exists | A key makes the *delta* fast; it does not make the ~350k-record *bootstrap* survivable. A shared runner egress IP sustains ~30 records/s even authenticated — >3h for a cold build, past any sane timeout. A cold or partial database is therefore always bootstrapped from the rate-limit-free datafeed, and the API is used only once a complete database has been restored |
| `cache/save` is gated on a `.owasp/.odc-complete` marker, not on `always()` alone | Saving unconditionally made one cancelled run permanent: the half-written database was published, restored, rejected by Dependency-Check, and rebuilt from zero until the timeout killed it and it saved another partial. `run.sh` clears the marker before running and writes it only after the analysis returns, so it is the one trustworthy "this database is whole" signal — a partial `odc.mv.db` is indistinguishable from a good one on disk |

With no API key the runner uses NIST's gzipped JSON data feeds (`nvdDatafeedUrl`), which are not rate limited, so a keyless project still gets a usable scan; a **cold** run uses them even when a key *is* present, for the reason in the table above. `NVD_DATAFEED_URL` overrides this with a self-hosted [`vulnz`](https://github.com/jeremylong/open-vulnerability-cli) mirror. The database is pinned to `.owasp/` (both plugins require an absolute path and otherwise default it into `~/.m2` / `$GRADLE_USER_HOME`, where the pipelines were not caching it) and reused for 24h via `nvdValidForHours`. The job is capped at 45 minutes on every platform so a pathological download is bounded rather than trusted — a safety net, not the fix; the datafeed bootstrap is what keeps a cold build under it. Covered by `.github/tests/test-dependency-check.sh`, which runs the script against a stub build tool and asserts on the argv it actually produces, including both the cold (datafeed) and warm (API delta) paths.

### Dart & Flutter Support

One set of templates and scripts serves both toolchains. `dart_detect_toolchain`
(in `global/scripts/languages/dart/common.sh`) reads the project's `pubspec.yaml`
and picks `flutter` when it finds a `flutter:\n    sdk: flutter` dependency,
`dart` otherwise; `DART_TOOLCHAIN` overrides it. The detection deliberately keys
on that dependency rather than on a top-level `flutter:` key — a pure Dart
package can carry the latter to declare assets without depending on Flutter at
all, and picking the wrong CLI fails deep inside the widget-test bindings.

Entry templates: `dart-docker`, `dart-library`, `flutter-docker`,
`flutter-artifacts` on GitLab CI and Azure DevOps; `dart.yaml`,
`dart-docker.yaml`, `dart-library.yaml`, `flutter-artifacts.yaml` on GitHub
Actions.

**Two tools in the standard stack do not support Dart.** Both gaps are handled
by a deliberate absence or substitution rather than by a job that silently checks
nothing; `.github/tests/test-dart-pipeline.sh` fails if either decision is
reverted. Do not "restore consistency" with the other languages here:

| Constraint | Why |
|------------|-----|
| **No `sast:codeql` job in any Dart template** | CodeQL ships no Dart extractor ([dart-lang/sdk#52953](https://github.com/dart-lang/sdk/issues/52953), open since 2023). `codeql database create --language=dart` is not a supported invocation, so the job could only fail. `makefiles/dart.mk` leaves `CODEQL_LANGUAGE` unset and `common.mk`'s `codeql` target skips with an explanation |
| **Semgrep runs, but the registry contributes nothing** | The engine parses Dart (experimental, actively maintained), but the registry publishes **zero** Dart rules: `p/dart` is HTTP 404 and `r/dart` returns a literal `rules: []`. Passing an unpublished pack is FATAL to the whole invocation, so `semgrep/run.sh` now probes the registry and skips a missing pack — only an explicit 404 skips it, so a network blip cannot quietly downgrade a scan. It then loads `global/scripts/tools/semgrep/rules/<language>.yaml` if this repository ships one, which for Dart it does |
| **OSV-Scanner replaces OWASP Dependency-Check** | Dependency-Check has no pub analyzer. OSV-Scanner queries the Pub advisory database directly and runs **alongside** `sca:trivy`, not instead of it: Trivy reads `pubspec.lock` but records SDK-provided dependencies (Flutter itself and anything resolved through it) at version `0.0.0`, leaving them unmatched against any advisory. Exit code 128 ("no packages found") is mapped to success — a lockfile with only SDK dependencies produces it, and the safest possible dependency set must not be a red job |
| **`dart analyze`, not `flutter analyze`** | `flutter analyze` has no `--format` option at all ([flutter/flutter#95090](https://github.com/flutter/flutter/issues/95090)), so it can only be scraped. The Flutter SDK's bundled `dart` runs the same analyzer over the same `analysis_options.yaml`, which is why `common.sh` symlinks it. The analyzer's own exit code is ignored and the verdict recomputed from the parsed diagnostics, because this pipeline's gate is configurable (`DART_FATAL_WARNINGS`, `DART_FATAL_INFOS`) and the tool's all-or-nothing verdict is the wrong one to propagate |
| **The SDK comes from `storage.googleapis.com`, never a Docker image** | Same reason every other tool here is installed natively: Docker Hub rate-limits anonymous pulls, and a large, frequently-pulled SDK image is exactly what trips it. `DART_SDK_INSTALL_DIR` relocates the unpack target because GitLab CI can only cache paths inside `$CI_PROJECT_DIR` |
| **Coverage is converted, not consumed raw** | Dart emits LCOV and nothing else. Azure DevOps' `PublishCodeCoverageResults@2` and GitLab's coverage visualisation both need Cobertura, so `test/lcov_to_cobertura.py` converts it — standard library only, so an offline `make test` can exercise it and a Dart job needs no Python toolchain. Repeated `SF:` records for one file are MERGED, not replaced: a multi-entry-point suite emits several, and taking the last would report only that suite's hits |
| **`dart_run` prints to stderr, never stdout** | Several callers capture the wrapped command's stdout because that stdout IS the payload (`dart test --reporter json`, `flutter test --machine`, `osv-scanner --format json`). A progress line on stdout would be interleaved into it and `tojunit`/`jq` would reject the whole document |
| **The pub token is never on argv** | `dart pub token add --env-var PUB_TOKEN` passes the variable's NAME; pub reads the value from the environment. Argv is world-readable via `ps`, and the recorded `command.txt` is published as a job artifact. Same reasoning as `-DnvdApiKeyEnvironmentVariable` above |

The shipped Semgrep ruleset (`global/scripts/tools/semgrep/rules/dart.yaml`)
holds eight rules covering TLS verification bypass, WebView JavaScript and
file-URL access, shell and SQL injection through interpolation, weak randomness
for security-sensitive values, cleartext HTTP, and secrets in
`SharedPreferences`. Two Dart-specific Semgrep mechanics are load-bearing and
were verified against the engine rather than assumed: patterns containing
`runInShell: true` must be QUOTED (YAML reads them as a nested mapping
otherwise), and interpolation must be detected with `metavariable-regex` — the
`"...$..."` string-ellipsis idiom is **not implemented for Dart**, so a rule
written with it loads cleanly and then matches nothing. When editing that file,
re-run `make test-dart-pipeline` with Semgrep installed; the suite asserts every
rule still matches its vulnerable sample and none matches the safe counterpart.

### Terra Test Tiers

The Terra CLI pipeline test stage exposes three parallel jobs on every platform (Azure DevOps, GitLab CI, GitHub Actions) — two always on, one opt-in:

1. **`test:all`** — the unified test job, delegates to `global/scripts/languages/terraform/test-all/run.sh` which orchestrates the two heavier tiers:

   | Tier          | Input                              | Tool                             | Output                          |
   |---------------|------------------------------------|----------------------------------|---------------------------------|
   | `terra-test`  | `modules/*/tests/*.tftest.hcl`     | `terraform test -junit-xml`      | `terra-tests.xml`, `terra-coverage.{md,json,xml}` |
   | `terratest`   | `tests/terratest/*.go`             | `go test ./...` + `go-junit-report` | `junit-terratest.xml`         |

2. **`test:structural`** — third-tier shell runner, delegates to `global/scripts/languages/terraform/structural/run.sh`:

   | Tier          | Input                              | Tool                             | Output                          |
   |---------------|------------------------------------|----------------------------------|---------------------------------|
   | `structural`  | `tests/structural.sh` (consumer-owned) | executes the script directly | `junit-structural.xml`          |

3. **`test:validate`** (opt-in) — fourth-tier root-module check, delegates to `global/scripts/languages/terraform/validate/run.sh`:

   | Tier          | Input                              | Tool                             | Output                          |
   |---------------|------------------------------------|----------------------------------|---------------------------------|
   | `validate`    | every `*.tf`-bearing dir under `VALIDATE_ROOTS` (default `stacks`) | `terraform init -backend=false` + `terraform validate` | `junit-validate.xml`  |

   The other three tiers **parse**; this is the only one that **resolves** a reference. `terra-test` covers only reusable modules carrying a test file, `terratest` reads HCL offline, and `structural` asserts conventions in bash — none has an evaluation context, a module graph or a provider schema. So a root module can reference a module, variable, resource or output that does not exist and all three stay green, while the defect fails *every* plan and apply of that root module, for every target, before a resource is touched.

   Opt-in per platform, each in the form that platform already uses for options — Azure DevOps `ENABLE_VALIDATE: true` (template parameter), GitLab CI `ENABLE_VALIDATE: "true"` (CI/CD variable gating `rules`), GitHub Actions `enable_validate: true` (workflow input) — because unlike its siblings it needs the network for provider downloads and, for private module sources, credentials, which each platform's existing pre-script hook supplies (`PRE_STEPS`, `VALIDATE_PRE_SCRIPT`, `pre_script`). `-backend=false` keeps it a test rather than a deployment step: no backend credentials, no state access, no cloud login. Vendored copies under `.terraform/` are excluded.

The merged JUnit (`junit-terra-all.xml`) is the portable contract for `test:all` — GitLab CI's `artifacts:reports:junit` and GitHub Actions' `upload-artifact` both only take one file. `test:structural` publishes its own `junit-structural.xml` on a separate pipeline surface because it runs on its own job. When a tier has nothing to act on (e.g., a stack-only repo without `modules/`, `tests/terratest/` or `tests/structural.sh`, or — for `validate` — no directory matching `VALIDATE_ROOTS`), the corresponding runner emits an empty-but-valid JUnit and exits `0` so the job passes without a bespoke opt-out. `test:structural` runs on a parallel job rather than through `test-all` because the shell tier is offline and deps-free — queuing it behind the heavier Go / Terraform tiers would waste feedback time.

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

### MVP Hosting Providers

The `50-deployment` stage ships jobs for the five platforms most worth using to host an MVP cheaply. Each is wired identically on all three platforms (`github/global/stages/50-deployment/<p>/action.yaml`, `gitlab/global/stages/50-deployment/<p>.yaml`, `azure-devops/global/stages/50-deployment/<p>.yaml`) and delegates to `global/scripts/deploy/<p>/run.sh`. Ranked in `README.md` by a stated composite of price (50%), reliability (30%) and popularity (20%).

| Provider | Free tier (verified Aug 2026) | Deploys via |
|----------|-------------------------------|-------------|
| **Cloudflare** | Permanent, **commercial use allowed**, Pages bandwidth unmetered; Workers 100k req/day, 10ms CPU | `wrangler pages deploy` / `wrangler deploy` |
| **Vercel** | 100 GB transfer, 1M edge requests, 6k build min — **non-commercial only**, revenue requires Pro | `vercel deploy` |
| **Render** | 512 MB web service, **sleeps after 15 min idle** (30-60s cold start); free Postgres **expires at 30 days** | REST API — Render publishes no CLI |
| **Netlify** | 300 credits/month; deploys cost 15 each, bandwidth 20/GB — roughly **20 deploys/month** | `netlify deploy --no-build` |
| **Fly.io** | **None.** Withdrawn 2024 (2-hour trial); ~**$2/mo** always-on, ~35 regions | `flyctl deploy --remote-only` |

Four constraints shape this family; do not "simplify" any of them away:

| Constraint | Why |
|------------|-----|
| **A credential is never passed on argv** | Argv is world-readable through `ps` for the process's lifetime on a shared or self-hosted runner, AND `deploy_run` records the resolved command line into `command.txt`, which all three platforms publish as a downloadable artifact — so a token on argv is exfiltrated into that artifact and kept for its retention period. Every CLI here reads its token from the environment; Render uses `curl --config -` (stdin). Its deploy hook URL embeds a secret in the query string, so the whole URL is redacted rather than recorded. Same reasoning as `-DnvdApiKeyEnvironmentVariable` above |
| **`DEPLOY_DRY_RUN=true` installs nothing and touches no network** | It is the only reason `make test-deploy-providers` can exercise all five providers offline, with no credentials and no Node.js toolchain. A dry run that installed a CLI would add ~100 MB per provider and make the suite need npm |
| **Render's API key is preferred over its deploy hook** | A deploy hook is fire-and-forget: Render returns success for "request accepted", so the job goes **green even when the build that follows fails**, making the job's status meaningless. The API path returns a deploy id the script polls to a terminal state. The hook path warns about exactly this |
| **`flyctl` comes from the GitHub release archive, never `curl \| sh`** | Piping a remote script into a shell hands the runner's credentials to whatever that URL returns at that moment — the supply-chain shape this repository's own SAST stage exists to flag. Matches the gitleaks/hadolint/shellcheck install pattern |

Covered by `.github/tests/test-deploy-providers.sh` (114 assertions): the cross-platform wiring contract (a provider added to one platform and forgotten on the other two leaves three files that are each valid YAML on their own, so nothing else in CI would catch it), the argv each provider builds under dry run, and a sentinel-credential leak check over the whole report directory.

### Makefile Include Pattern

Downstream projects include pipeline targets via:
```makefile
SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
-include $(SCRIPTS_DIR)/makefiles/common.mk    # setup, sast
-include $(SCRIPTS_DIR)/makefiles/golang.mk     # lint, test
```

Order matters for `dart.mk`: it APPENDS its `sca` target to `common.mk`'s `sast`
(a prerequisite-only rule, so appending emits no "overriding recipe" warning),
so `common.mk` must be included first.

The `-include` prefix makes includes optional (no error if pipelines not cloned).

## Contribution Requirements

- Changes **must** work across all three platforms (GitHub Actions, GitLab CI, Azure DevOps)
- Run `make test` before submitting
- **Mandatory updates**: CHANGELOG.md, relevant documentation, and test scenarios for new functionality
- Shell scripts must pass ShellCheck and must be executable (`chmod +x`)
- YAML indentation: 2 spaces, UTF-8, LF line endings (see `.editorconfig`)
