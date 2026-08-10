# Mode: Update

Bring a repo that was **already generated from harmon-init (v3+)** up to the latest
template — the repeatable "keep it in sync" path. Use this when the goal is "pull
the newest harmon-init changes into this repo," not initial setup.

Routing:

- **v3+ repo** (`.copier-answers.yml` present, with `_commit` either a `v3.x` or
  later release ref or the 40-character commit recorded by a guarded update) →
  this mode (`copier update`). For an unfamiliar full hash, resolve it against
  the canonical harmon-init remote and confirm it descends from `v3.0.0`.
- **v2 repo or never templated** → [`mode-adopt-existing.md`](./mode-adopt-existing.md)
  (v2→v3 was a breaking redesign; re-template via its Path B).
- **Just want a drift report, no changes** → run §1 and stop, or see
  [`mode-audit.md`](./mode-audit.md). Both read local/template state only, so on
  a `project_management: github` repo add §6a's and §6c's **read-only** queries
  to cover live labels, project fields, and org issue fields — a drift report
  without them is silently blind to the whole GitHub side.

The target repo is a **plain repo** — there is no special structure, no
"template-owned vs custom" split a developer must learn. Customizations live
normally in `Taskfile.yml`, `scripts/`, workflows, etc. The intelligence is here in
the skill: `copier update` does a three-way merge that pulls template improvements
*into* those files while preserving the repo's own edits; you reconcile anything that
conflicts. For copier mechanics see [`copier-gotchas.md`](./copier-gotchas.md).

`copier update` never touches **GitHub-side state**. On a repo answering
`project_management: github` the live metadata — project fields, org issue
fields, `layer:`/`domain:` labels — is a second, separate reconciliation the
update is not finished without: §6, which runs **after the PR merges**.

(It is not quite "files only" locally, either: the `task install` `_tasks` entry
is guarded on `run_task_install` alone — unlike every other entry, it carries no
`_copier_operation == 'copy'` guard — so an update on a repo that answered yes
re-runs brew deps and `lefthook install`. See §2.)

**How to run the snippets below.** They are written to survive `bash -eu`: the
load-bearing steps carry an explicit `|| { …; exit 1; }` handler so the failure
names itself, and a command without one still stops the run under errexit, just
anonymously — so keep the handlers when you copy a block into a fresh shell.
They are not proven under `pipefail`, though: without it a mid-pipeline failure
can be masked by a succeeding final stage, so run a lifted block with
`bash -euo pipefail` care and treat the recipes' own gates and frozen-OID
cross-checks as the real backstop. Every sorted-list
comparison pins `LC_ALL=C` on both the producer and the consumer, because `sort`
and `comm` must agree on collation — an ambient UTF-8 locale orders `_` against
letters differently than byte order does (`github_org` sorts before `git_init`
under `en_US.UTF-8`, after it under `C`), so a `comm` left unpinned rejects the
`LC_ALL=C sort`ed file it was handed with `file 1 is not in sorted order`. The
pin is per command, never a one-time export at the top of a section, because
these blocks get lifted piecemeal.

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
  the class the file lands in: a `CO-OWNED` or `IGNORED` file that lost `+x` is
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
- **`EQUIV`** — a mature nested Terraform layout or established/renumbered ADR
  log intentionally replaces a generated seed path. This is informational and
  does not fail the comparison.
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
always gates, `CO-OWNED` or not: a flattened alias means the repo now carries
two independent copies of the agent instructions that will silently
desynchronize, and the finding is one line of metadata rather than a diff worth
withholding. This holds for **curated** entries too. A plain `diff -q` follows a
symlink, so a manifest-listed regular file swapped for a link to a
byte-identical referent used to read as clean while the sweep gated the same
shape; both paths now share one comparison routine.

### Preview the release and review new answers

Before accepting `--defaults`, identify both the target release and any Copier
questions added since the repo's recorded `_commit`:

```bash
: "${HARMON_INIT_REF:?set to the deliberately selected latest harmon-init release tag}"
HARMON_INIT_SOURCE=https://github.com/evanharmon1/harmon-init
RECORDED_SOURCE="$(yq -r '._src_path // ""' .copier-answers.yml)"
RECORDED_REF="$(yq -r '._commit // ""' .copier-answers.yml)"
case "$RECORDED_SOURCE" in
"$HARMON_INIT_SOURCE" | "$HARMON_INIT_SOURCE.git") ;;
*)
  echo "_src_path must be the canonical harmon-init URL before update" >&2
  exit 1
  ;;
esac
git -C ~/git/harmon-init fetch "$HARMON_INIT_SOURCE" \
  '+refs/heads/main:refs/remotes/origin/main' --tags ||
  { echo "failed to refresh harmon-init from origin" >&2; exit 1; }
test -n "$RECORDED_REF" ||
  { echo "_commit must name the recorded harmon-init baseline" >&2; exit 1; }
if printf '%s\n' "$RECORDED_REF" | grep -Eq '^[0-9a-fA-F]{40}$'; then
  RECORDED_COMMIT="$(git -C ~/git/harmon-init rev-parse "$RECORDED_REF^{commit}")"
else
  # Legacy Copier answers normally contain `git describe` output (usually a
  # release tag), which is not immutable evidence of the commit originally used.
  # An agent must not accept the current mapping silently.
  : "${ACCEPT_LEGACY_BASELINE:?obtain maintainer approval for the legacy baseline recovery}"
  test "$ACCEPT_LEGACY_BASELINE" = true ||
    { echo "ACCEPT_LEGACY_BASELINE must be exactly true" >&2; exit 1; }
  # This branch needs authenticated `gh` — `gh api` requires a credential even
  # for a public repository. Probe it separately so a missing/unauthenticated
  # CLI is not misreported as a tag/release problem.
  command -v gh >/dev/null 2>&1 ||
    { echo "legacy baseline recovery requires the gh CLI on PATH" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 ||
    {
      echo "legacy baseline recovery requires authenticated gh; run gh auth login" >&2
      exit 1
    }
  RELEASE_ERR="$(mktemp -t harmon-init-release-err-XXXXXX)" ||
    { echo "failed to allocate the release probe buffer" >&2; exit 1; }
  if RELEASE_TARGET="$(
    gh api "repos/evanharmon1/harmon-init/releases/tags/$RECORDED_REF" \
      --jq '.target_commitish' 2>"$RELEASE_ERR"
  )"; then
    rm -f "$RELEASE_ERR"
  elif grep -q 'HTTP 404' "$RELEASE_ERR"; then
    rm -f "$RELEASE_ERR"
    echo "recorded tag has no matching GitHub release" >&2
    exit 1
  else
    echo "cannot read the GitHub release record for $RECORDED_REF:" >&2
    cat "$RELEASE_ERR" >&2
    rm -f "$RELEASE_ERR"
    exit 1
  fi
  RECORDED_COMMIT="$(git -C ~/git/harmon-init rev-parse "$RECORDED_REF^{commit}")"
  case "$RELEASE_TARGET" in
  "$RECORDED_COMMIT") ;;
  main)
    git -C ~/git/harmon-init merge-base --is-ancestor \
      "$RECORDED_COMMIT" origin/main ||
      { echo "recorded tag is not on the release target branch" >&2; exit 1; }
    ;;
  *)
    echo "GitHub release target must be the recorded commit or main" >&2
    exit 1
    ;;
  esac
fi
git -C ~/git/harmon-init merge-base --is-ancestor "$RECORDED_COMMIT" origin/main ||
  { echo "recorded _commit must resolve to a commit on origin/main" >&2; exit 1; }
V3_TAG_OBJECT="$(
  git -C ~/git/harmon-init ls-remote --exit-code "$HARMON_INIT_SOURCE" \
    "refs/tags/v3.0.0" |
    awk 'NR == 1 { print $1 }'
)" ||
  { echo "cannot verify the v3 migration boundary on origin" >&2; exit 1; }
test -n "$V3_TAG_OBJECT" &&
  test "$(git -C ~/git/harmon-init rev-parse refs/tags/v3.0.0)" = \
    "$V3_TAG_OBJECT" ||
  { echo "local v3.0.0 tag does not match origin" >&2; exit 1; }
V3_BASELINE_COMMIT="$(git -C ~/git/harmon-init rev-parse "v3.0.0^{commit}")"
git -C ~/git/harmon-init merge-base --is-ancestor \
  "$V3_BASELINE_COMMIT" "$RECORDED_COMMIT" ||
  {
    echo "recorded baseline predates v3; use mode-adopt-existing.md" >&2
    exit 1
  }
REMOTE_TAG_OBJECT="$(
  git -C ~/git/harmon-init ls-remote --exit-code "$HARMON_INIT_SOURCE" \
    "refs/tags/$HARMON_INIT_REF" |
    awk 'NR == 1 { print $1 }'
)" ||
  { echo "HARMON_INIT_REF is not a tag published by origin" >&2; exit 1; }
test -n "$REMOTE_TAG_OBJECT" &&
  test "$(git -C ~/git/harmon-init rev-parse "refs/tags/$HARMON_INIT_REF")" = "$REMOTE_TAG_OBJECT" &&
  git -C ~/git/harmon-init merge-base --is-ancestor "$HARMON_INIT_REF^{commit}" origin/main ||
  { echo "HARMON_INIT_REF must exactly match a release tag on origin/main" >&2; exit 1; }
HARMON_INIT_COMMIT="$(git -C ~/git/harmon-init rev-parse "$HARMON_INIT_REF^{commit}")"
git -C ~/git/harmon-init merge-base --is-ancestor \
  "$RECORDED_COMMIT" "$HARMON_INIT_COMMIT" ||
  { echo "target release must descend from the recorded baseline" >&2; exit 1; }
git -C ~/git/harmon-init show "$HARMON_INIT_COMMIT":copier.yml |
  grep -q '^use_coderabbit:' ||
  { echo "latest harmon-init release does not support the CodeRabbit choice" >&2; exit 1; }
git -C ~/git/harmon-init show "$HARMON_INIT_COMMIT":copier.yml |
  grep -q '^use_codex_cloud_review:' ||
  { echo "latest harmon-init release does not support the Codex cloud review choice" >&2; exit 1; }
git -C ~/git/harmon-init diff \
  "$RECORDED_COMMIT".."$HARMON_INIT_COMMIT" -- copier.yml
```

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
arms above are not equally strong:

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

Create a read-only offline clone containing the validated baseline and target,
then bind Copier's canonical Git URL to that clone for each guarded subprocess:

```bash
GUARDED_TEMPLATE="$(mktemp -d -t harmon-init-guarded-XXXXXX)"
GUARDED_COPIER_CACHE="$(mktemp -d -t copier-guarded-cache-XXXXXX)"
git clone --no-checkout "$HARMON_INIT_SOURCE" "$GUARDED_TEMPLATE" ||
  { echo "failed to snapshot harmon-init from the canonical remote" >&2; exit 1; }
git -C "$GUARDED_TEMPLATE" remote remove origin
test "$(git -C "$GUARDED_TEMPLATE" rev-parse "$RECORDED_COMMIT^{commit}")" = \
  "$RECORDED_COMMIT" &&
  test "$(git -C "$GUARDED_TEMPLATE" rev-parse "$HARMON_INIT_COMMIT^{commit}")" = \
    "$HARMON_INIT_COMMIT" ||
  { echo "guarded template does not contain the validated commits" >&2; exit 1; }
test "$(git -C "$GUARDED_TEMPLATE" rev-parse "$HARMON_INIT_REF^{commit}")" = \
  "$HARMON_INIT_COMMIT" ||
  { echo "guarded target tag mapping changed during snapshot creation" >&2; exit 1; }
if ! printf '%s\n' "$RECORDED_REF" | grep -Eq '^[0-9a-fA-F]{40}$'; then
  test "$(git -C "$GUARDED_TEMPLATE" rev-parse "$RECORDED_REF^{commit}")" = \
    "$RECORDED_COMMIT" ||
    { echo "guarded baseline tag mapping changed during snapshot creation" >&2; exit 1; }
fi
for GUARDED_COMMIT in "$RECORDED_COMMIT" "$HARMON_INIT_COMMIT"; do
  if git -C "$GUARDED_TEMPLATE" cat-file -e \
    "$GUARDED_COMMIT:.gitmodules" 2>/dev/null; then
    echo "guarded updates do not support template commits with submodules" >&2
    exit 1
  fi
done
chmod -R a-w "$GUARDED_TEMPLATE"
GUARDED_STATE=.copier-guarded-update
guarded_checkout_id() {
  if GUARDED_BRANCH="$(git symbolic-ref --quiet --short HEAD)"; then
    printf 'branch:%s\n' "$GUARDED_BRANCH"
  else
    printf '%s\n' detached
  fi
}
GIT_EXCLUDE="$(git rev-parse --path-format=absolute --git-path info/exclude)"
grep -qxF "/$GUARDED_STATE/" "$GIT_EXCLUDE" ||
  printf '%s\n' "/$GUARDED_STATE/" >>"$GIT_EXCLUDE" ||
  { echo "failed to ignore guarded update state" >&2; exit 1; }
mkdir "$GUARDED_STATE" ||
  {
    echo "$GUARDED_STATE already exists; recover or remove it before retrying" >&2
    exit 1
  }
git rev-parse HEAD >"$GUARDED_STATE/start-head" &&
  guarded_checkout_id >"$GUARDED_STATE/start-checkout" &&
  git hash-object .copier-answers.yml >"$GUARDED_STATE/canonical-answers-oid" &&
  printf '%s\n' "$HARMON_INIT_COMMIT" >"$GUARDED_STATE/target-commit" &&
  printf '%s\n' "$GUARDED_TEMPLATE" >"$GUARDED_STATE/template-path" &&
  printf '%s\n' "$GUARDED_COPIER_CACHE" >"$GUARDED_STATE/cache-path" &&
  cp .copier-answers.yml "$GUARDED_STATE/original-answers.yml" ||
  { echo "failed to initialize guarded update state" >&2; exit 1; }
git -C "$GUARDED_TEMPLATE" show "$RECORDED_COMMIT":copier.yml |
  yq -r 'keys | .[] | select(test("^_") | not)' |
  LC_ALL=C sort -u >"$GUARDED_STATE/baseline-questions" &&
  git -C "$GUARDED_TEMPLATE" show "$HARMON_INIT_COMMIT":copier.yml |
    yq -r 'keys | .[] | select(test("^_") | not)' |
    LC_ALL=C sort -u >"$GUARDED_STATE/target-questions" &&
  LC_ALL=C comm -13 \
    "$GUARDED_STATE/baseline-questions" \
    "$GUARDED_STATE/target-questions" \
    >"$GUARDED_STATE/new-question-candidates" ||
  { echo "failed to derive new question candidates" >&2; exit 1; }
test -z "$(git status --porcelain)" ||
  { echo "guarded preparation must leave the worktree clean" >&2; exit 1; }
run_guarded_copier() {
  env \
    "COPIER_CACHE_DIR=$GUARDED_COPIER_CACHE" \
    GIT_CONFIG_COUNT=2 \
    "GIT_CONFIG_KEY_0=url.$GUARDED_TEMPLATE.insteadOf" \
    "GIT_CONFIG_VALUE_0=$HARMON_INIT_SOURCE.git" \
    "GIT_CONFIG_KEY_1=url.$GUARDED_TEMPLATE.insteadOf" \
    "GIT_CONFIG_VALUE_1=$HARMON_INIT_SOURCE" \
    copier "$@"
}
HARMON_INIT="$GUARDED_TEMPLATE" \
  HARMON_INIT_RECORDED_COMMIT="$RECORDED_COMMIT" \
  assets/diff-template.sh .
# add --show to print the full per-file diff
run_guarded_copier check-update --output-format json .
```

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
`template-path`, `cache-path`, reviewed/discovery data, and the ignored-path
backup plus its recorded object IDs
alongside the working-tree diff. Restore the validated variables and
`run_guarded_copier` definition from that state when resuming, then run the
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
- `use_codex_cloud_review` adds a required external shepherd signal and defaults
  off. It is active only when `use_codex_review=true` — the sole precondition
  Copier's own validator enforces. When active, a *consumer* repo must also set
  `use_skills_sync=true` and include `universal` in `skill_categories`, because
  there the classifier (`check-codex-cloud-review.sh`) reaches the repo only by
  syncing the shepherd skill from the `universal` category. A skills-*source*
  repo — one that authors the shepherd skill under `ai/skills/` rather than
  vendoring a released copy of it (harmon-devkit is the canonical case, and may
  therefore keep `use_skills_sync=false` since self-vendoring its own
  `ai/skills/` would be circular) — ships that classifier natively in its own
  tree at `ai/skills/universal/shepherd/assets/check-codex-cloud-review.sh`, so
  it already satisfies that intent. The guard detects a usable classifier there
  and waives both the skills-sync and universal-category requirements for it
  while keeping them for every other repo. This carve-out is mirrored in
  `mode-audit.md` (G4) and `standards-catalog.md` so audit mode does not then
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

Preview the exact answer set before the real update:

