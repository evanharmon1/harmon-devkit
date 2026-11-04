# Mode: Update

Update a repo already generated from harmon-init v3+ with `copier update`.
This runbook has a **250-line budget**, enforced by
`assets/test-mode-update-runbook.sh` through `task test:skills`.

Follow steps 0–6 in order. Read each linked procedure when reaching its step;
its commands, rules, rationale and recovery paths remain authoritative. Keep
one shell and the same guarded state across steps: these are parts of one
procedure, not independent recipes. Section numbers (§0–§6) in the references
refer to this runbook. Do not execute a later step before its prerequisites.

For v2 or never-templated repos, use [adopt-existing](./mode-adopt-existing.md).
For a read-only drift report, complete §1 and stop, or use
[audit mode](./mode-audit.md). For `project_management: github`, also run
§6a/§6c's read-only queries; a local drift report cannot see live metadata.
Complete the shared **Vendored skills** step in `SKILL.md` after updating;
vendored skills and agents belong in the same standardize PR.

## 0. Branch from a clean tree

Read [routing, shell conventions and branch setup](./mode-update-basics.md).
Check the skill's prerequisites, start from the current default branch with a
clean tree, and create a version-suffixed update branch.

**Gate:** [Clean tree and versioned branch](./mode-update-basics.md#0-branch-from-a-clean-tree).
**Stop:** If the tree is dirty or the branch already exists, resolve that state;
do not discard existing work to proceed.

## 1. Verify and freeze both template inputs

Read [input freezing and drift classification](./mode-update-preflight.md#1-verify-and-freeze-both-template-inputs).
Do not render, preview or apply before the guarded source and answers exist.
Freeze the canonical source, baseline and target commit; verify origin tags,
v3 ancestry and forward ancestry. A legacy tag baseline needs explicit approval
for the documented recovery, recorded in the PR.

### Preview the release and review new answers

Follow the [preview and confirmation procedure](./mode-update-preflight.md#preview-the-release-and-review-new-answers).
Check the verified target's minimum skills pin. Below-minimum and error stop;
unknown is reported with its reason and continues, never called compatible.
Review every active resolved answer, including standing sensitive answers;
only the human confirms. Workers present the table and return to the parent.
Freeze the guarded checkout, answers, reviewed data, ignored-file backups and
rollback state. Run the confirmation check before each trusted Copier run.
Keep the drift worklist and non-adoption classification for reconciliation.

**Gate:** [Immutable inputs, pin minimum, complete answer confirmation, guarded rehearsal and rollback](./mode-update-preflight.md#preview-the-release-and-review-new-answers).
**Stop:** Any failed input, ancestry, capability, guarded-state or confirmation
check stops before Copier. Never self-confirm or accept a mutable tag silently.

## 2. Run the update

Follow [the guarded apply and recovery procedure](./mode-update-execution.md#2-run-the-update)
using the full deliberately selected release, frozen commit and reviewed data.
Use `--defaults` non-interactively. Recheck all bindings immediately before apply;
account for trusted `_tasks`, migrations and `run_task_install` side effects.
Reconcile rehearsal observations against the real apply before other work,
persist the branch-keyed non-adoption report, resolve §3 conflicts before
promoting lineage, and prove the applied answers record the canonical target.
Audit renamed template files, removed scripts, hand-copied ancestors and answer
flips; a successful Copier exit alone does not prove these changes landed.

**Gate:** [Bound apply, observed-result reconciliation, persisted report and canonical lineage](./mode-update-execution.md#2-run-the-update).
**Stop:** Changed checkout, inputs, backups or confirmation invalidate the run.
Use only the documented guarded rollback/recovery with its required approval;
do not fabricate lineage or delete uncertain orphan files.

## 3. Reconcile conflicts (in place — no special files)

Follow [conflict, deletion and silent-clobber reconciliation](./mode-update-conflicts.md#3-reconcile-conflicts-in-place--no-special-files).
Keep both template improvements and repo customizations. Stage and review the
whole diff, justify every deletion, and inspect formerly divergent files even
when no marker appeared. Merge `AGENTS.md` section by section; compare vanished
`CO-OWNED`/`OWNED` entries against pre-update content before deciding what to restore.
Read the relevant per-file cases: forked tasks, absorbed features, docs, tightened
quality gates, release manifests, local skills, web dependencies and CI placement.

**Gate:** [Full staged diff, no conflict/render markers, preserved customizations and justified deletions](./mode-update-conflicts.md#3-reconcile-conflicts-in-place--no-special-files).
**Stop:** Uncertain deletions or quality-gate changes need the documented decision.
Credential or capability failures never justify weakening a workflow or guard.

## 4. Verify comprehensively

Follow [the complete verification procedure](./mode-update-verification.md#4-verify-comprehensively):
`task format`, `assets/diff-template.sh .`, `task verify`, then
`assets/verify-applied.sh .`. Review workflow semantics as well as syntax.
Walk audit-mode drift classes, compare the original worklist and persisted
non-adoption report, and verify every observed row and reconciliation marker.
Check hook installation/shadowing, IaC tracked state/vars, and web Lighthouse
requirements where applicable. Port older live-tool bootstrap tests before
parallel verification; until then run those repo gates serially.

**Gate:** [Formatting, drift and audit review, verify, verify-applied and reconciliation evidence](./mode-update-verification.md#4-verify-comprehensively).
**Stop:** A failed or unperformed applicable check is not green. Resolve drift
or record its justified disposition; preserve the observed report and verdict.

### Before the draft PR: provision missing labels additively

Follow [the additive label-provisioning gate](./mode-update-verification.md#before-the-draft-pr-provision-missing-labels-additively).
The parent creates only missing model labels from the updated target's registry,
after verification and before publication. A fleet uses one explicit release/run
approval and pinned decision ID; a single-repo parent gets explicit approval.
Capture the actual result and approval ID. A dry-run is not provisioning evidence.

**Gate:** [Approved parent-only additive provisioning](./mode-update-verification.md#before-the-draft-pr-provision-missing-labels-additively).
**Stop:** Missing, withheld or conflicting `label_provisioning`, invalid live
listing, failed renderer or create refusal blocks publication. No lane writes
labels; never substitute pre-merge `setup:github-labels --force` reconciliation.

## 5. Hand off

Follow [the target-policy handoff procedure](./mode-update-handoff.md#5-hand-off).
Commit conventionally with hooks intact. Read the rendered target's `AGENTS.md`:
use its lifecycle, selecting a compatible release or reporting the lifecycle
upgrade blocked if it predates the draft workbench. On compatible targets,
open a draft, complete its readiness gate and promote for human review; never merge.
Pin wanted hand-set Tiers **before merge**, with exactly one Tier rung on each
pinned issue, and include this pre-merge action in the PR description.
Include all post-merge §6 obligations; a merge is not the end of the update.

**Gate:** [Target-policy lifecycle, pre-merge Tier pins and complete PR disclosure](./mode-update-handoff.md#5-hand-off).
**Stop:** An incomplete readiness gate cannot authorize promotion. Unsettled
non-adoption or orphan dispositions cannot disappear from the handoff.

## Silent non-adoption

Use [the required PR section and disposition rules](./mode-update-handoff.md#5-hand-off).
List every persisted row, including explained absences and files created by the
apply. Evidence never removes a row; record reconciliation decisions as
Dispositions. Sweep both orphan lists, run the verdict first, and stop on failure
before cleanup. Do not infer safety from a bare count or delete by filename alone.

## 6. Reconcile live GitHub metadata (`project_management: github`) — post-merge

Follow [the live metadata procedure](./mode-update-github.md#6-reconcile-live-github-metadata-project_management-github--post-merge)
**only after the update PR merges**. It applies to `project_management: github`;
org-owned repos with other answers still owe `setup:github-issue-types`.
The pre-draft additive label step does not replace this reconciliation.

### 6a. Confirm the targets first

Read [target and board identity checks](./mode-update-github.md#6a-confirm-the-targets-first).
Snapshot the before-state, including org variable visibility and selected-repo
access policy, before any write: reverting files cannot undo live metadata.
Confirm the actual repository, owner and board identity; a unique title is not proof.
Serialize same-owner fleet reconciliation.

**Gate:** [Confirmed live targets and recoverable before-state](./mode-update-github.md#6a-confirm-the-targets-first).
**Stop:** Ambiguous identity, unavailable evidence or missing operator confirmation
blocks writes; report human-only prerequisites instead of widening credentials.

### 6b. Re-run the setup tasks

Read [the ordered metadata setup and label migration](./mode-update-github.md#6b-re-run-the-setup-tasks).
Check maintainer-provided scopes read-only. Inventory and migrate retired label
families before provisioning their replacements; stop on ambiguous multi-label
items. Run the selected setup tasks in their documented order and scope.

**Gate:** [Approved scopes, migration inventory and ordered setup reruns](./mode-update-github.md#6b-re-run-the-setup-tasks).
**Stop:** Missing scopes, ambiguous mappings or failed reruns require resolution;
never create credentials, choose a policy mapping or clear metadata blindly.

### 6c. What the reruns still leave for you

Read [residual cleanup and live verification](./mode-update-github.md#6c-what-the-reruns-still-leave-for-you).
Reconcile remaining fields, options, labels and issue types against the selected
scripts and vocabulary. Preserve assignments before removals; perform the listed
manual settings work through the operator. Run the final live queries and walk
the relevant post-generation checklist items. Local verify cannot prove this state.

**Gate:** [Live vocabulary checks and explicit residual/manual follow-ups](./mode-update-github.md#6c-what-the-reruns-still-leave-for-you).
**Stop:** Stale or disabled issue types, unresolved assignments or outstanding
manual work remain reported follow-ups; do not call the full update complete.
