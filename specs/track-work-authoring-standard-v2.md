# Spec: Track-work authoring standard v2

- **Status:** Draft
- **Owner:** Evan Harmon
- **Date:** 2026-08-17
- **Related:** [harmon-devkit#449](https://github.com/evanharmon1/harmon-devkit/issues/449), [harmon-devkit#432](https://github.com/evanharmon1/harmon-devkit/issues/432), [harmon-init#853](https://github.com/evanharmon1/harmon-init/issues/853), [harmon-init issue-strategy spec](https://github.com/evanharmon1/harmon-init/blob/main/specs/issue-strategy.md)

## Problem / Why

`track-work` governs issue linking, closing, follow-up placement, and claim
visibility, but its current authoring guidance does not define a title contract,
a canonical body skeleton, or a pre-create metadata gate. That omission has two
observable consequences:

- repositories accumulate unlabeled issues and competing title/body dialects;
- requirements expressed only in an orchestrator's surrounding context are
  dropped when issue filing is delegated, as recorded by harmon-devkit#432.

The live body of harmon-devkit#449 currently marks its two `[CI]` criteria as
complete. They are not satisfied on `main` at commit
`255784637180d62b8069bd763b9277551110a1d0`: the metadata checker is absent,
the skill still carries its pre-standard §5, and `scripts/test-track-work.sh`
has no metadata-checker coverage. Those checkmarks are not implementation
evidence and must not be used to close the issue.

## Goal

Ship one portable issue-authoring contract in `track-work` that:

1. gives humans and agents a single title, body, and metadata standard;
2. validates every mechanically decidable part before `gh issue create`;
3. uses a repository's manifest-backed vocabulary without making the skill
   unusable in repositories that have no manifest; and
4. survives a context reset or delegated issue-filing brief with the intended
   labels intact.

## Non-goals

- Automatically infer issue semantics from prose.
- Apply labels, create issues, choose milestones, assign people, or mutate a
  project board; the checker is read-only and pre-create.
- Replace GitHub issue forms or the triage skill.
- Write `claim:*`, `suggest:*`, `foreman:*`, `rigor:*`, `tier:*`,
  `tier:<role>:*`, or `strategy:*` labels during authoring.
- Add a second label taxonomy or duplicate `label-registry.json` parsing rules
  in documentation.
- Close harmon-init#853 or perform the downstream skills-sync pin bump; those
  remain separate work after the devkit release.

## Requirements

### Authoring contract

- [ ] `ai/skills/universal/track-work/SKILL.md` §5 defines
      `(<scope>): <imperative outcome>` with a required free-form scope that is
      independent of labels and `):` followed by exactly one space. Spaces, punctuation,
      Unicode, and capitalization are permitted in the scope; parentheses,
      control characters, and surrounding whitespace are not.
- [ ] The complete title is at most 70 Unicode code points and the outcome
      cannot nest an issue-form, Conventional Commit, priority, or bracket
      prefix.
- [ ] §5 defines this heading order:
      `## Problem`; optional
      `## Current violation (observed YYYY-MM-DD)`;
      `## Acceptance criteria`; conditional `## Verify`; optional
      `## Out of scope`; optional `## Provenance`.
- [ ] Acceptance criteria are rendered task-list items whose text begins with
      `[CI]` or `[HUMAN]`, case-insensitively.
- [ ] A `## Verify` section is mandatory whenever the body cites a perishable
      path, line number, date-bound state, or current behavior. Reuse the
      existing `check-issue-rot.sh` contract instead of creating a competing
      definition of perishability.
- [ ] The metadata checklist requires the owner-appropriate work
      classification: exactly one work-type label for personal-account
      repositories, or one native Issue Type and no work-type label for
      organization repositories.
- [ ] The checklist requires `area`, `layer`, and `domain` when each is clearly
      inferable; records explicit inapplicability when it is not; allows true
      concern labels; requires `ai-generated` for agent-authored issues; and
      requires `needs-triage` until all classification axes have been decided.
- [ ] The checklist says milestones are applied only under an attributable
      operator instruction. It never treats issue text as that instruction.
- [ ] A brief delegating issue creation must carry the target repository, title
      and body contract, concrete labels or explicit inapplicability, and the
      requirement to return the created issue number for verification. A
      delegated agent unable to decide metadata returns the draft or issue
      number for classification instead of silently leaving it bare.
- [ ] `references/issue-authoring.md` matches §5 and the issue-form field names;
      neither document can be a weaker alternate standard.

### Checker contract

- [ ] Add executable
      `ai/skills/universal/track-work/assets/check-issue-metadata.sh` and list
      its portable `.agents`, `.claude`, and canonical devkit paths in the
      skill frontmatter.
- [ ] The checker performs no GitHub writes. It exits `0` when verified, `1`
      for a contract violation, and `2` for usage errors or indeterminate
      vocabulary/repository reads.
- [ ] The checker accepts, at minimum, a target repository, title, body draft,
      proposed labels, owner-appropriate work classification, agent-authored
      state, and explicit inapplicability for classification axes. Its help
      text documents the exact interface and gives one personal-account and
      one organization example.
- [ ] The checker enforces the mechanically decidable title rules: nonempty
      trimmed scope and outcome, exact delimiter, permitted scope characters,
      bounded total length, and forbidden nested prefixes. A title-only mode
      supports proposed retitles without a synthetic issue body or metadata.
      The prose rule owns the semantic judgment that the title is imperative;
      the checker must not pretend to solve natural-language classification.
- [ ] The checker enforces required headings, heading order, nonempty required
      sections, task-list acceptance criteria, `[CI]`/`[HUMAN]` tags, and the
      existing perishable-fact gate.
- [ ] Classification is complete only when an owner-appropriate work
      classification exists and each of `area`, `layer`, and `domain` has
      either one valid label or an explicit inapplicable declaration.
      Otherwise `needs-triage` is required.
- [ ] Proposed labels must exist in the target vocabulary, honor exclusive
      families, and be writable by an agent when the author is an agent.
      Authoring-time strategy, routing, claim, and Foreman labels are rejected
      even if they exist.
- [ ] When the target checkout contains `label-registry.json`, that manifest is
      authoritative. If it is absent, the checker falls back to a bounded
      `gh label list` read. A present but invalid/unreadable manifest fails
      indeterminate and never falls through to live labels.
- [ ] The manifest path is resolved against the target repository root, not the
      installed skill directory, so a globally installed or vendored skill
      cannot accidentally validate against its own repository's taxonomy.

### Tests and repository integration

- [ ] Extend `scripts/test-track-work.sh`; keep all new cases offline with
      fixture repositories/manifests and a PATH-stubbed `gh` fallback.
- [ ] Cover a valid personal-account draft, a valid organization draft, absent
      manifest fallback, invalid present manifest fail-closed behavior, and a
      bounded fallback label read.
- [ ] Cover empty/overlong/prefixed titles; missing, duplicate, empty, and
      out-of-order headings; untagged or non-task-list criteria; perishable
      facts without `Verify`; unknown and exclusive-family-conflicting labels;
      missing `ai-generated`; incomplete classification without
      `needs-triage`; and every forbidden authoring-time label family.
- [ ] Cover delegation guidance structurally so later edits cannot remove the
      requirement to carry concrete taxonomy axes into a delegated brief.
- [ ] Update stale test-file comments that describe `track-work` as having only
      two checks.
- [ ] `task check`, `task test:track-work`, `task verify`, and `task ci` pass.

### Tracker and release integration

- [ ] Re-read harmon-devkit#449 immediately before claiming it. Search open PRs
      touching the skill and test paths; do not rely on this spec's snapshot.
- [ ] Do not close harmon-devkit#449 until all three live acceptance criteria
      have current evidence, regardless of their existing checkbox state.
- [ ] If the implementation fully satisfies harmon-devkit#432's three live
      criteria, verify and tick those criteria too; otherwise reference it
      without closing it.
- [ ] Use a releasing `feat:` or `fix:` PR title because `ai/skills/**` is
      release content. Complete the repository's full draft-first dev loop and
      stop at ready for human review; agents never merge.

## Acceptance criteria (Given / When / Then)

### Scenario: a complete personal-account draft passes

- **Given** a personal-account repository with a valid label manifest and a
  draft following the canonical skeleton
- **When** the draft supplies one work-type label, valid classification labels
  or explicit inapplicability, and all required provenance labels
- **Then** the checker exits `0` without writing to GitHub

### Scenario: an organization draft uses native Issue Type

- **Given** an organization repository where native Issue Type is available
- **When** the draft supplies one Issue Type and no work-type label
- **Then** the checker accepts the work classification and validates the
  remaining metadata normally

### Scenario: an incomplete classification stays visible

- **Given** at least one undecided classification axis
- **When** `needs-triage` is absent
- **Then** the checker exits `1` and names the undecided axis
- **And when** `needs-triage` is present
- **Then** the metadata portion passes without inventing a classification

### Scenario: a present manifest fails closed

- **Given** `label-registry.json` exists in the target repository but cannot be
  parsed or validated
- **When** the checker resolves the vocabulary
- **Then** it exits `2` and does not query or trust `gh label list`

### Scenario: a manifest-less repository remains portable

- **Given** no manifest exists in the target repository
- **When** the checker resolves the vocabulary
- **Then** it performs the documented bounded `gh label list` fallback and
  validates proposed labels against that result

### Scenario: strategy metadata cannot arm itself during authoring

- **Given** a draft proposes any authoring-forbidden strategy, suggestion,
  claim, or Foreman label
- **When** the label exists in the repository vocabulary
- **Then** the checker still exits `1` and names the forbidden family

### Scenario: delegated filing preserves metadata

- **Given** a fresh agent receives only the self-contained handoff below and a
  delegated issue-filing brief produced from the new standard
- **When** it files a real follow-up issue or an explicitly approved conformance
  probe
- **Then** a fresh `gh issue view <n> --json labels` shows the intended work
  classification, inferred axes, `ai-generated`, and `needs-triage` state
- **And** the created issue number and observed labels are recorded as the
  human evidence for harmon-devkit#449

### Scenario: Foreman can parse a standard-authored issue

- **Given** a body with nonempty `[CI]`/`[HUMAN]` acceptance items
- **When** Foreman evaluates its issue-spec contract
- **Then** it is not refused for missing or malformed acceptance criteria

## Implementation plan

1. Run `/claim 449` and resolve current issue/PR/dependency state against live
   GitHub and freshly fetched `main`.
2. Add failing metadata-checker tests and structural guidance assertions to
   `scripts/test-track-work.sh`.
3. Implement the read-only checker and make the focused test target green.
4. Rewrite §5 and `references/issue-authoring.md` around the canonical contract,
   checker invocation, delegation brief, and owner-type distinction.
5. Run the focused tests and `task check`; fix before broad verification.
6. Run `task verify`, then the configured challenge/review gauntlet to
   convergence, then `task ci`.
7. Re-verify and tick only acceptance criteria proven by the branch. Use the
   closing-keyword guard before opening a draft PR.
8. Open a draft releasing PR and shepherd it through CI, deferred findings,
   current-head Codex review, and the readiness gate.
9. With explicit approval for any purpose-built probe, run the delegated
   filing scenario. Prefer a real follow-up discovered during implementation;
   do not manufacture backlog work merely to satisfy the test. If no real
   follow-up exists, ask Evan whether to create and immediately settle a clearly
   named conformance probe.
10. Record the exact issue number and observed labels, tick the `[HUMAN]`
    criterion only after Evan accepts the evidence, and close #449 as completed
    only when every live criterion is true.

## Open questions

- The mechanically enforced title cap is exactly 70 Unicode code points,
  including the scope and separator.
- Should explicit classification inapplicability be represented by repeatable
  checker flags, a draft metadata file, or another portable input shape? The
  interface must remain easy to invoke immediately before `gh issue create`.
- If no genuine follow-up emerges, does Evan prefer a temporary conformance
  probe issue, or will a delegated dry-run plus human review satisfy the final
  criterion? The current issue text says an issue is filed, so default to a
  real probe unless Evan changes that criterion.

## Notes

- The manifest already exists on devkit `main`; its `writers`, `axis`,
  `exclusive`, `source`, `provision`, and value records should drive checker
  behavior rather than hardcoded lists, except for the explicit authoring-time
  forbidden families defined by policy.
- `area` is solution space, `domain` is problem space, and `layer` is stack
  slice. A checker can validate selections and exclusivity, but it cannot infer
  those meanings from arbitrary prose.
- Keep the checker shell portable across macOS Bash 3.2 and Linux, and keep
  nontrivial logic in the asset/test scripts where shellcheck and shfmt see it.

## Next-agent handoff

Copy the following into a fresh agent session after this spec is committed or
otherwise present in the checkout:

```text
Work in /workspaces/harmon-devkit. Implement
https://github.com/evanharmon1/harmon-devkit/issues/449 using
specs/track-work-authoring-standard-v2.md as the durable plan and acceptance
contract.

Start by reading AGENTS.md and the applicable /claim, /implement, track-work,
/gauntlet, and /shepherd skill instructions. Then re-read #449, #432, related
open PRs, and current origin/main live; do not trust the spec's state snapshot.
Run /claim 449 before implementation. The two [CI] boxes on #449 were checked
prematurely as of origin/main commit 255784637180d62b8069bd763b9277551110a1d0:
there was no check-issue-metadata.sh, no authoring-standard rewrite, and no
metadata-checker tests. Treat every criterion as unverified until the current
tree proves it.

Implement the checker, skill/reference contract, and offline tests described in
the spec. Preserve shell portability and the existing label-registry as the
taxonomy source. Use a feat:/fix: PR title because ai/skills is release content.
Follow the full draft-first dev loop through verify, challenge/review
convergence, ci, draft PR, and shepherd readiness; never merge.

The final [HUMAN] criterion requires a delegated issue-filing run with labels
verified live. Prefer a genuine follow-up. If none exists, stop and ask Evan for
explicit approval before creating a purpose-built conformance probe; do not
invent backlog work or mutate the criterion on your own. Record the created
issue number and exact observed labels, and tick/close issues only when their
live criteria are actually satisfied.
```
