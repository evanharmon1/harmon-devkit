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
# Check the skills pin against the verified target before any Copier run.
# A missing manifest is normal for first adoption or when skills sync is off.
if PIN_CHECK="$(assets/check-pin-minimum.sh \
  ~/git/harmon-init "$HARMON_INIT_COMMIT" .skills-sync.yaml)"; then
  PIN_STATUS=0
else
  PIN_STATUS=$?
fi
case "$PIN_STATUS" in
  0) echo "$PIN_CHECK" ;;
  1) echo "$PIN_CHECK" >&2
     echo "Set source.ref to the reported minimum, run task sync:skills in the same PR, and rerun this check before Copier." >&2
     exit 1 ;;
  2) PIN_REASON="${PIN_CHECK#*\"reason\":\"}"
     if [ "$PIN_REASON" = "$PIN_CHECK" ]; then PIN_REASON=unspecified; else
       PIN_REASON="${PIN_REASON%%\"*}"
       PIN_REASON="${PIN_REASON:-unspecified}"
     fi
     echo "skills pin compatibility unknown: $PIN_REASON" ;;
  *) echo "Skills pin minimum check failed (exit $PIN_STATUS); stop before Copier." >&2
     exit 1 ;;
esac
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
# integrate skill and its check-codex-cloud-review.sh reach the repo only via
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
# additionally requires the integrate skill's entry point and the helper's own
# structure, and it requires them from CODE rather than from prose.
#
# Anchoring on the usage strings (`reserve --state`, …) was the obvious version
# of that and is not enough: a no-op helper whose comments merely PRINT those
# five forms satisfies every one of them, and a waived config with such a stub
# is worse than no waiver — the integrator's `check` would read its exit 0 as clean
# evidence and the composition fails OPEN. So the verb probes anchor on the
# dispatch `case` arms in the helper's executable body, and are joined by two
# pairs from the exit-code contract the integrator actually depends on: `emit pending`
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
# `.name`, so a bare `name: integrate` sitting in a file's BODY would satisfy
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
# The asset probe set is check-codex-cloud-review.sh (the classifier's static
# interface) and require-marker.sh (its marker dependency). Together with the
# entry-point checks below, they identify the native source; they do not verify
# a complete vendor or the behavior of any asset. The classifier itself sources
# asset-freshness.sh and trusted-registry.sh; a vendor missing either cannot run
# it, even though this probe still identifies the source. Other prescribed assets are
# deliberately excluded because their presence is not needed for this identity
# test. Review this list whenever the procedures prescribe a new asset:
# BEGIN unprobed procedure assets
# dev-flow-support/assets/dev-flow-exit.mjs — stage exit calculation
# dev-flow-support/assets/dev-flow-exit.sh — stage exit wrapper
# dev-flow-support/assets/devflow-policy.mjs — policy resolution
# dev-flow-support/assets/lib/merge-base-policy.sh — merge-base policy loading
# dev-flow-support/assets/lib/toml-lite.mjs — policy parsing
# dev-flow-support/assets/render-dev-flow.mjs — run record rendering
# dev-flow-support/assets/render-dev-flow.sh — rendering wrapper
# dev-flow-support/assets/run-record.mjs — run record management
# dev-flow-support/assets/schemas/run.schema.json — run record schema
# dev-flow-support/assets/settle-wait.sh — settlement polling
# dev-flow-support/assets/validate-result-schemas.mjs — result validation
# implement/assets/record-implementer.sh — implementer record management
# integrate/assets/drive-codex-cycle.sh — owner-only cycle orchestration writes
# integrate/assets/gh-ro.sh — GitHub read operations
# integrate/assets/gh-write-broker.sh — GitHub write operations
# integrate/assets/promote.sh — promotion procedure
# integrate/assets/readiness-gate.sh — handoff evaluation
# integrate/assets/trusted-registry.sh — registry validation
# integrate/assets/update-branch.sh — branch catch-up
# orchestrate/assets/consumer-pin-audit.sh — consumer pin audit
# orchestrate/assets/settle-wait.sh — orchestrator settlement polling
# track-work/assets/clear-needs-review.sh — issue label cleanup
# track-work/assets/file-review-finding.sh — finding tracking
# END unprobed procedure assets
SKILLS_SOURCE_CLASSIFIER="ai/skills/universal/integrate/assets/check-codex-cloud-review.sh"
SKILLS_SOURCE_MARKER="ai/skills/universal/integrate/assets/require-marker.sh"
SKILLS_SOURCE_INTEGRATE_SKILL="ai/skills/universal/integrate/SKILL.md"
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
  case "$(git ls-files --stage -- "$SKILLS_SOURCE_INTEGRATE_SKILL" 2>/dev/null | cut -c1-6)" in
  100644 | 100755) return 0 ;;
  esac
  return 1
}
classifier_skill_frontmatter_ok() {
  awk '
    NR == 1 && $0 != "---" { exit }
    $0 == "---" { fence++ }
    END { exit (fence >= 2) ? 0 : 1 }
  ' "$SKILLS_SOURCE_INTEGRATE_SKILL" &&
    yq --front-matter=extract -e '
      ((.name | tag) == "!!str") and (.name == "integrate") and
      ((.description | tag) == "!!str") and (.description != "")
    ' "$SKILLS_SOURCE_INTEGRATE_SKILL" >/dev/null 2>&1
}
if [ -f "$SKILLS_SOURCE_MARKER" ] &&
  [ "$(git ls-files --stage -- "$SKILLS_SOURCE_MARKER" 2>/dev/null | cut -c1-6)" = "100755" ] &&
  [ -f "$SKILLS_SOURCE_CLASSIFIER" ] &&
  [ "$(git ls-files --stage -- "$SKILLS_SOURCE_CLASSIFIER" 2>/dev/null | cut -c1-6)" = "100755" ] &&
  git ls-files --error-unmatch -- "$SKILLS_SOURCE_INTEGRATE_SKILL" >/dev/null 2>&1 &&
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
# >>> guarded-render-variables >>>
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
  if [ "${USE_CODEQL+x}" != x ]; then
    yq -e 'has("use_codeql") and (.use_codeql | tag == "!!bool")' \
      .copier-answers.yml >/dev/null ||
      { echo "use_codeql must be a boolean in .copier-answers.yml" >&2; exit 1; }
    USE_CODEQL="$(yq -r '.use_codeql' .copier-answers.yml)"
  fi
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
# <<< guarded-render-variables <<<
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
  NONADOPT_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/copier-nonadoption-apply-XXXXXX")" ||
    { echo "failed to create the scratch apply directory" >&2; exit 1; }
  # macOS exposes the same temporary directory as both /var/folders/... and
  # /private/var/folders/.... Normalize before comparing the cloned git dir to
  # its scratch parent or the lexical containment check rejects a safe clone
  # (harmon-init#847).
  NONADOPT_SCRATCH="$(cd "$NONADOPT_SCRATCH" && pwd -P)" ||
    { echo "failed to normalize the scratch apply directory" >&2; exit 1; }
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
  # diff-template.sh's OWNED class is likewise absent, and needs even less
  # apology than the rest of `is_co_owned`. That class is derived from the
  # template's `_skip_if_exists`, which copier consults ONLY when the path
  # exists: a declared path the repo lacks is rendered fresh by the very next
  # update, so it is neither frozen nor declined and it gets an ordinary table
  # row. Nothing here needs to know the declaration exists.
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
  # those: a numbered or date-named `*-record-architecture-decisions.md`, or an
  # index.md/README.md-backed log holding at least one numbered or date-named ADR.
  # "Any ADR" is broader than the
  # documented evidence — `0002-use-postgres.md` says the repo writes ADRs, not
  # that it re-recorded the decision this seed records or keeps an indexed log,
  # and accepting it filtered the seed away on the strength of an unrelated file.
  nonadoption_has_adr_log() {
    NONADOPT_ADR_PRESENT=0
    for NONADOPT_ADR in docs/decisions/[0-9][0-9][0-9][0-9]-*.md; do
      test -f "$NONADOPT_ADR" || continue
      NONADOPT_ADR_PRESENT=1
      case "${NONADOPT_ADR##*/}" in
      *-record-architecture-decisions.md) return 0 ;;
      esac
    done
    test "$NONADOPT_ADR_PRESENT" -eq 1 || return 1
    test -f docs/decisions/index.md || test -f docs/decisions/README.md
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
    docs/decisions/[0-9]*-record-architecture-decisions.md)
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
  # The permission string a file STORES, read out of `ls -l` (POSIX-specified
  # first field: one type character then nine permission characters). Anything
  # else — a short field, an unreadable path — returns nonzero so the caller
  # reports `unknown` rather than inventing an answer, the same fail-closed
  # stance the rest of this recipe takes.
  nonadoption_stored_mode() {
    NONADOPT_MODE_FIELD="$(ls -ld -- "$1" 2>/dev/null |
      awk 'NR == 1 { print substr($1, 2, 9) }')" || return 1
    case "$NONADOPT_MODE_FIELD" in
    ?????????) printf '%s\n' "$NONADOPT_MODE_FIELD" ;;
    *) return 1 ;;
    esac
  }
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
    #
    # STORED bits, via `ls -l`, not `test -x`. `test -x` answers "may THIS
    # process execute this file HERE", which is a fact about the mount and the
    # caller, not about the render: under a `noexec` mount it is false for a
    # 100755 file, and on a filesystem with no permission bits of its own (FAT,
    # some network shares) it is true for everything. Either way a real
    # mode-only change across the range reads `no` and the disposition table
    # tells the reviewer nothing moved. The renders only ever carry git's own
    # 100644/100755, so comparing the whole permission string is the exec bit in
    # practice while staying honest about what it read.
    NONADOPT_BASE_MODE="$(nonadoption_stored_mode "$NONADOPT_BASE")" &&
      NONADOPT_TGT_MODE="$(nonadoption_stored_mode "$NONADOPT_TGT")" ||
      {
        printf '%s\n' unknown
        return 0
      }
    if test "$NONADOPT_BASE_MODE" != "$NONADOPT_TGT_MODE"; then
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
