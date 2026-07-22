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
git switch -c chore/update-harmon-init-v<X.Y.Z>   # e.g. chore/update-harmon-init-v3.20.0
```

**Use a version-suffixed branch name.** A bare `chore/update-harmon-init` often
already exists locally as a leftover from a prior run whose PR was
*squash-merged* — the local branch is never deleted, and its commits look
"unmerged" by SHA, so `git switch -c chore/update-harmon-init` aborts with
`a branch named '…' already exists`. Suffixing the target version
(`chore/update-harmon-init-v3.20.0`) sidesteps the collision and self-documents
the PR. (Deleting the stale local branch also works, but is destructive — prefer
the versioned name.)

## 1. See what's missing (read-only)

```bash
assets/diff-template.sh .
# add --show to print the full per-file diff
```

This renders harmon-init from the repo's own `.copier-answers.yml` and reports
the following result classes (mapping `.yml`↔`.yaml`):

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
  slip through silently. A tracked path deleted only from the working tree is
  compared from the index; staging that deletion makes it real `MISSING`.
  (`.gitkeep` dir-stubs show as benign `ABSENT`.) Some
  `MISSING` findings are **intentional divergences, not gaps** — see the
  known-false-`MISSING` list in [`mode-audit.md`](./mode-audit.md) §3 (drift
  class K) before "restoring" any of them (e.g. a repo using `.prettierrc.cjs`
  instead of the template's `prettier.config.cjs`).
- **`EQUIV`** — a mature nested Terraform layout or established/renumbered ADR
  log intentionally replaces a generated seed path. This is informational and
  does not fail the comparison.

Together these are your reconciliation worklist for §3.

### Preview the release and review new answers

Before accepting `--defaults`, identify both the target release and any Copier
questions added since the repo's recorded `_commit`:

```bash
copier check-update --output-format json .
git -C ~/git/harmon-init diff "$(yq -r '._commit' .copier-answers.yml)"..v<TARGET> -- copier.yml
```

Every newly introduced question needs an explicit decision. This is especially
important for a feature with a material footprint or an external capability:

- `use_foreman` adds its supervisor, agents, taskfile, configuration,
  documentation, and tests. It was default-on when introduced in v3.26.1;
  current template source defaults it off. Update mode must still decide whether
  the target should opt in.
- `use_codeql` includes CodeQL only when the matrix corresponds to planned/actual
  first-party JS/TS/Python source. `use_node` / `use_python` are tooling flags,
  not source evidence; review and persist the explicit `codeql_languages`
  multiselect alongside the selection. When these answers are new to the target,
  make that repository-aware decision in this PR instead of assuming an existing
  workflow must be preserved forever.
  Public repositories have GitHub Code Security by default. For a
  private/internal repo, perform a read-only capability check before selecting it
  — including when an older answer file has no `use_codeql` field:

  ```bash
  gh api "repos/<owner>/<repo>" \
    --jq '{visibility, code_security: (.security_and_analysis.code_security.status // "unknown")}'
  ```

  If Code Security is disabled and will not be enabled, pass
  `--data use_codeql=false`; the update must remove the workflow, badge,
  `FULL_SECURITY_SCAN` setup, and CodeQL coverage claims. If the API field is
  unavailable because the caller lacks permission, verify the capability in
  **Settings → Code security** rather than inferring it. A workflow file or
  `FULL_SECURITY_SCAN=true` proves configuration, not successful SARIF coverage.
  Require the fail-closed result contract: the workflow maps the scan decision
  to one expected result, and the shared helper accepts only that exact result.
  Trusted events conditionally check out and execute the helper; fork aggregates
  must not execute repository code and use the workflow-inline deliberate-skip
  diagnostic.

- `include_terraform=true` now carries a reachable four-part lint contract:
  format, TFLint, pinned Checkov, and a provider-lock check. Reconcile customized
  Taskfiles by proving both `task --dry lint:terraform` and `task --dry check`
  reach all four commands, and keep Terraform/TFLint/uv reachable locally and in
  CI. Adopt `scripts/terraform-provider-locks.sh` plus its hermetic regression;
  the check/update task paths generate exactly `darwin_arm64` and `linux_amd64`
  checksums. Update-mode scratch initialization must pass `-upgrade`, while
  check-mode initialization must omit it. Do not accept a pre-existing
  `.terraform.lock.hcl` as proof of that process.

Pass each reviewed answer with `--data`, even when the decision happens to match
the current default.

Preview the exact answer set before the real update:

```bash
: "${USE_CODEQL:?set USE_CODEQL=true or false after the capability review}"
copier update --trust --defaults --pretend \
  --data use_foreman=false \
  --data use_codeql="$USE_CODEQL"
