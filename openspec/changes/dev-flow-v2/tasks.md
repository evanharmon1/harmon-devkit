Each checkbox maps to exactly one open issue in the Harmon DevKit Dev flow v2
milestone. Cross-repository config and Foreman work remain dependencies in their
own sibling milestones and are not duplicated as DevKit tasks here.

Each OpenSpec apply run selects exactly one unchecked task. That task's milestone
issue owns one `/claim` → feature branch/worktree → repository Dev Loop →
ready-for-review PR lifecycle. Stop and hand off after that PR; never batch
multiple task checkboxes or milestone issues into one apply run, branch, or PR.

## 1. Reconcile the contract and schema foundation

- [ ] 1.1 Complete [#666](https://github.com/evanharmon1/harmon-devkit/issues/666): fold the capped Codex findings and all 2026-08-31 config amendments into the anchor spec, lifecycle docs, glossary, and Harmon Init ADR reference; verify every issue criterion and `task check` pass.
- [ ] 1.2 Complete [#633](https://github.com/evanharmon1/harmon-devkit/issues/633): reconcile its older acceptance language to the updated anchor, confirm every milestone issue links to the spec, record the required human review, and verify all remaining criteria are satisfied before closure.
- [ ] 1.3 Complete [#686](https://github.com/evanharmon1/harmon-devkit/issues/686): implement the single-document schema and validator residue from PR #678, including clean-verdict, native-envelope, digest, path, and managed-set cases; verify `./scripts/test-result-schemas.sh` passes.

## 2. Establish registry, gates, computation, and rendering

- [ ] 2.1 Complete [#635](https://github.com/evanharmon1/harmon-devkit/issues/635): add registry roles, challenger/reviewer separation, finders, model tiers/defaults, harness role support, write boundaries, and cross-file validation; verify the registry mutation tests and `task validate:agents` pass.
- [ ] 2.2 Complete [#632](https://github.com/evanharmon1/harmon-devkit/issues/632): make the round-push broker resolve bare gate targets and the sole docs allowlist from v2 config, re-derive diff class, and always scan secrets; verify docs-only, code, and mixed-diff fixtures plus the relevant skill tests pass.
- [ ] 2.3 Complete [#636](https://github.com/evanharmon1/harmon-devkit/issues/636): implement trajectory receipt, provenance/fingerprint verification, logical finder rounds, and deterministic `continue|converged|diverging|capped` computation from `[rounds]` and `[convergence]`; verify every outcome, invalidation boundary, and omator replay fixture passes.
- [ ] 2.4 Complete [#637](https://github.com/evanharmon1/harmon-devkit/issues/637): render deferred findings, adjudications, policy disclosure, round tables, blockers, and thread plans from one validated record with transactional handoff; verify golden outputs are byte-stable and interruption/idempotency fixtures pass.

## 3. Replace stage orchestration and prove trajectory invariants

- [ ] 3.1 Complete [#638](https://github.com/evanharmon1/harmon-devkit/issues/638): add challenger/reviewer agents, the `/review` stage skill, and `/orchestrator` standing mode with scoped dispatch, parallel-implementer bounds, single-writer lane assembly, replay-safe persistent monitoring, and merge scheduling; verify skill/agent validation and the fixture-driven stage dry run pass.
- [ ] 3.2 Complete [#639](https://github.com/evanharmon1/harmon-devkit/issues/639): add the scoped integrator agent and `/integrate` stage skill, resumable CI/Codex collection, JSON-only readiness evidence, remediation accounting, and session-owned promotion; verify fake-clock protocol and readiness-gate regression suites pass.
- [ ] 3.3 Complete [#685](https://github.com/evanharmon1/harmon-devkit/issues/685): add every de-scoped run-trajectory receipt case to the exit and readiness suites using `[rounds]` paths and stage-resolved challenger/reviewer contracts; verify missing finders, cap-zero skips, remediation loops, stale promotion, evidence markers, chronology, and settlement tests all reject their attacks.

## 4. Make evidence measurable and retrospective

- [ ] 4.1 Complete [#663](https://github.com/evanharmon1/harmon-devkit/issues/663): implement read-only run harvesting, the closed-cohort unattended-success metrics, per-run JSON/table output, immutable `--as-of` scoring, and convergence-policy replay; verify omator and Foreman trajectory fixtures pass.
- [ ] 4.2 Complete [#664](https://github.com/evanharmon1/harmon-devkit/issues/664): make `/retro` consume per-run evidence when present, report fixed per-stage measurements, and carry run provenance into tracked improvements while retaining the no-record fallback; verify skill validation passes.

## 5. Remove transitional compatibility

- [ ] 5.1 Complete [#604](https://github.com/evanharmon1/harmon-devkit/issues/604): after every consumer is migrated, remove all pre-v1 and v1 policy branches from the successor stage skills and refuse each detected older shape with a specific migration hint; verify the consumer audit, refusal fixtures, and `task test:skills` pass.
