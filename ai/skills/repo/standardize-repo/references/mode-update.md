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
assets/diff-template.sh .
# add --show to print the full per-file diff
```

This renders harmon-init from the repo's own `.copier-answers.yml` and runs two
checks (mapping `.yml`↔`.yaml`):

- **`DRIFT`** — a curated file differs from a render at the repo's **own recorded
  `_commit`** (diff-template.sh renders at `_commit`, not the template's HEAD). So
  DRIFT is the repo's **local customization** relative to its own baseline — or,
  less often, a **regression** where a past hand-reconciled update dropped a
  template improvement at/below that baseline (the status.sh / lint-hygiene /
  bootstrap class). It is **not** "an improvement from a newer template version":
  those arrive through the `copier update` three-way merge (§2), never via
  diff-template. Read the diff to tell a deliberate customization from a regression
  to restore.
- **`MISSING`** — a template file the repo lacks entirely. This scan walks the
  whole render (it does **not** depend on the curated list), so a file the
  template added later, or one a previous hand-reconciled update dropped, can't
  slip through silently. (`.gitkeep` dir-stubs show as benign `ABSENT`.)

Together these are your reconciliation worklist for §3.

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
copier update --trust --defaults
```

**`--defaults` is mandatory when running non-interactively (agents have no TTY).**
Without it copier tries to prompt for answers and crashes with
`OSError: [Errno 22] Invalid argument` (prompt_toolkit can't attach to a missing
terminal). It reuses the stored answers and accepts defaults for any new questions
the template added since `_commit`.

**Always do a full update to the latest released version.** Plain `copier update`
goes to harmon-init's newest **tag** and three-way-merges the *entire* delta from the
repo's recorded `_commit` up to that tag, preserving local edits. Don't get fancy
scoping the update to a specific intermediate version (no `--vcs-ref vX.Y.Z`, no
hand-picking which template changes to take) — pull all the way to latest and
reconcile in §3. First-run `_tasks` are guarded on `_copier_operation == 'copy'`, so
update will **not** make a scaffold commit, re-init git, or re-cut a release. Only
`CHANGELOG.md` is frozen (`_skip_if_exists`); every other template improvement
(README, AGENTS.md, docs, scripts, …) flows in through the merge.

> `--vcs-ref=HEAD` is **only** for a *template developer* testing **unreleased**
> harmon-init changes from a local checkout (see [copier-gotchas.md](./copier-gotchas.md)
> gotcha 1). It is never needed for a normal repo update — don't add it here.

**Renamed templated files are skipped silently — port their delta by hand.**
`copier update`'s three-way merge is keyed on file *path*. If the repo renamed a
templated file (most commonly `*.yml` → `*.yaml` for the workflows, `Taskfile`,
and `lefthook`), copier can't match it: it leaves the file **untouched** and emits
**no warning** — the run still prints `Updating to template version <X>`, so it
*looks* fully applied while those files stay on the old version. `diff-template.sh`
(§1/§4) maps `.yml`↔`.yaml` for *detection*, so such a file shows as `DRIFT`
whether the gap is a benign extension swap **or** a genuinely missed update — open
the diff to tell which. For every renamed templated file, port the version delta
manually:

```bash
# <old> = the repo's _commit before this update; <new> = the tag you updated to
git -C ~/git/harmon-init diff <old>..<new> -- template/<path>
```

Apply the meaningful changes into the repo's renamed file, keeping its local
customizations. harmon-infra is the standing example (every `.yml` renamed to
`.yaml`, so its workflows/Taskfile/lefthook always need this hand-port).

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
separate file. Then read the full diff (`git add -A && git diff HEAD`) and confirm no
app content was clobbered and no copier marker leaked (`[[`, `[%`,
`TODO: project_description`). Use `git add -A` (not `git add -A -N`): copier
resolves some conflicts with a delete-then-add, which a bare `git diff` renders as a
misleading whole-file rewrite (`DA` in `git status`, every line shown as removed +
re-added); staging first and diffing against `HEAD` shows the true, small delta.

