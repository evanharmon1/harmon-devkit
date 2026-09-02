Apply metadata: `apply-mode: issue-mapped`; `completion-source: issue-state`.

Each task maps to exactly one explicitly linked issue in the repository that
issue belongs to (Harmon DevKit for sections 1 through 5 and task 6.3, Harmon
Init for 6.1 and 6.2) and obtains its completion from that repository's issue
state. Open issues are pending and issues closed by their merge are complete. One apply run
selects one open issue for its own `/claim` → feature branch/worktree → repository
Dev Loop → ready-for-review PR lifecycle, then stops at handoff. A task PR never
edits this file's checkbox: reconcile checkboxes to issue state only in a change
landing on `main` after issue-closing merges, or during archival reconciliation.
Concurrent task PRs therefore share no task-state write. Foreman work remains a
dependency in its own sibling milestone and is not duplicated here. The two
Harmon Init issues this milestone sequences directly are listed in section 6:
they apply in the Harmon Init repository and complete by that repository's
issue state, never by a DevKit PR.

Execution order (2026-09-02 orchestration plan). A subwave starts only after
every task its lanes are declared `after` has merged to `main`; each subwave
holds at most three worktrees. Every task below is scheduled exactly once.

- Wave 1 (concurrent lanes, ordered merge): 2.1, 2.3, and 2.4 start
  together; 1.3 and then 1.1 start as lanes free. Recommended merge order
  is 1.3, 1.1, 2.1, 2.4, 2.3. Because 2.1 and 1.3 both extend the
  single-document schema harness, 2.3 validates challenger passes against
  2.1's schema, and 2.3 and 2.4 consume the validator 1.3 finishes, each of
  2.1, 2.3, and 2.4 merges the updated `main` (never a rebase: pushed
  history is not rewritten) once every task ahead of it in that order has
  merged, and re-runs its full suite (for 2.1, the complete schema suite)
  before it leaves draft; until then its PR body records the seam as an
  unsettled deferred finding. 1.2 follows 1.1 (maintainer ticks).
