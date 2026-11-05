<!-- Update reference: github. Step numbers (§0–§6) refer to the runbook. -->

[Update runbook](./mode-update.md) · Read this reference when its step is reached;
keep the same shell and guarded state across steps.

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

The pre-draft additive step above creates missing names only. It does not
replace this post-merge `--force` reconciliation of existing label metadata;
run §6 unchanged even when every label name was already present before merge.

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
gh api "orgs/<org>/actions/variables/ORG_PROJECT_ID/repositories" --paginate # if 'selected'
```

For `selected` visibility, save **every page** emitted by `--paginate`, including
all repository IDs; the first page alone is not the complete access policy.
That full snapshot is the only rollback you will have, and undoing from it is manual —
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
the *old* owner or repo. The [§0 identity check](./mode-update-basics.md#0-branch-from-a-clean-tree)
already requires correcting these answers in the update PR before rendering.
Repeat the comparison now as a post-merge sanity check before running any
metadata task, in case the repository changed again:

```bash
grep -E '^(github_org|project_slug):' .copier-answers.yml
gh repo view --json nameWithOwner -q .nameWithOwner   # must agree with the above
```

A mismatch still stops all metadata writes. If identity changed after §0, fixing it means editing
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

**Rename any retired label family before this line reprovisions its
replacement — with `assets/migrate-label-family.sh`, not inline shell.**
This exact recipe earned a P1 finding three review rounds running while the
mechanism stayed prose here: a `gh api -f` call that silently flips GitHub's
default method to POST, a six-value inventory loop with no fail-fast on a
broken page, `--paginate --slurp` misread as a flat item array when it is
actually an array of *pages* (so a naive reader of it processes nothing and
a completion check built on it is vacuously "clean"). Every one of those is
a mechanical mistake a test catches immediately and prose cannot — the
script (`scripts/test-migrate-label-family.sh`) is where that test lives
now; this section keeps only why and when to run it.

**Why the ordering matters.** That task below is `gh label create --force`:
the first run **creates** `strategy:<value>` fresh, and GitHub label names
are unique (case-insensitively), so once that name exists a rename onto it
is rejected as a collision, leaving the repo with two disconnected labels —
an orphaned old one and an empty new one — instead of one renamed label.
`setup-github-labels.sh` itself never renames or removes anything (see
catalog §1.13's `.devflow.toml` entry), so the rename is entirely on you,
first.

**Why the multi-label check matters.** The retired `method` family had no
`exclusive` constraint — GitHub labels never enforce that — but
`[method].rank` gave every consumer a deterministic way to pick one value
when an issue carried several. `strategy` is exclusive and, per ADR 0006, a
conflict between its values has **no rank** — it is simply ambiguous. A
rename does not know this: an issue carrying two `method:*` labels ends up
with two `strategy:*` labels instead of the single winner the old rank
would have picked.

Run, once per value the repo actually has (the six shipped values are
`oneshot`/`plan`/`plan-approved`/`orchestrate`/`council`/`human-led`):

```bash
assets/migrate-label-family.sh inventory method --repo <owner>/<repo>
```

This refuses (exit 3) while any issue or PR carries more than one
`method:*` label, naming each one — resolve every conflict to the value
`[method].rank` would have picked (`human-led` > `plan-approved` > `council`
> `orchestrate` > `plan` > `oneshot`, most human oversight first — the fixed
order in the pre-#1047 `.devflow.toml`) and remove the rest by hand before
continuing. Once it reports clean, rename each value in place — this
preserves every label association, since a rename is not a
delete-and-recreate:

```bash
assets/migrate-label-family.sh rename method:<value> strategy:<value> \
  --repo <owner>/<repo> --execute
```

**If a prior run already provisioned `strategy:<value>` before this ran**,
`rename` refuses the collision by name and points here: transfer instead.
It adds `strategy:<value>` to every item carrying `method:<value>`, verifies
each addition individually (not just the write call's own exit code — a
verification catches a write that reports success but never actually
lands), and only then deletes `method:<value>`, aborting without deleting on
the first failure of either step:

```bash
assets/migrate-label-family.sh transfer method:<value> strategy:<value> \
  --repo <owner>/<repo> --execute
```

Confirm the migration is done — no live label still matches `method:*`:

```bash
assets/migrate-label-family.sh verify method --repo <owner>/<repo>
```

Historically, the same release (harmon-init#1047) expanded `rigor:*` from three levels
(`light`/`standard`/`deep`) to six (`trivial`/`minimal`/`light`/`standard`/
`thorough`/`deep`) — a new value set on the *same* prefix, not a rename, so
it had no name-collision hazard and needed no rename script; setup seeded
those values at that release. A later release replaced that historical
order with the current `rigor_order` (`cursory → light → standard → thorough → deep → forensic`);
see catalog §1.13. Use the selected release's current vocabulary.

```bash
task setup:github-project      # board + Status pipeline; personal accounts also Product
task setup:github-labels       # this repo's full label-registry.json-driven taxonomy