```bash
REVIEWED_DATA="$GUARDED_STATE/reviewed-data.yml"
ORIGINAL_DATA="$GUARDED_STATE/original-data.yml"
yq 'with_entries(select(.key | test("^_") | not))' \
  "$GUARDED_STATE/original-answers.yml" >"$ORIGINAL_DATA" ||
  { echo "failed to prepare recorded answers for discovery" >&2; exit 1; }
# >>> classifier-detector >>>
# use_codex_cloud_review's use_skills_sync / universal-category requirements are
# a proxy for "the cloud-review classifier is installed": in a consumer repo the
# shepherd skill and its check-codex-cloud-review.sh reach the repo only via
# skills sync of the universal category. A skills-source repo hosts that
# classifier natively in its own tree, so it satisfies the intent directly and
# is exempt (matching Copier's validator, which gates the option on
# use_codex_review alone). The guards below waive both requirements only when
# this asset is a real, repo-shipped executable helper — proven from Git's
# index, not the filesystem. The authoritative test is the tracked mode being
# `100755`: `git ls-files --stage` reports it, and a `100755` blob is by
# definition tracked, a regular file, non-symlink, and executable for every
# fresh clone. A filesystem `[ -x ]` is the wrong test — under
# `core.fileMode=false` or a mount that reports everything executable it passes
# for a `100644` blob a Linux clone checks out non-runnable. Require the working
# tree to also hold that regular file (`-f`), so a staged-but-deleted path does
# not qualify. The requirements stay in force for every other repo.
#
# That tracked mode is necessary but nowhere near sufficient on its own: a
# one-line stub committed `100755` at the right path would pass it and prove
# nothing about the skill being usable. So "ships the classifier natively"
# additionally requires the shepherd skill's entry point and the helper's own
# structure, and it requires them from CODE rather than from prose.
#
# Anchoring on the usage strings (`reserve --state`, …) was the obvious version
# of that and is not enough: a no-op helper whose comments merely PRINT those
# five forms satisfies every one of them, and a waived config with such a stub
# is worse than no waiver — shepherd's `check` would read its exit 0 as clean
# evidence and the composition fails OPEN. So the verb probes anchor on the
# dispatch `case` arms in the helper's executable body, and are joined by two
# pairs from the exit-code contract shepherd actually depends on: `emit pending`
# with `exit 11`, and `emit escalate` with `exit 13`. Those two verdicts are the
# bounded-attempt lifecycle — a helper that cannot say "still waiting" or "both
# windows elapsed" cannot drive the stage no matter what its banner claims —
# and 11/13 are unusual enough that nothing satisfies them incidentally.
# `classifier_code_has` strips leading whitespace and drops every `#` line
# first, so no comment can answer a probe.
#
# The `SKILL.md` probe likewise checks the frontmatter rather than the path: a
# helper with no valid skill around it is a stripped tree, not a shipped skill.
# It splits in two, because the two halves have genuinely different natures.
#
# STRUCTURE is checked statically: the file must open with `---` and the block
# must CLOSE with a second one. These stay hand-rolled because yq does NOT fail
# closed on either — verified against yq v4, not assumed. Under
# `--front-matter=extract`, a file with no frontmatter at all, and an unclosed
# block whose body happens to be valid YAML, both parse happily and resolve
# `.name`, so a bare `name: shepherd` sitting in a file's BODY would satisfy
# the value probe. The two checks mirror `verify-skills.sh`'s `head -n 1` test
# and its `frontmatter_is_closed`, which remains canonical for layout.
#
# VALUES are resolved by yq rather than re-implemented. This section already
# hard-requires yq v4 for the guarded update, so the detector may assume it.
# The hand-rolled grammar this replaces had to learn YAML one finding at a
# time — quoted scalars, block-scalar headers, chomping and indentation
# indicators in either order, the null spellings, and comments composing with
# every one of them — and each round closed an instance while the next spelling
# waited. A parser already knows the whole grammar, so that family of findings
# ends here rather than being enumerated further.
# `tag == "!!str"` is the load-bearing part: it is what makes `null`, `~`, `[]`,
# `{ }`, numbers, and booleans fail, which is precisely the "reads like a value,
# is not one" set the hand-written reject list was chasing.
#
# A yq failure — malformed YAML, or an invalid header like `|0` — answers false,
# so no waiver. That is the safe direction, and unlike the ignore probes it is
# deliberately NOT an exit-2 "cannot tell" condition: a SKILL.md that does not
# parse is a definite answer, namely that this is not a valid skills source.
# Every probe sits in the `if` condition, where a non-zero exit selects the
# else-branch instead of tripping errexit — these are questions about the repo,
# not failures.
#
# What this still CANNOT prove, plainly: runtime behavior. A read-only stage
# must not render or execute the repo under update, so every probe above is
# static, and a tree that passes could still hold a helper that is broken when
# run — or one deliberately forged to match these anchors, since any static
# shape can be reproduced by something that does nothing. Issue 336 accepts
# that residual explicitly. What the probes buy is the accidental case they
# were written for: a stub, a stripped tree, or a half-vendored copy no longer
# waives three guards by looking right from a distance.
SKILLS_SOURCE_CLASSIFIER="ai/skills/universal/shepherd/assets/check-codex-cloud-review.sh"
SKILLS_SOURCE_SHEPHERD_SKILL="ai/skills/universal/shepherd/SKILL.md"
# Match a POSIX ERE against the helper's code only: leading whitespace stripped,
# every comment line dropped. Called only after the `-f` test above passes.
#
# It is one awk pass over the file, deliberately NOT a pipeline. The obvious
# `sed | grep -v | grep -qE` form is broken under `pipefail`: `grep -q` exits at
# the first match, the upstream stages die of SIGPIPE (141), and the whole
# pipeline then reports failure — so on a real classifier, where every anchor
# matches early, every probe "fails" and the waiver is denied to exactly the
# repo it exists for. The preamble tells you to run these blocks with `pipefail`
# care; this one is safe under it because there is no pipe. awk owns the input,
# so the early `exit` costs nothing and still runs END.
# The pattern arrives through the environment rather than `-v`, which would
# escape-process it and mangle the `\)` in the case-arm anchors.
classifier_code_has() {
  CLASSIFIER_PROBE="$1" awk '
    BEGIN { pat = ENVIRON["CLASSIFIER_PROBE"] }
    { line = $0; sub(/^[[:space:]]*/, "", line) }
    line ~ /^#/ { next }
    line ~ pat { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$SKILLS_SOURCE_CLASSIFIER"
}
# The entry point must be a REGULAR file, proven from the index the same way
# the classifier path is: `git ls-files --stage` reports the tracked mode, and
# only `100644`/`100755` are regular blobs. A `120000` is a symlink, which
# `verify-skills.sh` also refuses by finding skills with `-type f` — a symlinked
# SKILL.md resolves fine in this checkout and can dangle in a fresh clone, or
# point outside the skill tree entirely. Checked before the frontmatter awk,
# which would happily read straight through the link.
classifier_skill_is_regular_file() {
  case "$(git ls-files --stage -- "$SKILLS_SOURCE_SHEPHERD_SKILL" 2>/dev/null | cut -c1-6)" in
  100644 | 100755) return 0 ;;
  esac
  return 1
}
classifier_skill_frontmatter_ok() {
  awk '
    NR == 1 && $0 != "---" { exit }
    $0 == "---" { fence++ }
    END { exit (fence >= 2) ? 0 : 1 }
  ' "$SKILLS_SOURCE_SHEPHERD_SKILL" &&
    yq --front-matter=extract -e '
      ((.name | tag) == "!!str") and (.name == "shepherd") and
      ((.description | tag) == "!!str") and (.description != "")
    ' "$SKILLS_SOURCE_SHEPHERD_SKILL" >/dev/null 2>&1
}
if [ -f "$SKILLS_SOURCE_CLASSIFIER" ] &&
  [ "$(git ls-files --stage -- "$SKILLS_SOURCE_CLASSIFIER" 2>/dev/null | cut -c1-6)" = "100755" ] &&
  git ls-files --error-unmatch -- "$SKILLS_SOURCE_SHEPHERD_SKILL" >/dev/null 2>&1 &&
  classifier_skill_is_regular_file &&
  classifier_skill_frontmatter_ok &&
  classifier_code_has '^reserve\)' &&
  classifier_code_has '^attach\)' &&
  classifier_code_has '^check\)' &&
  classifier_code_has '^show\)' &&
  classifier_code_has '^reap\)' &&
  classifier_code_has '^emit pending ' &&
  classifier_code_has '^exit 11$' &&
  classifier_code_has '^emit escalate ' &&
  classifier_code_has '^exit 13$'; then
  SHIPS_CLASSIFIER_NATIVELY=true
else
  SHIPS_CLASSIFIER_NATIVELY=false
fi
# <<< classifier-detector <<<
if test -e "$REVIEWED_DATA"; then
  yq -e \
    'tag == "!!map" and
     ([.[] | select(. == "__REVIEW_REQUIRED__")] | length == 0)' \
    "$REVIEWED_DATA" >/dev/null ||
    {
      echo "review every existing entry and replace all __REVIEW_REQUIRED__ values" >&2
      exit 1
    }
  USE_FOREMAN="$(yq -r '.use_foreman' "$REVIEWED_DATA")"
  USE_CODEX_REVIEW="$(yq -r '.use_codex_review' "$REVIEWED_DATA")"
  USE_CODEX_CLOUD_REVIEW="$(
    yq -r '.use_codex_cloud_review // false' "$REVIEWED_DATA"
  )"
  USE_SKILLS_SYNC="$(yq -r '.use_skills_sync' "$REVIEWED_DATA")"
  USE_CODERABBIT="$(yq -r '.use_coderabbit' "$REVIEWED_DATA")"
  USE_CODEQL="$(yq -r '.use_codeql' "$REVIEWED_DATA")"
  CODEQL_LANGUAGES="$(yq -o=json -I=0 '.codeql_languages' "$REVIEWED_DATA")"
else
  : "${USE_CODEQL:?set USE_CODEQL=true or false after the capability review}"
  : "${CODEQL_LANGUAGES:=$(yq -o=json -I=0 '.codeql_languages // []' .copier-answers.yml)}"
  : "${USE_FOREMAN:=$(yq -r '.use_foreman // false' .copier-answers.yml)}"
  : "${USE_CODEX_REVIEW:=$(yq -r '.use_codex_review // false' .copier-answers.yml)}"
  : "${USE_CODEX_CLOUD_REVIEW:=$(yq -r '.use_codex_cloud_review // false' .copier-answers.yml)}"
  : "${USE_SKILLS_SYNC:=$(yq -r '.use_skills_sync // false' .copier-answers.yml)}"
  : "${USE_CODERABBIT:=$(yq -r '.use_coderabbit // false' .copier-answers.yml)}"
fi
case "$USE_FOREMAN" in true | false) ;; *) echo "USE_FOREMAN must be true or false" >&2; exit 1 ;; esac
case "$USE_CODEX_REVIEW" in true | false) ;; *) echo "USE_CODEX_REVIEW must be true or false" >&2; exit 1 ;; esac
case "$USE_CODEX_CLOUD_REVIEW" in true | false) ;; *) echo "USE_CODEX_CLOUD_REVIEW must be true or false" >&2; exit 1 ;; esac
case "$USE_SKILLS_SYNC" in true | false) ;; *) echo "USE_SKILLS_SYNC must be true or false" >&2; exit 1 ;; esac
[ "$USE_CODEX_CLOUD_REVIEW" != "true" ] || [ "$USE_CODEX_REVIEW" = "true" ] ||
  { echo "use_codex_cloud_review requires use_codex_review" >&2; exit 1; }
[ "$USE_CODEX_CLOUD_REVIEW" != "true" ] || [ "$USE_SKILLS_SYNC" = "true" ] ||
  [ "$SHIPS_CLASSIFIER_NATIVELY" = "true" ] ||
  { echo "use_codex_cloud_review requires use_skills_sync (waived when this repo ships the classifier natively at $SKILLS_SOURCE_CLASSIFIER)" >&2; exit 1; }
case "$USE_CODERABBIT" in true | false) ;; *) echo "USE_CODERABBIT must be true or false" >&2; exit 1 ;; esac
if [ "$USE_CODEQL" = "false" ]; then
  CODEQL_LANGUAGES='[]'
elif [ "$USE_CODEQL" != "true" ] ||
  ! printf '%s\n' "$CODEQL_LANGUAGES" |
    yq -e '(tag == "!!seq") and (length > 0) and
      ([.[] | select(. != "javascript-typescript" and . != "python")] | length == 0)' - >/dev/null; then
  echo "CODEQL_LANGUAGES must be a nonempty YAML list of supported first-party languages" >&2
  exit 1
fi
CODEQL_LANGUAGES="$(
  printf '%s\n' "$CODEQL_LANGUAGES" | yq -o=json -I=0 '.'
)"
DISCOVERY_DATA="$GUARDED_STATE/discovery-data.yml"
: >"$GUARDED_STATE/active-target-questions"
DISCOVERY_STABLE=false
for DISCOVERY_ROUND in 1 2 3 4 5 6 7 8 9 10; do
  ACTIVE_REVIEWED="$GUARDED_STATE/active-reviewed-data.yml"
  printf '%s\n' '{}' >"$ACTIVE_REVIEWED" ||
    { echo "failed to initialize active reviewed data" >&2; exit 1; }
  if test -e "$REVIEWED_DATA"; then
    while IFS= read -r ACTIVE_KEY; do
      if ACTIVE_KEY="$ACTIVE_KEY" \
        yq -e 'has(strenv(ACTIVE_KEY))' "$REVIEWED_DATA" >/dev/null; then
        ACTIVE_VALUE="$(
          ACTIVE_KEY="$ACTIVE_KEY" \
            yq -o=json -I=0 '.[strenv(ACTIVE_KEY)]' "$REVIEWED_DATA"
        )" &&
          ACTIVE_KEY="$ACTIVE_KEY" ACTIVE_VALUE="$ACTIVE_VALUE" \
            yq -i \
              '.[strenv(ACTIVE_KEY)] = (strenv(ACTIVE_VALUE) | from_json)' \
              "$ACTIVE_REVIEWED" ||
          { echo "failed to select active reviewed value" >&2; exit 1; }
      fi
    done <"$GUARDED_STATE/active-target-questions"
  fi
  DISCOVERY_CANDIDATE="$(mktemp "$GUARDED_STATE/discovery-data.XXXXXX")" ||
    { echo "failed to create discovery-data candidate" >&2; exit 1; }
  yq eval-all \
    'select(fileIndex == 0) * select(fileIndex == 1)' \
    "$ORIGINAL_DATA" "$ACTIVE_REVIEWED" >"$DISCOVERY_CANDIDATE" ||
    {
      rm -f "$DISCOVERY_CANDIDATE"
      echo "failed to merge discovery answers" >&2
      exit 1
    }
  mv "$DISCOVERY_CANDIDATE" "$DISCOVERY_DATA" ||
    {
      rm -f "$DISCOVERY_CANDIDATE"
      echo "failed to publish discovery answers" >&2
      exit 1
    }
  TARGET_DISCOVERY="$(mktemp -d -t copier-target-discovery-XXXXXX)" ||
    { echo "failed to create target discovery directory" >&2; exit 1; }
  run_guarded_copier copy --trust --defaults --skip-tasks \
    --vcs-ref="$HARMON_INIT_COMMIT" \
    --data-file="$DISCOVERY_DATA" \
    "$HARMON_INIT_SOURCE" "$TARGET_DISCOVERY" ||
    { echo "target question discovery failed" >&2; exit 1; }
  yq -r 'keys | .[] | select(test("^_") | not)' \
    "$TARGET_DISCOVERY/.copier-answers.yml" |
    LC_ALL=C sort -u >"$GUARDED_STATE/active-target-questions.next" ||
    { echo "failed to derive active target questions" >&2; exit 1; }
  if cmp -s \
    "$GUARDED_STATE/active-target-questions" \
    "$GUARDED_STATE/active-target-questions.next"; then
    rm -f "$GUARDED_STATE/active-target-questions.next"
    DISCOVERY_STABLE=true
    break
  fi
  mv \
    "$GUARDED_STATE/active-target-questions.next" \
    "$GUARDED_STATE/active-target-questions" ||
    { echo "failed to advance active question discovery" >&2; exit 1; }
done
test "$DISCOVERY_STABLE" = true ||
  { echo "active question discovery did not converge in 10 rounds" >&2; exit 1; }
LC_ALL=C comm -12 \
  "$GUARDED_STATE/new-question-candidates" \
  "$GUARDED_STATE/active-target-questions" \
  >"$GUARDED_STATE/active-new-questions" ||
  { echo "failed to derive active new questions" >&2; exit 1; }
{
  cat "$GUARDED_STATE/active-new-questions"
  printf '%s\n' \
    use_foreman use_codex_review use_codex_cloud_review use_skills_sync \
    use_coderabbit use_codeql codeql_languages
  if [ "$USE_CODEX_CLOUD_REVIEW" = "true" ]; then
    printf '%s\n' skill_categories
  fi
} |
  LC_ALL=C sort -u |
  LC_ALL=C comm -12 - "$GUARDED_STATE/active-target-questions" \
    >"$GUARDED_STATE/reviewed-keys" ||
  { echo "failed to derive the complete active review set" >&2; exit 1; }
for CAPABILITY_KEY in \
  use_foreman use_codex_review use_skills_sync use_coderabbit use_codeql codeql_languages; do
  grep -qxF "$CAPABILITY_KEY" "$GUARDED_STATE/reviewed-keys" ||
    {
      echo "required capability question is not active: $CAPABILITY_KEY" >&2
      exit 1
    }
done
# skill_categories is a conditional question activated by use_skills_sync, so a
# skills-source repo running with use_skills_sync=false (native classifier) has
# it inactive by design. Require it active only when the sync/universal path is
# what installs the classifier — the same carve-out the later guards apply.
if [ "$USE_CODEX_CLOUD_REVIEW" = "true" ] && [ "$SHIPS_CLASSIFIER_NATIVELY" != "true" ]; then
  grep -qxF skill_categories "$GUARDED_STATE/reviewed-keys" ||
    {
      echo "required skill_categories question is not active" >&2
      exit 1
    }
fi
find "$TARGET_DISCOVERY" \( -type f -o -type l \) -print |
  sed "s#^$TARGET_DISCOVERY/##" |
  LC_ALL=C sort -u >"$GUARDED_STATE/target-managed-paths" ||
  { echo "failed to inventory target render paths" >&2; exit 1; }
if test -e "$REVIEWED_DATA"; then
  REVIEWED_KEYSET_OID="$(
    yq -r 'keys | .[]' "$REVIEWED_DATA" |
      LC_ALL=C sort -u |
      git hash-object --stdin
  )" ||
    { echo "failed to hash the reviewed keyset" >&2; exit 1; }
else
  REVIEWED_KEYSET_OID=""
fi
REQUIRED_KEYSET_OID="$(
  git hash-object "$GUARDED_STATE/reviewed-keys"
)"
if ! test -e "$REVIEWED_DATA" ||
  test "$REVIEWED_KEYSET_OID" != "$REQUIRED_KEYSET_OID"; then
  REVIEWED_CANDIDATE="$(mktemp "$GUARDED_STATE/reviewed-data.XXXXXX")" ||
    { echo "failed to create reviewed-data candidate" >&2; exit 1; }
  printf '%s\n' '{}' >"$REVIEWED_CANDIDATE" ||
    {
      rm -f "$REVIEWED_CANDIDATE"
      echo "failed to initialize reviewed-data candidate" >&2
      exit 1
    }
  while IFS= read -r REVIEWED_KEY; do
    if ! REVIEWED_KEY="$REVIEWED_KEY" yq -i \
      '.[strenv(REVIEWED_KEY)] = "__REVIEW_REQUIRED__"' \
      "$REVIEWED_CANDIDATE"; then
      rm -f "$REVIEWED_CANDIDATE"
      echo "failed to seed reviewed question: $REVIEWED_KEY" >&2
      exit 1
    fi
  done <"$GUARDED_STATE/reviewed-keys"
  if ! USE_FOREMAN="$USE_FOREMAN" \
    USE_CODEX_REVIEW="$USE_CODEX_REVIEW" \
    USE_CODEX_CLOUD_REVIEW="$USE_CODEX_CLOUD_REVIEW" \
    USE_SKILLS_SYNC="$USE_SKILLS_SYNC" \
    USE_CODERABBIT="$USE_CODERABBIT" \
    USE_CODEQL="$USE_CODEQL" \
    CODEQL_LANGUAGES="$CODEQL_LANGUAGES" \
    yq -i \
      '.use_foreman = (strenv(USE_FOREMAN) == "true") |
       .use_codex_review = (strenv(USE_CODEX_REVIEW) == "true") |
       .use_skills_sync = (strenv(USE_SKILLS_SYNC) == "true") |
       .use_coderabbit = (strenv(USE_CODERABBIT) == "true") |
       .use_codeql = (strenv(USE_CODEQL) == "true") |
       .codeql_languages = (strenv(CODEQL_LANGUAGES) | from_json)' \
      "$REVIEWED_CANDIDATE"; then
    rm -f "$REVIEWED_CANDIDATE"
    echo "failed to seed reviewed capability answers" >&2
    exit 1
  fi
  if grep -qxF use_codex_cloud_review "$GUARDED_STATE/reviewed-keys" &&
    ! USE_CODEX_CLOUD_REVIEW="$USE_CODEX_CLOUD_REVIEW" \
      yq -i \
        '.use_codex_cloud_review =
          (strenv(USE_CODEX_CLOUD_REVIEW) == "true")' \
        "$REVIEWED_CANDIDATE"; then
    rm -f "$REVIEWED_CANDIDATE"
    echo "failed to seed reviewed Codex cloud answer" >&2
    exit 1
  fi
  mv "$REVIEWED_CANDIDATE" "$REVIEWED_DATA" ||
    {
      rm -f "$REVIEWED_CANDIDATE"
      echo "failed to publish reviewed data" >&2
      exit 1
    }
  echo "the active question set changed; review every key in $REVIEWED_DATA, replace all __REVIEW_REQUIRED__ values, then rerun discovery" >&2
  exit 1
