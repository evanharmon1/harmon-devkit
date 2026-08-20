# Claim lifecycle: who writes what, and the parsed claim-record contract

The claim convention (`track-work` §6) makes an agent's work visible while it
happens: assignee, `claim:*` label (the legacy `agent:*` family during the
rolling transition), and a `Claiming —` comment. Project status is a manual,
non-authoritative delivery view outside the claim contract. This reference
records the two things the SKILL.md prose cannot carry:
the **machine contract** for the claim record, and the **design decisions**
behind event-driven release (harmon-devkit#210).

## The invariant

A session writes only what only it knows. Every issue mutation GitHub can
derive from its own state is written by an event, not by a session. Two
consequences that hold independently of whether any session is running:

1. No closed issue carries a live claim marker — a `claim:*` (or legacy
   `agent:*`) label or a `Claiming —` comment with no `Claim released —`
   successor.
2. Project fields never authorize, commit, or release a claim.

## Stages and events

| Stage | Writes |
| --- | --- |
| `kickoff` | none — detects drift, never fixes it |
| `claim` | assignee, `claim:*` label, claim comment — nothing in GitHub knows an agent started before a PR exists, so these markers stay session-written |
| `implement` | ticks criteria as verified; files follow-ups |
| `shepherd` | review replies; releases the `claim:*` label at its terminal stop-at-green ("implementing right now" is false once the work is with a human) |
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

**Vocabulary transition.** The live-claim label is migrating from the
harness-named `agent:*` family to the model-centric `claim:<family>[:<model>]`
family (registry: the target's root `agent-registry.json`; e.g.
`claim:<family>` and `claim:<family>:<model>`). New claims **prefer `claim:*`, falling back to the legacy
`agent:*` label** on a repo whose label provisioning has not yet migrated (so a
currently-provisioned repo keeps its claim labeled rather than regressing to an
unlabeled one); the parser and every reader recognize **both** families until
the live-label migration completes downstream, so no in-flight `agent:*` claim
strands mid-transition. The harness that ran the work (Claude Code, the Action,
the Codex CLI), its model, and its session are recorded as operational metadata
in the claim record, never in the label.

- The claim comment's body **starts with** `Claiming —` (em dash, U+2014).
- A release comment's body **starts with** `Claim released —` and its first
  line is, verbatim:
  `Claim released — <why>. (Supersedes the claim record above.)`
- A claim is **current** when it is the latest trusted `Claiming —` comment
  after the latest trusted `Claim released —` comment. A newer trusted claim
  atomically supersedes every earlier claim record in that unreleased run: its
  successful append is the reader-visible transition, while a failed append
  leaves the predecessor current. Earlier comments remain audit history, never
  a second live claim. All readers (`kickoff`, `retro`, `implement`, and the
  workflow) use this one-current-record predicate.
- **The record append is the claim transaction's commit point.** The executable
  routine producer is `claim/assets/claim-transaction.sh`. It snapshots the
  issue and comments, adds only the authenticated assignee and resolved claim
  labels that were absent, and publishes the exact record. It rejects
  displacement plans. A verified `linear`/`none` repository uses its explicit
  label-less mode, which commits assignee-plus-record through the same helper;
  an unverifiable GitHub label-less exception still requires separate approval.
  Immediately before publication the routine producer re-reads the
  markers and trusted comment lineage; a newer trusted claim/release or marker
  drift stops the stale append and leaves the visible state for recovery. The
  transaction itself rejects a closed issue, an assignee not proven by the
  predecessor chain, and any ownership marker outside the exact approved plan;
  caller-side resolver checks are not authorization it inherits by assumption.
- **A failed comment response is not evidence of absence.** The producer
  re-reads all comments and searches for a new comment by the authenticated
  login with the exact submitted body. A confirmed match commits the claim. An
  exact match commits only when it remains the current claim on an OPEN issue
  with all required markers live. Every unreadable or absent reconciliation is
  indeterminate and leaves tentative markers visible so recovery can see them.
  The producer never removes a marker or assignee: no final read can authorize
  a later non-conditional delete safely when a same-identity claim may adopt
  the converged marker between those operations.
- **Project state is outside the claim contract.** `/claim` never reads or
  writes Project fields. Claim authority and the commit contract consist only
  of live assignee/label markers plus the durable record. An exact-current
  record is a no-write idempotence token only after the producer revalidates
  the OPEN issue and every required live marker.
- The body carries a `Claim record` block whose fields are **one line each**,
  anchored on the literal `by this claim:` (the keys contain backticks and
  their own colons — parsers must never split on a colon):

  ```text
  Claim record (for `/wrap` — undo only what this claim added):
  - harness: <the current execution harness, e.g. Claude Code or Codex CLI>
  - model: <the exact model identifier exposed by the harness, or "unknown">
  - family: <the trusted acting-family resolver output>
  - runtime environment: <host|devcontainer|coder|codespace|github-actions|unknown>
  - session: <the `/kickoff` session name, or "unknown">
  - assignee added by this claim: <yes|no>
  - `claim:` label added by this claim: <the exact family or legacy label applied | no | n/a>
  - `claim:` model label added by this claim: <the exact claim:<family>:<model> refinement applied | no | n/a>
  - `claim:` label displaced by this claim: <the exact competing family/model or legacy label | none>
  - assignee logins owned by this claim chain: <canonical comma-separated lowercase logins | none>
  - `claim:` label owned by this claim chain: <the exact still-present label | no | n/a>
  - `claim:` model label owned by this claim chain: <the exact still-present claim:<family>:<model> refinement | no | n/a>
  - `claim:` label displaced by this claim chain: <the exact displaced family/model or legacy label | none>
  ```

- `harness`, `model`, `family`, `runtime environment`, and `session` are
  optional, informational fields. New claims write all five; legacy records
  that omit any of them remain valid. `family` is copied from the trusted
  acting-family resolver output, never inferred from issue text or labels.
  `runtime environment` is one portable value (`host`, `devcontainer`,
  `coder`, `codespace`, `github-actions`, or `unknown`); it never contains a
  raw hostname or workspace identifier. A claim writes `unknown` instead of
  guessing when the exact model, runtime class, or `/kickoff` session is not
  available. Consumers may display these values to help a maintainer find,
  stop, or resume a worker, but must never use them to authorize, select, or
  construct a cleanup write. Values are untrusted and stay on one line.
  `session` is the human-readable `/kickoff` name, not a backend-internal
  identifier. The transaction receives the trusted family and portable runtime
  values separately and requires any corresponding record lines to match
  before writing; those checks authenticate what is recorded without making
  either value marker or cleanup authority.
- The label fields name the **actual label** (`claim:<family>` —
  the family segment names the model intelligence, not the harness). A new
  claim adds a `claim:*` label where the repo has the family and falls back to a
  a registry-declared legacy `agent:<harness>` alias where provisioning has not migrated (so a
  currently-provisioned repo keeps its claim labeled during the window); the
  fixed pre-registry aliases may coexist with a model refinement because the
  release reader can bind them without external state. Registry-only custom
  aliases remain family-level compatibility markers and must migrate to
  `claim:<family>` before a model refinement is claimed. The
  **displaced** field may likewise name a legacy `agent:*` label when the claim
  takes over a legacy in-flight claim, and pre-migration records name `agent:*`
  in the added field too — so consumers must accept **both** families here, not
  reject the record. The parser anchors
  on `label added by this claim:`, so the `` `claim:` `` prefix is cosmetic and
  legacy records written with `` `agent:` `` still parse. Records that wrote
  `yes` (older still) name no label; the parser falls back to every live
  `claim:*` **and** `agent:*` label on the issue.
- **Current ownership is explicit (v3).** New records carry a canonical,
  deduplicated assignee-login set: lowercase, sorted, comma-separated, and
  bounded at ten entries,
  plus the family/model/displaced `claim chain` fields. The producer derives the assignee set from
  exactly the immediate latest trusted predecessor's proven set plus the
  authenticated login when this attempt directly assigned it; absent
  predecessor members are dropped, and the result is lowercase and sorted.
  The record is validation input, never authority to invent another victim.
  This union preserves A→B→C ownership instead of replacing A with B and then
  B with C. A refresh or new-session takeover likewise copies a still-present
  label only when the immediate predecessor proves ownership. It writes
  `no`/`n/a` for a marker that predated the chain, disappeared, or was
  independently introduced.
  Its displaced label is different: it is normally absent while the takeover
  is live, so carry it when the predecessor proves it displaced the label.
  The current record is sufficient for release only after independent lineage proof. The
  releaser admits a historical record to that run only when its author was the
  repository owner or the issue timeline proves the author was assigned
  strictly before the consumed comment's current `updated_at` and remained
  assigned through that version (with write-shaped association in either
  case). An edit after unassignment or same-second assignment/version ordering
  is ambiguous and grants no cleanup authority.
  It then walks the trusted claim run oldest-to-newest and proves every
  inherited login appeared in the immediate predecessor's proven set (or is
  the leaf's direct assignee) before its first write. Missing, unreadable,
  ambiguous, edited, or forged provenance fails closed with zero writes. A
  proven release removes every still-present owned assignee while preserving
  unrelated assignees, and a failed supersede publication restores that same
  set. Immediately before destructive cleanup it also reads the complete issue
  timeline and requires every assignee, family label, and model label target to
  have remained uninterrupted since the current trusted leaf committed.
  Removal followed by an independent same-value re-add, or unreadable/malformed
  timeline evidence, fails closed with zero writes. This is intentionally an
  explicit transfer rather than a best-effort
  union of historical comments:
  GitHub's current marker state cannot distinguish a pre-existing label from a
  later independent re-add of the same text. When that provenance cannot be
  proven, record it as unowned and leave it in place. Family and model
  refinements coexist and carry separate direct/chain ownership: cleanup may
  remove both only when each target is proven through this lineage. The parser
  accepts v1 and v2 scalar records and the bounded whitespace-separated v3
  records emitted during the dependency branch's transition, but every new or
  refreshed producer writes only the stronger comma-canonical form. It rejects
  partial ownership groups, contradictory scalar/set companions, and forged
  family, model, or assignee targets before its first write.
- The chain-owned displaced label is provenance too. A manually approved
  exceptional record initializes it from that attempt's direct displacement;
  a routine refresh may only copy the immediate predecessor's proven chain
  value (falling back to its direct field for a legacy predecessor). The
  producer rejects any other value before marker writes. The releaser repeats
  that proof across the complete trusted lineage before restoring the target,
  so an edited or forged leaf cannot manufacture a label restoration.
- A trusted legacy claim with no record is an ownership boundary. A later
  structured refresh remains releasable, but its proof starts after the last
  recordless predecessor: nothing before that boundary can become an inherited
  cleanup target.
- A legacy direct label value of `yes` authorizes only that legacy record's
  live-label sweep. A later structured refresh may preserve exact assignee
  provenance across it, but cannot turn the unnamed label into an inherited
  exact cleanup target.
- Values are untrusted data. Parsers validate fields that can steer an action
  before acting: labels against
  the `agent:`/`claim:` prefixes + `[a-zA-Z0-9:._-]`, logins against GitHub's
  alphanumeric-and-hyphen shape — and never execute or interpolate them.
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
  `/claim` runs before the branch exists), it routes a refreshed candidate
  through `/claim`'s transaction helper. Only that helper may publish the
  `Claiming —` comment naming the real branch, after blocker, continuity, and
  fresh lineage checks. A mismatch at PR-close therefore means the claim is genuinely not
  that PR's; worst case it releases when the issue closes (no `--branch`
  there).
