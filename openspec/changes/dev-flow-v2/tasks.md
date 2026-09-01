Apply metadata: `apply-mode: issue-mapped`; `completion-source: issue-state`.

Each task maps to exactly one Harmon DevKit Dev flow v2 milestone issue. Open
issues are pending and issues closed by their merge are complete. One apply run
selects one open issue for its own `/claim` → feature branch/worktree → repository
Dev Loop → ready-for-review PR lifecycle, then stops at handoff. A task PR never
edits this file's checkbox: reconcile checkboxes to issue state only in a change
landing on `main` after issue-closing merges, or during archival reconciliation.
Concurrent task PRs therefore share no task-state write. Cross-repository config
and Foreman work remain dependencies in their own sibling milestones and are not
duplicated as DevKit tasks here.

## 1. Reconcile the contract and schema foundation

- [ ] 1.1 Complete [#666](https://github.com/evanharmon1/harmon-devkit/issues/666): fold the capped Codex findings and all 2026-08-31 config amendments into the anchor spec, lifecycle docs, glossary, and Harmon Init ADR reference; verify every issue criterion and `task check` pass.
- [ ] 1.2 Complete [#633](https://github.com/evanharmon1/harmon-devkit/issues/633): reconcile its older acceptance language to the updated anchor, confirm every milestone issue links to the spec, record the required human review, and verify all remaining criteria are satisfied before closure.
- [ ] 1.3 Complete [#686](https://github.com/evanharmon1/harmon-devkit/issues/686): implement the single-document schema and validator residue from PR #678, including clean-verdict, native-envelope, digest, path, and managed-set cases; verify `./scripts/test-result-schemas.sh` passes.

## 2. Establish registry, gates, computation, and rendering

- [ ] 2.1 Complete [#635](https://github.com/evanharmon1/harmon-devkit/issues/635): add registry roles, challenger/reviewer separation, finders, exact multi-model tier defaults, harness role support, write boundaries, execution-label provenance, and cross-file validation; verify missing/duplicate-default and interactive/unattended label-provenance cases plus `task validate:agents` pass.
- [ ] 2.2 Complete [#632](https://github.com/evanharmon1/harmon-devkit/issues/632): make the round-push broker resolve bare gate targets and the sole docs allowlist from v2 config, re-derive diff class, always scan secrets, and record branch-resident local gate results as branch-attested rather than CI-authoritative; verify docs-only, code, mixed-diff, and required-check-substitution refusal fixtures plus the relevant skill tests pass.
- [ ] 2.3 Complete [#636](https://github.com/evanharmon1/harmon-devkit/issues/636): implement trajectory receipt, chronology and provenance/fingerprint verification, logical finder rounds, and deterministic `continue|converged|diverging|capped` computation from `[rounds]` and `[convergence]`; verify every outcome, invalidation boundary, and omator replay fixture passes.
- [ ] 2.4 Complete [#637](https://github.com/evanharmon1/harmon-devkit/issues/637): render deferred findings, adjudications, policy disclosure, round tables, blockers, and thread plans from one validated record with marked-section ownership and latest-read handoff; document GitHub's unconditional-write race, and verify golden outputs, post-write mismatch repair, bounded-retry blockers, concurrent human body edits, fresh-read re-merges, and interruption/idempotency fixtures pass.

## 3. Replace stage orchestration and prove trajectory invariants

- [ ] 3.1 Complete [#638](https://github.com/evanharmon1/harmon-devkit/issues/638): add challenger/reviewer agents, the `/review` stage skill, and `/orchestrator` standing mode with scoped dispatch, parallel-implementer bounds, single-writer lane assembly, reserve-first external actions, postcondition-reconciled persistent monitoring, and merge scheduling; verify crash-after-write adoption, absent-action retry, indeterminate-postcondition refusal, skill/agent validation, and the fixture-driven stage dry run pass.
- [ ] 3.2 Complete [#639](https://github.com/evanharmon1/harmon-devkit/issues/639): add the scoped integrator agent and `/integrate` stage skill, resumable CI/Codex collection, JSON-only readiness evidence, remediation accounting, and session-owned promotion; verify fake-clock protocol and readiness-gate regression suites pass.
- [ ] 3.3 Complete [#685](https://github.com/evanharmon1/harmon-devkit/issues/685): add every de-scoped run-trajectory receipt case to the exit and readiness suites using `[rounds]` paths and stage-resolved challenger/reviewer contracts; verify missing finders, cap-zero skips, remediation loops, stale promotion, evidence markers, settlements, and chronology attacks—pre-run or pre-stage results, out-of-order transitions, earlier-stage pass reuse at the same head, and post-promotion results—all reject.

## 4. Make evidence measurable and retrospective

- [ ] 4.1 Complete [#663](https://github.com/evanharmon1/harmon-devkit/issues/663): implement read-only run harvesting, append-only digest-chained history, closed-cohort unattended-success metrics, per-run JSON/table output, immutable `--as-of` reconstruction, and convergence-policy replay; verify cutoff reconstruction, edited/deleted-entry rejection, and omator/Foreman trajectory fixtures pass.
- [ ] 4.2 Complete [#664](https://github.com/evanharmon1/harmon-devkit/issues/664): make `/retro` consume per-run evidence when present, report fixed per-stage measurements, and carry run provenance into tracked improvements while retaining the no-record fallback; verify skill validation passes.

## 5. Remove transitional compatibility

- [ ] 5.1 Complete [#604](https://github.com/evanharmon1/harmon-devkit/issues/604): after every consumer is migrated, remove all pre-v1 and v1 policy branches from the successor stage skills and refuse each detected older shape with a specific migration hint; verify the consumer audit, refusal fixtures, and `task test:skills` pass.
