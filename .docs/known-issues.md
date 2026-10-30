# Known issues

This page lists the defects that consuming repositories have observed in the shared workflows, and
that are not fixed yet. Each entry says:
- what happens, with the evidence;
- where it lives, as `path` and job;
- the fix it needs;
- its status.

It exists so that a defect someone has already diagnosed is written down where the next reader of
the workflow looks, instead of in one consumer's notes. When an entry is fixed, set its **Status**
to `Fixed in #<PR>` and keep the entry: the history is why the workflow is the way it is.

Security defects are never described here, because this repository is public. Report them
privately and fix them.

| ID | Workflow and job | Issue | Status |
|---|---|---|---|
| [KI-01](#ki-01--the-dart-test-job-has-no-timeout) | `.github/workflows/dart.yaml`, `tests > test:all` | The Dart test job has no timeout | Open |
| [KI-02](#ki-02--gitlab-ci-cannot-start-codeql-in-the-default-image) | `gitlab/global/stages/20-security/codeql.yaml`, `sast:codeql` | GitLab CI cannot start CodeQL in the default image | Fixed in #775 |
| [KI-03](#ki-03--the-go-autobuild-runs-the-default-goal-of-a-consumer-makefile) | `global/scripts/tools/codeql/run.sh` and the `20-security/codeql` action, Go | The Go autobuild runs the default goal of a consumer Makefile | Won't fix |
| [KI-04](#ki-04--gitlab-cis-debian-11-images-can-no-longer-install-packages) | `gitlab/javascript/abstracts/npm.yaml`, `gitlab/javascript/abstracts/yarn.yaml`, `gitlab/java/abstracts/maven.yaml` | GitLab CI's Debian 11 images can no longer install packages | Fixed in #775 |
| [KI-05](#ki-05--gitlab-cis-javascript-images-run-a-nodejs-past-its-end-of-life) | `gitlab/javascript/abstracts/npm.yaml`, `gitlab/javascript/abstracts/yarn.yaml` | GitLab CI's JavaScript images run a Node.js past its end of life | Fixed in #775 |

## KI-01 — The Dart test job has no timeout

- **Where:** `.github/workflows/dart.yaml`, job `tests-test_all` (`name: 'tests > test:all'`, around
  line 220). Its sibling `tests-test_build` sets none either.
- **What happens:**
  - A Flutter suite that stops progressing holds its runner until GitHub's six-hour cap.
  - `flutter test --machine` streams nothing to the job log until the step ends, so a slow run and
    a stuck one look the same from outside.
  - On 2026-10-06, a consumer's push run sat 1h39m in `flutter test --machine` on a self-hosted
    runner until it was cancelled by hand. The same suite takes about ten minutes on a developer
    machine, and earlier healthy runs took 10 to 30.
  - The consumer's deploy workflow keeps one pending run per concurrency group. Every newer push
    was cancelled in favour of the next, and the last one waited behind the stuck run, so four
    merges were not deployed until the stuck run was cancelled.
- **Why it matters:** other jobs here bound themselves. The Java dependency-check job sets
  `timeout-minutes: 45` (`gradle.yaml` and `maven.yaml`, around line 121, with the reasoning in the
  comment above it), and CodeQL sets 30 (`codeql.yaml`, around line 56). The Dart test job is the
  long-running job that does not.
- **The fix:**
  - Set `timeout-minutes` on `tests-test_all`, and on `tests-test_build` if its slowest healthy run
    warrants it. Size it from the slowest healthy run on the self-hosted fleet, with headroom:
    about 60 minutes for `test:all`, given the 10 to 30 minutes observed under load.
  - Consider an input such as `test_timeout_minutes`, so a consumer with a larger suite can widen
    it without forking the workflow.
  - A timed-out job must fail red with the timeout as its cause, never pass.
- **How to prove it:** a structural test in `.github/tests/` that asserts every long-running job of
  the language workflows sets `timeout-minutes`, the way `test-workflow-composition.sh` asserts the
  workflows' shape.
- **Status:** Open.

## KI-02 — GitLab CI cannot start CodeQL in the default image

- **Where:** `gitlab/global/stages/20-security/codeql.yaml`, job `sast:codeql`. It extended
  `.scripts-repo-alpine-docker` and set no `image:`, so it ran in the pipeline's default image,
  `docker:24.0.3` (`gitlab/global/abstracts/default-image.yaml`). Every GitLab CI entry template
  includes that default.
- **What happened:**
  - `docker:24.0.3` is Alpine Linux, which uses musl. The CodeQL bundle's Java runtime is linked
    against glibc, so the launcher cannot start it. Reproduced on 2026-10-29 by running the job's
    steps in that image with the pinned `codeql-bundle-v2.27.3`:
    `codeql: line 149: .../codeql/tools/linux64/java/bin/java: not found`, then
    `ERROR: 'codeql database create' failed`.
  - On a runner the job did not get that far. The image has no `curl`, and BusyBox's `wget` rejects
    the `--https-only` that `verify-download.sh` passes, so a cold job stopped at
    `wget: unrecognized option: https-only`, then `ERROR: failed to download` the bundle.
    Reproduced on 2026-10-29 with the job's own commands, for the Python and C# templates.
  - The job has no `allow_failure`, so it failed the pipeline for every language that includes it:
    Go, Java, Python, JavaScript and C#. Nothing was analysed.
- **Fixed for Go in #769:** `gitlab/golang/stages/20-security/go.yaml` overrides the job onto `.go`,
  the `golang:<pinned>-bookworm` image the other Go jobs use, and installs `jq` for the gate.
  Reproduced in that image: a cold install of the pinned bundle, then a `go 1.27.3` module whose
  command injection the gate reports and fails on.
- **Fixed for the rest:**
  - The shared job's default moved to the abstract it extends, `.codeql-runtime`: the pinned
    `python:3.13-slim` image `sast:semgrep` and `sast:gitleaks` run in, plus `git`, `jq` and `curl`.
    The default sits on the abstract, not on the job, because an `image:` on the job would outrank
    the image an override takes through `extends`. Python runs there unchanged: its extractor needs
    a Python 3 and builds nothing. So does a language no template analyses yet whose extractor needs
    only glibc: a Ruby analysis run there, with no override, found its planted command injection.
  - JavaScript runs in the same image and installs `nodejs`: the extractor parses TypeScript with
    Node.js, and without it stops at `Could not start Node.js. It is required for TypeScript
    extraction.` The JavaScript jobs' own images could not be used: `.yarn` and `.npm` were Debian 11,
    whose security updates left the Debian mirrors when its LTS ended (the index still lists them,
    the packages answer 404, `archive.debian.org` serves them), so `apt-get install jq` failed there
    (KI-04 has since moved them off Debian 11, and KI-05 to Node 24; `.yarn` still runs as an
    unprivileged user).
  - Gradle moves to `gradle:8.7.0-jdk21`, the glibc build of `.gradle`'s Gradle and JDK, keeping
    `.gradle`'s runner tags. `.gradle`'s own image is Alpine; with the image's musl JDK as
    `CODEQL_JAVA_HOME` the CLI starts, but the build cannot, because CodeQL's build tracer
    `preload_tracer` is glibc too (`error=2, No such file or directory`).
  - Maven moves to `maven:3.8.8-eclipse-temurin-11`, `.maven`'s Maven 3.8 and JDK 11 on Ubuntu
    22.04: `.maven` was Debian 11 as well (KI-04 has since moved `.maven` itself to that image, and
    the job takes it from there). The Maven entry template had never loaded: since
    2023-10-02 it included `java/stages/2-security/` and `3-tests/` paths, and its security stage
    `global/stages/2-security.yaml`, none of which exist, so GitLab refused the whole pipeline.
  - C# runs in `.sdk` without building (`CODEQL_BUILD_MODE: 'none'`). The GitLab .NET templates build
    .NET Framework projects on Windows runners, and on Linux the C# autobuilder stops at
    `MSB3644: The reference assemblies for .NETFramework,Version=v4.8 were not found`, then
    `Could not auto-detect a suitable build method`. Without a build, the planted finding is found in
    an old-style .NET Framework project and in an SDK-style one alike.
  - Two defects in what every language shares, found on the way. `run.sh` now recreates the report
    directory before `database analyze`: the Java autobuilder runs Gradle's `clean`, which deletes
    `build/`, so a Gradle analysis on a CI runner ended in `Could not write SARIF file`. And the
    job's report path gained the per-tool directory `run.sh` has written into since 2026-02-17.
- **How it was proven:** each language's job run in Docker in its pinned image, with the job's own
  `before_script` and `script` as `.github/tests/test-codeql-runtime.sh` resolves them, its own
  `.scripts-repo` clone and a cold install of the pinned bundle (served from a local copy instead of
  the network, and checked by `run.sh` against the committed digest): a project with a planted
  finding fails the gate (exit 1) and a clean one passes it (exit 0), for Go, Python, JavaScript
  (TypeScript), Java with Gradle and with Maven, and C#, SDK-style and .NET Framework.
  `make test-codeql-runtime` holds the templates to it.
- **Status:** Fixed in #775.

## KI-03 — The Go autobuild runs the default goal of a consumer Makefile

- **Where:** every Go CodeQL job: `run.sh` (GitLab CI, Azure DevOps and `make codeql`) and the
  `github/global/stages/20-security/codeql` action's Autobuild step.
- **What happens:**
  - CodeQL's Go autobuilder runs `make` with no target wherever a `Makefile` exists, before it builds
    the module itself (`go/extractor/autobuilder/autobuilder.go`). It has no switch to turn this off.
  - A consumer Makefile that follows this repository's include pattern includes `common.mk` before
    its own targets. When those includes resolve, the default goal is `common.mk`'s first target,
    `setup`, which clones or fast-forwards `PIPELINES_HOME`, by default
    `~/Development/github.com/rios0rios0/pipelines`. They resolve wherever `SCRIPTS_DIR` points at a
    checkout: `run.sh` exports it, and a developer's machine has the default path.
  - Observed on 2026-10-29: a `make codeql` reproduction logged
    `Updating pipelines repository at ...` from inside `codeql database create`. On a GitLab CI or
    Azure DevOps runner that is a full `git clone` of this repository into the runner's home on
    every Go analysis, or a pull of the clone an earlier job left on a persistent runner. On a
    developer's machine it is a `git pull --ff-only` of their own checkout, which may be the one
    the scan is running its scripts from.
  - On GitHub Actions the composite exports no `SCRIPTS_DIR`, the includes are skipped, and the
    consumer's first own target runs. For most consumers that is a `go build`, as intended.
  - The analysis itself is unaffected: a failed `make` is logged and skipped.
- **The fix it needs:** end `common.mk` and each language fragment with `.DEFAULT_GOAL :=`. GNU make
  then takes the next target it reads, the consumer's first own target, as the default goal. That
  changes what a bare `make` does in every consumer, so it needs its own change and changelog entry.
- **Status:** Won't fix. On 2026-10-29 the owner decided not to change the default goal of the shared
  makefiles: a bare `make` keeps meaning what it means in every consumer today, and the cost above
  stays. Do not propose `.DEFAULT_GOAL :=` again without a new reason.

## KI-04 — GitLab CI's Debian 11 images can no longer install packages

- **Where:** three GitLab CI abstracts ran Debian 11 ("bullseye") images: `.npm`
  (`node:16.14.0-bullseye`, `gitlab/javascript/abstracts/npm.yaml`), `.yarn`
  (`node:18.17.1-bullseye`, `gitlab/javascript/abstracts/yarn.yaml`) and `.maven`
  (`maven:3.8-jdk-11-slim`, `gitlab/java/abstracts/maven.yaml`). Two jobs on them install packages:
  `report:dependency-track` (`gitlab/javascript/stages/35-management/npm-yarn.yaml`,
  `apt install ... curl jq git`) and the Maven `sca:dependency-check`
  (`gitlab/java/stages/20-security/maven.yaml`, through `.scripts-repo-debian`).
- **What happened:**
  - Debian 11's LTS ended, and its security updates left the Debian mirrors: on 2026-10-29
    `deb.debian.org` and `security.debian.org` still served a `bullseye-security` index (dated
    2026-09-12) listing `jq 1.6-2.1+deb11u3`, while the package itself answered 404 there and 200 on
    `archive.debian.org`.
  - So any `apt-get install` that reaches an updated package fails, in both images:
    `E: Failed to fetch http://security.debian.org/debian-security/pool/updates/main/j/jq/jq_1.6-2.1%2bdeb11u3_amd64.deb  404  Not Found`,
    then `E: Unable to fetch some archives`. Reproduced on 2026-10-29 with `apt-get install jq` in
    `.npm`'s image and `apt-get install git jq` in `.maven`'s.
  - `report:dependency-track` therefore could not upload an SBOM, and `sca:dependency-check` failed
    before scanning (it is `allow_failure: true`, so the pipeline stayed green). Run with the jobs'
    own commands, both stopped at the install, exit 100, the first on `curl`'s security update.
  - The CodeQL jobs could not use these images for the same reason: KI-02.
- **Fixed:** each abstract moved to a supported base, pinned by digest, keeping its toolchain:

  | Abstract | Before | After |
  |---|---|---|
  | `.npm` | `node:16.14.0-bullseye`: Node 16.14.0, npm 8.3.1, Yarn 1.22.17 | `node:16.20.2-bookworm`: Node 16.20.2, npm 8.19.4, Yarn 1.22.19 |
  | `.yarn` | `node:18.17.1-bullseye`, by tag only: Node 18.17.1, npm 9.6.7, Yarn 1.22.19 | `node:18.17.1-bookworm`, by digest: the same three |
  | `.maven` | `maven:3.8-jdk-11-slim`: Maven 3.8.6, OpenJDK 11.0.16, no `git` | `maven:3.8.8-eclipse-temurin-11` (Ubuntu 22.04): Maven 3.8.8, Temurin 11.0.21, `git` |

  Node 16.14.0 was never built on Debian 12, so `.npm` takes 16.20.2, the last Node 16. The Maven
  `sast:codeql` now runs in `.maven`'s image, which is the image it was already pinned to. `.yarn`
  had been the one image of these pipelines pinned by tag alone, and `.sonarqube`'s
  `sonar-scanner-cli:latest` was another, both in the `image:` mapping form that
  `test-supply-chain.sh` did not read: both are pinned now (the scanner to the build every other
  platform runs), and the suite reads that form.
- **How it was proven:** each job run in Docker in its new image, with its own commands as
  `.github/tests/test-codeql-runtime.sh` resolves them:
  - `report:dependency-track` installed `curl`, `jq` and `git` from Debian 12, generated the
    CycloneDX BOM of an npm project and uploaded it, exit 0. The server was a stub answering 200.
  - `sca:dependency-check` installed `git` and `jq`, built its database from the NVD datafeed,
    scanned a Maven project and reported `CVE-2015-6420` in `commons-collections` 3.2.1, exit 0.
  - The abstracts' other jobs pass on them: the Maven `test:all` (tests, the JaCoCo summary,
    `mvn verify`), the Yarn `style:eslint`, `style:format`, `test:all`, `test:build` and
    `sca:yarn-audit` over a Yarn 4 project, and the Maven `sast:codeql`.
  - Section 7 of `make test-codeql-runtime` fails on any GitLab CI image marked Debian 11, and keeps
    the two jobs on an image where `apt-get` works.
- **Status:** Fixed in #775.

## KI-05 — GitLab CI's JavaScript images run a Node.js past its end of life

- **Where:** `.npm` (`gitlab/javascript/abstracts/npm.yaml`) runs Node 16 and `.yarn`
  (`gitlab/javascript/abstracts/yarn.yaml`) Node 18. Every job of the GitLab CI JavaScript pipeline
  runs on one of them: `.yarn` for the code check, the tests and the audit, `.npm` for
  `report:dependency-track`. Azure DevOps runs these jobs on Node 20.20.2, and GitHub Actions on the
  `node_version` input, `20` by default.
- **What happens:**
  - Node 16 reached its end of life on 2023-09-11, and Node 18 on 2025-04-30: neither gets security
    fixes. KI-04 moved both images to Debian 12 and kept their Node, deliberately.
  - `quality:knip` cannot run on Node 18: knip 6.42.1 requires `^20.19.0 || >=22.12.0`, so `npx`
    stops at `EBADENGINE` and the job fails, on the old image and the new one alike. It is
    `allow_failure: true`, so nothing shows it.
- **Fixed:** every Node.js these templates choose moved to Node 24 ("Krypton"), supported until
  2028-04-30:

  | Platform | Where | Before | After |
  |---|---|---|---|
  | GitLab CI | `.npm`: `report:dependency-track` | `node:16.20.2-bookworm`: Node 16.20.2, npm 8.19.4, Yarn 1.22.19, corepack 0.17.0 | `node:24.22.1-trixie` (Debian 13), by digest: Node 24.22.1, npm 11.19.1, Yarn 1.22.22, corepack 0.36.0 |
  | GitLab CI | `.yarn`: code check, tests, audit, `report:sonarqube` | `node:18.17.1-bookworm`: Node 18.17.1, npm 9.6.7, Yarn 1.22.19, corepack 0.18.0 | the same image, as the `node` user |
  | Azure DevOps | `corepack-node-no-cache.yaml` and the CodeQL `PRE_STEPS` | `UseNode@1` 20.20.2: npm 10.8.2, corepack 0.34.6 | `UseNode@1` 24.22.1: npm 11.19.1, corepack 0.36.0 |
  | GitHub Actions | the CodeQL composite's `setup-node` | `node-version: '20'` | `node-version: '24'` |
  | GitHub Actions | the `node_version` default of `npm.yaml`, `yarn.yaml`, `yarn-cloudflare.yaml` and the `format` and `knip` composites | `'20'` | `'24'` |

  Yarn is whatever each project pins: the images' Yarn 1 hands a project's `yarnPath` release its
  commands, and on Azure DevOps `corepack prepare yarn@stable --activate` installs the newest
  stable release (4.18.1 on 2026-10-30) before and after alike.
  Not Node 26, although it became LTS on 2026-10-28: Node 25 dropped corepack from its
  distribution, and neither the `node:26.13.0-trixie` image nor the 26.13.0 tarball `UseNode@1`
  installs ships it -- the image ships no `yarn` either -- so every `.yarn` job and Azure DevOps'
  `corepack enable` would fail on it.
  The GitHub Actions `node_version` input defaults moved too, from `20` to `24`: `npm.yaml`,
  `yarn.yaml` and `yarn-cloudflare.yaml`, and the `format` and `knip` composites, so a consumer who
  leaves the input unset now builds on Node 24 and one who needs another major names it. Left as
  they were: the deployment templates' Node 22, supported until 2027-04-30.
  The release is 24.22.1 rather than the newer 24.22.2: 24.22.1 (2026-10-21) is the security
  release that fixed the eight advisories 24.22.0 carries, and 24.22.2 fixes nothing more and was
  a day old, inside the dependency update's 7-day cooldown.
  And the pins no longer stay where this left them. A tag naming one release stops being rebuilt
  once the next ships, so its digest never moves again and the digest check has nothing to report:
  that is how `.npm` stayed on Node 16.14.0. The GitLab CI images and the Azure DevOps `UseNode@1`
  inputs now follow `NODE_PINNED_VERSION` in `global/scripts/shared/pinned-versions.sh`, held to
  the 24 line, which the scheduled dependency update moves: to a new release once it is a week
  old, and at once to one fixing a known vulnerability (advisories from OSV's Bitnami feed).
- **What a consumer may notice:** a project's own scripts now run on Node 24. One that runs the
  test runner over a directory, `node --test test/`, stops working: Node 21 and later read the
  arguments as files and glob patterns, and load `test/` as a module (`Cannot find module
  '/builds/project/test'`). `node --test test/*.test.mjs`, which the shell expands, works on every
  Node.
- **How it was proven:** each job run in Docker in the new image, with its own commands as
  `.github/tests/test-codeql-runtime.sh` resolves them, for `yarn-docker.yaml` and
  `yarn-docker-k8s-deployment.yaml` alike:
  - `style:eslint`, `style:format`, `sca:yarn-audit`, `test:build`, `report:sonarqube` (its
    `yarn sonar` a stub, since the scanner needs a server) and `report:dependency-track` (the SBOM of an
    npm project uploaded to a stub server) exit 0 over a Yarn 4 project.
  - `quality:knip` now runs: on Node 18 it stopped at `EBADENGINE` before reading anything; on
    Node 24 it reports a project's unused file and dependency (exit 1) and passes a clean one
    (exit 0). `test:all` passes once the project's test script names its files.
  - Azure DevOps: the official 24.22.2 tarball, checked against `SHASUMS256.txt`, on Ubuntu 24.04
    as an unprivileged user, ran the abstract's `corepack enable` and `corepack prepare` (Yarn
    4.18.1), then the `quality:knip` install and knip, `yarn npm audit`, lint, tests and build.
  - Section 8 of `make test-codeql-runtime` fails on any Node.js a template names that is past its
    end of life, on an odd line, or on a line with no recorded date.
  - These runs used 24.22.2, the newest release when they were made. The pins name 24.22.1, whose
    image ships the same npm 11.19.1, Yarn 1.22.22 and corepack 0.36.0 on the same Debian 13.7, so
    only Node's own fixes differ.
- **Status:** Fixed in #775.
