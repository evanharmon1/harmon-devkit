# Mode: Audit

Audit an existing repo against the harmon-init conventions, report the drift, and
reconcile it. Use this mode when the goal is to **assess and remediate** a repo
(generated from the template or not) rather than scaffold a new one.

Source of truth: the harmon-init template at `~/git/harmon-init` (the `template/`
subdirectory is what gets generated; the repo root "dogfoods" the same conventions
for maintaining the template). The per-area checklist lives in
[`references/standards-catalog.md`](./standards-catalog.md) — that catalog is the
authoritative list of what "standardized" means; this file is the **procedure** for
walking it against a target and fixing gaps.

---

## 1. Running the audit

Work the target repo area-by-area, in the same order the catalog
([`references/standards-catalog.md`](./standards-catalog.md)) presents them. For
each area: read the catalog entry, inspect the corresponding files in the target,
and compare against the template. Do not assert a gap from memory — verify it.

### Setup

```bash
TARGET=/abs/path/to/target-repo      # the repo being audited
TEMPLATE=~/git/harmon-init           # source of truth
```

1. **Establish provenance.** Check whether the repo was generated from the
   template: look for `.copier-answers.yml` at the target root.
   - Present → it can be reconciled with `copier update --trust` (it records
     `_commit` / `_src_path`). Note the recorded commit; drift is "template moved
     ahead since then." **Also check `_src_path` is a resolvable git URL** — if it's
     a relative/machine-local path (e.g. `harmon-init`), `copier update` aborts with
     `Updating is only supported in git-tracked templates`; normalize it to
     `https://github.com/evanharmon1/harmon-init` first (a real finding — see
     [copier-gotchas.md](./copier-gotchas.md) gotcha 8 / [mode-update.md](./mode-update.md) §2).
   - Absent → it was never templated (or was adopted by a raw `copier copy`).
     Reconciling the templated bits means a fresh adopt:
     `copier copy --trust ~/git/harmon-init . --vcs-ref=HEAD` (see §4). Treat
     every catalog area as hand-verifiable rather than diff-against-answers.

2. **Walk each catalog area against the target.** For every area in
   `standards-catalog.md`, do the three-way check:
   - What the catalog requires.
   - What the template actually ships (read the real file under
     `$TEMPLATE/template/...`, or the dogfooded root copy — do not guess paths,
     task names, or tool versions).
   - What the target currently has.

   Useful evidence-gathering commands (read-only; never mutate the target during
   the audit phase):

   ```bash
   # AGENTS.md symlink direction (see drift class A)
   ls -la "$TARGET" | grep -iE 'AGENTS|CLAUDE|GEMINI'
   ls -la "$TARGET/.github/copilot-instructions.md" 2>/dev/null

   # Docs layout (drift class B)
   find "$TARGET/docs" -maxdepth 2 2>/dev/null | sort
   ls -d "$TARGET/specs" "$TARGET/tests" 2>/dev/null

   # Workflow inventory + extensions (drift classes E, F, G, H)
   ls -la "$TARGET/.github/workflows/"

   # Renovate/version-pin annotations (drift class C)
   grep -rnE 'GITLEAKS_VERSION|setup-task|# renovate:' "$TARGET/.github/workflows/" 2>/dev/null

   # Required status checks / merge_queue in the ruleset (drift class D)
   find "$TARGET/.github" -iname '*ruleset*'
   ```

