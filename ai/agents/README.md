# Agents

Reusable **subagents** — each a single Markdown file whose frontmatter names it
and whose body is its system prompt. harmon-devkit is the single source of
truth, the same way it is for [`ai/skills/`](../skills/README.md).

An agent is a *delegated context*: the calling session hands it a brief and gets
back a result, with none of the caller's transcript in between. A skill is
*procedure* loaded into whatever context is already running. The two compose —
the agents here are deliberately thin and defer to skills for anything a skill
already says.

## Layout

Flat, one file per agent, no category subdirectories:

```text
ai/agents/
└── implementer.md   # implement a plan or a confirmed defect in a fresh context
```

Categories exist in `ai/skills/` so consumers can vendor a subset without a
per-skill list. There are not yet enough agents for that to be worth the
indirection; when there are, categories drop in exactly as they did for skills.

| Agent | For |
| --- | --- |
| [`implementer`](./implementer.md) | Turning a written plan — or a review finding the caller has already confirmed — into a verified, committed change. Never branches, pushes, opens PRs, or merges. |

## Portability contract

Agents are less harness-agnostic than skills: the frontmatter keys, the tool
names, and the invocation model are all Claude Code's. These are written in
Claude's format, with the parts that would strand them elsewhere left out. Any
harness that can give a subagent a system prompt consumes the body as-is and
ignores the frontmatter.

- **Frontmatter is `name` and `description` only.** `tools`, `model`, `color`,
  and `effort` are Claude-specific, drift as the harness changes, and each one
  is a decision better made by the calling session than baked into a shared
  file. Restrict scope in the body instead; a consumer that wants a hard
  capability limit can add `tools:` to its own vendored copy.
- **`name` matches the filename** (kebab-case, no extension), and must not
  collide with a skill name — `task validate:agents` enforces all three. The
  kebab-case rule is not cosmetic: the name becomes a path on both sides of the
  vendor, so a space or a capital is a path hazard, the latter colliding
  silently with its lowercase twin on a case-insensitive filesystem.
- **Reference skills by reading the file, never by invoking one.** A subagent
  has no slash commands, and the dev-workflow skills are user-invocable only
  (`disable-model-invocation: true`), so nothing can invoke them on a model's
  behalf. `Read .claude/skills/<name>/SKILL.md` works in every harness that has
  a file-read tool.
- **Discover the skill, don't require it.** Check the conventional path, fall
  back to a glob, and degrade to `AGENTS.md` plus the brief when there is
  nothing to read. A consumer that vendors no skills still gets a working agent.
- **Don't name tools in prose.** Say what to do, not which tool does it — tool
  names are the least portable thing in the file.
- **The repo's policy outranks the agent.** State it, the way the skills do:
  `AGENTS.md` is policy, the agent is procedure.

## Guard

`task validate:agents` checks that every agent has valid frontmatter, that
`name` matches the filename, and that no agent name collides with a skill
directory name under `ai/skills/`. It runs in `task verify`, in CI, and in the
pre-commit hook. `README.md` is not an agent and is skipped.

The collision check is the one rule that has no skills-side equivalent. Agents
and skills land in sibling directories (`.claude/agents/` and
`.claude/skills/`), so a shared name never collides on disk — it collides in the
reader, which is worse, because nothing fails.

## Dogfooding

harmon-devkit uses its own agents by symlinking them into `.claude/agents/`,
for the same reason it does with skills: the source repo cannot vendor from
itself without waiting on its own release, and a symlink makes the authored
file the live one.

```sh
ln -s ../../ai/agents/<name>.md .claude/agents/<name>.md
```

Safe with the repo's gates — `lint-hygiene.sh` skips symlinks, `.claude/**` is
excluded from markdownlint, and this guard only walks `ai/agents/`, so nothing
is linted or counted twice.

## Add an agent

1. Create `ai/agents/<name>.md`:

   ```markdown
   ---
   name: your-agent-name
   description: >-
     What it does, when to hand work to it, and what it will not do. This is
     what the calling session reads when deciding whether to delegate — write
     the boundaries in, not just the capability.
   ---

   # Your Agent Name

   Agent body…
   ```

2. Keep it thin. If a skill already documents the procedure, point at it per the
   portability contract above rather than restating it — a copy in an agent
   rots against the skill with nothing checking the two agree.
3. Run `task validate:agents` (or `task verify`).
4. Symlink it into `.claude/agents/` to use it here.
