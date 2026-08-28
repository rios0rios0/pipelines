# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A CI/CD pipeline templates library providing reusable workflows for **GitHub Actions**, **GitLab CI**, and **Azure DevOps** across Go, Python, Java, JavaScript, PHP, Ruby, .NET, Dart/Flutter, Terraform, and Terra CLI. This is **not a runnable application** — it provides templates and scripts consumed by other projects.

## Commands

```bash
make test              # Run all validation tests (Go, go-module-toolchain, CycloneDX main detection, Go cache trim, Lambda, YAML merge, SonarQube, release tag, tftest-gen, order-check, var-catalog, terraform-validate, docker-multi-arch, basic-checks, dependency-check, dependency-track, goreleaser-prepare, release-version-extraction, release-reconcile, deploy-providers, dart-pipeline, javascript-pipeline, workflow-composition, supply-chain, runner-cache-gating, azure-step-names)
make test-go-script    # Test Go validation script only
make test-go-module-toolchain  # Test that every go.mod toolchain directive is readable by the images/analysers that consume it only
make test-go-tool-staleness    # Test that a source-built Go tool (govulncheck) is rebuilt when its toolchain/pin moves only
make test-go-tmpdir-modcache   # Test that the Go module cache stays out of $TMPDIR only
make test-go-integration-scope  # Test which packages the Go runner's integration phase selects only
make test-lambda       # Test Lambda template validation only
make test-yaml-merge   # Test YAML merge validation only
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
make test-dependency-track  # Test the Dependency-Track BOM uploader (identity, isLatest gating, PR skip, cross-platform wiring) only
make test-goreleaser-prepare  # Test the GoReleaser main package detection only
make test-release-version-extraction  # Test release version extraction (tag ref + bump commit) only
make test-release-reconcile  # Test release reconciliation gap detection only
make test-deploy-providers   # Test the MVP hosting deployment providers (Cloudflare, Vercel, Render, Netlify, Fly.io) only
make test-memory-detection  # Test the cgroup-aware memory ceiling detection only
make test-dart-pipeline # Test the Dart/Flutter pipeline (scripts, Semgrep rules, cross-platform wiring) only
make test-javascript-pipeline  # Test the JavaScript formatting gate (Prettier runner + cross-platform wiring) only
make test-workflow-composition  # Test the GitHub Actions workflow composition standard only
make test-supply-chain # Test the supply-chain pinning contract (actions, images, binaries, packages) only
make test-runner-cache-gating  # Test that no GitHub Actions cache restores into $HOME on a self-hosted runner only
make test-dependency-updates  # Test the dependency-update checker only
make check-dependency-updates # Report which pinned dependencies have a newer release (network)
make test-azure-step-names  # Test Azure DevOps step-name uniqueness across expanded templates only
make build-and-push NAME=<image> TAG=<tag>  # Build and push a container image
```

Test scripts live in `.github/tests/`. The CI workflow (`.github/workflows/ci.yaml`) validates YAML syntax, script permissions, and runs ShellCheck on all shell scripts.

## Architecture

### 5-Stage Pipeline Model

