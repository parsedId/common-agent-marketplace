# Chief

A lightweight supervisor for Claude Code: dispatches work to isolated builder/researcher/reviewer/brainstormer agents over the herdr or Orca backend, tracks a plain-markdown backlog, and supervises them with a near-zero-token watch loop. (Verbatim from `.claude-plugin/plugin.json`'s `description` - see "Maintaining these docs" below.)

Scoped down hard from bigger multi-agent supervisors on purpose: **Claude Code only**, **herdr or Orca backend only** (configurable via `.chief/config/backend`, default `herdr`), one delivery mode (branch + you approve every merge - no auto-merge). Every script is meant to be short enough to read start to finish.

Inspired by [Firstmate](https://github.com/kunchenguid/firstmate), which does the same job across many more harnesses, backends, and delivery modes - Chief keeps its core ideas (isolated worktrees per task, an intent/spec brief split, a closed status vocabulary, a durable steering inbox, refuse-before-discard teardown, and a near-zero-token Stop-hook watch loop) while cutting everything scoped to that broader generality.

## Layout

- `bin/` - the lifecycle scripts, split into `bin/` (`chief-spawn`, `chief-watch`, `chief-teardown`, `chief-backlog`, `chief-setup`, `chief-agents`), `bin/task/` (`chief-control`, `chief-crew-state`, `chief-send`, `chief-promote`, `chief-review`), and `bin/pr/` (`chief-pr-open`, `chief-pr-update`, `chief-pr-state`, `chief-pr-review`, `chief-pr-approve`, `chief-pr-merge`); and `bin/lib/` (`paths.sh`/`home.sh`/`meta.sh`/`lock.sh`/`brief.sh`/`meta-extensions.sh` helpers, `bin/lib/agents/` with the loader and selector `agent.sh` (a task's adapter from its meta; profile selection from `.chief/config/agents`) and the adapters `{claude,codex,copilot}.sh` - the agent's launch command, screen texts and folder pre-trust - `git-sync.sh` - best-effort freshening of a project's default-branch checkout against origin, used by spawn/pr-merge/teardown - `worktree.sh` - the guard that tells a spawned builder's own session apart from the operator-facing one - `bin/lib/backends/` with the loader `backend.sh` and its adapters `{herdr,orca,mock}.sh`, and `bin/lib/pr-providers/` with the loader `pr-provider.sh` and its adapters `{github,gitlab,azuredevops,mock}.sh`).
- `templates/` - a brief template (`brief-<role>.md`) and a per-task lifecycle checklist (`lifecycle-<role>.md`) per worker role (`builder`, `researcher`, `reviewer`, `brainstormer`) rendered into `state/<id>.lifecycle` at spawn time, mirroring `skills/dispatch/SKILL.md`'s own steps so Chief can recover in-flight progress after a context compaction.
- `skills/using-chief` - the identity/job-description skill, force-injected every session via the `SessionStart` hook so Chief always knows its role without being asked.
- `skills/setup` - one-time CHIEF_HOME config (backend choice + gitignoring `.chief/`); only relevant before `.chief/config/backend` exists, which the `SessionStart` digest flags explicitly.
- `skills/dispatch` - the operator-facing entry point; load this to hand off work.
- `hooks/` - `SessionStart` (injects `using-chief`, a configuration status line, and a backlog/in-flight digest) and `Stop` (the token-saving watch arm). Both stand down entirely inside a spawned builder's own worktree - see `worktree.sh`.

Runtime state lives at `.chief/` under `CHIEF_HOME` - by default the outermost git root enclosing wherever the Chief session runs, so the operator's top-level workspace even when run from inside a project or one of its worktrees; never inside a project (`state/`, `data/`, `config/`, `worktrees/`) - created on first use, not part of the plugin package. `chief-setup.sh` gitignores it for you.

Spawn syncs the project's default branch from origin (best-effort), then creates the task worktree and launches the worker in it (agent command from `agents/<agent>.sh`, brief as first prompt). A spawn or relaunch succeeds (`spawned:` / `relaunched:`) only once the worker's first turn was observed started; otherwise it fails non-zero and rolls back. With herdr, each task is its own linked-worktree workspace grouped under the project's primary workspace; with Orca, the project is registered on first spawn (`orca repo add`) and each task is an Orca-created worktree nested under the project's main worktree, running the agent in a terminal created with `terminal create --command` (Orca picks the path). Teardown closes the task's terminals and removes the worktree (and, on Orca, its worktree entry).

## Naming

Task ids read `<role>-<topic>` (`build-rate-limit`, `research-auth-flow`; a reviewer is `<builder-id>-review`); herdr labels a task's workspace `<id> · <role> · <project>` (recorded as `label=` in meta; earlier tasks keep `chief-<id>`), Orca names the worktree `<id>`. herdr agent names must match `^[a-z][a-z0-9_-]{0,31}$`: an id that doesn't is mapped to a shortened name plus a hash inside the herdr adapter, so any id works. The watcher surfaces a terminal state line once per task (`notify-baseline` in meta) and again only when the line changes or the task goes back to work. `chief-backlog.sh show <id>` prints a task's workspace, branch, worktree, brief and report paths.

## Agents

Workers run on `claude` (default), `codex` or `copilot`, on herdr and Orca alike; all but the brainstormer run unattended. **`codex` and `copilot` have no folder-trust handling:** if their CLI asks to trust a new worktree, the spawn stalls and fails as "not ready" (only `claude` is pre-trusted, see below). Which agent a task gets:

1. `chief-spawn.sh ... --agent <agent[:model]>` and/or `--model <model>` win. `--model` alone overrides only the model of the profile the config selects.
2. Else `.chief/config/agents`, if present:

   ```
   strategy = weighted          # first (default) | round-robin | random | weighted
   claude:opus   weight=3
   codex:gpt-5   weight=2
   copilot       args="--banner" weight=1                  # weight defaults to 1

   [builder]                    # optional pool (and strategy) for builders
   claude:opus args="--verbose"

   [researcher]                 # and for researchers; a missing section uses the global pool
   strategy = round-robin
   claude:haiku
   codex:gpt-5-mini

   [reviewer]                   # and for reviewers
   strategy = all               # reviewer only: one reviewer per entry on every review
   copilot
   claude:sonnet

   [brainstormer]               # and for brainstormers
   claude:opus
   ```

   Sections are the worker roles: `[builder]`, `[researcher]`, `[reviewer]`, `[brainstormer]`; any other name is an error. `#` starts a comment. Per entry, `weight=`, `args=` and `command=` may come in any order. `first` takes the first entry; `round-robin` rotates (cursor in `state/agent-cursor-<role>`, updated under a lock so parallel spawns differ); `weighted` draws by `weight=`; `random` is `weighted` with equal weights. `all` (the `[reviewer]` role only) runs every entry; see the review loop.
3. Else `claude` with its default model.

The choice is recorded in the task's meta (`agent`, `model`, `args`, `command`) and reused by relaunch; `chief-crew-state.sh`, `chief-backlog.sh list|show` (in-flight) and the session digest show `[agent: <agent>[:<model>]]`. Spawn fails before creating anything for an unknown agent, a malformed profile or weight, a missing CLI, or a bad `command=` / `args=` / model combination below. Models are passed to the agent unvalidated.

A profile's `args="..."` (or `--args "..."` on spawn, which replaces the configured ones) adds CLI arguments after the adapter's own unattended and model flags, on herdr and Orca alike, e.g. `claude:opus args="--verbose --add-dir /x"`. `args=` and `command=` values are split on whitespace and may only use letters, digits, spaces and `. _ / @ : = + , -` (no quotes or shell characters), so both backends read them the same way. `weight=` is a whole number from 0 to 1000 (0 = never picked by `weighted`; a pool where every weight is 0 is an error).

`command="..."` instead replaces the whole launch line (a wrapper, another binary path), so it cannot be combined with a model or `args=` (put them in the command). Orca runs it as given. herdr starts the agent's own executable (`--kind`), so the command must start with it (`claude`, `/usr/local/bin/claude`) and only its arguments are used; for another executable use `args=` or the Orca backend. An explicit `--agent` drops the configured `args` and `command`.

A role with no section of its own runs the global pool. `chief-agents.sh` prints the agent each role would get now (read-only; a weighted or random pool is listed, not picked) and marks a role that falls back with `(global fallback)`. Spawn prints the chosen `agent:` too.

`CHIEF_AGENT` and `.chief/config/agent` (the old single-agent selection) are gone; `.chief/config/agents` replaces them.

The launch line each worker runs is the adapter's `agent_command` in `bin/lib/agents/<name>.sh` (executable, unattended flag, `--model`, then `args=`), unless the task has a `command=`; spawn prints it as `launch: ...`. Adding an agent is one `bin/lib/agents/<name>.sh` implementing the contract in `agents/agent.sh`. Differences to know:

- Folder trust is pre-accepted for `claude` only (see below); for `codex` and `copilot` a trust prompt, if shown, stalls the spawn as "not ready".
- The worker brief is agent-neutral (status file and turn-ended file by path), but `claude` workers also get this repo's plugins and skills from their own config; `codex` and `copilot` do not, so project conventions come from `AGENTS.md` and the brief alone.
- Approval/sandbox: `claude --dangerously-skip-permissions`, `codex --dangerously-bypass-approvals-and-sandbox`, `copilot --allow-all`.
- Claude workers inherit the `CLAUDE_CONFIG_DIR` note below.

## Handoff

`chief-spawn.sh <id> <project> --mode <role> --from <src> ...` starts a **successor** of a done researcher (or brainstormer) with a non-empty `data/<src>/report.md`: a fresh worktree on a synced default branch, a brief with the `from=` lineage (oldest first) and the source's report appended under `# Prior work`, `from=<src>` in meta. Targets are `builder`, `researcher` or `brainstormer`, never the source's own role; builders and reviewers are never sources. The successor gets the **target role's** configured agent, never the source's; `--agent` carries one over explicitly. The source is left untouched.

`--dry-run` validates everything and prints `agent:` and `launch:` (or the pool for a weighted/random strategy) without creating anything or advancing a cursor, so a go-ahead can name the exact agent. `chief-promote.sh <src> --to <role> --branch <name> --intent "..." [--as <new-id>] [--keep-source] [--dry-run] [spawn flags]` is a thin wrapper: the successor is `<src>-<role>` unless `--as` (file it in the backlog first), then the source is torn down unless `--keep-source`; its report survives under `data/`.

## Review

The operator decides, per builder, whether it is reviewed; Chief asks after every builder `done` and never starts a review itself (unless told "review everything this session"). `chief-review.sh <builder>` needs the builder's last status `done`, a clean worktree and a commit ahead of the default branch.

- **Round 1** files backlog item `<builder>-review` and spawns a reviewer (`--mode reviewer`, branch `chore/review-<builder>`, the `[reviewer]` pool). Its spec pins the builder's HEAD SHA, names the branch and base, points at the builder's brief and `done` line. Meta links: `for=<builder>` on the reviewer, `reviewer=` and `review_round=` on the builder.
- **Several reviewers:** with `strategy = all` in `[reviewer]`, round 1 spawns one reviewer per entry instead of one: `<builder>-review-<agent>[-<model>]` (a repeated slug gets `-<n>`), branch `chore/review-<builder>-<agent>[-<model>]`, each with its own entry's model/args/command and its own report. `reviewer=` on the builder lists every id, space-separated. Rounds, gates and teardown below apply to each.
- **Later rounds** re-arm the same reviewer(s): its `report.md` is archived as `report.round-<N-1>.md`, the round message goes to its inbox, the backlog item returns to in-flight, and `working: round N requested` is appended to its status. The same commit is refused while the reviewer is working.
- **The reviewer** resets its scratch worktree, detaches at the pinned SHA and reviews the full `base...sha` diff every round against the 8-item checklist in its brief (item 3 runs the project's checks), then verifies earlier findings. It writes `report.md` (`Verdict`, `Target`, `Blocking`, `Suggestions`, `Checklist`, `Prior findings`) and ends with `done: round N PASS @<sha7>` or `done: round N FAIL (<n> blocking) @<sha7>`; `failed` means the review could not be completed. It never posts, pushes or merges. A builder's `done` line starts with its short commit SHA, so every re-report is a new line to the watcher.
- **Chief** presents the verdict, holds the reviewer, and on the operator's yes sends the findings to the builder; the builder fixes them with new commits and reports `done` again. Findings go to a PR only when the operator asks (`chief-pr-review.sh`).
- **Teardown** of a builder also discards its reviewers once the builder's own teardown succeeds; a refused builder leaves it alone. A reviewer can be torn down alone; that ends review of that builder, and a manual `--mode reviewer` spawn is the way to review it again. `chief-crew-state.sh` and the session digest show `[for: <builder>]` / `[reviewer: <id>]`.

A reviewer on any branch, with no builder: `chief-spawn.sh <id> <project> --mode reviewer --branch chore/<name> --intent "..." --spec "<branch, pinned SHA, base, intent>"`.

## Brainstormer

An explicit-only worker (`--mode brainstormer`), spawned only when the operator asks to brainstorm. It talks to the operator directly in its own pane; Chief never relays the conversation. It writes a one-page, self-contained spec to `data/<id>/report.md` (goal, scope, acceptance criteria, decisions with rationale and rejected options, open questions) and reports `done` only after the operator confirms it there. Its brief is agent-neutral and depends on no skill. A done spec hands off like a researcher's report, and a researcher can hand off to a brainstormer.

- **Attach hint.** A backend may define the optional `backend_attach_hint <id>` (see `backend.sh`). Spawn and `chief-control.sh relaunch` print it as `attach: ...` and store `attach=`; `chief-crew-state.sh` and the session digest repeat it while the brainstormer runs. herdr: `herdr workspace focus <workspace>` (verified live). Orca: the worktree and terminal to open (tested against the fake `orca` only, unverified live). mock: `tail -f` of its log.
- **Idle.** An idle brainstormer with a non-terminal last status reads `working · awaiting operator in pane`, never `stale`. `done`, `failed`, `blocked` and `needs-decision` surface immediately.

## Folder trust

Each backend pre-accepts the agent's folder-trust dialog before a worker starts, via `agent_prepare` (also on relaunch) in `bin/lib/agents/claude.sh`: it sets `hasTrustDialogAccepted` in `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json` for the task's exact worktree (claude does not inherit trust from a parent directory), under a lock, never touching `$HOME`. Teardown and spawn rollback call `agent_release`, which removes only flags Chief set. Pre-trust is lossy: a concurrently starting claude can rewrite `.claude.json` and drop the entry. The herdr backend therefore reads the screen after `agent start` and, if the dialog for the worktree Chief just created is showing, accepts it once (`agent_trust_keys`); a dialog for any other folder, or for an agent without trust keys, fails the spawn as "not ready" with the last screen lines. Orca has no such fallback.

- Chief and the worker's claude should resolve the same `.claude.json` (herdr panes inherit the herdr server's environment, so start both with the same `CLAUDE_CONFIG_DIR`); on herdr a mismatch costs the pre-trust fast path, not the spawn.
- `CHIEF_NO_PRETRUST=1` opts out. Use it only if you trust folders another way; on Orca spawns will otherwise stall at the trust dialog.
- Orca picks its own worktree path, so it is trusted right after `orca worktree create`, before the agent starts.

## Status

Core lifecycle (backlog, spawn, send, control/relaunch, crew-state, watch, teardown, merge, handoff) is implemented and tested end-to-end against a mock backend. The **herdr adapter** (`bin/lib/backends/herdr.sh`) is verified against a live herdr 0.9.0 install - spawn/capture/busy/send/kill/relaunch all exercised end to end with a real `claude` turn in `tests/chief/test-backend-herdr.sh` (opt-in, `CHIEF_TEST_HERDR=1`) and against a fake `herdr` with live-captured screens in `tests/chief/test-backend-herdr-mock.sh`. The **Orca adapter** (`bin/lib/backends/orca.sh`) follows the same flow - bypass-permissions launch, spawn rollback, relaunch, teardown - verified live in `tests/chief/test-backend-orca.sh` (opt-in, `CHIEF_TEST_ORCA=1`; adapter functions plus the real spawn/send/control/crew-state/teardown scripts) and against a fake `orca` CLI in `tests/chief/test-backend-orca-mock.sh`.

PR provider adapters: **GitHub** is implemented and tested against a fake `gh` CLI, including inline (file:line) review comments. **GitLab and Azure DevOps are fully implemented but their `pr_review_line` (inline comments) is an unverified draft**, same status as the Orca backend - built from each provider's documented API shape, not run against a live `glab`/`az` install; each adapter's header comment lists exactly what needs confirming.

## Maintaining these docs

One owner per fact - don't restate one doc's content in another:

- Public pitch and current status -> this file (`README.md`) only.
- Agent operating contract and hard rules -> `skills/using-chief/SKILL.md`
  only; never restated here.
- Step-by-step process for one workflow -> that step's own `SKILL.md`
  (`skills/dispatch`, `skills/setup`).
- Stable architecture and extension points (backend adapters, PR-provider
  adapters) -> a future `plugins/chief/ARCHITECTURE.md`, created once the
  "Layout" section above actually needs to split out, not pre-emptively.

This plugin's one-line pitch lives in `.claude-plugin/plugin.json`'s
`description`; this file's opening line quotes it verbatim rather than
paraphrasing it, so there's exactly one wording to keep current.
