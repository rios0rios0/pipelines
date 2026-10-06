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