3. **If `task` is available in the target**, run the standard gates as a live
   signal of conformance (they are themselves part of the standard):

   ```bash
   ( cd "$TARGET" && task verify )    # check (lint) -> test:template
   ( cd "$TARGET" && task security )  # secrets (gitleaks) + audit
   ```

   A repo missing `task verify` / `task security`, or whose tasks don't delegate
   lint to a Taskfile target, is itself a finding (the standard is "every hook /
   CI job delegates to a `task` target").

4. **Record each comparison as a gap-report line** (format in §2). Skip nothing:
   an area that fully matches is recorded as "OK" so the report is a complete
   ledger, not just a problem list.

---

## 2. Gap-report format

Produce one report, grouped by catalog area, in the catalog's order. Each finding
carries a **severity** and a **concrete fix** (the exact file/edit/command, not
"fix the workflow"). Severities:

- **blocker** — breaks a required CI gate, security control, or the branch
  ruleset; or makes `task verify` / `task security` fail. Must be fixed before the
  repo is "standardized."
- **should** — a real convention divergence with no immediate breakage (stale job
  names that still pass, missing docs scaffold, un-annotated version pins). Fix in
  the same pass unless explicitly deferred.
- **nice** — cosmetic / low-risk normalization (naming consistency, legacy
  graveyard cleanup).

### Template

```markdown
## <Area name, matching standards-catalog.md>

- [blocker] <one-line gap>
  - Evidence: <path:line or command output proving it>
  - Fix: <exact change — file to edit, command to run, or "re-template (§4)">
- [should] <one-line gap>
  - Evidence: ...
  - Fix: ...
- OK — <areas/items that already conform> (so the ledger is complete)
```

End the report with a short **Reconciliation plan**: the ordered list of fixes,
which ones a `copier` re-template will resolve automatically vs. which need a
hand-edit, and the verification command set from §4.

---

## 3. Common drift classes to check

These are the recurring divergences observed when porting real repos onto the
template (seeded from `~/git/harmon-init/docs/sourceRepoFollowUps.md`). Treat the
list as a checklist of likely findings — confirm each against the target before
reporting, and map each to its catalog area.

**A. AGENTS.md symlink direction.** Canonical layout: `AGENTS.md` is the real
file; `CLAUDE.md`, `GEMINI.md`, **and `.github/copilot-instructions.md`** are
symlinks to it (copilot's default path is `.github/copilot-instructions.md` →
`../AGENTS.md`). Old repos invert this (`CLAUDE.md` real, the rest symlinked).
Fix: make `AGENTS.md` canonical, repoint the three symlinks, and flip the
prettier/lefthook symlink excludes (the template lefthook `pre-commit` prettier
step excludes `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md` because
prettier errors when handed a symlink). Severity: **should** (blocker if a hook
fails on the symlink). `_preserve_symlinks: true` in `copier.yml` keeps these as
symlinks on re-template.

**B. Docs layout drift.** Standard docs tree (from `template/docs/`):
`docs/README.md`, `docs/architecture/{README,ci-cd,branch-protection,security,tests}.md`,
`docs/glossary.md`, `docs/conventions.md`, `docs/guides/{README,onboarding,deploying,troubleshooting}.md`,
`docs/product/{README,vision,domain,roadmap}.md`, `docs/decisions/` (ADRs, seeded
with `0001-record-architecture-decisions.md` + `README.md`), and
`docs/runbooks/` — **plural `runbooks/`** (matches harmon-infra; old repos use
singular `runbook`). Also: `specs/` and `tests/` belong at **repo root**, not
under `docs/` (old repos nest `docs/specs/`). Common misses: no `guides/`, no
`product/`, no ADR dir, no `architecture/tests.md` or `glossary.md`. Fix: move
`docs/specs/` → `specs/`, rename `runbook/` → `runbooks/`, and add the missing
scaffold (a re-template fills these in; rename/move are hand-edits because copier
won't delete the old paths). Severity: **should**.

**C. Version pins lacking renovate annotations.** `gitleaks` and `arduino/setup-task`
must be pinned with a managed-version annotation so Renovate bumps them. Template
standard (verify against the real workflow — versions move):
- gitleaks via a `GITLEAKS_VERSION=...` env line preceded by
  `# renovate: datasource=github-releases depName=gitleaks/gitleaks extractVersion=^v?(?<version>.+)$`
- go-task via `arduino/setup-task@<sha> # v2.0.0` with `version:` preceded by
  `# renovate: datasource=github-releases depName=go-task/task extractVersion=^v(?<version>.+)$`

Old repos pin divergent, un-annotated versions (e.g. gitleaks 8.24.3 vs 8.21.2;
setup-task 3.51.1 vs 3.49.x). Fix: copy the annotated pin blocks from the current
template `build.yml`; do **not** hardcode a version from this doc — read the live
value from `$TEMPLATE/.github/workflows/build.yml`. Severity: **should** (blocker
if an unpinned/missing tool breaks the `security` job).

**D. Stale branch ruleset / old job names / missing `merge_queue`.** Canonical
ruleset (`template/.github/Branch Protection Ruleset - Protect Main.json`) requires
exactly two status-check contexts — **`verify`** and **`security`** — plus a
**`merge_queue`** rule. Old repos reference retired job names (`secrets`,
`validate`, `build-homepage`) and lack the merge-queue rule. Note this drift can
also live in *prose*: even the harmon-init root `docs/architecture/branch-protection.md`
still narrates the old `secrets`/`validate`/`build-homepage` contexts while the
shipped ruleset JSON is already `verify`+`security` — so check the JSON, not just
the doc. Relatedly, ambiguous `verify` contexts: if both `build.yml` and the
devcontainer workflow define a job literally named `verify`, either can satisfy
the required check — the template renames the devcontainer job to
**`devcontainer-verify`**. Fix: re-import the ruleset via the GitHub UI
(Settings → Rules → Rulesets → **Import a ruleset**; avoid `gh api … rulesets`,
which is non-idempotent and rejects the `merge_queue` rule), rename the
devcontainer job, and align CI job names to `verify` + `security`.
Severity: **blocker** (wrong contexts mean the gate is unenforced or unsatisfiable).

**E. YAML file extensions — NOT drift; do not flag.** `.yml` vs `.yaml` is left
to each tool's own convention (`Taskfile.yml`, `.coderabbit.yaml`, GitHub Actions
accepts either). Never rename a tool's file to homogenize extensions across the
repo. Severity: **none** (listed only so audits don't wrongly raise it).

**F. Duplicate / `-max` Claude workflows to consolidate.** Standard set is exactly
three: `claude-plan.yml`, `claude-implement.yml`, `claude-review.yml`. Old repos
carry duplicates like `claude-review-max.yml` / `claude-implement-max.yml`. Fix:
delete the `-max` duplicates, keep the three canonical workflows. Severity:
**should** (blocker if a duplicate fires redundant/conflicting automation).

**G. Missing `codeql.yml`.** The template ships a CodeQL workflow gated on
`use_node or use_python` (`template/.github/workflows/[% if use_node or use_python %]codeql.yml[% endif %].jinja`).
Repos with Node/Python code but no `codeql.yml` are missing static analysis. Fix:
add `codeql.yml` from the template (a re-template with the right answers includes
it). Severity: **should**.

**H. lint-hygiene script portability to macOS bash 3.2.** `scripts/lint-hygiene.sh`
must be portable: **no `mapfile`, no `grep -P`** (both Linux/bash-4-only), and it
must self-skip in a path-independent way (skip any copy of the script so its own
pattern strings don't match) and skip symlinks (the AGENTS.md aliases). Old infra
copies use `mapfile` + `grep -P` and a brittle self-skip. Fix: replace with the
template version (`$TEMPLATE/scripts/lint-hygiene.sh`). Severity: **blocker** if
`task lint:hygiene` errors on macOS; otherwise **should**.

**I. Brewfile ↔ local-tooling parity (run-locally goal).** The repo must be able
to run its tooling on a **bare host**, not only in the devcontainer (catalog 1.11
"Local ↔ devcontainer parity"). Every binary the `Taskfile`, lefthook hooks, and
`scripts/` invoke must be installable via the `Brewfile`; when a devcontainer
exists, the same toolset must also be in the devcontainer `Dockerfile`. The
recurring miss: a binary added to the `Dockerfile` (so it works in-container) but
never added to the `Brewfile`, so the matching `task` fails on a fresh host
(observed with `gum` — the `status` dashboard renderer — and `television`/`tv` —
the interactive `task` menu; also `tokei`). Build the invoked-tool set and diff it
against the `Brewfile`:

```bash
# Tools the repo invokes (tasks + hooks + scripts), then what Brewfile installs
grep -rhoE '\b(gum|tv|television|tokei|jq|yq|fzf|fd|ripgrep|bat|shfmt|shellcheck|actionlint|yamllint|gitleaks|snyk|hadolint|lychee|direnv|terraform|terraform-docs|tflint|black|ansible-lint|pip-audit|uv|uvx|pnpm|node|npx|gh|lefthook|delta)\b' \
  "$TARGET/Taskfile.yml" "$TARGET/lefthook.yml" "$TARGET"/scripts/*.sh 2>/dev/null | sort -u
grep -oE 'brew "[^"]+"' "$TARGET/Brewfile" | sort -u
# If a devcontainer exists, the Dockerfile should cover the same set:
grep -rnE 'ARG .*_VERSION|apt-get install' "$TARGET"/.devcontainer/*ockerfile* 2>/dev/null
```

Map invoked binaries to their brew formula (note the names differ: `tv` →
`television`, `rg` → `ripgrep`, npx/pnpm-run tools resolve through `node`/`pnpm`,
`black`/`ansible-lint`/`pip-audit` through `uv`). Anything invoked but not
installable is a gap. Fix: add the missing `brew "<formula>"` to the `Brewfile`
(template owns it — prefer `copier update`, else hand-add), and to the
devcontainer `Dockerfile` if one exists. Severity: **blocker** if the missing
tool makes a routine `task` target fail on a host (e.g. bare `task` → `tv`);
**should** if the task degrades gracefully (e.g. `status` without `gum`).

**Also seeded from sourceRepoFollowUps (verify per repo):** legacy-bloated
`Brewfile` (deprecated formulae, missing gitleaks/yamllint/actionlint); CI that
reinstalls lint tools inline every run instead of using the prebuilt devcontainer
image / a composite action; auto-release-on-merge `release.yml` (standard is
release-please — an intentional rolling release PR, `use_release_please: yes` by
default; `task release:*` stays a manual override); stale `CHECKLIST.md`
(mentions pre-commit/cookiecutter); naming inconsistency between
workspace/bunch/slug files and the repo slug. Map each to its catalog area and
assign severity by the §2 rubric.

**J. Missing universal Taskfile targets (e.g. `status:setup`).** Every
standardized repo defines the universal targets from
[`standards-catalog.md`](./standards-catalog.md) §1.2 regardless of
`project_type` — notably `verify`, `check`, `security`, `install:hooks`, and
**`status:setup`** (the setup-completeness audit, `./scripts/status.sh setup`).
Repos whose `Taskfile` / `scripts/status.sh` predate or forked away from the
template often lack `status:setup` (the older `status.sh` had no `setup`
section). Detect by listing targets (`task --list-all`) and checking the
universal set; `assets/verify-applied.sh` enforces this. Fix: port the
setup-check helpers + the "Setup Completeness" section from the template's
`scripts/status.sh` (preserving any repo-specific sections) and add the
`status:setup` task. Severity: **should**.

**K. Template-owned file content drift (the general check).** The generalization of
H/J and the bootstrap/idempotency class: any **template-owned** file (the set in
[`assets/template-owned-files.txt`](../assets/template-owned-files.txt) —
`Taskfile.yml`, `scripts/*.sh`, lint configs, the standard `.github/workflows/*`,
devcontainer files) that no longer matches a fresh render is potentially missing
template improvements. Detect it mechanically — this is how the audit "checks
everything" instead of eyeballing each file:

```bash
~/git/harmon-devkit/ai/skills/repo/standardize-repo/assets/diff-template.sh "$TARGET"
# --show to see the per-file diff
```

It renders harmon-init from the repo's own `.copier-answers.yml` and reports both
content **`DRIFT`** in the curated set and **`MISSING`** template files the repo
lacks entirely (mapping `.yml`↔`.yaml`). The `MISSING` scan walks the whole render
and is **manifest-independent**, so a file the template added after the curated list
was last edited — or one a hand-reconciled update dropped — is still caught
(`.gitkeep` dir-stubs show as benign `ABSENT`). Each `DRIFT` is either a
**missed template improvement** or a **legitimate local customization** — read the
diff to tell them apart. Fix the former with `copier update`
([`mode-update.md`](./mode-update.md)) or by copying the template's version; leave
the latter, reconciling **in place** (keep the customization in its normal file — do
not extract it elsewhere). Severity: **should** (blocker if the drift breaks a
required gate, e.g. a non-portable `lint-hygiene.sh`). Run this as a standard step of
every audit.

---

## 4. Fix flow

Apply fixes on a branch, prefer re-templating for files copier owns, then verify.

1. **Branch.** Never commit to `main` (the template enforces a
   `guard:no-commit-to-main` lefthook hook + a branch ruleset; respect it in the
   target too). Create a feature branch, e.g.:

   ```bash
   ( cd "$TARGET" && git switch -c chore/standardize-with-harmon-init )
   ```

2. **Apply fixes.** Two tracks — do the re-template first so hand-edits layer on
   top of refreshed templated files:

   - **Templated bits — re-run copier.** For files the template owns, reconcile
     rather than hand-porting:
     - Generated from the template (has `.copier-answers.yml`):
       ```bash
       ( cd "$TARGET" && copier update --trust )
       ```
     - Never templated / adopting fresh:
       ```bash
       ( cd "$TARGET" && copier copy --trust ~/git/harmon-init . --vcs-ref=HEAD )
       ```
     `--vcs-ref=HEAD` is **load-bearing**: from a local path copier otherwise
     renders the latest git tag and silently ignores committed-but-untagged work;
     with it, copier includes dirty/untracked template changes via a throwaway
     commit in a temp clone (your template working tree is untouched). Answer the
     questions to match the repo, and keep all side-effectful answers
     (`github_remote_create`, `github_release_init`, `bunch_add`,
     `obsidian_project_add`, `run_task_install`) at their **no** defaults so the
     adopt has no side effects. Review the resulting diff carefully and discard
     overwrites of intentional local divergences.

   - **Non-templated bits — hand-edit.** Copier won't *delete* or *move* files,
     so renames and relocations are manual: `git mv docs/specs specs`,
     `git mv docs/runbook docs/runbooks`, delete `-max`
     duplicate workflows, re-import the branch ruleset JSON (via the GitHub UI),
     repoint the AGENTS.md symlinks. Use the gap report's Reconciliation plan as the work
     list.

3. **Verify locally.** Run the same gates the standard requires, from the target:

   ```bash
   ( cd "$TARGET" && task verify )    # check (lint) -> test:template
   ( cd "$TARGET" && task security )  # gitleaks + dependency audit
   ```

   Fix anything red and re-run until clean. (`task verify` ≙ `task check` +
   `task test:template`; `task ci` additionally chains `test` and `security`.)

4. **Run the applied-state verifier.** Confirm the audited drift classes are
   actually resolved by running the skill's checker:

   ```bash
   ~/git/harmon-devkit/ai/skills/repo/standardize-repo/assets/verify-applied.sh "$TARGET"
   ```

   (See [`../assets/verify-applied.sh`](../assets/verify-applied.sh) — it should
   re-check the §3 drift classes against the target and exit non-zero on any
   remaining **blocker**. If the script isn't present yet in this skill, fall back
   to manually re-walking the gap report's Reconciliation plan.)

5. **Hand back.** Leave the changes committed on the feature branch with a
   Conventional-Commits message (e.g. `chore: standardize against harmon-init`)
   and open a PR for human + code-owner review — releases and merges stay
   intentional; do not merge or tag.
