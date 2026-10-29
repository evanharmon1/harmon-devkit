# Backlog grooming audit — 2026-10-29

This is an **AUDIT**, with no GitHub mutations. It covers all **620 open issues** in the final captured scan of `evanharmon1/harmon-devkit`. Recommendations are pending maintainer review; a closure candidate is not an issue closed by this run.

- [Searchable HTML report](report.html) — open locally in a browser; self-contained, with filtering and sorting.
- [Markdown report](report.md) — readable directly in the repository.
- [Disposition dataset](dispositions.json) — all verdicts, evidence, decisions, conformance findings, and grouping proposals.

| Disposition | Issues |
| --- | ---: |
| KEEP | 562 |
| CLOSE-done | 16 |
| CLOSE-obsolete | 3 |
| CLOSE-dup-of | 1 |
| NEEDS-DECISION | 30 |
| NEEDS-INFO | 8 |
| **Total** | **620** |

The two bot-owned dependency dashboards are included as KEEP and excluded from every proposed mutation. The report proposes five parent groupings, five milestone changes, and 24 design themes. These are separately selectable proposals, not a newly committed delivery schedule. Existing native parents and milestone assignments were preserved during consolidation.

## Evidence and coverage

The initial scan contained 619 issues. Eleven read-only cluster reviews inspected their full bodies and paginated comment histories against the default-branch snapshot [0ec6bc2e](https://github.com/evanharmon1/harmon-devkit/commit/0ec6bc2e7b381d59500792aebdfd641329bb1f35), the merged-PR index, and active PRs. Auditors used the registry's GPT frontier model, `gpt-6.1-sol`. Findings were reconciled centrally, including live parent/sub-issue reads.

A final refresh found two new issues and one closure. A twelfth, two-issue delta review covered both additions. The only intervening main-branch change was [PR 1727 — compare vendored asset bytes without external diff or textconv](https://github.com/evanharmon1/harmon-devkit/pull/1727), producing [6f0f3222](https://github.com/evanharmon1/harmon-devkit/commit/6f0f32228fe02689e45d87699899e75580f638db). Its code and test diff was checked against the affected verdicts. The now-closed [#1614 — Preserve canonical run identifiers and freshness byte comparisons](https://github.com/evanharmon1/harmon-devkit/issues/1614) was removed from the open-issue dataset; its closure was external to this audit.

Thus 621 distinct issue histories were reviewed, and the final dataset has exactly one verdict for each of the 620 issues still open at the captured refresh. Evidence file/line references generally name the initial immutable snapshot; the two delta reviews explicitly use the refreshed main commit. This is a dated audit, not a live readiness gate.

The pre-audit triage pass was read-only. It recorded classification gaps and dry-run priority proposals without applying labels. The new delta issues still require ordinary triage. No raw comment histories or credentials are included in this committed report.

## How to act on the report

Review closure candidates first, then answer the decision rows using their suggested response wording. Select any parent links, milestone additions, title corrections, and design work separately. For completed-close candidates with unchecked acceptance criteria, verify and tick the delivered criteria through track-work before closing. Human follow-ups require their named collector-transfer decision first.

Refresh each affected issue, PR merge state, and relationship before preparing an apply plan. The [groom skill](../../../ai/skills/universal/groom/SKILL.md) requires a maintainer pass before a separately supervised apply run. This audit contains no approved apply plan and performs no issue, label, milestone, relationship, or decision-comment writes. Run triage after approved changes.

The user selected a committed report on branch `audit/groom-2026-10-29` for this run. That choice is recorded here; the future default publishing policy remains a separate decision in the report.

## Report interpretation and validation

The skill's generated evidence chart uses textual heuristics: a numbered PR reference can appear as duplicate-link evidence. Use the exact disposition counts above and the verdict table for closure types. Automatic conformance rows may also mention bot dashboards; those rows do not authorize changes to bot-owned issues. These presentation limitations are recorded as a process finding, with the existing report-fidelity work as the follow-up path.

The full join rejects missing or duplicate verdicts, unknown issue numbers, invalid closure evidence, missing decision recommendations, and malformed conformance data. An initial conformance-format rejection was corrected by preserving the detailed recommendations and mapping only their write-path field to the required vocabulary; the full join was then rerun. No missing-coverage override was used. Separate checks verified bot exclusions, unticked HUMAN closure protection, and that the duplicate survivor remains open with a KEEP verdict.

All recommendations remain pending. Implementation, transfers of human checks, issue closures, title edits, milestone work, parent changes, and design documents have deliberately not been started.
