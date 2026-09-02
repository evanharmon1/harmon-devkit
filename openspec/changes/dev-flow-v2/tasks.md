Apply metadata: `apply-mode: issue-mapped`; `completion-source: issue-state`.

Each task maps to exactly one Harmon DevKit Dev flow v2 milestone issue. Open
issues are pending and issues closed by their merge are complete. One apply run
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
holds at most three worktrees. Wave 1: 2.1, 2.3, and 2.4 in parallel, then
1.3 and 1.1 as lanes free. Wave 2a (after wave 1): 2.2, 3.2, and 4.1.
Wave 2b (after 2.2): 3.1. Wave 3a (after wave 2): 6.1, 6.2, and 4.2.
Wave 3b (after 6.1): 5.1. Lanes that share a file (Taskfile targets, schema
README) merge through the feature branch's single writer rather than editing
concurrently.

## 1. Reconcile the contract and schema foundation

- [ ] 1.1 Complete [#666](https://github.com/evanharmon1/harmon-devkit/issues/666): fold the capped Codex findings and all 2026-08-31 config amendments into the anchor spec, lifecycle docs, glossary, and Harmon Init ADR reference; verify every issue criterion and `task check` pass.
- [ ] 1.2 Complete [#633](https://github.com/evanharmon1/harmon-devkit/issues/633): reconcile its older acceptance language to the updated anchor, confirm every milestone issue links to the spec, record the required human review, and verify all remaining criteria are satisfied before closure.
- [ ] 1.3 Complete [#686](https://github.com/evanharmon1/harmon-devkit/issues/686): implement the single-document schema and validator residue from PR #678, including clean-verdict, native-envelope, digest, path, and managed-set cases; verify `./scripts/test-result-schemas.sh` passes.

## 2. Establish registry, gates, computation, and rendering

- [ ] 2.1 Complete [#635](https://github.com/evanharmon1/harmon-devkit/issues/635): add registry roles, challenger/reviewer separation, finders, exact multi-model tier defaults, harness role support, write boundaries, execution-label provenance, and cross-file validation, and ship `ai/schemas/result.challenger.schema.json` with its fixture corpus so every registry role names an existing result schema (moved here from #638 because the exit script validates challenger passes); verify missing/duplicate-default, missing-schema, and interactive/unattended label-provenance cases plus `task validate:agents` and `task test:result-schemas` pass, then post the registry tier and default vocabulary on harmon-init#1081.
- [ ] 2.3 Complete [#636](https://github.com/evanharmon1/harmon-devkit/issues/636): ship the shared v2 policy reader (`scripts/devflow-policy.mjs`: shape detection, legacy/v1 refusal with migration messages, rigor/rounds/breadth/gates/convergence/role/stage resolution, and the merge-base rule) and `scripts/dev-flow-exit.sh` (the retired `gauntlet-exit.sh` name is not used), implementing trajectory receipt, chronology and provenance/fingerprint verification, logical finder rounds, and deterministic `continue|converged|diverging|capped` computation from `[rounds]` and `[convergence]`, with the predicate catalog from `specs/dev-flow-v2.md` pinned by name; verify every outcome, invalidation boundary, shape-refusal, and omator replay fixture passes against fixture policies only (never this repository's live `.devflow.toml`), then post the pinned predicate names and composition grammar on harmon-init#1081.
- [ ] 2.2 Complete [#632](https://github.com/evanharmon1/harmon-devkit/issues/632) after 2.3: move the round-push broker to the repository-owned path `scripts/round-push.sh` (so `git show <merge-base>:scripts/round-push.sh` can materialize it outside the worktree), make it resolve bare gate targets and the sole docs allowlist through the policy reader, re-derive diff class, always scan secrets, and record branch-resident local gate results as branch-attested rather than CI-authoritative; verify docs-only, code, mixed-diff, and required-check-substitution refusal fixtures plus the relevant skill tests pass, and the existing skill asset delegates to the new path.
- [ ] 2.4 Complete [#637](https://github.com/evanharmon1/harmon-devkit/issues/637): render deferred findings, adjudications, policy disclosure, round tables, blockers, and thread plans from one validated record with marked-section ownership and latest-read handoff; document GitHub's unconditional-write race, and verify golden outputs, post-write mismatch repair, bounded-retry blockers, concurrent human body edits, fresh-read re-merges, and interruption/idempotency fixtures pass.

## 3. Replace stage orchestration and prove trajectory invariants

- [ ] 3.1 Complete [#638](https://github.com/evanharmon1/harmon-devkit/issues/638) after 2.1, 2.3, 2.4, and 2.2: add challenger/reviewer agents, the `/review` stage skill, and `/orchestrator` standing mode with scoped dispatch, parallel-implementer bounds, single-writer lane assembly, reserve-first external actions, postcondition-reconciled persistent monitoring, and merge scheduling, consuming the challenger schema from 2.1, the policy reader and exit script from 2.3, the renderer from 2.4, and the broker from 2.2 by path (the skill references `scripts/round-push.sh` and does not edit or vendor it); verify crash-after-write adoption, absent-action retry, indeterminate-postcondition refusal, skill/agent validation, and the fixture-driven stage dry run pass.
- [ ] 3.2 Complete [#639](https://github.com/evanharmon1/harmon-devkit/issues/639) after 2.1 and 2.3: add the scoped integrator agent and `/integrate` stage skill, resumable CI/Codex collection, JSON-only readiness evidence, remediation accounting, and session-owned promotion; verify fake-clock protocol and readiness-gate regression suites pass.
- [ ] 3.3 Complete [#685](https://github.com/evanharmon1/harmon-devkit/issues/685): add every de-scoped run-trajectory receipt case to the exit and readiness suites using `[rounds]` paths and stage-resolved challenger/reviewer contracts; verify missing finders, cap-zero skips, remediation loops, stale promotion, evidence markers, settlements, and chronology attacks—pre-run or pre-stage results, out-of-order transitions, earlier-stage pass reuse at the same head, and post-promotion results—all reject.

## 4. Make evidence measurable and retrospective

- [ ] 4.1 Complete [#663](https://github.com/evanharmon1/harmon-devkit/issues/663): implement read-only run harvesting, append-only digest-chained history, closed-cohort unattended-success metrics, per-run JSON/table output, immutable `--as-of` reconstruction, and convergence-policy replay; verify cutoff reconstruction, edited/deleted-entry rejection, and omator/Foreman trajectory fixtures pass.
- [ ] 4.2 Complete [#664](https://github.com/evanharmon1/harmon-devkit/issues/664): make `/retro` consume per-run evidence when present, report fixed per-stage measurements, and carry run provenance into tracked improvements while retaining the no-record fallback; verify skill validation passes.

## 5. Ship v2-only successor skills

- [ ] 5.1 Complete [#604](https://github.com/evanharmon1/harmon-devkit/issues/604) after 3.1, 3.2, and 6.1: ship successor stage skills as v2-only from their first release, with no pre-v1 or v1 branches; keep unmigrated consumers on the existing skills-sync pin to the last pre-v2 skill release until their `.devflow.toml` migrates, then advance the pin; verify the consumer pin audit, older-shape refusal fixtures, and `task test:skills` pass. This repository's own `.devflow.toml` migrates only through the Harmon Init copier update, never by a DevKit task PR.

## 6. Sibling-repository lanes (Harmon Init)

These tasks apply in `evanharmon1/harmon-init` and complete by that
repository's issue state. They are listed because the orchestrator sequences
them with the DevKit waves, not because a DevKit PR can close them.

- [ ] 6.1 Complete [harmon-init#1081](https://github.com/evanharmon1/harmon-init/issues/1081) after 2.1 and 2.3: render the `schema_version = 2` `.devflow.toml` template with `[rounds.*]`, `[breadth.*]`, `[gates]`, the composed `[convergence]` catalog pinned by 2.3, `[role.*]`, `[stage.*]`, and the `cursory`–`forensic` ladder, remove `[tier.*]`, and validate every slug against the registry shipped by 2.1; verify `scripts/test-devflow-config.sh` and the copier render pass.
- [ ] 6.2 Complete [harmon-init#1082](https://github.com/evanharmon1/harmon-init/issues/1082) after 3.1 and 3.2: shrink the AGENTS.md Dev Loop to policy invariants plus a pointer to `/implement`, `/review`, `/integrate`, and `/orchestrator`; verify the section is under 150 lines and `audit:agent-instructions` passes.