fi
while IFS= read -r REVIEWED_KEY; do
  REVIEWED_KEY="$REVIEWED_KEY" yq -e \
    'has(strenv(REVIEWED_KEY)) and
     .[strenv(REVIEWED_KEY)] != "__REVIEW_REQUIRED__"' \
    "$REVIEWED_DATA" >/dev/null ||
    {
      echo "missing explicit reviewed value for $REVIEWED_KEY" >&2
      exit 1
    }
done <"$GUARDED_STATE/reviewed-keys"
USE_FOREMAN="$(yq -r '.use_foreman' "$REVIEWED_DATA")"
USE_CODEX_REVIEW="$(yq -r '.use_codex_review' "$REVIEWED_DATA")"
USE_CODEX_CLOUD_REVIEW="$(
  yq -r '.use_codex_cloud_review // false' "$REVIEWED_DATA"
)"
USE_SKILLS_SYNC="$(yq -r '.use_skills_sync' "$REVIEWED_DATA")"
SKILL_CATEGORIES="$(yq -o=json -I=0 '.skill_categories // []' "$REVIEWED_DATA")"
USE_CODERABBIT="$(yq -r '.use_coderabbit' "$REVIEWED_DATA")"
USE_CODEQL="$(yq -r '.use_codeql' "$REVIEWED_DATA")"
CODEQL_LANGUAGES="$(yq -o=json -I=0 '.codeql_languages' "$REVIEWED_DATA")"
case "$USE_FOREMAN" in true | false) ;; *) echo "reviewed use_foreman must be boolean" >&2; exit 1 ;; esac
case "$USE_CODEX_REVIEW" in true | false) ;; *) echo "reviewed use_codex_review must be boolean" >&2; exit 1 ;; esac
case "$USE_CODEX_CLOUD_REVIEW" in true | false) ;; *) echo "reviewed use_codex_cloud_review must be boolean" >&2; exit 1 ;; esac
case "$USE_SKILLS_SYNC" in true | false) ;; *) echo "reviewed use_skills_sync must be boolean" >&2; exit 1 ;; esac
[ "$USE_CODEX_CLOUD_REVIEW" != "true" ] || [ "$USE_CODEX_REVIEW" = "true" ] ||
  { echo "use_codex_cloud_review requires use_codex_review" >&2; exit 1; }
[ "$USE_CODEX_CLOUD_REVIEW" != "true" ] || [ "$USE_SKILLS_SYNC" = "true" ] ||
  [ "$SHIPS_CLASSIFIER_NATIVELY" = "true" ] ||
  { echo "use_codex_cloud_review requires use_skills_sync (waived when this repo ships the classifier natively at $SKILLS_SOURCE_CLASSIFIER)" >&2; exit 1; }
[ "$USE_CODEX_CLOUD_REVIEW" != "true" ] || [ "$SHIPS_CLASSIFIER_NATIVELY" = "true" ] ||
  printf '%s\n' "$SKILL_CATEGORIES" | yq -e 'contains(["universal"])' - >/dev/null ||
  { echo "use_codex_cloud_review requires the universal skill category (waived when this repo ships the classifier natively at $SKILLS_SOURCE_CLASSIFIER)" >&2; exit 1; }