**Silent reverts have NO conflict marker.** copier only emits markers / `.rej`
where edits *overlap*. A file the repo customized **outside copier's tracked
answers** — anything restored wholesale from `main` during a Path-B adopt
(`.vscode/settings.json`, `.gitignore`, `renovate.json`, a forked `Taskfile.yml`) —
can be reverted to the template default *cleanly and invisibly*. (`.vscode/settings.json`
is gitignored, so its revert doesn't even show in a normal `git diff`.) So the diff
review above is not optional: eyeball every high-churn, locally-customized file by
name and confirm your customization survived. Cross-check the §1 `diff-template.sh`
worklist — any file that was `DRIFT` *before* the update but is now byte-identical to
the template was silently reverted; restore the customization.

**AGENTS.md is co-owned — always 3-way-merge it by hand; the safety net above does
NOT cover it.** `AGENTS.md` is deliberately **not** in
[`template-owned-files.txt`](../assets/template-owned-files.txt), so `diff-template.sh`
never checks it and the silent-revert cross-check cannot catch an AGENTS.md clobber —
yet it is usually the most heavily customized file in the repo (project overview,
architecture, real commands, project-specific conventions). Treat every update as a
genuine three-way merge on AGENTS.md, section by section: **keep the repo's
substantive customizations**, but **do adopt the template's real improvements** —
some template sections legitimately supersede the repo's (e.g. a corrected
Conventional-Commits type enum, a reworded workflow rule). It is a judgment call, not
a wholesale `--ours`/`--theirs`. Diff the merged result against the pre-update file
(`git show HEAD:AGENTS.md`) and confirm both sides survived where each should.

**Heavily-forked files: take `--ours` and re-apply the new bits.** When a file is
*heavily* customized (a forked `Taskfile.yml`, a bespoke `status.sh`), copier's
three-way merge can scramble it — a single conflict hunk spanning several unrelated
targets. Hand-resolving that is error-prone. Take the repo's complete version and
cherry-pick only the genuinely-new pieces:

```bash
git checkout --ours Taskfile.yml   # keep the repo's complete, working file
# then add just what the update introduced (e.g. a new `status:setup` target)
```

**The template absorbed something this repo pioneered → add/add conflict; keep
yours.** A canonical convention repo's innovations get *generalized* and upstreamed;
on its next update, the template's new generic version collides with the repo's
specific original (an add/add conflict on, e.g., `scripts/validate-*.mjs`). Keep the
repo's specific version (`git checkout --ours <file>`) — the generic one is for
*other* repos. Recognise this when a file you know the repo authored shows up as a
conflict against a near-identical-but-blander template version.

## 4. Verify comprehensively

copier renders files in the **template's** style, which may not match the repo's
formatter (e.g. Prettier reformatting freshly-rendered workflow YAML or config).
Run **`task format` first**, or `task verify` can fail on formatting alone:

```bash
task format                 # reconcile rendered files to the repo's formatter
assets/diff-template.sh .   # should now show only legit customizations
task verify
assets/verify-applied.sh .
```

Walk the [`mode-audit.md`](./mode-audit.md) drift classes too — `copier update`
refreshes templated files, but renames/moves and GitHub-side settings it cannot do.
Re-run `diff-template.sh`: every remaining `DRIFT` should be an intentional local
customization you can explain, not a missed update. In particular, a `DRIFT` on a
file the repo *renamed* (e.g. `.yaml`) may be an update copier skipped, not a
customization — confirm against the §2 renamed-files note before dismissing it.

## 5. Hand off

Commit on the branch with a Conventional-Commits message
(`chore: update to harmon-init <version>`) and open a PR. Never bypass hooks; never
merge to `main` directly. Re-import the branch ruleset via the GitHub UI only if the
ruleset JSON changed (see [`post-generation-checklist.md`](./post-generation-checklist.md)).
