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
     ahead since then." **Also check `_src_path` and `_commit` form a resolvable
     lineage tuple.** A relative/machine-local path can make `copier update` abort
     with `Updating is only supported in git-tracked templates`, but do not
     rewrite the path alone unless the recorded commit is reachable from the
     canonical remote (a real finding — see
     [copier-gotchas.md](./copier-gotchas.md) gotcha 8 / [mode-update.md](./mode-update.md) §2).
   - Absent → it was never templated (or was adopted by a raw `copier copy`).
     Reconciling the templated bits means a fresh adopt:
     `copier copy --trust --vcs-ref=v3.26.1
     https://github.com/evanharmon1/harmon-init.git .` (substitute the reviewed
     current release; see §4). Treat
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

   # Required checks and account-appropriate merge_queue policy (drift class D)
   find "$TARGET/.github" -iname '*ruleset*'
   ```

3. **If `task` is available in the target**, run the standard gates as a live
   signal of conformance (they are themselves part of the standard):

   ```bash
   ( cd "$TARGET" && task verify )    # repo's fast check/build/validate/guard gate
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
template. Treat the list as a checklist of likely findings — confirm each
against the target before reporting, and map each to its catalog area.

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

**D. Stale branch ruleset / old job names / wrong `merge_queue` policy.** Canonical
ruleset (`template/.github/Branch Protection Ruleset - Protect Main.json`) requires
the baseline contexts **`verify`** and **`security`**, plus
**`terraform-verify`** exactly when `include_terraform=true`. It does not currently
require `codeql-verify`. The
**`merge_queue`** rule is conditional: org repos
(`github_org != author_git_provider_username`) get it; personal-account repos do
not. Missing it is drift only for an org repo, while adding it to a personal repo
is itself drift. Old repos may reference retired job names (`secrets`, `validate`,
`build-homepage`) or carry the wrong account-type variant. Note this drift can
also live in *prose*: even the harmon-init root `docs/architecture/branch-protection.md`
still narrates the old `secrets`/`validate`/`build-homepage` contexts while the
shipped non-Terraform ruleset JSON is already `verify`+`security` — so check the
rendered JSON, not just the doc. Relatedly, ambiguous `verify` contexts: if both
`build.yml` and the
devcontainer workflow define a job literally named `verify`, either can satisfy
the required check — the template renames the devcontainer job to
**`devcontainer-verify`**. Fix: re-import the ruleset via the GitHub UI
(Settings → Rules → Rulesets → **Import a ruleset**) and choose the rendered
ruleset for the repo's account type. REST supports `merge_queue`, but a blind
`POST` is non-idempotent and can create duplicate rulesets; automation must
discover exactly one matching live ruleset and `PUT` that ruleset's id. Rename
the devcontainer job and align CI job names to the rendered required-check set.
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

**G. CodeQL source/selection/capability mismatch.** CodeQL has three gates: actual
first-party JS/TS/Python source, the explicit `use_codeql` answer, and a live
GitHub capability. `use_node` / `use_python` are tooling flags, not source
evidence. Compare the workflow's `javascript-typescript` / `python` matrix with
the tracked first-party source, excluding generated dependencies and config-only
tooling. Record an explicit `codeql_languages` multiselect/override as a
harmon-init source follow-up; until it exists, correct the rendered matrix during
reconciliation.

A `codeql.yml` file and `FULL_SECURITY_SCAN=true` prove configuration, not that an
analysis ran or GitHub accepted SARIF. Public repositories have Code Security by
default. Whenever the workflow exists, inspect capability read-only — even when a
legacy `.copier-answers.yml` has no `use_codeql` field:

```bash
gh api "repos/<owner>/<repo>" \
  --jq '{visibility, code_security: (.security_and_analysis.code_security.status // "unknown")}'
```