case "$USE_CODERABBIT" in true | false) ;; *) echo "reviewed use_coderabbit must be boolean" >&2; exit 1 ;; esac
case "$USE_CODEQL" in true | false) ;; *) echo "reviewed use_codeql must be boolean" >&2; exit 1 ;; esac
if ! test -e "$GUARDED_STATE/ignored-snapshot-ready"; then
  BASELINE_DISCOVERY="$(mktemp -d -t copier-baseline-discovery-XXXXXX)" ||
    { echo "failed to create baseline discovery directory" >&2; exit 1; }
  run_guarded_copier copy --trust --defaults --skip-tasks \
    --vcs-ref="$RECORDED_COMMIT" \
    --data-file="$ORIGINAL_DATA" \
    "$HARMON_INIT_SOURCE" "$BASELINE_DISCOVERY" ||
    { echo "baseline path discovery failed" >&2; exit 1; }
  find "$BASELINE_DISCOVERY" \( -type f -o -type l \) -print |
    sed "s#^$BASELINE_DISCOVERY/##" |
    LC_ALL=C sort -u >"$GUARDED_STATE/baseline-managed-paths" ||
    { echo "failed to inventory baseline render paths" >&2; exit 1; }
  cat \
    "$GUARDED_STATE/baseline-managed-paths" \
    "$GUARDED_STATE/target-managed-paths" |
    LC_ALL=C sort -u >"$GUARDED_STATE/managed-paths" ||
    { echo "failed to inventory guarded render paths" >&2; exit 1; }
  : >"$GUARDED_STATE/ignored-managed-paths"
  : >"$GUARDED_STATE/ignored-existing-paths"
  : >"$GUARDED_STATE/ignored-absent-paths"
  while IFS= read -r MANAGED_PATH; do
    case "$MANAGED_PATH" in
    "" | /* | ../* | */../*)
      echo "unsafe managed path: $MANAGED_PATH" >&2
      exit 1
      ;;
    esac
    if git check-ignore -q -- "$MANAGED_PATH"; then
      printf '%s\n' "$MANAGED_PATH" \
        >>"$GUARDED_STATE/ignored-managed-paths"
      if test -e "$MANAGED_PATH" || test -L "$MANAGED_PATH"; then
        test ! -d "$MANAGED_PATH" || test -L "$MANAGED_PATH" ||
          {
            echo "ignored managed path is an unsupported directory: $MANAGED_PATH" >&2
            exit 1
          }
        printf '%s\n' "$MANAGED_PATH" \
          >>"$GUARDED_STATE/ignored-existing-paths"
      else
        printf '%s\n' "$MANAGED_PATH" \
          >>"$GUARDED_STATE/ignored-absent-paths"
      fi
    fi
  done <"$GUARDED_STATE/managed-paths"
  # >>> nonadoption-classify >>>
  # OBSERVE the apply; do not model it. Earlier revisions of this block
  # re-implemented copier's adoption semantics in shell — three-way-merge
  # reasoning, `_skip_if_exists` glob matching, `.yml`/`.yaml` twin rules — and
  # every single defect found in six rounds of review was the model disagreeing
  # with copier rather than the shell being wrong. A model of someone else's
  # apply has no upper bound on how many ways it can be subtly false.
  #
  # So: copy the repo, run the SAME update against the copy, and diff before
  # against after. What copier does to the scratch is what it will do here, and
  # the classification below is a recording of it rather than a prediction about
  # it. §4 then re-checks the prediction against the real apply and fails closed
  # on any divergence, which is the only remaining way this can be wrong.
  #
  # $REVIEWED_DATA is fully validated before this block: the seeding path exits
  # non-zero, and the loop above it rejects any key still holding
  # `__REVIEW_REQUIRED__`. Reaching here means the payload the real update will
  # use is the payload this rehearsal uses.
  # `-type f -o -type l` is the file-or-symlink predicate applied wholesale: a
  # DIRECTORY at a rendered file's path simply never appears, which is the
  # correct answer to "does the repo have this file". `.git` is pruned at any
  # depth, and the guarded state directory with it.
  nonadoption_inventory() {
    (cd "$1" && find . -name .git -prune -o -path "./$GUARDED_STATE" -prune -o \
      \( -type f -o -type l \) -print) |
      sed 's#^\./##' |
      LC_ALL=C sort -u
  }
  # A previous run's report and verdict must not survive into this one. Rollback
  # deletes $GUARDED_STATE but leaves the branch-keyed files in the git dir, so a
  # rollback-then-rerun that dies before persisting would hand §4 a clean verdict
  # describing a tree that no longer exists. Clear both here, at the one moment
  # that means "a new guarded run is starting" — and only this branch's, for the
  # same reason the persistence step is branch-keyed at all.
  NONADOPT_BRANCH="$(git branch --show-current)"
  test -n "$NONADOPT_BRANCH" ||
    { echo "detached HEAD: the guarded update needs a branch to key its report to" >&2; exit 1; }
  for NONADOPT_STALE_KEY in guarded-update-nonadoption guarded-update-reconciled; do
    NONADOPT_STALE_FILE="$(
      git rev-parse --path-format=absolute \
        --git-path "$NONADOPT_STALE_KEY/$NONADOPT_BRANCH"
    )" || { echo "failed to resolve $NONADOPT_STALE_KEY for this branch" >&2; exit 1; }
    rm -f -- "$NONADOPT_STALE_FILE" ||
      { echo "failed to clear the stale $NONADOPT_STALE_KEY entry" >&2; exit 1; }
  done
  # The target's own copier.yml, frozen at the pinned commit — the config the
  # real update will obey.
  git -C "$GUARDED_TEMPLATE" show "$HARMON_INIT_COMMIT":copier.yml \
    >"$GUARDED_STATE/target-copier.yml" ||
    { echo "failed to read the target copier.yml" >&2; exit 1; }
  # MIGRATIONS MAKE THE REHEARSAL UNSAFE. `--skip-tasks` suppresses `_tasks` and
  # nothing else: copier 9.17.1 guards `_execute_tasks(self.template.tasks)` with
  # `skip_tasks` and runs `migration_tasks("before"/"after")` unguarded. Verified
  # by fixture — a `_migrations` command fired during an update run with exactly
  # the flags below, while `_tasks` did not. Migrations mutate the project and
  # must run exactly once, against the real repo; a rehearsal would run them a
  # second time, against a copy, with the real one still to come. So when the
  # target declares any, the rehearsal is refused and the report degrades to
  # inventory facts. harmon-init declares no `_migrations` today, so this stays
  # a guard rather than the normal path.
  yq -r '._migrations // [] | length' "$GUARDED_STATE/target-copier.yml" \
    >"$GUARDED_STATE/target-migration-count" ||
    { echo "failed to read _migrations from the target copier.yml" >&2; exit 1; }
  NONADOPT_MIGRATIONS="$(cat "$GUARDED_STATE/target-migration-count")"
  case "$NONADOPT_MIGRATIONS" in
  '' | *[!0-9]*)
    echo "could not determine the target's _migrations count" >&2
    exit 1
    ;;
  esac
  NONADOPT_REHEARSED=0
  if test "$NONADOPT_MIGRATIONS" -gt 0; then
    echo "target declares $NONADOPT_MIGRATIONS _migrations; skipping the rehearsal (migrations must run exactly once, against the real repo)" >&2
    echo "non-adoption classes will read unknown-until-apply and are resolved by the reconciliation in §2" >&2
  else
    NONADOPT_REHEARSED=1
  fi
  if test "$NONADOPT_REHEARSED" -eq 1; then
  NONADOPT_SCRATCH="$(mktemp -d -t copier-nonadoption-apply-XXXXXX)" ||
    { echo "failed to create the scratch apply directory" >&2; exit 1; }
  # ZERO shared git metadata, via `git clone`. A linked worktree's `.git` is a
  # POINTER FILE, so copying it verbatim would leave the scratch operating on the
  # real worktree's index and object store — and copier's update runs
  # `git write-tree` in the subproject, so the rehearsal would stage into the
  # tree it is meant to observe from a distance. Cloning gives the scratch its
  # own admin directory outright, and cloning the WORKTREE path (not the common
  # git dir) checks out this worktree's branch, linked or not.
  #
  # The clone also *is* the index, which is the property that matters: copier's
  # deleted-path exclusion diffs the old render's tree against the SUBPROJECT'S
  # INDEX, and a clone reproduces it exactly — tracked-but-ignored files still
  # tracked, gitlinks still mode 160000 and uninitialized, filenames that look
  # like options carried as data. Every one of those was a defect in the
  # hand-built copy-init-add-commit construction this replaces, and each was
  # found by somebody thinking of a case rather than by the design excluding it.
  # §1 has already proved the worktree clean, so HEAD is the worktree.
  test -z "$(git status --porcelain)" ||
    { echo "worktree not clean; the rehearsal would not reproduce the real index" >&2; exit 1; }
  git clone --no-hardlinks --quiet . "$NONADOPT_SCRATCH/repo" ||
    { echo "failed to clone the worktree for the scratch apply; inspect $NONADOPT_SCRATCH" >&2; exit 1; }
  # Ignored files are untracked, so the clone does not carry them; overlay the
  # ones the TEMPLATE manages and this repo has. Unmanaged ignored content
  # (`node_modules`, `.venv`, `.terraform`) is left behind deliberately: it is in
  # neither render inventory, so it is not a path copier renders, excludes or
  # skips, and it is not in the index, so it cannot appear in the tree diff that
  # decides which paths were deleted. Nothing copier does can depend on it.
  #
  # Each name is prefixed `./` before it reaches `tar -T`: GNU tar treats a
  # leading `-` in a file list as an option, and these names come from the
  # template's own render inventory rather than from anything this recipe
  # controls.
  sed 's#^#./#' "$GUARDED_STATE/ignored-existing-paths" \
    >"$GUARDED_STATE/scratch-overlay-paths" ||
    { echo "failed to derive the ignored-path overlay list" >&2; exit 1; }
  if test -s "$GUARDED_STATE/scratch-overlay-paths"; then
    tar -cf "$NONADOPT_SCRATCH/overlay.tar" \
      -T "$GUARDED_STATE/scratch-overlay-paths" ||
      { echo "failed to archive the managed ignored paths" >&2; exit 1; }
    (cd "$NONADOPT_SCRATCH/repo" && tar -xf "$NONADOPT_SCRATCH/overlay.tar") ||
      { echo "failed to overlay the managed ignored paths" >&2; exit 1; }
    rm -f "$NONADOPT_SCRATCH/overlay.tar" ||
      { echo "failed to remove the overlay archive" >&2; exit 1; }
  fi
  # The isolation invariant, asserted rather than assumed: the scratch's git dir
  # must live inside the scratch. If this ever fails the rehearsal is operating
  # on somebody else's repository.
  NONADOPT_SCRATCH_GITDIR="$(
    git -C "$NONADOPT_SCRATCH/repo" rev-parse --absolute-git-dir
  )" || { echo "failed to resolve the scratch git directory" >&2; exit 1; }
  case "$NONADOPT_SCRATCH_GITDIR" in
  "$NONADOPT_SCRATCH"/*) ;;
  *)
    echo "scratch repository shares git metadata with $NONADOPT_SCRATCH_GITDIR; refusing to rehearse" >&2
    exit 1
    ;;
  esac
  # BEFORE, taken from the SCRATCH and not from the real repo. Both sides of
  # every `comm` below must describe the same universe of paths, and the scratch
  # is deliberately a SUBSET of the worktree: the clone carries tracked content
  # and the overlay adds managed ignored paths, while unmanaged ignored content
  # (`node_modules`, `.venv`, `.terraform`) is left behind on purpose. Diffing
  # the real repo against the scratch therefore reported every one of those
  # thousands of files as deleted by the apply, and reconciliation then failed
  # against a real tree that still had them. Snapshotting the scratch on both
  # sides makes the two universes identical by construction rather than by a
  # filter somebody has to keep in step.
  #
  # The real repo's inventory is no longer an input to the rehearsal diff at all.
  # It never fed the classifier's repo-presence checks either — those go through
  # `nonadoption_path_present`, a direct `test -f`/`test -L` against the path —
  # so nothing else needs rescoping.
  nonadoption_inventory "$NONADOPT_SCRATCH/repo" \
    >"$GUARDED_STATE/apply-before-paths" ||
    { echo "failed to inventory the scratch before the rehearsal" >&2; exit 1; }
  # §2's real invocation, verbatim, plus `--skip-tasks` and an explicit
  # destination. Those are the ONLY two differences and both are deliberate:
  # tasks are side effects a rehearsal must not run, and the destination is what
  # makes it a rehearsal. Same wrapper, same `--vcs-ref`, same `--data-file`,
  # same `--trust --defaults`. If §2's flags ever change, change these with them
  # — a rehearsal of a different command predicts nothing.
  run_guarded_copier update --trust --defaults --skip-tasks \
    --vcs-ref="$HARMON_INIT_COMMIT" \
    --data-file="$REVIEWED_DATA" \
    "$NONADOPT_SCRATCH/repo" ||
    { echo "scratch apply failed; the guarded update would fail the same way — inspect $NONADOPT_SCRATCH" >&2; exit 1; }
  nonadoption_inventory "$NONADOPT_SCRATCH/repo" \
    >"$GUARDED_STATE/apply-after-paths" ||
    { echo "failed to inventory the scratch apply result" >&2; exit 1; }
  # What the apply actually did, as two sets. Collation is pinned on both the
  # sorts above and the comms here: `comm` rejects input it thinks is unsorted,
  # and an ambient UTF-8 locale disagrees with byte order on exactly the paths a
  # template ships.
  LC_ALL=C comm -13 \
    "$GUARDED_STATE/apply-before-paths" \
    "$GUARDED_STATE/apply-after-paths" \
    >"$GUARDED_STATE/apply-created" ||
    { echo "failed to derive paths the apply created" >&2; exit 1; }
  LC_ALL=C comm -23 \
    "$GUARDED_STATE/apply-before-paths" \
    "$GUARDED_STATE/apply-after-paths" \
    >"$GUARDED_STATE/apply-deleted" ||
    { echo "failed to derive paths the apply deleted" >&2; exit 1; }
  else
    # Degraded: no rehearsal, so no before/after pair and nothing for the comms
    # to compare. The candidate set falls back to the render inventories alone.
    : >"$GUARDED_STATE/apply-created"
    : >"$GUARDED_STATE/apply-deleted"
  fi
  # Everything either render ships, plus anything the apply touched that neither
  # does. The second half is belt and braces — copier writes rendered files and
  # its own answers file — but it costs one `cat` and means a path cannot escape
  # the report by being unrendered.
  cat \
    "$GUARDED_STATE/baseline-managed-paths" \
    "$GUARDED_STATE/target-managed-paths" \
    "$GUARDED_STATE/apply-created" \
    "$GUARDED_STATE/apply-deleted" |
    LC_ALL=C sort -u >"$GUARDED_STATE/nonadoption-candidates" ||
    { echo "failed to derive the candidate path set" >&2; exit 1; }
  # The one presence predicate, used for both sides of the comparison. `-L` is
  # not redundant: `-f` calls a dangling symlink absent, and a dangling link is
  # still a path the repo has.
  nonadoption_path_present() {
    test -f "$1/$2" || test -L "$1/$2"
  }
  # `--` because these patterns are template-controlled paths: a rendered file
  # named `-x` would otherwise be read as a grep option. The same reason the
  # overlay list is `./`-prefixed before it reaches tar. The three greps in
  # `nonadoption_reconcile` and `nonadoption_verify_verdict` need no `--`: their
  # patterns are literal prefixes (`reconciled: `, `report: `, `target-commit: `)
  # that cannot begin with a dash.
  nonadoption_in_set() {
    grep -qxF -- "$2" "$GUARDED_STATE/$1"
  }
  nonadoption_add_note() {
    if test "$NONADOPT_NOTE" = -; then
      NONADOPT_NOTE="$1"
    else
      NONADOPT_NOTE="$NONADOPT_NOTE; $1"
    fi
  }
  # diff-template.sh's `repo_variant` is the canonical .yml<->.yaml mapping; this
  # is the two-branch subset a path inventory needs. Prints the twin, or nothing
  # for a path that has none.
  nonadoption_twin_of() {
    case "$1" in
    *.yml) printf '%s\n' "${1%.yml}.yaml" ;;
    *.yaml) printf '%s\n' "${1%.yaml}.yml" ;;
    esac
  }
  # The `docs/`/`specs/` PROSE branch of diff-template.sh's `is_co_owned`, and
  # ONLY that branch. Change one, change the other — including the SHAPE: the
  # nested basename case is part of the contract, not a paraphrase. A
  # non-Markdown file under those trees is a build script, a config, or a
  # generated asset that nobody rewrote, so it is not prose and its absence is
  # unexplained non-adoption.
  #
  # The rest of `is_co_owned` is deliberately absent. Co-ownership is a CONTENT
  # exemption — the repo's prose is expected to differ from the template's — and
  # absence is not content. A missing `AGENTS.md`, `LICENSE`, `SECURITY.md`, or
  # `.devcontainer/config/zshrc` is a file the repo does not have and will never
  # be offered again; reading "the repo owns its prose" as "the repo meant to
  # delete it" invents a decision nobody made, which is the exact failure this
  # report exists to end. Those paths get table rows.
  #
  # This is a NOTE, not a filter, and §5 keeps it in the disposition TABLE. It
  # once routed a row to the compact list on the grounds that a repo carries tens
  # of documentation pages — but volume is not intent, and this note is the one
  # that establishes none: co-ownership explains why a file the repo HAS may
  # differ from the template's, and an absent file differs from nothing. Only
  # `ignored-policy`, `known-false-verified` and `gitkeep` send a row to the
  # list, because each of those records a decision somebody already made.
  nonadoption_is_doc_prose() {
    case "$1" in
    docs/* | specs/*)
      case "${1##*/}" in
      *.md) return 0 ;;
      esac
      ;;
    esac
    return 1
  }
  # The two ADR shapes diff-template.sh's `has_repo_equivalent` accepts, and only
  # those: a RENUMBERED `*-record-architecture-decisions.md`, or a README-backed
  # log holding at least one numbered ADR. "Any numbered ADR" is broader than the
  # documented evidence — `0002-use-postgres.md` says the repo writes ADRs, not
  # that it re-recorded the decision this seed records or keeps an indexed log,
  # and accepting it filtered the seed away on the strength of an unrelated file.
  nonadoption_has_adr_log() {
    NONADOPT_ADR_NUMBERED=0
    for NONADOPT_ADR in docs/decisions/[0-9]*.md; do
      test -f "$NONADOPT_ADR" || continue
      NONADOPT_ADR_NUMBERED=1
      case "${NONADOPT_ADR##*/}" in
      *-record-architecture-decisions.md) return 0 ;;
      esac
    done
    test "$NONADOPT_ADR_NUMBERED" -eq 1 || return 1
    test -f docs/decisions/README.md
  }
  # Nested/split Terraform roots — a `*.tf` at least one directory BELOW
  # `terraform/`, which is what makes the flat seed files redundant. A flat
  # `terraform/*.tf` proves nothing: that is the seed layout itself.
  #
  # `.terraform` is pruned because `terraform init` fills
  # `.terraform/modules/**/*.tf` with vendored module sources. Those are
  # generated cache, gitignored, and nested by construction, so an unrestricted
  # walk read `terraform init` itself as evidence that the repo had outgrown the
  # seed — in a repo that still has exactly the flat layout. `-prune` before the
  # `-o` branch is the portable form (BSD and GNU find alike).
  nonadoption_has_nested_terraform() {
    test -d terraform || return 1
    find terraform -name .terraform -prune -o -type f -name '*.tf' -print \
      2>/dev/null |
      awk '{
             rel = substr($0, length("terraform/") + 1)
             if (rel ~ /\//) found = 1
           }
           END { exit(found ? 0 : 1) }'
  }
  # Prettier reads its config from any of a dozen filenames, and every one of
  # them replaces the template's `prettier.config.cjs`. Checking `.prettierrc.cjs`
  # alone invented an unverified row for every repo that picked a different
  # supported form. `prettier.config.cjs` is not in the list: it is the path being
  # classified, absent by construction, which is why we are here at all.
  nonadoption_has_prettier_config() {
    for NONADOPT_PRETTIER in \
      .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml \
      .prettierrc.json5 .prettierrc.toml \
      .prettierrc.js .prettierrc.cjs .prettierrc.mjs \
      .prettierrc.ts .prettierrc.mts .prettierrc.cts \
      prettier.config.js prettier.config.mjs \
      prettier.config.ts prettier.config.mts prettier.config.cts; do
      test -f "$NONADOPT_PRETTIER" || continue
      return 0
    done
    # The `prettier` key in package.json is the remaining supported location, and
    # it is PARSED, not grepped. A bare `grep '"prettier"'` matches the
    # devDependency entry too, so a repo that installed the tool and never
    # configured it certified a config that does not exist — weaker evidence than
    # the claim, which is the exact defect this whole list was tightened to stop.
    # §1 already requires `yq`, and yq v4 reads JSON natively, so the real parse
    # costs no new dependency.
    test -f package.json || return 1
    NONADOPT_PRETTIER_RC=0
    NONADOPT_PRETTIER_KEY="$(yq -r '.prettier // ""' package.json 2>/dev/null)" ||
      NONADOPT_PRETTIER_RC=$?
    if test "$NONADOPT_PRETTIER_RC" -ne 0; then
      # ADVISORY evidence about one path, unlike the ignore probes below — those
      # guarantee a withheld exemption and so are fatal. A malformed package.json
      # must not kill a guarded run that is otherwise fine, so it fails toward
      # the row and says so. The note is a fixed token rather than yq's message:
      # that text is multi-line and would corrupt the TSV row it lands in, so the
      # detail goes to stderr where it has room.
      echo "could not parse package.json for a prettier config (yq exit $NONADOPT_PRETTIER_RC); reporting prettier.config.cjs as a row" >&2
      nonadoption_add_note package-json-unparseable
      return 1
    fi
    test -n "$NONADOPT_PRETTIER_KEY"
  }
  # The known-false-`MISSING` list from mode-audit.md §3 (drift class K):
  # absences that are deliberate divergences, not gaps. Every entry there is
  # CONDITIONAL — it is a false MISSING *because the repo carries a documented
  # equivalent* — so each is verified against this repo rather than granted on
  # the strength of the path name. An unverified path falls through to a table
  # row, which is the safe direction: the reviewer sees something that may need
  # adopting, instead of the classifier certifying a replacement nobody checked
  # for. Granting the exemption unconditionally made a repo that simply never had
  # `terraform/main.tf` indistinguishable from one that outgrew it.
  #
  # Two class-K entries are deliberately NOT here, for opposite reasons.
  #
  # `.envrc`'s legitimacy is ignore policy — the template ships it gitignored —
  # so it is settled by the probe below, on the template's own declaration rather
  # than on this list's say-so.
  #
  # The root `Brewfile` is absent because the doctrine is CONTESTED and this
  # snippet is the wrong place to settle it. Class K calls a missing root
  # `Brewfile` a false MISSING in a chezmoi source repo, on the grounds that
  # chezmoi names its copy `private_Brewfile`. But mode-adopt-existing.md §4.7
  # says such a repo needs a root `Brewfile` anyway, for its OWN toolchain
  # (`task install`, `status.sh`) — `private_Brewfile` renders to `~/Brewfile`,
  # the dev-machine set, which is a different file for a different job. Both
  # documents are in the skill; they cannot both be right about this path.
  # Collapsing it into a count would pick a side silently, on exactly the kind of
  # unexamined absence this report exists to surface. So it gets a row, and the
  # note carries the reason a reviewer needs in order to settle it themselves.
  #
  # The chezmoi detection survives only to FILL that note. Both conditions still
  # matter: a marker without the twin means the Brewfile is plainly missing, and
  # the twin without a marker is an ordinary repo that happens to use the prefix.
  # Neither shape earns the annotation, and neither is filtered either way.
  nonadoption_has_chezmoi_brewfile() {
    test -f .chezmoiroot || test -f .chezmoi.toml ||
      test -f .chezmoi.yaml || test -f .chezmoi.json || return 1
    test -f private_Brewfile || test -f home/private_Brewfile
  }
  # Drift class K's entries are false `MISSING`s only *because the repo carries a
  # documented replacement*, so each is checked against this repo and the ANSWER
  # is recorded either way: `known-false-verified` when the replacement is there,
  # `unverified-equivalent` when it is not. Neither outcome decides whether the
  # path is reported — the transition class already did that. This function only
  # says what the evidence was.
  nonadoption_known_false_note() {
    case "$1" in
    docs/decisions/0001-record-architecture-decisions.md)
      if nonadoption_has_adr_log; then
        nonadoption_add_note known-false-verified
      else
        nonadoption_add_note unverified-equivalent
      fi
      ;;
    terraform/main.tf | terraform/variables.tf | \
      terraform/outputs.tf | terraform/tfvars.env.example)
      if nonadoption_has_nested_terraform; then
        nonadoption_add_note known-false-verified
      else
        nonadoption_add_note unverified-equivalent
      fi
      ;;
    prettier.config.cjs)
      if nonadoption_has_prettier_config; then
        nonadoption_add_note known-false-verified
      else
        nonadoption_add_note unverified-equivalent
      fi
      ;;
    esac
  }
  # Whether the TEMPLATE declares a path local-only, evaluated in a scratch repo
  # built from the .gitignore files the TARGET render ships. The repo's own rules
  # are not the authority and never were: `ignored-absent-paths` is keyed on this
  # repo's `check-ignore`, so a repo that added `.vscode/` to its own .gitignore
  # was granting itself an adoption exemption on a template artifact every other
  # clone still gets. Ignoring something is a habit a repo can acquire for its own
  # reasons; the template DECLARING a path local is a statement about the artifact
  # — the same correction diff-template.sh's IGNORED class already makes.
  #
  # The TARGET render is the right side to ask, not the baseline: the question is
  # whether the file the update is about to decline to create is one the template
  # still means to keep local, and the target render is the post-update truth.
  #
  # Two things have to be shut off or this answers "what does this MACHINE
  # ignore" — the very question it exists to stop asking. An empty `--template`
  # keeps `init.templateDir`/`~/.git-template` from seeding an info/exclude, and
  # `core.excludesFile=/dev/null` keeps the operator's personal ignore file out of
  # the answer.
  NONADOPT_IGNORE_ROOT="$(mktemp -d -t copier-nonadoption-ignore-XXXXXX)" ||
    { echo "failed to create the render ignore evaluator" >&2; exit 1; }
  NONADOPT_IGNORE_SEEDED=0
  mkdir -p "$NONADOPT_IGNORE_ROOT/empty-git-template" ||
    { echo "failed to prepare the render ignore evaluator" >&2; exit 1; }
  git init -q --template="$NONADOPT_IGNORE_ROOT/empty-git-template" \
    "$NONADOPT_IGNORE_ROOT/tree" >/dev/null 2>&1 ||
    { echo "failed to initialize the render ignore evaluator" >&2; exit 1; }
  # Every .gitignore in the render, at its own relative path: a nested one governs
  # only its own subtree, so flattening them would change what they mean.
  find "$TARGET_DISCOVERY" -type f -name .gitignore |
    LC_ALL=C sort >"$GUARDED_STATE/render-ignore-files" ||
    { echo "failed to inventory the target render's ignore files" >&2; exit 1; }
  while IFS= read -r NONADOPT_IGNORE_SRC; do
    test -n "$NONADOPT_IGNORE_SRC" || continue
    NONADOPT_IGNORE_REL="${NONADOPT_IGNORE_SRC#"$TARGET_DISCOVERY"/}"
    mkdir -p "$(dirname "$NONADOPT_IGNORE_ROOT/tree/$NONADOPT_IGNORE_REL")" &&
      cp "$NONADOPT_IGNORE_SRC" \
        "$NONADOPT_IGNORE_ROOT/tree/$NONADOPT_IGNORE_REL" ||
      { echo "failed to stage $NONADOPT_IGNORE_REL for ignore evaluation" >&2; exit 1; }
    NONADOPT_IGNORE_SEEDED=1
  done <"$GUARDED_STATE/render-ignore-files"
  # `git check-ignore` is THREE-valued: 0 = matches an ignore rule, 1 = does not,
  # anything else = the probe itself failed. Folding the last two together is
  # fail-OPEN — a broken evaluator would answer "the template declares nothing
  # local" and turn every `ignored-policy` path into a table row the operator then
  # adopts back into a repo that never wanted it. There is no safe default for "I
  # could not tell", so an errored probe stops the run.
  nonadoption_is_render_ignored() {
    test "$NONADOPT_IGNORE_SEEDED" -eq 1 || return 1
    NONADOPT_IGNORE_RC=0
    NONADOPT_IGNORE_ERR="$(
      git -C "$NONADOPT_IGNORE_ROOT/tree" -c core.excludesFile=/dev/null \
        check-ignore -q --no-index -- "$1" 2>&1
    )" || NONADOPT_IGNORE_RC=$?
    case "$NONADOPT_IGNORE_RC" in
    0) return 0 ;;
    1) return 1 ;;
    esac
    echo "failed to evaluate the target render's ignore rules for $1 (git check-ignore exit $NONADOPT_IGNORE_RC)" >&2
    test -z "$NONADOPT_IGNORE_ERR" || printf '  %s\n' "$NONADOPT_IGNORE_ERR" >&2
    exit 1
  }
  # Gather EVERY explanation that applies, in no particular order, because none
  # of them competes with any other any more. There is no precedence chain to get
  # wrong and no early return to suppress a row: each probe either has something
  # to say about this path or does not.
  #
  # Notes join with `; `. Callers reset NONADOPT_NOTE once per path, before the
  # presence test, because presence may already have something to add.
  nonadoption_collect_notes() {
    case "$1" in
    *.gitkeep) nonadoption_add_note gitkeep ;;
    esac
    if nonadoption_is_doc_prose "$1"; then
      nonadoption_add_note co-owned-prose
    fi
    # Repo-ignored, but the exemption belongs to the TEMPLATE's declaration: a
    # repo that added `.vscode/` to its own .gitignore is stating a habit, not a
    # fact about the artifact every other clone receives.
    if grep -qxF -- "$1" "$GUARDED_STATE/ignored-absent-paths"; then
      if nonadoption_is_render_ignored "$1"; then
        nonadoption_add_note ignored-policy
      else
        nonadoption_add_note repo-ignored-only
      fi
    fi
    nonadoption_known_false_note "$1"
    # The `.yml`/`.yaml` counterpart, as evidence and nothing more. Round 5 had
    # to reason per class about whether a twin counted as presence; the scratch
    # apply answers that by watching, so all that survives is telling the
    # reviewer the other spelling is there.
    NONADOPT_TWIN="$(nonadoption_twin_of "$1")"
    if test -n "$NONADOPT_TWIN" && nonadoption_path_present . "$NONADOPT_TWIN"; then
      nonadoption_add_note "twin-exists: $NONADOPT_TWIN"
    fi
    # The root Brewfile: class K calls its absence a false MISSING in a chezmoi
    # source repo, mode-adopt-existing.md §4.7 says the repo needs one anyway for
    # its own toolchain. Two documents in one skill disagree, so the note names
    # the argument and the reviewer settles it.
    case "$1" in
    Brewfile)
      if nonadoption_has_chezmoi_brewfile; then
        nonadoption_add_note "chezmoi-managed — verify per mode-audit class K"
      fi
      ;;
    esac
  }
  # Did the template itself change the file across the update range? A `no` says
  # the repo is declining a file that has sat unchanged since its own baseline;
  # a `yes` says it is also missing upstream work.
  nonadoption_changed_in_range() {
    NONADOPT_BASE="$BASELINE_DISCOVERY/$1"
    NONADOPT_TGT="$TARGET_DISCOVERY/$1"
    if test -L "$NONADOPT_BASE" || test -L "$NONADOPT_TGT"; then
      # A symlink has no readable content of its own: `cmp` would follow it, or
      # fail outright on a dangling one. Compare link targets instead.
      if ! test -L "$NONADOPT_BASE" || ! test -L "$NONADOPT_TGT"; then
        printf '%s\n' unknown
        return 0
      fi
      NONADOPT_BASE_LINK="$(readlink "$NONADOPT_BASE")" &&
        NONADOPT_TGT_LINK="$(readlink "$NONADOPT_TGT")" ||
        {
          printf '%s\n' unknown
          return 0
        }
      if test "$NONADOPT_BASE_LINK" = "$NONADOPT_TGT_LINK"; then
        printf '%s\n' no
      else
        printf '%s\n' yes
      fi
      return 0
    fi
    if ! test -f "$NONADOPT_BASE" || ! test -r "$NONADOPT_BASE" ||
      ! test -f "$NONADOPT_TGT" || ! test -r "$NONADOPT_TGT"; then
      printf '%s\n' unknown
      return 0
    fi
    # The exec bit is upstream work too, and `cmp` cannot see it. A template that
    # fixed a rendered script from 100644 to 100755 across the range changed the
    # file in the only way that mattered, and reporting `no` would tell the
    # reviewer the repo is declining something that has not moved. Symlinks never
    # reach here — the branch above returns — so the bit always belongs to the
    # file itself rather than to a link target.
    NONADOPT_BASE_EXEC=0
    NONADOPT_TGT_EXEC=0
    test ! -x "$NONADOPT_BASE" || NONADOPT_BASE_EXEC=1
    test ! -x "$NONADOPT_TGT" || NONADOPT_TGT_EXEC=1
    if test "$NONADOPT_BASE_EXEC" != "$NONADOPT_TGT_EXEC"; then
      printf '%s\n' yes
      return 0
    fi
    if cmp -s "$NONADOPT_BASE" "$NONADOPT_TGT"; then
      printf '%s\n' no
    else
      printf '%s\n' yes
    fi
  }
  # path<TAB>class<TAB>changed_in_range<TAB>baseline_membership<TAB>note
  #
  # `class` is what the scratch apply was OBSERVED to do to this path:
  #   nonadopt-both  absent before, absent after, and the target render ships it
  #                  — copier demonstrably declines to adopt it
  #   created        absent before, present after (the note says which kind)
  #   deleted        present before, absent after
  # A path present on both sides is adopted and gets no row; one absent on both
  # sides that the target does not ship is not the update's business.
  #
  # `note` is `-`, or accumulated evidence: `new-in-target` / `recreated`,
  # `co-owned-prose`, `ignored-policy`, `repo-ignored-only`,
  # `known-false-verified`, `unverified-equivalent`, `package-json-unparseable`,
  # `gitkeep`, `twin-exists: <path>`, and the chezmoi Brewfile annotation. Notes
  # annotate; they never remove a row.
  # One emitter: three call sites had to be kept in step on the column count by
  # hand, and a fifth column was once added to all of them one at a time.
  nonadoption_emit_row() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$NONADOPT_NOTE" \
      >>"$GUARDED_STATE/nonadoption-report.tsv" ||
      { echo "failed to record non-adoption row: $1" >&2; exit 1; }
  }
  : >"$GUARDED_STATE/nonadoption-report.tsv"
  while IFS= read -r NONADOPT_PATH; do
    test -n "$NONADOPT_PATH" || continue
    NONADOPT_NOTE=-
    NONADOPT_BEFORE=0
    nonadoption_path_present . "$NONADOPT_PATH" && NONADOPT_BEFORE=1
    NONADOPT_AFTER=0
    if test "$NONADOPT_REHEARSED" -eq 1; then
      nonadoption_path_present "$NONADOPT_SCRATCH/repo" "$NONADOPT_PATH" &&
        NONADOPT_AFTER=1
    fi
    NONADOPT_IN_BASELINE=0
    NONADOPT_IN_TARGET=0
    nonadoption_in_set baseline-managed-paths "$NONADOPT_PATH" &&
      NONADOPT_IN_BASELINE=1
    nonadoption_in_set target-managed-paths "$NONADOPT_PATH" &&
      NONADOPT_IN_TARGET=1
    NONADOPT_CLASS=""
    if test "$NONADOPT_REHEARSED" -eq 0; then
      # Nothing was observed, so nothing is claimed: every managed path the apply
      # could touch gets a row and §2's reconciliation resolves it against the
      # real result. PRESENT paths included — the earlier shape skipped a path the
      # repo already had when the target still shipped it, on the reasoning that
      # an ordinary apply leaves it alone. Migrations are the whole reason this
      # branch exists and they run arbitrary commands, so one can delete it, and
      # skipping the row let the report call that update clean. The before-state
      # is recorded as a note because reconciliation has no other way to know it:
      # by then the tree has moved.
      #
      # Deliberately plain. harmon-init declares no `_migrations`, so this path is
      # dormant for the platform; it needs to be correct, not elaborate.
      if test "$NONADOPT_BEFORE" -eq 1; then
        nonadoption_add_note present-before
      elif test "$NONADOPT_IN_TARGET" -eq 0; then
        # Absent, and the target does not ship it: nothing for the apply to do.
        continue
      fi
      NONADOPT_CLASS=unknown-until-apply
    elif test "$NONADOPT_BEFORE" -eq 0 && test "$NONADOPT_AFTER" -eq 0; then
      # Only interesting while the target render still ships it: that is a file
      # the repo could have and, as the rehearsal just showed, never will.
      test "$NONADOPT_IN_TARGET" -eq 1 || continue
      NONADOPT_CLASS=nonadopt-both
    elif test "$NONADOPT_BEFORE" -eq 0; then
      NONADOPT_CLASS=created
      if test "$NONADOPT_IN_TARGET" -eq 0; then
        # Written by the apply but shipped by NEITHER render: a `.rej`/`.orig`
        # left behind by a conflicted merge, not something the repo adopted.
        # Calling it `new-in-target` put a merge failure in the adoption table.
        nonadoption_add_note apply-artifact
      elif test "$NONADOPT_IN_BASELINE" -eq 1; then
        # Both renders ship it and the repo lacked it, yet the apply wrote it
        # anyway — `_skip_if_exists`, observed rather than pattern-matched.
        nonadoption_add_note recreated
      else
        nonadoption_add_note new-in-target
      fi
    elif test "$NONADOPT_AFTER" -eq 0; then
      NONADOPT_CLASS=deleted
    else
      continue
    fi
    if test "$NONADOPT_IN_BASELINE" -eq 1 && test "$NONADOPT_IN_TARGET" -eq 1; then
      NONADOPT_MEMBER=baseline+target
      NONADOPT_CHANGED="$(nonadoption_changed_in_range "$NONADOPT_PATH")" ||
        { echo "failed to compare rendered copies: $NONADOPT_PATH" >&2; exit 1; }
    elif test "$NONADOPT_IN_TARGET" -eq 1; then
      NONADOPT_MEMBER=target-only
      NONADOPT_CHANGED=n/a-new
    elif test "$NONADOPT_IN_BASELINE" -eq 1; then
      NONADOPT_MEMBER=baseline-only
      NONADOPT_CHANGED=n/a-removed
    else
      NONADOPT_MEMBER=unrendered
      NONADOPT_CHANGED=n/a-unrendered
    fi
    nonadoption_collect_notes "$NONADOPT_PATH"
    nonadoption_emit_row "$NONADOPT_PATH" "$NONADOPT_CLASS" \
      "$NONADOPT_CHANGED" "$NONADOPT_MEMBER"
  done <"$GUARDED_STATE/nonadoption-candidates"
  for NONADOPT_CLASS in nonadopt-both created deleted unknown-until-apply; do
    NONADOPT_COUNT="$(
      awk -F '\t' -v cls="$NONADOPT_CLASS" \
        '$2 == cls { n++ } END { print n + 0 }' \
        "$GUARDED_STATE/nonadoption-report.tsv"
    )" ||
      { echo "failed to count non-adoption class: $NONADOPT_CLASS" >&2; exit 1; }
    printf 'non-adoption %-14s %s\n' "$NONADOPT_CLASS" "$NONADOPT_COUNT"
  done
  # The rehearsal is spent. An aborted run leaves it behind ON PURPOSE, exactly
  # like the discovery renders above: when the scratch apply fails, that scratch
  # IS the diagnosis — it holds the half-applied tree and copier's own output —
  # so the error paths name its location instead of deleting the evidence. Only
  # the success path cleans up.
  if test "$NONADOPT_REHEARSED" -eq 1 && test -n "$NONADOPT_SCRATCH"; then
    rm -rf -- "$NONADOPT_SCRATCH" ||
      { echo "failed to remove the scratch apply directory" >&2; exit 1; }
  fi
  # Scratch, and outside the repo: nothing below reads it. A fail-closed exit
  # above leaves it behind on purpose — the guarded run is aborting, and a
  # `mktemp -d` under the system temp dir is the operator's to inspect.
  if test -n "$NONADOPT_IGNORE_ROOT"; then
    rm -rf -- "$NONADOPT_IGNORE_ROOT" ||
      { echo "failed to remove the render ignore evaluator" >&2; exit 1; }
  fi
  # <<< nonadoption-classify <<<
  tar -cf "$GUARDED_STATE/ignored-backup.tar" \
    -T "$GUARDED_STATE/ignored-existing-paths" ||
    { echo "failed to back up ignored managed paths" >&2; exit 1; }
  git hash-object "$GUARDED_STATE/ignored-backup.tar" \
    >"$GUARDED_STATE/ignored-backup-oid" &&
    git hash-object "$GUARDED_STATE/ignored-managed-paths" \
      >"$GUARDED_STATE/ignored-managed-paths-oid" &&
    printf '%s\n' ready >"$GUARDED_STATE/ignored-snapshot-ready" ||
    { echo "failed to freeze ignored-path recovery state" >&2; exit 1; }
