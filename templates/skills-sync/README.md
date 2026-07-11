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

## How it works

- **Source of truth.** Skills live in harmon-devkit under `ai/skills/<category>/<skill>/SKILL.md`, grouped by category (`universal`, `backend`, `frontend`, `infra`, `mobile`, `repo`).
- **Category-selective.** A consumer requests whole **categories**, not individual skills — so skills can move between categories in one place (harmon-devkit) without touching every consumer.
- **Flattened on vendor.** Requested categories are flattened into the destination (`.claude/skills/<skill>/`), which is why skill directory names must be **unique across categories**. harmon-devkit enforces this at source with `task validate:skills`; the sync fails loudly if two requested categories collide.
- **Pinned tag.** The manifest pins a git tag, so updates are a deliberate manifest bump — never a surprise from upstream `main`.
- **Provenance.** Every synced destination gets a `.SKILLS_PROVENANCE` stamp recording the source, ref, and resolved commit SHA, with a "do not edit here" marker.

## What's in this bundle

| File | Purpose |
| --- | --- |
| [`.skills-sync.yaml`](./.skills-sync.yaml) | Example manifest — copy to your repo root and edit |
| [`Taskfile.skills.yml`](./Taskfile.skills.yml) | The `sync:skills` / `verify:skills` / `verify:skills:offline` tasks |
| `scripts/sync-skills.sh` | The vendoring engine — copy it from harmon-devkit's [`scripts/sync-skills.sh`](../../scripts/sync-skills.sh) |

## Adopt it in a consumer repo

1. **Copy the engine** into your repo (it is maintained and unit-tested in harmon-devkit):

   ```sh
   mkdir -p scripts
   curl -fsSL -o scripts/sync-skills.sh \
     https://raw.githubusercontent.com/evanharmon1/harmon-devkit/v0.5.0/scripts/sync-skills.sh
   chmod +x scripts/sync-skills.sh
   ```

2. **Add the manifest.** Copy `.skills-sync.yaml` to your repo root and edit `categories`, `ref`, and `dest`:

   ```yaml
   source:
     repo: https://github.com/evanharmon1/harmon-devkit.git
     ref: v0.5.0
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

Requires `yq` ([mikefarah/yq](https://github.com/mikefarah/yq)) and `git` on `PATH`.

## CI drift check

Add a job that fails a PR introducing skill drift. The message tells the dev to re-sync. Pin actions by SHA per your conventions.

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
    - name: Allow read access to the private harmon-devkit
      env:
        DEVKIT_READ_TOKEN: ${{ secrets.DEVKIT_READ_TOKEN }}
      run: |
        git config --global \
          url."https://x-access-token:${DEVKIT_READ_TOKEN}@github.com/".insteadOf \
          "https://github.com/"
    - run: task verify:skills
```

`verify:skills` vendors into a temp directory outside the repo and diffs — it has no side effects on the working tree, so **no `.gitignore` entry is needed**.

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

`verify:skills:offline` fails fast if the manifest ref and the vendored provenance disagree (i.e. you bumped the ref but forgot to re-sync).

## Adding a new skill

Skills are authored in harmon-devkit, not here. See
[`ai/skills/README.md`](../../ai/skills/README.md) for the layout, the
unique-name-across-categories rule, and how to add one. After it ships in a
harmon-devkit release, bump your `ref` and re-sync.

## Auth for the private harmon-devkit

- **Local:** your normal git credentials already cover it — no change.
- **CI:** store a read-only, fine-grained token scoped to harmon-devkit as the secret `DEVKIT_READ_TOKEN`, injected via `insteadOf` (see the CI job above).

## Why this shape

Pull-based vendoring was chosen over `git submodule`/`subtree` (which can't do a
subset cleanly) and over a per-repo skill list (which rots into a skill×repo
matrix). Push-based auto-PR sync, `SKILL.md` frontmatter linting, and package
distribution are deliberately **deferred** — revisit them only when syncing by
hand across repos becomes the bottleneck.