All platforms follow consistent numbered stages:
1. **10 - Code Check** — Linting, formatting, basic checks (rebase verification, changelog validation). The `terra`/`terraform` templates add an **order-check** job here that enforces the file-ordering standard (dependency/inputs ordering in `root.hcl`, `// SET ON .HCL` / `// SET ON .ENV` grouping in `variables.tf`, heaviest→lightest `providers.tf`, `main*.tf`-ordered `outputs.tf`) and flags dead terragrunt inputs (`inputs = {}` keys not declared as a stack `variable`); see Terraform Ordering Standard below
2. **20 - Security** — SAST (CodeQL, Semgrep, Gitleaks, Hadolint, ShellCheck) and SCA
3. **30 - Tests** — Unit/integration tests, coverage. For the Azure DevOps `terraform` template, this stage runs three opt-in test tiers as parallel jobs: a plan-time smoke job (`tests/*.tftest.hcl` via `terraform test` with `mock_provider`) and an apply-time e2e job that provisions a disposable [kind](https://kind.sigs.k8s.io/) cluster and runs both `tests/e2e/*.tftest.hcl` (via `terraform test`) and `tests/terratest/*.go` (via the shared `terratest/run.sh`). All tiers are blocking so a red apply-time regression prevents `35-management` and `40-delivery` from running. The earlier `45-e2e` design was merged into `30-test` so smoke and apply-time feedback land in the same stage.
4. **35 - Management** — SBOM generation, dependency tracking
5. **40 - Delivery** — Artifact builds, container images
6. **50 - Deployment** — two families with different platform coverage. The infrastructure targets (ARM, Lambda, K8s) remain **Azure DevOps only**; the **MVP hosting providers** (Cloudflare, Vercel, Render, Netlify, Fly.io) are wired on **all three platforms** — see MVP Hosting Providers below

### Directory Layout

- `.github/workflows/` — GitHub Actions reusable workflows (e.g., `go-docker.yaml`, `pdm-docker.yaml`)
- `gitlab/<language>/` — GitLab CI templates with `stages/`, `scripts/`, `abstracts/` subdirs
- `azure-devops/<language>/` — Azure DevOps templates, same structure as GitLab
- `global/scripts/tools/` — Platform-agnostic security tools (codeql, gitleaks, semgrep, hadolint, shellcheck, sonarqube, dependency-track)
- `global/scripts/languages/` — Language-specific scripts (golang, java, javascript, php, python, ruby, dart, terraform). Most `run.sh` scripts follow shared conventions, but the Terraform helpers below are documented exceptions: they write reports directly under `build/reports/` and do not rely on the common `cleanup.sh` report-directory pattern.
  - `dart/` — Dart and Flutter runners: `setup`, `format`, `analyze`, `test`, `unused`, `sca`, `build`, `publish`, plus a sourced `common.sh` (not executable — it is sourced, never run). All honour `DART_DRY_RUN=true`, which resolves and records commands without installing or executing anything; that is what makes the whole family testable offline. See Dart & Flutter Support below
  - `terraform/terra-test/` — `terraform test` runner over `modules/*/tests/*.tftest.hcl` (emits JUnit + Markdown/JSON/Cobertura coverage under `build/reports/`)
  - `terraform/terratest/` — Go Terratest runner over `tests/terratest/*.go` (emits JUnit under `build/reports/`)
  - `terraform/test-all/` — unified orchestrator for the first two tiers; runs both when present, merges JUnits into `build/reports/junit-terra-all.xml`, exits `0` when neither tier has tests (stack-only repos)
  - `terraform/structural/` — third tier runner for `tests/structural.sh` (repo-convention assertions the consumer owns); emits `build/reports/junit-structural.xml` (empty-but-valid on skip). Runs on its own parallel job (`test:structural`) instead of through `test-all` because the shell tier is offline and deps-free and shouldn't block on the heavier tiers
  - `terraform/validate/` — fourth tier runner: `terraform init -backend=false` + `terraform validate` over every root module under `VALIDATE_ROOTS` (default `stacks`); emits `build/reports/junit-validate.xml` (empty-but-valid on skip). The only tier that RESOLVES references — the other three parse — so it is the only one that can see `Reference to undeclared module` / `Unsupported argument` in a root module. Runs on its own **opt-in** parallel job (`test:validate`), off by default because unlike its siblings it needs the network for provider downloads and, for private module sources, credentials
  - `terraform/tftest-gen/` — generator that emits `tests/smoke.tftest.hcl` for single-module repos; parses `variables.tf` + `main.tf` / `providers.tf` and emits `mock_provider` blocks plus validation-rejection runs
  - `terraform/tflint/install.sh` and `terraform/terra/install.sh` — pinned, checksum-verified installers that replaced the vendors' `curl … | sh` one-liners on all three platforms
  - `terraform/order-check/` — checks (and with `--fix` rewrites) the file-ordering standard across `environments/**/root.hcl`, `stacks/*/{variables,providers,outputs}.tf`, and `**/providers.tf`, and additionally reports **dead terragrunt inputs** (an `inputs = {}` key with no matching `variable` in the target stack — reported only, never auto-deleted); emits `build/reports/junit-order-check.xml`. Runs as the `order-check` / `style:order-check` job in the `10-code-check` stage. Stdlib-only `python3`; the `--fix` rewriter is round-trip-safe (parses to exact substrings, then only permutes). See Terraform Ordering Standard below
  - `terraform/var-catalog/` — stdlib-only `python3` generator that keeps ONE canonical body per shared `variable` in a per-repo `.terraform-var-catalog.hcl` and writes the subset each stack actually uses into `stacks/<stack>/variables-shared.tf` (the same generic-script/repo-data split as `order-check`). Output is **committed**, not emitted by a Terragrunt `generate` block, because the order-check dead-input scan, the `terraform validate` tier, and AST-based tests all read `stacks/**/*.tf` from the source tree without invoking Terragrunt. It writes a sibling file rather than appending to `variables.tf` (so generated content is exempt from the `// SET ON` marker rule yet still seen by the dead-input glob) and **never overwrites a hand-written declaration** — a stack that already declares a catalogued name keeps its body and is reported. `run.sh --check` is the CI gate (fails if the committed output is stale); `--report` prints changes without writing
- `global/scripts/deploy/` — MVP hosting providers for the `50-deployment` stage: `cloudflare/` (Pages + Workers via `wrangler`), `vercel/`, `render/` (REST API, no CLI exists), `netlify/`, `flyio/`. Each is wired identically on all three platforms; `common.sh` is sourced, not executed, and holds the shared helpers. See MVP Hosting Providers below
- `global/scripts/shared/` — Shared utilities (cleanup.sh, rebase-check.sh, changelog-check.sh, reconcile-releases.sh, terraform-provider-mirror.sh, **pinned-versions.sh**, **verify-download.sh**). The last two are sourced, never executed, and are the supply-chain contract: `pinned-versions.sh` is the single source of truth for every third-party binary version and its SHA-256, and `verify-download.sh` is the only sanctioned way to fetch one — see Supply-Chain Pinning below. `terraform-provider-mirror.sh` is sourced by the `terra-test` and `validate` tiers: it points `terraform init` at provider stores this machine already populated (`TF_PROVIDER_MIRROR_DIR`, `TERRA_PROVIDER_CACHE_DIR`, the terra CLI's `~/.cache/terra/providers`, then the tier's own `TF_PLUGIN_CACHE_DIR`) via a `filesystem_mirror`, so a mirrored provider costs no registry query and no github.com checksum fetch. Falls back to the origin registry per directory, so a cold machine still works and pays one fetch per provider version instead of one per directory. `TF_PROVIDER_MIRROR=off` disables it
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

Not every reusable workflow is a language pipeline. `reusable-claude-review.yaml` (automated
review on every pull request) and `reusable-claude-mention.yaml` (the `@claude`
mention responder) are standalone, like `dependency-updates.yaml` and
`update-major-version-tag.yaml` — `claude` is an agent, not a toolchain, so they
are listed in `STANDALONE` in `.github/tests/test-workflow-composition.sh` with
the reason spelled out there. The `reusable-` prefix marks a definition: every
caller, this repository's own included, drops it and is named
`claude-review.yaml` / `claude-mention.yaml`. Consumers pass `CLAUDE_CODE_OAUTH_TOKEN`
explicitly; `secrets: inherit` fails Semgrep's
`yaml.github-actions.security.secrets-inherit` rule.

### Supply-Chain Pinning

**Enforced by `.github/tests/test-supply-chain.sh` (`make test-supply-chain`), 27 assertions, every one of
them proven to fire against a deliberate violation.** Read this before adding an action, an image, or
anything that downloads a binary.

| What | Pinned to | Enforced by |
|------|-----------|-------------|
| Third-party GitHub Actions | 40-character commit SHA + trailing `# vX.Y.Z` comment | assertions 1-2 |
| Container images (`image:`, `FROM`) | `tag@sha256:<digest>` | assertions 3-4 |
| Downloaded binaries | exact version **and** a committed SHA-256 | assertions 6-12 |
| `go install` / `pip` / `gem` / `npx` | exact version | assertions 15-18 |

`global/scripts/shared/pinned-versions.sh` holds every version and digest; `verify-download.sh` is the
only sanctioned way to fetch a binary, and it DELETES an artifact whose checksum does not match rather
than merely reporting it — a later step that only tests for existence would otherwise install the thing
just rejected.

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
week** (Mon/Thu 06:00 UTC) and **fails the build** when anything is stale.

| Surface | Question asked | Discovered from |
|---------|----------------|-----------------|
| Actions | is there a newer release for `owner/repo`? | `uses: '…@<sha>' # vX.Y.Z` in every YAML |
| Images | does the pinned tag still resolve to this digest? | `image:` and Dockerfile `FROM` |
| Binaries / packages | is there a newer version upstream? | `# upstream:` annotations in `pinned-versions.sh` |
| Inline copies | do the two copies of a version still agree? | a fixed list of templates with no `SCRIPTS_DIR` |

Five decisions shape it; do not "simplify" any of them away:

| Decision | Why |
|----------|-----|
| **Images are checked by DIGEST, not by tag** | `python:3.13-slim` is rebuilt with patched system packages under the SAME tag, so "is there a newer tag" misses every security rebuild. "Does this tag still resolve to the bytes we pinned" catches all of them. Moving `3.13` → `3.14` is a decision, not an update, so no newest-tag search is attempted |
| **A failed lookup exits 2 and is never "up to date"** | ~40 of the lookups hit `api.github.com`, which allows 60 requests/hour unauthenticated. Treating a 403 as "current" would turn the whole check into a green light that inspected nothing — worse than not running it |
| **A pin with no `# upstream:` annotation FAILS** | Otherwise coverage shrinks one forgotten annotation at a time while the job stays green. The annotation lives next to the pin so adding one without the other is visible in review |
| **`track=<major>` exists for deliberately-held pins** | GoReleaser is on 1.x because 2.x is a breaking config change. Without it the check would report that migration as an update on every run, forever, until somebody muted the job |
| **It fails the build; it does not open a PR** | An automated bump would have to re-resolve a commit SHA, re-fetch a checksum from an upstream manifest and re-resolve an image digest before it could even be correct, and a wrong one of those is a supply-chain change nobody reviewed. A red build with a diff-ready list keeps the decision with a person |

`.dependency-updates.json` (`{"ignore": ["glob", …]}`) silences a reference. It
is empty by default and is meant for genuinely ROLLING tags such as
`alpine:edge`, which is rebuilt almost daily — a check that is always red stops
being read.

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

**Enforced by `.github/tests/test-workflow-composition.sh` (`make test-workflow-composition`), twelve
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

**Job names are an API, not a label.** `delivery > <target>` and `deployment > <provider>` are the
strings consumers pass to `require-checks`, because GitHub composes a check's name from the calling
job and the called workflow's job. Renaming a job renames a check for everyone downstream.

**A `STANDALONE` workflow is exempt from the composition rules, not from every rule.** The two Claude
reusables are listed there, so the naming, delegation and suffix assertions skip them by design —
which left their wiring asserted by nothing at all. The last two assertions cover what that exemption
leaves behind, and both read the PARSED document (YAML 1.1 resolves `on:` to the boolean `true`, so no
indentation rule can reach under it) — which is why this suite needs PyYAML at all, and why it says so
by name rather than dying when it is absent.

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

Seven constraints shape this; `make test-dependency-track` asserts all of them:

| Constraint | Why |
|------------|-----|
| **A merge/pull request never uploads** | A PR whose version file is already bumped mints that version's project BEFORE the merge, and keeps it if the merge never happens — the largest single source of sprawl. Gated in the SHARED SCRIPT, not per-platform YAML, so a consumer pinned to an older template revision gets it and so the suite can exercise it offline. Only a POSITIVELY identified PR is skipped: "I could not tell" must not silently mean "nothing was recorded" |
| **`isLatest` is claimed only for a default branch or tag** | At most one version per name carries it, and a collection project with `AGGREGATE_LATEST_VERSION_CHILDREN` reads its metrics from that child. Asserting it every run moved the flag backwards onto older versions, so the parent reported a risk score belonging to the wrong version |
| **Azure DevOps and GitHub Actions cannot report their own default branch** | `Build.Repository.DefaultBranch` **does not exist** (`Build.Repository.*` is Name, Uri, Provider, ID, LocalPath, Clean, Tfvc.Workspace, Git.SubmoduleCheckout). A condition comparing against it tests an empty string, is always false, and silently disables every upload. GitHub exposes the default branch only through `github.event.repository`, not the environment. `DEPENDENCY_TRACK_DEFAULT_BRANCH` supplies it; without it those platforms upload but do not claim the flag. Two assertions stop the non-existent variable being reintroduced |
| **`parentName` only parents projects being CREATED** | `BomResource.uploadBom` resolves the parent solely inside `if (project == null && autoCreate)` — same in `4.14` and 5.0.5. For an existing project both parent fields are read and ignored, with no error and nothing in the response to notice. Adopting an existing portfolio needs `PATCH /api/v1/project/{uuid}` from an administrative job |
| **`jq -r` prints the STRING `null` for a missing key** | And `null` is a valid project name, so a BOM without `metadata.component` created a project literally called `null` and kept updating it. Extraction uses `// empty`; a missing name fails the job, a missing *version* uploads versionless (one stable identity, better than one pinned to `null`) |
| **The API key is never on argv** | argv is world-readable through `ps` and `/proc/<pid>/cmdline`, which on a shared or self-hosted runner means every other job on that host. The header goes in through `curl --config -` on stdin — same posture as `global/scripts/deploy/render/run.sh`, same reasoning as `-DnvdApiKeyEnvironmentVariable` |
| **There is exactly ONE implementation** | The GitLab abstract used to inline its own `curl` that skipped the `sed 's\|/\|-\|g'` name normalisation and sent no `isLatest`, so a scoped npm package became TWO projects depending on which platform built it. Separately, the GitLab **Go** job defined its own `script:` — and GitLab's `extends` REPLACES `script:` rather than appending — so it generated a BOM and threw it away, green, forever |

**GitHub Actions has no `35-management` stage at all** (`github/global/stages/` goes 20 → 40), so it has no
Dependency-Track job to wire. That is a pre-existing gap, not something this uploader can paper over; adding
the stage is its own piece of work.

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
| **OSV-Scanner replaces OWASP Dependency-Check** | Dependency-Check has no pub analyzer. OSV-Scanner queries the Pub advisory database directly and is the ONLY dependency scanner Dart has here. Exit code 128 ("no packages found") is mapped to success — a lockfile with only SDK dependencies produces it, and the safest possible dependency set must not be a red job |
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
- **Mandatory updates**: a changelog fragment (`chlog new --kind <Kind> --body "..."` — never edit
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
  `chlog new --kind <Kind> --body "<imperative description>"`
- Valid kinds: Added, Changed, Deprecated, Removed, Fixed, Security
- Choose the kind that best matches the change (e.g., new feature → Added,
  bug fix → Fixed, behavior change → Changed, removal → Removed, security fix → Security).
- If the change is backward-INCOMPATIBLE with the public API (a breaking
  change), you MUST add the `--breaking` flag:
  `chlog new --kind <Kind> --breaking --body "<description>"`.
  This is the ONLY thing that triggers a major version bump — the kind alone
  never does (per SemVer, major = incompatible change). When unsure whether a
  change breaks compatibility, ask the user instead of guessing.
- Fragments are YAML files in `.changes/unreleased/`; stage them with your commit.
- `chlog check` fails the build when a fragment is missing — never skip it.
<!-- chlog:end -->