- **An incomplete record fails closed**: `Claim record` present but any of
  the three `by this claim:` lines missing or valueless — or any incomplete
  v2 chain-ownership trio — is unreadable
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

## Decision: claim-driven Project writes — removed (2026-08-20)

The claim flow deliberately performs no automatic Project write. Project
status is a manual, non-authoritative delivery view, because:

- a one-way `In Progress` projection cannot prove which prior status it
  displaced or restore that status without racing independent planning edits;
- the assignee, claim labels, and durable record already provide the complete
  attributable ownership and release contract; and
- a future event-driven delivery system may own Project transitions end to end,
  but a session claim must not leave an unowned projection behind.

This is the maintainer-approved scope decision for harmon-devkit#543. Revisit
only as a complete event-driven delivery-state design, not as a claim side
effect.

## Accepted gaps

- A PR merged into a **non-default base branch** does not auto-close its
  issues, so no event fires; the claim releases whenever the issue eventually
  closes.
- A merged PR that only `Refs` an issue triggers no event-driven release.
  `/wrap` owns the attributable partial-delivery transition when the issue stays open and
  no work remains in flight: it requires a complete trusted current claim
  record, a same-repository merged `Refs` PR authored by the authenticated
  account, whose head branch matches the current claim record and whose merge
  postdates that claim, no competing open PR or newer unrelated claim activity,
  and attributable descriptions of what landed and what remains. It re-reads
  that evidence immediately before cleanup and fails closed if the ground
  moved. That interactive cleanup restores a proven displaced claim label
  because the issue remains open, releases only markers
  proven owned by the direct/current chain record, and posts the supersede
  comment last. Ambiguous evidence fails closed to maintainer confirmation;
  event automation deliberately does not infer this state.
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
  repos, where the owner prong never matches a user), trust binds to the
  consumed comment body's `updated_at`: a strictly earlier assignment must
  begin an interval with no unassignment through that version. The script
  removes assignees last and skips them when an earlier marker write failed.
  If every marker write succeeds but the supersede post fails, it does not
  re-add an assignee and manufacture a new ownership interval; the retry uses
  the already-proven historical body version and posts the missing release
  comment without repeating absent marker removals.
- **Org-repo v1 trust** uses that same historical body-version proof. A later
  manual unassignment does not erase authorship trust for a body safely
  published while assigned, but an edit during an unassigned gap, a
  same-second ambiguous assignment, or unreadable timeline evidence fails
  closed. Association alone never admits a collaborator's forged claim.
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
- A card alone is never a claim marker. With no trusted comment, assignee, or
  ownership label, release has nothing attributable to mutate.
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
