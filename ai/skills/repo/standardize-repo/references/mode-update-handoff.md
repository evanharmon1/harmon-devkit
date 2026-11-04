<!-- Update reference: handoff. Step numbers (§0–§6) refer to the runbook. -->

[Update runbook](./mode-update.md) · Read this reference when its step is reached;
keep the same shell and guarded state across steps.

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

**Pin wanted hand-set Tiers before merge.** This classification step cannot
wait for §6. When the update adds or enables
`.github/workflows/classification-reconcile.yml` and open issues carry a
hand-set `tier:<value>` label, the operator adds `tier:pinned` to each issue
whose Tier they want to keep **before the PR merges**. Create `tier:pinned` by
hand first if the repository lacks it. Keep exactly one `tier:<value>` rung on
each pinned issue. Merging enables the reconciler; it and any writer of Risk
and Complexity rewrite an unpinned issue's Tier when those axes are set. Follow the
selected template's `docs/project-management.md` **The Tier: derivation and
pin → Pin first on an existing repository**. Include this as a pre-merge item
in the PR description.

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
