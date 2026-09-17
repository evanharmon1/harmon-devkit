# Groom report — evanharmon1/harmon-devkit

_Generated: 2026-09-17 06:10 UTC_

## Stats

- Open issues: 423
- Close candidates: 3
- Decisions needed: 2
- High priority: 0
- Pre-audit triage pass: ran

## What to do next

1. Review 3 close candidate(s) below.
1. Answer 2 decision(s) below.
1. Review 2 spec-worthy theme proposal(s) below.
1. Review 2 process finding(s) below.
1. Resolve 3 conformance defect(s) below.

## Close now

| # | Title | Verdict | Priority | Group | Status | Reason / Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| #982 | Clean up deprecated docker compose v1 syntax in templates | CLOSE-done | P1 | templates | PENDING | Superseded and fully implemented in PR #985 (commit b4e3697). — _Evidence:_ PR #985 merged on 2026-09-12; compose templates use Compose v2 specification. |
| #941 | Duplicate taskfile entry for semgrep security scan | CLOSE-dup-of-#935 — (title unavailable) | P2 | ci | PENDING | Exact duplicate of taskfile audit issue #935. — _Evidence:_ See #935 filed on 2026-08-30 covering identical task definition overlap. |
| #884 | Add support for obsolete CentOS 7 devcontainers | CLOSE-not-planned | P3 | devcontainers | PENDING | CentOS 7 reached EOL June 2024. Harmon devkit only targets active LTS distros. — _Evidence:_ docs/architecture/adr-002-supported-platforms.md specifies Ubuntu 22.04+ and Debian 12+. |

## Milestones

- close v0.45.0 (health: open: 1, closed: 48, oldest open issue: #982 — Clean up deprecated docker compose v1 syntax in templates (110 days old)) (#982 — Clean up deprecated docker compose v1 syntax in templates) — All milestone deliverables merged; only release tag tagging remains.
- assign v0.46.0 (health: open: 14, closed: 2, no open issues) (#1012 — Deprecate legacy ruby serverlessFunctionTemplates, #1048 — Evaluate adopting OpenTofu for homelab IaC snippets) — Active cycle items scheduled for the next release.

## Parent issues

- #1066 — (groom): Follow-ups from the first supervised groom run: #1059 — (groom): Let the retitle op preserve the wording it removes instead of discarding it, #1061 — (title unavailable), #1062 — (title unavailable), #1063 — (title unavailable), #1064 — (title unavailable), #1065 — (title unavailable)

## Spec-worthy themes

### Serverless Template Modernization

- Recommended vehicle: openspec
- Reason: Unified overhaul of runtime versions across AWS Lambda and GCP Cloud Functions.
- Candidate issues:
  - #982 — Clean up deprecated docker compose v1 syntax in templates
  - #1012 — Deprecate legacy ruby serverlessFunctionTemplates
- How to respond: Agree to draft spec via openspec, or decline to keep as individual issues.

### Declarative IaC Alignment with OpenTofu

- Recommended vehicle: adr
- Reason: Harmonize homelab IaC templates with harmon-infra ecosystem standards.
- Candidate issues:
  - #1048 — Evaluate adopting OpenTofu for homelab IaC snippets
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

## Decisions

### Top five

- #1012 — Deprecate legacy ruby serverlessFunctionTemplates — Should we archive Ruby serverless templates or update them to Ruby 3.3 runtime?
  - Recommendation: Archive to snippets/historical/ and drop active CI validation for Ruby 2.7.
  - Why ranked in top five: High (P1) priority, blocks 3 downstream issue(s), 95 days old.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #1048 — Evaluate adopting OpenTofu for homelab IaC snippets — Migrate homelab Terraform boilerplates to OpenTofu 1.8+ or maintain dual compatibility?
  - Recommendation: Switch templates to OpenTofu by default with terraform alias compatibility.
  - Why ranked in top five: Medium (P2) priority, blocks 1 downstream issue(s), 45 days old.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

## Completed this run

None this run.

## Process findings

| Finding | Recommended action |
| --- | --- |
| 14 issues carry missing needs-triage labels after recent bulk creation | Run /triage to classify pending backlog items against taxonomy. (How to respond: reply "agree" to apply remediation, or "decline") |
| 3 stale PR branches remain on origin after squash merges | Prune origin remote branches for closed pull requests. (How to respond: reply "agree" to apply remediation, or "decline") |

## Conformance

### body

- #1012 — — Deprecate legacy ruby serverlessFunctionTemplates — Empty acceptance criteria section (proposed fix: a manual edit)

### labels

- #884 — — Add support for obsolete CentOS 7 devcontainers — missing work-type label (proposed fix: a triage apply)

### title

- #941 — — Duplicate taskfile entry for semgrep security scan — Title lacks component prefix (proposed fix: a retitle plan row)

## Bot-owned issues (excluded from retitle/close/relabel)

- #1004 — chore(deps): update postgres docker tag to v18.6

## Every issue

| # | Title | Verdict | Priority | Group | Status |
| --- | --- | --- | --- | --- | --- |
| #982 | Clean up deprecated docker compose v1 syntax in templates | CLOSE-done | P1 | templates | PENDING |
| #941 | Duplicate taskfile entry for semgrep security scan | CLOSE-dup-of-#935 | P2 | ci | PENDING |
| #884 | Add support for obsolete CentOS 7 devcontainers | CLOSE-not-planned | P3 | devcontainers | PENDING |
| #1059 | (groom): Let the retitle op preserve the wording it removes instead of discarding it | KEEP | P1 | skills | PENDING |
| #1012 | Deprecate legacy ruby serverlessFunctionTemplates | NEEDS-DECISION | P1 | templates | PENDING |
| #1048 | Evaluate adopting OpenTofu for homelab IaC snippets | NEEDS-DECISION | P2 | templates | PENDING |
| #1004 | chore(deps): update postgres docker tag to v18.6 | KEEP | P3 | dependencies | PENDING |
