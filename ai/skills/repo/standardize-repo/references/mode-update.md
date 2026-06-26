# Mode: Update

Bring a repo that was **already generated from harmon-init (v3+)** up to the latest
template — the repeatable "keep it in sync" path. Use this when the goal is "pull
the newest harmon-init changes into this repo," not initial setup.

Routing:

- **v3+ repo** (`.copier-answers.yml` present, `_commit: v3.x` or later) → this mode
  (`copier update`).
- **v2 repo or never templated** → [`mode-adopt-existing.md`](./mode-adopt-existing.md)
  (v2→v3 was a breaking redesign; re-template via its Path B).
- **Just want a drift report, no changes** → run §1 and stop, or see
  [`mode-audit.md`](./mode-audit.md).

The target repo is a **plain repo** — there is no special structure, no
"template-owned vs custom" split a developer must learn. Customizations live
normally in `Taskfile.yml`, `scripts/`, workflows, etc. The intelligence is here in
the skill: `copier update` does a three-way merge that pulls template improvements
*into* those files while preserving the repo's own edits; you reconcile anything that
conflicts. For copier mechanics see [`copier-gotchas.md`](./copier-gotchas.md).

---

## 0. Branch from a clean tree

```bash
cd <repo>
git switch main && git pull
git status --porcelain   # MUST be empty
git switch -c chore/update-harmon-init
```

## 1. See what's missing (read-only)

```bash
~/git/harmon-devkit/ai/skills/repo/standardize-repo/assets/diff-template.sh .
# add --show to print the full per-file diff
```

This renders harmon-init from the repo's own `.copier-answers.yml` and lists every
template-owned file that differs from a fresh render (mapping `.yml`↔`.yaml`). Each
`DRIFT` line is either a **template improvement the repo is missing** (the
status.sh / lint-hygiene / bootstrap class) or a **legitimate local customization** —
the diff tells you which. This is your reconciliation worklist for §3.

## 2. Run the update

**Preflight — ensure `_src_path` is a resolvable git source.** `copier update`
reuses the `_src_path` recorded in `.copier-answers.yml`; if it's a relative or
machine-local path (e.g. `harmon-init`), the update aborts with `Updating is only
supported in git-tracked templates` (see [copier-gotchas.md](./copier-gotchas.md)
gotcha 8). Normalize it to the GitHub URL first — once, committed:

```bash
grep '^_src_path:' .copier-answers.yml   # is it a URL? if relative/local, fix it:
yq -i '._src_path = "https://github.com/evanharmon1/harmon-init"' .copier-answers.yml
git commit -am "chore: point copier _src_path at the harmon-init GitHub URL"
```

```bash
copier update --trust --vcs-ref=HEAD
```

`copier update` reuses the `_src_path` + `_commit` from `.copier-answers.yml` and
three-way-merges the template's changes into the repo. `--vcs-ref=HEAD` renders the
template's working tree (a local checkout); omit it to update to the latest **tag**
(the normal case once harmon-init has cut a release). First-run `_tasks` are guarded
on `_copier_operation == 'copy'`, so update will **not** make a scaffold commit,
re-init git, or re-cut a release; one-time seeds (README, CHANGELOG, AGENTS.md,
product docs) are protected by `_skip_if_exists`.

## 3. Reconcile conflicts (in place — no special files)

The three-way merge applies template improvements and keeps the repo's edits when
they don't overlap. Where they do, copier leaves inline markers / `.rej` files:

```bash
grep -rn '^<<<<<<<\|^=======\|^>>>>>>>' . ; find . -name '*.rej'
```

Resolve each like a git merge — keep **both** the template's intent and the repo's
real customization in the same file. Example: the template improved `scripts/status.sh`
and the repo had added an `infra` section — the merged file keeps the improved core
*and* the `infra` section. Don't discard either side; don't extract anything into a
separate file. Then read the full diff (`git add -A -N && git diff`) and confirm no
app content was clobbered and no copier marker leaked (`[[`, `[%`,
`TODO: project_description`).

## 4. Verify comprehensively

```bash
~/git/harmon-devkit/ai/skills/repo/standardize-repo/assets/diff-template.sh .   # should now show only legit customizations
task verify
~/git/harmon-devkit/ai/skills/repo/standardize-repo/assets/verify-applied.sh .
```

Walk the [`mode-audit.md`](./mode-audit.md) drift classes too — `copier update`
refreshes templated files, but renames/moves and GitHub-side settings it cannot do.
Re-run `diff-template.sh`: every remaining `DRIFT` should be an intentional local
customization you can explain, not a missed update.

## 5. Hand off

Commit on the branch with a Conventional-Commits message
(`chore: update to harmon-init <version>`) and open a PR. Never bypass hooks; never
merge to `main` directly. Re-import the branch ruleset via the GitHub UI only if the
ruleset JSON changed (see [`post-generation-checklist.md`](./post-generation-checklist.md)).
