<!-- Update reference: execution. Step numbers (§0–§6) refer to the runbook. -->

[Update runbook](./mode-update.md) · Read this reference when its step is reached;
keep the same shell and guarded state across steps.

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
assets/confirm-answers.sh --check \
  --data-file "$REVIEWED_DATA" \
  --recorded "$GUARDED_STATE/original-answers.yml" \
  --template-commit "$HARMON_INIT_COMMIT" \
  --state-dir "$GUARDED_STATE" ||
  { echo "resolved answers were never confirmed; do not run Copier" >&2; exit 1; }
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
not retype or omit answers between those two steps. The `--check` above is
re-run immediately before the mutating call for the same reason the OID freeze
is re-verified: an answer edited between the rehearsal and the apply is an
unconfirmed answer, and the gate fails closed rather than trusting the earlier
approval. The `applying` phase is
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
