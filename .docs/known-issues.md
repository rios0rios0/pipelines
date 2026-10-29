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
| [KI-02](#ki-02--gitlab-ci-cannot-start-codeql-in-the-default-image) | `gitlab/global/stages/20-security/codeql.yaml`, `sast:codeql` | GitLab CI cannot start CodeQL in the default image | Fixed for Go; open for the other languages |
| [KI-03](#ki-03--the-go-autobuild-runs-the-default-goal-of-a-consumer-makefile) | `global/scripts/tools/codeql/run.sh` and the `20-security/codeql` action, Go | The Go autobuild runs the default goal of a consumer Makefile | Won't fix |

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

- **Where:** `gitlab/global/stages/20-security/codeql.yaml`, job `sast:codeql`. It extends
  `.scripts-repo-alpine-docker` and sets no `image:`, so it runs in the pipeline's default image,
  `docker:24.0.3` (`gitlab/global/abstracts/default-image.yaml`). Every GitLab CI entry template
  includes that default.
- **What happens:**
  - `docker:24.0.3` is Alpine Linux, which uses musl. The CodeQL bundle's Java runtime is linked
    against glibc, so the launcher cannot start it. Reproduced on 2026-10-29 by running the job's
    steps in that image with the pinned `codeql-bundle-v2.27.3`:
    `codeql: line 149: .../codeql/tools/linux64/java/bin/java: not found`, then
    `ERROR: 'codeql database create' failed`.
  - The job has no `allow_failure`, so it fails the pipeline for every language that includes it:
    Go, Java, Python, JavaScript and C#. Nothing is analysed.
- **Fixed for Go:** `gitlab/golang/stages/20-security/go.yaml` overrides the job onto `.go`, the
  `golang:<pinned>-bookworm` image the other Go jobs use, and installs `jq` for the gate. Reproduced
  in that image: a cold install of the pinned bundle, then a `go 1.27.3` module whose command
  injection the gate reports and fails on.
- **The fix for the rest:**
  - Python and JavaScript need no build, so any glibc image with `git`, `jq` and `curl` would do.
    Give the shared job one, pinned by digest.
  - Java and C# build the code, so their stages should move the job onto their own toolchain
    images, as the Go stage does.
- **How to prove it:** the Docker reproduction above, per language, and an assertion like the
  GitLab half of section 3c of `.github/tests/test-go-module-toolchain.sh`.
- **Status:** Fixed for Go. Open for Java, Python, JavaScript and C#.

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
