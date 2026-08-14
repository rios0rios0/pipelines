# GitHub Actions -- Flutter with Artifact Delivery Example

Minimal example showing how to use the reusable Flutter workflow from `rios0rios0/pipelines`.

## Files

| File                        | Purpose                                                    |
|-----------------------------|------------------------------------------------------------|
| `.github/workflows/ci.yaml` | Calls the reusable `flutter-artifacts.yaml` workflow       |
| `Makefile`                  | Local development with pipeline tools via `makefiles/`     |

## Setup

1. Copy `.github/workflows/ci.yaml` into your repository.
2. Push to `main` or open a pull request to trigger the pipeline.

No SDK setup step is needed. The pipeline detects Dart vs Flutter from your
`pubspec.yaml` and installs the matching SDK from Google's release archive.

## Local Development

```bash
# First-time setup -- clone the pipelines repository
curl -sSL https://raw.githubusercontent.com/rios0rios0/pipelines/main/clone.sh | bash

# Then use the Makefile targets
make lint       # dart format --fix, dart analyze, unused-code scan
make test       # flutter test with coverage -> JUnit + Cobertura + LCOV
make sast       # Semgrep, Trivy, Hadolint, ShellCheck, Gitleaks, OSV-Scanner
make sca        # OSV-Scanner over pubspec.lock only
make build      # flutter build apk (override with DART_BUILD_TARGETS)
```

## What the Pipeline Does

1. **Code Check** -- `dart format`, `dart analyze`, unused-code/files scan
2. **Security** -- Semgrep, Gitleaks, Hadolint, Trivy (IaC + SCA), OSV-Scanner
3. **Tests** -- `flutter test` with coverage, published as JUnit + Cobertura
4. **Management** -- CycloneDX SBOM published as a job artifact
5. **Delivery** -- web bundle and Android APK/AAB as downloadable artifacts

## Two Tools Are Missing, On Purpose

| Tool        | Why it is absent                                                                                                                                             |
|-------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **CodeQL**  | Has no Dart extractor ([dart-lang/sdk#52953](https://github.com/dart-lang/sdk/issues/52953)). A CodeQL job on a Dart repository can only fail.                |
| **`p/dart` Semgrep pack** | The Semgrep Registry publishes no Dart rules. The pipeline ships [its own Dart ruleset](../../../global/scripts/tools/semgrep/rules/dart.yaml) instead. |

`dart analyze` and the shipped Semgrep rules together cover what those two would
have. See the repository README's *Dart & Flutter Tool Coverage* section for the
full matrix.

## Useful Inputs

| Input              | Default | Purpose                                                    |
|--------------------|---------|------------------------------------------------------------|
| `flutter_version`  | current stable | Pin an exact SDK version for reproducible builds    |
| `build_web`        | `true`  | Build the web bundle                                       |
| `build_android`    | `true`  | Build Android artifacts                                    |
| `android_targets`  | `apk appbundle` | APK for QA sideloading, AAB for Google Play         |

## Building an iOS Archive

`ipa` is not part of this workflow: it needs a `macos-latest` runner and a
signing identity that belongs to your project, not to a shared template. Add:

```yaml
  delivery-ios:
    runs-on: 'macos-latest'
    steps:
      - uses: 'rios0rios0/pipelines/github/dart/stages/40-delivery/build@main'
        with:
          toolchain: 'flutter'
          targets: 'ipa'
```

The runner builds it with `--no-codesign`; add your own signing step afterwards.
