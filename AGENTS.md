# AGENTS.md

This file provides guidance to AI coding agents (Claude Code, Codex, Cursor, GitHub Copilot) when working with code in this repository.

## What This Is

A CI/CD pipeline templates library providing reusable workflows for **GitHub Actions**, **GitLab CI**, and **Azure DevOps** across Go, Python, Java, JavaScript, PHP, Ruby, .NET, Dart/Flutter, Terraform, and Terra CLI. This is **not a runnable application** — it provides templates and scripts consumed by other projects.

## Commands

```bash
make test              # Run every validation suite; the prerequisites of the Makefile's `test` target are the authoritative list
make test-go-script    # Test Go validation script only
make test-cyclonedx-main  # Test the Go CycloneDX entry-point detection only
make test-go-cache-trim   # Test the Go build-cache disk guard (threshold parsing, trim decision) only
make test-go-module-toolchain  # Test that every go.mod toolchain directive is readable by the images/analysers/workflows that consume it only
make test-go-tool-staleness    # Test that a source-built Go tool (govulncheck) is rebuilt when its toolchain/pin moves only
make test-govulncheck-verdict  # Test that govulncheck fails on a vulnerability the code calls, read from its report rather than the `-json` exit code only
make test-go-tmpdir-modcache   # Test that the Go module cache stays out of $TMPDIR only
make test-go-cross-compile     # Test the Go cross-compile runner (every target in one job, at most CROSS_COMPILE_JOBS at once, a failing target named) only
make test-go-integration-scope  # Test which packages the Go runner's integration phase selects only
make test-lambda       # Test Lambda template validation only
make test-yaml-merge   # Test golangci-lint/run.sh (config merge, binary reuse and install, toolchain guard) only
make test-golangci-scanner-markers  # Test that `golangci-lint/run.sh --fix` keeps other scanners' allow markers (e.g. `//gitleaks:allow`) only
make test-sonarqube    # Test SonarQube auto-derivation and the retry of a scanner run the server broke only
make test-release-tag-idempotency  # Test release tag idempotency only
make test-tftest-gen   # Test tftest-gen generator only
make test-terra-coverage  # Test the Terraform generic coverage report generator only
make test-order-check  # Test the Terragrunt file-ordering checker/fixer only
make test-var-catalog  # Test the shared variable-declaration generator only
make test-terraform-validate  # Test the root-module `terraform validate` tier only
make test-terraform-provider-mirror  # Test the local Terraform provider mirror only
make test-terra-test-roots  # Test the terra-test tier's opt-in root-module run (`TERRA_TEST_ROOTS`) only
make test-terra-install  # Test the terra CLI installer (pin check, installs that run together on one HOME, Azure DevOps step stops at a failed install) only
make test-docker-multi-arch  # Test 40-delivery/docker multi-arch contract only
make test-build-version  # Test the version build argument (shared helper, GitHub image delivery, Fly.io deploy, Go workflow wiring) and the delivered image's way to the Fly.io deploy only
make test-containers-detect  # Test the Container Images change detection (deleted/renamed folders, dispatch inputs) only
make test-basic-checks # Test basic-checks changelog validation (chlog fragments + legacy CHANGELOG.md) only
make test-fixture-isolation  # Test that every suite builds its fixtures in mktemp space and guards every cd only
make test-gitignore    # Test the shared .gitignore block generator only
make test-sast-gate    # Test that the SAST targets propagate tool failures only
make test-hadolint-discovery  # Test which files the Hadolint runner lints as Dockerfiles (every name the delivery templates build) only
make test-checkov      # Test the Checkov IaC scanner tier (verified install, report verdict, advisory default, wiring on every platform) only
make test-codeql-scope  # Test that a local CodeQL scan builds from the files git would ship, on every core, only
make test-codeql-gate   # Test that CodeQL fails on findings `.codeql-false-positives` does not list, on every platform, and that the GitHub upload cannot fail the job, only
make test-codeql-runtime  # Test where each language's CodeQL analysis runs and with what (GitLab CI images and installs, run.sh's report and build mode, the Azure DevOps and GitHub Actions toolchains, every Node.js the templates name against its end of life) only
make test-dependency-check  # Test the OWASP Dependency-Check NVD cache / API-key contract only
make test-dependency-track  # Test the Dependency-Track BOM uploader (identity, isLatest gating, PR skip, retry of a briefly unreachable server, cross-platform wiring) only
make test-python-cyclonedx  # Test static/non-distribution and dynamic Python SBOM versions, including resolution failures
make test-goreleaser-prepare  # Test the GoReleaser main package detection only
make test-release-version-extraction  # Test release version extraction (tag ref + bump commit) only
make test-release-reconcile  # Test release reconciliation gap detection only
make test-release-promotion  # Test release promotion (the tag run a bump merge now starts) only
make test-deploy-providers   # Test the MVP hosting deployment providers (Cloudflare, Vercel, Render, Netlify, Fly.io) only
make test-build-env-vars   # Test the step that resolves `build_env_vars` in the three Cloudflare deployment workflows (one identical step, what it writes, no Python) only
make test-no-python    # Test that the repository runs no Python of its own: no `.py` file, and no interpreter outside the Python pipelines and the Semgrep/Checkov installs, only
make test-memory-detection  # Test the cgroup-aware memory ceiling detection only
make test-dart-pipeline # Test the Dart/Flutter pipeline (scripts, report converters, Semgrep rules, cross-platform wiring) only
make test-terra-pipeline # Test the Terraform/terra pipeline's CodeQL tool gap (GitHub, GitLab, Azure, terra.mk, terraform.mk) only
make test-javascript-pipeline  # Test the JavaScript formatting gate (Prettier runner + cross-platform wiring) only
make test-phpmd        # Test the PHPMD runner (the command line each major takes, the verdict, a report that stays JSON) only
make test-workflow-composition  # Test the GitHub Actions workflow composition standard only
make test-working-directory  # Test the `working_directory` threading contract (bundler/npm/yarn and their variants) only
make test-supply-chain # Test the supply-chain pinning contract (actions, images, binaries, packages) only
make test-runner-cache-gating  # Test that no GitHub Actions cache restores into $HOME on a self-hosted runner only
make test-dependency-updates  # Test the dependency-update tool's wiring (run.sh, report isolation, both workflows) only
make test-go-helpers         # Run the Go helpers' unit tests (`go test ./...`; the dependency-update tool's behaviour, policy and command line)
make lint-go-helpers         # Lint the Go helpers with the shared golden golangci-lint configuration (downloads the pinned golangci-lint)
make check-dependency-updates # Report which pinned dependencies have a newer release (network)
make apply-dependency-updates # Rewrite every stale pin in the working tree, digests included -- what the scheduled pull request carries (network)
make test-azure-step-names  # Test Azure DevOps step-name uniqueness across expanded templates only
make test-azure-secret-env  # Test that every Azure step consuming a credential maps it through `env:` only
make test-report-uploads  # Test that no GitHub Actions report upload can fail its job or ask to be kept longer than the repository keeps artifacts, while mandatory reports stay enforced, only
make build-and-push NAME=<image> TAG=<tag>  # Build and push a container image
make build NAME=<image> TAG=<tag>           # Build both architectures, publish nothing (verification)
```

Test scripts live in `.github/tests/`. The CI workflow (`.github/workflows/ci.yaml`) validates YAML syntax, script permissions, and runs ShellCheck on all shell scripts. A suite whose checks parse YAML or read files structurally keeps them as Go test support under `internal/testsuites/<suite>/`, which the suite builds from the checkout for its run (`go build -C "$SCRIPTS_DIR" ...`) and stops on if the build fails; `make test-go-helpers` runs their unit tests.

## Architecture

### Pipeline Stage Model

All platforms follow consistent numbered stages:
1. **10 - Code Check** — Linting, formatting, basic checks (rebase verification, changelog validation). The `terra`/`terraform` templates add an **order-check** job here that enforces the file-ordering standard (dependency/inputs ordering in `root.hcl`, `// SET ON .HCL` / `// SET ON .ENV` grouping in `variables.tf`, heaviest→lightest `providers.tf`, `main*.tf`-ordered `outputs.tf`) and flags dead terragrunt inputs (`inputs = {}` keys not declared as a stack `variable`); see Terraform Ordering Standard below
2. **20 - Security** — SAST (CodeQL, Semgrep, Gitleaks, Hadolint, ShellCheck; Checkov for the `terra`/`terraform` templates) and SCA
3. **30 - Tests** — Unit/integration tests, coverage. For the Azure DevOps `terraform` template, this stage runs three opt-in test tiers as parallel jobs: a plan-time smoke job (`tests/*.tftest.hcl` via `terraform test` with `mock_provider`) and an apply-time e2e job that provisions a disposable [kind](https://kind.sigs.k8s.io/) cluster and runs both `tests/e2e/*.tftest.hcl` (via `terraform test`) and `tests/terratest/*.go` (via the shared `terratest/run.sh`). All tiers are blocking so a red apply-time regression prevents `35-management` and `40-delivery` from running. The earlier `45-e2e` design was merged into `30-test` so smoke and apply-time feedback land in the same stage.
4. **35 - Management** — SBOM generation, dependency tracking
5. **40 - Delivery** — Artifact builds, container images. On GitHub, `delivery > release` (`github/global/stages/40-delivery/release/action.yaml`) cuts the version tag from a bump merge on the commit the run verified — pushed from the job's own checkout at `github.sha`, never through the Releases API, which tags the branch's *current* head — then creates the GitHub Release on it and, with `promote_release`, dispatches the tag run. A tag that already exists on that commit is kept; one on another commit fails the job by name. See README "Release Promotion"
6. **50 - Deployment** — two families with different platform coverage. The infrastructure targets (ARM, Lambda, K8s) remain **Azure DevOps only**; the **MVP hosting providers** (Cloudflare, Vercel, Render, Netlify, Fly.io) are wired on **all three platforms** — see MVP Hosting Providers below

### Directory Layout

- `.github/workflows/` — GitHub Actions reusable workflows (e.g., `go-docker.yaml`, `pdm-docker.yaml`)
- `gitlab/<language>/` — GitLab CI templates with `stages/`, `scripts/`, `abstracts/` subdirs
- `azure-devops/<language>/` — Azure DevOps templates, same structure as GitLab. A delivery or deployment stage whose `condition:` replaces the implicit `succeeded()` carries `not(canceled())` beside `not(failed())`: a cancelled run is not a failed one, so `not(failed())` alone lets a cancelled run deliver
- `global/scripts/tools/` — Platform-agnostic security tools (codeql, gitleaks, semgrep, hadolint, shellcheck, checkov, sonarqube, dependency-track, osv-scanner — the last only an installer, for the dependency-update image scans), and `dependency-updates/`, the Go checker described in Keeping the Pins Current
- `global/scripts/languages/` — Language-specific scripts (golang, java, javascript, php, python, ruby, dart, terraform). Most `run.sh` scripts follow shared conventions, but the Terraform helpers below are documented exceptions: they write reports directly under `build/reports/` and do not rely on the common `cleanup.sh` report-directory pattern.
  - `dart/` — Dart and Flutter runners: `setup`, `format`, `analyze`, `test`, `unused`, `sca`, `build`, `publish`, plus a sourced `common.sh` (not executable — it is sourced, never run). All honour `DART_DRY_RUN=true`, which resolves and records commands without installing or executing anything; that is what makes the whole family testable offline. The report converters beside two of them — `test/lcov-to-cobertura.sh`, `test/lcov-to-markdown.sh`, `test/filter-test-events.sh` and `analyze/analyze-report.sh` — are POSIX sh around awk programs (`*.awk`, loaded with `awk -f` after the shared `common.awk`, so they carry no executable bit), and a Dart job needs no Python. See Dart & Flutter Support below
  - `terraform/terra-test/` — `terraform test` runner over `modules/*/tests/*.tftest.hcl` (emits JUnit + Markdown/JSON/Cobertura coverage under `build/reports/`, plus `terra-coverage-generic.xml` from the Go generator in `terra-test/coverage/`, a soft step that warns and skips when Go is absent). `TERRA_TEST_ROOTS` (space-separated, **empty by default**, e.g. `stacks` as for `VALIDATE_ROOTS`) adds every root module under those directories, at any depth, that owns a `tests/*.tftest.hcl`: read from the environment, which each template sets from its own option (GitHub Actions `terra_test_roots` input, since a called workflow's jobs never see the caller's environment; Azure DevOps `TERRA_TEST_ROOTS` parameter, mapped into the step only when non-empty so a pipeline variable of that name is never shadowed by an empty `env:` entry; GitLab CI a variable of that name, deliberately undeclared on the job because a job-level variable outranks the consumer's top-level one), initialised `-backend=false` and deliberately **without** the modules' `-upgrade` so a root's committed lock file decides its providers, one JUnit per root named after its path, kept out of the module breadth figures. The selection lives in the sourced `roots.sh`, which `test-all` asks too, so the two cannot disagree. A root is **refused**, never run, when a test file `terraform test` would read there (`*.tftest.hcl` beside its `.tf` files as well as in `tests/`) holds a `run` block that resolves to apply — no `command`, or `command = apply` — in a file with no `mock_provider`: a root carries its real provider configuration, and under `-backend=false` a cancelled job would orphan whatever the apply created. `roots.sh`'s `terra_test_root_apply_runs` decides it by tokenizing the files in POSIX `awk` (comments, strings, heredocs and brace depth honoured, so only a `command` at the run block's own top level counts), a `*.tftest.json` is refused as unreadable, and the refusal is written as a JUnit failure so every report agrees with the exit code. Module tests are never checked
  - `terraform/terratest/` — Go Terratest runner over `tests/terratest/*.go` (emits JUnit under `build/reports/`)
  - `terraform/test-all/` — unified orchestrator for the first two tiers; runs both when present (a root under `TERRA_TEST_ROOTS` counts toward tier 1), merges JUnits into `build/reports/junit-terra-all.xml`, exits `0` when neither tier has tests (stack-only repos)
  - `terraform/structural/` — third tier runner for `tests/structural.sh` (repo-convention assertions the consumer owns); emits `build/reports/junit-structural.xml` (empty-but-valid on skip). Runs on its own parallel job (`test:structural`) instead of through `test-all` because the shell tier is offline and light and shouldn't block on the heavier tiers. Every platform's job still provisions Go: a consumer's `tests/structural.sh` runs this repository's Go helpers (`var-catalog/run.sh --check` is the CI gate for a generated `variables-shared.tf`), a call `make test-go-module-toolchain` cannot discover because it sits in the consumer's repository, so that suite lists the runner as a helper entry by hand
  - `terraform/validate/` — fourth tier runner: `terraform init -backend=false` + `terraform validate` over every root module under `VALIDATE_ROOTS` (default `stacks`); emits `build/reports/junit-validate.xml` (empty-but-valid on skip). The only tier that RESOLVES references — the other three parse — so it is the only one that can see `Reference to undeclared module` / `Unsupported argument` in a root module. Runs on its own **opt-in** parallel job (`test:validate`), off by default because unlike its siblings it needs the network for provider downloads and, for private module sources, credentials
  - `terraform/tftest-gen/` — Go generator (`main.go` + `internal/`, run through `go_helper_run`; `make test-gen` in `terraform.mk` calls it) that emits `tests/smoke.tftest.hcl` for single-module repos; parses `variables.tf` + `main.tf` / `providers.tf` and emits `mock_provider` blocks plus validation-rejection runs
  - `terraform/tflint/install.sh` and `terraform/terra/install.sh` — pinned, checksum-verified installers that replaced the vendors' `curl … | sh` one-liners on all three platforms
  - `terraform/order-check/` — checks (and with `--fix` rewrites) the file-ordering standard across `environments/**/root.hcl`, `stacks/*/{variables,providers,outputs}.tf`, and `**/providers.tf`, and additionally reports **dead terragrunt inputs** (an `inputs = {}` key with no matching `variable` in the target stack — reported only, never auto-deleted); emits `build/reports/junit-order-check.xml`. Runs as the `order-check` / `style:order-check` job in the `10-code-check` stage. A standard-library-only Go helper (`main.go` + `internal/`, run through `go_helper_run`, so the job needs Go and nothing else); the `--fix` rewriter is round-trip-safe (parses to exact substrings, then only permutes). See Terraform Ordering Standard below
  - `terraform/var-catalog/` — a standard-library-only Go generator (`main.go` + `internal/`, run through `go_helper_run`) that keeps ONE canonical body per shared `variable` in a per-repo `.terraform-var-catalog.hcl` and writes the subset each stack actually uses into `stacks/<stack>/variables-shared.tf` (the same generic-script/repo-data split as `order-check`). Output is **committed**, not emitted by a Terragrunt `generate` block, because the order-check dead-input scan, the `terraform validate` tier, and AST-based tests all read `stacks/**/*.tf` from the source tree without invoking Terragrunt. It writes a sibling file rather than appending to `variables.tf` (so generated content is exempt from the `// SET ON` marker rule yet still seen by the dead-input glob) and **never overwrites a hand-written declaration** — a stack that already declares a catalogued name keeps its body and is reported. `run.sh --check` is the CI gate (fails if the committed output is stale); `--report` prints changes without writing
- `global/scripts/deploy/` — MVP hosting providers for the `50-deployment` stage: `cloudflare/` (Pages + Workers via `wrangler`), `vercel/`, `render/` (REST API, no CLI exists), `netlify/`, `flyio/`. Each is wired identically on all three platforms; `common.sh` is sourced, not executed, and holds the shared helpers. See MVP Hosting Providers below
- `global/scripts/shared/` — Shared utilities (cleanup.sh, rebase-check.sh, changelog-check.sh, reconcile-releases.sh, terraform-provider-mirror.sh, **go-helper.sh**, venv-distribution.sh, **pinned-versions.sh**, **verify-download.sh**). The last two are sourced, never executed, and are the supply-chain contract: `pinned-versions.sh` is the single source of truth for every third-party binary version and its SHA-256, and `verify-download.sh` is the only sanctioned way to fetch one — see Supply-Chain Pinning below. `terraform-provider-mirror.sh` is sourced by the `terra-test` and `validate` tiers: it points `terraform init` at provider stores this machine already populated (`TF_PROVIDER_MIRROR_DIR`, `TERRA_PROVIDER_CACHE_DIR`, the terra CLI's `~/.cache/terra/providers`, then the tier's own `TF_PLUGIN_CACHE_DIR`) via a `filesystem_mirror`, so a mirrored provider costs no registry query and no github.com checksum fetch. Falls back to the origin registry per directory, so a cold machine still works and pays one fetch per provider version instead of one per directory. `TF_PROVIDER_MIRROR=off` disables it. `venv-distribution.sh` (sourced) answers which version of a distribution a Semgrep or Checkov virtualenv holds, from the METADATA pip wrote rather than by running its interpreter
- `global/containers/` — Docker image definitions for CI environments
- `makefiles/` — Includable `.mk` fragments for downstream projects (`common.mk`, `golang.mk`, `python.mk`, etc.)
- `global/gitignore/` — Canonical ignore rules for the files the pipeline writes into a consumer's working tree, one fragment per language plus `common`. Git has no `include` for ignore files and refuses to follow a symlinked `.gitignore`, so these are GENERATED into a delimited block in the consumer's own `.gitignore` by `make gitignore`, and `make gitignore-check` fails when that block is stale. See Shared Ignore Rules below
- `internal/testsuites/` — Go test support for the suites in `.github/tests/`, never run by a consumer: one `main` package per suite that needs one, plus `yamldoc` (reads YAML into a tree that keeps document order and REFUSES duplicate keys, merge keys, a second document and unknown tags, so a file the platforms would reject fails its check instead of passing it empty; renders values the way the suites' messages always spelled them) and `filetext` (the walk order findings are reported in, lines, whole-line comments)
- `.docs/examples/` — Complete per-platform usage examples
- `.docs/known-issues.md` — Defects consumers observed in the shared workflows and not fixed yet (never security defects: this repository is public); read it before diagnosing a workflow, and record a new one there

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

Not every reusable workflow is a language pipeline. `reusable-claude-review.yaml` (one
automated review per pull request covering correctness, security, and software design in a
single sticky comment; its design and forensics live in `.docs/claude-review.md`) and
`reusable-claude-mention.yaml` (the `@claude` mention responder) are standalone, like `dependency-updates.yaml` and
`update-major-version-tag.yaml` — `claude` is an agent, not a toolchain, so they
are listed in `STANDALONE` in `.github/tests/test-workflow-composition.sh` with
the reason spelled out there. The `reusable-` prefix marks a definition: every
caller, this repository's own included, drops it and is named
`claude-review.yaml` / `claude-mention.yaml`. Consumers pass `CLAUDE_CODE_OAUTH_TOKEN`
explicitly; `secrets: inherit` fails Semgrep's
`yaml.github-actions.security.secrets-inherit` rule.

### Supply-Chain Pinning

**Enforced by `.github/tests/test-supply-chain.sh` (`make test-supply-chain`), 29 assertions, every one of
them proven to fire against a deliberate violation.** Read this before adding an action, an image, or
anything that downloads a binary.

| What | Pinned to | Enforced by |
|------|-----------|-------------|
| Third-party GitHub Actions | 40-character commit SHA + trailing `# vX.Y.Z` comment | assertions 1-4 |
| Container images (`image:` -- a scalar, or the `name:` of a mapping -- and `FROM`) | `tag@sha256:<digest>` | assertions 5-7 |
| Downloaded binaries | exact version **and** a committed SHA-256 | assertions 9-16 |
| `go install` / `pip` / `gem` / `npx` | exact version | assertions 17-20 |

`global/scripts/shared/pinned-versions.sh` holds every version and digest; `verify-download.sh` is the
only sanctioned way to fetch a binary, and it DELETES an artifact whose checksum does not match rather
than merely reporting it — a later step that only tests for existence would otherwise install the thing
just rejected. Every `download_verified` call is handed a digest its own script resolved through
`pinned_digest` (assertion 16): `SKIP` or a digest typed into an installer would pass through the
verifier and verify nothing this repository decided. The Dart and Flutter SDKs are the one named
exception, because their version is the consumer's to choose.

Five constraints shape this family; do not "simplify" any of them away:

| Constraint | Why |
|------------|-----|
| **A pinned version and its digest move together** | A committed digest describes ONE build. `pinned_digest` compares `<TOOL>_VERSION` against `<TOOL>_PINNED_VERSION` and refuses to reuse the digest when they differ — verifying new bytes against an old digest fails every time and reads like an attack. An override without `<TOOL>_SHA256_OVERRIDE` warns loudly and skips verification rather than failing the job, because responding to an upstream CVE must not require a release here |
| **Same-repository references declare whether they move** | `rios0rios0/pipelines/...@main` deliberately follows the latest first-party implementation. When an executable chain must follow a consumer's pinned workflow SHA, use GitHub's `$/path/to/action` self-repository syntax instead: runner 2.336.0+ resolves it from the exact repository and commit of the running workflow or composite, without a circular hard-coded SHA. It is a GitHub.com feature and is unavailable on GitHub Enterprise Server. The Yarn Semgrep workflow and its scripts checkout use this exact-commit form; `test-workflow-composition.sh` Test 7 and the supply-chain test hold both edges. |
| **The `scripts-repo` abstracts must honour an explicit ref** | They cloned the default branch with no ref, so a consumer pinning `@4.23.0` got the workflow from the tag and every SCRIPT from `main`. Pinning the entry point while the payload floats is worse than not pinning: it reads as covered. GitHub follows `github.action_ref` — including the exact SHA supplied by a `$/` self-reference; GitLab and Azure take `PIPELINES_REF`. All three use `git init` + `git fetch <ref>`, NOT `git clone --branch`, because `--branch` rejects a raw commit SHA — the only genuinely immutable form |
| **The tools no longer self-update** | Several installers re-resolved `releases/latest` on every run of a persistent agent, justified as staying current for CVE fixes. It also meant a linter or scanner's verdict on unchanged code could change overnight, and the earlier verdict could not be reproduced. An exact version is idempotent, so those branches were deleted rather than rewritten |
| **The test strips comments before matching** | This repository documents the patterns it forbids at length, so a check that bans `npx --yes knip` is otherwise failed by the comment explaining why. `drop_comments` handles it; `yaml_files` must pass `"$@"` through to `find`, because a swallowed `-print0` made three assertions pass without examining a single file |

Two consumer-facing consequences worth knowing: the examples under `.docs/examples/` are pinned to a
release tag on all three platforms (an example that tracks a branch teaches every consumer the exposure),
and Azure DevOps resolves the repository's DEFAULT BRANCH when a `resources.repositories` entry gives no
`ref:` — which is why every Azure example now sets one.

### Keeping the Pins Current

Pinning is only half a policy. A pin stops a dependency moving without a
decision; it does not tell anyone when to make one, and a pin never announces
that it is three CVEs behind. `global/scripts/tools/dependency-updates/` is the
other half, and `.github/workflows/dependency-updates.yaml` runs it **twice a
week** (Mon/Thu 06:00 UTC) and **opens a pull request** that moves every stale
pin — one branch, `chore/dependency-updates`, regenerated from the default branch
on every run. It merges nothing; a person reads the diff and decides. It is **Go**
(`internal/domain` for the policy, `internal/infrastructure` for the network,
files and git, `internal/cli` for the command line), built from the checkout by
`run.sh` through `global/scripts/shared/go-helper.sh`; the Python it replaced is
gone. `dependency-updates-verify.yaml` then proves any pull request that moves a
pin, from its diff — see Verifying a Dependency Pull Request below.

| Surface | Question asked | Discovered from | `--apply` writes |
|---------|----------------|-----------------|------------------|
| Actions | is there a newer release for `owner/repo`? | `uses: '…@<sha>' # vX.Y.Z` in every YAML | the commit the new tag points at (annotated tags dereferenced) and its comment |
| Images | does the pinned tag still resolve to this digest? | `image:` -- a scalar, the `name:` of a block mapping, a flow mapping, each also a list item -- and Dockerfile `FROM` | the digest the tag resolves to now, at every copy of the reference, once a scan shows the rebuild introduces no known vulnerability |
| Binaries / packages | is there a newer version upstream? | `# upstream:` annotations in `pinned-versions.sh` | the version, and every `*_SHA256*` from the new release's assets |
| Vendored files | is there a newer upstream release of a copied file? | `# vendored:` annotations (the golden golangci-lint config) | the file re-merged three-way onto this repository's adjustments, and its base digest |
| Inline copies | do the two copies of a value still agree? | `InlineCopies` in `internal/domain/entities/scanning.go` (versions AND digests, YAML and Dockerfiles) | the value its manifest variable now holds |
| Go toolchain | is there a newer patch of the pinned Go line, and is the one in use vulnerable? | `# upstream: go-toolchain` pins, one per release line, and their copies (`internal/domain/entities/toolchain.go`): `go-version:`, the `GoTool@0` `version:`, `golang:<release>[-<variant>]` images | the pin; every input; every image moved to the new release's tag at the digest it resolves to, scanned against the old image |
| Image tags a pin names | is there a newer release of an image whose tag names one exact build? | `# image: <repository>` pins in `pinned-versions.sh` (the SonarQube scanner's, Node.js's), every image of that repository on the pin's `track=` line (`internal/domain/entities/followers.go`), and Node's Azure DevOps `UseNode@1` inputs as inline copies | the pin; every copy moved to the new release's tag, its variant kept, at the digest it resolves to, scanned against the old image |

Twenty-two decisions shape it; do not "simplify" any of them away:

| Decision | Why |
|----------|-----|
| **Images are checked by DIGEST, not by tag** | `python:3.13-slim` is rebuilt with patched system packages under the SAME tag, so "is there a newer tag" misses every security rebuild. "Does this tag still resolve to the bytes we pinned" catches all of them. Moving `3.13` → `3.14` is a decision, not an update, so no newest-tag search is attempted -- unless a pin's `# image:` hands the tag to a release (next row but one) |
| **An image is read in every form the supply-chain suite pins** | `test-supply-chain.sh` holds an `image:` given as a mapping to a digest, and GitLab CI writes one whenever the image carries more than its name -- the `.yarn` abstract's `docker: user:`, the `.sonarqube` abstract's `entrypoint:`. Reading only the scalar form left the `.yarn` Node image, which has no other copy, maintained by nothing: never re-pinned, and invisible to the verification, which passed a pull request re-pinning it to a rebuild with a critical CVE as one that moves no pin. One reference is one update however many copies hold it: the SonarQube scanner is written seven times, in three forms, and moves in one |
| **An image whose tag names one exact build follows a pin** | SonarSource publishes each scanner release as one tag (`12.1.0.3233_8.0.1`) and never rebuilds it, so "does the tag still resolve to the pinned digest" can never fire: the scanner sat on 12.1 while 12.2 and 12.3 shipped, reported by nothing. A pin annotated `# image: sonarsource/sonar-scanner-cli` makes the release decide the tag -- resolved from the GitHub releases of the image's own repository, which carry exactly those tags and the dates the cooldown reads -- and every image of that repository follows it the way a `golang:` image follows its Go pin: retagged at the digest the new tag resolves to, scanned against the image it replaces, refused to a person when the tag is not published, and drift when tagged anything else. A tag the publisher deletes still fails its lookup and with it the run (exit 2, no pull request) until the pin is moved by hand. Node.js is the second: `node:24.22.1-trixie` stops being rebuilt the day 24.22.2 ships, which is how `.npm` sat on Node 16.14.0. Its pin is held with `track=24`, so it takes only the images of that line and keeps each tag's variant (`-trixie`), while a rolling tag of another line (the deployment templates' `node:22-alpine`) stays with the digest check and an exact tag of a line no pin holds is drift. Its advisories come from OSV's `Bitnami` ecosystem, the one that indexes the Node.js runtime itself |
| **A failed lookup exits 2 and is never "up to date"** | ~40 of the lookups hit `api.github.com`, which allows 60 requests/hour unauthenticated. Treating a 403 as "current" would turn the whole check into a green light that inspected nothing — worse than not running it. After one, the pull request is left exactly as it was: a partial result is not a smaller set of updates. A gateway error (500/502/503/504) or a dropped connection is asked twice more first, 2s and then 4s later, so a blip is not an outage; a rate limit, an untrusted certificate and a refused redirect never are |
| **A pin with no `# upstream:` annotation FAILS** | Otherwise coverage shrinks one forgotten annotation at a time while the job stays green. The annotation lives next to the pin so adding one without the other is visible in review. A `*_SHA256*` with no `# asset:` fails the same way, because nothing could ever bump its pin |
| **`track=<line>` exists for deliberately-held pins** | GoReleaser is on 1.x because 2.x is a breaking config change. Without it the check would report that migration as an update on every run, forever, until somebody muted the job. A line is a major (`track=1`) or a minor line (`track=1.27`): Go is held to its minor line, because moving every consumer's builds to a new Go is a decision, while its patches are where its security fixes ship |
| **Go is a pin, and every copy of Go follows the pin of its line** | The checker never moved Go itself, so a Go security release left GitLab's and Azure DevOps' Go templates, the Terra workflows and two Dockerfiles on a `1.27.1` with 13 standard-library and 2 `go` command advisories, unreported. A `go-toolchain` pin is resolved from the module proxy that serves GOTOOLCHAIN (`golang.org/toolchain`, its `.info` dating each release for the cooldown) and checked like any pin, so a vulnerable Go is forced out. A copy -- `go-version:`, `GoTool@0`, a `golang:<release>` image -- follows the pin whose major.minor it shares; an image moves to the new release's tag at the digest it resolves to, after the same scan as a rebuild, and a variant not published for that release is handed to a person rather than guessed. A copy no pin holds the line of is drift, so coverage cannot shrink by a new line slipping in. A repository with no Go pin -- every consumer -- has none of its Go judged |
| **A pin may name several advisory packages** | The Go vulnerability database files the standard library's issues under `stdlib` and the `go` command's under `toolchain`: `1.27.1` carried GO-2026-6601/6602 in the second, which a lookup of `stdlib` alone would have called clean. `# osv: Go stdlib toolchain` asks about both, and an issue filed under both counts once |
| **It opens a pull request; it never merges one** | It used to fail the build instead, because an automated bump has to re-resolve a SHA, a checksum and a digest before it is even correct. The pull request is the answer to that, not a way round it: every value is resolved from the release, and nothing reaches the default branch unread. The red list sat on every run for weeks, which is how a gate stops being read |
| **A digest comes from the asset, never from the old one** | Each `*_SHA256*` carries an `# asset:` URL template (`{version}` = the pin), and a pin may name its publisher's `# checksums:` manifest. The new digest is GitHub's recorded SHA-256 of the release asset (or the downloaded bytes, for releases older than GitHub's digests), and must match the manifest. BEFORE that, the template must reproduce the committed digest of the CURRENT version — the only proof it names the file the installer verifies. `run.sh --verify-assets` checks every template after an edit |
| **Anything unsafe is refused, never half-applied** | A missing annotation, a template that fails that proof, an asset the new release renamed, a checksum disagreement, or an upstream name with a quote or `$` in it (it would be written into a file every installer SOURCES): the pin stays exactly as it was, the rest of the run still lands, the pull request lists it under "needs a person", and the job goes red. The same holds for a pin one of whose images cannot move -- no tag published for the new release, a scan finding the new image introduces, a failed lookup: the pin, its inline copies and its images all stay, since a pin written without an image of it leaves a copy behind, which the pull request's own verification fails, holding every other update back with it. Upstream values shown because they were refused are made inert before reaching Markdown |
| **Releases compare within one release line** | `github/codeql-action` tags the action `v4.x` and the CodeQL bundle `codeql-bundle-v2.x`, and marks whichever shipped last as latest — so the action read as current at v4.37.7 while v4.38.3 was out. `tag_family` keeps the two lines apart, in the resolvers and again in `resolve()` |
| **A rerun is byte-identical** | The changelog fragment is named and dated from the base commit, not the clock. The default branch's rules dismiss approvals on every push, so a rerun that differed would cost the reviewer their approval twice a week for nothing |
| **A decline and a hand-made commit are respected** | `run.sh guard` refuses to regenerate the branch when a pull request with the same fingerprint (an HTML comment in the body, a trailer in the commit) was closed unmerged, or when the branch holds a non-merge commit without that trailer. Closing the pull request therefore means "not this set"; `.dependency-updates.json` means "never" |
| **Callers must grant `contents: write` + `pull-requests: write`** | GitHub checks a called workflow's job permissions against the caller's grant before any job starts, regardless of `if:` — so a caller granting `contents: read` alone gets a log-less startup failure, `report_only` or not. A run on a pull request event falls back to the old gate (fail on stale) rather than opening a second pull request |
| **A release that INTRODUCES an advisory is never proposed** | Every candidate release, and the version in use, is checked against OSV.dev (GitHub reviewed + malware advisories, OpenSSF malicious packages, Go vulndb, PyPA, RubySec). A candidate carrying an advisory the pin does not already have is skipped for the newest older one that does not — one bad release must not block every safe update behind it. A known malicious release (`MAL-*`, a GHSA aliasing one, or CWE-506) is never proposed and can never be accepted. This library's pins run in every consumer, so a known-vulnerable bump is a supply-chain incident for all of them at once |
| **A known vulnerability in a pin in use is FORCED out** | The fixing release is proposed at once with the cooldown waived (the OLDEST unaged fix when no aged one exists — it has had the longest to be scrutinised), the pull request is titled `fix(deps)` with a `Security` changelog entry, and the job stays RED until it is merged. "No release fixes it yet" stays red too, until one does or the advisory is accepted. Waiting a week on a published fix is the wrong trade |
| **Everything else waits out a cooldown (7 days)** | No advisory database knows about a release hijacked an hour ago; most 2024–2025 compromises were found and pulled within days, and a week is the figure that analysis recommends. The newest release past the cooldown is proposed, so a project that releases daily is still updated. A pin's `cooldown=<n>`, a label in `cooldown.exempt`, or `cooldown.days` in `.dependency-updates.json` changes it; an npm range pin (`wrangler`) has none, because npm resolves it at run time |
| **GitHub Actions advisories are evaluated HERE** | OSV publishes actions advisories as ranges but does not order action versions: asked about the compromised `tj-actions/changed-files@v45.0.7` by version, it answers "no vulnerabilities". The ranges are evaluated locally — honouring GHSA's `last_known_affected_version_range`, without which `GHSA-vqf5-2xx6-9wfm`'s open v2 range flagged `github/codeql-action@v4.38.3`. The evaluator was cross-checked against GitHub's own advisory API for every action pinned here, with zero mismatches |
| **A binary names its advisory source, or says `none`** | `# osv: <ecosystem> <package>` (e.g. `Go github.com/gruntwork-io/terragrunt`, `Hackage ShellCheck`, `Maven com.guardsquare:proguard-base`) or `# osv: none`; a pin with neither FAILS as untracked. Silence would read as "no known vulnerabilities" forever. pypi/npm/rubygems/goproxy pins are packages already |
| **An acceptance expires and gives a reason** | `vulnerabilities.accept` in `.dependency-updates.json` needs an `id`, a `reason` and an `until` date; one missing any of them is ignored with a warning, an expired one stops applying, and none ever covers a malicious package. A file that cannot be read applies NOTHING — the safe direction for every field |
| **A vendored file is re-merged, never replaced** | The golden golangci-lint config carries local adjustments. A bump downloads upstream at the pinned version, PROVES it is the file the copy came from (its SHA-256 is the pin's digest), and `git merge-file`s upstream's change onto the copy; a conflict refuses the bump. `ceiling=GOLANGCI_LINT` holds it at or below the binary — a config naming a linter the binary lacks fails every consumer's lint — and a release starting to declare a custom linter PLUGIN (code running in every consumer's lint job) is refused. The pull request lists every linter switched on or off |

`.dependency-updates.json` (`{"ignore": ["glob", …]}`) silences a reference. It
is empty by default and is meant for genuinely ROLLING tags such as
`alpine:edge`, which is rebuilt almost daily — a check that is always red stops
being read — and for a dependency somebody has decided never to move.

**The job needs a token, in practice.** `GITHUB_TOKEN` can never change a file
under `.github/workflows/` — GitHub offers no `workflows` permission for it, by
design — and almost every update set here bumps an action in one; it can also
open a pull request only when Settings → Actions → General → "Allow GitHub
Actions to create and approve pull requests" is on, and that pull request starts
no workflows, so a ruleset requiring CodeQL results blocks it until someone
closes and reopens it. So `dependency_updates_token` (repository secret
`DEPENDENCY_UPDATES_TOKEN` here) is a **fine-grained personal access token** on
the repository with Contents, Pull requests and Workflows read and write
(classic: `repo` + `workflow`). Two costs come with it and neither is a bug:
`sign-commits` signs only for a bot's token, so its commits are unsigned
(`required_signatures` needs a bypass), and its owner cannot approve the pull
request it opens. A GitHub App would avoid both, but an App token expires within
the hour and would have to be minted on every run from the App's ID and private
key (`actions/create-github-app-token`) — a step the workflow does not have, so
an App token stored in that secret stops working an hour after it is created.
The first run that hits either `GITHUB_TOKEN` limit fails with a message naming
the fix.

### Verifying a Dependency Pull Request

`.github/workflows/dependency-updates-verify.yaml` (`run.sh verify --base-dir
<base> --repo-dir <head>`) is the gate on the pull request itself, and it does
NOT trust the generator: it reads the DIFF between the pull request's base and
head checkouts and re-proves every pin that moved, so it covers the scheduled
pull request, a commit pushed onto it, and a hand-written bump alike. Make
`security > verify:dependency-updates` a required check.

| Check | Fails when |
|-------|-----------|
| advisories | the new version has an advisory the old one did not, or is known malicious (a WARN, not a failure, when it still has one the old version had too — the scheduled run forces that fix) |
| cooldown | the release is younger than the cooldown and fixes no known vulnerability of the version it replaces |
| integrity | a committed digest is not upstream's asset (re-derived from the `# asset:` template at the NEW version) or disagrees with the `# checksums:` manifest |
| provenance | an action's SHA is not the commit its `# vX.Y.Z` comment's tag names |
| history | the new action commit does not descend from the old pin (GitHub's compare view: `ahead`/`identical` only) |
| vendored | the vendored file is not EXACTLY `merge(base file, upstream@old, upstream@new)` — a bump must not smuggle other edits |
| registry | an image digest is not a manifest of the repository it is pinned under |
| scan | the re-pinned image carries a known vulnerability, or a malicious package, that the image it replaces did not (OSV-Scanner over both, see below) |
| bounds | a pin leaves its `track=` line, its `ceiling=`, or its release line |
| copies | a moved `golang:` image's tag names another release than its Go pin, or an image's tag names another release than its `# image:` pin holds; and, on every pull request, any copy the head leaves out of step with its pin that the base had in step -- read from the files alone, so it asks the network nothing |

Five constraints shape it:

| Constraint | Why |
|------------|-----|
| **No `paths:` filter, and no network when no pin moved** | A required check gated by paths never reports on a pull request outside them, which blocks that pull request forever. So it runs on every pull request, and one that moves no pin passes in seconds having asked NOTHING -- no advisory lookup, no scanner download: a check required everywhere that consulted OSV.dev regardless would block every pull request in the repository while the database is down. `test-dependency-updates.sh` holds it by running a live verification with every connection refused |
| **A check that cannot complete is ERROR, exit 2, and fails** | An unproven change is not a passing one — the same fail-safe direction as the scheduler's lookups |
| **The comment is posted only when a pin moved** | Every other pull request stays free of it; `changes.txt` in the report directory carries the count |
| **An image rebuild is scanned against the image it replaces** | A same-tag rebuild is USUALLY a distribution security refresh, but "usually" is not a proof: a rebuild can also pull in a newer package with a published CVE. Both digests are exported straight from the registry API into a `docker save` archive — no Docker daemon, every blob's SHA-256 and size checked against the manifest that names it — and scanned by OSV-Scanner (OS packages plus the artifacts the image ships, e.g. a Go binary's module list). Only the DIFFERENCE gates: a rebuild of a Debian image always carries hundreds of open CVEs, and failing on those would fail every rebuild, including one like `python:3.10-pdm-bookworm`'s on 2026-10-10, which fixed 155. `--apply` refuses a rebuild that introduces one, exactly as it refuses a vulnerable release. Measured: the export reproduces a `docker pull` scan finding for finding (81 = 81), and verifying a five-pin pull request, both images of all four rebuilds, took 32s. An image with no `linux/amd64` build, or with foreign (Windows) layers, is a WARN reading "not scanned: …", never a PASS |
| **OSV-Scanner, not Snyk** | Snyk needs an account token, and GitHub gives a pull request from a fork no secrets, so the gate could not scan the pull requests most worth scanning; its free tier is metered too (third-party pricing summaries put it at 100 container tests a month, October 2026), and a gate that has run out of quota goes red for a reason unrelated to the change. OSV-Scanner needs no account, is pinned and checksum-verified like every tool here (`global/scripts/tools/osv-scanner/install.sh`, run by the command the first time an image actually needs scanning, reused only when the installed file's SHA-256 is the committed one, and run by that exact path rather than whatever is first on `PATH`; an explicit `--osv-scanner` brings its own and installs nothing), and reads the OSV.dev database the pins are judged by, so an image verdict and a pin verdict never disagree about what is known |

### Caches on a Self-Hosted Runner

**Enforced by `.github/tests/test-runner-cache-gating.sh` (`make test-runner-cache-gating`).** Read this
before adding an `actions/cache` step or an `actions/setup-*` that takes a `cache:` input.

GitHub's cache service is designed for a runner that starts empty. A self-hosted runner does not:
`$HOME` survives every job on that host, so a restore into `~/…` untars an archive over files that are
already there. That is not a redundant copy, it is a **failed** one — `tar` exits 2, the action logs
`Failed to restore`, and the whole download is discarded after it has been paid for. Two shapes of the
same defect were observed, and the differing errno is why they read like unrelated bugs:

| Language | What `tar` says | Why |
|----------|-----------------|-----|
| Go | `Cannot open: File exists` | `GOMODCACHE` is deliberately read-only, so `tar` cannot replace it |
| Dart | `Cannot mkdir: Permission denied` | the unpacked SDK directory is already present and not writable |

Measured on a 12-vCPU self-hosted runner, one workflow run each:

| Language | Archive | Restore, per job | Post-job save, per job |
|----------|---------|------------------|------------------------|
| Go | 263–286 MB | 47–68s (1s when it MISSES) | 33–78s |
| Dart | **1.67 GB** | **214–358s** | 87–102s |

On Dart's `style:format` that is 314s of cache around 17.6s of work, and roughly 31 minutes of runner
time per pipeline run. **Nothing reports any of it**: every file is valid YAML, every job stays green,
and the only symptom is a pipeline that is slow for no stated reason.

Four constraints shape this; do not "simplify" any of them away:

| Constraint | Why |
|------------|-----|
| **`!= 'self-hosted'`, never `== 'github-hosted'`** | A context that resolves to neither — an empty string on an older runner, a future third value — must keep the cache ON for hosted consumers rather than silently disabling it for everyone. The test rejects the inverted form |
| **A cache that WORKS on self-hosted is still not necessarily worth it** | The one Dart job whose restore succeeded still paid 308s, while a cold `dart_ensure_sdk` in the same run installed the same SDK from Google's archive in 126s. A cache slower than the download it replaces is not a cache — which is what makes skipping it right on a cold self-hosted host as well as on a warm one |
| **`actions/setup-node` and `actions/setup-java` are deliberately left ON** | Their caches target `$HOME` too, but their files are writable, so the restore SUCCEEDS — ~9s for a 58 MB `yarn` cache across ten jobs of two runs, no failure and no post-job save. That is a genuine cache seeding a cold host, and turning it off would be a change with no measurement behind it. If one is ever observed failing, it belongs under the rule |
| **The gate is written even where `runs-on` is hard-coded to a hosted runner** | `terra.yaml` and this repository's `ci.yaml` pin `ubuntu-latest`, so the expression is provably a no-op there. Writing it anyway is what lets the rule have no exemption list — and `terra.yaml` is a reusable workflow, so the day it gains the `runs_on` input that `go.yaml`, `yarn.yaml` and `dart.yaml` already have, the gate is already correct |

Two `actions/cache` steps are outside the rule by their **path** rather than by exemption, and the rule
is written so that stays true without a list: `golang/stages/30-tests/all` caches `${{ env.GO_BIN_DIR }}`
(7 MB of test-tool binaries, writable, saves a `go install` chain every run), and
`java/stages/20-security/dependency-check` caches `.owasp` — inside the workspace, which every platform
wipes per job, and load-bearing because rebuilding the NVD database costs hours.

**This is a GitHub-only defect and needs no cross-platform equivalent.** GitLab CI and Azure DevOps both
keep their caches inside the per-job workspace (`$CI_PROJECT_DIR`, `$(Pipeline.Workspace)`), so neither
can restore over a directory a previous job left behind.

One practical note for anyone auditing this by hand: `github/terra/terra.yaml` is a **symlink** into
`.github/workflows/`, and `grep -r` does not follow one. Three ungated call sites hid behind that, which
is a large part of why the rule is a test rather than a review habit.

### Workflow Composition Standard

**Enforced by `.github/tests/test-workflow-composition.sh` (`make test-workflow-composition`), nineteen
assertions, every one of them proven to fire against a deliberate violation.** Read this section
before writing anything under `.github/workflows/`, and before writing a pipeline in a repository
that consumes this one.

A workflow file name is `<toolchain>[-<suffix>].yaml`, and the suffix names **what the file adds**
to the base of the same toolchain:

| Shape                        | Adds                                              | Example              |
|------------------------------|---------------------------------------------------|----------------------|
| `<toolchain>.yaml`           | stages 10–35: code check, security, tests, SBOM   | `go.yaml`            |
| `<toolchain>-docker.yaml`    | fourth stage — release + container image          | `go-docker.yaml`     |
| `<toolchain>-library.yaml`   | fourth stage — package published to a registry    | `npm-library.yaml`   |
| `<toolchain>-binary.yaml`    | fourth stage — compiled artifacts                 | `go-binary.yaml`     |
| `<toolchain>-<provider>.yaml`| **fifth stage — deployment to that provider**     | `go-render.yaml`     |

A deployment suffix must name a directory that exists under
`github/global/stages/50-deployment/` — `cloudflare`, `vercel`, `render`, `netlify`, `flyio`. That
is what stops a plausible-looking `go-heroku.yaml` from being added for a provider nothing
implements.

**Compose, never re-declare.** A composed workflow `uses:` the sibling it builds on and adds jobs;
it does not copy its jobs. `go-render.yaml` calls `go-docker.yaml`, which calls `go.yaml` — three
files, each adding one stage, none repeating another. Copying instead of calling drifts one input at
a time, and every drift reads to the next person like a deliberate difference.

**Internal GitHub actions have two explicit revision policies.** `@main` is the intentionally moving
default for first-party stages. `$/path/to/action` resolves the action at the exact commit of the running
workflow or composite and is required when a consumer's pinned entry point promises an immutable
execution chain. The latter requires GitHub Actions runner 2.336.0 or newer and is unavailable on GitHub
Enterprise Server. Do not replace `$/` with `@main` in the Yarn Semgrep chain: doing so lets an unchanged
consumer SHA execute different scanner wiring or scripts on a rerun.

**A deploy is a job with `needs:`, never a second workflow.** This is the rule the whole standard
exists for. The shape a consumer reaches for instead is:

```yaml
# NEVER DO THIS
on:
  workflow_run:
    workflows: [ 'CI/CD Pipeline' ]   # matched by DISPLAY NAME
    types: [ 'completed' ]
```

`workflow_run` couples two files by the *display name* of the other one, and naming a workflow that
does not exist **is not an error** — it simply never fires. A consumer renamed its CI workflow while
adopting this library and went four days without deploying, with every pipeline green the whole
time, because nothing anywhere reports "the workflow you are waiting on has no such name". A
`needs:` edge is structural: it cannot drift, and a deploy that does not run is a visible skipped
job rather than silence.

Every deployment job therefore declares, and the test asserts, all four of:

- **`needs:`** — the edge that replaces `workflow_run`.
- **`environment:`** — what scopes the credentials, so a run not entitled to `production` cannot
  read its secrets and `production` can refuse every ref that is not a tag.
- **`if:`** — without one, a pull request deploys.
- a preceding **`# fifth stage`** comment, matching the `# fourth stage` comments the delivery jobs
  already carry.

**A deployment handed a delivered image may pull it.** `go-flyio.yaml` deploys the image `delivery >
docker` pushed to GHCR, pulled with the deployment job's own `GITHUB_TOKEN`, and a job that declares
`permissions:` holds `none` for every scope it leaves out -- so without `packages: read` a private
image is refused at deploy time, after every check passed, as what reads like a bad token. Test 17
holds it over every workflow: a job handed a `needs.<job>.outputs.image` that declares
`permissions:` must grant `packages`. It asks a caller for nothing new: the delivery job pushes with
`github.token`, which takes `packages: write`, and the deployment `needs:` that job.

**A gate that calls a status function must also refuse a cancelled run.** Delivery and deployment
jobs gate on `!failure()` instead of the implicit `success()` so that an upstream job skipped by
design — `delivery-release` on a non-bump commit, every base job on a tag — does not skip them too.
But a cancelled job is not a failed one, and an `if:` that calls any status function gets no
implicit `success()`, so `!failure() && (…)` is still true when `cancel-in-progress` supersedes the
run: the checks are cancelled and delivery starts anyway. medhub-life/backend run 36349435394
published an image of a commit whose lint, tests and SAST had all been cancelled, keeping a runner
slot busy for ~23 minutes. Write `!cancelled() && !failure() && (…)`, with any input guard such as
`inputs.build_web &&` in front, and give every `||` clause a `!cancelled()` or `success()` of its
own, as the release gates' `(!cancelled() && startsWith(github.ref, 'refs/tags/'))` does. The
fifteenth assertion holds it clause by clause.

**Every stage waits for the whole stage before it.** GitHub Actions has no stages: a job starts as
soon as the jobs it `needs:` are done, so a stage exists only as edges. Each `security >` job needs
EVERY `code-check >` job -- `basic-checks` and the opt-in ones (`openapi-sync`, `cross-compile`)
included -- each `tests >` job every `security >` job, the `management >` job every `tests >` job,
and a `delivery >` or `deployment >` job the whole pipeline it ships (the base workflow it calls).
Before this rule the Go security stage waited for golangci-lint alone, the Terraform one for
`terra-format` alone, and none waited for the changelog gate; a consumer with extra jobs of its own
started 10 to 19 of them at once. The companion rule is what makes the barrier safe: `basic-checks`
runs on pull requests only, an opt-in check only when asked for, and GitHub skips every job of a
dependency chain from a skipped one onwards unless its `if:` calls a status function, so every job
past the first stage gates on `!cancelled() && !failure() && (…)` -- without it, every push to
`main` would skip SAST, tests and delivery, green. A skip further down may propagate on purpose (a
job that runs only after a release was cut). The eighteenth assertion holds both halves.

**A consumer's extra test run goes in the tests stage, through an input.** A caller's job can only
`needs:` a reusable workflow as a whole, delivery included, so a test job declared beside the call
starts at the very beginning and delivery never waits for it -- which is how Windows tests, race
tests and script suites ended up running beside `code-check` in four consumers. `go.yaml` therefore
runs `extra_test_command` as `tests > test:<extra_test_name>` on `extra_test_runs_on` (falling back
to `runs_on`), and every Go workflow composed on it forwards the three inputs. One slot is all any
consumer needed; GitLab CI and Azure DevOps need none, since a consumer adds a job to the stage there.

**Job names are an API, not a label.** `delivery > <target>` and `deployment > <provider>` are the
strings consumers pass to `require-checks`, because GitHub composes a check's name from the calling
job and the called workflow's job. Renaming a job renames a check for everyone downstream.

**On a branch, `require-checks` trusts `needs`; on a tag, it reads check runs.** Every deployment
workflow hands the gate `toJSON(needs)`. On a branch run verifying its own commit, the jobs named
there ran that very run's checks, so each must have finished `success` and no check run is read. A
check run is a second record of a job, written separately: during a GitHub Actions incident one
stayed `in_progress` for almost an hour after its job had finished, and the gate refused a deploy
whose every check had passed. A reusable workflow reports `success` when some of its jobs were
skipped and the rest passed, and `cancelled` when one was cancelled; both were read off public runs
that print `toJSON(needs)`. So on a tag, where the checks are skipped and delivery still runs, that
`success` proves nothing, and the tag reads the check runs the default-branch push left.
`make test-deploy-providers` holds both halves, and discovers the wiring in every workflow that runs
the gate.

**A `STANDALONE` workflow is exempt from the composition rules, not from every rule.** The two Claude
reusables are listed there, so the naming, delegation and suffix assertions skip them by design —
which left their wiring asserted by nothing at all. The last three assertions cover what that exemption
leaves behind, and all read the PARSED document rather than the indented text: an input declared three
mappings under `on:` (a key a YAML 1.1 reader does not even spell `on`, resolving it to the boolean
`true`), or an `if:` or prompt spread over a block scalar, is out of reach of any indentation rule.
Those three, and every assertion after them, run in the suite's Go command
`internal/testsuites/workflowcomposition`, which reads YAML 1.2 as GitHub Actions does. The suite
builds it from the checkout before its first assertion and stops by name when the build fails, so it
needs a Go toolchain and no Python.

The tenth is the **`runs_on` contract**, and it has two halves because either alone is defeatable. The
contract half runs over *every* workflow declaring the input — 19 today, not just the Claude pair,
since `go.yaml`, `yarn.yaml`, `npm.yaml` and `dart.yaml` declare the byte-identical shape: optional,
defaulting to `'["ubuntu-latest"]'`, and reaching every job — resolved from a **declared input** for a
normal job, or forwarded in `with:` for a job that `uses:` another workflow, where GitHub rejects the
`runs-on` key outright. The declaration half keeps a `reusable-claude-*.yaml` glob, because generalising
alone would invert the assertion: a workflow that *drops* the input stops being iterated and would pass
by not being looked at.

Two edges of that rule are worth stating, because the obvious stricter version of each is wrong. The
runner must be **caller-selectable**, not literally `inputs.runs_on`: `runs_on` carries one value for
the whole workflow, so a job on another platform cannot share it, and `flutter-artifacts.yaml` documents
exactly such a job (an `ipa` build needing macOS) — it must take a second input rather than a pinned
runner, which is what the check enforces. And the forward is demanded only when the **callee** declares
`runs_on`: a `with:` key the callee does not declare is rejected by GitHub outright, so demanding it
unconditionally would be a trap the first time one of these calls something like
`update-major-version-tag.yaml`.

That callee lookup has a **converse**, and it is the rule that catches the most consequential shape:
a *reusable* workflow whose job calls one that takes `runs_on` must declare and forward it. Without it
the inversion returns one level up — a composed workflow that drops the input stops being iterated and
passes by not being looked at, while its consumers cannot reach another runner at all, for the composed
pipeline *or* its own delivery jobs. `yarn-docker.yaml` and `yarn-library.yaml` were exactly that: their
npm twins with the input deleted, hardcoded to `ubuntu-latest`, green the whole time. A **leaf** caller
is deliberately not asked, since taking the default is what a caller is for. And because the runner rule
accepts any declared input, a workflow declaring `runs_on` must have at least one job resolve from or
forward *it* — otherwise a consumer sets an input that GitHub accepts and nobody reads.

A job may also take a selector of its **own** that falls back to the pipeline's:
`runs-on: ${{ fromJSON(inputs.codeql_runs_on || inputs.runs_on) }}` is how `go.yaml`, `npm.yaml` and
`yarn.yaml` let a consumer send CodeQL alone to a dedicated runner. CodeQL sizes its RAM and threads
from the whole machine, so two analyses on one shared self-hosted host exhaust its memory, and the
kernel's OOM kill surfaces as "The runner has received a shutdown signal". The chain parses as a
declared-input selector, but a fallback reads correctly and still fails silently three ways, and the
check reports each: a link after `runs_on` is never read, because `runs_on` always has a value; a link
that is required or has a non-empty default never lets the job fall through, so the consumer's
`runs_on` is ignored for that job; and a composed workflow that does not declare and forward its base's
`<purpose>_runs_on` strands its consumers on `runs_on` — a drop that looks exactly like the default.
Every runner-selecting input follows the same name, `runs_on` or `<purpose>_runs_on`, which is what
lets the forward be demanded without the test listing the purposes.

The eleventh is the **mention responder's trigger guard**, which is an authorization boundary rather
than a style rule — that job runs with `contents: write` and the repository's secrets. It shipped with
a hole worth remembering: an `issue_comment` payload carries **both** `comment` and `issue`, so a
clause reading `github.event.issue.author_association` — the *thread author's* — also evaluated on
every comment, and any comment by anyone on a maintainer-opened `@claude` thread started the job. (Not
an escalation: the action re-checks the actor's write permission and refuses to act. But the job
started, which on a self-hosted runner is the whole exposure.) The assertion is structural, not a
string match: the `if:` is split into its top-level `||` clauses, and each clause reading an
`author_association` must carry the null-check selecting the payload it belongs to, with the `issue`
clause additionally excluding comment events — by `github.event.comment == null` or
`github.event_name == 'issues'`, either spelling, because the invariant is what matters and not the
idiom. The split assumes each clause is itself parenthesised, and checks that assumption rather than
documenting it: one clause reading more than one payload's association means a wrapping reformat
collapsed them, at which point the pairing degrades to "present somewhere in the expression" — a PASS
that verifies nothing, which is the failure this assertion exists to prevent. *Which* association a
clause reads is only half the boundary, so the allowlist is pinned too: every clause's
`contains(fromJSON(…))` must be exactly `OWNER`, `MEMBER`, `COLLABORATOR`. Adding `CONTRIBUTOR` or
`NONE` is one token in the same free-text block and opens the job to anyone, with every pairing check
still passing.

The twelfth forbids an **evaluated expression in a trigger-block `description:` or `default:`**.
GitHub evaluates `${{ }}` in those fields rather than treating them as documentation, and the `on:`
block has no context — so a usage example naming `github` does not document the input, it stops the
whole file compiling. The failure is the least legible one this repository has hit: the workflow is
never triggered, yet every push produces a failed run with **no jobs, no logs, and the file path
where the workflow name belongs**, which reads like a broken pin rather than a broken file.
`go-flyio.yaml` shipped exactly that in a `fly_app_name` example and failed on `main` until it was
found. Usage examples belong in a `#` comment, which is never evaluated. The assertion is scoped to
the class rather than the instance: every workflow file, not only reusable ones (a
`workflow_dispatch` input evaluates identically), and `default:` as well as `description:` — a
`default:` being the likelier place to write `${{ github.ref_name }}` believing it resolves —
including nested `outputs`. Note the linter cannot be relied on here: `actionlint` catches the
`workflow_call` description case but the repository's own CI passed the broken file for its entire
life on `main`.

The thirteenth pairs each Claude workflow's **prompt** with the **tools its job actually
grants**. `anthropics/claude-code-action` ships a template that tells the model to "install
dependencies, run build commands, etc.", and then — when a linter or test suite is denied — to
"explain this in your comment so that the user can update your `--allowedTools`". Both are wrong
here and neither is a model quirk: the pipeline compiles, lints and tests the same commit in its
own jobs, and the denial is the design. Left alone the template produced review comments carrying
a *"Note on verification: `go build ./...` and `go vet` were denied by the tool permissions in
this run"* — a caveat about a decision, addressed to a reader who did not make it. Both prompts
therefore state their tool surface and name the toolchains they exclude, and the assertion keeps
the prose and the wiring moving together: a granted `Bash(…)` command missing from the prompt
re-creates the defect (the model meets its own tools by being denied them), and a command the
prompt calls denied while the allowlist grants it is the same drift reversed. A prompt may name
either the rule (`git add`) or the broader grant covering it (`git`).

Both halves read **sentences**, and the first version read paragraphs — a hole the review of the
pull request that added it found. A prompt states an exclusion wherever it is clearest: the
mention responder's sits in its Tools paragraph (*"`gh` is not granted, and neither is `git
diff`"*), not under `Denied on purpose:`. Scoping the collision check to that one paragraph never
read the sentence, while the naming check — searching the whole prompt for a backticked `gh` —
found it there and counted a *denial* as a *description*, so granting `Bash(gh:*)` to the
responder would have left the assertion green while the prompt called that tool denied. Denial
sentences are therefore partitioned out of the naming match and scanned for collisions wherever
they sit, and a widened grant (`Bash(git:*)`) collides with a narrow denial (`git diff`) that a
`git add` grant correctly does not.

The same assertion pins **`prompt` to `track_progress: true`**, which is the expensive half. A
`prompt:` on a comment or issue event *selects agent mode* (`src/modes/detector.ts`), where the
action's template — the thing that answers the mention — is replaced by the custom prompt. So
adding one to `reusable-claude-mention.yaml` without `track_progress: true` would silently stop it
answering the question it was mentioned for, with every job still green. That is the review's
original plugin trap (documented in `.docs/claude-review.md`) running in the opposite direction.
Tag mode's price is an event constraint: `validateTrackProgressEvent` accepts only
`pull_request`, `issues`, `issue_comment`, `pull_request_review_comment` and
`pull_request_review`, and **throws** on anything else — so a mention responder wired to another
event now fails loudly instead of quietly doing nothing.

The fourteenth asserts **which pull requests the review runs on at all**, and it is the one
assertion here that exists to save money rather than to prevent a silent failure. A
`chore/bump-*`, `bump/*`, `chore/autoupdate-*` or `dependabot/*` pull request is generated wholesale by a tool,
carries a version number or a dependency pin, and is merged unread — so every review of one is a
full-diff Claude run, at Opus prices, on a diff nobody reads back. The guard that stops it is a
job-level `if:`: free text, one expression, exactly what a "tidy these conditions" pass eats
first. It is therefore **evaluated, not matched** — the expression is run against ten pull
requests whose verdict is known, by a strict evaluator of the part of GitHub's expression language
a guard is written in and with GitHub's rules for it (strings compare ignoring case, `!` binds
tighter than `==`, `==` across types compares numbers) — so it survives a reordering, an input
rename or a rewrite from `startsWith` to `contains`, and still fails when a prefix is dropped.
Syntax outside that subset fails the case by name rather than being guessed at.

Two of the ten are the traps, and both are cases where the obvious guard is worse than none.
A plain `feat/…` branch must still BE reviewed, or an expression that skips *everything* passes a
test that only checks the automation branches. And emptying `autoupdate_branch_prefix` must give
up only the autoupdate exemption: `startsWith(ref, '')` is TRUE, so an input read without a
non-empty check silently disables every review in the repository that set it — a workflow that
looks configured and reviews nothing.

The prefixes are spelled exactly as `basic-checks` spells them
(`github/global/stages/10-code-check/basic-checks/action.yaml`), including the split between three
literal shapes (the two bump forms and `dependabot/`) and one configurable autoupdate prefix, which there is `AUTOUPDATE_BRANCH_PREFIX`
and here is the `autoupdate_branch_prefix` input. That split is forced — `startsWith` takes one
prefix and the expression language cannot iterate a list — but keeping the two jobs in step is a
choice: the changelog gate and the review gate exempt the same pull requests, so a repository does
not have to teach two jobs two different names for the same automation.

**Copilot's automatic code review cannot be given the same guard, and this is not an oversight.**
Its ruleset rule (`copilot_code_review`) takes exactly two parameters — `review_draft_pull_requests`
and `review_on_push` — and a ruleset's `ref_name` condition targets the **base** branch, so there
is no head-branch, author or path filter anywhere in the feature; the same is true of the personal
"Automatic Copilot code review" setting, which is account-wide. Two plausible-sounding workarounds
are not ones: an unlicensed author is still reviewed when a policy enables automatic review, and a
bot or Actions identity is too — GitHub bills that usage to whoever triggered the workflow, or to a
designated billing owner, rather than skipping the review. So a repository that wants Copilot off
for automation pull requests has to turn the automatic review off entirely and request it per pull
request instead (`gh pr edit <n> --add-reviewer @copilot`, or the REST equivalent requesting
`copilot-pull-request-reviewer[bot]`). That is a decision about an account's settings rather than
anything this library can ship, which is why nothing here attempts it — and why the two reviewers
being configured differently is the documented state, not drift.

**Secrets reach a build as secrets.** A value passed into a reusable workflow as an *input* loses
the caller's masking; passed as a *secret* it keeps it. That is why the deployment workflows take
`build_env` (an input, for an API origin) and `build_env_secrets` (a secret, same dotenv shape)
rather than one of each name. Related: a step-level `if:` cannot read the `secrets` context at all —
`if: secrets.x != ''` is a syntax error, so hoist the value into a job-level `env:` and test that.

**A `uses:` job cannot declare `environment:`, and everything environment-scoped follows from that.**
The key is simply not allowed on a job that calls a reusable workflow, so that job's `with:` and
`secrets:` blocks are evaluated with **no environment selected**. A caller writing
`with: { api_url: '${{ vars.API_URL }}' }` therefore gets the *repository-level* variable — which is
usually unset, so the value arrives as an empty string with no error anywhere. The two consequences
are worth memorising because neither is guessable and both fail silently:

- **Environment-scoped variables cannot be passed as inputs.** Name them instead: `build_env_vars`
  takes `KEY=VARIABLE_NAME` lines and resolves them from `toJSON(vars)` *inside* the deployment job,
  which does declare the environment. A name that resolves to nothing fails the step.
- **Environment-scoped SECRETS cannot reach a workflow in THIS repository at all.** Not with
  `secrets: inherit`, not by passing them explicitly, not by declaring `environment:` on the called
  job. Credentials a consumer wants this library to deploy with must be **repository-scoped** and
  passed explicitly.

  This is the asymmetry that makes it so easy to get wrong, and it is the opposite of what the
  GitHub documentation reads like: **environment VARIABLES do cross, environment SECRETS do not.**
  Measured, not inferred — a probe matrix run against a real consumer's `staging` environment,
  reading the same secret four ways:

  | Called workflow            | `environment:` | Environment secret |
  |----------------------------|----------------|--------------------|
  | same repository            | literal        | **present**        |
  | same repository            | expression     | **present**        |
  | **different repository**   | literal        | **empty**          |
  | **different repository**   | expression     | **empty**          |

  So the expression form is fine and the cross-repository boundary is the whole cause. GitHub's own
  wording is *"workflows that call reusable workflows in the same organization or enterprise can use
  the `inherit` keyword"* — this library is `rios0rios0/pipelines`, which is a different owner from
  essentially every consumer, so `inherit` carries `github_token` and nothing else. The failure is
  silent: the credential arrives as an empty string, the job's `environment:` still applies, a
  deployment record is still created, and the deploy fails as a missing credential rather than as a
  missing environment.

  **Do not "fix" this by suppressing Semgrep's `yaml.github-actions.security.secrets-inherit` and
  keeping `inherit`.** An earlier revision of this section said to, and it was wrong on both counts:
  the rule was right, and `inherit` did not work anyway. Pass the credentials explicitly — which
  also means the rule never fires and there is nothing to suppress.

  What a consumer gives up by moving a credential to repository scope is real and worth stating:
  every workflow and job in that repository can then read it, and `staging` and `production` no
  longer hold separate values. What it does **not** give up is the ref gate — the called job still
  declares `environment:`, so a `production` environment restricted to tags still refuses every
  branch, and its protection rules still run.

Because of that, credential secrets here are declared `required: false` and checked at runtime with
a message naming the likely cause. A `required: true` secret a caller cannot supply fails workflow
validation before any job starts, which is a worse error than a named one in the log.

Do not "fix" this by moving a resolver job in front of the pipeline. A job that declares
`environment:` and outputs the values works, but the `uses:` job then `needs:` it — so a
`production` environment with a required reviewer blocks lint, tests and security behind an approval
on every tag. The environment gate belongs on the deployment job alone.

**When a consumer needs a deploy, the answer is a composed workflow here — not a job there.** A
hand-written deployment job in a consumer repository gets no `require-checks` gate, no shared script,
and no cross-platform equivalent, and it is invisible to every assertion above. If the provider is
missing, add it under `global/scripts/deploy/` and wire it on all three platforms; if only the
GitHub convenience layer is missing, add the `<toolchain>-<provider>.yaml`.

### How Platforms Consume Templates

**GitHub Actions** — Reusable workflows via `uses: 'rios0rios0/pipelines/.github/workflows/<workflow>@<tag-or-sha>'`

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
| `semgrep`                                      | installed from PyPI into an isolated `python3 -m venv` — Semgrep ships no binary    |
| `checkov`                                      | the pinned release's wheel, refused unless its committed SHA-256 matches, installed binary-only into its own `python3 -m venv` |
| `sonarqube`                                    | expects `sonar-scanner` to already be on the runner                                 |
| `dependency-track`                             | no tool binary — uploads the CycloneDX BOM with `curl`                              |

Because the tools run directly on the host, the consuming CI job only needs the tool's own runtime dependencies (e.g. `python3` for `semgrep`, `git`/`jq`/`curl` for `gitleaks`) — not a Docker-in-Docker service.

### No Python of Its Own

**Enforced by `.github/tests/test-no-python.sh` (`make test-no-python`).** This repository's scripts
run in every consumer's CI, so a helper here is code every consumer executes. The helpers that used
to be Python -- the Terraform ordering, coverage, smoke-test and variable-catalog generators, the
Dart report converters, and the Python inside the test suites -- are Go (the root module, built from
the checkout on every run by `global/scripts/shared/go-helper.sh`) or POSIX shell. A new helper is
written in one of those two, never in Python, and `jq` and mikefarah/yq (`resolve-yq.sh`) are the
tools for JSON and YAML.

Python stays only where it is really needed, and the suite names each place:

| Where | Why it has to be Python |
|-------|-------------------------|
| The Python pipelines: `*/python/`, `makefiles/python.mk`, `global/scripts/languages/python/`, the `python.*` images, `pdm*.yaml` | They build consumers' Python projects |
| `python3 -m venv` and the virtualenv's pip in the Semgrep and Checkov runners | Both are Python programs with no binary release |
| One heredoc in `checkov/run.sh`, at most 30 lines, asked once | It asks Checkov's HCL parser -- `bc-python-hcl2`, a Python library that exists only in Checkov's virtualenv -- where it stopped in a file it could not parse |

The excused lines are listed verbatim, so a new use of Python beside them fails like any other, and an
excused line that disappears fails too, as does an excused file, so the list cannot outlive what it excuses. Prose that only
names Python -- "install python3 and re-run", `command -v python3`, a `python:3.13-slim` image -- is
not a call and is not flagged.

### OWASP Dependency-Check and the NVD

`global/scripts/languages/java/dependency-check/run.sh` is the one runner all three platforms call for the Java `sca:dependency-check` job. Dependency-Check scans against a local H2 copy of the NVD (~350k CVE records), and **building that copy is the only expensive part of the job** — the NVD API rate limits it per source IP (5 requests/30s anonymous, 50 with a key), and hosted runners share their egress IPs, so an unauthenticated bootstrap does not finish. Six non-obvious constraints shape the design; do not "simplify" any of them away:

| Constraint | Why |
|------------|-----|
| The API key must be passed as `-DnvdApiKeyEnvironmentVariable=NVD_API_KEY` (Maven) or written into the `dependencyCheck.nvd.apiKey` extension (Gradle) | **Neither plugin reads an `NVD_API_KEY` environment variable.** Exporting it is a no-op — the historical cause of hours-long unauthenticated runs. `-DnvdApiKey=<value>` does work but leaks the secret into `mvn -X` output ([GHSA-qqhq-8r2c-c3f5](https://github.com/advisories/GHSA-qqhq-8r2c-c3f5)), so the *variable name* is passed instead of the value |
| Gradle is configured with `--init-script` (`init.gradle`), not properties | The Gradle plugin reads its settings **only** from the `dependencyCheck` extension — it consults neither the environment nor system properties. An init script injects them without asking every consuming project to edit its `build.gradle`. It applies on `projectsEvaluated`, so it wins over a project's own `dependencyCheck { }` block |
| GitHub Actions uses split `actions/cache/restore` + `actions/cache/save` with `if: always()` | The all-in-one `actions/cache` saves in a post-job step that is **skipped on cancellation**. A cancelled Dependency-Check job therefore cached nothing, so the next run started cold and was cancelled again — a loop the cache could never escape |
| The update mechanism is chosen by **database state**, not by whether a key exists | A key makes the *delta* fast; it does not make the ~350k-record *bootstrap* survivable. A shared runner egress IP sustains ~30 records/s even authenticated — >3h for a cold build, past any sane timeout. A cold or partial database is therefore always bootstrapped from the rate-limit-free datafeed, and the API only tops up a complete database completed within `NVD_API_MAX_AGE_DAYS` (default 7). An older one's delta can be most of the NVD, which the API serves no faster than a cold build, so the datafeed refreshes it instead, in about three minutes. The marker's first line is the epoch second its run finished; a marker without one, written before it carried one, counts as too old |
| `cache/save` is gated on a `.owasp/.odc-complete` marker, not on `always()` alone | Saving unconditionally made one cancelled run permanent: the half-written database was published, restored, rejected by Dependency-Check, and rebuilt from zero until the timeout killed it and it saved another partial. `run.sh` clears the marker before running and writes it only once the analysis has written its report (next row), so it is the one trustworthy "this database is whole" signal — a partial `odc.mv.db` is indistinguishable from a good one on disk |
| The marker follows the analysis's **report** (`dependency-check-report.json`), never the build tool's exit status | A project setting `failOnError=false` — a plugin `<configuration>` value no command-line property overrides — exits 0 when the NVD update fails ("Unable to continue dependency-check analysis"), having scanned nothing. On 2026-10-22 that passed rest-arch's job and cached its near-empty database as complete; every later run sent the whole NVD through the API and was cancelled at the timeout. So a run without a report fails and leaves the database unmarked, whatever the tool returned. A report alone is not enough either: the engine treats a failed update as non-fatal whenever the database already holds data (part of an interrupted bootstrap, or the snapshot a failed delta targeted), analyses against it and writes the report anyway, listing the failure under `scanInfo.analysisExceptions` — a key the report carries only when there is one. A report holding it fails the run the same way, so a partial database is never cached as whole and a stale one is never restamped as fresh. The other way round, a build failing only on `failBuildOnCVSS` records no exception over a whole database, which is marked and cached so the next run tops it up instead of downloading it again. `cleanup.sh` empties the report directory first, so a report found there is always this run's |

With no API key the runner uses NIST's gzipped JSON data feeds (`nvdDatafeedUrl`), which are not rate limited, so a keyless project still gets a usable scan; a **cold** run uses them even when a key *is* present, for the reason in the table above. `NVD_DATAFEED_URL` overrides this with a self-hosted [`vulnz`](https://github.com/jeremylong/open-vulnerability-cli) mirror. The database is pinned to `.owasp/` (both plugins require an absolute path and otherwise default it into `~/.m2` / `$GRADLE_USER_HOME`, where the pipelines were not caching it) and reused for 24h via `nvdValidForHours`. The job is capped at 45 minutes on every platform so a pathological download is bounded rather than trusted — a safety net, not the fix: the datafeed bootstrap keeps a cold build under it and the age limit keeps the API delta small, so raising the cap would only let the slow path run longer. Covered by `.github/tests/test-dependency-check.sh`, which runs the script against a stub build tool and asserts on the argv it actually produces and on which runs mark the database complete, including the cold (datafeed), warm (API delta) and stale (datafeed refresh) paths.

### Dependency-Track and the Project Identity Model

`global/scripts/tools/dependency-track/run.sh` is the one uploader every platform calls. Read this before
changing it, because every defect it has ever had returned **HTTP 200 and a green job**.

**A project's identity is the PAIR `(name, version)`.** Each pair is a separate entity with its own UUID,
components and findings; there is no "project that holds several versions". An uploader that sends the
release version with `autoCreate=true` therefore mints a permanent new project on every bump, and nothing
removes it. One consuming instance reached **2585 projects across 77 distinct names**, one application
accounting for 355 of them, with every upload succeeding throughout.

**The upload API is identical on `4.14.x` and `5.0.5`, and the script has one code path.** Verified against the
`5.0.5` tag rather than the documentation site: `BomResource` is still `@Path("/v1/bom")`, the multipart
parameters are byte-identical, and auth is still `X-Api-Key`. v5 adds a `resources/v2` package that holds
no BOM resource. Do not add version detection this does not need. One model change DOES land for anything
that READS a project back: `ACTIVE` became `INACTIVE_SINCE` (nullable timestamp), `isActive()` kept as a
derived accessor. The v5 tree also moved to `apiserver/src/main/java/...`, which is why those files look
absent at the 4.x path.

Eight constraints shape this; `make test-dependency-track` asserts all of them:

| Constraint | Why |
|------------|-----|
| **A merge/pull request never uploads** | A PR whose version file is already bumped mints that version's project BEFORE the merge, and keeps it if the merge never happens — the largest single source of sprawl. Gated in the SHARED SCRIPT, not per-platform YAML, so a consumer pinned to an older template revision gets it and so the suite can exercise it offline. Only a POSITIVELY identified PR is skipped: "I could not tell" must not silently mean "nothing was recorded" |
| **`isLatest` is claimed only for a default branch or tag** | At most one version per name carries it, and a collection project with `AGGREGATE_LATEST_VERSION_CHILDREN` reads its metrics from that child. Asserting it every run moved the flag backwards onto older versions, so the parent reported a risk score belonging to the wrong version |
| **Azure DevOps and GitHub Actions cannot report their own default branch** | `Build.Repository.DefaultBranch` **does not exist** (`Build.Repository.*` is Name, Uri, Provider, ID, LocalPath, Clean, Tfvc.Workspace, Git.SubmoduleCheckout). A condition comparing against it tests an empty string, is always false, and silently disables every upload. GitHub exposes the default branch only through `github.event.repository`, not the environment. `DEPENDENCY_TRACK_DEFAULT_BRANCH` supplies it; without it those platforms upload but do not claim the flag. Two assertions stop the non-existent variable being reintroduced |
| **`parentName` only parents projects being CREATED** | `BomResource.uploadBom` resolves the parent solely inside `if (project == null && autoCreate)` — same in `4.14` and 5.0.5. For an existing project both parent fields are read and ignored, with no error and nothing in the response to notice. Adopting an existing portfolio needs `PATCH /api/v1/project/{uuid}` from an administrative job |
| **`jq -r` prints the STRING `null` for a missing key** | And `null` is a valid project name, so a BOM without `metadata.component` created a project literally called `null` and kept updating it. Extraction uses `// empty`; a missing name fails the job, a missing *version* uploads versionless (one stable identity, better than one pinned to `null`) |
| **The API key is never on argv** | argv is world-readable through `ps` and `/proc/<pid>/cmdline`, which on a shared or self-hosted runner means every other job on that host. The header goes in through `curl --config -` on stdin — same posture as `global/scripts/deploy/render/run.sh`, same reasoning as `-DnvdApiKeyEnvironmentVariable` |
| **There is exactly ONE implementation** | The GitLab abstract used to inline its own `curl` that skipped the `sed 's\|/\|-\|g'` name normalisation and sent no `isLatest`, so a scoped npm package became TWO projects depending on which platform built it. Separately, the GitLab **Go** job defined its own `script:` — and GitLab's `extends` REPLACES `script:` rather than appending — so it generated a BOM and threw it away, green, forever |
| **A server that is briefly away is retried; nothing else is** | A restarting instance answers for a few minutes with no response (`000`), its proxy's `502`/`503`/`504`, or Cloudflare's `521`. On 2026-10-21 a consumer's instance went away behind Cloudflare for about two minutes, and the upload that reached it then was answered `521` while the same job passed on its next run. The upload is an upsert, so `000`, `408`, `429` and `5xx` are retried with a growing wait: `DEPENDENCY_TRACK_ATTEMPTS` (default `5`) and `DEPENDENCY_TRACK_RETRY_DELAY` (default `30`, multiplied by the attempt number), five minutes in all. Any other answer would repeat identically and fails at once |

**GitHub Actions has no `35-management` stage at all** (`github/global/stages/` goes 20 → 40), so it has no
Dependency-Track job to wire. That is a pre-existing gap, not something this uploader can paper over; adding
the stage is its own piece of work.

### SonarQube and a Server That Is Briefly Away

`global/scripts/tools/sonarqube/run.sh` runs `sonar-scanner` again when a run failed because the server was
unreachable or answered 5xx, and only then. The scanner exits `1` both for a server that is restarting and
for a broken analysis, so the runner reads its output: an `ERROR` or `Caused by` line naming a refused or
reset connection, a timeout or a 5xx answer makes the run retryable, and a `QUALITY GATE STATUS` line rules
it out, because a failed gate is the analysis working. The shapes it keys on are the ones scanner `8.0.1`
prints: `Call to URL [...] failed: Connection reset`, `... failed: null` for a refused connection (the JDK's
`ConnectException` has no message), `GET ... failed with HTTP 500`, and the engine's
`HttpException: Error 521 on ...`. A scanner upgrade that rewords them turns a retry back into a plain
failure without any error, which is why `make test-sonarqube` pins each one. The budget matches the
Dependency-Track upload: `SONARQUBE_ATTEMPTS` (default `5`) and `SONARQUBE_RETRY_DELAY` (default `30`,
multiplied by the attempt number). The knobs are not named `SONAR_SCANNER_*` on purpose: that prefix belongs
to the scanner's own environment.

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
| **Semgrep runs, but the registry contributes nothing** | The engine parses Dart (experimental, actively maintained), but the registry publishes **zero** Dart rules: `p/dart` is HTTP 404 and `r/dart` returns a literal `rules: []`. Passing an unpublished pack is FATAL to the whole invocation, so `semgrep/run.sh` now probes the registry and skips a missing pack — only an explicit 404 skips it and only an explicit 200 settles it; anything else is retried (three attempts) and kept if it persists, so a network blip can neither quietly downgrade a scan nor, on its own, fail one. It then loads `global/scripts/tools/semgrep/rules/<language>.yaml` if this repository ships one, which for Dart it does |
| **OSV-Scanner replaces OWASP Dependency-Check** | Dependency-Check has no pub analyzer. OSV-Scanner queries the Pub advisory database directly and is the ONLY dependency scanner Dart has here. Exit code 128 ("no packages found") is mapped to success — a lockfile with only SDK dependencies produces it, and the safest possible dependency set must not be a red job |
| **`dart analyze`, not `flutter analyze`** | `flutter analyze` has no `--format` option at all ([flutter/flutter#95090](https://github.com/flutter/flutter/issues/95090)), so it can only be scraped. The Flutter SDK's bundled `dart` runs the same analyzer over the same `analysis_options.yaml`, which is why `common.sh` symlinks it. The analyzer's own exit code is ignored and the verdict recomputed from the parsed diagnostics, because this pipeline's gate is configurable (`DART_FATAL_WARNINGS`, `DART_FATAL_INFOS`) and the tool's all-or-nothing verdict is the wrong one to propagate |
| **The SDK comes from `storage.googleapis.com`, never a Docker image** | Same reason every other tool here is installed natively: Docker Hub rate-limits anonymous pulls, and a large, frequently-pulled SDK image is exactly what trips it. `DART_SDK_INSTALL_DIR` relocates the unpack target because GitLab CI can only cache paths inside `$CI_PROJECT_DIR` |
| **Coverage is converted, not consumed raw** | Dart emits LCOV and nothing else. Azure DevOps' `PublishCodeCoverageResults@2` and GitLab's coverage visualisation both need Cobertura, so `test/lcov-to-cobertura.sh` converts it — POSIX sh and awk, so an offline `make test` can exercise it and a Dart job needs no toolchain beyond the SDK. Repeated `SF:` records for one file are MERGED, not replaced: a multi-entry-point suite emits several, and taking the last would report only that suite's hits. The GitHub pull-request comment comes from the SAME parse (`test/lcov.awk`): `test/lcov-to-markdown.sh` renders the totals, the floor and the coverage of the files the change touches (diffed against the base SHA `dart.yaml` passes as `coverage_diff_base`), so the comment, `DART_COVERAGE_MINIMUM` and `DART_COVERAGE_EXCLUDE` never disagree; `dart.yaml` posts it through a pinned `sticky-pull-request-comment` step, and a caller grants `pull-requests: write`. No LCOV comment action was adopted instead because every maintained one needs an `lcov` binary the runner cannot `apt-get` or a Docker step the fleet cannot start, and all of them read the raw tracefile the gate never saw |
| **The GitHub `Test Results` check reads the FILTERED event stream, not the JUnit** | `flutter test --machine` shares stdout with pub's progress lines and flutter_tools' array-shaped events, and `dorny/test-reporter`'s `dart-json` parser fails the whole report on the first line it cannot parse -- so `test/filter-test-events.sh` keeps only the package:test protocol objects -- judged by the grammar Python's `json.loads` applied before it, not by jq, whose grammar varies by version and disagrees with that one on a lone surrogate escape (which Dart's `jsonEncode` writes), `NaN`, `01` and a byte order mark -- says what it dropped, and writes nothing when nothing is left (the `hashFiles` guard then skips the step). Its `java-junit` parser was not used because `tojunit` records each suite's class name as the runner's absolute path with the separators turned into dots, which annotates nothing. The parser is `flutter-json` for Flutter and `dart-json` for Dart, picked from the `toolchain` output the `30-tests/all` action resolves BEFORE the tests and publishes (`inputs.toolchain` is `auto` for the consumers that matter): only the Flutter one reads a Flutter failure's real message out of the `print` events and matches its `#0 ... (file:line:col)` frames, so under the Dart one every Flutter failure would say nothing and be annotated at the `testWidgets(` line. `tojunit` keeps reading the raw stream it has always read |
| **The report converters reproduce the Python ones byte for byte, in POSIX awk under `LC_ALL=C`** | Everything they write is read literally downstream, so each Python behaviour is reproduced rather than approximated: what `str.strip()` removes, the `int()` and `float()` grammars, UTF-8 decoding with `errors="replace"`, `fnmatch` (`*` crosses `/`, `?` is one character, sets read as `fnmatch.translate` writes them), `json.dumps`' ASCII escaping and `xml.sax.saxutils`' quoting -- all in `common.awk` and `test/lcov.awk`. `LC_ALL=C` makes every awk count bytes and print a `.` decimal point. Integers are printed with `%.0f`, because `%d` overflows above 2^31 in BusyBox and clamps in older mawk, and a string is checked against Python's grammar before awk converts it, because older mawk and BusyBox read `0x1A`, `inf` and `nan` as numbers. Section 7d of `test-dart-pipeline.sh` holds every report against output recorded from the Python converters; awk numbers are doubles, so a hit count above 2^53 is the one value written differently |
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

**Terraform has the same CodeQL gap, handled the same way.** CodeQL ships no HCL extractor,
so `terra.yaml` carries no `sast:codeql` job: the one it used to carry
(`codeql_language: 'hcl'`) failed at `codeql resolve languages` on every run and
`continue-on-error` hid it as a red-but-ignored job on every consumer's pull request.
Semgrep's Terraform rules are the static analysis for HCL, and `terraform.mk` leaves
`CODEQL_LANGUAGE` unset so `make sast` skips CodeQL. `.github/tests/test-terra-pipeline.sh`
fails if the job reappears on any platform. Do not "restore consistency" here either.

### Terra Test Tiers

The Terra CLI pipeline test stage exposes three parallel jobs on every platform (Azure DevOps, GitLab CI, GitHub Actions) — two always on, one opt-in:

1. **`test:all`** — the unified test job, delegates to `global/scripts/languages/terraform/test-all/run.sh` which orchestrates the two heavier tiers:

   | Tier          | Input                              | Tool                             | Output                          |
   |---------------|------------------------------------|----------------------------------|---------------------------------|
   | `terra-test`  | `modules/*/tests/*.tftest.hcl`, plus root modules under `TERRA_TEST_ROOTS` (opt-in, default empty, e.g. `stacks`) | `terraform test -junit-xml`      | `terra-tests.xml`, `terra-coverage.{md,json,xml}`, `terra-coverage-generic.xml` |
   | `terratest`   | `tests/terratest/*.go`             | `go test ./...` + `go-junit-report` | `junit-terratest.xml`         |

   `terra-coverage-generic.xml` (SonarQube's generic coverage format) comes from a standard-library-only Go generator, `terra-test/coverage/`, built from the pipelines checkout on every run. Every template's `test:all` job provisions a Go that can build it -- on GitHub Actions a consumer's `tests/terratest/go.mod` chooses the Go only when it asks for at least the root `go.mod`'s `go` directive, and the pinned Go is used otherwise, because setup-go sets `GOTOOLCHAIN=local` -- and where Go is absent the tier warns and skips that one file, as it did when the generator needed `python3`.

   Root modules join `terra-test` only through `TERRA_TEST_ROOTS`, set the way each platform already expresses options — Azure DevOps `TERRA_TEST_ROOTS` (template parameter, or a pipeline variable), GitLab CI `TERRA_TEST_ROOTS` (CI/CD variable), GitHub Actions `terra_test_roots` (workflow input) — and only with plan-only or mocked tests: a root whose test would apply with its real providers is refused and fails the job (see `terraform/terra-test/` above).

2. **`test:structural`** — third-tier shell runner, delegates to `global/scripts/languages/terraform/structural/run.sh`:

   | Tier          | Input                              | Tool                             | Output                          |
   |---------------|------------------------------------|----------------------------------|---------------------------------|
   | `structural`  | `tests/structural.sh` (consumer-owned) | executes the script directly | `junit-structural.xml`          |

3. **`test:validate`** (opt-in) — fourth-tier root-module check, delegates to `global/scripts/languages/terraform/validate/run.sh`:

   | Tier          | Input                              | Tool                             | Output                          |
   |---------------|------------------------------------|----------------------------------|---------------------------------|
   | `validate`    | every `*.tf`-bearing dir under `VALIDATE_ROOTS` (default `stacks`) | `terraform init -backend=false` + `terraform validate` | `junit-validate.xml`  |

   The other three tiers **parse**; this is the only one that **resolves** a reference. `terra-test` covers only modules carrying a test file (a root module only through the opt-in `TERRA_TEST_ROOTS`), `terratest` reads HCL offline, and `structural` asserts conventions in bash — none has an evaluation context, a module graph or a provider schema. So a root module can reference a module, variable, resource or output that does not exist and all three stay green, while the defect fails *every* plan and apply of that root module, for every target, before a resource is touched.

   Opt-in per platform, each in the form that platform already uses for options — Azure DevOps `ENABLE_VALIDATE: true` (template parameter), GitLab CI `ENABLE_VALIDATE: "true"` (CI/CD variable gating `rules`), GitHub Actions `enable_validate: true` (workflow input) — because unlike its siblings it needs the network for provider downloads and, for private module sources, credentials, which each platform's existing pre-script hook supplies (`PRE_STEPS`, `VALIDATE_PRE_SCRIPT`, `pre_script`). `-backend=false` keeps it a test rather than a deployment step: no backend credentials, no state access, no cloud login. Vendored copies under `.terraform/` are excluded.

The merged JUnit (`junit-terra-all.xml`) is the portable contract for `test:all` — GitLab CI's `artifacts:reports:junit` and GitHub Actions' `upload-artifact` both only take one file. `test:structural` publishes its own `junit-structural.xml` on a separate pipeline surface because it runs on its own job. When a tier has nothing to act on (e.g., a stack-only repo without `modules/`, `tests/terratest/` or `tests/structural.sh`, or — for `validate` — no directory matching `VALIDATE_ROOTS`), the corresponding runner emits an empty-but-valid JUnit and exits `0` so the job passes without a bespoke opt-out. `test:structural` runs on a parallel job rather than through `test-all` because the shell tier is offline and light — queuing it behind the heavier Go / Terraform tiers would waste feedback time. It is not dependency-free, though: the consumer's script runs the Go helpers (`var-catalog/run.sh --check`), so the job provisions the same Go as `order-check` on every platform.

### Terraform Ordering Standard

The `order-check` job (`global/scripts/languages/terraform/order-check/`, in the `10-code-check` stage of the `terra` and `terraform` templates on all three platforms) enforces the team's file-ordering convention for dense Terragrunt monorepos (numbered dependency layers under `environments/`, root modules under `stacks/`, leaf modules under `modules/`). The rules:

| File | Rule |
|------|------|
| `environments/**/root.hcl` | `dependency` blocks ordered ascending by the `environments/NN_` number in `config_path`; the `inputs` block groups `dependency.<name>.outputs.*` assignments by ascending dependency number (locals/`tags` first, static literals last) |
| `stacks/*/variables.tf` | a `// SET ON .HCL` section before a `// SET ON .ENV` section; inside `.HCL`, **dependency-derived** variables ordered by the dependency number they are fed from (looked up from the paired `root.hcl` inputs). `tags`/literals/feature-flags are unconstrained |
| `**/providers.tf` (stacks + modules) | `required_providers` entries and top-level `provider` blocks ordered heaviest→lightest by a built-in ranking (cloud → data → orchestration → network/PKI → app/utility → trivial like `null`/`random`/`local`) |
| `stacks/*/outputs.tf` | outputs ordered to follow the declaration position of the first `module`/`resource` their value references in `main*.tf` |
| `inputs = {}` in `root.hcl` / leaf `terragrunt.hcl` | every input key must be declared as a `variable` in the target stack; an undeclared input is **dead code** (Terraform silently drops the `TF_VAR_` Terragrunt exports for it, so the value is passed and never read) and is reported so it can be deleted before pushing. The target stack is resolved from the file's literal `source` (or, for a leaf, its included `root.hcl`'s), falling back to path convention (`environments/<p>` → `stacks/<p>`) when the source path is interpolated; a container dir with no `*.tf` of its own is skipped. This rule is **check-only — `--fix` never deletes a dead input** (deleting would break the "only ever permute" invariant, and the stack is resolved heuristically), so the finding names the exact keys for a human to remove |

Check mode is a CI gate (emits `build/reports/junit-order-check.xml`); `run.sh --fix` rewrites files into order (except dead inputs, which are only reported). The checker is a standard-library-only Go helper built from the pipelines checkout, so its job needs Go and nothing else -- each template provisions Go 1.25 or newer, the root `go.mod`'s directive, which `make test-go-module-toolchain` holds per job -- and running `--fix` locally needs the same. Missing `SET ON` markers, providers absent from the ranking, and files whose target stack cannot be resolved are **warnings/skips** (non-fatal). The provider ranking and path ignores are overridable per-repo via an optional `.terraform-order.json` (`{"provider_order": [...], "ignore": ["glob", ...]}`). The `--fix` rewriter parses each region into exact substrings, verifies a byte-for-byte round-trip, then only permutes those substrings — so it can never drop or corrupt content (it leaves any file it cannot parse cleanly untouched and reports it). Reordering `root.hcl` inputs changes `=` alignment, so run `terra format` / `terragrunt hcl format` after `--fix`; the `.tf` reordering is already `fmt`-clean.

### MVP Hosting Providers

The `50-deployment` stage ships jobs for the five platforms most worth using to host an MVP cheaply. Each is wired identically on all three platforms (`github/global/stages/50-deployment/<p>/action.yaml`, `gitlab/global/stages/50-deployment/<p>.yaml`, `azure-devops/global/stages/50-deployment/<p>.yaml`) and delegates to `global/scripts/deploy/<p>/run.sh`. Ranked in `README.md` by a stated composite of price (50%), reliability (30%) and popularity (20%).

| Provider | Free tier (verified Aug 2026) | Deploys via |
|----------|-------------------------------|-------------|
| **Cloudflare** | Permanent, **commercial use allowed**, Pages bandwidth unmetered; Workers 100k req/day, 10ms CPU | `wrangler pages deploy` / `wrangler deploy` |
| **Vercel** | 100 GB transfer, 1M edge requests, 6k build min — **non-commercial only**, revenue requires Pro | `vercel deploy` |
| **Render** | 512 MB web service, **sleeps after 15 min idle** (30-60s cold start); free Postgres **expires at 30 days** | REST API — Render publishes no CLI |
| **Netlify** | 300 credits/month; deploys cost 15 each, bandwidth 20/GB — roughly **20 deploys/month** | `netlify deploy --no-build` |
| **Fly.io** | **None.** Withdrawn 2024 (2-hour trial); ~**$2/mo** always-on, ~35 regions | `flyctl deploy --image` (an image already delivered, copied with `crane`), else `flyctl deploy --remote-only` |

Nine constraints shape this family; do not "simplify" any of them away:

| Constraint | Why |
|------------|-----|
| **A credential is never passed on argv** | Argv is world-readable through `ps` for the process's lifetime on a shared or self-hosted runner, AND `deploy_run` records the resolved command line into `command.txt`, which all three platforms publish as a downloadable artifact — so a token on argv is exfiltrated into that artifact and kept for its retention period. Every CLI here reads its token from the environment; Render uses `curl --config -` (stdin). Its deploy hook URL embeds a secret in the query string, so the whole URL is redacted rather than recorded. Same reasoning as `-DnvdApiKeyEnvironmentVariable` above |
| **`DEPLOY_DRY_RUN=true` installs nothing and touches no network** | It is the only reason `make test-deploy-providers` can exercise all five providers offline, with no credentials and no Node.js toolchain. A dry run that installed a CLI would add ~100 MB per provider and make the suite need npm |
| **Render's API key is preferred over its deploy hook** | A deploy hook is fire-and-forget: Render returns success for "request accepted", so the job goes **green even when the build that follows fails**, making the job's status meaningless. The API path returns a deploy id the script polls to a terminal state. The hook path warns about exactly this |
| **A Fly app that is not safe to run twice needs a CEILING, and `fly.toml` has none** | `min_machines_running` is a floor. Fly's deploy adds a spare machine the first time it fills a process group, and an app with an in-process event bus, an in-memory rate limiter or unelected background workers is then silently WRONG rather than broken -- duplicated workers, split state, halved rate budgets, and nothing to report it. `FLY_MACHINE_COUNT` enforces the ceiling with `flyctl scale count` after a successful deploy, and `1` also passes `--ha=false` so the spare is never created. The value is VALIDATED before anything is deployed, because the two enforcement points fail asymmetrically: `1 ` (trailing space) is not equal to `1`, so `--ha=false` is skipped and Fly creates the spare, and then the deploy SUCCEEDS and `scale count` is rejected once the release is already live -- leaving the app on the two machines the ceiling exists to refuse |
| **Fly app names are GLOBALLY unique, so a create failure is classified** | The name space is shared by every Fly customer, not scoped to an organisation, so `Name has already been taken` after the lookup already proved the app absent from your org means the name is held and no permission change can obtain it. flyctl cannot tell WHOSE, so the message names both: a stranger, or the operator's own account under an organisation `FLY_ORG` does not name (`apps list` only shows what the token can reach) — the second is fixed by pointing `FLY_ORG` at that org, and asserting the first would tell that operator to rename a running application. Reported as its own cause, because the obvious guess -- an app-scoped token, which genuinely cannot create apps -- sends the operator to mint a wider credential that still fails. Every role-shaped name (`api-staging`, `web`, `api`) is long gone; consumers prefix with their org or product |
| **Fly.io app auto-creation is opt-in, via `FLY_ORG`** | `flyctl deploy` does not create an app, so a brand-new environment's first pipeline is always red and the fix lives in someone's shell history. Setting `FLY_ORG` makes the script create the app when `apps list` does not show it. It is opt-in rather than automatic because an APP-SCOPED deploy token cannot create apps: auto-creation forces an ORG-SCOPED token that manages every app in the organisation, which is a real widening of blast radius and the consumer's trade to make, not this library's. Existence is checked before creating rather than "create and ignore the error", because Fly app names are globally unique and the duplicate-name error is identical whether the app is ours or an unrelated organisation's. Two shapes of "opted in and got nothing" are closed by design: the app name is resolved from `fly.toml` as well as `FLY_APP_NAME` (gating on the variable alone made `FLY_ORG` a silent no-op for the configuration `go-flyio.yaml` documents as making it optional), and an unresolvable name warns rather than skipping. `flyctl`'s exit status is read separately from `grep`'s, so a FAILED lookup is never read as "the app is absent" — that would announce a creation of an app that exists, fail on the name being taken, and advise widening a token that was never the problem |
| **The Fly.io version build argument is opt-in, by naming the `ARG`** | `--remote-only` builds from source on Fly's builder, so a Dockerfile that compiles its version in (`ARG VERSION=dev`, then `-ldflags -X`) reported its default on every deploy: nothing passed the argument. `FLY_VERSION_BUILD_ARG` names the `ARG`; the value is `FLY_APP_VERSION`, else the tag, else the commit's first 7 characters, resolved by `global/scripts/shared/build-version.sh` -- the helper the GitHub image delivery uses too, so one commit built in both places reports one version (asserted by running both, in `make test-build-version`). Opt-in because a name this library chose would override a project's unrelated `ARG VERSION`. The name and the value are VALIDATED before anything is deployed, because nothing downstream refuses either: a build argument no `ARG` declares is ignored, and a newline in the value would add a second argument to the newline-separated `build-args` list. A valid name the Dockerfile never declares warns rather than fails -- the check reads the file line by line, and a false alarm must not cost a deploy. With `FLY_IMAGE` there is no build to pass it to: the image was built with its version in it, so the name is neither passed nor validated |
| **A Fly.io deploy ships the image the pipeline delivered, by digest** | `FLY_IMAGE` names an image already pushed -- `go-flyio.yaml` passes the one `delivery > docker` pushed to GHCR, which is its default. Rebuilding the Dockerfile on Fly's builder took about two of the two and a half minutes a deploy spent, shipped an image with another digest than the one CI pushed, and put a deploy at the mercy of the remote builder: one stalled for 51 minutes and failed the deploy. The image's linux/amd64 build (the platform Fly machines run) is resolved to a digest FIRST, copied with `crane` -- registry to registry, no Docker daemon -- into `registry.fly.io/<app>` under a tag named after that digest, and deployed as `registry.fly.io/<app>@sha256:...`. Fly's registry, not GHCR, because machines pull again on every restart and migration and the GHCR credential is a job token that expires with the job. By digest, because a tag is mutable -- a re-run of a commit is a new build with a new digest -- and flyctl 0.4.118 hands a digest-pinned reference to Fly's API unchanged, then configures the machines with what the API resolves, where a tag would reach them as the tag. `crane` is pinned and checksum-verified like `flyctl`, nothing is installed or copied on a dry run, the credentials go into a throwaway `DOCKER_CONFIG` (never `$HOME/.docker`, which a persistent runner keeps) and reach `crane` on stdin -- the Fly token as flyctl hands it to its registry, `Tokens.Docker()`: no `FlyV1 ` scheme, macaroons only -- and both the credentials and the source registry's password are gone before flyctl runs, removed as soon as the copy is done and on any exit before it. A missing app name fails before anything is installed, since the copy names the app. `fly_build_from_source` restores the build on Fly's builder. GitLab CI and Azure DevOps take `FLY_IMAGE` too but keep building from source by default: their deploy templates are included on their own rather than composed after a delivery job, and their delivery templates push tags without recording a digest, so they have no image to hand over |
| **`flyctl` comes from the GitHub release archive, never `curl \| sh`** | Piping a remote script into a shell hands the runner's credentials to whatever that URL returns at that moment — the supply-chain shape this repository's own SAST stage exists to flag. Matches the gitleaks/hadolint/shellcheck install pattern |

Covered by `.github/tests/test-deploy-providers.sh` (345 assertions): the cross-platform wiring contract (a provider added to one platform and forgotten on the other two leaves three files that are each valid YAML on their own, so nothing else in CI would catch it), the argv each provider builds under dry run, and a sentinel-credential leak check over the whole report directory. The Fly.io image copy is also run for real, against stand-ins for `crane` and `flyctl` on an isolated PATH, so the order of the copy and the deploy, the digest each names, what reaches stdin rather than argv, and where the credentials are written are observed rather than read off the script.

### Makefile Include Pattern

Downstream projects include pipeline targets via:
```makefile
SCRIPTS_DIR ?= $(HOME)/Development/github.com/rios0rios0/pipelines
-include $(SCRIPTS_DIR)/makefiles/common.mk    # setup, sast
-include $(SCRIPTS_DIR)/makefiles/golang.mk     # lint, test
```

`dart.mk` adds its `sca` target to the suite `common.mk`'s `sast` runs by appending to
`SAST_TOOLS_EXTRA`, not by declaring `sast: sca`. `sast` carries a recipe now, and a
prerequisite runs *before* it — so `sast: sca` would abort the whole scan on the first
vulnerable package. Because `SAST_TOOLS_EXTRA` is only ever appended to and only ever
read, include order no longer changes which tools run.

The `-include` prefix makes includes optional (no error if pipelines not cloned).

### The SAST Gate Fails

`make sast` runs the whole suite and then **exits non-zero if any tool reported findings**,
printing a `SAST FAILED: <tools>` line naming which ones. Each individual target
(`make semgrep`, `make gitleaks`, …) fails on its own tool too. This is what makes the
documented pre-push step `make lint && make sast` a real gate.

It was not always so. Every SAST recipe carried a `-` prefix and `codeql` a trailing
`|| true`, which tell Make to ignore the recipe's exit status, so the targets returned 0
on findings, on a crash and on termination alike — real runs printed `Error 123 (ignored)`
from ShellCheck and `Terminated (ignored)` from an out-of-memory Semgrep and then reported
success. That was introduced for a good reason (*"so the aggregate `sast` target runs all
tools to completion"* — a prerequisite-only `sast` stops at the first failure, and a
repository with a Semgrep finding never learns it has a Gitleaks one), and the fix keeps
that reason: `sast` iterates `SAST_TOOLS` + `SAST_TOOLS_EXTRA`, dispatching one `$(MAKE)`
per tool so the recipes stay the single definition, collects the failures, and fails once
at the end.

**Do not "make SAST advisory again" here.** Advisory-versus-blocking is already decided at
the call site, differently per platform — Azure DevOps marks all five `continueOnError:
true`, `.github/workflows/*.yaml` forgives only `hadolint` (and `go.yaml` not even that, see
"A Failing Check Fails the Run"), GitLab blocks on all five — and
a makefile that swallows the code silently overrides all three. Findings a team has triaged
belong in that tool's own suppression file (`.codeql-false-positives`, `.semgrepignore`,
`.semgrepexcluderules`, `.hadolint.yaml`, `.gitleaksignore`). A consumer that genuinely
wants the old behaviour writes `make sast || true` at its own call site, where review can
see it. `.github/tests/test-sast-gate.sh` fails if the suppression returns.

### Checkov Starts Advisory, and Each Consumer Opts In to Blocking

`global/scripts/tools/checkov/run.sh` is the IaC misconfiguration tier that `terra.yaml`, both
`terra` security stages on GitLab and Azure DevOps, and `make sast` through `terra.mk` and
`terraform.mk` run. It is the one scanner here that does **not** fail on findings by default, and
the reason is the roll-out, not the noise: the Terraform tier had had no such scanner since Trivy's
removal, so every consumer meets this one on the same day. Blocking from the start would turn each
consumer with findings red before anyone could triage them, the way a single Hadolint discovery
fix once surfaced findings in six repositories at once. Do not "make it consistent" in either
direction:

| Constraint | Why |
|------------|-----|
| **Findings fail only when `CHECKOV_BLOCKING` is `true`** (`checkov_blocking` on GitHub, a CI/CD or pipeline variable elsewhere, a make variable locally) | The choice stays at the call site, as the section above asks, and a consumer turns it on once its findings are fixed or recorded. A value other than `true` or `false` fails rather than reading as advisory |
| **Advisory lives in the script, not in a job-level `continue-on-error`** | A job flag forgives a crash as readily as a finding and cannot be switched per consumer. In advisory mode the script exits 0 even when the scan cannot complete, and says so in the log and in a warning annotation on GitHub |
| **The verdict is read from the JSON report, never from Checkov's exit code** | Checkov exits 0 over a file it could not parse and over `#checkov:skip=<ID>` with no reason, and a repository's own `.checkov.yaml` can set `soft-fail`. All three are findings here: an unparsed file was never scanned, and the reason is what records a deliberate exception. The report is read with `jq`, so every runner of the scan needs it (GitLab's job installs it beside `git` and `curl`) |
| **The wheel is downloaded by name and refused unless its committed SHA-256 matches** before pip sees it, then installed binary-only into its own venv and run by path | The lesson of Trivy's compromise. The `# asset:` template lets the scheduled updater re-derive the digest on a bump; the wheel's dependencies resolve within the ranges it declares, binary-only |
| **The pin is read from the metadata pip wrote, never from `checkov --version` and never by running the venv's interpreter** | `global/scripts/shared/venv-distribution.sh` reads the `Version:` of `checkov-<version>.dist-info/METADATA` -- what `pip show` and `importlib.metadata` read -- so the check needs no Python. A venv holding two `checkov` distributions is a broken install and is reinstalled, not trusted. Semgrep's runner reads its pin the same way |
| **`.checkov.yaml`'s `skip-path` is read with mikefarah/yq**, resolved from PATH or downloaded at its pinned version and verified | A path or a list of paths is kept; any other shape fails the scan rather than being guessed at, exactly as a file yq cannot parse does |
| **Terraform only (`--framework terraform`), offline once installed (`--skip-download`, no update lookup)** | Hadolint and Gitleaks already cover Dockerfiles and secrets, and the pin, not the tool, decides the version |
| **Only the `*.tf` files Terraform reads: every `*.hcl` is skipped (`--skip-path '\.hcl$'`), and the repository's own `skip-path` entries are passed again beside it** | Checkov's Terraform runner parses every `*.hcl` as Terraform -- Terragrunt's `terragrunt.hcl`/`root.hcl`, the `*.tftest.hcl` files `terraform test` runs -- though Terraform never reads one as configuration. They yield no check, and their syntax (a Terragrunt `exclude { if = ... }`, a test's `run` blocks) only produced parse errors nobody could fix. A `--skip-path` on the command line *replaces* the configuration file's `skip-path` list instead of extending it, so the repository's `.checkov.yaml` is read for its entries, and one it cannot read fails the scan rather than dropping them |
| **An unparsed file stays a finding, named with where Checkov's HCL parser stopped and, for valid Terraform it is known to reject, the rewrite** | The parser (`bc-python-hcl2`, `0.4.3` in the newest Checkov too) rejects three constructs Terraform accepts: a `?` or `:` starting a line after a unary `!` in the condition ([bridgecrewio/python-hcl2#153](https://github.com/bridgecrewio/python-hcl2/issues/153)), a number in scientific notation, and `if` or `for` as an unquoted object key. Moving the operator up, writing the plain decimal and quoting the key are all read identically by Terraform, so the developer gets the line and the fix instead of a bare file name. The verdict asks the parser in Checkov's virtualenv -- the one Python left in the runner, and the reason it has to be Python: bc-python-hcl2 exists only as a Python library there, and only it knows where it stopped. It is asked once, about the unparsed files alone, and answers one line per file; the rewrite is read from the file in shell. Where the parser is absent the file is listed without a cause rather than with a guessed one |

### A Local CodeQL Scan Builds From What Git Would Ship

`global/scripts/tools/codeql/run.sh` builds its database from the directory it is handed, and the
extractors take everything under it -- the Go autobuilder builds every `go.mod` it finds. A CI
checkout holds only the repository, but a developer's working tree also holds what `.gitignore`
keeps out of it: on 2026-09-29 thirty stale agent worktrees under `.claude/worktrees` turned one
module into 31, a 93 GB database and a `make codeql` still importing on one thread after 77
minutes, where a clean checkout scanned in six.

So the script decides two things by whether it runs on CI (`CI`, which GitHub Actions and GitLab CI
set, or `TF_BUILD`, which Azure DevOps sets):

| | CI runner | Developer's machine |
|---|---|---|
| Source root (`CODEQL_SOURCE_SCOPE`) | `tree`: the checkout as it is | `git`: a scratch copy of the tracked files still on disk plus untracked ones no ignore rule excludes |
| `CODEQL_THREADS` | `1`: the host may be shared (see `codeql_runs_on`) | `0`: every core |

Either variable overrides its default. The copy keeps every path relative to the project root, so
SARIF locations and the `.codeql-false-positives` fingerprints (hashes of source lines, not of
paths) come out as on CI. It leaves out an untracked nested repository, which `git ls-files
--others` lists as `dir/`, as `git add` would. Outside a git work tree the directory is scanned as
it is. A build that needs a file `.gitignore` keeps out runs with `CODEQL_SOURCE_SCOPE=tree`, and a
failed `database create` on the copy says so. `.github/tests/test-codeql-scope.sh` asserts all of
it against a stub `codeql`.

### CodeQL Fails on Findings, Never on Its Upload

`global/scripts/tools/codeql/gate.sh` decides whether a CodeQL scan passes, on every platform: it
drops each SARIF result one of whose `partialFingerprints` values the project's
`.codeql-false-positives` lists (or the default beside the script), prints what remains with its
`primaryLocationLineHash`, and exits 1 when anything does. `run.sh` calls it for `make codeql`,
GitLab CI and Azure DevOps; the GitHub Actions `20-security/codeql` composite calls it on the
report `github/codeql-action/analyze` writes.

The GitHub job used to pass whatever CodeQL found. `analyze` fails only when the analysis itself
fails -- GitHub acts on a finding through code scanning, which needs the upload -- and a private
repository without GitHub Advanced Security, whose upload is refused, was told to set `upload:
'never'` to keep "a build-breaking check without the alerts". Nothing read the report after that,
so the check could not break.

| Constraint | Why |
|------------|-----|
| **`analyze` never uploads; the upload is its own `upload-sarif` step, `if: always()` and `continue-on-error: true`, after the gate** | A refused upload is a report-publishing failure (see Report Uploads Never Gate a Job) and must not fail a scan that passed; running it when the gate failed still shows code scanning what failed the job. `codeql_upload` only decides whether the upload is attempted (`failure-only`: when the job is failing) |
| **The gate step has no `if:` and no `continue-on-error`** | It is the verdict. An `if:` lets something skip it, and `continue-on-error` turns every finding back into a pass |
| **The analysis runs `security-and-quality` and reads the project's `codeql-config.yml`, as `run.sh` does** | The action's default suite keeps only high-precision security queries, so a medium-precision rule a local scan reports is never even run there, and a gate over a different scan fails on findings nobody can reproduce locally -- or passes ones they can |
| **The composite reaches the gate through `$GITHUB_ACTION_PATH`, not a `scripts-repo` checkout** | The runner unpacks the whole repository at the ref the action resolved, so the script always matches the action: this repository's own `ci.yaml` runs the action by `./` path, and a `scripts-repo@main` checkout there would test a pull request's action against `main`'s gate. It needs no network fetch and no `$/` runner floor |
| **It fails closed** | No argument, a missing report, a directory with no `*.sarif`, a report that is not SARIF, or no `jq` is an error, never "no findings". The inline filter it replaced read an unparsable report as zero findings |

`.github/tests/test-codeql-gate.sh` holds all of it: the gate against synthetic reports, `run.sh`
end to end against a stub `codeql`, and the composite's step order and flags.

This repository's own scan (`security > sast:codeql` in `.github/workflows/ci.yaml`) is a consumer of the same rules, from
its own root. `codeql-config.yml` excludes `actions/unpinned-tag`, which reports every
`rios0rios0/pipelines/...@main` self-reference -- moving by design, see Test 7 of
`make test-workflow-composition` -- while `make test-supply-chain` already holds every other `uses:`
to a commit SHA, more strictly than the query, which exempts trusted owners. `.codeql-false-positives`
lists the findings triaged as false positives, each with a dated rationale. Both files are read from
the root of the repository being scanned, so neither reaches a consumer; the default
`global/scripts/tools/codeql/.codeql-false-positives` is every consumer's and lists nothing -- never
add this repository's suppressions to it.

**A pull request's verdict covers only what it changes.** `github/codeql-action` analyses a pull
request diff-informed: a dataflow query such as `actions/code-injection` keeps only the findings in
lines the pull request touched, so one in untouched code passes that check and first fails the push
to `main`. That is how #746 passed on 8 findings while its merge push found 29. The other 21 were
`actions/code-injection/medium`, which reads every `${{ }}` inside a `run:` script of a composite
action or a `workflow_call` workflow as attacker controlled, because CodeQL cannot see who calls
them. So every value reaches a script through `env:` and is read as a shell variable, and an input
that is shell by contract (`build_command`, `pre_script`, the `command` of openapi-sync and
pdm-lint) runs as `eval "$VAR"` on an `env:` value: in the step's own `bash -e -o pipefail`, which a
child `sh -c` would drop, so it behaves exactly as the expression did.

### CodeQL Reads Go Only Under a Go as New as the Module

Two things have to read a module's `go` directive before CodeQL can analyse it, and either one
failing loses the analysis. `make test-go-module-toolchain` (sections 3, 3c and 4) holds both:

| What | Why it must reach the module's Go | Where it comes from |
|------|-----------------------------------|---------------------|
| The `go` on PATH | The Go autobuilder builds the module with it. Under `GOTOOLCHAIN=local` it refuses a newer directive; under `auto` it fetches that toolchain only with a route to proxy.golang.org | GitHub Actions: `actions/setup-go` from `go_version_file`, before `init`. GitLab CI: the Go stage's `sast:codeql` override, in `.go`'s image. Azure DevOps: the pinned `GoTool@0` the Go stage passes through the CodeQL template's `PRE_STEPS`. `make codeql`: the developer's own Go |
| The bundle's Go extractor | A prebuilt binary whose type checker refuses a language version newer than the Go it was built with | `CODEQL_BUNDLE_PINNED_VERSION` for `run.sh`. On GitHub, the CLI GitHub's servers pick for the pinned action: it ran 2.27.1 under a pin whose own default was 2.26.3 |

Four constraints shape it; do not "simplify" any of them away:

| Constraint | Why |
|------------|-----|
| **The extractor's refusal is silent, so it is checked by table** | CLI 2.26.3 logs `package requires newer Go version go1.27 (application built with go1.26)` over a `go 1.27` module and still creates the database, exit 0, with broken types. That is why this repository waived Go from 2026-08-21. Every bundle from `codeql-bundle-v2.26.4` (2026-08-26) is built with go1.27. Section 4 records the first bundle for each Go minor, and fails when a module here moves to a minor it does not list or the pin falls below it |
| **GitLab's shared job has no Go, so the Go stage moves it** | The shared job ran in the pipeline's default `docker:x.y` image, which is Alpine: the bundle's glibc-linked Java failed with `java: not found`, and there is no Go. Its default image is glibc now, but carries no Go either. The override takes `.go`'s IMAGE only. `.go`'s before_script and cache put GOPATH in the checkout, and the autobuilder searches every `go.mod` under the source root (it skips only `vendor/`), so a module cache there would be extracted as hundreds of projects. Every other language's job is covered under "Every Language's CodeQL Has What Its Extractor Needs" below |
| **Azure's failure would not be red** | The `run.sh` step is `continueOnError`, by the shared-SAST decision recorded under "A Failing Check Fails the Run", so a missing Go reads as "succeeded with issues". Hosted images carry Go 1.24 to 1.26 only (Ubuntu 24.04 defaults to 1.24, 26.04 to 1.26), so the pinned `GoTool@0` is what makes the result independent of the agent |
| **The autobuilder runs `make` first, with no target** | It does so wherever a Makefile exists, and offers no switch. Here the default goal is `login`, a `docker login` that fails without a terminal and is skipped. In a consumer whose Makefile includes `common.mk` before its own targets, under the `SCRIPTS_DIR` that `run.sh` exports, it is `setup`, which clones or fast-forwards `PIPELINES_HOME`: KI-03 |

This repository's self-scan extracts two modules under one Go, the helpers at the root and the
tor-proxy health probe, so `go_version_file` names the newer directive; section 3 fails if another
module overtakes it.

### Every Language's CodeQL Has What Its Extractor Needs

**Enforced by `.github/tests/test-codeql-runtime.sh` (`make test-codeql-runtime`).** Until 2026-10-29
no GitLab CI analysis ran at all, for any language (KI-02 in `.docs/known-issues.md`), and nothing
was red for the right reason: the image a job runs in is rarely written on the job, so the suite
resolves each GitLab CI entry template the way GitLab does (`include:`, `extends:`, `!reference`)
before asserting on it. What an image ships cannot be read from a template, so `IMAGE_FACTS` there
records what each one was observed to carry, and an image with no row fails until somebody looks.

| Language | Its extractor needs | GitLab CI `sast:codeql` runs in | Azure DevOps `PRE_STEPS` | GitHub Actions |
|----------|---------------------|---------------------------------|--------------------------|----------------|
| Go | the module's Go: it builds | `.go`'s `golang:<pinned>-bookworm` | `GoTool@0`, as the Go jobs | `setup-go` from `go_version_file` |
| Python | a Python 3 | the shared default, `python:3.13-slim` | `UsePythonVersion@0`, as the Python jobs | a GitHub-hosted runner |
| JavaScript / TypeScript | Node.js, which parses TypeScript | the shared default, with `nodejs` installed | `UseNode@1`, as the JavaScript jobs | `setup-node`, before `init` |
| Java, Gradle | a JDK and Gradle: it builds | `gradle:8.7.0-jdk21`, on `.gradle`'s runner tags | `JavaToolInstaller@0`, as the Java jobs | a GitHub-hosted runner |
| Java, Maven | a JDK and Maven: it builds | `.maven`'s `maven:3.8.8-eclipse-temurin-11` | no Maven template | a GitHub-hosted runner |
| C# | the .NET SDK | `.sdk`, without building (`CODEQL_BUILD_MODE: 'none'`) | `UseDotNet@2`, as the .NET jobs | a GitHub-hosted runner |

Eight constraints shape it; do not "simplify" any of them away:

| Constraint | Why |
|------------|-----|
| **The shared default sits on `.codeql-runtime`, not on `sast:codeql`** | An `image:` on the job outranks the image an override takes through `extends`, so with the default on the job every override would analyse in it: Go with no Go. Overrides replace `extends` and keep the shared script, report and stage |
| **No GitLab CI image is Debian 11** | Debian 11's security updates left the Debian mirrors when its LTS ended: the index still lists them and the packages answer 404, so `apt-get install` fails before a job does any work. `.npm`, `.yarn` and `.maven` were Debian 11, which cost `report:dependency-track` and the Maven `sca:dependency-check` their installs (KI-04) and kept the CodeQL jobs off them; they are Debian 13 and Ubuntu 22.04 now. Section 7 of the suite fails on any GitLab CI image `IMAGE_FACTS` marks `debian11`, and the `apt` fact keeps `sast:codeql` and those two jobs on an image where `apt-get` works |
| **No template names a Node.js past its end of life** | GitLab CI's JavaScript jobs ran Node 16 and Node 18 long after their end of life, and Azure DevOps' ran Node 20 past its, with nothing red (KI-05): nothing anywhere knew the dates. Section 8 reads every Node.js a template names -- a GitLab CI `node` image, an Azure DevOps `UseNode@1` or `NodeTool@0` input, a GitHub Actions `setup-node` `node-version:`, the default of a GitHub Actions input carrying a Node.js version (`node_version`, `test_build_node_version`) -- and fails on a line past its end of life on the day it runs, on an odd line, and on a line with no date in `NODE_END_OF_LIFE`. It is meant to go red the day a line in use ends: 22, which the deployment templates install, does on 2027-04-30. Node 26 is no way out of it for the JavaScript jobs: Node 25 dropped corepack, and `node:26` ships neither corepack nor Yarn. Only literal values are read, input defaults included: a value that names an input or a variable is the consumer's |
| **Gradle runs in the glibc twin of `.gradle`'s image** | `.gradle` is Alpine. With the image's musl JDK as `CODEQL_JAVA_HOME` the CLI starts, but the build cannot: CodeQL's build tracer, `preload_tracer`, is glibc too |
| **`run.sh` recreates the report directory after the build** | The Java autobuilder runs Gradle's `clean`, which deletes `build/`, including the `build/reports/codeql/` that `cleanup.sh` made. On a CI runner the build runs in the checkout, and `database analyze` ended in `Could not write SARIF file` |
| **GitLab CI extracts C# without building it** | Its .NET templates build .NET Framework projects on Windows runners, and on Linux the C# autobuilder stops at `MSB3644` and `Could not auto-detect a suitable build method`. `CODEQL_BUILD_MODE` is unset everywhere else, which keeps the CLI's default: the autobuild every other platform relies on |
| **The job restores no cache** | A Go module cache in the checkout is extracted as hundreds of extra projects, and a restored Java `build/` or build cache can mark the compilation up to date, so the extractor sees nothing compiled |
| **Every language and every Azure stage has a row** | A stage that includes the shared job without a row in `EXTRACTOR_NEEDS`, or an Azure stage without one in `AZURE_TOOLCHAINS`, fails, and so does a row nothing reaches: a language that stops being analysed looks exactly like one nobody thought of |

The findings gate reads the SARIF with `jq`. GitHub-hosted runners and Microsoft-hosted agents carry
it, and no job installs it on a self-hosted one, where the gate fails closed without it.

### Report Uploads Never Gate a Job

On GitHub Actions every `actions/upload-artifact` step that publishes a report is
`continue-on-error: true`. The tool's own step decides pass or fail; the upload only publishes the
evidence, and GitHub can refuse it for reasons unrelated to the code. The one that forced this:
once an account has spent its monthly Actions storage allowance and its budget stops further
usage, every upload answers `Failed to CreateArtifact: Artifact storage quota has been hit`. The
allowance is storage-time accrued over the billing month, so deleting artifacts does not bring
uploads back before the next month starts. While uploads could fail their jobs, that refusal
turned clean scans red and SKIPPED every stage that `needs` them — tests, builds and deployments.

This does not make any tool advisory — findings still fail the job, as the previous section
requires — and two cases keep the upload from weakening a gate:

- **A mandatory report** (the tool must leave one when it exits 0) gets a `Verify Report` step
  right before the upload. Do not use `if-no-files-found: 'error'` for this: under
  `continue-on-error` it fails nothing.
- **A deliverable** (the upload IS the job's product, like `dart/stages/40-delivery/build`)
  stays fatal, because a refused upload means nothing was delivered.

**An upload never asks to be kept longer than the repository keeps artifacts.** `actions/upload-artifact`
cuts a `retention-days` above the repository's own retention down to it and adds a warning
annotation saying so. Every `medhub-life` repository keeps artifacts for 2 days, so the stages'
plain `10` (and `30` for the coverage reports) put "Retention days cannot be greater than the
maximum allowed retention set within the repository. Using 2 instead." on every job that uploads,
on every run. Each `retention-days` is therefore the shorter of the stage's own number and the
repository's `github.retention_days`, written as
`"${{ github.retention_days < 10 && github.retention_days || 10 }}"` with the same number twice.
An absent `github.retention_days` compares as `0` and falls back to the stage's number, so nothing
changes where the repository keeps artifacts longer.

`.github/tests/test-report-uploads.sh` holds all four rules; a new stage that is mandatory or a
deliverable must be added to that test's `MANDATORY` or `DELIVERABLES` set.

### A Failing Check Fails the Run

A `code-check >` or `security >` job carries **no job-level `continue-on-error`**. On a job, the
flag concludes the *run* as passed whatever the job did: the check goes red, nothing waits for it,
and every later stage runs anyway. That is how the Go pipeline's lint became advisory without
anyone deciding so. A consumer's golangci-lint sat red on its default branch for about seven hours,
every run green, while a binary built with an older Go than the code's could not load the standard
library and no linter ran at all. The one failure a check tolerates is a refused report upload,
and that belongs on the upload step (previous section).

The Go pipeline blocks on its checks on every platform:

| Check         | GitHub Actions          | GitLab CI                      | Azure DevOps                                 |
|---------------|-------------------------|--------------------------------|----------------------------------------------|
| golangci-lint | blocking (was advisory) | blocking (was `allow_failure`) | blocking (already was)                       |
| govulncheck   | blocking (was advisory) | blocking (was `allow_failure`) | blocking (was a job-level `continueOnError`) |
| Hadolint      | blocking (was advisory) | blocking (already was)         | advisory: a shared template, see below       |

For govulncheck, removing the advisory flags was not enough. The script runs `govulncheck -json` so the report is machine-readable, and with `-json` govulncheck exits 0 whatever it finds: the job could only fail when the scan itself broke, so no Go pipeline ever failed on a vulnerability. The verdict now comes from the report. `global/scripts/languages/golang/govulncheck/run.sh` replays it through `govulncheck -mode convert`, which prints the findings into the log and exits 3 when the code calls a vulnerable symbol. A vulnerability only in a package the code imports, or a module it requires, is listed but does not fail the job, which is govulncheck's own default. The scan's stderr goes to the log, never into the report, so the report stays JSON `convert` can read. `make test-govulncheck-verdict` pins all of it, with `go` and `govulncheck` stubbed. When the fix was written, none of the 17 GitHub repositories that use the Go pipeline called a vulnerable symbol on its default branch, so the change turned none of them red.

`make test-workflow-composition` (Test 16) holds the rule with two lists. It fails on a job that is
advisory without being listed, and on a listed job that no longer is:

- **`ADVISORY`**: advisory on purpose, each entry with the reason its users read. Today that is
  ESLint beside the blocking `style:format`, Knip, and Dart's unused-code check.
- **`UNREVIEWED`**: advisory since before the rule, with no reason recorded anywhere. It holds 30
  jobs, every other toolchain's Hadolint among them. It may only **shrink**, and its limit is
  pinned in the test. Before a job leaves it, check it the way the Go checks were checked: does
  any consumer fail it today? Each one that does turns red the moment the check blocks.

The test follows the Go pipeline's GitLab CI and Azure DevOps twins through their includes and
templates too. It accepts exactly two kinds of `continueOnError` there:

- the step that trims the build cache, which is housekeeping rather than a check;
- the analysis steps of Azure DevOps' four shared SAST templates. They are advisory for **every**
  Azure toolchain at once, by the decision recorded under "Do not make SAST advisory again". Making
  them block is a decision about every Azure pipeline, not about the Go one.

**A blocking lint needs headroom under load.** With about twenty runs sharing one self-hosted host,
a clean golangci-lint analysis outran its fixed `--timeout 10m` and exited 4. A blocking job turns
that into a red build. Three things changed in the runner:

- its default timeout is now `30m`;
- `GOLANGCI_LINT_TIMEOUT` overrides it, and a self-hosted runner's `.env` can set it;
- an exit code of 4 now prints that no finding caused the failure.

The other two remedies were not needed:

- **A persistent analysis cache:** golangci-lint already keeps its cache in the user's cache
  directory, which a self-hosted runner preserves.
- **A cap on concurrent lint jobs per host:** it would need a runner label on every host, and it
  queues each lint behind the others to absorb a spike that a longer timeout absorbs on its own.


### Shared Ignore Rules

`global/gitignore/` holds the canonical list of files the pipeline writes into a consumer's working
tree; `make gitignore` generates them into a delimited block in that consumer's own `.gitignore`, and
`make gitignore-check` fails when the block is stale. Both come from `common.mk`, so any project that
already includes it gets them.

**Why this is generated rather than included, like the makefiles are.** Four mechanisms were tested
against git 2.53.0 before settling on generation; the first two rule themselves out:

| Mechanism | Result |
|-----------|--------|
| an `include` directive inside `.gitignore` | **does not exist** — git has no such feature |
| `.gitignore` as a symlink to a shared file | **refused** — `warning: unable to access '.gitignore'`, and every ignored file becomes untracked |
| `core.excludesFile` (accepts a path outside the repo) | works, but is local config, holds one file, and set per-repo it silently replaces the developer's own `~/.gitignore` |
| `$GIT_DIR/info/exclude` | works, and does not clobber a personal global — but is still per-clone |

Both working mechanisms are **local to a clone**, so they are invisible to CI, to a fresh checkout, and
to every bot that clones and runs `git add -A` — which is precisely the population that commits a stray
report file. The rules therefore have to be committed. Generating them keeps one definition, and
`--check` restores the enforcement an `include` would have given for free.

Four properties are deliberate:

| Property | Why |
|----------|-----|
| **The block sits FIRST in the file** | Gitignore resolves last-match-wins, so anything BELOW the block overrides it. Putting the block last would let a shared entry silently defeat a project's own `!` negation — the project must stay able to opt out of a rule it does not want |
| **Which fragments apply is read from the consumer's Makefile** | It already declares the pipeline it consumes, so the `.mk` files it includes are the answer, and there is no second list to keep in step. An include whose fragment is absent is skipped silently, so "no fragment" must never be reached by omission -- see the last row |
| **A fragment exists only where a language writes outside `build/reports/`** | There are TWO ways to escape it, and checking only the first is how this was got wrong twice. **Overriding `REPORT_PATH`**: `golang.mk:16`, `dart.mk:26` and `python.mk:16` point it at `./reports`, so each of those three needs `/reports/`, which `common` does not cover. **Writing outside `REPORT_PATH` altogether**: Go also writes JUnit and coverage files at the repository root; Dart leaves `coverage/lcov.info` where `package:coverage` and the IDE plugins expect it; and Terraform -- which DOES keep the default `build/reports/` -- has the largest ones in the repository, because `terraform init` vendors provider binaries into `modules/*/.terraform/` (`terraform/terra-test/run.sh`) and `stacks/*/.terraform/` (`terraform/validate/run.sh`), and that same validate tier points `TF_PLUGIN_CACHE_DIR` at `$(pwd)/build/.terraform-plugin-cache` -- under `build/`, NOT under `build/reports/`. Only Java, JavaScript and .NET genuinely need nothing. Check `grep -rn 'REPORT_PATH *?*=' makefiles/` before concluding a language is covered -- reading a truncated grep of that command is how `dart` and `python` were missed -- and then ask the second question too, because `REPORT_PATH` alone would not have caught Go, Dart or Terraform |
| **A `.mk` with no fragment is a recorded decision, not a silence** | `run.sh` skips a language with no fragment silently (`[ -f "$FRAGMENT_DIR/$name" ] || continue`), so `terra.mk` and `terraform.mk` shipped with none while `make gitignore-check` stayed green in every consumer -- the failure has no symptom until a `git add -A` stages a few hundred MB of provider binaries. `test-gitignore.sh` therefore requires every `makefiles/*.mk` to either ship a fragment or be named in its `WRITES_ONLY_REPORTS` list, so a new language fails the suite until somebody writes down which of the two it is |

## Contribution Requirements

- Changes **must** work across all three platforms (GitHub Actions, GitLab CI, Azure DevOps)
- Run `make test` before submitting
- **Mandatory updates**: a changelog fragment (`chlog new --kind <Kind> --body '...'` — never edit
  `CHANGELOG.md`, which is generated from the fragments), relevant documentation, and test scenarios
  for new functionality
- Shell scripts must pass ShellCheck and must be executable (`chmod +x`)
- YAML indentation: 2 spaces, UTF-8, LF line endings (see `.editorconfig`)

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
