<!-- Update reference: conflicts. Step numbers (§0–§6) refer to the runbook. -->

[Update runbook](./mode-update.md) · Read this reference when its step is reached;
keep the same shell and guarded state across steps.

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

**Deletion audit — justify every removed pre-existing path.** Inspect staged
deletions before proceeding:

```bash
git diff --name-status --diff-filter=D HEAD
```

For each path, compare the pre-update file, the recorded Copier answers, and the
template condition that controls it. A condition becoming false is evidence to
review, not permission to discard repo-owned behavior. Restore and ask when the
deletion is uncertain. Never delete or weaken a workflow to clear a credential or
external-capability failure; report the human-only blocker instead.

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

**AGENTS.md is co-owned — always 3-way-merge it by hand; the safety net above covers
only its PRESENCE.** `AGENTS.md` is deliberately **not** in
[`template-owned-files.txt`](../assets/template-owned-files.txt), yet it is usually the
most heavily customized file in the repo (project overview, architecture, real
commands, project-specific conventions). `diff-template.sh` does compare it — as a
`CO-OWNED` line, deliberately **presence-only**: it tells you the repo's copy still
differs from the template's, never *how*, and it never fails the run. That is enough
for the clobber check and nothing like enough for the merge. Treat every update as a
genuine three-way merge on AGENTS.md, section by section: **keep the repo's
substantive customizations**, but **do adopt the template's real improvements** —
some template sections legitimately supersede the repo's (e.g. a corrected
Conventional-Commits type enum, a reworded workflow rule). It is a judgment call, not
a wholesale `--ours`/`--theirs`. Diff the merged result against the pre-update file
(`git show HEAD:AGENTS.md`) and confirm both sides survived where each should.

**A `CO-OWNED` line that DISAPPEARS is the clobber signal.** Read this class
inversely to `DRIFT`: for a co-owned file, *differing from the template is the
healthy state*, so the alarming transition is the line vanishing between the §1
run and the post-update re-run. Gone means the repo's copy is now byte-identical
to the template's — the customizations were overwritten wholesale. Note the §1
`CO-OWNED` paths before you update and confirm every one of them is still listed
afterwards; a missing entry gets the same treatment as the silent-revert
cross-check above, restored from `git show HEAD:<path>`. The same reading applies
to the aliases: `CLAUDE.md`, `GEMINI.md`, and `.github/copilot-instructions.md`
are symlinks compared by link target, so they stay silent while they remain
links — a `DRIFT … (symlink mismatch …)` on one of them means an update flattened
it into a second, independently drifting copy of the instructions.

**`OWNED` lines read the same way, and a vanished one is worse.** The class is
presence-only for the same reason, so note the §1 `OWNED` paths too and confirm
each is still listed afterwards. A `CHANGELOG.md` or `.release-please-manifest.json`
that stopped diverging is a **prompt to check**, not a verdict. Copier is
supposed to make a clobber impossible here (`_skip_if_exists` freezes the path),
so if one happened the restore is urgent — but a vanished line has an innocent
cause too: a newer template seed can simply have caught up with the repo's
content (a release-manifest seed that now names the version the repo is on), and
then the render compares equal although the freeze worked perfectly. Diff the
file against its pre-update content (`git show HEAD:<path>`) before treating it
as a clobber; the destination changing is what makes it one, not the line
disappearing.

**Heavily-forked files: take `--ours` and re-apply the new bits.** When a file is
*heavily* customized (a forked `Taskfile.yml`, a bespoke `status.sh`), copier's
three-way merge can scramble it — a single conflict hunk spanning several unrelated
targets. Hand-resolving that is error-prone. Take the repo's complete version and
cherry-pick only the genuinely-new pieces:

```bash
git checkout main -- Taskfile.yml   # restore the repo's clean pre-update file
# then add just what the update introduced (e.g. a new `status:setup` target)
```