fi
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
run_guarded_copier update --trust --defaults --pretend \
  --vcs-ref="$HARMON_INIT_COMMIT" \
  --data-file="$REVIEWED_DATA"
```

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
sentinel. Each pass supplies only reviewed keys that Copier marked active on
the prior pass, so a stale value from a newly inactive question cannot affect
later conditions. Hidden `when: false` values and inactive conditional
questions are never passed as user data. On recovery, load the complete map
instead of recomputing defaults:

```bash
REVIEWED_DATA="$GUARDED_STATE/reviewed-data.yml"
USE_FOREMAN="$(yq -r '.use_foreman' "$REVIEWED_DATA")"
USE_CODEX_REVIEW="$(yq -r '.use_codex_review' "$REVIEWED_DATA")"
USE_CODEX_CLOUD_REVIEW="$(
  yq -r '.use_codex_cloud_review // false' "$REVIEWED_DATA"
)"
USE_SKILLS_SYNC="$(yq -r '.use_skills_sync' "$REVIEWED_DATA")"
SKILL_CATEGORIES="$(
  yq -o=json -I=0 '.skill_categories // []' "$REVIEWED_DATA"
)"
USE_CODERABBIT="$(yq -r '.use_coderabbit' "$REVIEWED_DATA")"
USE_CODEQL="$(yq -r '.use_codeql' "$REVIEWED_DATA")"
CODEQL_LANGUAGES="$(
  yq -o=json -I=0 '.codeql_languages' "$REVIEWED_DATA"
)"
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
renders in hand is what makes it visible at all, which is why the block above
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
test "$(cat "$GUARDED_STATE/start-head")" = "$(git rev-parse HEAD)" &&
  test "$(cat "$GUARDED_STATE/start-checkout")" = "$(guarded_checkout_id)" &&
  test "$(cat "$GUARDED_STATE/canonical-answers-oid")" = \
    "$(git hash-object .copier-answers.yml)" &&
  test "$(cat "$GUARDED_STATE/target-commit")" = "$HARMON_INIT_COMMIT" &&
  test "$(cat "$GUARDED_STATE/template-path")" = "$GUARDED_TEMPLATE" &&
  test "$(cat "$GUARDED_STATE/cache-path")" = "$GUARDED_COPIER_CACHE" &&
  test "$(cat "$GUARDED_STATE/reviewed-data-oid")" = \
    "$(git hash-object "$REVIEWED_DATA")" &&
  test "$(cat "$GUARDED_STATE/ignored-snapshot-ready")" = ready &&
  test "$(cat "$GUARDED_STATE/ignored-backup-oid")" = \
    "$(git hash-object "$GUARDED_STATE/ignored-backup.tar")" &&
  test "$(cat "$GUARDED_STATE/ignored-managed-paths-oid")" = \
    "$(git hash-object "$GUARDED_STATE/ignored-managed-paths")" &&
  test -z "$(git status --porcelain)" ||
  { echo "working checkout no longer matches guarded update state" >&2; exit 1; }
tar -cf "$GUARDED_STATE/ignored-preapply.tar" \
  -T "$GUARDED_STATE/ignored-existing-paths" ||
  { echo "failed to verify ignored paths before apply" >&2; exit 1; }
test "$(git hash-object "$GUARDED_STATE/ignored-preapply.tar")" = \
  "$(cat "$GUARDED_STATE/ignored-backup-oid")" ||
  { echo "an ignored managed path changed after preparation" >&2; exit 1; }
rm -f "$GUARDED_STATE/ignored-preapply.tar"
while IFS= read -r ABSENT_IGNORED_PATH; do
  if test -e "$ABSENT_IGNORED_PATH" || test -L "$ABSENT_IGNORED_PATH"; then
    echo "an ignored managed path appeared after preparation: $ABSENT_IGNORED_PATH" >&2
    exit 1
  fi
done <"$GUARDED_STATE/ignored-absent-paths"
test ! -e "$GUARDED_STATE/apply-phase" ||
  {
    echo "apply already started; do not rerun Copier—continue with applied-state validation" >&2
    exit 1
  }
write_guarded_phase() {
  GUARDED_PHASE="$1"
  GUARDED_PHASE_CANDIDATE="$(
    mktemp "$GUARDED_STATE/apply-phase.XXXXXX"
  )" ||
    { echo "failed to create apply-phase candidate" >&2; return 1; }
  if printf '%s\n' "$GUARDED_PHASE" >"$GUARDED_PHASE_CANDIDATE" &&
    mv "$GUARDED_PHASE_CANDIDATE" "$GUARDED_STATE/apply-phase"; then
    return 0
  fi
  rm -f "$GUARDED_PHASE_CANDIDATE"
  echo "failed to persist guarded apply phase" >&2
  return 1
}
write_guarded_phase applying ||
  { echo "Copier was not started" >&2; exit 1; }
if run_guarded_copier update --trust --defaults \
  --vcs-ref="$HARMON_INIT_COMMIT" \
  --data-file="$REVIEWED_DATA"; then
  write_guarded_phase applied ||
    {
      echo "Copier returned success but phase recording failed; validate the applied state" >&2
      exit 1
    }
else
  echo "guarded Copier update failed; preserve the applying phase and recovery state" >&2
  exit 1
fi
```

Use the same frozen reviewed-data file in the preview and real invocation; do
not retype or omit answers between those two steps. The `applying` phase is
atomically recorded before Copier can mutate the worktree. `applied` records a
normal return, but promotion does not trust either phase by itself: it validates
the complete resulting state below. After a crash or nonzero return, never
blindly rerun Copier.

**Reconcile the rehearsal against the real apply — now, before anything else
touches the tree.** This is the only moment the comparison is meaningful: §3 is
about to make deliberate changes the guidance prescribes, and every one of them
would read as divergence afterwards.

```bash
nonadoption_reconcile() {
  RECONCILE_BAD=0
  RECONCILE_OUT="$GUARDED_STATE/nonadoption-resolved.tsv"
  : >"$RECONCILE_OUT"
  while IFS="$(printf '\t')" read -r ROW_PATH ROW_CLASS ROW_CHANGED ROW_MEMBER ROW_NOTE; do
    test -n "$ROW_PATH" || continue
    # The same file-or-symlink predicate the observation used. `-e` would call a
    # directory at a rendered file's path "present" and pass a mismatch.
    ROW_PRESENT=0
    if test -f "$ROW_PATH" || test -L "$ROW_PATH"; then
      ROW_PRESENT=1
    fi
    case "$ROW_CLASS" in
    nonadopt-both)
      test "$ROW_PRESENT" -eq 0 || {
        echo "DIVERGED  $ROW_PATH: rehearsal left it absent, the real apply created it" >&2
        RECONCILE_BAD=$((RECONCILE_BAD + 1))
      }
      ;;
    created)
      test "$ROW_PRESENT" -eq 1 || {
        echo "DIVERGED  $ROW_PATH: rehearsal created it ($ROW_NOTE), the real apply did not" >&2
        RECONCILE_BAD=$((RECONCILE_BAD + 1))
      }
      ;;
    deleted)
      test "$ROW_PRESENT" -eq 0 || {
        echo "DIVERGED  $ROW_PATH: rehearsal deleted it, the real apply left it in place" >&2
        RECONCILE_BAD=$((RECONCILE_BAD + 1))
      }
      ;;
    unknown-until-apply)
      # No prediction to confirm — the rehearsal was refused, so this resolves
      # the row into exactly the class the rehearsed path would have recorded.
      # §1 records the before-state as a `present-before` note, because nothing
      # else here can recover it: by now the tree has moved. Reading present-after
      # alone called a surviving file `created` and a removed one `nonadopt-both`,
      # both backwards.
      case "$ROW_NOTE" in
      *present-before*)
        if test "$ROW_PRESENT" -eq 1; then
          # Present before and after: no transition at all. The rehearsed path
          # emits no row for this, so neither does the resolution — inventing a
          # `retained` class would put a non-event in a report of events.
          continue
        fi
        ROW_CLASS=deleted
        # The target render still ships it, so an ordinary apply would have left
        # it alone. Something else removed it, and on this branch that means a
        # migration — flagged as a question, not a conclusion.
        case "$ROW_MEMBER" in
        baseline-only) ;;
        *) ROW_NOTE="$ROW_NOTE; migration-effect?" ;;
        esac
        ;;
      *)
        if test "$ROW_PRESENT" -eq 1; then
          ROW_CLASS=created
          case "$ROW_MEMBER" in
          baseline+target) ROW_KIND=recreated ;;
          target-only) ROW_KIND=new-in-target ;;
          *) ROW_KIND=apply-artifact ;;
          esac
          # Same note and same ordering the rehearsed path produces: the kind
          # first, then whatever evidence §1 already attached.
          if test "$ROW_NOTE" = -; then
            ROW_NOTE="$ROW_KIND"
          else
            ROW_NOTE="$ROW_KIND; $ROW_NOTE"
          fi
        else
          ROW_CLASS=nonadopt-both
        fi
        ;;
      esac
      ;;
    *)
      echo "DIVERGED  $ROW_PATH: unknown class '$ROW_CLASS' in the report" >&2
      RECONCILE_BAD=$((RECONCILE_BAD + 1))
      ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$ROW_PATH" "$ROW_CLASS" "$ROW_CHANGED" "$ROW_MEMBER" "$ROW_NOTE" \
      >>"$RECONCILE_OUT" || return 1
  done <"$GUARDED_STATE/nonadoption-report.tsv"
  test "$RECONCILE_BAD" -eq 0 || {
    echo "non-adoption reconciliation failed on $RECONCILE_BAD path(s); the applied tree does not match the rehearsal — stop and investigate before hand-off" >&2
    return 1
  }
  mv "$RECONCILE_OUT" "$GUARDED_STATE/nonadoption-report.tsv" || return 1
  # Bind the verdict to THIS run and THIS report. "clean" on its own is a claim
  # with no subject: after a rollback and a rerun that dies before persisting, an
  # old verdict still reads clean and still sits next to a report describing a
  # tree that no longer exists. §1 clears both on entry; this makes the pairing
  # checkable even if that ever fails.
  RECONCILE_REPORT_OID="$(
    git hash-object "$GUARDED_STATE/nonadoption-report.tsv"
  )" || return 1
  {
    printf 'reconciled: clean\n'
    printf 'report: %s\n' "$RECONCILE_REPORT_OID"
    printf 'target-commit: %s\n' "$(cat "$GUARDED_STATE/target-commit")"
    printf 'start-head: %s\n' "$(cat "$GUARDED_STATE/start-head")"
  } >"$GUARDED_STATE/nonadoption-reconciled" || return 1
}
nonadoption_reconcile ||
  { echo "reconciliation failed; do not proceed to §3" >&2; exit 1; }