- Wave 2a (after wave 1): 2.2, 3.2, and 4.1.
- Wave 2b (after 2.2 and 3.2, since `/orchestrator` owns the integration
  transition and the anchor sequences the integrator before it): 3.1, and
  3.3 as an audit lane once 2.3 and 3.2 have merged (it adds any receipt
  case those two did not land and closes #685).
- Wave 3a (after wave 2): 6.1, 6.2, and 4.2.
- Wave 3b (after 6.1 and 6.2): 6.3, then 5.1 once 6.3 has merged.
  harmon-init#1080 (the pre-PR gate the anchor sequences before #604) is
  already closed, so it needs no lane. Migrating the other generated
  repositories is the Harmon Init copier sweep (design migration plan step
  7), not a DevKit task: each of those repositories needs the policy reader
  at its merge base first, and how Harmon Init distributes a repository-owned
  script (template file or an extended sync manifest) is harmon-init#1081's
  decision, recorded there by the orchestrator.

Lanes that share a file (Taskfile targets, schema README) merge through the
feature branch's single writer rather than editing concurrently.

## 1. Reconcile the contract and schema foundation

- [ ] 1.1 Complete [#666](https://github.com/evanharmon1/harmon-devkit/issues/666): fold the capped Codex findings and all 2026-08-31 config amendments into the anchor spec, lifecycle docs, glossary, and Harmon Init ADR reference; verify every issue criterion and `task check` pass.
- [ ] 1.2 Complete [#633](https://github.com/evanharmon1/harmon-devkit/issues/633): reconcile its older acceptance language to the updated anchor, confirm every milestone issue links to the spec, record the required human review, and verify all remaining criteria are satisfied before closure.
- [ ] 1.3 Complete [#686](https://github.com/evanharmon1/harmon-devkit/issues/686): implement the single-document schema and validator residue from PR #678, including clean-verdict, native-envelope, digest, path, and managed-set cases; verify `./scripts/test-result-schemas.sh` passes.

## 2. Establish registry, gates, computation, and rendering

- [ ] 2.1 Complete [#635](https://github.com/evanharmon1/harmon-devkit/issues/635): add registry roles, challenger/reviewer separation, finders, exact multi-model tier defaults, harness role support, write boundaries, execution-label provenance, and cross-file validation, and ship `ai/schemas/result.challenger.schema.json` with its fixture corpus so every registry role names an existing result schema (moved here from #638 because the exit script validates challenger passes); verify missing/duplicate-default, missing-schema, and interactive/unattended label-provenance cases plus `task validate:agents` and `task test:result-schemas` pass, then post the registry tier and default vocabulary on harmon-init#1081.
- [ ] 2.3 Complete [#636](https://github.com/evanharmon1/harmon-devkit/issues/636): ship the shared v2 policy reader (`scripts/devflow-policy.mjs`: shape detection, legacy/v1 refusal with migration messages, rigor/rounds/breadth/gates/convergence/role/stage resolution, and the merge-base rule) with its `devflow:policy` Taskfile target (resolve and detect modes, tested) and `scripts/dev-flow-exit.sh` (the retired `gauntlet-exit.sh` name is not used), implementing trajectory receipt, chronology and provenance/fingerprint verification, logical finder rounds, and deterministic `continue|converged|diverging|capped` computation from `[rounds]` and `[convergence]`, with the predicate catalog from `specs/dev-flow-v2.md` pinned by name; verify every outcome, invalidation boundary, shape-refusal, and omator replay fixture passes against fixture policies only (never this repository's live `.devflow.toml`), plus the legacy-to-v2 and v1-to-v2 merge-base decoder fixtures that mutate every protected value in the branch policy copy, in the branch reader's defaults, and in the branch `agent-registry.json` (roles, write boundaries, trusted actor IDs, tiers) and prove the resolved policy is unchanged, with the legacy shared `shepherd` budget preserved, then post the pinned predicate names and composition grammar on harmon-init#1081.
- [ ] 2.2 Complete [#632](https://github.com/evanharmon1/harmon-devkit/issues/632) after 2.3: move the round-push broker to the repository-owned path `scripts/round-push.sh` (so `git show <merge-base>:scripts/round-push.sh` can materialize it outside the worktree; for this relocation change alone the merge-base broker is the skill-asset copy it relocates, tested as such; the scanner closure is `scripts/gitleaks-scan.sh`, `.gitleaks.toml`, and `scripts/summarize-gitleaks.mjs`, invoked by explicit path from the extracted tree rather than through the worktree's `security:secrets` recipe), leave the existing gauntlet asset untouched and legacy-only (it keeps serving the still-shipped gauntlet procedure against this repository's legacy policy until 6.3, and is deleted with the skill in 5.1; the successor skills reference the new path, and no shim delegates one to the other), make it resolve bare gate targets and the sole docs allowlist through the policy reader, re-derive diff class, always scan secrets, and record branch-resident local gate results as branch-attested rather than CI-authoritative; verify docs-only, code, mixed-diff, and required-check-substitution refusal fixtures, a dependency-only closure fixture (a branch that changes only the policy reader, the scanner configuration, the scanner's summary helper, or the `security:secrets` Taskfile recipe still gates with the merge-base copies), and the relevant skill tests pass, with `scripts/test-gauntlet-push.sh` still green against the untouched asset.
- [ ] 2.4 Complete [#637](https://github.com/evanharmon1/harmon-devkit/issues/637): render deferred findings, adjudications, policy disclosure, round tables, blockers, and thread plans from one validated record with marked-section ownership and latest-read handoff; document GitHub's unconditional-write race, and verify golden outputs, post-write mismatch repair, bounded-retry blockers, concurrent human body edits, fresh-read re-merges, and interruption/idempotency fixtures pass.

## 3. Replace stage orchestration and prove trajectory invariants

- [ ] 3.1 Complete [#638](https://github.com/evanharmon1/harmon-devkit/issues/638) after 2.1, 2.3, 2.4, and 2.2: add challenger/reviewer agents, the `/review` stage skill, and `/orchestrator` standing mode with scoped dispatch, parallel-implementer bounds, single-writer lane assembly, reserve-first external actions, postcondition-reconciled persistent monitoring, and merge scheduling, consuming the challenger schema from 2.1, the policy reader and exit script from 2.3, the renderer from 2.4, and the broker from 2.2 by path (the skill references `scripts/round-push.sh` and does not edit or vendor it), and repointing `/implement`'s hand-offs from the retired `gauntlet` and `shepherd` names to `/review` and `/integrate` so the successor skills are reachable before the live policy migrates in 6.3; verify crash-after-write adoption, absent-action retry, indeterminate-postcondition refusal, skill/agent validation, and the fixture-driven stage dry run pass.
- [ ] 3.2 Complete [#639](https://github.com/evanharmon1/harmon-devkit/issues/639) after 2.1 and 2.3: add the scoped integrator agent and `/integrate` stage skill, resumable CI/Codex collection, JSON-only readiness evidence, remediation accounting, and session-owned promotion; verify fake-clock protocol and readiness-gate regression suites pass.
- [ ] 3.3 Complete [#685](https://github.com/evanharmon1/harmon-devkit/issues/685): add every de-scoped run-trajectory receipt case to the exit and readiness suites using `[rounds]` paths and stage-resolved challenger/reviewer contracts; verify missing finders, cap-zero skips, remediation loops, stale promotion, evidence markers, settlements, and chronology attacks—pre-run or pre-stage results, out-of-order transitions, earlier-stage pass reuse at the same head, and post-promotion results—all reject.

## 4. Make evidence measurable and retrospective

- [ ] 4.1 Complete [#663](https://github.com/evanharmon1/harmon-devkit/issues/663): implement read-only run harvesting, append-only digest-chained history, closed-cohort unattended-success metrics, per-run JSON/table output, immutable `--as-of` reconstruction, and convergence-policy replay; verify cutoff reconstruction, concurrent-writer replay stability (duplicate transition/intervention/outcome entries resolve by lowest committed ID, and a fixed cutoff reconstructs identically across repeated reads), evidence trust-root authentication (configured trusted-orchestrator actor IDs from `agent-registry.json`, or the trusted kickoff event — never an identity declared inside the record), edited/deleted-entry rejection, and omator/Foreman trajectory fixtures pass.
- [ ] 4.2 Complete [#664](https://github.com/evanharmon1/harmon-devkit/issues/664): make `/retro` consume per-run evidence when present, report fixed per-stage measurements, and carry run provenance into tracked improvements while retaining the no-record fallback; verify skill validation passes.

## 5. Ship v2-only successor skills

- [ ] 5.1 Complete [#604](https://github.com/evanharmon1/harmon-devkit/issues/604) after 3.1, 3.2, 6.1, 6.2, and 6.3: ship successor stage skills as v2-only from their first release, with no pre-v1 or v1 branches; keep unmigrated consumers on the existing skills-sync pin to the last pre-v2 skill release until their `.devflow.toml` migrates, then advance the pin; verify the consumer pin audit, older-shape refusal fixtures, and `task test:skills` pass. This repository's own `.devflow.toml` migrates only through the Harmon Init copier update, never by a DevKit task PR.

## 6. Sibling-repository lanes (Harmon Init) and the DevKit migration

Tasks 6.1 and 6.2 apply in `evanharmon1/harmon-init` and complete by that
repository's issue state; they are listed because the orchestrator sequences
them with the DevKit waves, not because a DevKit PR can close them. Task 6.3
is a DevKit lane like every task in sections 1 through 5.

- [ ] 6.1 Complete [harmon-init#1081](https://github.com/evanharmon1/harmon-init/issues/1081) after 2.1 and 2.3: render the `schema_version = 2` `.devflow.toml` template with `[rounds.*]`, `[breadth.*]`, `[gates]`, the composed `[convergence]` catalog pinned by 2.3, `[role.*]`, `[stage.*]`, and the `cursory`–`forensic` ladder, remove `[tier.*]`, and validate every slug against the registry shipped by 2.1; verify `scripts/test-devflow-config.sh` and the copier render pass.
- [ ] 6.2 Complete [harmon-init#1082](https://github.com/evanharmon1/harmon-init/issues/1082) after 3.1 and 3.2: shrink the AGENTS.md Dev Loop to policy invariants plus a pointer to `/implement`, `/review`, `/integrate`, and `/orchestrator`; verify the section is under 150 lines and `audit:agent-instructions` passes.
- [ ] 6.3 Complete [#711](https://github.com/evanharmon1/harmon-devkit/issues/711) after 6.1 and 6.2 (a DevKit PR applying the Harmon Init copier update to this repository only): migrate `.devflow.toml` to `schema_version = 2` and take the shrunk AGENTS.md together, with the reader from 2.3 already at the merge base; verify on the feature head, before handoff, that the `devflow:policy` target (task 2.3) in detect mode reports version 2, `task verify` passes, and no v2 consumer refuses the migrated policy; the same detection on `main` is post-merge reconciliation, not a handoff condition.