> **Don't hand-take a spanning "after" hunk — grep first.** The scrambled hunk's
> "after" side often re-lists targets that ALSO live elsewhere in the file (copier
> couldn't align them), so accepting it wholesale **duplicates keys** — a
> `yamllint` `key-duplicates` error or a `task --list-all` parse failure catches it,
> but only after the fact. Before taking any spanning "after" hunk, `grep -n '^  <target>:' <file>`
> each target it defines; if one already appears outside the hunk, don't take it.
> `git checkout main -- <file>` + re-applying only the genuinely-new targets is the
> reliable path (prefer it over `git checkout --ours`, which needs a real merge
> state a copier conflict may not have).

**Verify the after-side is the same task as the before-side — copier pairs
hunks positionally, not semantically.** In a heavily-forked file the
positional neighbor is often a *different* task entirely, so "take the
template side" — safe-looking for a mechanical hunk — silently swaps or
deletes repo behavior. Two real cases from one harmon-infra update: a
conflict paired `security:audit:node` (`npm audit` for the repo's homepage)
against `./scripts/python-audit.sh` (taking "after" would have replaced the
Node audit with a duplicate Python audit), and a spanning hunk paired the
repo's **entire e2e/build/validate task tree** as "before" against one new
template task block as "after" (taking "after" would have deleted every
build/validate task in the repo). When the two sides are unrelated, the
resolution is keep-before **and separately graft** the after-side content at
its correct location — never a straight take.

**Many near-identical blocks? Rule-resolve them, then hand-do the rest.** A
heavily-forked repo can surface *dozens* of conflict blocks (harmon-infra: 13
files; sommerlawn-site: 16 files, 40+ blocks). Eyeballing every one is slow and
error-prone, and most are the **same** mechanical swap — overwhelmingly the
v3.19.0 `CI_RUNS_ON` switch (`runs-on: [ "ubuntu-latest" ]` →
`runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '"ubuntu-latest"') }}`), which
conflicts wherever the repo's `runs-on` spelling had drifted (`['ubuntu-latest']`
single-quote, plain `ubuntu-latest`, …). Write a tiny throwaway resolver that
decides **by before-side content** — take the template's "after" when the
before-side is exactly a `runs-on:` line (adopt the switch), otherwise keep the
repo's side — and let it clear the bulk, printing anything it doesn't recognize
for you to hand-resolve. That isolates the genuinely-nuanced blocks (production
URLs, fork-guards, `settings.json` merges) from the mechanical noise. **Always
re-scan for duplicate keys afterward** (`grep` each re-listed target/key): a
scripted or spanning take can duplicate a `Taskfile`/JSON key that also lives
elsewhere, which `yamllint key-duplicates` / a `task --list-all` parse failure
only catches after the fact.

**The template absorbed something this repo pioneered → add/add conflict; keep
yours.** A canonical convention repo's innovations get *generalized* and upstreamed;
on its next update, the template's new generic version collides with the repo's
specific original (an add/add conflict on, e.g., `scripts/validate-*.mjs`). Keep the
repo's specific version (`git checkout --ours <file>`) — the generic one is for
*other* repos. Recognise this when a file you know the repo authored shows up as a
conflict against a near-identical-but-blander template version.

> Two refinements from real updates:
>
> - **Shared-file absorb → silent duplicate, no marker.** When the pioneered content
>   lives in a *section of a shared file* the template also writes elsewhere (e.g. a repo
>   pioneered the Terraform state/`*.tfvars` ignores in `.gitignore`, later generalized
>   into the template's own `.gitignore` block), copier adds the template's version in a
>   *different* spot — no conflict marker, a silent **duplicate**. Scan the file for
>   template-added lines that duplicate the repo's pioneered section and trim the
>   redundant side: adopt the template's now-canonical block, keep only the repo's unique
>   extras (including any intentional `!negation` for a deliberately-tracked file).
> - **Identical/superseded content → take the *template*, not "yours".** "Keep yours" fits
>   when the repo's version is *more specific*. When the pioneered content is
>   *functionally identical* to what got upstreamed (e.g. a `pnpm-workspace.yaml` the
>   template later shipped near-verbatim), take the **template** version instead: same
>   behavior, and it ends the perpetual `DRIFT` so future updates stop conflicting.

**Doc/guide "after" that grows the prose → check for redundancy before adopting.**
copier only shows you the *conflicting hunk*, not the rest of the file. When a
template update *expands* a doc's intro (e.g. a `docs/guides/deploying.md` intro
that grows Preview/Production/Credentials bullets), the repo often **already has**
richer, repo-specific sections covering exactly that content further down — outside
the conflict, so you can't see them at resolve time. Naively taking the "after"
then leaves the template's generic summary duplicating the repo's own detailed
sections. Before adopting an expanded doc hunk, read the whole file: if later
sections already cover it, the right resolution is usually `git checkout main --
<doc>` (the repo's version is richer) plus grafting any single genuinely-new line.

**A template that *tightens a quality gate* is a per-repo decision — treat it like
a conflict even when copier merges it cleanly.** When an update raises a threshold
the repo's existing content must clear — a Lighthouse score
(`categories:accessibility` minScore `0.85 → 1.0`, harmon-init v3.18.0), a coverage
floor, a lint-severity bump — adopting it can turn a mechanical *sync* PR **red** on
content the update never touched. Don't silently take the stricter value: keep the
repo's current threshold if its content doesn't yet pass, and file the bump as
separate content work. (Real case: sommerlawn-site's blog page scored a11y 0.92, so
the 1.0 gate failed CI; reverting that one `lighthouserc.json` line to 0.85 kept the
update PR clean. evanharmon-site already met 1.0, so it kept the raise — it *is*
per-repo.) This class is doubly dangerous because the local gate misses it — see §4.

**Bunch/Obsidian util targets — self-contained `bunch-add` vs. the template's
add+install split.** The template splits the macOS-launcher helpers into
`util:bunch-add` (scaffolds `.meta/*.bunch` via `scripts/meta-create.sh`) +
`util:bunch-install` (moves it to iCloud) — same for `util:obsidian-*`. Older repos
instead have a **self-contained `util:bunch-add`** that writes the launcher straight
to iCloud with a hardcoded heredoc (no `.meta` step, no `install` target). On update,
copier interleaves the two models — naively taking the "after" side leaves a new
`util:bunch-install` whose input (`.meta/*.bunch`) the repo's direct-write `bunch-add`
never produces, and the repo's real heredoc dangles as if it were the install cmds.
These are low-stakes, macOS-only helpers, so pick ONE model cleanly: either adopt the
template's full add+install pair (drop the heredoc) or keep the repo's self-contained
`bunch-add` (and don't add a stray `install`) — do not mix. Keep the `docs/CHECKLIST.md`
Bunch/Obsidian line consistent with whichever you chose.

**`.release-please-manifest.json` — keep the repo's real version, and check it isn't
stale.** copier seeds this at `0.0.0`, so every released repo conflicts on it — keep the
repo's version, never the seed. harmon-init freezes it via `_skip_if_exists` (PR #252),
which ends the conflict on repos updated after that lands. But freezing does **not** fix a
manifest that is already *wrong*: a repo on manual `task release:*` with dormant
release-please can have a manifest that silently lags the latest tag (seen at `0.1.0` while
the repo was really at `v0.0.22`), and neither `diff-template.sh` (the file is
release-please-gated) nor `task verify` catches it. On update, reconcile the manifest to the
repo's actual latest release tag. Recording the baseline does **not** cut a release.

**`.claude/skills` is SHARED — local skills are first-class; upgrade legacy
provenance stamps once.** The sync-skills engine manages **only** the vendored
skill dirs listed on the provenance `# managed:` line in
`.claude/skills/.SKILLS_PROVENANCE`. Any other directory there is a **local
skill** the repo owns — create/edit/delete it normally; `task sync:skills` and
both verify modes never touch or report it. Never "clean up" an unlisted skill
dir during an update: it is not drift, it is the repo's own work. If a local
dir's name collides with an incoming vendored skill, the sync dies loudly
*before deleting anything* — rename the local skill or drop its category from
`.skills-sync.yaml`; don't force it through. After updating a repo past the
managed-set engine change, run `task sync:skills` **once** to upgrade a legacy
provenance stamp (one with no `# managed:` line): the engine derives the owned
set from the OLD pin, so local skills added after the legacy sync are never
claimed. Bumping the skills pin is always the same manual pair: bump `ref` in
`.skills-sync.yaml` → `task sync:skills` → commit both together (Renovate can
bump the ref but cannot run the re-sync half, so never merge a ref bump
without the accompanying re-sync).

**web repos: the shipped `tests/a11y.spec.ts` requires its deps or the whole
Playwright run breaks.** The spec imports `@axe-core/playwright` (and needs
`@playwright/test`); if the repo doesn't have them installed, `astro check` /
`tsc` fails on the import **and** the entire Playwright run breaks loading the
spec — not just the a11y test. Pair the spec with the dep install in the same
update, keep its chromium-only skip guard, and place it under the repo's
*actual* `testDir` (check `playwright.config.*` — it isn't always `tests/`).

**`scripts/e2e-env-guard.sh` ships fail-closed — configure it during the
update or `task test:e2e` turns red.** On a repo with a WORKING e2e suite, the
freshly-adopted guard blocks the run until it's configured (providers + prod
domains). Configure it as part of the update, or explicitly defer adoption —
**never delete the guard** to get the suite green.

**Split-workflow repos:** Follow the [template CI gate placement
rule](standards-catalog.md#template-ci-gate-placement) when grafting CI changes;
inspect live job tasks instead of copying template job names.

**web-astro: the `pnpm-workspace.yaml` (#248) requires pnpm 11+.** Its `allowBuilds` approval
map is a pnpm-11 setting (it replaced pnpm 10's `onlyBuiltDependencies` list); the file
itself — settings-only, no `packages:` — is invalid on pnpm 9. So adopting it below pnpm 11
misbehaves: pnpm 9 aborts *every* command (`packages field missing or empty`), pnpm 10
silently ignores `allowBuilds` (build scripts stay blocked → `wrangler deploy` can fail
`ERR_PNPM_IGNORED_BUILDS`). Check the repo's `packageManager` pin: on pnpm 11+, adopt it;
below that, upgrade pnpm first, or **defer** the file (keep the repo's working approvals) and
track the pnpm upgrade as separate work.
