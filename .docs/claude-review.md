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

`reusable-claude-review.yaml` runs **three jobs** — `claude-review`, `security-review`,
`design-review` — one workflow, one trigger set, three tailored prompts, all inspired by
OneRedOak's code-review, security-review and design-review prompts (the design review is
re-tailored from their UI/UX focus to software design, which is what this repository's consumers
need). All three:

- run in tag mode with prose prompts; no plugin, no background agents, and an explicit
  instruction to do all analysis passes inline in the session;
- keep the plugin's two genuinely valuable ideas as *prompt methodology*: the **4-agent
  pipeline** (four named review passes, run sequentially by the one session) and the **≥80
  confidence filter** (score every candidate finding 0–100, report only ≥80, list the dropped
  ones with reasons — a rejected finding is evidence the filter ran);
- carry the #641 posting discipline: post on every run, open with a short summary of what the
  pull request changes, name what was checked when clean;
- are bounded to the diff: findings on unmodified lines are out of scope, and a re-run on a new
  push verifies the previous round's findings instead of hunting new ones.

`use_sticky_comment` is **deliberately absent**: its lookup matches the *first* Claude comment
on the pull request (`create-initial.ts` matches on the bot's identity), so three parallel jobs
would race to claim and overwrite one tracking comment, losing two reviews nondeterministically.
Three tracking comments per push is the price of three deterministic reviews; the re-review
discipline in the prompts is what keeps later pushes cheap and short.

Cost note: this is three Opus sessions per push. The re-review discipline keeps rounds after
the first short, but the multiplier is real — if it needs reducing, gate `security-review` and
`design-review` on `opened`/`ready_for_review` only and leave `claude-review` on every push.

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
