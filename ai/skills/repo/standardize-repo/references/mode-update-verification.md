<!-- Update reference: verification. Step numbers (§0–§6) refer to the runbook. -->

[Update runbook](./mode-update.md) · Read this reference when its step is reached;
keep the same shell and guarded state across steps.

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
`OWNED`, `CO-OWNED`, and `IGNORED` lines need no such adjudication — they are
expected to differ — but do check them for *absences*: a `CO-OWNED` or `OWNED`
path that stopped being listed is a prompt to diff that file against its
pre-update content, which is what distinguishes a real clobber from a template
seed that merely caught up with the repo's copy (see the AGENTS.md note in §2
above).

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

### Before the draft PR: provision missing labels additively

The implementer record needs the target release's `model-family:*`, `model:*`,
`model-version:*` and `model-effort:*` vocabulary before draft publication and
the readiness gate. The updated files alone do not create those live labels.
After §4 passes, have the **parent** run `assets/ensure-missing-labels.sh`
against the updated target checkout, before §5 publishes the draft. For a
single-repository session, that session is the parent and obtains explicit
maintainer approval first. This is the narrow pre-merge exception for creating
missing labels; existing metadata and all other §6 reconciliation stay post-merge.

For a fleet run, the parent obtains **one approval for the selected release and
run scope**, records `label_provisioning: approved` as a structured release
ruling in the decisions file, and verifies its provenance and pinned snapshot
as described in [fleet-decisions.md](./fleet-decisions.md). Read that key once
per run through `fleet-decisions.py --require-key label_provisioning`; reuse
the same approved decision ID for every selected repository. A lane never asks
again or writes labels: it reports the missing key or provisioning request to
the parent. A missing, conflicting or `withheld` answer stops this step naming
`label_provisioning`, without publishing a draft that lacks its model labels.
Do not interpret a key's existence as approval.

From the installed skill directory, the parent checks the pinned decision
snapshot (the first selected repository supplies the required lookup context):

```bash
LABEL_APPROVAL="$(python3 assets/fleet-decisions.py "$DECISIONS_SNAPSHOT" \
  --release "$TARGET_RELEASE" --repository "$FIRST_REPOSITORY" \
  --require-key label_provisioning)" || exit 1
if ! jq -e '.decisions | length == 1 and
  (.[0].ruling | fromjson | .key == "label_provisioning" and .answer == "approved")' \
  <<<"$LABEL_APPROVAL" >/dev/null; then
  echo 'Missing approval: label_provisioning' >&2
  exit 1
fi
```

Then, serialized by the parent, for each approved target checkout on its update
branch (use absolute paths when invoking the helper from elsewhere):

```bash
bash assets/ensure-missing-labels.sh --repo "$TARGET_REPOSITORY" \
  --checkout "$TARGET_CHECKOUT" --dry-run || exit 1
bash assets/ensure-missing-labels.sh --repo "$TARGET_REPOSITORY" \
  --checkout "$TARGET_CHECKOUT" || exit 1
```

The target checkout must already contain the selected release's rendered
`label-registry.json`, `agent-registry.json` and renderer dependencies. The helper
runs **that checkout's** `scripts/label-registry-render.mjs labels`; pass
`--foreman` and/or `--release-please` only when the target enables those profiles,
just as its `setup:github-labels` task does. It refuses a missing/failed renderer
or an invalid/potentially truncated live listing before any create. It creates
only missing names with `gh label create` **without `--force`** and never edits
or deletes existing labels. `--gh-bin FILE` injects the CLI for offline tests.

Capture the exit status and the single JSON result (`created`, `already_present`,
`would_create`, `refused`) in the lane report, with the approval ID (or direct
single-repo approval), target repository, release and update head. A dry-run
records prospective creates in `would_create` and writes nothing; it is not
provisioning evidence. A failed create can leave earlier creates live; preserve
the result, inspect live state and resolve the refusal before retrying. Never
fall back to `task setup:github-labels` before merge. This additive step does
not replace §6's post-merge `--force` reconciliation.
