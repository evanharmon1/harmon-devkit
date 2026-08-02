# skills-sync

Vendor a **selected subset** of the shared agent skills in
[harmon-devkit](https://github.com/evanharmon1/harmon-devkit) into a consumer
repo, pinned to a tag, via a pull-based `task sync:skills`. A `verify:skills`
drift check (CI) plus a fast `verify:skills:offline` check (git hook) keep the
vendored copies from silently rotting against the pinned ref.

harmon-devkit is the single source of truth; each consumer declares what it
wants in a small `.skills-sync.yaml` manifest. Pure `git` + `task` + `yq` — no
submodules, no package registry, tool-agnostic (skills stay portable `SKILL.md`
files).

> **If your repo is generated from [harmon-init](https://github.com/evanharmon1/harmon-init), skills-sync is already built in** — the engine, manifest, tasks, CI drift check, and pre-push hook are rendered for you (categories seeded from your `project_type`). Just set the manifest `ref` and run `task sync:skills`. This bundle is the reference for **manually** adopting skills-sync in a repo that does _not_ use harmon-init.

## How it works

- **Source of truth.** Skills live in harmon-devkit under `ai/skills/<category>/<skill>/SKILL.md`, grouped by category (`universal`, `backend`, `frontend`, `infra`, `mobile`, `repo`).
- **Category-selective.** A consumer requests whole **categories**, not individual skills — so skills can move between categories in one place (harmon-devkit) without touching every consumer.
- **Flattened on vendor.** Requested categories are flattened into the destination (`.claude/skills/<skill>/`), which is why skill directory names must be **unique across categories**. harmon-devkit enforces this at source with `task validate:skills`; the sync fails loudly if two requested categories collide.
- **Pinned tag.** The manifest pins a git tag, so updates are a deliberate manifest bump — never a surprise from upstream `main`.
- **Shared destination — local skills are first-class.** The dest (`.claude/skills`) is shared between vendored and local skills. The sync manages **only** the dirs it vendored (recorded on the provenance `# managed:` line); any other directory is a local skill the repo owns — the sync and both verify modes never touch or report it. If a local dir's name collides with an incoming vendored skill, the sync fails loudly **before deleting anything** (rename the local skill or drop the category).
- **Provenance.** Every synced destination gets a `.SKILLS_PROVENANCE` stamp recording the source, ref, resolved commit SHA, and the `# managed:` list of vendored dirs, with a do-not-edit marker for the managed skills.
- **Agents ride along, optionally.** An `agents:` block vendors shared subagents (single `<name>.md` files) into their own dest, at the **same pinned ref**, in the same `task sync:skills` run. Omit the block and nothing about the sync changes.

## Agents

Shared subagents live in harmon-devkit under `ai/agents/<name>.md` — flat, no categories. Add an `agents:` block to request them:

```yaml
agents:
  names: [implementer] # or ["*"] for every agent at the pin
  dest: .claude/agents # must differ from the skills dest
```

> **Requires an engine with agents support.** `scripts/sync-skills.sh` from a
> release older than this feature does not know the `agents:` key exists — it
> vendors your skills, exits 0, and never mentions that the block was ignored,
> and its `verify` is silent about it too. There is no version handshake that
> could warn you: an old program cannot recognise a future key. If the block is
> in your manifest and `.AGENTS_PROVENANCE` never appears in `agents.dest`, your
> engine is too old — re-fetch it per step 1 of the adoption steps below.

Everything the skills pass guarantees, the agents pass guarantees too: pinned ref, flattened dest shared with your local agents, a `.AGENTS_PROVENANCE` stamp whose `# managed:` line is the only thing the sync will replace or delete, a collision that fails **before** any deletion, and both drift checks (`verify` and `verify:skills:offline`).

Three things are specific to agents:

- **One ref for both.** Agents and skills are pinned by the same `source.ref`, and that is deliberate rather than incidental. A shared agent is thin: it defers to a skill by _reading_ it (`.claude/skills/<name>/SKILL.md`). Pinning the two separately would let an agent follow a procedure that no longer exists at the other pin.
- **`names`, not categories.** Agents are few and flat, so a consumer names them — or asks for all of them with `["*"]`. Mixing `"*"` with explicit names is a manifest error, not a union.
- **Separate dest, always.** `agents.dest` must differ from `dest`. Two independent managed sets over one directory would each have to reason about the other's deletions; the sync refuses the arrangement instead.

`README.md` in the source agents directory documents that directory and is never vendored as an agent.

## What's in this bundle

| File | Purpose |
| --- | --- |
| [`.skills-sync.yaml`](./.skills-sync.yaml) | Example manifest — copy to your repo root and edit |
| [`Taskfile.skills.yml`](./Taskfile.skills.yml) | The `sync:skills` / `verify:skills` / `verify:skills:offline` tasks |
| `scripts/sync-skills.sh` | The vendoring engine — copy it from harmon-devkit's [`scripts/sync-skills.sh`](../../scripts/sync-skills.sh) |

## Adopt it in a consumer repo

1. **Copy the engine** into your repo (it is maintained and unit-tested in harmon-devkit). Resolve the newest release rather than hard-coding a tag — see the warning below:

   ```sh
   mkdir -p scripts
   engine="$(gh release view --repo evanharmon1/harmon-devkit --json tagName -q .tagName)"
   curl -fsSL -o scripts/sync-skills.sh \
     "https://raw.githubusercontent.com/evanharmon1/harmon-devkit/${engine}/scripts/sync-skills.sh"
   chmod +x scripts/sync-skills.sh
   ```

   > **The engine version and the manifest `ref` are different things.** The
   > `ref` pins _what content you vendor_ and is a deliberate choice. The engine
   > is _the program doing the vendoring_, and should simply be current — an
   > engine older than a manifest feature **ignores that feature silently**. An
   > engine predating `agents:` support, handed a manifest with an `agents:`
   > block, exits 0 having vendored only skills; its `verify` ignores agents
   > too, so nothing ever reports the omission. Take the newest engine.

2. **Add the manifest.** Copy `.skills-sync.yaml` to your repo root and edit `categories`, `ref`, and `dest`:

   ```yaml
   source:
     repo: https://github.com/evanharmon1/harmon-devkit.git
     ref: v0.17.0 # a deliberate content pin — bump when you want new assets
   categories:
     - universal
     - frontend
   dest: .claude/skills
   ```

3. **Add the tasks.** Paste the tasks from `Taskfile.skills.yml` into your `Taskfile.yml`, or `includes:` the file.

4. **Sync and commit:**

   ```sh
   task sync:skills
   git add .skills-sync.yaml .claude/skills scripts/sync-skills.sh
   git commit -m "chore: vendor shared agent skills from harmon-devkit"
   ```

Requires `yq` ([mikefarah/yq](https://github.com/mikefarah/yq)) and `git` on `PATH`. Step 1 also uses `gh` to resolve the newest release; without it, open the [releases page](https://github.com/evanharmon1/harmon-devkit/releases/latest) and substitute the tag by hand — just don't reuse your manifest `ref` for it, which is the mistake the warning above describes.

## CI drift check

Add a job that fails a PR introducing skill drift. The message tells the dev to re-sync. harmon-devkit is **public**, so cloning it needs no token. Pin actions by SHA per your conventions.

```yaml
skills-drift:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@<sha> # vX.Y.Z
    - uses: arduino/setup-task@<sha> # vX.Y.Z
      with:
        repo-token: ${{ secrets.GITHUB_TOKEN }}
    - name: Install yq (pinned)
      run: |
        sudo curl -sSL -o /usr/local/bin/yq \
          https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64
        sudo chmod +x /usr/local/bin/yq
    - run: task verify:skills
```

`verify:skills` vendors into a temp directory outside the repo and diffs — it has no side effects on the working tree, so **no `.gitignore` entry is needed**. It also skips cleanly until the first `task sync:skills`, so a repo that hasn't synced yet stays green.

## Git hook

Use the **offline** variant in a hook (fast, deterministic, no network). With Lefthook:

```yaml
pre-push:
  commands:
    skills-drift:
      run: task verify:skills:offline
```

## Updating the pinned ref

1. Bump `source.ref` in `.skills-sync.yaml` to the new harmon-devkit tag.
2. Run `task sync:skills`.
3. Commit the manifest change and the updated `dest/` in one commit.

`verify:skills:offline` fails fast if the manifest ref and the vendored provenance disagree (i.e. you bumped the ref but forgot to re-sync). Renovate can automate the ref bump, but it cannot run the re-sync half — never merge a ref bump without the accompanying `task sync:skills` result.

## Adding a new skill or agent

Both are authored in harmon-devkit, not here. See
[`ai/skills/README.md`](../../ai/skills/README.md) for the skill layout and the
unique-name-across-categories rule, and
[`ai/agents/README.md`](../../ai/agents/README.md) for the agent layout and the
portability contract. After it ships in a harmon-devkit release, bump your `ref`
and re-sync.

A new **skill** arrives automatically if it lands in a category you already
request. A new **agent** does not: `names` is an explicit list, so add it there
first — unless you use `["*"]`, which picks up every agent at the new pin.

## Auth

harmon-devkit is **public**, so cloning it needs no credentials — locally or in
CI. No token, no secret, no `insteadOf` config. (If it were ever made private,
you'd add a read-only token and inject it via `insteadOf`.)

## Why this shape

Pull-based vendoring was chosen over `git submodule`/`subtree` (which can't do a
subset cleanly) and over a per-repo skill list (which rots into a skill×repo
matrix). Push-based auto-PR sync, `SKILL.md` frontmatter linting, and package
distribution are deliberately **deferred** — revisit them only when syncing by
hand across repos becomes the bottleneck.
