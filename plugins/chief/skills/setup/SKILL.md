---
name: setup
description: Use when Chief has not been configured yet at CHIEF_HOME (no .chief/config/backend at the operator's workspace root) - walks the operator through the one-time setup of choosing a backend, the workers' agents, and gitignoring runtime state. This is a one-time step for the whole CHIEF_HOME, not something to repeat inside each project you dispatch into. Do not use once Chief is already configured; dispatch owns everything after that.
---

# Chief: setup

Needed once per `CHIEF_HOME` (the operator's shared home, typically the top-level workspace root, not each project), when `.chief/config/backend` doesn't exist yet.

All commands live in `${CLAUDE_PLUGIN_ROOT}/bin/`.

1. Ask the operator which backend to use: `herdr` or `orca`. Skip this if they already said.
2. Run `${CLAUDE_PLUGIN_ROOT}/bin/chief-setup.sh --backend <choice>`. It writes the config, checks the tool is on PATH, and adds `.chief/` to `.gitignore` if missing - safe to re-run.
3. If it warns the backend isn't on PATH, tell the operator: dispatching needs it installed (and, for Orca, running; the PATH check can't confirm that).
4. Ask which agent[:model] each dispatched role (builder, researcher, reviewer, brainstormer) should run: `claude` (default), `codex` or `copilot`, e.g. `claude:opus`. Optional per profile: `weight=N`, `args="..."`, `command="..."`. One profile, or a pool with a strategy (`first`, `round-robin`, `random`, `weighted`). For reviewers also ask the run mode (`mode = ` in `[reviewer]`): `parallel` (all at once, the default), `sequential` (one at a time; the first FAIL stops it), `ask` (Chief asks at each review how to run them, and which pool entries) or `first` (only the first pool entry). If they decline, skip it: with no `.chief/config/agents`, workers run `claude`.
5. Write `.chief/config/agents` (format: the plugin README's "Agents" section): a section per role (`[builder]`, `[researcher]`, `[reviewer]`, `[brainstormer]`) for its own pool, global lines above them for a shared pool. A role without a section uses the global pool. This Chief session's own agent is not configurable here.
6. Run `${CLAUDE_PLUGIN_ROOT}/bin/chief-agents.sh` and show the operator the agent each role gets, flagging any `(global fallback)`.
7. Done. From here on, use `dispatch` for actual work.