When Code Security is disabled/unavailable and will not be enabled, set
`use_codeql=false` and re-render: the CodeQL workflow, README badge,
`FULL_SECURITY_SCAN` setup, and positive coverage claims must disappear, while
`docs/architecture/security.md` names the first-party SAST gap. If the capability
will be enabled, enable it before selecting `use_codeql=true`, then verify a real
analysis and successful SARIF upload. The analyze job/action must not use
`continue-on-error: true`; unrelated best-effort cleanup does not make analysis
fail-open. On trusted events, `codeql-verify` conditionally checks out the repo and
calls `scripts/verify-codeql-result.sh` with `FULL_SECURITY_SCAN`, the explicit
fork decision, and `needs.analyze.result`. A fork aggregate must not check out or
execute fork-controlled repository code (especially on a configurable/self-hosted
runner); require the separate workflow-inline fork diagnostic instead. Exercise
the helper's hermetic truth table: unset/empty normalizes to disabled;
disabled/fork → `skipped`; enabled non-fork → `success`; enabled non-fork →
`skipped`, failure, cancellation, nonempty malformed values, and unknown states
all fail. If the API hides the field because of caller
permissions, record a manual **Settings → Code security** check instead of
inferring support. Severity:
**blocker** for fail-open result propagation, a predictably red SARIF upload, or a
false coverage claim; **should/manual residual** for an intentional, documented
SAST gap.

The current generated CodeQL workflow is fail-closed internally, but it lacks a
`merge_group` trigger and the generated ruleset does not require
`codeql-verify`; therefore it is not a merge-gating SAST control. Record this as a
high-priority harmon-init follow-up: remove the redundant `FULL_SECURITY_SCAN`
runtime gate when `use_codeql=true`, add `merge_group`, and conditionally require
`codeql-verify` in the ruleset in the same release.

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

