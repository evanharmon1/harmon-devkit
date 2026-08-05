# Claim lifecycle: who writes what, and the parsed claim-record contract

The claim convention (`track-work` §6) makes an agent's work visible while it
happens: assignee, `agent:*` label, a card at `In Progress`, and a `Claiming —`
comment. This reference records the two things the SKILL.md prose cannot carry:
the **machine contract** for the claim record, and the **design decisions**
behind event-driven release (harmon-devkit#210).

## The invariant

A session writes only what only it knows. Every issue mutation GitHub can
derive from its own state is written by an event, not by a session. Two
consequences that hold independently of whether any session is running:

1. No closed issue carries a live claim marker — an `agent:*` label, a card at
   `In Progress`, or a `Claiming —` comment with no `Claim released —`
   successor.
2. A card's `Status` matches the delivery state GitHub already knows, rather
   than a snapshot some session took. (Deferred — see the decision below.)

## Stages and events

| Stage | Writes |
| --- | --- |
| `kickoff` | none — detects drift, never fixes it |
| `claim` | assignee, `agent:*` label, card `In Progress`, claim comment — nothing in GitHub knows an agent started before a PR exists, so this stays session-written |
| `implement` | ticks criteria as verified; files follow-ups |
| `shepherd` | review replies; releases the `agent:*` label at its terminal stop-at-green ("implementing right now" is false once the work is with a human); card advances (see decision below) |
| `retro` | none — distinguishes a claim *pending release* from one that outlived its session |
| `wrap` | releases what events did not; owns the abandoned/parked case |

| Event | Writes (`.github/workflows/claim-release.yml`) |
| --- | --- |
| `issues` closed, by any means | if a live, trusted claim remains: undo what the claim record says the claim added, post `Claim released —` |
| `pull_request` closed **unmerged** | same release, for each same-repo issue the PR would have closed (`closingIssuesReferences`) |
| `pull_request` closed merged | *no job* — the merge closes the linked issue and the `issues` path runs; a merged PR with no closing keyword releases nothing, by design (see gaps) |

Both event paths call `../assets/release-claim.sh`, which is also the manual
and backfill entry point. `GITHUB_TOKEN` with `issues: write` suffices — the
release invariant costs no new secret.

## The claim-record contract (v1)

`/claim` writes the claim comment; this file is the contract every parser
holds it to. `release-claim.sh` is the reference parser.

- The claim comment's body **starts with** `Claiming —` (em dash, U+2014).
- A release comment's body **starts with** `Claim released —` and its first
  line is, verbatim:
  `Claim released — <why>. (Supersedes the claim record above.)`
- A claim is **live** when no *later* comment starts with `Claim released —`.
  All readers (`kickoff`, `retro`, `implement`, the workflow) share this
  predicate; the latest `Claiming —` comment is the claim of record.
- The body carries a `Claim record` block whose fields are **one line each**,
  anchored on the literal `by this claim:` (the keys contain backticks and
  their own colons — parsers must never split on a colon):

  ```text
  Claim record (for `/wrap` — undo only what this claim added):
  - board: <board title, or "none">
  - prior board status: <status | "none" (unset) | "unknown" (unreadable)>
  - assignee added by this claim: <yes|no>
  - `agent:` label added by this claim: <agent:claude-code | no | n/a>
  - `agent:` label displaced by this claim: <agent:codex | none>
  ```

- The label fields name the **actual label** (`agent:…`). Legacy records wrote
  `yes`; the parser falls back to every live `agent:*` label on the issue.
- Values are untrusted data. Parsers validate before acting: labels against
  `agent:` + `[a-zA-Z0-9:._-]`, logins against GitHub's alphanumeric-and-hyphen
  shape — and never execute or interpolate them.
- **Trust gate, applied at selection**: a `Claiming —` comment counts only
  from the repo owner or a **current** assignee **whose per-comment
  `author_association` is `OWNER`, `MEMBER`, or `COLLABORATOR`** — assignment
  without write access must not steer a write-capable token. A
  `Claim released —` comment counts from those plus `github-actions[bot]`,
  because the workflow's own supersede comments are authored by it and a
  re-run that could not see them would release the same claim twice. Anyone
  can post either shape on a public repo; a forged claim must not shadow the
  real one, and a forged release must not suppress its cleanup. Untrusted
  comments are invisible to the parser (exit 3 when nothing trusted
  remains). v1 assumption: single-writer repos — App-authored claims would
  need this gate widened, and until then such claims strand as before.
- **The claim's first line is parsed too**: `Claiming — starting
  implementation on branch <branch> (session <name>).` On the unmerged-PR
  path the workflow passes the PR's head branch as `--branch`, and a claim
  naming a different branch exits 3 — replacement work claimed before an
  obsolete PR was closed is not that PR's to release. Keep the line's shape.
  The line is kept *true* by `/implement` §3: when the feature branch it
  creates differs from the branch the claim recorded (the normal case —
  `/claim` runs before the branch exists), it posts a refreshed
  `Claiming —` comment naming the real branch, which becomes the claim of
  record. A mismatch at PR-close therefore means the claim is genuinely not
  that PR's; worst case it releases when the issue closes (no `--branch`
  there).
- **An incomplete record fails closed**: `Claim record` present but any of
  the three `by this claim:` lines missing or valueless is unreadable
  provenance (exit 2), never a no-op — releasing around it would clear some
  markers and then block retries with the supersede comment.
- **An event releases only claims it covers**: the workflow passes the
  event's `closed_at` as `--not-after`, and a trusted claim created after it
  exits 3 — replacement work that reclaimed the issue is the next event's to
  release. The script also re-reads the comments immediately before writing
  and aborts if the claim of record changed in the window.
- A trusted claim whose record is present but unreadable **fails closed**
  (exit 2, loud in the Actions log). A trusted claim with **no** record at all
  releases by comment only and touches no marker — "undo only what the claim
  added" with no record means undo nothing.
- **Partial failure withholds the supersede comment everywhere** — `/wrap`
  interactively and the workflow alike. The comment is the release; posting
  it over a surviving marker tells every sweep the claim is settled, and a
  re-run would exit 3 instead of retrying. The workflow's exit 4 leaves the
  Actions job red and the remaining markers searchable, so a re-run (or the
  next close event) finishes the job.

Changing any of this is a contract change: update `/claim`'s template,
`release-claim.sh`, and this file in the same PR.

## Decision: event-driven `Status` writes — declined for now (2026-07-29)

The events table in #210 also sketched card moves (`Verifying` on PR open,
`In Review` on green checks, `Ready to Merge` on approval, `Done` on merge).
**Not shipped**, because:

- `GITHUB_TOKEN` cannot write user-owned Projects V2 fields — card automation
  needs a PAT or App secret (the "paid half"). The release invariant above
  needed no new secret, so they ship separately.
- harmon-devkit itself has `project_management: none` and its issues sit on no
  board — there is nothing here to automate, and shipping unexercisable
  automation invites rot.
- Sessions and events must never both write `Status` (the last-write-wins race
  `shepherd` §7 warns about). If card events ever land, the `Status` writes
  leave `/shepherd` and `/wrap` in the same change — do not ship one side.

Revisit when a Projects-scoped secret exists and a board is live. Until then
`/shepherd` and `/wrap` keep their session-written card moves.

## Accepted gaps

- A PR merged into a **non-default base branch** does not auto-close its
  issues, so no event fires; the claim releases whenever the issue eventually
  closes.
- A merged PR that only `Refs` an issue releases nothing — `/shepherd`
  deliberately parks such issues at `In Progress`, and the claim is still
  live.
- An unmerged **fork** PR's close releases nothing: `pull_request` runs from
  forks carry a read-only `GITHUB_TOKEN`, and `pull_request_target` is what
  this repo's security guidance tells workflows to gate against — so the
  same-repo gate stays and the claim strands until the issue closes or
  `/wrap` hands it back.
- The unmerged-close path deliberately has **no open-PR guards**: counting
  open references would let any unrelated PR that mentioned the issue —
  including a fork PR from an untrusted user — suppress the release forever.
  The `--branch` binding is the ownership test instead: only the claim
  naming the closed PR's head branch releases, and everything else exits 3
  untouched.
- For a claim authored by a **non-owner assignee** (the norm on organization
  repos, where the owner prong never matches a user), the assignment is also
  the trust anchor: the script removes it last, skips it when an earlier
  write failed, and **re-adds it if the supersede post then fails** — after
  first re-checking that no concurrent run released in the meantime, so the
  compensation cannot resurrect an assignee over a completed release. The
  residue is the compensation itself failing — two consecutive write
  failures — which strands a findable, assigned claim for `/kickoff` to
  surface.
- **Org-repo v1 limitation**: trust requires the claim author to be the repo
  owner or a *current* assignee (with write-shaped association). On an
  organization repo the owner prong never matches a user, so a maintainer
  unassigning or reassigning the claimant before the close event strands
  that claim (exit 3) until `/wrap` or a re-assignment. Widening trust to
  association alone would admit read-only collaborators' forged claims, so
  the narrow gate stays until an org actually consumes this workflow.
- The write window after the script's final pre-write re-read is **not**
  race-free: a reopen-and-reclaim landing inside those seconds can lose
  markers or be superseded by the in-flight release comment. GitHub offers
  no transaction over comments and issue edits; the re-read, `--not-after`
  (which fails safe on equal second-precision timestamps), and
  `--require-closed` bound the window, and the residue is accepted
  (`track-work` §6: a claim is a signal, not a lock).
- The workflow deliberately declares **no concurrency group**: a group holds
  only one pending run, so a burst of close events would silently cancel the
  middle one — a permanently dropped release. Overlapping runs converge
  instead: the script re-reads before writing, recognizes its own
  bot-authored supersede comments, and withholds the comment on partial
  failure, so the worst interleaving is a duplicate release comment.
- A claim whose only surviving markers are on the board (no comment, no
  label) is invisible to the release workflow — that discovery gap is
  harmon-devkit#183.
- Loop safety rests on two independent facts: comments posted with
  `GITHUB_TOKEN` never trigger workflow runs, and every `issue_comment`
  workflow in this repo gates on an allowlisted sender. A future workflow
  using a PAT/App token on `issue_comment` must keep such a gate.

## Backfill

Run once per stranded issue (a closed issue whose `Claiming —` comment has no
`Claim released —` successor):

```sh
ai/skills/universal/track-work/assets/release-claim.sh \
  --repo <owner/repo> --issue <n> \
  --reason "backfill (#210): closed before event-driven release existed"
```

The census query that finds them is in harmon-devkit#210's Verify block.