```

A non-zero return stops the run. Do not "note it and continue": the rehearsal
and the apply ran the same copier with the same ref and the same answers, so a
disagreement means the environment moved, and the report §5 is about to publish
describes a tree that does not exist.

**Persist the non-adoption report before anything tears `$GUARDED_STATE` down.**
Promotion below deletes that directory, and §4 and §5 both still need the TSV:

```bash
test "$(cat "$GUARDED_STATE/start-checkout")" = "$(guarded_checkout_id)" ||
  { echo "checkout changed since guarded preparation; refusing to write the non-adoption report" >&2; exit 1; }
GUARDED_NONADOPT_BRANCH="$(git branch --show-current)"
test -n "$GUARDED_NONADOPT_BRANCH" ||
  { echo "detached HEAD: no branch to key the non-adoption report to" >&2; exit 1; }
GUARDED_NONADOPT_FILE="$(
  git rev-parse --path-format=absolute \
    --git-path "guarded-update-nonadoption/$GUARDED_NONADOPT_BRANCH"
)" || { echo "failed to resolve the non-adoption report path" >&2; exit 1; }
mkdir -p "$(dirname "$GUARDED_NONADOPT_FILE")" ||
  { echo "failed to create the non-adoption report directory" >&2; exit 1; }
test -s "$GUARDED_STATE/nonadoption-reconciled" ||
  { echo "refusing to persist an unreconciled non-adoption report" >&2; exit 1; }
cp "$GUARDED_STATE/nonadoption-report.tsv" "$GUARDED_NONADOPT_FILE.$$.tmp" &&
  mv "$GUARDED_NONADOPT_FILE.$$.tmp" "$GUARDED_NONADOPT_FILE" ||
  { echo "failed to persist the non-adoption report" >&2; exit 1; }
GUARDED_VERDICT_FILE="$(
  git rev-parse --path-format=absolute \
    --git-path "guarded-update-reconciled/$GUARDED_NONADOPT_BRANCH"
)" || { echo "failed to resolve the reconciliation verdict path" >&2; exit 1; }
mkdir -p "$(dirname "$GUARDED_VERDICT_FILE")" ||
  { echo "failed to create the reconciliation verdict directory" >&2; exit 1; }
cp "$GUARDED_STATE/nonadoption-reconciled" "$GUARDED_VERDICT_FILE.$$.tmp" &&
  mv "$GUARDED_VERDICT_FILE.$$.tmp" "$GUARDED_VERDICT_FILE" ||
  { echo "failed to persist the reconciliation verdict" >&2; exit 1; }
```

This mirrors the deferred-findings git-path idiom, **including the branch key**,
and for the same reason. The git directory is deterministic for any later
session in this checkout, resolves correctly inside a linked worktree, and is
invisible to `git status`, so the report can never be handed to a reviewer as
part of the change under review. But an ordinary clone switches branches *in
place*: with one shared file, a guarded update started on branch B would
overwrite branch A's report before A's PR body was ever written, and A's only
copy of its own findings is gone — the classification survived §1, survived
promotion, and was then destroyed by an unrelated run. The branch is the key
because the branch is what owns the report.

**The binding is re-checked immediately before the write, and the write is
atomic.** Everything above ran minutes ago at best, and the branch key is read
from live git state, not from the frozen record — so a checkout that moved in
between would file this run's report under someone else's name, destroying
theirs and hiding this one. The same `start-checkout` comparison the promotion
block makes is therefore repeated here, at the last moment it can still matter,
and it refuses rather than guessing. The copy then lands via a temp file and
`mv` **within the same directory**, so a crash mid-write leaves either the old
report or the new one, never a truncated file that reads as a short list of
findings.

The branch name becomes a **path, verbatim** — no `/`-folding, no extension.
Folding `/` to `-` would collide `feat/x` with `feat-x` and reintroduce exactly
the loss the key exists to prevent; an extension would make `foo` (a file) block
`foo.md/bar` (needing a directory). Used as-is, the mapping is git's own ref
namespace, and git already forbids one live branch from being a path prefix of
another. A detached HEAD has no key at all, so it stops rather than guessing.

It needs no cleanup on the rollback path — rollback re-runs §1, which
regenerates the report from scratch.

Copier can return success while leaving merge conflicts. Reconcile those as
described in §3 before promotion. Then prove that the canonical answers record
the applied target and promote its lineage to the canonical URL plus full target
commit:

```bash
test "$(cat "$GUARDED_STATE/start-head")" = "$(git rev-parse HEAD)" &&
  test "$(cat "$GUARDED_STATE/start-checkout")" = "$(guarded_checkout_id)" &&
  test "$(cat "$GUARDED_STATE/canonical-answers-oid")" = \
    "$(git hash-object "$GUARDED_STATE/original-answers.yml")" &&
  test "$(cat "$GUARDED_STATE/target-commit")" = "$HARMON_INIT_COMMIT" &&
  test "$(cat "$GUARDED_STATE/template-path")" = "$GUARDED_TEMPLATE" &&
  test "$(cat "$GUARDED_STATE/cache-path")" = "$GUARDED_COPIER_CACHE" &&
  test "$(cat "$GUARDED_STATE/reviewed-data-oid")" = \
    "$(git hash-object "$REVIEWED_DATA")" &&
  test "$(cat "$GUARDED_STATE/ignored-snapshot-ready")" = ready &&
  test "$(cat "$GUARDED_STATE/ignored-backup-oid")" = \
    "$(git hash-object "$GUARDED_STATE/ignored-backup.tar")" &&
  test "$(cat "$GUARDED_STATE/ignored-managed-paths-oid")" = \
    "$(git hash-object "$GUARDED_STATE/ignored-managed-paths")" ||
  { echo "working checkout no longer matches guarded update state" >&2; exit 1; }
APPLY_PHASE="$(cat "$GUARDED_STATE/apply-phase")" ||
  { echo "guarded apply has not started" >&2; exit 1; }
case "$APPLY_PHASE" in
applied) ;;
applying)
  echo "Copier did not record a normal return; validate for diagnosis, then use the rollback path" >&2
  exit 1
  ;;
*) echo "invalid guarded apply phase" >&2; exit 1 ;;
esac
test -z "$(git diff --name-only --diff-filter=U)" ||
  { echo "resolve every Copier merge conflict before promotion" >&2; exit 1; }
APPLIED_REF="$(yq -r '._commit // ""' .copier-answers.yml)" &&
  APPLIED_SOURCE="$(yq -r '._src_path // ""' .copier-answers.yml)" ||
  { echo "applied canonical answers are not valid YAML" >&2; exit 1; }
APPLIED_COMMIT="$(
  git -C "$GUARDED_TEMPLATE" rev-parse "$APPLIED_REF^{commit}"
)" ||
  { echo "applied answers do not record a resolvable commit" >&2; exit 1; }
case "$APPLIED_SOURCE" in
"$HARMON_INIT_SOURCE" | "$HARMON_INIT_SOURCE.git") ;;
*) echo "applied answers no longer name canonical harmon-init" >&2; exit 1 ;;
esac
test "$APPLIED_COMMIT" = "$HARMON_INIT_COMMIT" ||
  { echo "guarded update did not apply the validated target" >&2; exit 1; }
while IFS= read -r REVIEWED_KEY; do
  REVIEWED_KEY="$REVIEWED_KEY" yq -e \
    'has(strenv(REVIEWED_KEY))' .copier-answers.yml >/dev/null ||
    {
      echo "applied answers omit reviewed key: $REVIEWED_KEY" >&2
      exit 1
    }
  ACTUAL_REVIEWED_VALUE="$(
    REVIEWED_KEY="$REVIEWED_KEY" \
      yq -o=json -I=0 '.[strenv(REVIEWED_KEY)]' .copier-answers.yml
  )" &&
    EXPECTED_REVIEWED_VALUE="$(
      REVIEWED_KEY="$REVIEWED_KEY" \
        yq -o=json -I=0 '.[strenv(REVIEWED_KEY)]' "$REVIEWED_DATA"
    )" &&
    test "$ACTUAL_REVIEWED_VALUE" = "$EXPECTED_REVIEWED_VALUE" ||
    {
      echo "applied answer differs from reviewed value: $REVIEWED_KEY" >&2
      exit 1
    }
done <"$GUARDED_STATE/reviewed-keys"
PROMOTED_ANSWERS="$(mktemp .copier-answers.yml.promote.XXXXXX)" ||
  { echo "failed to create answers promotion file" >&2; exit 1; }
if cp .copier-answers.yml "$PROMOTED_ANSWERS" &&
  HARMON_INIT_SOURCE="$HARMON_INIT_SOURCE" \
    HARMON_INIT_COMMIT="$HARMON_INIT_COMMIT" \
    yq -i \
      '._src_path = strenv(HARMON_INIT_SOURCE) |
       ._commit = strenv(HARMON_INIT_COMMIT)' \
      "$PROMOTED_ANSWERS"; then
  mv "$PROMOTED_ANSWERS" .copier-answers.yml ||
    { echo "failed to atomically promote canonical answers" >&2; exit 1; }
  git add -- .copier-answers.yml ||
    { echo "failed to stage promoted canonical answers" >&2; exit 1; }
  test "$GUARDED_STATE" = .copier-guarded-update &&
    test -d "$GUARDED_STATE" &&
    test ! -L "$GUARDED_STATE" &&
    rm -rf -- "$GUARDED_STATE" ||
    { echo "canonical answers promoted, but guarded state cleanup failed" >&2; exit 1; }
else
  echo "answers promotion failed; canonical answers and recovery state remain" >&2
  exit 1
fi
git diff -- .copier-answers.yml # canonical URL + full HARMON_INIT_COMMIT
```

Do not normalize only one field. The successful guarded update may have changed
other answers, so copy its complete result first, then replace `_src_path` and
`_commit` together with the already-validated canonical values. The temporary
file is renamed over the canonical answers only after both edits succeed; if
promotion fails, preserve it and recovery state for diagnosis. Promotion is
allowed only when the checkout and original answers still match preparation and
the `applied` phase proves Copier returned normally, the reviewed-data object is
unchanged, and the applied canonical answers resolve to the validated target
commit in the offline clone with every reviewed value intact. An `applying`
state is never promotable: Copier writes the target answers before its full
three-way merge is complete, so the answers alone cannot prove that a
mid-process crash left a complete update.

If an interrupted `applying` state fails that validation, preserve it for
diagnosis. To abandon it, first verify the recorded branch and HEAD still match,
inspect `git diff`, and obtain explicit maintainer approval to discard **all**
worktree changes made since preparation. The deterministic rollback is:

```bash
test "$(cat "$GUARDED_STATE/start-head")" = "$(git rev-parse HEAD)" &&
  test "$(cat "$GUARDED_STATE/start-checkout")" = "$(guarded_checkout_id)" &&
  test "$(cat "$GUARDED_STATE/canonical-answers-oid")" = \
    "$(git hash-object "$GUARDED_STATE/original-answers.yml")" &&
  test "$(cat "$GUARDED_STATE/ignored-snapshot-ready")" = ready &&
  test "$(cat "$GUARDED_STATE/ignored-backup-oid")" = \
    "$(git hash-object "$GUARDED_STATE/ignored-backup.tar")" &&
  test "$(cat "$GUARDED_STATE/ignored-managed-paths-oid")" = \
    "$(git hash-object "$GUARDED_STATE/ignored-managed-paths")" ||
  { echo "rollback context no longer matches guarded preparation" >&2; exit 1; }
git diff HEAD --stat
git clean -nd
tar -tvf "$GUARDED_STATE/ignored-backup.tar"
cat "$GUARDED_STATE/ignored-absent-paths"
: "${APPROVE_GUARDED_ROLLBACK:?obtain maintainer approval after reviewing all four outputs}"
test "$APPROVE_GUARDED_ROLLBACK" = true ||
  { echo "APPROVE_GUARDED_ROLLBACK must be exactly true" >&2; exit 1; }
git restore \
  --source="$(cat "$GUARDED_STATE/start-head")" \
  --staged --worktree -- .
git clean -fd
while IFS= read -r ABSENT_IGNORED_PATH; do
  rm -f -- "$ABSENT_IGNORED_PATH" ||
    { echo "failed to remove new ignored path: $ABSENT_IGNORED_PATH" >&2; exit 1; }
done <"$GUARDED_STATE/ignored-absent-paths"
tar -xf "$GUARDED_STATE/ignored-backup.tar" ||
  { echo "failed to restore ignored managed paths" >&2; exit 1; }
tar -cf "$GUARDED_STATE/ignored-verify.tar" \
  -T "$GUARDED_STATE/ignored-existing-paths" ||
  { echo "failed to verify ignored managed paths" >&2; exit 1; }
test "$(git hash-object .copier-answers.yml)" = \
  "$(cat "$GUARDED_STATE/canonical-answers-oid")" &&
  test "$(git hash-object "$GUARDED_STATE/ignored-verify.tar")" = \
    "$(cat "$GUARDED_STATE/ignored-backup-oid")" &&
  test -z "$(git status --porcelain)" ||
  { echo "rollback did not restore the prepared worktree" >&2; exit 1; }
while IFS= read -r ABSENT_IGNORED_PATH; do
  if test -e "$ABSENT_IGNORED_PATH" || test -L "$ABSENT_IGNORED_PATH"; then
    echo "rollback left a newly-created ignored path: $ABSENT_IGNORED_PATH" >&2
    exit 1
  fi
done <"$GUARDED_STATE/ignored-absent-paths"
rm -f "$GUARDED_STATE/ignored-verify.tar"
test "$GUARDED_STATE" = .copier-guarded-update &&
  test -d "$GUARDED_STATE" &&
  test ! -L "$GUARDED_STATE" &&
  rm -rf -- "$GUARDED_STATE" ||
  { echo "rollback succeeded, but guarded state cleanup failed" >&2; exit 1; }
```

Run `git clean -fd` only if its preview contains exclusively Copier-created
paths; the ignored guarded state survives that command. The prepared tar archive
restores pre-existing ignored template paths, and the absent-path list removes
ignored paths that Copier created. This rollback is destructive and must never
be inferred from a failed validation.

Stage the promoted file immediately because §3 may already have staged Copier's
tag-valued version. Leave the guarded template and Copier cache directories in
the system temporary area until the PR is verified; the OS can clean them later.

**`--defaults` is mandatory when running non-interactively (agents have no TTY),
but it is not permission to accept newly introduced behavior.** Review and pass
new answers explicitly as described above. Without `--defaults`, Copier tries to
prompt for answers and crashes with
`OSError: [Errno 22] Invalid argument` (prompt_toolkit can't attach to a missing
terminal). It reuses the stored answers and accepts defaults for any new questions
the template added since `_commit`; the generated `--data-file` explicitly
authorizes every one of those new questions, while `--defaults` supplies only
unchanged existing answers and noninteractive prompt behavior.

**Always do a full update to the deliberately selected latest released
version.** Derive `HARMON_INIT_COMMIT` once from the remote-verified
`HARMON_INIT_REF`, resolve `RECORDED_COMMIT` once, place both in the read-only
offline clone, and pass the immutable target commit to both preview and apply
through `run_guarded_copier`. Copier three-way-merges the *entire* delta from that
immutable recorded baseline up to the release commit, preserving local edits.
Do not hand-pick which template changes to take—select the current release and
reconcile the full result in §3.
First-run `_tasks` are guarded on `_copier_operation == 'copy'`, so
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

**Diff the template's script inventory across the range — audit what
survived the update.** Copier does delete a cleanly-tracked old file when
the template renames it (delete + add in the re-rendered diff). The orphans
are the *survivors*: an old copy the repo modified locally, adopted by hand
(so copier never tracked it), or renamed out of path-match. Any of those
stays behind silently while every workflow/Taskfile reference to it keeps
"working" against stale code — so after the update, check each old-side
inventory entry against the tree and clean up the ones still present:

```bash
# -r: recurse — shipped subtrees hide renames from a top-level listing (e.g.
# the scripts/foreman/ tree that pre-v2 template revisions vendored)
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
same judgment call as any DRIFT.

A range that crosses the Foreman v2 flip is the canonical whole-subtree case:
every `scripts/foreman/*` entry shows as an old-side deletion. Do not
repoint anything at the vendored tree — remove it wholesale
(`git rm -rf --ignore-unmatch scripts/foreman`, per foreman's migration
guide — `-f` so locally modified survivors whose deltas were already
ported still stage, `--ignore-unmatch` so an already-clean tree exits 0)
under either
answer, then branch on the reviewed `use_foreman`:

- `true`: the in-repo successor is the packaged dependency the
  `taskfiles/foreman.yml` wrapper pins via
  `uvx --from git+https://github.com/ponderousdev/foreman@v{{.FOREMAN_VERSION}}`;
  prove it resolves — `task foreman:plan` must succeed with the vendored
  tree gone — and a `test ! -d scripts/foreman` guard in CI (extended to
  the other retired paths, per the migration section) keeps the subtree
  from silently returning.
- `false`: there is no successor — the render carries no wrapper, so
  `task foreman:plan` does not exist and must not be required. The check is
  the sweep itself: retired paths gone, `task --list` shows no `foreman:*`
  targets.

**The template-side diff cannot see hand-copied ancestors — sweep the
repo's own inventory too.** A helper the repo adopted by hand (e.g. copied
from harmon-init's root layer before the template shipped it) was never in
the `<old>` template tree, so its rename shows up only as the successor's
*addition* — nothing tells you the old file exists. The five harmon-infra
orphans were exactly this shape. So, for every script the inventory diff
ADDS, grep the repo for a predecessor under a different name; and list the
repo's template-extra scripts outright and judge each one (local keeper vs
orphan of a new successor).

Sweep against a **rendered** inventory, never the raw template tree. Much of
`template/scripts/` is jinja-wrapped (`[% if use_codeql %]…`), so a
raw `ls-tree` listing reports every gated file the repo legitimately owns as
"repo-extra" and buries the handful of real orphans. Render the target once
under the repo's own post-update answers and compare against that — the
gating is then already resolved, and no mental un-gating is needed:

