# Claude Review: Findings and Design

This document records why `reusable-claude-review.yaml` is shaped the way it is. It exists
because the workflow was debugged four times in two days, three of those times on failure modes
that produced **a green job with no comment** — and every conclusion below was paid for with a
real run. Read it before "simplifying" the workflow, and update it when the workflow changes.

## The incident that started it

The review originally ran the `code-review@claude-code-plugins` plugin as a slash command with
`track_progress: true`. That combination silently disabled the plugin: `track_progress` forces
tag mode, where `prompt` is injected into the action's own template as *context* rather than
executed — so the plugin installed, appeared in `slash_commands`, and never ran. What reviewed
pull requests instead was an unbounded free-form agent. On one pull request in this repository
(#636) it posted **seven reviews in seventy minutes**, findings per round going 6 → 4 → 4 → 6 →
5, the last round's top findings about three files the pull request never touched.

## The four fixes, in order

| PR | What it fixed | What it taught |
|----|---------------|----------------|
| #638 | Switched to agent mode so the slash command executes | Tag mode reads `prompt` as context; agent mode executes it. The difference is invisible until measured: a tag-mode run reported `subagent_stats.spawned: 0` against a plugin that mandates ~7 |
| #639 | Granted the Bash tools the plugin's agents need | In headless CI there is no approval prompt, so a denied tool is denied outright. The first agent-mode run logged 22 permission denials and ended having never read the diff |
| #640 | Scoped Bash by prefix (`Bash(gh:*)`, `Bash(git:*)`) plus read-only pipe helpers | `--allowedTools` is the complete **Bash** allowlist and the MCP-server selector — NOT the complete tool set. `Read`, `Grep`, `Glob`, `Task`, `TodoWrite` are permitted by default (measured: `Read` ran 5×, `Task` spawned 7 subagents, while absent from the list). Every segment of a pipe must match. A redirect is blocked by the sandbox, not the list |
| #641 | Told the review to post on every run | The plugin's own step 6 says "if there are no issues that meet this criteria, do not proceed", while its output format defines a no-issues template. Both behaviours were observed on identical wiring |

## Why the plugin was removed anyway

After all four fixes, runs still went silent — and the forensics say the failure is structural,
not configurable. Across five runs of the same wiring:

| Run | Subagents spawned / completed | Posted? |
|-----|-------------------------------|---------|
| A (public repo, testkit #62) | 7 / 3 | no |
| B (public repo, testkit #62) | 8 / 8 | no — plugin's step-6 "do not proceed" (fixed by #641) |
| C (public repo, testkit #62) | 4 / 0 | no — ended its turn "waiting for agents to report back" |
| D (private consumer repo) | 1 / 1 | **yes** — the #641 format, in full |
| E (private consumer repo) | 9 / 9 | **yes** — three comments |

**Every run whose subagents completed posted; every run that orphaned them went silent.** The
same code, the same prompt, the same permissions. The discriminator is whether the orchestrator
ends its turn while Task subagents are still running — at which point the Action terminates the
session and the review dies in flight.

This is a known, open, upstream family of bugs:

- [anthropics/claude-code-action#1646](https://github.com/anthropics/claude-code-action/issues/1646)
  — "code-review plugin exits green without posting: orchestrator awaits an async agent the
  Action never resumes." The plugin assumes an interactive harness that re-invokes on task
  notifications; the Action assumes single-turn completion. Both are right alone; neither holds
  composed.
- [#1515](https://github.com/anthropics/claude-code-action/issues/1515) — the same mid-turn
  session end, measured at **30–43% of runs on heavier prompts**, SDK path only, never
  reproducible in the local CLI. Decisive detail: a prompt instruction saying "the Task tool is
  synchronous; never write 'awaiting results' and end your turn" is *visibly read but does not
  reliably prevent it*. A prompt-level fix for this class was tried upstream and failed.
- [#1087](https://github.com/anthropics/claude-code-action/issues/1087) — plugin completes the
  review, produces an empty result, posts nothing.
- [#1384](https://github.com/anthropics/claude-code-action/issues/1384) — the permission-denial
  shape #639 fixed here.

One more research result worth recording: a GitHub-wide code search for
`code-review@claude-code-plugins` finds **no public CI workflow using it** — only the action's
own docs, source mirrors, and local `.claude/settings.json` files. The pattern this repository
was debugging has essentially no production users to have found these bugs first.

## What the successful pattern looks like

The most-adopted working setup is
[OneRedOak/claude-code-workflows](https://github.com/OneRedOak/claude-code-workflows)
(~3.9k stars), which the current workflow is modelled on. Its shape:

- **Tag mode** (`track_progress: true`) with a **prose prompt** — no plugin, no slash command,
  no Task fan-out to orphan.
- An explicit `--allowedTools` list naming the `gh` commands and the inline-comment MCP server.
- Posting instructed explicitly in the prompt.

Tag mode has a determinism property agent mode cannot offer: **the tracking comment is created
by the action itself before Claude runs.** A run that dies mid-turn leaves a visibly stuck
tracking comment instead of silence — the failure mode becomes legible, which is exactly what
two of the four debugging cycles were spent lacking. And in every tag-mode run observed here,
`subagent_stats.spawned` was 0: the model reviews inline, so upstream #1515 has nothing to kill.

## The resulting design

`reusable-claude-review.yaml` runs **one job**, `claude-review`, whose single prompt covers
three dimensions — correctness, security, and software design — inspired by OneRedOak's
code-review, security-review and design-review prompts (the design dimension re-tailored from
their UI/UX focus to software design, which is what this repository's consumers need). The
review:

- runs in tag mode with a prose prompt; no plugin, no background agents, and an explicit
  instruction to do all passes inline in the session;
- executes **six sequential passes**: the plugin's **4-agent pipeline** (CLAUDE.md compliance,
  bug scan, git history, code-comment adherence) plus a security pass and a design pass;
- applies the **≥80 confidence filter to every finding from every pass** — correctness,
  security and design alike — with each survivor labeled by dimension and score, and every
  dropped candidate listed with its score and reason (a rejected finding is evidence the
  filter ran);
- carries the posting discipline: post on every run, open with a short summary of what the
  pull request changes, name what was checked when clean;
- is bounded to the diff, and a re-run on a new push verifies the previous round's findings
  instead of hunting new ones;
- posts **one comment per pull request**: `use_sticky_comment` updates it in place on every
  push.

### Why one job, not three

The first shipped version of this design ran three parallel jobs (`claude-review`,
`security-review`, `design-review`) with one prompt each. It worked — on its pilot pull
request all three posted, the disciplines held, and the dimension separation was clean — but
it posted **three comments per push**: six comments after one review-and-fix round, on top of
whatever other bots the repository runs. The signal was good and the volume was not.

Merging the dimensions into one prompt fixed the volume twice over. One job means one comment
per run — and one job is the first of **three** preconditions for `use_sticky_comment`, whose
lookup (`create-initial.ts`) claims the first comment from *any* Claude bot on the pull
request through an unpaginated `issues.listComments` call. The review's own first run caught
the other two, at confidence 80, reviewing this very change:

1. **A single review job** — parallel jobs race to claim and overwrite one tracking comment,
   losing reviews nondeterministically.
2. **No other Claude comment precedes the review's** — the mention responder shares the
   action and identity, so a `@claude` answer posted before any review comment exists (the
   realistic order: a *draft* pull request, which the review's `if:` skips, gets a `@claude`
   question; the answer posts; the PR is marked ready) is claimed and overwritten by the
   first review run, surviving only in its edit history. On non-draft PRs the review comments
   first, which is what usually protects this.
3. **The review's comment sits within the first page (30) of comments** — past that, the
   lookup misses it and sticky silently degrades back to one comment per push, with nothing
   reporting it.

None of the three is fixable from the workflow; they are properties of the pinned action.

### Findings post as inline threads, deterministically

Every finding that survives the filter is required by the prompt to be its own inline comment
thread — anchored to the exact file and line, opening with `**<dimension> (confidence
<score>)**` — so findings are individually discussable and resolvable, and the tracking
comment carries the summary, the thread index, the per-dimension clean verdicts, and the
dropped list. Two mechanics make the threads deterministic rather than model-discretionary:

- the prompt mandates the thread (previously "anchor line-specific findings" was a
  suggestion, and whether a finding became a thread depended on the run);
- `classify_inline_comments: false` posts every inline comment immediately. The default
  buffers any call not carrying `confirmed: true` into `/tmp/inline-comments-buffer.jsonl`
  and replays it after the session through a Haiku classifier — a path with two open upstream
  bugs ([#1667](https://github.com/anthropics/claude-code-action/issues/1667): one malformed
  buffer line discards every buffered comment;
  [#1679](https://github.com/anthropics/claude-code-action/issues/1679): "Posted 0/N" exits
  green) — and its purpose, filtering test comments from *subagents*, protects nothing in a
  prompt that forbids subagents.

Cost: one Opus session per push (the three-job layout cost three).

### The review does not build, and says so

The action's own tag-mode template ends with an analysis checklist whose last two steps are,
verbatim:

> e. Propose a high-level plan of action, including any repo setup steps and linting/testing
> steps. Remember, you are on a fresh checkout of the branch, so you may need to install
> dependencies, run build commands, etc.
>
> f. If you are unable to complete certain steps, such as running a linter or test suite,
> particularly due to missing permissions, explain this in your comment so that the user can
> update your `--allowedTools`.

Both are wrong for this design, and the second one *published* the first. A review on a consumer
repository closed with a **"Note on verification"** explaining that `go build ./...` and `go vet`
had been denied by the tool permissions — a caveat about a deliberate decision, written to a
reader who had not made it, occupying the end of a review that was otherwise about the code. The
model was doing what it had been told; the instruction was the defect. Nothing in the workflow
contradicted it, because the prompt described the review's *disciplines* and never its *tools*.

Both prompts now do. Each states the surface it actually has, names the toolchains it excludes
(`go`, `node`, `npm`, `yarn`, `pnpm`, `python`, `pip`, `pdm`, `mvn`, `gradle`, `dart`, `flutter`,
`dotnet`, `composer`, `bundle`, `terraform`, `terragrunt`, `docker`, `make`), says that the
exclusion is a decision rather than a gap, and overrides (e) and (f) by name: plan no setup step,
run none to "verify" a finding, never retry a denied command, and never write a verification
caveat or limitations section. The review adds the rule that makes it self-consistent — **a
finding you could only establish by executing something is not a finding you can post**: read
until it reaches ≥80 confidence, or drop it into the tracking comment's dropped list with its
score and reason, like any other.

The redirection is not "trust the code": the pipeline compiles, lints, type-checks, scans and
tests the same commit in dedicated jobs, and reports on the same pull request. A partial second
verdict from a review session cannot add to that, and can contradict it.

`.github/tests/test-workflow-composition.sh` Test 13 holds the pairing, because the prose and the
`--allowedTools` string are edited in different places for different reasons — a granted command
missing from the prompt re-creates the defect, and a command the prompt calls denied while the
allowlist grants it is the same drift reversed.

### The mention responder needed `track_progress` to take a prompt at all

`reusable-claude-mention.yaml` carries the same contract, and getting it there was not a matter of
adding a `prompt:`. A prompt on a comment or issue event **selects agent mode**
(`src/modes/detector.ts`), where the action's template is replaced by the custom prompt — the
template being the thing that reads the `@claude` and answers it. A bare `prompt:` would therefore
have turned the mention responder into something that runs those instructions and ignores the
question, green throughout. `track_progress: true` forces tag mode back, which is the review's
original plugin trap run in reverse: there, tag mode silently *disabled* the slash command; here,
its absence would silently *replace* the responder.

Tag mode's price is an event constraint, and it is a loud one: `validateTrackProgressEvent`
accepts `pull_request`, `issues`, `issue_comment`, `pull_request_review_comment` and
`pull_request_review`, and throws on everything else. Those five are what the documented caller
subscribes to; a responder wired to some other event now fails by name instead of quietly not
answering.

Its tool surface was deliberately **not** widened to match the review's. The responder holds
`contents: write` and checks a fork's branch out into the workspace, so every command added there
is added on the exposed side of the boundary the workflow's header comment describes. It keeps
what tag mode grants — `git add`, `git commit`, `git rm`, the push wrapper, `Read`/`Grep`/`Glob`/
`LS`, the comment tool, and the CI tools — and the prompt says so, including that `gh`, `git diff`
and `git log` are absent, so the model reads the pre-fetched `<changed_files>` list and the files
themselves instead of discovering the gap by denial.

## Operational facts worth not relearning

- `--allowedTools` only ever *selects*; in headless CI it is the entire Bash surface. Granting
  `Read`/`Grep`/`Glob` in it is redundant; omitting `Bash(gh:*)` is fatal.
- Every segment of a pipe must be allowed. `gh pr diff` passes, `gh pr diff | wc -l` fails with
  "This Bash command contains multiple operations". The read-only helpers (`grep`, `cat`, `wc`,
  `head`, `tail`) exist for this. `sed`, `awk`, `find`, `sort`, `uniq` are excluded on purpose:
  each can write a file or execute (`sed -i`, `awk print >`, `find -exec`, `sort -o`).
- Output redirection is refused by the working-directory sandbox regardless of the allowlist.
- `ANTHROPIC_MODEL` pins the model without touching `claude_args`
  (`parse-sdk-options.ts` resolves `model: options.model || modelFromClaudeArgs`).
- The model pin matters: without it the CLI default applies, which in CI resolves to Sonnet.
- `id-token: write` is required — the action exchanges a GitHub OIDC token for the App token it
  posts with. Removing it fails every run with `Could not fetch an OIDC token`.
- Tag mode MERGES its own `--allowedTools` with the one in `claude_args` rather than letting the
  second overwrite the first (`base-action/src/parse-sdk-options.ts` accumulates the flag). So the
  effective surface is `Glob`, `Grep`, `LS`, `Read`, the comment tool, `Bash(git add|commit|rm)`
  plus the push wrapper, *and* everything this workflow lists.
- The review cannot read CI results, and the reason is not the allowlist. Tag mode lists
  `mcp__github_ci__*` unconditionally, but `prepareMcpConfig` installs that server only after
  `checkActionsReadPermission` passes — and the review job does not take `actions: read`. Adding it
  is not free: a called workflow cannot hold a permission its caller did not grant, so it would
  have to be added to every consumer's caller first. The mention responder does take it, which is
  why only that prompt offers the CI tools.
- `--permission-mode acceptEdits` is set by tag mode, so file edits inside the workspace are
  allowed even though `Edit`/`Write` appear in no list. The review job never pushes, so an edit is
  discarded with the runner — worth knowing before reading the allowlist as proof of read-only.