# org-owned repos only (github_org != author_git_provider_username):
task setup:github-issue-fields # org declared issue fields, including Product
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

6b is **additive**. Both field scripts append whatever starter options a
declared single-select lacks, including `Status`, and neither ever removes
anything. Domain/Layer values belong in `domain:`/`layer:` labels; agent routing
and claims also use labels. Never re-provision retired fields. That leaves four residues an
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
- **Repo-specific label vocabulary.** Add this product's real domains, from your
  ERD entities, to the selected template's repo label vocabulary and re-run
  `task setup:github-labels` in that repo. Do not add domain or layer field options.
- **Retired labels.** Plain `task setup:github-labels` never deletes. The operator
  runs the selected template's guarded `--prune` / `--migrate OLD=NEW` maintenance
  mode in a quiescent window, with TTY confirmation or explicit `--yes`, following
  `docs/project-management.md` **Migrating retired and renamed labels**, as for
  `suggest:*` / `tier:adaptive` below. Review issues carrying `rigor:trivial` or
  `rigor:minimal` against the selected release's `rigor_order`; never mechanically
  migrate these labels, because they have no one-to-one successor.
- **Retired fields.** Migrate only fields the selected release no longer creates:
  Domain/Layer from **v4.31.0** (harmon-init#875), Agent from **v4.23.0**
  (harmon-init#662), and Priority/Size from **v5.0.1** (harmon-init#1451).
  Retain fields still created by an older selected release. Old boards may carry
  Domain/Layer/Agent fields, `Size` (both owner types), and `Priority` (personal-account project field only;
  the organization's built-in Priority issue field stays). Setup no longer
  creates or reconciles them at those boundaries. Nothing reads their leftover values
  after retirement. Follow the selected template's `docs/project-management.md` **Fields → Migrating a board
  that still has one**, including its #910 enumeration rule and **Priority / Size** migration
  (harmon-init#1451). For Domain/Layer, provision replacement labels in every
  affected repository and migrate values to those labels. Re-point every saved
  view before an operator removes the fields. Org issue-field removal destroys
  values across the org; checking only this board is insufficient.

Validate classification provisioning against catalog §1.13: after
`task setup:github-labels`, require the six personal label families, `tier:*`,
and the `area:*` / `layer:*` / `domain:*` families with their `none` values
on every owner type; after `task setup:github-issue-fields` on organizations,
check Impact, Risk, Complexity, Priority (AI) and Effort with their full options
(Priority is built-in). For retired `suggest:*` and `tier:adaptive` labels,
follow the selected template's `docs/project-management.md` **Migration: what
the classification retired** and **Migrating retired and renamed labels**;
never provision them as routing. Pinning was a pre-merge step (§5); here only
verify that every wanted hand-set Tier carries `tier:pinned`, following
**The Tier: derivation and pin**.
Check both per-repository workflows,
`.github/workflows/classification-reconcile.yml` and
`.github/workflows/classification-event.yml`, plus
`scripts/classification-reconcile.mjs` and `task test:classification-reconcile`,
and their wiring against the selected release (catalog §1.13). The standalone
organization-wide walk is a separate **opt-in** in any private repository of
the organization (`<org>/.github` only when private), following harmon-init's
`docs/architecture/ci-cd.md` **Organization-wide walk**; it is not a public
`.github` caller and is not required unless the owner opted in.

A renamed label family (harmon-init#1047's `method:*` → `strategy:*`) is
**not** one of these residues — it is a precondition 6b assumes you already
handled, in 6b itself, before its `task setup:github-labels` line runs and
forecloses the rename by creating the destination name first. If that step
was skipped, see 6b above rather than continuing here.

Check against the vocabulary in [`standards-catalog.md`](./standards-catalog.md)
§1.13. Query each field's **data type and full option list**, not just its name —
a names-only check passes on exactly the wrong-type and at-capacity fields the
warnings above describe:

```bash
# labels — --limit matters, the default returns only 30
gh label list --repo <owner>/<repo> --limit 1000

# project fields — BOTH owner types. setup:github-project syncs Status; personal
# accounts additionally carry Product. Releases >= v5.0.1 (harmon-init#1451)
# create no Priority or Size project fields. Take <number> from the paginated
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

Validate the declared fields against the selected setup scripts, and the
repo's labels against its selected vocabulary. `domain:` and `layer:` labels
are the source of truth on both owner types; no corresponding field is expected
and there is no parallel option list to preserve or synchronize.

For the GitHub-side follow-ups that have no API at all — and so were never
scripted in the first place — walk the "Project management" section of
[`post-generation-checklist.md`](./post-generation-checklist.md) whenever the
update touched the corresponding template files.