```bash
RENDERED_ANSWERS="$(mktemp -t rendered-answers-XXXXXX.yml)"
RENDERED_TREE="$(mktemp -d -t rendered-inventory-XXXXXX)"
yq 'with_entries(select(.key | test("^_") | not))' .copier-answers.yml \
    >"$RENDERED_ANSWERS" &&
  run_guarded_copier copy --trust --defaults --skip-tasks \
    --vcs-ref="$HARMON_INIT_COMMIT" \
    --data-file="$RENDERED_ANSWERS" \
    "$HARMON_INIT_SOURCE" "$RENDERED_TREE" ||
  { echo "failed to render the target inventory" >&2; exit 1; }
LC_ALL=C comm -23 \
    <(git ls-files 'scripts/*' |
        while IFS= read -r SCRIPT_PATH; do
          if test -e "$SCRIPT_PATH" || test -L "$SCRIPT_PATH"; then
            printf '%s\n' "$SCRIPT_PATH"
          fi
        done |
        LC_ALL=C sort -u) \
    <(find "$RENDERED_TREE/scripts" \( -type f -o -type l \) -print |
        sed "s#^$RENDERED_TREE/##" | LC_ALL=C sort -u)
```

The repo side is filtered to paths that still exist on disk. `git ls-files`
reads the **index**, and §3 does not stage the update until later, so a file
Copier cleanly deleted for this update — a rename, or a feature answered off
— is still listed there. Those are not survivors, and this step is only
about survivors; leaving them in mixes Copier's intended deletions into the
orphan list and re-blunts exactly the precision this comparison buys.

Render through the **frozen** guarded source, not `~/git/harmon-init` at the
release tag. This sweep's output authorizes deletions, so a render that
drifts from what was actually applied can hide a stale script or condemn a
valid one; `$GUARDED_TEMPLATE` is immutable and `$HARMON_INIT_COMMIT` is a
full hash, so neither a source retag nor local checkout drift can move it.
The guarded template and Copier cache outlive the `$GUARDED_STATE` cleanup
in the promotion step above precisely so late audits like this one can still
use them — that is why §2 leaves them in place until the PR is verified.

Run this **after** the update, so the answers file already records the
target. Every remaining line is genuinely absent from the repo's own render:
either a deliberate repo-local keeper, or an orphan — of a renamed
successor, or of a feature whose answer is off. Judge each on that basis.

Real case (harmon-infra v4.0.0→v4.3.1): five orphans — `shell-quality.sh` (→
`format-shell.sh` + `lint-shell.sh`), `verify-required-results.sh` (→
`verify-ci-results.sh`), its truth-table test, and two CodeQL helpers — with
stale references in two workflows, the Taskfile, and `test-tasks.sh`.

**Answer flips do NOT show in the template-side diff — sweep them
explicitly.** A file gated on a copier answer (`[% if use_codeql %]…`)
exists in the raw template tree at *both* refs, so flipping the answer off
(e.g. `use_codeql=false`) produces an empty `<old>`↔`<new>` inventory diff
while still orphaning that feature's helpers. Copier deletes the
cleanly-tracked rendered copies on the flip, but hand-copied or
locally-modified ones survive. The rendered sweep above catches the
survivors under `scripts/` — it renders the flipped answer, so they show as
repo-extra — but nothing else: when an update turns a feature answer off,
separately `grep -rn` the repo for the disabled feature's workflow steps,
Taskfile targets, and doc claims, and remove them with the same
reference-repoint-then-delete discipline.

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
refreshes templated files, but renames/moves and GitHub-side settings it cannot
do. The GitHub-side half is not optional and not covered by any local gate: on a
`project_management: github` repo it is §6 below, applied after the PR merges.
Re-run `diff-template.sh`: every remaining `DRIFT` should be an intentional local
customization you can explain, not a missed update. In particular, a `DRIFT` on a
file the repo *renamed* (e.g. `.yaml`) may be an update copier skipped, not a
customization — confirm against the §2 renamed-files note before dismissing it.
**`(uncurated …)` findings get the identical treatment**: the tag is a statement
about the hand-maintained manifest, not a lower severity, so each one is still
either an explainable customization or a missed update, and the ones nobody has
ever looked at are exactly where a silently dropped template improvement hides.
`CO-OWNED` and `IGNORED` lines need no such adjudication — they are expected to
differ — but do check them for *absences*: a `CO-OWNED` path that stopped being
listed was clobbered (see the AGENTS.md note in §2 above).

**Cross-check that same re-run against the persisted non-adoption report** —
`git rev-parse --path-format=absolute --git-path
"guarded-update-nonadoption/$(git branch --show-current)"`, the branch-keyed
file §2 wrote. No new render is needed; the re-run above already produced the
`MISSING` set. Each class answers a different question:

**Confirm the reconciliation was recorded.** §2 already replayed every observed
row against the freshly applied tree, immediately after the apply and *before*
§3 touched anything. That ordering is the point: §3 legitimately restores files
the template deleted and removes twins the apply created, so a presence check
run here would flag prescribed reconciliation work as divergence and block the
hand-off over changes the guidance itself asked for. What §4 verifies is that
the frozen verdict exists and is clean:

```bash
nonadoption_verify_verdict() {
  VERIFY_BRANCH="$(git branch --show-current)"
  test -n "$VERIFY_BRANCH" ||
    { echo "detached HEAD: cannot locate this branch's reconciliation" >&2; return 1; }
  # Both paths resolved here, from the branch, in the one place that reads them.
  # §2 knows them as GUARDED_NONADOPT_FILE and GUARDED_VERDICT_FILE, and those
  # names are long out of scope by §4 — reaching for one of them is how this
  # check came to hash an unset variable.
  VERIFY_REPORT="$(
    git rev-parse --path-format=absolute \
      --git-path "guarded-update-nonadoption/$VERIFY_BRANCH"
  )" || { echo "failed to resolve the persisted non-adoption report" >&2; return 1; }
  VERIFY_VERDICT="$(
    git rev-parse --path-format=absolute \
      --git-path "guarded-update-reconciled/$VERIFY_BRANCH"
  )" || { echo "failed to resolve the frozen reconciliation" >&2; return 1; }
  # EXISTENCE, not size. A content-only update — every managed path already
  # present, only bytes changed — legitimately produces a zero-byte report, and
  # `test -s` turned that successful run into a blocked hand-off. Emptiness is
  # not evidence of an incomplete run: the hash and lineage binding below already
  # carry that. A report truncated or replaced after §2 fails the `report:` hash,
  # one from an earlier run fails it too or fails the lineage check, and §1 clears
  # both files on entry so a rerun cannot inherit either.
  test -f "$VERIFY_REPORT" ||
    { echo "no persisted non-adoption report for this branch; §2 did not complete — do not hand off" >&2; return 1; }
  test -s "$VERIFY_VERDICT" ||
    { echo "no frozen reconciliation for this branch; §2 did not complete — do not hand off" >&2; return 1; }
  grep -qx 'reconciled: clean' "$VERIFY_VERDICT" ||
    { echo "the frozen reconciliation is not clean:" >&2; cat "$VERIFY_VERDICT" >&2; return 1; }
  VERIFY_REPORT_OID="$(git hash-object "$VERIFY_REPORT")" ||
    { echo "failed to hash the persisted non-adoption report" >&2; return 1; }
  grep -qx "report: $VERIFY_REPORT_OID" "$VERIFY_VERDICT" ||
    { echo "the frozen verdict does not describe the persisted report; it is left over from an earlier run" >&2; return 1; }
  # The LIVE lineage, not the shell variable. `$HARMON_INIT_COMMIT` says which
  # update this session intended to run; `.copier-answers.yml` says which one the
  # tree actually carries. Those differ precisely when it matters — §3's manual
  # reconciliation or a `git restore` can put the pre-update answers file back,
  # leaving a tree at the old version beside a verdict describing the new one,
  # and comparing the verdict to the variable happily passed.
  VERIFY_LIVE_COMMIT="$(yq -r '._commit // ""' .copier-answers.yml)" ||
    { echo "failed to read _commit from .copier-answers.yml" >&2; return 1; }
  test -n "$VERIFY_LIVE_COMMIT" ||
    { echo "the applied answers file records no _commit; the update did not complete" >&2; return 1; }
  grep -qx "target-commit: $VERIFY_LIVE_COMMIT" "$VERIFY_VERDICT" ||
    { echo "the frozen verdict's target commit is not the lineage .copier-answers.yml now records; the tree was reset or reconciled back to another version" >&2; return 1; }
}
nonadoption_verify_verdict ||
  { echo "the reconciliation for this branch is missing, stale or unclean; do not hand off" >&2; exit 1; }
```

The binding matters more than the word. A verdict that says `clean` is making a
claim about a specific report produced by a specific run; on its own it is a
claim with no subject, and a rollback followed by a rerun that dies before
persisting leaves exactly that — a clean verdict beside a report describing a
tree nobody has any more. §1 clears both files for this branch when a new
guarded run starts, and these three lines make the pairing checkable even if
that ever fails.

Do not re-derive it by re-reading the worktree. The tree §4 sees has had §3
applied to it deliberately, and the only moment at which "what copier did" was
observable was the moment §2 finished.

What the recorded rows mean, once the verdict is clean:

- **`nonadopt-both`** — CONFIRMED silent non-adoption, on the strongest evidence
  available: a real copier apply of this exact update declined to create the
  file, and the freshly reset baseline means nothing will offer it again. These
  are the rows of §5's disposition table.
- **`created`, noted `new-in-target`** — the update added a file the repo did
  not have. Normal, and worth a glance: new surface the repo now owns.
- **`created`, noted `apply-artifact`** — the apply wrote a path NEITHER render
  ships: a `.rej` or `.orig` from a conflicted merge. That is a failed merge, not
  an adoption, so it belongs in the anomalies call-out above §5's table and must
  be resolved before hand-off — never listed as a file the repo gained.
- **`created`, noted `recreated`** — the apply wrote the file back over an
  absence the repo had chosen, because the template marks the path
  `_skip_if_exists` or the render's own `.gitignore` hides it from copier's
  deleted-path scan (copier-gotchas.md §9). **Read it.** It arrives with the
  target render's content, not whatever was there before someone removed it.

  `.github/CODEOWNERS` is the one to look at first. It encodes who must review
  and is auto-requested on every PR; the render writes `* @code_owner` from a
  single answer, which cannot express a second owner or a team. A repo that
  deliberately widened or narrowed its owners gets the single-owner version back
  — silently, unless you diff it here.
- **`deleted`** — the template dropped the file and the apply removed it. Check
  it was not carrying local content; §3's deletion reconciliation covers the
  ones that were.
- **`unknown-until-apply`** — the rehearsal was refused because the target
  declares `_migrations`, so §2's reconciliation resolved each of these against
  the real result rather than confirming a prediction. Read them as ordinary
  observations; they are simply later ones.
- **A `twin-exists:` note on any row** — the repo carries the `.yml`/`.yaml`
  counterpart. On a `created` row that means the repo now holds **both**; decide
  which survives before hand-off, because two configs for one tool is a silent
  precedence bug rather than a cosmetic duplicate.

Where §3 deliberately undoes something this report recorded — restoring a
`deleted` file, removing a `created` twin — say so in §5's *Disposition* column
(`restored in §3: <reason>`) rather than editing the row. The report is what the
apply did; the disposition is what you decided about it.

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
(`chore: update to harmon-init <version>`). Before publication, read the
rendered target `AGENTS.md`: open a draft PR and use the draft-workbench
lifecycle only when that authoritative policy defines ready-for-review as the
human handoff. If it still requires an ordinary PR or stopping at green, the
selected harmon-init release predates this lifecycle; select a compatible
release or follow the target policy and report the lifecycle upgrade as
blocked. Never bypass hooks; on a compatible target, shepherd the unchanged
draft through the complete readiness gate, promote it to ready for human
review, and then stop. Never merge to `main` directly.
Re-import the branch ruleset via the GitHub UI only if the ruleset JSON changed
(see [`post-generation-checklist.md`](./post-generation-checklist.md)).

The update has one more part on two kinds of repo, and it lands **after the PR
merges**: §6. It applies to any `project_management: github` repo, *and* to any
**org-owned** repo whatever its `project_management` answer — `setup:github-issue-types`
is rendered for every org repo, so a `linear`/`none` org repo still has live
issue types to reconcile. Say so in the PR description — it is the operator's cue
that the merge is not the end of the update.

**The PR body must carry a `## Silent non-adoption` section.** This is the whole
point of the classification in §1: the reviewer is the only party who can decide
whether a file the merge will never offer again should be adopted, and they can
only decide it if the PR tells them it exists. Read the persisted TSV
(`git rev-parse --path-format=absolute --git-path
"guarded-update-nonadoption/$(git branch --show-current)"`) and write the
section from the rows §4 confirmed:

```markdown
## Silent non-adoption

**Files the update created — review what landed.** `.github/CODEOWNERS` came
back (`created`, noted `recreated`): the template marks it `_skip_if_exists`, so
the apply rendered it fresh over an absence this repo had chosen. It now reads
`* @evanharmon1`; the team rule it replaced is gone. Decide before merge.

Files the template already shipped at this repo's baseline and this repo does
not have. `copier update` reads each absence as a deliberate deletion and will
never restore it — see copier-gotchas.md §9.

| Path | In template since | Renders under | Changed upstream in range | Why not adopted | Disposition |
| --- | --- | --- | --- | --- | --- |
| `scripts/lint-hygiene.sh` | baseline+target (≤ v3.12.0) | always | no | Deliberate: `Taskfile.yml` has no `lint:hygiene` target and nothing calls it. Nothing breaks without it. | decline — the repo lints hygiene through its own `lint:shell` |
| `scripts/status.sh` | baseline+target (≤ v3.4.0) | always | yes | unclear — needs your judgment; `Taskfile.yml` still has a `status` target that calls it, so the absence looks accidental | adopt — restore from the render and re-run `task verify` |
| `AGENTS.md` | baseline+target (≤ v3.0.0) | always | yes | Accidental: the repo has `CLAUDE.md` as a regular file, so the symlink alias was flattened and the real file never landed. | adopt — restore and re-point the aliases |
| `.envrc` | baseline+target (≤ v3.20.2) | always | no | note `repo-ignored-only`: this repo gitignores `.envrc`, but the template does not ship it ignored, so the exemption is this repo's habit rather than the template's declaration. | decline — the repo resolves env through `op run`; record it |
| `docs/runbooks/restore.md` | baseline+target (≤ v3.14.0) | always | no | note `co-owned-prose`: prose this repo owns — but it never had this page, and co-ownership explains why content differs, never why a file is absent. Nothing references it. | decline — restore is documented in this repo's own runbook index |

### Explained absences — same finding, evidence attached

One line each, never a bare count: these are `nonadopt-both` rows whose only
notes are routine, listed so the classification can be audited rather than
trusted.

- `.vscode/settings.json` — ignored-policy
- `terraform/main.tf` — known-false-verified (nested roots under `terraform/`)
- `.github/ISSUE_TEMPLATE/.gitkeep` — gitkeep

### Files the update created

Observed in the rehearsal and confirmed after the apply.

- `.github/CODEOWNERS` — `recreated`. Reappeared as `* @evanharmon1` over a
  deliberate removal; the render cannot express the team rule it replaced.
- `CHANGELOG.md` — `recreated`, empty; release-please owns it and refills it on
  the next release. No action.
- `.github/workflows/codeql.yml` — `new-in-target`. New surface this repo now
  owns; confirm the matrix matches its actual first-party source.
```

Column by column:

- **Path** — one row per **confirmed** `nonadopt-both`. Nothing else belongs in
  the table. An `apply-artifact` row is a conflicted-merge leftover: call it out
  with the anomalies, resolve it, and never let it reach the table.
  Other `created` rows get the separate list shown above — they are the
  inverse finding, a file arriving rather than staying away, and folding them
  into a table headed "files this repo does not have" would state the opposite
  of what happened. `deleted` rows belong to §3's reconciliation, not here.
