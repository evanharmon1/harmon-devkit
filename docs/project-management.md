# Project Management

How work is tracked for Harmon DevKit in **GitHub Projects**.

## One default project per owner

The standard strategy is a single default GitHub **Project (V2)** per owner — one
board for the organization, or (for personal-account repos) one for the user
account — titled after the owner's GitHub login: `<owner> Project` (here:
**evanharmon1 Project**; e.g. `harmonops Project`, `evanharmon1 Project`).
Every repo the owner controls feeds that one board; an issue can belong to
multiple projects, but this default board is its home. Reach for a second,
focused project only when a body of work needs its own.

## Token scopes

Everything on this page that touches the board — `task setup:github-project`,
and the `Status` writes the [claim lifecycle](#claiming--making-an-agents-work-visible-while-it-happens)
makes — goes through the Projects V2 API, and `gh auth login` does **not** grant
access to it by default. Nothing else notices: the same token still reads
issues, opens PRs, and drives CI perfectly well, so the gap shows up only as
board writes that do nothing.

| Scope | Grants | Enough for |
|---|---|---|
| *(neither)* | — | nothing here — every board read and write fails |
| `read:project` | read Projects | reading a card's current `Status`; **no writes** |
| `project` | read **and write** Projects | everything on this page |

Ask for the full scope. It is a superset, so there is no reason to request
`read:project` alongside it:

```sh
gh auth refresh -s project
```

Check what a token actually carries:

```sh
gh auth status | grep 'Token scopes'
```

`task status:gh` reports this as **Project board writes**, so a missing scope
surfaces at session start — before a claim is made against a board that cannot
receive it. `task setup:github-project` refuses to run without it rather than
failing partway through its writes.

Two adjacent scopes, for completeness: an organization's **issue types** need
`admin:org` (reported by `task status:setup`), and the vendored claim skills
hint at `gh auth refresh -s read:project,project` — equivalent for this purpose,
since `project` alone already covers it.

### Scopes are only half the story

The table above is about **classic OAuth scopes**, which is what `gh auth login`
issues and `gh auth refresh` edits. A **fine-grained PAT** or a GitHub App
installation token has none of them: its Projects access is a *permission*
granted where the token was issued. `gh auth status` reports no scope list for
one, so `task status:gh` can only report the check as **unknown**, and
`gh auth refresh` cannot help — a token supplied through the environment as
`GH_TOKEN` cannot be refreshed at all. Grant it **Projects: Read and write** at
the source (organization permissions, for an org-owned board) instead.
The bot credential this template documents ([bot-account.md](guides/bot-account.md))
is exactly such a token. On a personal account it is granted no Projects
permission at all — that row of the PAT table is organization-scoped, and a
user-owned board has no equivalent setting to hand a second account. So an agent
running as the bot **cannot move a card**, and there is no permission to raise:
the board is moved by you, while the claim stays visible through the `claim:*`
label and the assignee — see
[Claiming](#claiming--making-an-agents-work-visible-while-it-happens), which is
exactly why a claim writes all three signals instead of relying on the board
alone. To have claims move cards on a personal board, run the agent under your
own `gh` login (which the scope table above applies to) rather than the bot's.

## Status pipeline

`Status` is a single-select field with exactly one meaning: **where in the flow
toward delivery is this.** The columns, grouped:

**Backlog** — triage; not yet committed

- Inbox — newly landed, unsorted
- Icebox — real, but not now
- Next — will pull in soon

**Unstarted** — committed to a cycle, not yet in motion

- Todo
- Shaping — problem/approach still being defined
- Ready — shaped, ready to pick up
- Agent Queue — queued for an AI agent to implement

**Started** — in motion, partial progress

- In Progress
- Verifying — CI/checks running
- In Review — under human review
- Ready to Merge — approved, awaiting merge

**Completed**

- Done — merged/shipped; the single terminal status
- Deployed
- Accepted — smoke/QA/manual check passed, communicated, released

Archiving isn't a status — it's a separate native axis. GitHub's built-in
**auto-archive** removes finished items from the board (into the retrievable
Archived-items view), so aged `Done` items leave the board automatically instead
of sitting in an "Archived" column.

**Agent Queue is the hand-off lane to AI coding agents.** An item lands there once
it's shaped and ready for an *agent* rather than a human to implement — a
`suggest:<family>[:<model>]` label says which intelligence should (see
[Labels](#labels)). Today the hand-off is manual: apply the suggestion and trigger
it (a `claude-*` workflow, or point Claude Code at the item). The lane is built for
future automation, though — an agent can watch *Agent Queue + `suggest:*` +
priority* (the Agent-queue view below) and pull the top item on its own — and
either way the item moves to **In Progress** once work starts.

> **Foreman is that automation** for issue-driven delivery: arm the issue with
> a `foreman:*` label (label arming is the supported mode — issue-field arming
> is refused because GitHub exposes no actor for field changes, so the trust
> gate cannot attribute it) and
> `task foreman:dispatch` / `foreman:watch` pulls ready items, opens verified
> PRs, and shepherds them to a human merge. The Project stays the human
> dashboard — foreman neither reads nor writes it (issue state, labels/fields,
> and PRs are its interface). See https://github.com/ponderousdev/foreman.

## Status is not issue state

GitHub has **two independent state machines**, and conflating them is the most
common way to make a board lie:

- **Issue state** — `open` / `closed`, native to the issue.
- **Status** — the custom pipeline field above, layered on top.

`Status` answers *"where in the delivery flow is this."* It is **not** where you
record *why something left the flow without shipping* — GitHub has a dedicated
axis for that, the **close reason**.

### Canceled and Duplicate are close reasons, not statuses

They aren't pipeline positions; they're terminal closure reasons, and GitHub
already has an axis for those that's separate from `Status` by design. When you
close an issue you pick **Completed**, **Not planned**, or **Duplicate**:

- **Cancel / won't-fix / stale** → close as **Not planned** — explicitly the
  bucket for exactly this.
- **Duplicate** → close as **Duplicate** (shipped December 2024). You select the
  duplicated issue, which produces a timeline event and a note at the top making
  the closure reason clear.

Neither needs a `Status` value, and **Done** stays the single terminal status
meaning "shipped." Why not add `Canceled`/`Duplicate` columns anyway, given
Linear has a Canceled group? Because in Linear the status *is* the state, so
"Canceled" closes the work atomically with that meaning. GitHub split them:
`Status` is a custom field layered on an issue that keeps its own independent
open/closed state.

### Automation gotcha

The built-in **"issue closed → Done"** rule doesn't look at *why* the issue
closed, so closing something as Not planned or Duplicate would paint it **Done**
on the board — wrong. Gate it:

- Drive Done off **"PR merged → Done"** for the success path.
- On a raw close event, check `state_reason == completed` before setting Done.

Items closed as not-planned/duplicate just stay closed and fall off the board;
their `Status` value goes vestigial, which is fine — nothing open-filtered shows
them.

## Blocked is not a status

A `Blocked` column buys you visibility you already get for free, and it fights
automation: statuses are artifact-driven (PR opened → Verifying) while "blocked"
is a manual human overlay — an item that's "Blocked" but has an open PR is a
contradiction the automation can't resolve. Blocked is **orthogonal** to pipeline
position; keep it off that axis. There are two kinds, and they want different
tools:

- **Blocked by another issue** (the common case) — use the native **"Mark as
  blocked by"** relationship (issue dependencies, GA 2025-08-21). It records
  *what's* blocking (the actual issue, not a bare flag), shows the **Blocked**
  icon on the board and Issues page automatically, is queryable with
  `is:blocked`, and is fully programmatic (`gh issue view` shows Blocked by /
  Blocking; `--json blockedBy,blocking`; REST endpoints add/list/remove).
  When the blocker closes, the relationship reflects it. Up to 50 issues per
  relationship type.
- **Blocked by a non-issue** — waiting on a Twilio 10DLC approval, an upstream
  library fix, a pricing decision, info from a customer. The native feature can't
  express this (an issue only becomes "blocked" by depending on another issue),
  so this is the **`blocked` label's** job: it means "stuck on a non-issue
  thing," with the actual reason in a comment.

One upgrade for that second case: model a *significant or shared* external
blocker as its own **tracking issue** ("Twilio 10DLC brand approval") and mark
the real work blocked-by it — that pulls the external dependency into the native
mechanism (board icon, `is:blocked`, auto-resolve). Worth it when several items
wait on the same thing; reserve the bare label for one-off, transient blockers.

## Automations

Projects are **org-level** objects, but automations trigger from **events**, and
issue/PR events are repo-local. That splits automation three ways:

1. **Triggered by repo activity (issue/PR events)** — the workflow *must* live in
   the repo where the activity happens; a workflow in one repo never sees
   another's PR events. In a polyrepo org the same automation runs in every repo
   whose issues/PRs feed the project.
2. **Triggered by a schedule or `workflow_dispatch`** — no per-repo trigger to
   distribute, so pick one hub/ops repo and run it there.
3. **Not an Action at all** — the project's **built-in workflows**.

Start with #3: **push everything you can onto the built-in workflows.** They're
configured on the project itself, fire on project-item events, and work
org-project-wide across every repo with zero Actions and zero per-repo setup —
Backlog on add, In Review on review-requested, Done on merge, Done on close,
auto-close, auto-archive. Drop to Actions only for the gaps built-ins don't
cover.

TODO: finalize exactly what to automate. The intended event → status shape:

- New issue → **Inbox**
- Branch/PR started → **In Progress**
- PR opened → **In Review**
- Deployment complete → verification (if applicable)
- Issue closed (`state_reason == completed`) → **Done**
- 90 days in Done → **auto-archived** off the board (native built-in, not a Status)

## Fields

`Status` is a **Project field** — the board pipeline above; it stays on the
project because the built-in workflows (and `project-automation.yml`, on an org)
drive it.

The work-metadata fields:

- **Priority** — Urgent / High / Medium / Low
- **Size** — estimation points on the Fibonacci ladder (1 / 2 / 3 / 5 / 8 / 13 / 21),
  a project **number** field so a view can sum it per group
- **Product** — which product/area it belongs to (free text)
- **Domain** — which part of the *product* it belongs to. Ships as a starter
  single-select (`auth`, `billing`, `platform`); the real vocabulary comes from
  your ERD entities — add options as the product grows
- **Layer** — which slice of the *stack* it changes: `ui` (components, styling,
  interaction, tokens, a11y — no data change), `logic` (business rules,
  handlers, calculation), `data` (schema, indexes, validators, migrations),
  `integration` (external boundary: webhooks, API clients, credentials)

There is deliberately **no `Agent` field.** *Which* intelligence should implement
an issue is advisory routing, and it now lives in the `suggest:*` **label**; which
one *is* implementing it lives in the `claim:*` label (both under
[Labels](#labels)). Both are labels rather than fields because a project field
records no actor for its changes and cannot be written on a personal-account board
at all — the reasoning is in
[Claiming](#claiming--making-an-agents-work-visible-while-it-happens).

Domain and Layer are orthogonal to each other and to `Type`/`Status`: an issue
normally carries one of each — *what part of the product* × *what slice of the
stack*. They ship with the same option lists as the `domain:` / `layer:` label
families below, so both surfaces start from one vocabulary — but nothing keeps
them in step afterwards. Two things to know before you extend either:

- **Nothing syncs an individual issue's label to its field value**, so an issue
  can carry `domain:auth` and `Domain=billing` at once. **Pick one surface as the
  source of truth** — the fields if you work the board, the labels if you live in
  `gh issue list` — and treat the other as optional. Dual-entering both by hand is
  how they end up contradicting each other.
- **A new starter value lands on a re-run.** `task setup:github-labels` creates
  *or updates*, and both field scripts **append** any starter option an existing
  single-select is missing — `task setup:github-project` for project fields,
  `task setup:github-issue-fields` for org issue fields. So a value added by a
  later harmon-init release reaches every surface the next time you run them.
  Appending is purely additive: the options you added are kept *with their
  identity*, so issues and board items already assigned to one keep their value,
  and nothing is renamed, reordered, or deleted. A re-run against an
  already-synced project writes nothing at all. One caveat: the issue-fields API
  is in public preview, so if its update endpoint rejects the change, the script
  names the missing options to add by hand rather than failing the run.

On a personal account there are no issue fields, so `task setup:github-project`
creates **Priority, Product, Domain, Layer, and Size** as project fields.

TODO: finalize each field's options/values.

## Labels

Labels are **repo-level** and orthogonal to `Status` (pipeline position) and
`Type` (kind of work) — they tag cross-cutting *facets*. Keep them in a few
families, color-coded by family; the starter set is created by
`task setup:github-labels`:

- **Concerns** — `sec`, `a11y`, `perf`, `tech-debt`, `i18n`, `l10n`
- **Source** — `customer-request`, `ai-generated`
- **Workflow** — `needs-triage`, `needs-requirements`, `blocked`, `waiting`,
  `needs-decision`, `needs-response`, `needs-communication` (transient triage
  states; `blocked` is the non-issue-blocker flag described above)
- **Layer** — `layer:ui`, `layer:logic`, `layer:data`, `layer:integration`
- **Domain** — start with `domain:auth`, `domain:billing`, `domain:platform`;
  grow from your ERD entities
- **Suggested agent** — `suggest:<family>[:<model>]`, human-written advisory
  routing: *which* intelligence should work the issue (e.g. `suggest:claude`,
  `suggest:claude:sonnet`, `suggest:codex:sol`). Replaces the retired `Agent`
  field; advisory only, it never dispatches anything.
- **Claim** — `claim:<family>[:<model>]`, agent-written live ownership: which
  intelligence is working the issue *right now* (e.g. `claim:claude`,
  `claim:claude:opus`, `claim:kimi:k3`). Applied at claim, released at hand-off
  (see **Claiming** below)

The `layer:` and `domain:` families offer the same options as the **Layer** and
**Domain** fields above — same names, same meanings, but no per-issue sync (see
Fields). Use the label when you want it on the issue list and in
`gh issue list --label`, the field when you want to group a board view by it,
and extend both together so the option sets stay identical.

`suggest:*` and `claim:*` name the model **intelligence**, not the harness that
runs it — Claude Code vs. the `@claude` Action vs. the codex CLI is operational
detail, recorded in the claim comment, not the label. The family segment is
required; the model segment is optional (`claim:claude` is a valid family-level
claim, `claim:claude:opus` pins the model). The family vocabulary — `claude`,
`codex`, `copilot`, `qwen`, `deepseek`, `glm`, `kimi`, `minimax`, `gemini` — and
its per-family models are defined once in harmon-init's `agent-registry.json` and
provisioned by `task setup:github-labels`; don't invent a per-repo slug. Foreman
arming stays separate and harness-centric (`foreman:<adapter>`) — a `suggest:*`
label is advice, never an arming signal.

GitHub labels live per-repository (there's no shared org label pool).
`setup-github-labels` seeds the set into one repo — run it in each, or set the
org's **default labels** (org Settings → Repository, UI-only) to seed *new* repos
(it won't change existing ones). It never deletes labels, so GitHub's defaults
remain until you prune them — including a pre-`ui`/`logic`/`data`/`integration`
repo's `layer:frontend`, `layer:backend`, and `layer:infra`, which you re-map and
delete by hand.

## Claiming — making an agent's work visible while it happens

An issue being worked on *right now* is the one fact the tracker holds worst.
The assignee is buried on the issue page and a claim comment is one entry in a
thread — neither shows on the board, which is where work is actually watched.
So two agents, or an agent and a human, start the same issue because nothing
visible said it was taken.

An agent starting work therefore writes every one of these it *can*, because
each is blind where the others see:

| Signal | Answers | Shows up in |
|---|---|---|
| `Status` = `In Progress` | where it is in delivery | the board |
| `claim:*` label | which agent is working it **right now** | the issue page, `gh issue list --label` |
| assignee | that *someone* has it | notifications, `gh issue list --assignee` |

**A claim writes `claim:*`, and must never write a `suggest:*` label.** The two
look like the same fact and are not:

| | Means | Set by | When |
|---|---|---|---|
| **`suggest:*`** label | which agent *should* implement it | whoever plans/triages | at planning, before the work starts |
| **`claim:*`** label | which agent *is* implementing it | the agent itself | at claim, released at hand-off |

They share one model-centric vocabulary — the same family and model slugs — but
they answer different questions. Overwriting the `suggest:*` label at claim time
would destroy the planning routing the **Agent queue** view is built on (that
view lists issues carrying a `suggest:*` label), and would erase the record that
work routed to one family was picked up by another.

So a claim writes the `claim:*` **label** and leaves any `suggest:*` untouched.
If the claim and the suggestion disagree, that is information, not drift: a
different intelligence picked up work routed to another one. Worth noticing, not
worth auto-correcting.

Both signals are labels, which is the whole point of retiring the old `Agent`
*field* (harmon-init ADR 0005). A label carries the actor who set it in its
timeline and works on every owner type; an org `Agent` issue field recorded no
actor and the Projects V2 API could not write it at all, so a claim that depended
on it was impossible on an organization to begin with.

These labels ship with `task setup:github-labels`, which is generated only for
`project_management: github`. A repo on `none` or `linear` gets no label
families at all, so a claim there rests on the assignee and the claim comment.

**During the rolling transition, the skills and the label provisioning move on
separate clocks.** The vendored `claim` / `shepherd` / `wrap` skills arrive via
`task sync:skills`; the `claim:*` / `suggest:*` label set is provisioned by
`task setup:github-labels`. Nothing makes the two atomic, so a repo can carry
skills that speak `claim:*` before its labels have migrated from the legacy
`agent:*` family — or the reverse. The skills absorb the skew: a claim prefers
`claim:claude` and falls back to the legacy `agent:claude-code` label only when
`claim:*` is not yet provisioned, and the release and stale-claim sweeps still
*recognize* a legacy `agent:*` claim so in-flight work started under the old
vocabulary is not stranded. That read-side recognition is also why a plain grep
for the literal `agent:claude-code` no longer proves a legacy *writer* is
installed — the automation check below accounts for it.

**A board write can fail without anyone learning.** Every `Status` write in the
lifecycle needs the [`project` scope](#token-scopes). Without it each one exits
2 — "could not verify" — and the steps handle that correctly *individually*:
it is an auth condition they cannot fix, so they note it and carry on. In
aggregate that is the worst outcome available. The agent reports the issue
claimed, the board says nothing was ever started, and neither is wrong from
where it stands; the hand-back then cannot restore a prior status it was never
able to read. Nothing in the loop escalates, so the board silently stops
tracking agent work in **both** directions until a human happens to notice it
has gone stale. Check the scope at session start (`task status:gh`), not after
the claim.

**A claim is a signal, not a lock.** None of these writes is atomic, and two
sessions running as the same GitHub user are invisible to each other — the
assignee converges, the label is idempotent, and the field is last-writer-wins.
It makes concurrent work discoverable by a human; it does not prevent it.

**A claim must be released.** `In Progress` left on finished or abandoned work
is worse than no signal, because the next reader believes it. The lifecycle
follows the pipeline honestly — `In Progress` at claim, `Verifying` while CI
runs, `In Review` awaiting a human, `Ready to Merge` only once actually
approved, and never `Done`, which belongs to whoever merges. On org repos
`project-automation.yml` already syncs `Status` from PR and CI events; anything
writing the card should defer to it there rather than racing it.

**A session cannot be relied on to release it.** The release is owed after the
merge, and no session is guaranteed to witness that: `/shepherd` stops before
the merge on policy, so the session that claimed the issue is usually over by
the time a human merges. `.github/workflows/claim-release.yml` is the release —
on `issues closed` (by any means) and on `pull_request closed` **unmerged**, it
undoes what the claim record says the claim added and posts the `Claim
released —` supersede comment. It needs no secret beyond `GITHUB_TOKEN`.

That workflow runs `release-claim.sh` out of the vendored `track-work` skill,
so it does nothing until you have run `task sync:skills` — which is also when
the skills that *write* claims arrive, so the two are never out of step. The
contract it parses, and the gaps it deliberately does not cover (a merged PR
with no closing keyword, an unmerged fork PR), are in
`.claude/skills/track-work/references/claim-lifecycle.md`.

> **Whether this is automatic depends on the skills you have vendored.**
> Writing and releasing these markers is implemented by harmon-devkit's
> `claim` / `shepherd` / `wrap` skills; older releases only assign the issue,
> and the three were named `preflight` / `shepherd` / `close` before
> harmon-devkit v0.21.0. Check yours rather than assuming — the pin moves on
> its own schedule, via the automated devkit-release sync:
>
> ```sh
> ls .claude/skills/claim/SKILL.md .claude/skills/wrap/SKILL.md 2>/dev/null
> ```
>
> Both present means claiming is automated end to end. Test for the **skills'
> presence**, not for a label literal: the migrated skills deliberately retain a
> read-side `agent:claude-code` compatibility literal (to recognize legacy
> in-flight claims), so the older check —
> `grep -rl 'agent:claude-code' .claude/skills/claim/ .claude/skills/wrap/` —
> now matches that *reader* and reports automation on a repo whose skills merely
> read the old label. It can no longer tell a legacy writer from a compatibility
> reader; the skills' presence can. If the skills are absent, the `claim:*` /
> `suggest:*` labels above are yours to apply by hand and no *skill* will move
> the card. That is not the same as nothing moving it: on an organization
> `project-automation.yml` still syncs `Status` from PR and CI events, so check
> what that workflow already does before setting the card manually — racing it
> is how the board ends up with whichever value happened to land last.

## Milestones

A milestone has **one job — "when it ships"** — and nothing else. Four things
could all masquerade as milestones, so keep the lanes clean:

- **Type** — what kind of work (Bug / Feature / Task / Research)
- **Status** — where it sits in the pipeline
- **Labels** — orthogonal, cross-cutting concerns
- **Sub-issues** — hierarchy

None of those answers *"which dated, shippable batch does this belong to, and how
done is that batch?"* — that's the milestone's unique contribution: a
release/launch container with a **due date** and a **live completion bar**. Labels
for classification, milestones for goal tracking. The moment you're making a
milestone that isn't a dated, shippable batch, it's really a label or a saved
view.

**Name milestones after release versions** — the milestone title *equals* the git
tag (`v1.0.0`, `v1.1.0`). Then the milestone list doubles as a release-history /
changelog skeleton, and closing a milestone on publish needs no special plumbing.
This dovetails with **release-please** because they run at different times and
never overlap:

- The **milestone** is the *pre-ship planning* artifact — "what must land before
  we cut `v1.1.0`."
- **release-please** is the *post-merge machine* that calculates and cuts the
  actual version from your conventional commits (see
  [conventions.md](conventions.md)).

Naming them identically makes the two legible to each other — the shipped
`close-milestone-on-release.yml` Action closes the milestone matching a published
tag (when release-please is on) — without making them one system. Since PRs and
issues share the milestone namespace, the release PR itself
can carry the milestone, so the shipped batch is fully self-documenting.

**One active release milestone at a time (rolling).** Carry one open milestone per
release line — created when it has real scope and a date, closed when it ships,
the next opened only as needed. Not five speculative open milestones competing for
attention.

**Due dates are signals, not gates.** A milestone's due date doesn't block a merge
or a close and triggers nothing — it's a communication tool; update it honestly
when the plan slips. That's where milestones earn their keep on a team: the dated
milestone is the shared artifact that tells collaborators what's shipping and
roughly when — worth more with others in the loop than in pure solo work.

## Milestones over iterations

For pre-launch product development, lead with **milestones, not iterations**
(sprints). The mechanisms differ in what they fix vs. flex:

- **Iterations fix time, flex scope** — the window ends Friday, you ship whatever's
  done.
- **Milestones fix scope, flex time** — you ship when the thing is done; the date
  is a signal.

Early product work needs to **fix scope**: a half-built product at an arbitrary
time-box boundary isn't shippable value — "ship it when it's good enough to charge
for" is a scope commitment, not a time one. Here the milestone's commitment shape
is right and the iteration's is actively wrong.

**Incremental delivery doesn't come from either mechanism** — it comes from **small
slices + frequent deploys + a release cadence**, which you already have (PR-sized
sub-issues, per-PR previews to prod, release-please cutting incremental releases
from accumulated commits). You can sprint and ship zero user value, or run
milestones and ship continuously; the delivery job routes through the *release*
mechanism (milestone-adjacent), not sprints.

**So run small, frequent milestones** — a shippable chunk every ~2–4 weeks, not one
giant "Launch." A tightly-scoped milestone with a target date is a chunk of value
with an expectation attached, doing three jobs at once: coordination (toward
shippable scope), commitment (to that scope; date as signal), and incremental
delivery (frequent small releases). It's literally the release-please flow —
**small frequent milestones == frequent small releases** — so it's one rhythm, not
two.

**Get the forcing-function from tools you already have,** not a sprint clock: a
**WIP limit** on `In Progress`, sub-issues **sized to one PR**, and continuous
deploy — anti-drag pressure applied at the work slice, not a calendar boundary a
tiny team can't make hard anyway.

**Why this phase picks milestones:** early development is **discovery-driven** —
you're figuring out scope as you go, capacity is erratic, and the priority is
shipping the *right* thing, not a predictable amount. Iterations shine in the
opposite regime (a known backlog, steady team, predictable capacity metered at a
constant clip) — steady-state maturity, not pre-launch. (Honest counter:
time-boxing can curb rabbit-holing during discovery — but the Lean answer is
build-measure-learn, get it in front of a user fast, for which the clock is your
**deploy cadence**, not a two-week sprint; and a WIP limit plus one-PR slices curb
it at the work level more directly. You already have those.)

**Iterations also don't fit the agent queue.** Agents run when triggered, not "this
week"; scoping the queue to `iteration:@current` adds nothing over *agent-set +
Ready + priority*. Iteration is a human-cadence concept your agents don't have.
(The native Iteration field stays available if you reach steady-state and want it.)

## Hierarchy (sub-issues, not Epics)

There's **no Epic type, by design.** The "big initiative" role splits cleanly
into two natives — **sub-issues** carry the *hierarchy* axis and **milestones**
carry the *release* axis — and GitHub stitches them together for you: a
**sub-issue inherits its parent's Project and Milestone by default** (shipped
2025-09). Assign them once on the parent and the child tree picks them up — no
per-child bookkeeping.

So a parent issue "Scheduling v1" in milestone `v1.1.0` pulls its whole subtree
into that release payload for free. Break big work down with **sub-issues** (up to
8 levels — flip on **Show hierarchy** in a view to expand/collapse the tree)
rather than a markdown checklist or an Epic type: you get the structure without
the "Feature or Epic?" tax.

**Sub-issues are your only hierarchy axis; everything else stays flat.** Type,
Status, milestone, labels, and fields must never try to encode "part of" — that's
the sub-issue's job, and only that. Once that's clear, the rest is just sizing and
deciding what metadata rides on the parent vs. the leaves.

**The three-tier shape (replaces Epic → Story → Task with natives):** a
**milestone** (the dated release batch — possibly-unrelated work) contains parent
**Feature** issues (each a cohesive capability), each of which contains **Task**
sub-issues (mergeable slices). Full hierarchy, no synthetic Epic.

The boundary that trips people up: **a milestone is a flat batch of unrelated
features targeting a date; a parent issue is one cohesive thing decomposed.** So
don't build a giant "Launch" parent with 40 sub-issues spanning unrelated features
— that's exactly what the milestone is for. Milestone for the cross-feature
release; the parent-issue tree for a single feature.

**Where metadata lives — parent vs. leaf.** The **parent** holds the durable
context: the spec (your Given/When/Then acceptance criteria), the "why," the
explicit *not*-doing reasoning, and — since sub-issues auto-inherit it — the
**milestone and project** assignment. Set those once on the parent and the tree
inherits; move the parent to `v1.1.0` and the whole tree moves with it. Never set
the milestone per child.

The **leaves** hold execution: the `Task` type and the **`Size` points**. Put
the estimate on the mergeable one-PR slices, not the parent — estimating a slice is
reliable, estimating a big parent isn't — and a view's field sums total the leaves
for you.
It's route-not-duplicate applied to hierarchy: a child references the parent's spec
rather than restating it, and reads up for context.

**Sub-issue vs. task-list checkbox.** Markdown `- [ ]` task lists still have a
place. The rule: if an item needs its own **status, assignee, or independent
scheduling**, promote it to a **sub-issue**; if it's just "steps to finish this one
issue," leave it a **checkbox** in the body. Don't promote every checkbox (that's
sprawl), and don't spin up a sub-issue where a checkbox suffices.

**Research child as a blocking gate.** When a Feature has an unknown, spawn a
**Research** sub-issue and let it *block* the implementation children. It closes
when it produces a decision record (the Research closure rule), which unblocks the
rest — encoding "figure this out first, then build" in the tree itself, and tying
Research, sub-issues, and the ADR discipline together.

**Hierarchy is not dependency.** A sub-issue means *"part of,"* not *"must happen
before."* If A must finish before B but B isn't part of A, that's a **dependency**
— the native blocked-by relationship, or the `blocked` label + a note (see
**Blocked is not a status** above) — not a parent-child link. Conflating them
corrupts the tree; keep composition (sub-issues) and sequencing (dependencies) in
separate mechanisms.

## Cross-repo work

The one board already spans every repo (the single default project per owner). For
work that *itself* crosses repos, reach for the tree, not a new field:

**A cross-repo feature → a parent sub-issue tree. No field needed.** A feature that
touches app + infra + marketing is one cohesive thing, so it's a legitimate parent:
the parent **Feature** issue lives in the app repo, its **Task** children live in
whichever repos they belong to (sub-issues cross repos freely), and the parent's
rollup counts completion across all of them. The tree *is* the cross-repo grouping
— you track it by opening the parent, not by tagging a field.

**A cross-repo *release* is mostly a smell.** Repos with genuinely independent
deploy cadences shouldn't share a release: the app cuts versions via release-please
on its own rhythm, an Astro marketing site deploys continuously on copy changes,
infra changes when infra changes. Forcing "app v1.1.0 + a pricing-page edit + a
terraform tweak" into one dated cross-repo release invents coordination the
independent cadences don't need. What legitimately spans repos is **features, not
releases** — so the flat cross-repo batch a milestone structurally can't hold (and
that a field would exist to solve) mostly shouldn't exist.

**The one genuine exception: a coordinated launch.** An initial public launch
really does need app-live + marketing-up + infra-provisioned at once — a real
cross-repo dated batch. Even then, model it as a single **Public Launch** parent
tracking issue with cross-repo sub-issues, not a new field: it's a one-time event,
not a recurring dimension worth a permanent field on every issue forever.

## Views

Views (the board's tabs) **can't be created via API** — Projects V2 exposes no
view mutations, only reads — so create these once in the UI (**Project → New
view**). Keep the saved set small; **slice the one board** (below) for the rest.

- **Board** — board, `is:open`, grouped by `Status`. The day-to-day working board.
- **Triage** — table, filtered to items **missing a `Priority`** or carrying
  **`needs-triage`**, grouped by **Type** (Bug / Feature / Task / Research) so you
  see the shape of the inbox. This is your grooming session — it exists so
  untriaged work can't hide; empty it regularly and it stays useful.
- **Agent queue** — board, filtered to issues carrying a **`suggest:*`** label,
  showing only the in-flight `Status` columns (**Ready, Agent Queue, In Progress,
  Verifying, In Review, Ready to Merge**), sorted by `Priority`.
- **Planning** — table, grouped by **`Product`** (or `Type`), sorted by
  `Priority`, with the **`Size` field summed in each group header**. The "how
  big is the pile, and what's the plan" view, and a **dates-free roadmap
  substitute**: the per-group sum shows the weight behind each product without
  maintaining a timeline. (`Size` is a **number** field — GitHub sums number
  fields in group headers, so this totals the points behind each group; a
  single-select can't be summed.)
- **Mine** — table, `is:open assignee:@me`, sorted by `Priority`.

### Two toggles, not more views

- **Show hierarchy** (sub-issues — public preview) — expands/collapses sub-issues
  up to 8 levels while still grouping, slicing, sorting, and filtering. Flip it on
  in the Board or Planning view for the parent-with-children rollup you'd
  otherwise reach for an Epic type to get — the payoff of choosing **sub-issues
  over Epics**: structure without the "Feature or Epic?" tax. Still preview, so
  expect rough edges.
- **Slice the board** — rather than separate per-product / per-layer / per-agent
  saved views, slice the one board: by **`Product`** when you go multi-product, by
  **`Domain`** to focus a product area, by **`Layer`** to focus a slice of the
  stack, or by the **Labels** axis on the `suggest:*` / `claim:*` families to see
  the agent split. One board, many lenses — and how multiple products stay legible
  in one aggregating project instead of fragmenting into project-per-product.

## Notes

- **Labels vs Type** — `Type` is a first-class, org-level issue field
  (Bug / Feature / Task / Research), separate from labels (see **Labels** above);
  don't reproduce it as a label.
- **Owner**, **Iteration/cycle** — additional fields/axes as the work needs them
  (**Milestones** have their own section above).
- An issue can belong to **multiple projects** — the org project plus a focused
  one is fine.
