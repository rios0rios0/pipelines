# GitLab CI -- Dart Package (pub.dev) Example

Minimal example showing how to use the Dart library template from
`rios0rios0/pipelines` on GitLab CI.

## Files

| File            | Purpose                                                  |
|-----------------|----------------------------------------------------------|
| `.gitlab-ci.yml`| Includes the remote `gitlab/dart/dart-library.yaml`      |
| `Makefile`      | Local development with pipeline tools via `makefiles/`   |

## Setup

1. Copy `.gitlab-ci.yml` into your repository root.
2. Add the CI/CD variables listed at the bottom of that file.
3. Push to your default branch or open a merge request.

The SDK is installed by the pipeline from Google's release archive and cached in
`$CI_PROJECT_DIR/.sdk`, so no runner image with Dart preinstalled is needed.

## Local Development

```bash
curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash

make lint       # dart format --fix, dart analyze, unused-code scan
make test       # dart test with coverage -> JUnit + Cobertura + LCOV
make sast       # Semgrep, Hadolint, ShellCheck, Gitleaks, OSV-Scanner
make cyclonedx  # CycloneDX SBOM at build/reports/bom.json
```

## Publishing

`publish:validate` runs on every merge request and default-branch build and does
**not** upload anything -- it runs the same validation pub.dev performs at upload
time. `publish:prod` runs only on a tag and needs `PUB_TOKEN` as a **masked and
protected** variable.

The token is never passed on the command line: the runner hands
`dart pub token add` the variable's *name* (`--env-var PUB_TOKEN`) and pub reads
the value from the environment.

For a self-hosted pub server, set `PUB_HOSTED_URL`.

## Coverage in the Merge Request Widget

Dart emits coverage as LCOV only. The test runner converts it to Cobertura (with
a dependency-free converter shipped in this repository) so GitLab renders
per-line coverage in the MR diff, and prints `COVERAGE_PERCENT=NN.NN%` for the
job's `coverage:` regex.
