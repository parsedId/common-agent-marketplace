# Contributing

## Adding a new plugin

Each plugin is a self-contained directory under `plugins/<new-plugin-name>/`:

```
plugins/<new-plugin-name>/
├── .claude-plugin/
│   └── plugin.json      # name, description, version, author, license
├── skills/               # optional — see "Skill conventions" below
│   └── <skill-name>/
│       └── SKILL.md
├── agents/               # optional — see "Agent conventions" below
│   └── <agent-name>.md
└── README.md
```

1. Create `plugins/<new-plugin-name>/.claude-plugin/plugin.json` — `name`
   (kebab-case, matches the directory), `description`, `version`, `author`
   (the marketplace owner unless the plugin has a different author),
   `license`.
2. Add the plugin's skill(s) and/or agent(s), following the conventions
   below.
3. Write `plugins/<new-plugin-name>/README.md` describing the plugin.
4. Add an entry to `.claude-plugin/marketplace.json`'s `plugins` array —
   this single file is read by both Claude Code and Copilot CLI, see
   "Claude Code / Copilot CLI compatibility" below.
5. Add the new plugin to the root `README.md`'s "Available plugins" list.
6. Validate every manifest parses: `python3 -m json.tool <path>`.

## Marketplace versions

`metadata.version` in `.claude-plugin/marketplace.json` versions the
marketplace as a whole. The tag `v<version>` pins every plugin version
listed in that file at that commit.

- Bump `metadata.version` in the same PR as any plugin version change.
- While 0.x: bump the minor for plugin additions, removals, or breaking
  changes; bump the patch for any other plugin bump.
- Don't tag by hand. The `tag-marketplace` workflow creates `v<version>`
  on merge to `main` if it doesn't exist yet.

## Skill conventions

- One directory per skill under `<plugin>/skills/<skill-name>/SKILL.md`.
- Frontmatter: `name` (matches the directory name) and `description`
  (states when the skill should be used — specific triggers, not vague
  topics).
- Body: purpose, when to use, a concrete step-by-step process, and what
  the agent should output when done.

## Agent conventions

- One file per agent under `<plugin>/agents/<agent-name>.md`.
- Frontmatter: `name` (matches the filename), `description` (include one
  or two usage examples showing when Claude should invoke it), and
  `model`.
- Body: the agent's process, output format, and an explicit "when NOT to
  use this agent" section so overlapping agents stay distinguishable.

## Claude Code / Copilot CLI compatibility

Both platforms are built on the same Open Plugin Spec:

- `marketplace.json` and `plugin.json` are read directly from
  `.claude-plugin/` by both Claude Code and Copilot CLI — one manifest,
  no duplication. (Copilot CLI also accepts a `.github/plugin/`
  location, but this repo doesn't maintain one — `.claude-plugin/` alone
  is sufficient for both platforms.)
- `skills/<name>/SKILL.md` uses the same format on both platforms.
- **Agents are Claude Code-only for now.** Claude Code loads every `*.md`
  file under `agents/`; Copilot CLI loads only files named `*.agent.md` in
  the same directory. Because a `.agent.md` file still matches `*.md`,
  adding a Copilot-formatted agent alongside a Claude Code one in the same
  directory would make Claude Code attempt to load it too, with
  frontmatter it doesn't expect (`tools` as an array, no `model` field).
  This hasn't been verified against the real Claude Code plugin loader,
  so until it has, agents in this marketplace target Claude Code only. If
  you need a Copilot CLI agent, test the collision behavior first and
  update this note with what you find.

## Tooling

Manifests are still validated by hand (JSON parses, referenced paths
exist, frontmatter fields are present).

Plugins with real executable code or checkable skill behavior get actual
tests. See [docs/testing.md](docs/testing.md) for the two tiers
(`tests/<plugin-name>/` for non-LLM mechanics, `tests/claude-code/` for
skill-behavior checks) and how to add coverage when you add a new plugin.
Tests run locally, by hand. The only CI workflow tags marketplace versions.
