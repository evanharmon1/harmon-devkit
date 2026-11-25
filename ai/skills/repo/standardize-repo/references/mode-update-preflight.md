<!-- Update reference: preflight. Step numbers (§0–§6) refer to the runbook. -->

[Update runbook](./mode-update.md) · Read this reference when its step is reached;
keep the same shell and guarded state across steps.

## 1. Verify and freeze both template inputs

Do not run `diff-template.sh` or any other trusted Copier render until the
guarded source and answers file below exist. The ordinary drift command trusts
the repo's recorded `_commit`; when that value is a tag, running it first would
reintroduce the mutable-baseline gap this preflight closes.

This renders harmon-init from the repo's own `.copier-answers.yml`, compares the
**whole render** against the repo, and reports the following result classes
(mapping `.yml`↔`.yaml`):

- **`DRIFT`** — a file differs from a render at the repo's **own recorded
  `_commit`** (diff-template.sh renders at `_commit`, not the template's HEAD). So
  DRIFT is the repo's **local customization** relative to its own baseline — or,
  less often, a **regression** where a past hand-reconciled update dropped a
  template improvement at/below that baseline (the status.sh / lint-hygiene /
  bootstrap class). It is **not** "an improvement from a newer template version":
  those arrive through the `copier update` three-way merge (§2), never via
  diff-template. Read the diff to tell a deliberate customization from a regression
  to restore. Files **outside** the curated
  [`template-owned-files.txt`](../assets/template-owned-files.txt) set are compared
  too and tagged `(uncurated — not in template-owned-files.txt)`. They carry
  exactly the same review-aid meaning; the tag only records that the
  hand-maintained manifest has not adopted the file, which is a fact about the
  manifest, not about the finding.
- **`MODE`** — the executable bit differs. Copier can preserve content while a
  hand copy silently drops `+x`, leaving a generated script present but
  unusable, so this is reported independently of content — and independently of
  the class the file lands in: an `OWNED`, `CO-OWNED`, or `IGNORED` file that lost `+x` is
  a broken script rather than expected drift, so it **gates** like any other
  `MODE` finding. Symlinks are exempt: the bit belongs to the link target.
- **`MISSING`** — a template file the repo lacks entirely. This scan walks the
  whole render (it does **not** depend on the curated list), so a file the
  template added later, or one a previous hand-reconciled update dropped, can't
  slip through silently. A tracked path deleted only from the working tree is
  compared from the index; staging that deletion makes it real `MISSING` — and
  that includes a `git rm --cached` whose working-tree copy **survives**
  (present in `HEAD`, gone from the index). The surviving copy makes the audit
  look clean while the next commit deletes a template-owned file, so the staged
  removal is reported instead of the comparison.
  (`.gitkeep` dir-stubs show as benign `ABSENT`.) Some
  `MISSING` findings are **intentional divergences, not gaps** — see the
  known-false-`MISSING` list in [`mode-audit.md`](./mode-audit.md) §3 (drift
  class K) before "restoring" any of them (e.g. a repo using `.prettierrc.cjs`
  instead of the template's `prettier.config.cjs`).
- **`EQUIV`** — a mature nested Terraform layout or established ADR log
  (numbered or date-named records) intentionally replaces a generated seed path.
  This is informational and does not fail the helper's comparison. Separately
  report each remaining `NNNN-` ADR as naming drift and recommend `git mv` to
  `YYYY-MM-DD-<kebab-title>.md` using its own `Date:` line, updating links.
  For missing or placeholder dates, follow the
  [ADR date fallback](./standards-catalog.md#11-docs-folder-layout).
  Structural equivalence does not make numbered naming conformant. The seed
  is `<decisions_seed_date>-record-architecture-decisions.md`; migrate an older
  numbered seed through the selected template using the recorded
  `decisions_seed_date` answer.
- **`OWNED`** — the **template itself** declares the path repo-owned, by listing
  it in `copier.yml`'s `_skip_if_exists`: `CHANGELOG.md`, `*.code-workspace`,
  `.github/CODEOWNERS`, `.devcontainer/related-repos.txt`, and
  `.release-please-manifest.json`. Copier never rewrites such a file once it
  exists, on adopt or on update, so its divergence is the designed steady state
  rather than drift — before this class existed the first two of those reported
  as gating uncurated `DRIFT` in every mature repo (issue 359). **Presence-only**
  and non-gating on content, exactly like `CO-OWNED` but for a different reason,
  which is why the tag is separate: `CO-OWNED` is a hand-maintained judgement
  about prose the repo rewrote, `OWNED` is the template's machine-readable
  statement about ownership, and it covers files nobody would call prose
  (`.release-please-manifest.json`, `CODEOWNERS`). Where the two overlap
  (`*.code-workspace` is on both lists) `OWNED` wins. The list is **derived**
  from the rendered commit's own `copier.yml` at run time and matched with git's
  gitignore dialect — the same semantics copier uses — so it cannot go stale;
  the script exits `2` if the declaration is unreadable, malformed, negated, or
  templated. A baseline that predates the declaration (added in harmon-init
  v3.4.0) is not an error: the run continues without the class and prints a
  note saying so, which is also when `CHANGELOG.md`'s historical hard skip
  applies. **Absence is not covered**: copier freezes a declared path only
  when it *exists*, so a declared path the repo lacks is rendered fresh by the
  next update and is still reported `MISSING`. Like `IGNORED`, it is
  **sweep-only** — a path on the curated manifest gates regardless.
- **`CO-OWNED`** — the template *seeds* the file but the repo owns its prose:
  `AGENTS.md` and its `CLAUDE.md` / `GEMINI.md` /
  `.github/copilot-instructions.md` symlink aliases, `README.md`, `DESIGN.md`,
  `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `LICENSE`, `SECURITY.md`, the
  **`*.md` under** `docs/` and `specs/`, `todo.md`, the `*.code-workspace`,
  `.meta/`, and the devcontainer `config/zshrc`. Those two tree globs are
  filtered to Markdown on purpose: a build script or generated config under a
  docs tree is not prose anybody rewrote, and letting it inherit the exemption
  for its directory alone is the opposite of safe-by-default — non-prose there
  gates as ordinary uncurated `DRIFT`.
  Divergence in the prose is the expected steady state, so the line is
  **presence-only**: no diff is printed, not even under `--show`, and its
  *content* never affects the exit status (a `MODE` finding on the same file
  still does). The useful reading is the inverse one — see §4.
- **`IGNORED`** — the copy is **untracked, and both the repo *and the template*
  ignore the path** (a resolved `.envrc`, local editor settings, and friends).
  Presence-only for the same reason as `CO-OWNED` plus a harder one: a resolved
  local config can hold real secrets, so its diff is never printed. Its content
  never affects the exit status. **The template's declaration is what grants
  this exemption, never the repo's habits** — see below. It is also a
  **sweep-only** class: a path on
  [`template-owned-files.txt`](../assets/template-owned-files.txt) always gates,
  ignore rules or not, because the manifest is itself an assertion of template
  ownership and ignore-based leniency cannot override it. Withholding still
  applies to those paths — the manifest says the template owns the path, not
  that the repo's copy is safe to print.

Ignore rules drive two **independent** axes, because "does this gate?" and "is
this safe to print?" are different questions:

- **Classification** follows repo *state*, then the *template's* declaration.
  Only an **uncurated** untracked file that **both** sides ignore is the
  informational `IGNORED` class; a curated path is never a candidate, per the
  sweep-only note above. A **tracked** one gates as ordinary `DRIFT`, ignore
  rules or not, because tracked content is template-relevant. And a path the repo ignores
  while the template **tracks** it gates too, tagged `(repo-ignored, but the
  template tracks this file — other clones will not have it)`: adding
  `.vscode/` to your own `.gitignore` says nothing about the artifact, and every
  other clone still renders it, so silencing it there hid real drift behind a
  local habit.
- **Withholding** follows the *path* alone, under the **union** of both rule
  sets, and applies to **every** diff the script prints — curated and swept
  alike, and not even a finding that gates is exempt. Being on the
  hand-maintained manifest says the template owns the path, not that the repo's
  copy is safe to echo: the manifest lists `.claude/settings.json`, exactly the
  shape whose local copy holds credentials. A repo can also `git add -f` a
  resolved config (tracking it makes that file reviewable, not publishable), or
  simply *fail* to ignore what the template declares local — the same secret in
  a less careful repo. You get `(diff withheld — path matches an ignore pattern;
  review manually)` under the `DRIFT` line and review it locally.

**Classification** needs the audited directory to be a repository root of its
**own**. A plain directory nested inside another repo's work tree gets no
`IGNORED` class: inheriting a stranger's ignore rules would silently downgrade
real drift, so everything there falls through to gating `DRIFT`. The render half
of **withholding** still applies there — it needs no work tree, and a
template-declared-local body is no safer to print for having landed in a
directory that is not a repo.

Symlinks are compared by **link target**, not content. The template ships
`CLAUDE.md`, `GEMINI.md`, and `.github/copilot-instructions.md` as links to
`AGENTS.md`, so content-diffing them would report one `AGENTS.md` divergence
four times over. A path that is a symlink on one side and a regular file on the
other — or a link pointing somewhere else — is a **structural** divergence and
always gates, `OWNED` or `CO-OWNED` or not: a flattened alias means the repo now carries
two independent copies of the agent instructions that will silently
desynchronize, and the finding is one line of metadata rather than a diff worth
withholding. This holds for **curated** entries too. A plain `diff -q` follows a
symlink, so a manifest-listed regular file swapped for a link to a
byte-identical referent used to read as clean while the sweep gated the same
shape; both paths now share one comparison routine.

### Preview the release and review new answers

The minimum pin check reads the verified target commit, not the checkout's
current `copier.yml`. A `below-minimum` verdict names both versions and stops
before Copier: set `.skills-sync.yaml` `source.ref` to exactly the reported minimum, run
`task sync:skills` in the same PR, then rerun the check before Copier. Leave a
pin at or above the minimum unchanged even when a newer skills release exists. An `unknown` verdict means the release
declares no minimum or an input is missing or malformed; report it with its
reason as unknown, never compatible, and continue. A missing manifest
(`no-skills-manifest`) is expected on first adoption or with skills sync off. An `error` verdict stops before Copier.

Before accepting `--defaults`, identify both the target release and any Copier
questions added since the repo's recorded `_commit`. Run
[`guarded-update.sh`](../assets/guarded-update.sh) from the repository root; it
is the runnable form of this section, and each subcommand reloads what it
needs from the guarded state directory:

```bash
HARMON_INIT_REF=<deliberately selected latest harmon-init release tag> \
  assets/guarded-update.sh prepare
```

`prepare` refreshes `~/git/harmon-init` from origin, requires the canonical
`_src_path`, freezes `RECORDED_COMMIT` and `HARMON_INIT_COMMIT`, checks v3 and
forward ancestry, runs `assets/check-pin-minimum.sh` against the verified
target, and refuses a release that cannot carry the CodeRabbit or Codex cloud
review choice. It prints the target's `copier.yml` diff since the baseline.
A legacy tag-valued `_commit` additionally needs `ACCEPT_LEGACY_BASELINE=true`
in that command's environment, and only after the approval described below;
`prepare` never defaults it.

Stop before previewing or applying when that guard fails. Requiring the recorded
source to be canonical binds Copier's actual update source to the remote that was
validated. `RECORDED_COMMIT` and `HARMON_INIT_COMMIT` freeze the old and new
template inputs and the ancestry check rejects a downgrade or unrelated target.

For a legacy tag-valued `_commit`, the original commit cannot be reconstructed
cryptographically after the fact. `ACCEPT_LEGACY_BASELINE=true` is an explicit
recovery decision, not a default: show the maintainer the current tag commit, the
GitHub release target, and relevant repository history, then obtain approval
before setting it. Record that decision in the eventual PR.

That recovery branch is the one part of update mode that needs **authenticated
`gh`** — see the Preconditions in [`SKILL.md`](../SKILL.md). The GitHub release
record is deliberate here, not incidental: the check exists to detect a **moved
tag**, and `git fetch --tags` re-fetches whatever origin currently claims, so
local git data moves with the tampering and structurally cannot detect it. The
release record is independent evidence, captured when the release was published.

How much it proves depends on what `target_commitish` holds, and the two `case`
arms in `prepare` are not equally strong:

- **A commit SHA** — what harmon-init's release-please releases record
  (`v4.4.0 → 617a309b…`). This pins the tag to one commit and does detect a
  retag. Strong evidence.
- **A branch name** (the `main)` arm) — proves only that the release was cut from
  that branch. It does **not** distinguish a retag to another commit on `main`,
  so it collapses into the ancestry check below. Weak evidence; say so explicitly
  when asking the maintainer to approve `ACCEPT_LEGACY_BASELINE`.

Either way the record is signal no git-only check can reproduce.
Do not "simplify" this by dropping `gh`.
Repos scaffolded after the lineage freeze in
[`mode-new-repo.md`](./mode-new-repo.md) §4a record a full hash and skip this
branch (and its `gh` requirement) entirely.

`prepare` then creates a read-only offline clone containing the validated
baseline and target, and binds Copier's canonical Git URL to that clone for
each guarded subprocess. It creates the guarded state directory, records the
frozen start head, checkout, answers, target and baseline commits, template
and cache paths, derives the new-question candidates between the two commits,
and finishes by printing the drift worklist and Copier's update check.

The guarded clone has no remote, is read-only, and is rejected if either
selected commit contains `.gitmodules`; Copier clones templates recursively, so
allowing a submodule URL would break the offline trust boundary. This matters
because Copier 9.16 checks out the recorded hash, then internally runs
`git describe --tags --always` and reuses that description for its old render.
Its nested clone now resolves that description against the same frozen local tag
mapping instead of a freshly fetched remote. Keeping the tags also preserves the
PEP 440 versions Copier requires for update ordering. Cloning the snapshot from
the canonical remote prevents local-only tags in `~/git/harmon-init` from
affecting `git describe`; both selected tag mappings are revalidated after the
clone to catch a concurrent retag. `run_guarded_copier`
defines two process-scoped Git `insteadOf` mappings so both accepted canonical
URL spellings clone the offline snapshot; the longer `.git` spelling wins when
applicable. Its isolated temporary mirror cache prevents a pre-existing
canonical-URL cache from bypassing the snapshot. Copier continues reading and
writing its canonical answers path, so harmon-init's fixed answers template and
Copier agree on the same file.

The worktree-root state directory is ignored through Git's resolved local
exclude file, so it works in both ordinary and linked worktrees. Its atomic
`mkdir` acts as a per-worktree lock and recovery marker. If preparation, preview,
update, or promotion is interrupted, do not rerun preparation or remove that
directory blindly: inspect the backed-up `original-answers.yml`, recorded
`start-head`, `start-checkout`, `canonical-answers-oid`, `target-commit`,
`recorded-commit`, `template-path`, `cache-path`, reviewed/discovery data
(including `target-discovery-path`), and the ignored-path
backup plus its recorded object IDs
alongside the working-tree diff. Restore the validated variables and
`run_guarded_copier` definition from that state when resuming — sourcing
`assets/guarded-update.sh load` reads them back from it — then run the
context checks below. Either finish the update and promotion or explicitly
discard the failed run. A concurrent or accidental rerun must stop at the
existing-directory error instead of overwriting recovery state.

The drift output is your reconciliation worklist for §3.

The companion harmon-init change must not be released until this skill is
published and its new tag is pinned into harmon-init. After that pin refresh,
release harmon-init; until then, older template releases render CodeRabbit
unconditionally and cannot satisfy a reviewed false answer.

Every newly introduced question needs an explicit decision. This is especially
important for a feature with a material footprint or an external capability:

- `use_foreman` adds the thin Foreman v2 integration
  (ponderousdev/foreman#12): `taskfiles/foreman.yml`, a wrapper whose
  `FOREMAN` var runs
  `uvx --from git+https://github.com/ponderousdev/foreman@v{{.FOREMAN_VERSION}} foreman`
  against a renovate-annotated `FOREMAN_VERSION` tag pin, plus `.foreman.toml`
  (consumer config). The supervisor's source stays in ponderousdev/foreman —
  consumers vendor none of it, and source updates arrive as Renovate pin
  bumps. It was default-on when introduced in v3.26.1, which also vendored the
  full source tree under `scripts/foreman/`; current template source defaults
  it off and ships no source at all. Update mode must still decide whether the
  target should opt in. A target scaffolded before the v2 flip carries the
  whole v1 footprint, and `copier update` deletes none of it (Copier never
  deletes files the template stopped emitting). The retired v1 artifacts are
  removed under BOTH answers — port any local modifications the repo wants to
  keep, then sweep `scripts/foreman/`, `.claude/agents/foreman-*.md`, and
  `docs/architecture/foreman.md`
  (`git rm -rf --ignore-unmatch scripts/foreman && git rm -f --ignore-unmatch .claude/agents/foreman-*.md docs/architecture/foreman.md`;
  `-f` because the locally modified survivors this sweep explicitly targets
  fail `git rm`'s up-to-date check — port their deltas FIRST, the force
  flag is not a license to skip that — and `--ignore-unmatch` because on an
  unmodified repo `copier update` may have staged the deletions already, so
  an absent path must not abort the chain). Then branch on the answer:
  - `use_foreman=true`: migrate `.foreman.toml` keys (`verify_command` → the
    `[verify]` table with a `default` command plus capability-keyed
    additions; `comment_trust` → `trusted_actors`; new `runner` and
    `required_capabilities`), and prove the wrapper resolves to the pin —
    `task foreman:plan` must succeed with no `scripts/foreman/` present. A CI
    guard keeps every retired path from coming back: `test ! -d
    scripts/foreman && test ! -e docs/architecture/foreman.md && ! ls
    .claude/agents/foreman-*.md >/dev/null 2>&1`. Note the command rename:
    read-only issue analysis is now `foreman vet`; `foreman preflight` is the
    empirical security-assertion gate.
  - `use_foreman=false`: the target render intentionally carries no Foreman
    files, so there is nothing to migrate and no wrapper to validate —
    `task foreman:plan` cannot succeed and must not be required. Beyond the
    sweep above, remove the rest of the legacy integration: `.foreman.toml`,
    `taskfiles/foreman.yml`, and any hand-added root-Taskfile include of it,
    then confirm `task --list` shows no `foreman:*` targets.
- `use_coderabbit` adds a third-party GitHub App integration and defaults off.
  Pass `--data use_coderabbit=false` unless the repository is deliberately
  retaining CodeRabbit. The false path removes `.coderabbit.yaml` and bot trust,
  but a human must also remove the repository from the CodeRabbit App
  installation because deleting repository files does not revoke App access.
- `use_codex_cloud_review` adds a required external Codex cloud-review signal
  and defaults off. It is active only when `use_codex_review=true` — the sole
  precondition Copier's own validator enforces. When active, a *consumer* repo
  must also set `use_skills_sync=true` and include `universal` in
  `skill_categories`, because there the classifier
  (`check-codex-cloud-review.sh`) reaches the repo only by syncing the
  `integrate` skill from the `universal` category. A skills-*source* repo —
  one that authors the `integrate` skill under `ai/skills/` rather than
  vendoring a released copy of it (harmon-devkit is the canonical case, and may
  therefore keep `use_skills_sync=false` since self-vendoring its own
  `ai/skills/` would be circular) — ships that classifier natively in its own
  tree at `ai/skills/universal/integrate/assets/check-codex-cloud-review.sh`,
  so it already satisfies that intent. The guard detects a usable classifier
  there and waives both the skills-sync and universal-category requirements
  for it while keeping them for every other repo. This carve-out is mirrored
  in `mode-audit.md` (G4) and `standards-catalog.md` so audit mode does not then
  report the same configuration as drift. Review it
  explicitly and keep it false unless the maintainer has
  connected Codex cloud review, accepts plan-dependent availability/quotas, and
  has granted explicit connector permission for a private repository. The
  maintainer must also disable Codex Automatic reviews — review **Trigger**
  knob included; the post-generation checklist states the full knob list — so
  ready-for-review promotion cannot start an untracked review. Legacy omission
  starts false.
  Enabling it changes the PR exit contract: a current-head terminal Codex result
  is required, with escalation after two unavailable attempts rather than a
  CI-only fallback.
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

Pass the complete reviewed answer map with `--data-file`, even when a decision
happens to match the current default. The guarded preparation first finds raw
questions added between the frozen baseline and target, then performs a
task-free target render to retain only questions Copier considers active and
recordable under this repository's answers. It adds the four active
repository-capability questions that always require reconsideration.

`discover` is that preparation. It converges the active target questions in a
bounded loop, seeds `reviewed-data.yml` with `__REVIEW_REQUIRED__` for every
question the active review set needs, and stops while any of those sentinels
stands: review every key, replace each sentinel with an explicit value, then
rerun it. It never fills a sentinel with a default. Before the reviewed data
exists it starts from `.copier-answers.yml`; to override one of those starting
answers (`USE_CODEQL`, `CODEQL_LANGUAGES`, `USE_FOREMAN`, `USE_CODEX_REVIEW`,
`USE_CODEX_CLOUD_REVIEW`, `USE_SKILLS_SYNC`, `USE_CODERABBIT`), export it for
that run. Once it converges with every reviewed value explicit, `rehearse`
snapshots the ignored managed paths, rehearses the update against a scratch
clone and classifies what Copier did (below); a rerun over a state directory
that already holds `ignored-snapshot-ready` skips it. Then load the results
and preview the exact answer set before the real update:

```bash
assets/guarded-update.sh discover
assets/guarded-update.sh rehearse
. assets/guarded-update.sh load
REVIEWED_DATA_OID="$(git hash-object "$REVIEWED_DATA")"
if test -e "$GUARDED_STATE/reviewed-data-oid"; then
  test "$(cat "$GUARDED_STATE/reviewed-data-oid")" = "$REVIEWED_DATA_OID" ||
    {
      echo "reviewed data changed after preview; explicitly restart the guarded run" >&2
      exit 1
    }
else
  printf '%s\n' "$REVIEWED_DATA_OID" >"$GUARDED_STATE/reviewed-data-oid" ||
    { echo "failed to freeze reviewed data" >&2; exit 1; }
fi
git -C "$GUARDED_TEMPLATE" show "$HARMON_INIT_COMMIT":copier.yml \
  >"$GUARDED_STATE/target-copier.yml" ||
  { echo "failed to extract the target copier.yml" >&2; exit 1; }
assets/confirm-answers.sh \
  --template-copier "$GUARDED_STATE/target-copier.yml" \
  --recorded "$GUARDED_STATE/original-answers.yml" \
  --data-file "$REVIEWED_DATA" \
  --active-keys "$GUARDED_STATE/active-target-questions" \
  --template-commit "$HARMON_INIT_COMMIT" \
  --state-dir "$GUARDED_STATE"
```

**Stop here and present that table.** It is the complete resolved question →
answer set this run will pass — **every active question**, not only the
reviewed subset: `copier update` merges the reviewed data file over the
recorded `.copier-answers.yml`, so `active-target-questions` (the full active
set the discovery render converged on) is the key list, the reviewed keys show
`data-file` as their source, and every other active answer — including the
standing `claude_authorized_members`, `code_owner`, `use_antigravity_cli`, or
`run_task_install` values the update will re-apply — shows `recorded`.
`reviewed-keys` is deliberately **not** the list here: it holds only the new
questions plus the capability subset, and a table over it would hide exactly
the standing sensitive answers this checkpoint exists to surface. Every answer
that differs from the recorded file is marked `CHANGED`, every answer with no
recorded value `NEW`, and every security-sensitive answer `SENSITIVE` — the
classes repeated as their own summary blocks so they cannot be scrolled past.
Nothing is written and no Copier process starts: the asset only reads YAML and
hashes files.

When the state directory already holds a prior confirmation marker, the
output leads with whether the active questions, their choices, and the data
file and recorded answers are unchanged, naming that marker's template commit.
The full table still follows, and a new template commit still requires its own
explicit confirmation.

Only after the human has seen that set and explicitly approved it, record the
confirmation by rerunning the same command with `--confirm` appended. An agent
never confirms on its own behalf, and in the parallel-worker topology a worker
prints the set, stops, and returns it to the parent/human rather than passing
`--confirm` itself.

The next two Copier runs execute the template's `_tasks` under `--trust`, so
each is preceded by a fail-closed `--check`:

```bash
assets/confirm-answers.sh --check \
  --data-file "$REVIEWED_DATA" \
  --recorded "$GUARDED_STATE/original-answers.yml" \
  --template-commit "$HARMON_INIT_COMMIT" \
  --state-dir "$GUARDED_STATE" ||
  { echo "resolved answers were never confirmed; do not run Copier" >&2; exit 1; }
run_guarded_copier update --trust --defaults --pretend \
  --vcs-ref="$HARMON_INIT_COMMIT" \
  --data-file="$REVIEWED_DATA"
```

The confirmation is bound to the reviewed data file's object ID, to the
recorded answers snapshot (`original-answers.yml` — `copier update` fills every
non-reviewed question from it, so it is an answer source too), and to
`HARMON_INIT_COMMIT`, which is the same freeze discipline the
`reviewed-data-oid` record already enforces: editing an answer after the
approval, a changed recorded file, or repointing the run at another template
commit, each invalidates the confirmation instead of silently reusing it. Rerun the presentation, obtain
approval again, then `--confirm`.

`copier … --trust` is exactly the command Claude Code auto-mode's classifier
denies, because it executes arbitrary template code. This checkpoint is where
that is settled. Prefer approving the single run at the prompt — that approval
covers this command, this data file, this commit. A `Bash(copier update:*)`
permission rule is the broader alternative: a standing, prefix-wide grant that
also authorizes every later trusted `copier update`, for any template, with no
further prompt — add one only deliberately. Agents never self-grant permissions.
The discovery and audit renders earlier in this mode pass `--trust` too (with
`--skip-tasks`, into scratch directories) and can be denied by the same
classifier, so the permission decision made here covers them as well — but the
hard gate is on the two runs that execute `_tasks` or mutate the target.

The existing Foreman answer is the starting point, not an instruction to retain
it blindly. Review that substantial per-repo choice and override `USE_FOREMAN`
deliberately when the repository should change posture. The existing local
Codex and CodeRabbit answers are handled the same way. Enabling local Codex
review activates `use_codex_cloud_review` for a second discovery pass; legacy
cloud omission starts at `false`, and the option remains absent from the
payload when its controller is false. An explicit CodeRabbit opt-in stays true
unless the maintainer deliberately opts out. `CODEQL_LANGUAGES` is a serialized
YAML list such as
`["javascript-typescript","python"]`; the existing matrix is only a starting
point and must be reviewed against actual first-party source. Disabling CodeQL
records an empty matrix.

The reviewed payload is written atomically before preview. The first run stops
after generating it: inspect every entry, replace every
`__REVIEW_REQUIRED__` sentinel, and rerun discovery. A reviewed choice may
activate another conditional new question; when that happens, discovery
regenerates the exact active keyset and stops for another explicit review.
Continue until the bounded discovery loop reaches a fixed point with no
sentinel. Each pass supplies the reviewed keys that Copier marked active on
the prior pass, and also admits every other reviewed key, so a question gated
on a newly active answer renders with its reviewed value rather than a default
its validator rejects. A pass's render is accepted only when every admitted key
is active in it: an admitted key the render shows inactive is dropped and the
pass renders again, and a render that fails with keys admitted is retried with
the prior pass's active keys alone. So a stale value from a newly inactive
question cannot affect an accepted render, and hidden `when: false` values and
inactive conditional questions are never part of the answers discovery settles
on. When even that retry fails, discovery stops and prints Copier's validation
errors from both renders. The one with reviewed keys admitted names the
question the reviewed data still lacks, and the fallback's may name only an
answer it had to leave out. On recovery, load the complete map
instead of recomputing defaults. The asset's loader is that reload: it
restores the frozen values and, once `discover` has written them, the reviewed
answers and the converged target render:

```bash
. assets/guarded-update.sh load
```

The frozen Git object ID refuses to preview or apply a different payload over
recovery state from an interrupted run.

`--pretend` confirms rendering succeeds but its output can be terse. For a
heavily customized or high-impact repo, make a disposable clone under a
temporary directory, repeat the guarded-source preparation there, run the same
update without `--pretend`, and inspect its full `git diff` before touching the
working branch. A preview complements the guarded-baseline drift report; neither
replaces the post-update reconciliation in §3.

**Silent non-adoption is the one gap a preview cannot show you.** Having both
renders in hand is what makes it visible at all, which is why `rehearse` above
ends by classifying it into `$GUARDED_STATE/nonadoption-report.tsv` — one row
per path,
`path<TAB>class<TAB>changed_in_range<TAB>baseline_membership<TAB>note`, with
where `class` is what the apply was OBSERVED to do — `nonadopt-both` naming the
blind spot itself, alongside `created`, `deleted`, and `unknown-until-apply` for
the degraded path — and `note` carries whatever evidence explains it:
`co-owned-prose`, `ignored-policy`, `repo-ignored-only`, `known-false-verified`,
`unverified-equivalent`, `package-json-unparseable`, `twin-exists: <path>`,
`gitkeep`, `new-in-target` / `recreated` / `apply-artifact` on a `created` row,
and the chezmoi Brewfile annotation. A note never removes a row. The mechanism,
and why `copier update` can never close it on its own, is
[`copier-gotchas.md`](./copier-gotchas.md) §9; §2 reconciles the rows against the
applied result and §5 turns the survivors into a disposition table in the PR
body. Only `nonadopt-both` reaches that table — the other classes describe what
the apply did and are settled before hand-off.

**The classification is an observation, not a prediction.** Before writing the
report, §1 copies the whole worktree to a scratch directory and runs *this exact
update* against the copy — same wrapper, same `--vcs-ref`, same reviewed
answers, plus `--skip-tasks` so the rehearsal has no side effects. Every row's
`class` is then a recording of what copier did: `nonadopt-both` (the path was
absent before, is absent after, and the target render ships it), `created`, or
`deleted`. That is the whole of the classification logic.

It reads as expensive and it is worth it. Every earlier revision of this block
modelled copier's adoption semantics in shell — three-way-merge reasoning,
`_skip_if_exists` glob matching, `.yml`/`.yaml` twin rules — and *every* defect
review found in it was the model disagreeing with copier, never the shell being
wrong: a repo-only ignore, an unverified equivalence, a recreate the model
called permanent, a rename the model called adoption. A model of another tool's
apply has no upper bound on how many ways it can be quietly false, and each way
was found only because somebody went looking. A rehearsal has one way to be
wrong — the environment moving between rehearsal and apply — and §4 checks
exactly that, fail-closed.

The `note` column then carries whatever evidence the classifier could find about
*why* the path is in that state:

- `new-in-target` / `recreated` — on a `created` row, which kind. `recreated`
  means both renders ship it, the repo had removed it, and the apply wrote it
  back anyway; that is `_skip_if_exists`, observed rather than pattern-matched.
- `co-owned-prose` — a `docs/`/`specs/` Markdown page the repo owns.
- `ignored-policy` — ignored by this repo **and** declared local by the target
  render's own `.gitignore` files, probed in a scratch evaluator built from them.
  Read this one together with the class rather than as a verdict: a path the
  render's own `.gitignore` covers is invisible to copier's "the subproject
  deleted this" scan, so deleting it does not opt out of it and the apply
  commonly renders it again. Such a row reads `created` / `recreated;
  ignored-policy` — the note says why the repo lacked the file, the class says it
  is coming back. Every predictive version of this block called those paths
  permanently absent; the rehearsal just watches them reappear.
- `repo-ignored-only` — the repo ignores it; the template never declared it
  local. A habit this repo acquired is not a fact about the artifact every other
  clone receives.
- `known-false-verified` / `unverified-equivalent` — drift class K's documented
  replacement was found, or was looked for and was not there.
- `twin-exists: <path>` — the repo carries the `.yml`/`.yaml` counterpart.
- `package-json-unparseable`, `gitkeep`, and the chezmoi Brewfile annotation.

**The evidence never removes the row.** That is the second structural rule, and
it exists because the alternative kept failing the same way: when an explanation
could *suppress* a path, every transition the classifier newly learned about
arrived as a path that had silently stopped being reported. Notes cannot do
that. The worst a wrong note can do is mislabel a row that is still there, in a
report §4 still checks and §5 still prints.

Readability is handled where a human can see the whole thing: §5 puts rows with
notes that record a decision already taken — `ignored-policy`,
`known-false-verified`, `gitkeep` — in a compact list under the table, one line
each, instead of collapsing them into counts. Every other absence is tabled.