- **In template since** — seed it from `baseline_membership`
  (`baseline+target` means at least as old as the repo's own baseline). Sharpen
  it with `git -C "$GUARDED_TEMPLATE" log --oneline --diff-filter=A -- <path>`
  when that is cheap; leave it "unclear" when it is not. A wrong date is worse
  than no date.
- **Renders under** — the answers and conditions that gate the file in
  `copier.yml` (`always`, or the condition), so the reviewer can see whether the
  repo's own answers even ask for it. "unclear" is allowed.
- **Changed upstream in range** — the TSV's `changed_in_range` flag verbatim.
  A `no` means the repo is declining something that has not moved since its
  baseline; a `yes` means it is also missing real upstream work. It compares
  content *and* the executable bit, so a template that only fixed a rendered
  script's mode across the range still reads `yes`.
- **The TSV's `note`, where it is not `-`** — fold it into *Why not adopted*
  rather than dropping it; it is the reason the path is a row instead of a
  collapsed count, and the reviewer cannot reconstruct it. `repo-ignored-only`:
  the repo ignores the path but the template never declared it local.
  `unverified-equivalent`: a drift-class-K path whose documented replacement is
  not in this repo. `package-json-unparseable`: the prettier-key probe could not
  read `package.json`, so it established nothing — check the file itself.
  `chezmoi-managed — verify per mode-audit class K`: the root `Brewfile` in a
  chezmoi source repo, where the skill's own guidance is split (see §1). Say
  which way you resolved it and why; that is the whole reason the row exists.
- **Why not adopted** — the one column only you can write, and the reason the
  table is worth the effort. Read the repo and say whether the absence looks
  **deliberate** or **accidental**, citing the evidence: a file that references
  the path, a task that depends on it, a replacement that does the same job, or
  the absence of any of those. State the consequence plainly, including when the
  consequence is "nothing breaks". **Uncertainty is permitted and expected** —
  write "unclear — needs your judgment" where you do not know. A confident wrong
  rationale is worse than none, because it is the sentence the reviewer will
  trust instead of looking.
- **Disposition** — `adopt` or `decline`, plus a one-line rationale. Both are
  legitimate outcomes; the point is that one of them was chosen on the record.

**Split the `nonadopt-both` rows by their notes, and by nothing else.** The
question a note has to answer is whether somebody already DECIDED this absence.
Exactly three answer it: `ignored-policy` (the template itself declares the path
local), `known-false-verified` (the documented replacement was found in this
repo), and `gitkeep` (a directory stub). A row goes to the explained-absences
list only when **every** note it carries is one of those three.

Everything else goes in the table — an empty note `-`, which is the most
important row in the report because nobody found any explanation at all, and
every note that describes a *state* rather than a decision:
`unverified-equivalent`, `repo-ignored-only`, `package-json-unparseable`,
`twin-exists:`, `co-owned-prose`, and the chezmoi Brewfile annotation.

**A directory where the render ships a file never reaches this report.** It used
to arrive as a `repo-path-is-directory` note, which was already obsolete when it
was written: copier asserts on that shape, so §1's rehearsal fails and the
guarded run stops before any report exists. The operator resolves the directory
and reruns — there is nothing here to disposition, and the diagnostic names the
scratch to inspect.

**`co-owned-prose` is on that second list, and it is the interesting one.** It
used to route a row away from the table, and it is the one note that says
nothing whatever about intent. Co-ownership is this report's own thesis
inverted: it explains why a file the repo HAS may differ from the template's
copy, and a file the repo does not have is not differing from anything. An
absent `docs/**.md` is a permanent non-adoption in exactly the way an absent
`AGENTS.md` is. The earlier split tabled the root files and collapsed the prose
on volume grounds — the issue's language about collapsing noise, applied to the
wrong population, because that language was about present-divergent files.
Present-divergent co-owned files never enter this report at all, so tabling the
absent ones costs nothing and closes the last route by which a permanent
non-adoption reached a reviewer without a Why or a Disposition beside it.

This is grouping, not filtering, and the difference is the whole point of the
report's shape. Earlier revisions collapsed these into counts like "4 co-owned",
and every round of review since found another transition the count was hiding —
because a count cannot be audited: nobody can tell whether the fourth item
belonged there. A line per path can be scanned in seconds and checked against
the repo in one command. The classifier no longer decides what the reviewer sees;
it records what it found, and this section decides how to lay it out.

`created` and `deleted` rows never reach the table: they describe what the apply
*did*, and §4 settles them. Only `nonadopt-both` is a question for a human —
which is the point, since it is the only class the tooling cannot resolve.

If the table is empty, say so outright: **"No unexplained silent
non-adoptions — every absence both renders ship carries a recorded
explanation."** Then keep the explained-absences list and any recreate list
underneath it, because they are precisely what "a recorded explanation" refers
to and the sentence is only true while they are visible. The older phrasing —
*every path present in both renders exists in the repo* — was simply false
whenever an explained row existed, which is nearly always: those paths are
absent, and claiming they exist is the one sentence here a reviewer would take
at face value. An omitted section is indistinguishable from a forgotten one; a
section that overstates is worse than either.

**Sweep BOTH trees for orphans before you delete anything.** §2 writes two
branch-keyed files — the report and its reconciliation verdict — so both are
listed and both are accounted for:

```bash
ls -R "$(git rev-parse --git-path guarded-update-nonadoption)"
ls -R "$(git rev-parse --git-path guarded-update-reconciled)"
```

Account for every file they hold, not just this branch's. Renaming a branch
(`git branch -m`) or deleting one strands its report under the old name, where
nothing will ever look for it again, and a rename mid-update is exactly when
that happens. Adopt an orphan into this PR if it belongs to this work; otherwise
leave it in place and **say in the PR body that it is there**, so the next
update does not mistake it for its own. Listing costs two commands; migration
logic would cost a mechanism that then needs its own correctness argument.

Then retire **this branch's two files together** — the same paths §2 wrote,
never the directories — once the section is in the PR body and you have re-read
the body to confirm the rows are actually in it:

```bash
HANDOFF_BRANCH="$(git branch --show-current)"
test -n "$HANDOFF_BRANCH" ||
  { echo "detached HEAD: refusing to guess which branch's files to retire" >&2; exit 1; }
HANDOFF_VERDICT="$(
  git rev-parse --path-format=absolute \
    --git-path "guarded-update-reconciled/$HANDOFF_BRANCH"
)" || { echo "failed to resolve the reconciliation verdict" >&2; exit 1; }
HANDOFF_REPORT="$(
  git rev-parse --path-format=absolute \
    --git-path "guarded-update-nonadoption/$HANDOFF_BRANCH"
)" || { echo "failed to resolve the non-adoption report" >&2; exit 1; }
# VERDICT FIRST, and stop dead if it will not go.
rm -f -- "$HANDOFF_VERDICT" ||
  { echo "failed to retire the reconciliation verdict; the report is untouched at $HANDOFF_REPORT — resolve this before removing anything by hand" >&2; exit 1; }
rm -f -- "$HANDOFF_REPORT" ||
  { echo "the verdict is retired but the report survives at $HANDOFF_REPORT; remove it before the next guarded run (§1 would clear it anyway)" >&2; exit 1; }
```

**The order is load-bearing.** The verdict goes first, and a failure there stops
the run before the report is touched. The invariant it buys: at every point where
this can fail, either both files still exist or the verdict is already gone —
never a clean verdict with no report beside it. That is the one combination that
lies, because a verdict asserts something about a report that would no longer be
there to check, and it is exactly the stale-verdict shape §1's entry clearing and
the hash binding exist to prevent. A surviving report with no verdict is the
harmless direction: §4 refuses on the missing verdict and §1 clears the leftover
on the next run.

Deleting the report and leaving the verdict is what the earlier revision did, and
it produced that forbidden state on every run rather than only on a failure. The
PR is the record from then on; the files are the sole durable copy until it is.
Removing the directories would take every other branch's with them, which is the
loss the branch key exists to prevent.

## 6. Reconcile live GitHub metadata (`project_management: github`) — post-merge

`copier update` rewrites **files**. It re-renders `scripts/setup-github-*.sh` and
their Taskfile targets with the template's current vocabulary — and then stops.
Nothing re-runs them. So a repo can pass §4 carrying a perfectly current
`setup-github-labels.sh` on disk while its **live** labels, project fields, and
org issue fields still hold whatever vocabulary the template had when the repo
was generated. Updating those files is not the same as applying them, and
neither `task verify` nor `verify-applied.sh` will notice — both read the
working tree, not GitHub. An update is not done until the live metadata matches
the files.

**Run this only once the update PR has merged.** Everything below mutates live,
shared, owner-wide state: `--force` overwrites a label's color and description,
and removing a field option that items are assigned to clears those values. An
update that is still in review, or that gets rejected or abandoned, must not have
already rewritten the org's vocabulary. The one thing that belongs in the PR is a
note that §6 is still outstanding.

**A `git revert` does not undo any of it.** The gate above protects a PR that
never merges; nothing protects one that merges and is reverted later. The setup
scripts are additive — they cannot restore a prior option set, a label's previous
color, or the old `ORG_PROJECT_ID`. So capture the before-state *first* and keep
it: run the verification commands at the end of 6c **before** 6b, and save their
output. On an org, add the variable's **access policy** — `setup-github-project.sh`
rewrites it with a hardcoded `--visibility all`, so an existing `private` or
`selected` scope is silently widened and the value alone will not restore it:

```bash
gh api "orgs/<org>/actions/variables/ORG_PROJECT_ID"                # value + visibility
gh api "orgs/<org>/actions/variables/ORG_PROJECT_ID/repositories"   # if 'selected'
```

That snapshot is the only rollback you will have, and undoing from it is manual —
re-set the variable *and its visibility*, restore label attributes, and re-add or
re-remove options by hand (re-mapping assignments before any removal).

This section applies only when the repo answers `project_management: github`:

```bash
grep '^project_management:' .copier-answers.yml   # 'github' → do this section; else skip
```

One exception to that gate: `setup:github-issue-types` is rendered for **any**
org-owned repo, independently of `project_management`. So an org repo answering
`linear`/`none` skips the rest of this section but still re-runs that one task.

`task setup:github` is **not** this. It applies repo *settings* (Dependabot
alerts, private vulnerability reporting, the bot collaborator) and touches none
of the project/label/field vocabulary — the metadata tasks are separate and must
be run by name.

### 6a. Confirm the targets first

These tasks mutate **live, shared** state — an owner-wide project, org-wide issue
fields, another repo's labels. The generated Taskfile hard-codes `github_org` and
`project_slug` from `.copier-answers.yml` into `--owner` / `--org` / `--repo`; it
does **not** infer them from the git remote. So on a repo that was renamed,
transferred, or forked since it was generated, these commands cheerfully target
the *old* owner or repo. Reconcile the answers before running anything:

```bash
grep -E '^(github_org|project_slug):' .copier-answers.yml
gh repo view --json nameWithOwner -q .nameWithOwner   # must agree with the above
```

A mismatch is a stop-and-fix, not a warning to run past. Fixing it means editing
the answers and re-rendering — which is itself an unmerged change, so it takes
its own PR. **Land that PR before returning to §6**; running the metadata tasks
off an uncommitted correction is the same "mutate from files that may still be
rejected" problem the post-merge gate exists to prevent.

**Confirm the board's identity too.** `setup-github-project.sh` resolves the
project by **title**, takes the *first* match, and **creates a new board** when
nothing matches — then (on an org) writes that board's id to `ORG_PROJECT_ID`.
So a board someone renamed, or an owner with two same-titled projects, turns a
routine re-run into "silently point all project automation at the wrong or a
brand-new empty board."

Query the set the script actually searches, with the script's own query — the raw
`projectsV2` connection, paginated, **closed boards included**. Do not substitute
`gh project list`: it defaults to 30 results and open projects only, and a board
hidden by either default is exactly the board that gets silently selected.

```bash
gh api graphql --paginate -F l='<owner>' -f query='
  query($l:String!,$endCursor:String){
    repositoryOwner(login:$l){ ... on ProjectV2Owner{
      projectsV2(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{id number title}}}}}' \
  --jq '.data.repositoryOwner.projectsV2.nodes[]
        | select(.title == "<owner> Project") | "\(.number)\t\(.id)"'
```

**A unique title is not proof of identity.** Exactly one match only tells you the
script will not pick arbitrarily — not that it will pick the *right* board. If
the board in real use was renamed and an obsolete or closed one kept the
canonical title, the count is still 1, and the script will select the obsolete
board and overwrite `ORG_PROJECT_ID` with its id. So compare ids, not counts.

**On an org with the variable already set**, that comparison is mechanical:

```bash
gh variable get ORG_PROJECT_ID --org <org>   # must equal the id from the query above
```

**Otherwise the check is the operator's eyes, and it is not optional.** A
personal account never has that variable (the script skips it — no user-level
variable scope), and so does an org templated before `ORG_PROJECT_ID` existed. A
missing variable is not a pass: open the matched board and confirm it is the one
actually in use — the items are there, the `Status` options are the pipeline you
recognize — before running anything:

```bash
gh project view <number> --owner <owner> --web   # <number> from the 6a query
```

Zero matches is ambiguous — it can mean drift *or* a legitimate first run. The
query above cannot tell you which: its `select(...)` filters out every other
title. List the owner's boards **unfiltered** before deciding:

```bash
gh api graphql --paginate -F l='<owner>' -f query='
  query($l:String!,$endCursor:String){
    repositoryOwner(login:$l){ ... on ProjectV2Owner{
      projectsV2(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{id number title closed}}}}}' \
  --jq '.data.repositoryOwner.projectsV2.nodes[] | "\(.number)\t\(.closed)\t\(.title)"'
```

Then judge what you see — presence of other boards is not itself drift:

- **A board that is plainly this owner's harmon-init board under another name**
  (the Status pipeline, the repo's items) → title drift. The script would create
  a fresh empty board and point automation at it. Resolve before running.
- **No matching board, and the other boards are unrelated** (or there are none)
  → valid first run. `project_management: github` was answered but
  `setup:github-project` was never run for this owner. Creation is the script's
  supported path; go ahead.

For the drift case, note that **re-pointing `ORG_PROJECT_ID` is not a fix**: the
script never *reads* that variable — it resolves by title and overwrites the
variable with whatever it picked, so a hand-set value is clobbered on the next
run. Two resolutions, both before the task runs:

1. Make the intended board the **unique title match** — rename the obsolete or
   duplicate board so the canonical title belongs to the board actually in use.
2. Or **skip `setup:github-project` entirely** for this repo and reconcile the
   board's fields by hand, leaving `ORG_PROJECT_ID` alone.

Never resolve it by letting the script choose.

**Do not run 6b across a fleet in parallel against the same owner.** Both field
scripts re-read immediately before writing, which narrows but does not close a
lost-update window: `updateProjectV2Field` and the issue-fields `PATCH` replace
the *entire* option array and accept no expected-version token, so a concurrent
write — another fleet run, or someone in the Project UI — can be silently
dropped, taking its option's assignments with it. Serialize per owner, and keep
the Project UI closed while it runs.

### 6b. Re-run the setup tasks

**Scopes are a maintainer prerequisite, not an agent step.** These tasks need
scopes an ordinary `gh` login does not carry, and `gh auth refresh -s` *widens a
credential's access* — which the Credential boundary in
[`SKILL.md`](../SKILL.md) puts off-limits to agents. So check read-only, and if a
scope is missing, **report the exact command and stop**; the maintainer runs it:

```bash
gh auth status   # read-only: does the token already carry 'project' / 'admin:org'?
```

Ask for the **minimum** the owner type actually needs — a personal-account repo
never needs `admin:org`, and requesting it anyway widens a credential for nothing:

| Missing scope | Maintainer runs | Needed by | When |
|---|---|---|---|
| `project` | `gh auth refresh -s project` | `setup:github-project` | always |
| `admin:org` | `gh auth refresh -s admin:org` | issue fields/types **and** `ORG_PROJECT_ID` | **org-owned repos only** |

On a personal account `setup:github-project` skips `ORG_PROJECT_ID` outright (no
user-level variable scope) and the issue-field/type tasks are never rendered, so
`project` alone is the whole prerequisite — a missing `admin:org` is not a
blocker there.

Whatever is needed must be in place **before** the first task. On an org,
`setup:github-project` tries to write the `ORG_PROJECT_ID` variable and only
*warns* when it lacks `admin:org` — it still exits 0, and nothing retries it, so
project automation quietly keeps a stale variable that can point at the wrong
board. If the project task already ran without the scope, re-run it once granted.

```bash
task setup:github-project      # board + Status pipeline + the Size number field; on a
                               # personal account also Priority/Product/Agent/Domain/Layer
task setup:github-labels       # this repo's five label families

# org-owned repos only (github_org != author_git_provider_username):
task setup:github-issue-fields # org Product/Agent/Domain/Layer issue fields
task setup:github-issue-types  # org Bug/Feature/Task/Research — rendered for any org
                               # repo, independently of project_management
```

`setup:github-project` resolves the board by title rather than by repo, so it can
be run from any of the owner's repos — and, for the same reason, needs the
identity check in 6a. `setup:github-labels` is **per-repo** — there is no
shared org label pool — so it needs running in *every* repo you update, not once
per owner. A task that isn't rendered means the repo's answers don't call for it;
skip it rather than hand-writing the equivalent.

One way these reruns *do* overwrite: `setup-github-labels.sh` is
`gh label create --force`, which rewrites a same-named label's color and
description. A deliberate local color or wording on a standard label name will be
reset to the template's — reconcile those first if the repo has any.

### 6c. What the reruns still leave for you

6b is **additive**. Both field scripts append whatever starter options an
existing single-select lacks — `Status` and the custom `Domain`/`Layer`/`Agent`
fields alike — and neither ever removes anything. That leaves four residues an
update can create, none of which any script closes:

- **Options the scripts skipped and warned about.** The scripts warn-and-continue
  (exit 0) rather than abort a half-reconciled project, so a clean-looking run can
  still have skipped a field: one that already exists with the **wrong data type**
  (GitHub cannot change a type in place, and **deleting a field destroys every
  issue's value for it org-wide** — so rename the old field, let the re-run
  create the correctly-typed replacement, migrate the values, and only then
  delete the original; never lead with the delete), one
  **at GitHub's single-select option cap**, or an issue-fields `PATCH` **rejected
  by the public preview**. Read the run's WARNING lines; each names the field and
  the options it did not add.
- **Repo-specific options.** The scripts ship only the starter *floor*
  (`auth`/`billing`/`platform`). This product's real domains, from your ERD
  entities, are still added by hand — org repos in the org's issue-field settings,
  personal accounts in the Project UI.
- **Retired labels.** `setup-github-labels.sh` never deletes, so a repo seeded
  before the layer family became `ui`/`logic`/`data`/`integration` ends up with
  the new four *alongside* orphaned `layer:frontend`, `layer:backend`, and
  `layer:infra`. Re-map those issues, then delete the three by hand.
- **Retired field options.** Same additive story on the `Domain`/`Layer`/`Agent`
  fields: an option the template dropped survives on the project (personal) or
  the org issue field. Remove it only after re-mapping — deleting an option that
  items are assigned to **clears those values**.

Check against the vocabulary in [`standards-catalog.md`](./standards-catalog.md)
§1.13. Query each field's **data type and full option list**, not just its name —
a names-only check passes on exactly the wrong-type and at-capacity fields the
warnings above describe:

```bash
# labels — --limit matters, the default returns only 30
gh label list --repo <owner>/<repo> --limit 1000

# project fields — BOTH owner types. setup:github-project syncs Status and the
# Size number field on an org board too, so an org run needs this snapshot as
# much as a personal one (personal accounts additionally carry
# Priority/Product/Agent/Domain/Layer here). Take <number> from the paginated
# identity query in 6a — `gh project list` would miss a closed board or one past
# its default 30.
gh project field-list <number> --owner <owner> -L 100 --format json

# orgs: issue fields + issue types are org-wide (needs admin:org). Take the
# X-GitHub-Api-Version pin from scripts/setup-github-issue-fields.sh rather than
# hardcoding it here — the preview version moves. Normalize the same two shapes
# that script does: a bare array, or a {"issue_fields":[...]} envelope (and
# --paginate concatenates one document per page either way).
gh api "orgs/<org>/issue-fields" -H "X-GitHub-Api-Version: <pin>" --paginate |
  jq -s '[ .[] | if type == "object" then (.issue_fields // []) else . end | .[] ]
         | map({name, data_type, options: [.options[]?.name]})'
# issue types: name alone is not enough — the script matches on name and leaves
# an existing type untouched, so a DISABLED or stale-metadata Bug/Feature/Task/
# Research passes a names-only check while being unusable.
gh api "orgs/<org>/issue-types" --paginate \
  --jq '.[] | {name, is_enabled, color, description}'
```

A type that comes back `is_enabled: false`, or with a color/description that does
not match, is drift the script will never correct — it matches by name and leaves
the existing type alone. There is no task for it: compare against the `desired`
list at the top of `scripts/setup-github-issue-types.sh` (the authority for the
expected color and description) and fix it in the org's issue-type settings by
hand. **[manual]**

Expect the two halves to **agree where they overlap, not to be equal**. On an org
the `Domain` issue field is the union across every repo, while a repo's `domain:`
labels are only the subset it actually uses — so a label with no matching field
option is drift, but a field option with no matching label in *this* repo is
normal. Do not prune org options to match one repo.

For the GitHub-side follow-ups that have no API at all — and so were never
scripted in the first place — walk the "Project management" section of
[`post-generation-checklist.md`](./post-generation-checklist.md) whenever the
update touched the corresponding template files.
