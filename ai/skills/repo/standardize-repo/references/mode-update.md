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
SKILLS_SOURCE_CLASSIFIER="ai/skills/universal/shepherd/assets/check-codex-cloud-review.sh"
if [ -f "$SKILLS_SOURCE_CLASSIFIER" ] &&
  [ "$(git ls-files --stage -- "$SKILLS_SOURCE_CLASSIFIER" 2>/dev/null | cut -c1-6)" = "100755" ]; then
  SHIPS_CLASSIFIER_NATIVELY=true
else
  SHIPS_CLASSIFIER_NATIVELY=false
fi
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
