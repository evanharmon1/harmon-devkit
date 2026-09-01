# Harmon DevKit OpenSpec Context

## Purpose

Harmon DevKit is Evan Harmon's personal developer kit: a collection of reusable
templates and boilerplates, standalone scripts, and AI assets. It is one part
of harmon-platform and supplies copyable or vendorable assets to other
repositories. It is not a monorepo and has no application runtime of its own.

## Repository shape

- `templates/` contains independent copy-paste boilerplates for Docker,
  scripts, serverless functions, web assets, and AI-tool integration.
- `scripts/` contains standalone utilities and the shell implementations behind
  Taskfile targets.
- `ai/` contains portable agent skills, thin shared agent definitions, JSON
  Schemas and fixtures, prompts, rules, workflows, and related AI assets.
- `snippets/` contains small reusable fragments.
- `docs/` is the documentation map; `specs/` contains milestone-level anchor
  specifications that OpenSpec changes may refine.

The shipped surfaces are independent assets. A change must identify which
asset owns a behavior instead of assuming shared application infrastructure.

## Tooling and workflow

- `Taskfile.yml` is the single source of truth for commands used by humans,
  hooks, and CI. Task commands stay as trivial one-liners; pipelines,
  conditionals, loops, and other substantive shell logic belong in
  `scripts/*.sh`.
- `task check` is the fast lint gate. `task verify` is the definition-of-done
  gate: check, validation, guards, and tests. `task ci` adds security checks and
  mirrors the build workflow locally.
- Node-based tools run through `npx`; the repository intentionally has no root
  `package.json`. OpenSpec is pinned by `scripts/openspec.sh`; use that wrapper
  directly or the `openspec:validate` Taskfile target rather than a bare CLI or
  an explicit unpinned `npx` invocation.
- Changes use Conventional Commits and are developed on feature branches.
  Safety gates are never bypassed, secrets never enter git, releases are
  intentional, and merges remain a human decision.

## AI and Dev-flow domain

Agent skills use the Agent Skills convention: one directory containing a
`SKILL.md` with frontmatter and supporting assets as needed. Shared agents are
one flat Markdown file each and remain thin by delegating workflow policy to
skills. Dev-flow v2 treats agent interactions as typed, evidence-bearing
protocols: role inputs and outputs are validated against JSON Schemas and a
fixture corpus, while deterministic harnesses compute gates and convergence.

Specifications should separate portable contracts from harness-specific
rendering, express requirements with observable scenarios, and preserve the
repository's preference for deterministic scripts beneath small Taskfile
entrypoints.

## OpenSpec conventions

- Active changes live in `openspec/changes/<change-name>/` and use the
  configured `spec-driven` schema.
- Capability deltas live under each change's `specs/` directory and use
  requirement/scenario format.
- Run `task openspec:validate` before considering an OpenSpec change complete.
- OpenSpec initialization regenerates the six `.agents/skills/openspec-*`
  skills with bare CLI commands. Reapply their `scripts/openspec.sh` routing
  whenever those skills are regenerated so clean checkouts keep using the
  pinned version.
- The anchor documents in the repository's root `specs/` directory are source
  material; OpenSpec capability deltas are the implementation-ready contract.
