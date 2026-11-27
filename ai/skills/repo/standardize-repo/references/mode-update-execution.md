<!-- Update reference: execution. Step numbers (§0–§6) refer to the runbook. -->

[Update runbook](./mode-update.md) · Read this reference when its step is reached;
keep the same shell and guarded state across steps. The guarded steps here run as
`assets/guarded-update.sh` subcommands (`apply`, `reconcile`, `promote` and, for
recovery only, `rollback`), each reloading the frozen state itself. The audits
after the update, the orphan sweep included, use `run_guarded_copier` and the
frozen values. Source `assets/guarded-update.sh load` before `promote`, which
removes the guarded state the loader reads, and keep that shell for the audits.

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

`apply` first rechecks every frozen binding — the starting HEAD and checkout,
the canonical answers, the target commit, the guarded template and cache, the
reviewed data's object ID, the ignored-path backup and its object IDs, and a
clean worktree — and that no ignored managed path changed or appeared since
preparation. It refuses a state directory whose apply already started, then
runs the confirmation `--check` and the real trusted update (the template's
`_tasks` included). Approving this command at the prompt is approving that
trusted run (see the preflight's permission note):

```bash
assets/guarded-update.sh apply
```

The preview and the real invocation pass the same frozen reviewed-data file
and the same `--vcs-ref`; no answer is retyped or omitted between those two
steps. The `--check` is re-run immediately before the mutating call for the
same reason the OID freeze is re-verified: an answer edited between the
rehearsal and the apply is an unconfirmed answer, and the gate fails closed
rather than trusting the earlier approval. The `applying` phase is
atomically recorded before Copier can mutate the worktree. `applied` records a
normal return, but promotion does not trust either phase by itself: it validates
the complete resulting state below. After a crash or nonzero return, never
blindly rerun Copier.

**Reconcile the rehearsal against the real apply — now, before anything else
touches the tree.** This is the only moment the comparison is meaningful: §3 is
about to make deliberate changes the guidance prescribes, and every one of them
would read as divergence afterwards.

```bash
assets/guarded-update.sh reconcile
```

A non-zero return stops the run. Do not "note it and continue": the rehearsal
and the apply ran the same copier with the same ref and the same answers, so a
disagreement means the environment moved, and the report §5 is about to publish
describes a tree that does not exist.

**Persist the non-adoption report before anything tears `$GUARDED_STATE` down.**
Promotion below deletes that directory, and §4 and §5 both still need the TSV,
so `reconcile` copies the report and its verdict into the git directory, at
`guarded-update-nonadoption/<branch>` and `guarded-update-reconciled/<branch>`,
as soon as the verdict is written. It refuses to persist an unreconciled report.

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
theirs and hiding this one. The same `start-checkout` comparison `promote`
makes is therefore repeated here, at the last moment it can still matter,
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
commit. **Source the asset's loader in your own shell before running `promote`.**
`promote` removes the guarded state directory, so `load` cannot restore the
frozen values afterwards, and the audits below and §5's hand-off still need
`$HARMON_INIT_COMMIT`, `$GUARDED_TEMPLATE` and `run_guarded_copier`:

```bash
. assets/guarded-update.sh load
assets/guarded-update.sh promote
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
worktree changes made since preparation. The deterministic rollback takes two
runs. The first rechecks the binding, prints `git diff HEAD --stat`,
`git clean -nd`, the ignored-path backup listing and the absent-path list, and
refuses:

```bash
assets/guarded-update.sh rollback   # prints the four previews, then refuses
```

Approve only if the `git clean -nd` preview contains exclusively Copier-created
paths; the ignored guarded state survives `git clean -fd`. Once the maintainer
has approved after reviewing all four outputs, the operator runs it again with
`APPROVE_GUARDED_ROLLBACK=true` set for that one command; any other value
refuses. It restores `start-head`, runs `git clean -fd`, removes the ignored
paths Copier created and restores the pre-existing ones from the prepared tar
archive, then verifies the answers, the ignored paths and a clean status before
removing the guarded state. This rollback is destructive and must never
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
          case "$SCRIPT_PATH" in *.app/*) continue ;; esac
          if test -e "$SCRIPT_PATH" || test -L "$SCRIPT_PATH"; then
            printf '%s\n' "$SCRIPT_PATH"
          fi
        done |
        LC_ALL=C sort -u) \
    <(find "$RENDERED_TREE/scripts" \( -type f -o -type l \) -print |
        sed "s#^$RENDERED_TREE/##" | LC_ALL=C sort -u)
```

The repo side skips internals of opaque macOS `.app` bundles and is filtered to
paths that still exist on disk. `git ls-files`
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
