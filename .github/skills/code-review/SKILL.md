---
name: code-review
description: "Review pull requests and diffs in pipelines — the shared SDLC pipeline templates and scripts for GitHub Actions, GitLab CI and Azure DevOps — against the rios0rios0/guide standards, with extra weight on the non-negotiable supply-chain pinning rules and the fact that every change here runs in every consumer repository. Use when reviewing a PR, a branch, or staged changes here."
---

# Code review — `pipelines`

`pipelines` provides the reusable workflows, stage templates, shell scripts, and Makefiles that every other repository consumes through `make lint`, `make test`, and `make sast`. A defect here breaks or silently weakens CI everywhere at once, which is why the pinning rules below are absolute.

## When to use this skill

Use it whenever you are asked to review a pull request, a diff, a branch, or staged changes
in this repository — and before opening a pull request of your own, as a self-check. It is a
**review** skill: it produces findings, not commits.

## Source of truth

The canonical engineering standards live in the
**[rios0rios0/guide wiki](https://github.com/rios0rios0/guide/wiki)**. This file is a
repo-tailored index into that guide plus the rules that only apply here. Precedence, highest
first:

1. This repository's `.github/copilot-instructions.md`, `CLAUDE.md`, and `CONTRIBUTING.md` —
   they describe *this* codebase and its load-bearing invariants.
2. The **rios0rios0/guide** wiki — the shared standard.
3. General language idiom.

When the guide and a general convention disagree, the guide wins. When this file and the
guide disagree, the guide wins and this file should be corrected in the same pull request.

### Guide pages that apply here

| Topic | Page |
|-------|------|
| YAML Conventions — `.yaml`, single quotes, unquoted scalars | [YAML](https://github.com/rios0rios0/guide/wiki/YAML) |
| Mapper Design Pattern — replacing `switch`/`case` | [Mapper-Design-Pattern](https://github.com/rios0rios0/guide/wiki/Mapper-Design-Pattern) |
| Git Flow — branches, commits, SemVer, breaking changes | [Git-Flow](https://github.com/rios0rios0/guide/wiki/Git-Flow) |
| Documentation & Change Control — changelog and docs discipline | [Documentation-&-Change-Control](https://github.com/rios0rios0/guide/wiki/Documentation-&-Change-Control) |
| CHANGELOG Formatting — capitalisation and backticks | [CHANGELOG-Formatting](https://github.com/rios0rios0/guide/wiki/CHANGELOG-Formatting) |
| Security — OWASP checklist, secret hygiene, SAST | [Security](https://github.com/rios0rios0/guide/wiki/Security) |
| CI & CD — pipeline stages and the local quality gates | [CI-&-CD](https://github.com/rios0rios0/guide/wiki/CI-&-CD) |
| Code Style — baseline naming and the operations vocabulary | [Code-Style](https://github.com/rios0rios0/guide/wiki/Code-Style) |

## How to run the review

1. **Establish the range.** Resolve the default branch with
   `git symbolic-ref refs/remotes/origin/HEAD` (strip `refs/remotes/origin/`; fall back to `main`),
   then read the diff with `git diff <default>...HEAD` and the file list with
   `git diff <default>...HEAD --name-only`.
2. **Read whole files, not just hunks.** A hunk cannot show a layering violation, a missing
   test, or a duplicated helper. Open every changed file in full, plus the files it imports
   from the layer below.
3. **Check the change set as a unit** — not only the code. A change that alters behaviour,
   configuration, or architecture is incomplete without its changelog entry and its
   documentation update, and that omission is a finding in its own right.
4. **Map every finding to a rule.** Each finding must name the rule it breaks and link the
   guide page (or the repository file) that states it. A comment that cannot be traced to a
   rule is a suggestion, not a defect — label it as such.
5. **Report, do not rewrite.** Produce the review in the output format below. Only edit files
   when the request explicitly asks for fixes.

## What matters most in `pipelines`

These are the checks that catch real defects in this repository. Work through
them before the generic ones.

```
.github/workflows/     reusable workflows per ecosystem (go-*, maven-*, gradle-*, npm-*,
                       yarn-*, pdm-*, composer-*, bundler-*, dotnet-*, dart-*, terra, containers)
github/ gitlab/ azure-devops/    per-vendor stage templates, one directory per language
global/scripts/        shared scripts, including pinned-versions.sh and verify-download.sh
global/containers/     shared container definitions
makefiles/             the Makefile targets consumers import
```

- **Supply-chain pinning is non-negotiable, and `make test-supply-chain` enforces it.** GitHub Actions are pinned to a full 40-character commit SHA with a trailing `# vX.Y.Z` comment — never a bare tag. The single exception is `rios0rios0/pipelines/…@main`, a same-repository reference that `test-workflow-composition.sh` separately **requires** to stay `@main`.
- **Container images are pinned as `tag@sha256:<digest>`**, in `image:` keys and in Dockerfile `FROM` lines alike.
- **Downloaded binaries carry a version and a SHA-256** in `global/scripts/shared/pinned-versions.sh` and are fetched through `download_verified` from `verify-download.sh`. **Never `curl | sh`**, and never an unverified `curl`/`wget` of a release artefact. This is a **Critical** finding every time.
- **Packages are version-pinned**: `go install …@<version>`, `pip install "pkg==<version>"`, `gem install pkg -v <version>`, `npx --yes pkg@<version>`. Never `@latest`, never a bare package name.
- **Every pin carries a `# upstream: <kind> <coordinate>` annotation.** A pin without one fails `make test-dependency-updates` — deliberately, because coverage otherwise shrinks one forgotten annotation at a time while the job stays green.
- **Bumping a tool means three things together**: change its `*_PINNED_VERSION`, replace every `*_SHA256_*` from the upstream checksum manifest (never carry an old digest forward), and run `make test-supply-chain`.
- **A weakened gate is worse than a failing one.** Lowering a severity threshold, adding a blanket exclusion, or making a scanner non-blocking silently disables the check for every consuming repository. Reject it unless the pull request argues the case and narrows the scope.
- **Templates must stay vendor-consistent.** A capability added to the GitHub template but not to the GitLab and Azure DevOps equivalents leaves consumers on those platforms behind — say so explicitly in the review.
- **Shell scripts run in strangers' CI.** `set -euo pipefail`, quoted expansions, no unvalidated `eval`, and no secret echoed into the log. ShellCheck findings are fixed, not disabled.
- **This repository is not an application.** There is no build/run cycle for itself; validation means running the template against an example project.

### Commands a reviewer should be able to quote

```bash
make test-supply-chain          # pinning gate — must pass
make test-dependency-updates    # upstream annotation coverage
make test                       # the full test-* script suite
make test-workflow-composition  # the @main self-reference rule
```

### YAML

See [YAML Conventions](https://github.com/rios0rios0/guide/wiki/YAML). The extension is `.yaml`, never `.yml`. String values are
single-quoted; double quotes appear only where interpolation or an escape needs them;
booleans and numbers are never quoted. This applies to workflows, compose files, manifests,
and YAML blocks inside Markdown.

### Dispatch tables over `switch`

See [Mapper Design Pattern](https://github.com/rios0rios0/guide/wiki/Mapper-Design-Pattern). Two or three stable cases may stay a
`switch`. Four or more, or a set that grows with features, becomes a map from key to handler
so that adding a case is a new entry rather than an edit to the dispatcher. Flag new
`switch`/`if-else` chains that dispatch on a string or enum key.

## Tests

Validation is the `make test-*` script suite in this repository plus running the changed template against a real consumer project. Security scanning takes 2–15 minutes and container builds up to 30 — a slow job is not a hung job, so do not report one as a defect.

## Documentation and change control

See [Documentation & Change Control](https://github.com/rios0rios0/guide/wiki/Documentation-&-Change-Control) and
[CHANGELOG Formatting](https://github.com/rios0rios0/guide/wiki/CHANGELOG-Formatting).

This repository uses **chlog fragments**. `CHANGELOG.md` is generated and is never edited by
hand.

- Every change ships a fragment created with `chlog new --kind <Kind> --body "…"`, staged in
  the **same commit** as the code. Kinds: `Added`, `Changed`, `Deprecated`, `Removed`,
  `Fixed`, `Security`.
- A backward-incompatible change to the public interface additionally carries `--breaking`.
  The kind alone never triggers a major bump.
- A hand-edited `CHANGELOG.md`, or a code change with no fragment under
  `.changes/unreleased/`, is a **Critical** finding — `chlog check` fails the build for it.
- Fragment bodies start with a lowercase verb in simple past tense, capitalise proper nouns
  (GitHub, Go, Docker), and wrap code identifiers and versions in backticks.
- `README.md` is updated whenever usage, setup, configuration, or architecture changes;
  `.github/copilot-instructions.md` and `CLAUDE.md` whenever the workflow, commands, or
  structure changes. Documentation and code ship in one commit.

## Git Flow and pull-request hygiene

See [Git Flow](https://github.com/rios0rios0/guide/wiki/Git-Flow) and [Merge Guide](https://github.com/rios0rios0/guide/wiki/Merge-Guide).

- Branch names are `feat/`, `fix/`, `refactor/`, `chore/`, `test/`, or `docs/` followed by a
  ticket ID or a short slug — `feat/TICKET-000`, `fix/input-mask`.
- Commit subjects are `type(SCOPE): message`: simple past tense (`added`, `fixed`, `changed`,
  `removed`), lowercase first word, no trailing period, code identifiers in backticks.
- Branches are synchronised with `git rebase`, never `git merge`. A merge commit from the
  default branch inside a feature branch is a finding.
- Breaking changes are flagged in **three** places: the commit footer
  (`**BREAKING CHANGE:** …`), the changelog, and the pull-request description. One or two of
  the three is not enough.
- Versions follow [SemVer](https://semver.org/): MAJOR for incompatible changes, MINOR for
  features, PATCH for fixes.

## Security

See [Security](https://github.com/rios0rios0/guide/wiki/Security).

- **No hard-coded secrets.** API keys, tokens, passwords, and private keys belong in
  environment variables or a secret manager — never in source, tests, fixtures, or the
  changelog. A secret that reaches a commit must be rotated, not merely deleted.
- **Never write a PEM header sentinel or a realistic key shape into a fixture** (a GitHub,
  OpenAI, AWS, or Slack token prefix, JWT-shaped strings, or the dashed `BEGIN …` banners).
  Gitleaks matches the shape, not the value, so a placeholder that merely *looks* like a
  credential fails the pipeline — spelling those prefixes out here would trip it too. Use
  inert placeholders such as `fixture-token-placeholder`.
- **Suppressions must be justified.** Entries in `.gitleaksignore`, `.trivyignore`,
  `.semgrepignore`, or `.codeql-false-positives` need a fingerprint, a dated comment, and a
  reason. A suppression added to silence a real finding is a Critical.
- Validate and sanitise every external input; use parameterised queries; apply least
  privilege; keep secrets out of logs.
- Dependency manifest changes are reviewed for new transitive vulnerabilities. When a fix
  exists, bump the version rather than suppressing the finding.

## What not to flag

A review that raises noise gets ignored. Do not report these:

- The `@main` reference on `rios0rios0/pipelines/...` — it is required, not an unpinned action.
- Long-running scanner and container-build steps.
- The per-vendor duplication between `github/`, `gitlab/`, and `azure-devops/` — the platforms genuinely differ.
- Anything the guide does not require and this file does not list, unless it is a genuine correctness or security defect — say so plainly and label it a Suggestion.

## Review output format

```
## Code review: <branch or PR>

### Critical (must fix before merge)
- `path/to/file.ext:LINE` — <what is wrong> — violates <rule> (<guide page or repo file>)

### Warning (should fix)
- `path/to/file.ext:LINE` — <what is wrong> — violates <rule>

### Suggestion (optional)
- `path/to/file.ext:LINE` — <improvement>

### Change-control checklist
- [ ] Changelog entry present for every behavioural change
- [ ] `README.md` updated if usage, setup, or architecture changed
- [ ] `.github/copilot-instructions.md` and `CLAUDE.md` updated if the workflow, commands, or structure changed
- [ ] Commit messages follow `type(SCOPE): message` in simple past tense
- [ ] Breaking changes flagged in the commit footer, the changelog, and the PR description

### Verdict: APPROVE / REQUEST CHANGES
<one paragraph: the blocking findings, or why the change is ready>
```

## Severity

| Severity       | Use for                                                                                                                            |
|----------------|------------------------------------------------------------------------------------------------------------------------------------|
| **Critical**   | Broken dependency direction, a leaked secret, an injection or authentication flaw, a missing changelog entry, a banned mock library, a load-bearing invariant broken, a test deleted rather than fixed. |
| **Warning**    | Naming that departs from the guide, a missing test for a new branch of logic, an unexplained magic value, a stale README or instructions file, a `switch` that should be a map. |
| **Suggestion** | Readability, consistency with neighbouring modules, and performance ideas that no rule mandates.                                     |

Rank findings most severe first, and state plainly when nothing blocks the merge — an empty
Critical section is a valid, useful review.
