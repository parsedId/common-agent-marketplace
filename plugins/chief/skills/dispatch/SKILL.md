---
name: dispatch
description: Use when the user wants to hand off a piece of work to an isolated agent instead of doing it inline - dispatching a task, spawning a builder/researcher/brainstormer, reviewing a finished builder, checking on in-flight work, steering, or merging/tearing down finished work, once CHIEF_HOME (the operator's one shared home, not one per project) is configured (or where the user asks to set it up).
---

# Chief: dispatch

Chief runs isolated worker agents in their own git worktree: builders (code changes), researchers (investigation-only reports), reviewers (verdicts on a builder's commit) and brainstormers (specs shaped with the operator). It tracks them in a plain-markdown backlog and supervises them at near-zero token cost between your turns. You are the operator's single point of contact; you do not do dispatched work yourself.

All commands live in ${CLAUDE_PLUGIN_ROOT}/bin/. Runtime state lives in `.chief/` at `CHIEF_HOME`: the git root of wherever the Chief session runs, typically the operator's top-level workspace, not inside a `<project-dir>` (created on first use). One `CHIEF_HOME` dispatches into many projects; don't run `chief:setup` per project.

## Deciding builder vs researcher vs brainstormer

- **builder** (default): the deliverable is a code change on a branch. Use for anything with clear enough intent to implement.
- **researcher**: the deliverable is a written report only, no commit or push. Use only when the operator explicitly wants a separate investigation or design artifact, or uncertainty about *what* to build would make implementing now wasteful.
- **reviewer**: started by the review loop below, never on your own. For an arbitrary branch with no builder, spawn one with `--mode reviewer` and a `--spec` naming the branch, pinned SHA, base and intent.
- **brainstormer**: the deliverable is a spec shaped in live conversation with the operator. Explicit-only: spawn one only when the operator explicitly asks to brainstorm. Never choose it, default to it, or offer it instead of a clarifying question.

Don't launch a researcher for ordinary ambiguity; ask one concise question instead.

## The lifecycle

`state/<id>.lifecycle` (rendered by `chief-spawn.sh`) is the checklist for each task, filing through teardown. Check off each line as you complete it. Read it before acting on an in-flight task, not just after a compaction.

1. **File it.** `${CLAUDE_PLUGIN_ROOT}/bin/chief-backlog.sh add <id> "<short title>"` with an id named `<role>-<topic>` (e.g. `build-rate-limit`, `research-auth-flow`; a reviewer is `<builder-id>-review`). The id names the worktree, the data and state files and the herdr workspace, so make it say what the task is.

2. **Spawn.**
   `${CLAUDE_PLUGIN_ROOT}/bin/chief-spawn.sh <id> <project-dir> --mode builder|researcher|brainstormer --branch "<type>/<short-kebab-description>" --intent "<the operator's own ask, close to verbatim>" --spec "<your build instructions, only what the intent requires>"`
   - `--branch` is required: a new name in the `conventional-branches` scheme.
   - The agent and model come from the role's pool in `.chief/config/agents`, then the global pool. Add `--agent <agent[:model]>` and/or `--model <model>` only when the operator names one. Spawn prints the chosen `agent:`; `${CLAUDE_PLUGIN_ROOT}/bin/chief-agents.sh` lists the agent each role would get, marking a global-pool fallback.
   - Keep `--intent` narrow (it becomes the acceptance criteria) and `--spec` to what the intent requires.
   - It creates the worktree and branch, renders the brief, launches the worker and marks the backlog item in-flight. It returns once the worker's first turn has started; run it in the background.

3. **It runs on its own.** `${CLAUDE_PLUGIN_ROOT}/bin/chief-watch.sh` (armed by a Stop hook, zero model cost) interrupts you only when the task finishes, fails, is blocked or needs a decision. On `blocked` or `needs-decision`, run `${CLAUDE_PLUGIN_ROOT}/bin/chief-backlog.sh hold <id> "<why, one line>"`.

4. **Check on it anytime:** `${CLAUDE_PLUGIN_ROOT}/bin/task/chief-crew-state.sh <id>` prints the current state (working/done/blocked/needs-decision/failed/stale) and a `[mode: builder|researcher|reviewer|brainstormer]` tag. `chief-backlog.sh show <id>` adds its workspace, branch, worktree, brief and report paths. Use it to tell the operator where a task lives.

5. **Steer it:** `${CLAUDE_PLUGIN_ROOT}/bin/task/chief-send.sh <id> "<instruction>"` delivers through a durable inbox the worker acknowledges; safe mid-task. If the item is `held`, move it back with `${CLAUDE_PLUGIN_ROOT}/bin/chief-backlog.sh status <id> in-flight` once you've sent the unblocking instruction.

6. **If it's stuck**, escalate cheapest first:
   - `${CLAUDE_PLUGIN_ROOT}/bin/task/chief-control.sh <id> interrupt` (nudge; it keeps running) plus a corrective `chief-send.sh`.
   - `${CLAUDE_PLUGIN_ROOT}/bin/task/chief-control.sh <id> relaunch --note "<progress so far>"` only if wedged. The replacement gets the same worktree and commits but none of the conversation, so the note is all it has. Run it in the background.

7. **Report.** `state/<id>.lifecycle` has the exact next actions. For a builder, follow "The review loop".

## The review loop

Never automatic. Propose each step; the operator decides.

1. Builder `done`: report the result with the diffstat and a one-line recommendation (e.g. "2 files, docs only: review probably unnecessary"), hold it (`${CLAUDE_PLUGIN_ROOT}/bin/chief-backlog.sh hold <id> "reported: awaiting review decision"`), and ask whether to review it. Batch the question when several builders finish together.
2. No: go to landing. Yes: `${CLAUDE_PLUGIN_ROOT}/bin/task/chief-review.sh <builder-id>`. Round 1 spawns the reviewer `<builder-id>-review` (with `strategy = all` in the `[reviewer]` pool: one `<builder-id>-review-<agent>` per entry); later rounds re-arm them all. Run it in the background. The watcher wakes you when the reviewer reports.
   If the operator says "review everything this session", skip the question for this conversation until they revoke it. Still present every verdict.
3. Reviewer `done` (with several, wait for all, then present each separately and name the agent): present the verdict (PASS, or the blocking findings, then the suggestions) from `.chief/data/<reviewer-id>/report.md`. Hold the reviewer (`chief-backlog.sh hold <reviewer-id> "round N <verdict>, idle"`) and propose the next step:
   - FAIL: offer to send the findings to the builder. The operator may add comments or drop findings first.
   - PASS: offer to land it or keep going.
   - Reviewer `failed`: the review did not complete; report why.
4. Operator approves sending: `${CLAUDE_PLUGIN_ROOT}/bin/task/chief-send.sh <builder-id> "<blocking findings, the operator's additions, the report path>"`, then `chief-backlog.sh status <builder-id> in-flight`.
5. Builder `done` again: say it was fixed in `<sha7>` and ask again (step 1). There is no round cap.
6. Suggest posting findings to the PR only when the operator asks. Then run `${CLAUDE_PLUGIN_ROOT}/bin/pr/chief-pr-review.sh <builder-id> --comment "<finding>" --file <path> --line <N>` per finding, then a closing `--comment` or `--request-changes`.
7. `chief-teardown.sh <builder-id>` also discards its reviewers: name them all in the go-ahead. A reviewer alone: `chief-teardown.sh <reviewer-id>`, on the go-ahead.

## After the operator responds

Do exactly what they decide, nothing more:

- **Not satisfied:** move the task back to in-flight (`${CLAUDE_PLUGIN_ROOT}/bin/chief-backlog.sh status <id> in-flight`), then `${CLAUDE_PLUGIN_ROOT}/bin/task/chief-send.sh <id> "<instruction>"`.
- **Ready to land** (builder only): compose a conventional-commit-style title and a structured body yourself (following the project's PR conventions: a `conventional-pull-requests`-style skill if installed, or its CLAUDE.md/AGENTS.md), then `${CLAUDE_PLUGIN_ROOT}/bin/pr/chief-pr-open.sh <id> --confirm --title "<title>" --body "<body>"`. `--title` and `--body` are required.
- **Accepted:** builder: `${CLAUDE_PLUGIN_ROOT}/bin/pr/chief-pr-merge.sh <id> --confirm` (merges the open PR, squash by default). Researcher or brainstormer to be built on: see "Handing off".
- **Accepted as-is** (researcher or brainstormer): `${CLAUDE_PLUGIN_ROOT}/bin/chief-backlog.sh done <id>`, then `${CLAUDE_PLUGIN_ROOT}/bin/chief-teardown.sh <id>` discards the worktree; the report at `.chief/data/<id>/report.md` survives.

`chief-pr-open.sh`, `chief-pr-update.sh` and `chief-pr-merge.sh` require `--confirm`; pass it only once the operator has explicitly said so in this conversation.

## The brainstormer

Spawn it as in step 2 with `--intent` set to the operator's idea. Spawn prints `attach: ...`; tell the operator that line so they can attach and talk to it directly. With no `attach:` line, tell them to open the workspace named by `chief-backlog.sh show <id>` in the backend. After a relaunch, spawn's `attach:` line is printed again.

Never relay the conversation or answer for the operator. The brainstormer asks its questions in its pane, not through `needs-decision`, and reports `done` only after the operator confirms the spec there. While idle it reads `working · awaiting operator in pane`; `crew-state` and the session digest show its `[attach: ...]`. The spec is `report.md`.

## Handing off a researcher or brainstormer

A done researcher or brainstormer with a report can be followed by a successor: a new worker in a fresh worktree whose brief carries the report (earlier stages are linked).

- Targets: builder, researcher (from a brainstormer), brainstormer (from a researcher). Never the source's own role. A brainstormer target needs the operator's explicit ask; never propose it unprompted.
- A brainstormer's spec reaches the successor as operator-approved and authoritative; a researcher's report as context.
- The report is the whole handoff. Skim it first and send the source back (`chief-send.sh`) to fix a thin one: it must stand alone for an agent that saw none of the conversation.
- The successor runs the target role's configured agent. `--agent` carries another over; name it in the go-ahead.

1. Propose the branch (`conventional-branches` scheme) and preview the agent: `${CLAUDE_PLUGIN_ROOT}/bin/chief-spawn.sh <new-id> <project-dir> --mode <builder|researcher|brainstormer> --from <id> --branch "<type>/<short-kebab-description>" --intent "<ask>" --dry-run` prints the exact `agent:` and `launch:` (a weighted or random pool prints as the pool) and creates nothing.
2. Ask the operator's go-ahead naming that agent and branch, and that the source's session ends (a brainstormer's pane closes; its report survives under `.chief/data/<id>/`).
3. On the go-ahead, file `<new-id>` (`chief-backlog.sh add`), then run `${CLAUDE_PLUGIN_ROOT}/bin/task/chief-promote.sh <id> --to <role> --as <new-id> --branch "<branch>" --intent "<ask>" [--spec "<instructions>"]`. It runs `chief-spawn.sh --from`, then tears the source down. `--keep-source` leaves it running; `--dry-run` previews. Run it in the background.

## Once a PR is open

- **A follow-up commit lands** - push it and refresh the description if it no longer matches: `${CLAUDE_PLUGIN_ROOT}/bin/pr/chief-pr-update.sh <id> --confirm [--title "<title>"] [--body "<body>"]`. It always pushes new commits; omit `--title` and `--body` for a push-only update.
- **Check it** - `${CLAUDE_PLUGIN_ROOT}/bin/pr/chief-pr-state.sh <id>` prints its state (open/draft/mergeable/checks).
- **Post a review** (only when the operator asks) - `${CLAUDE_PLUGIN_ROOT}/bin/pr/chief-pr-review.sh <id> --comment "<text>"` or `--request-changes "<text>"`. Add `--file <path> --line <N>` to a `--comment` to attach it to a line (not valid with `--request-changes`).
- **Approve it** - `${CLAUDE_PLUGIN_ROOT}/bin/pr/chief-pr-approve.sh <id>`.
- **Merge it** - `${CLAUDE_PLUGIN_ROOT}/bin/pr/chief-pr-merge.sh <id> --confirm`. Squashes by default; pass `--merge` or `--rebase` only if the operator asks.
- **Abandon** - `${CLAUDE_PLUGIN_ROOT}/bin/task/chief-control.sh <id> exit` stops the worker and keeps its worktree and commits. `${CLAUDE_PLUGIN_ROOT}/bin/chief-teardown.sh <id> --abandon` also discards the unlanded local work and keeps the remote branch; only on the operator's explicit instruction, after the open-PR check (see *What NOT to do*). Add `--delete-remote` only if the operator explicitly asks to delete the remote branch.
- **Landed** - `${CLAUDE_PLUGIN_ROOT}/bin/chief-backlog.sh done <id>` (if not already), then `${CLAUDE_PLUGIN_ROOT}/bin/chief-teardown.sh <id>`. Teardown refuses unless the branch is reachable from the default branch (or `--abandon`); it also discards the builder's reviewers. It deletes only the local branch and worktree and keeps the remote branch; add `--delete-remote` only on the operator's explicit instruction. Run the open-PR check first.

## Backlog reference

`${CLAUDE_PLUGIN_ROOT}/bin/chief-backlog.sh add|status|note|hold|done|list|next|show <id> ...`: one markdown file (`.chief/data/backlog.md`); statuses are `queued|in-flight|held|done`. `hold <id> "<reason>"` marks anything waiting on an operator decision.

## What NOT to do

- Don't delete a remote branch unless the operator explicitly names it; teardown and `--abandon` delete only the LOCAL branch and worktree.
- Before tearing down or abandoning a builder whose branch is on the remote (`git ls-remote --heads origin <branch>`), look up open/active PRs with that source branch on the hosting platform (`gh`, `az repos`, or the REST API; don't assume GitHub); merged or abandoned PRs don't count. With an open PR, tell the operator, state that the local worktree/branch is what gets discarded, and tear down only on a yes. With none, proceed.
- `--delete-remote` (the only way teardown runs `git push origin --delete`) needs the operator's explicit instruction; if the branch has an open PR, say first that deleting it breaks the PR's source branch.
- Merging a PR on the operator's go-ahead (`chief-pr-merge.sh`) deleting its remote source branch is expected; the rule forbids deleting a remote branch via teardown or abandon (e.g. opening a PR, then tearing down before it merges).
- Don't spawn a worker to answer something a quick read-only look settles. Any actual change to a project, however small, goes to a worker.
- Don't invent scope in `--spec` beyond what `--intent` asks for.