**Additional recurring findings (verify per repo):** legacy-bloated
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
assets/diff-template.sh "$TARGET"
# --show to see the per-file diff
```

It renders harmon-init **at the repo's own `_commit`** (from its
`.copier-answers.yml`) and reports both content **`DRIFT`** in the curated set and
**`MISSING`** template files the repo lacks entirely (mapping `.yml`↔`.yaml`). The
`MISSING` scan walks the whole render and is **manifest-independent**, so a file the
template added after the curated list was last edited — or one a hand-reconciled
update dropped — is still caught (`.gitkeep` dir-stubs show as benign `ABSENT`).
An absent tracked path that still exists in the index is compared from an index
snapshot, so a transient, unstaged working-tree deletion does not create false
drift; once the deletion is staged it is real `MISSING`. Mature nested Terraform
roots and an established or renumbered ADR log are reported as benign `EQUIV`
instead of false `MISSING` and do not affect the exit status.
Because the render is at `_commit`, each **`DRIFT`** is the repo's **local
customization** relative to its own baseline — or a **regression** where a past
hand-reconcile dropped a same-baseline improvement (the status.sh / lint-hygiene /
bootstrap class). It is **not** a newer-version improvement — those arrive via the
`copier update` merge, not diff-template. Read the diff to tell them apart: restore
a regression (copy the template's version), and leave a deliberate customization,
reconciling **in place** (keep it in its normal file — do not extract it elsewhere). Severity: **should** (blocker if the drift breaks a
required gate, e.g. a non-portable `lint-hygiene.sh`). Run this as a standard step of
every audit.

**Recognized equivalents and remaining false-`MISSING` categories — verify
before "fixing".** Some apparent gaps are legitimate divergences, not missing
standards; re-adding the template's seed is wrong. The recurring ones:

- **chezmoi `private_`/`dot_` prefix** — a dotfiles repo names the template's root
  `Brewfile` `private_Brewfile` (→ `~/Brewfile`), so `Brewfile` reads `MISSING`. Add
  a root `Brewfile` per [mode-adopt-existing.md](./mode-adopt-existing.md) §4.7, not
  a "restored" copy.
- **ADR renumbering** — the seed `docs/decisions/0001-record-architecture-decisions.md`
  is `EQUIV` when the repo carries a renumbered record-decisions ADR or already
  has a README-backed numbered ADR log. Don't re-add — it would duplicate.
- **Replaced terraform skeleton** — an iac repo with real infra (e.g.
  `terraform/environments/…`) deleted the template's flat
  `terraform/{main,variables,outputs}.tf` skeleton. Nested `*.tf` roots make
  these seed paths `EQUIV`; leave the real layout in place.
- **Gitignored `.envrc`** — a repo that resolves `.envrc`/`.envrc.local` from an
  `.envrc.tpl` via `op inject` gitignores the resolved file, so it reads `MISSING`.
  Leave it (it's the secure pattern the template now ships).
- **`.prettierrc.cjs` vs `prettier.config.cjs`** — a web/node repo that uses the
  `.prettierrc.cjs` filename (higher precedence in Prettier's config search) instead
  of the template's `prettier.config.cjs` reads as `MISSING prettier.config.cjs`. An
  intentional filename divergence (like `.yml`/`.yaml`, drift class E), **not** a gap.
  `copier update` correctly leaves it alone — the file is unchanged between template
  versions, so nothing is added and no dead second config results. Confirm the repo
  actually has a `.prettierrc*`/`prettier` package.json key, then leave it.

**L. Workflow ↔ Taskfile/runtime contract.** Every `task <target>` referenced in
`.github/workflows/*.yml` must exist in `Taskfile.yml`. CI's `lint`/`build` jobs
call targets `task verify` never runs (e.g. `test:tasks`, `test:hooks`,
`test:devcontainer:permissions`), so a Taskfile that drifted from the template —
or was restored wholesale from a pre-template `main` during a Path-B adopt while
the template's workflows were taken as-is — can omit them. The result is the worst
kind of green: `task verify` (and `verify-applied.sh`'s §1 gate) passes locally
while CI goes **red**, because the gate doesn't exercise what CI does. Detect the
contract directly:

```bash
grep -rhoE '(run:[[:space:]]*|^[[:space:]]*|&&[[:space:]]*)task +[a-z][a-z0-9:_-]*' \
  .github/workflows/ | sed -E 's/.*task +//' | sort -u
# then assert each is in `task --list-all`
```

`assets/verify-applied.sh` (§3c) enforces this. Fix: port the missing targets and
their `scripts/*.sh` helpers from the template (or reconcile the preserved Taskfile
against the adopted workflows). Severity: **blocker** (the gate is unenforced and CI
is unsatisfiable until the targets exist).

A repo-specific test is a gate only when all three links exist: the root
`Brewfile`/`task install` provides its runtime locally, the workflow provisions
that runtime in CI, and the workflow invokes `task test` (or the specific target)
rather than a narrower `test:tasks`. Check this manually for every added test;
this audit found both Copier-backed skill tests and a chezmoi render test that
passed locally but were initially unreachable or unprovisioned in CI.

Target names are also insufficient to prove workflow semantics. Compare the
`on` events/inputs and each job's `if`, `needs`, permissions, and side effects
against the pre-update workflow. In particular, preserve intentional
`workflow_dispatch` deploy/apply paths and their guards; YAML/actionlint can be
green while a Terraform apply path has silently disappeared.

For every aggregate job under `if: always()`, inspect its result reduction.
Generic `success || skipped` acceptance is fail-open. A fork PR must require every
fork-suppressed leaf to be exactly `skipped` in a workflow-inline diagnostic that
does not check out or execute repository-controlled code. Same-repository and
non-PR events must require every required leaf to be exactly `success`.
Conditionally disabled leaves may skip only when the aggregate derives that exact
expectation from the same explicit change/enabled predicates. Apply this contract
to both build `verify` and `devcontainer-verify`; reject cancellation, timeout,
unexpected skip/success, and unknown states.

For Python CI that consumes an existing `uv.lock`, distinguish validation from
mutation. Exports must use `uv export --locked`; syncs must use
`uv sync --locked` (or first run `uv lock --check`). `--frozen` skips the
freshness check. Treat a stale lock or a tracked lock rewrite as a blocker; keep
lock creation and updates in explicit local/update workflows.

When `runs-on` is variable-controlled (for example, `CI_RUNS_ON`), audit both
repository visibility and event trust. Every public `pull_request` job must
resolve to a GitHub-hosted runner. A same-repository job guard is defense in
depth, not a complete trust boundary. Self-hosted use in private/trusted repos or
on trusted push/dispatch events also needs server-side repository-scoped runner
groups and clean ephemeral/JIT isolation; otherwise treat it as a blocker. This
is currently a manual residual: do not assume the template's configurable
`runs-on` expression mechanically enforces the hosted-only public-PR policy.

For a Terraform-capable repo (`include_terraform=true` or real first-party `.tf`
files), prove the local/CI lint chain before reviewing mutation. Both
`task --dry check` and `task --dry lint:terraform` must reach format check,
TFLint, Renovate-pinned Checkov through `uvx --from`, and the provider-lock check. The
root `Brewfile` must provision Terraform/TFLint/uv locally, and the build workflow
must provision the same capabilities before the shared task runs. Task names or
documentation without command/tool reachability are not coverage.

Then trace the Terraform workflow chain: change detection → validation → saved
plan → exact-plan apply → aggregate. A tracked `.terraform.lock.hcl` makes CI init
use `-lockfile=readonly`, but file presence alone says nothing about platform
checksums. Require `scripts/terraform-provider-locks.sh`: lint calls `check`, the
explicit `terraform:providers:lock` mutation task calls `update`, and the helper
targets exactly `darwin_arm64` + `linux_amd64` in a scratch copy. Run its hermetic
regression and prove update initialization receives `-upgrade` while check
initialization does not; otherwise a constraint bump beyond the committed lock
fails before `providers lock`, or check mode compares against upgraded selections
instead of the committed-lock semantics. A fresh no-provider scaffold may skip
cleanly. Only explicit fresh scaffolding may create the first lock, while an
intentional local provider update may refresh it.
Plan/apply must be downstream of validation, guarded/namespaced to the trusted
run, and apply must refuse to re-plan if the private run-scoped saved plan is
absent. Confirm the summary displays that same plan, state-lock waits are bounded
(never `-lock=false`), and cleanup runs under `if: always()`.

A required `terraform-verify` must always emit on `push`, `pull_request`,
`merge_group`, and `workflow_dispatch`, including unrelated-path no-ops; use an
internal change detector, not workflow-level path filters. Derive every accepted
`skipped` result from explicit fork/change/enabled predicates and reject all
other states. Agents must also retain the exact-operation approval rule for
Terraform mutation; only the reviewed trusted-main exact-plan CI path is exempt.

On workflows that may use self-hosted runners, reject shared fixed `/tmp`
filenames for sensitive or cross-step artifacts (especially saved Terraform
plans). Use a private per-repo/run directory beneath `${{ runner.temp }}`,
propagate the exact path, and clean it up so concurrent or later jobs cannot
read, replace, or collide with it.

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
       ( cd "$TARGET" && copier copy --trust --vcs-ref=v3.26.1 \
           https://github.com/evanharmon1/harmon-init.git . )
       ```

     Replace `v3.26.1` only with a deliberately selected newer release. A local
     `--vcs-ref=HEAD` render is appropriate for a disposable pre-release preview,
     not the production adoption, because dirty work can record an unreachable
     throwaway commit. Answer the questions to match the repo, and keep all
     side-effectful answers
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
   ( cd "$TARGET" && task verify )    # repo's fast check/build/validate/guard gate
   ( cd "$TARGET" && task security )  # gitleaks + dependency audit
   ```

   Fix anything red and re-run until clean. The exact fast targets are
   profile/repo-specific; `task ci` additionally chains the heavier `test` and
   `security` aggregates.

4. **Run the applied-state verifier.** Confirm the audited drift classes are
   actually resolved by running the skill's checker:

   ```bash
   assets/verify-applied.sh "$TARGET"
   ```

   (See [`../assets/verify-applied.sh`](../assets/verify-applied.sh) — it should
   re-check the §3 drift classes against the target and exit non-zero on any
   remaining **blocker**. If the script isn't present yet in this skill, fall back
   to manually re-walking the gap report's Reconciliation plan.)

5. **Hand back.** Leave the changes committed on the feature branch with a
   Conventional-Commits message (e.g. `chore: standardize against harmon-init`)
   and open a PR for human + code-owner review — releases and merges stay
   intentional; do not merge or tag.