```

`--pretend` confirms rendering succeeds but its output can be terse. For a heavily
customized or high-impact repo, make a disposable clone under a temporary directory,
run the same update there without `--pretend`, and inspect its full `git diff` before
touching the working branch. A preview complements the pinned-baseline drift report;
neither replaces the post-update reconciliation in §3.

## 2. Run the update

**Preflight — ensure the recorded lineage tuple is resolvable.** `copier update`
reuses both `_src_path` and `_commit` from `.copier-answers.yml`. A relative or
machine-local path may abort with `Updating is only supported in git-tracked
templates`; changing that path alone is safe only when the recorded commit is
reachable from the canonical remote (see [copier-gotchas.md](./copier-gotchas.md)
gotcha 8). Inspect both fields:

```bash
grep -E '^(_src_path|_commit):' .copier-answers.yml
```

If `_src_path` is local, first prove `_commit` exists on the canonical remote.
Then update and commit the tuple together. If it is a dirty-render throwaway or
otherwise unreachable, do not fabricate lineage by swapping only the path or
commit; re-adopt from the canonical GitHub URL at a reviewed released ref.

```bash
copier update --trust --defaults \
  --data <new-question>=<reviewed-answer>
```

**`--defaults` is mandatory when running non-interactively (agents have no TTY),
but it is not permission to accept newly introduced behavior.** Review and pass
new answers explicitly as described above. Without `--defaults`, Copier tries to
prompt for answers and crashes with
`OSError: [Errno 22] Invalid argument` (prompt_toolkit can't attach to a missing
terminal). It reuses the stored answers and accepts defaults for any new questions
the template added since `_commit`; explicit `--data` values override those
defaults and are recorded in `.copier-answers.yml`.

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
customizations. harmon-infra is the standing example of renamed twins — though it
has since renamed its workflows and `Taskfile.yml` *back* to `.yml`, leaving only
`lefthook.yaml` renamed there; so confirm which files a repo *currently* renamed (a
`DRIFT` on a `.yaml` twin) rather than assuming a whole class always needs the port.

**The hand-port is only needed when the skipped delta actually intersects the
repo.** Diff the template range first (above) and check whether the change is
gated on a copier flag the repo doesn't have. Example: for the v3.16→v3.20
range the *only* `lefthook` change (v3.18.1, a `.meta/*.md` prettier exclude)
lives inside the `[% if use_node %]` prettier hook — so an **iac** repo with a
renamed `lefthook.yaml` (no `use_node`, no prettier hook) needs **no** port for
that range even though the file was skipped. Don't assume every renamed file
needs porting on every update; confirm the delta is non-empty *for this repo's
answers* before hand-editing.

**Diff the template's script inventory across the range — renames leave orphans
copier never deletes.** The three-way merge is path-keyed, so when the template
*renames* a shipped helper the repo keeps the old file silently, and every
workflow/Taskfile reference to it keeps "working" against stale code:

```bash
# -r: recurse — shipped subtrees (scripts/foreman/…) hide renames from a
# top-level listing
diff <(git -C ~/git/harmon-init ls-tree -r --name-only <old> template/scripts/) \
     <(git -C ~/git/harmon-init ls-tree -r --name-only <new> template/scripts/)
```

For each file that disappeared or was renamed: `grep -rn` the repo for
references, repoint them at the canonical successor, and delete the orphan —
an intentional repo-owned keeper is the exception, not the default. **Before
deleting, diff the repo's copy against its own template baseline**
(`git -C ~/git/harmon-init show <old>:template/<path>` vs the repo file): a
locally-modified orphan carries repo-specific behavior the canonical
successor lacks — port that intentional delta to the successor first, the
same judgment call as any DRIFT. Real case
(harmon-infra v4.0.0→v4.3.1): five orphans — `shell-quality.sh` (→
`format-shell.sh` + `lint-shell.sh`), `verify-required-results.sh` (→
`verify-ci-results.sh`), its truth-table test, and two CodeQL helpers — with
stale references in two workflows, the Taskfile, and `test-tasks.sh`.

**Answer flips do NOT show in this diff — sweep them explicitly.** A file
gated on a copier answer (`[% if use_codeql %]…`) exists in the raw template
tree at *both* refs, so flipping the answer off (e.g. `use_codeql=false`)
produces an empty inventory diff while still orphaning that feature's
helpers. Copier deletes the cleanly-tracked rendered copies on the flip, but
hand-copied or locally-modified ones survive — when an update turns a
feature answer off, separately `grep -rn` the repo for the disabled
feature's scripts, workflow steps, Taskfile targets, and doc claims, and
remove them with the same reference-repoint-then-delete discipline.

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

**Split-workflow repos: graft template CI additions into whichever job
actually runs `task check`.** Template CI additions (the skills drift check,
new lint steps) target `build.yml`'s `lint` job. A repo with a split workflow
layout (e.g. harmon-infra) doesn't have that job — graft the additions into
the job that actually runs `task check` (harmon-infra: `validate.yml`, feeding
`validate-verify`), not into a dead copy of `build.yml`.

**web-astro: the `pnpm-workspace.yaml` (#248) requires pnpm 11+.** Its `allowBuilds` approval
map is a pnpm-11 setting (it replaced pnpm 10's `onlyBuiltDependencies` list); the file
itself — settings-only, no `packages:` — is invalid on pnpm 9. So adopting it below pnpm 11
misbehaves: pnpm 9 aborts *every* command (`packages field missing or empty`), pnpm 10
silently ignores `allowBuilds` (build scripts stay blocked → `wrangler deploy` can fail
`ERR_PNPM_IGNORED_BUILDS`). Check the repo's `packageManager` pin: on pnpm 11+, adopt it;
below that, upgrade pnpm first, or **defer** the file (keep the repo's working approvals) and
track the pnpm upgrade as separate work.

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

Current harmon-init renders a hermetic `test:tasks`: fake `brew`, `npm`, and
`curl` commands exercise bootstrap without installing or updating shared
machine tooling. If a target still carries the older live-tool version, port the
current test before parallel fleet verification; until then, run those repo gates
serially so concurrent audits cannot contend on or mutate shared package-manager
state.

Review reconciled workflows semantically, not only syntactically: compare
`push`/`pull_request`/`merge_group`/`workflow_dispatch` events and inputs,
then each deploy/apply job's `if`, `needs`, permissions, and side effects.
Preserve deliberate manual Terraform apply or deploy paths. A green actionlint
run proves syntax, not trigger semantics.

**A green `task verify` does NOT cover the Lighthouse gates on web repos.** For
web-astro repos the a11y/perf/SEO assertions (`lighthouserc.json`) run in the
heavier CI `build-test` job via `task test:lighthouse` — which needs a full build
and a served site — **not** in `task verify` (the fast lint/build/validate gate
this skill runs). So a raised a11y gate (see §3) sails through `task verify` and
`verify-applied.sh` locally, then fails CI's `build-test`. If the update touched
`lighthouserc.json` or any a11y/perf threshold, either run `task test:lighthouse`
locally (build + serve) before opening the PR, or expect CI to be the gate that
catches a regression — and don't report "locally verified, all green" as if it
covered Lighthouse.

Walk the [`mode-audit.md`](./mode-audit.md) drift classes too — `copier update`
refreshes templated files, but renames/moves and GitHub-side settings it cannot do.
Re-run `diff-template.sh`: every remaining `DRIFT` should be an intentional local
customization you can explain, not a missed update. In particular, a `DRIFT` on a
file the repo *renamed* (e.g. `.yaml`) may be an update copier skipped, not a
customization — confirm against the §2 renamed-files note before dismissing it.

**Check the git hooks aren't shadowed or stale, too.** Even in an already-templated
repo two non-lefthook hook managers can lurk: a **pre-commit.com** stub in
`.git/hooks/pre-commit` (globally seeded by `~/.git-template`, silently no-oping next
to lefthook's hooks) and, in a **git-lfs** repo, a git-lfs `pre-push` that lefthook's
install shadowed to `pre-push.old` (LFS objects then stop uploading on push). Both are
covered under §5 / trap (a) of [`mode-adopt-existing.md`](./mode-adopt-existing.md) —
audit with `grep -rl 'generated by pre-commit' .git/hooks` and
`grep -l git-lfs .git/hooks/*`.

**iac repos: confirm no real Terraform state or tfvars got committed.** The v3.20.2
`.gitignore` (#243) ignores `*.tfstate`/`*.tfvars`, but it cannot untrack a file already
committed. After updating an iac repo, run
`git ls-files | grep -E '\.tfstate|\.tfvars' | grep -Ev '\.tfvars\.example$'` (the `.example`
exclusion skips the intended-to-commit placeholder). Any hit is a pre-existing tracked
state/vars file — don't delete it blindly: inspect it. It may be *deliberately non-secret*
config kept on purpose (e.g. harmon-infra's `terraform.tfvars` of server sizing + a
Cloudflare account id + a public SSH key, tracked via a `!` negation) — leave those alone;
flag any real secret for **rotation** (an ignore entry stops re-flagging, it does not
un-expose a committed key).

## 5. Hand off

Commit on the branch with a Conventional-Commits message
(`chore: update to harmon-init <version>`) and open a PR. Never bypass hooks; never
merge to `main` directly. Re-import the branch ruleset via the GitHub UI only if the
ruleset JSON changed (see [`post-generation-checklist.md`](./post-generation-checklist.md)).
