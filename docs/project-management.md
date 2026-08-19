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

### Getting them: `task setup:gh-scopes`

```sh
task setup:gh-scopes
```

**Operator / dev profile only.** It refreshes *your* interactive `gh` login —
so it refuses when a `GH_TOKEN`/`GITHUB_TOKEN` env credential is set (an env
token overrides the stored one, so a refresh would repair something this shell
never uses — reissue that token at its source instead) and refuses without a
TTY, because the flow is an interactive browser device-code exchange and no
agent or CI job should re-mint a human credential. It prints the current
scopes, requests the missing ones, and then **verifies they actually landed** —
`gh auth refresh` can exit 0 having granted less than was asked for.

The raw equivalent, derived from the same list rather than copied out of it —
a hardcoded copy silently goes stale the moment the list changes (an org repo,
for instance, also needs `admin:org`):

```sh
gh auth refresh -s "$(bash -c '. scripts/gh-scopes.sh && gh_scopes_request_list')"
```

To just see what this repo asks for:

```sh
bash -c '. scripts/gh-scopes.sh && gh_scopes_request_list'
```

(Through `bash` on purpose: the helper resolves its own location via
`BASH_SOURCE`, and the devcontainer's default shell is zsh, where sourcing it
directly would resolve the repo root to the wrong directory and silently shrink
the list.)

Check what a token actually carries:

```sh
gh auth status | grep 'Token scopes'
```

### Where the required list lives

One file: `scripts/gh-scopes.sh`. The session-start check in `status.sh`,
`setup-gh-scopes.sh`, and the devcontainer's `gh_auth_help` banner all read it,
so the remedy a warning prints and the scopes the task requests cannot drift
apart. Add your own **without editing the file** by exporting
`GH_EXTRA_SCOPES` (e.g. from `.envrc`):

```sh
export GH_EXTRA_SCOPES="delete_repo"
```

That is **additive**: everything this repo's profile already requires keeps
applying, including anything a later template update introduces.
`GH_REQUIRED_SCOPES` also exists and **replaces** the computed list outright —
an escape hatch that freezes today's defaults. Prefer `GH_EXTRA_SCOPES`.

Whitespace separates requirements; `|` joins alternatives that each satisfy
one. The Projects requirement is present only because this repo has board
tooling — a repo generated without it requires `repo workflow` alone, and is
never warned about a grant it does not use.

### Where it surfaces

`task status:creds` — which the session-start hook runs every session — warns
when the token is missing anything on that list, names the missing scopes, and
prints the remedy. It is silent when the list is satisfied, read-only,
non-fatal, and bounded (one 3s probe; `STATUS_NO_NETWORK=1` skips it). A probe
that cannot answer reports nothing rather than accusing a working credential.

`task status:gh` additionally reports **Project board writes**, a narrower
question: `read:project` satisfies the session-start check but is read-only, so
it fails that one. `task setup:github-project` refuses to run without `project`
rather than failing partway through its writes.

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
it (an `@claude` mention naming `implement` — see
[The Claude Actions workflows](#the-claude-actions-workflows) — or point Claude
Code at the item). The lane is built for
future automation, though — but the trigger for autonomous dispatch is an
authorized `foreman:*` arming label (the Foreman note below), **never** the
advisory `suggest:*`, which only records which intelligence *should* work the
item. Treating a `suggest:*` label as consent to execute would let any repo
writer arm dispatch, bypassing the actor-attributable `foreman:*` trust gate.
Either way the item moves to **In Progress** once work starts.

> **Foreman is that automation** for issue-driven delivery: arm the issue with
> a `foreman:*` label — label arming is the only supported mode, because
> Foreman requires a trusted, timeline-attributable arming actor and GitHub
> exposes no actor for an issue-field change — and `task foreman:dispatch` /
> `foreman:watch` pulls ready items and delivers them **draft-first**: it opens
> a **draft** PR labelled `foreman:dispatched`, runs its own verify gate,
> shepherds CI and reviews on the draft, and promotes it to
> `foreman:ready-for-review` only through its readiness gate. Merging is always
> a human decision. The Project stays the human dashboard — foreman neither
> reads nor writes it (issue state, labels, and PRs are its interface). See
> https://github.com/ponderousdev/foreman.

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
- Leave the built-in **"item closed → Done"** rule **off**. Only a custom
  Action can read `state_reason`, and none ships here — so the built-in is the
  whole of what that rule would do, and it cannot tell a shipped issue from an
  abandoned one.

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

What is automated, and by which of the three:

| Event | Sets `Status` to | Mechanism |
|---|---|---|
| Item added to the project | **Inbox** | built-in workflow |
| Review requested on a PR | **In Review** | built-in workflow |
| PR merged | **Done** | built-in workflow |
| Issue closed, for any reason | *(nothing)* | not automated — see below |
| PR closed unmerged | *(nothing)* | deliberately not automated |
| 90 days in Done | **auto-archived** off the board | built-in auto-archive (not a `Status`) |

`In Progress` is deliberately **not** automated: it means a human or an agent
picked the work up, which happens before any artifact exists to trigger on. It
is written by the [claim lifecycle](#claiming--making-an-agents-work-visible-while-it-happens).

**Closing an issue moves nothing, on purpose.** Nothing shipped here listens for
`issues: closed`, and GitHub's built-in "item closed → Done" rule cannot read
the close reason — so leave that built-in **off**. Turned on, it paints every
issue closed as *Not planned* or *Duplicate* **Done**, which is exactly the
misfiling the [close-reason axis](#canceled-and-duplicate-are-close-reasons-not-statuses)
exists to prevent, and every one of them needs correcting by hand. Left off,
`Done` keeps meaning shipped: it arrives from the merge path above, and the
occasional issue that completes without a merged PR is moved by hand. An issue
closed as not-planned simply keeps whatever `Status` it had — vestigial, and
invisible to every open-filtered view.

There is no `project-automation.yml` here: it writes an **org** project through
the CI GitHub App, and a personal-account board has no equivalent. The
built-ins plus the claim lifecycle are the whole story.

## Fields

`Status` is a **Project field** — the board pipeline above; it stays on the
project because the built-in workflows (and `project-automation.yml`, on an org)
drive it.

The work-metadata fields:

- **Priority** — Urgent / High / Medium / Low
- **Size** — estimation points on the Fibonacci ladder (1 / 2 / 3 / 5 / 8 / 13 / 21),
  a project **number** field so a view can sum it per group
- **Product** — which product/area it belongs to (free text)

There is deliberately **no `Agent` field**. Which agent *should* take an issue
is the `suggest:*` label family plus the `Status: Agent Queue` lane; which agent
*is* working it is the claim label (see **Claiming** below). A field could carry
neither answer without duplicating the label vocabulary, and on an organization
the Projects V2 API could not even write it — see
[Label or field?](#label-or-field).

There is likewise deliberately **no `Domain` or `Layer` field** (harmon-init#875). Both
used to exist as a field *and* a label — `domain:` / `layer:` below — with
nothing syncing an issue's field value to its label, which is exactly the
[Label or field?](#label-or-field) trade-off: a label is readable without
project scope, writable with plain repo scope, and available on personal
repos, none of which the field bought back. Since one surface has to be the
source of truth and the label already was for anyone living in `gh issue list`,
the field was the redundant one.

**Migrating a board that still has one** (set up before a field was retired):
the setup scripts are additive-only by design, so deleting a live field is an
explicit operator step, and reviewing its values comes first — deleting a field
destroys every value on it, unrecoverably.

- **Agent** (retired earlier):
  1. Provision the replacement vocabulary first: run `task setup:github-labels`
     in every repository whose issues carry the field — a `suggest:*` label must
     exist in a repo before an assignment can be copied onto its issues.
  2. List what the field holds — filter the Project's own board/table view by
     the field, not a capped CLI listing (`gh project item-list` defaults to a
     page size well under a typical board, and `gh issue list` won't show
     draft items at all): every issue or board item with `Agent` set,
     including **draft items**, which can carry the project field but can
     never carry a label. Convert any draft whose assignment you want to keep
     into an issue first; a draft you leave as-is loses its assignment with
     the field.
  3. Carry each assignment you still want over as the matching `suggest:*` label
     on the issue (e.g. `Agent: Claude Code` → `suggest:claude`).
  4. Re-point the saved **Agent queue** view (below) at the new predicate —
     filter on the `suggest:*` labels instead of the `Agent` field. A view still
     filtered on the field loses its routing predicate the moment the field is
     deleted.
  5. Only then delete the field — Project settings → the field → *Delete field*
     on a personal project. On an organization the field is **org-wide**:
     deleting it under **Settings → Planning → Issue fields** removes the value
     from every issue in every repository and project the org owns, not just
     this board — repeat steps 2–4 across the whole organization before
     deleting, including step 4 for **every** Project whose saved views filter
     on the field, not just the board being migrated.
- **Domain / Layer** (retired by harmon-init#875): `domain:*`/`layer:*` are provisioned
  by default, so most repos already carry them — but don't skip the
  provisioning step on that assumption; confirm it.
  1. Provision the replacement vocabulary first, the same as Agent: run
     `task setup:github-labels` in every repository whose issues carry the
     field. An org-wide issue field is shared by every repo in the org, and
     labels are not — a repo that never ran the script has neither label
     family yet.
  2. List every issue with `Domain`/`Layer` set.
     Filter the Project's own board/table view by the field — every value is
     necessarily an item of that one project on a personal account — not a
     capped CLI listing (`gh project item-list` defaults to a page size well
     under a typical board, and `gh issue list` won't show draft items at
     all). Include **draft items**, which can carry the project field but can
     never carry a label: convert any draft whose value you want to keep into
     an issue first, since a draft left as-is loses the value outright once
     the field is gone.
     For each item, add the matching `domain:*`/`layer:*` label — **creating
     it first** if the field carries a custom option (e.g. `Domain: crm`)
     that has no label counterpart yet, since the starter set
     `setup:github-labels` provisioned is only a floor. Nothing kept the two
     in sync, so do not assume the label already exists just because the
     field option does.
  3. Re-point any saved view that **groups, filters, or sorts** by the
     `Domain`/`Layer` field. A label can still filter a view (`domain:delivery`,
     say), but — unlike a field — a project view cannot **group or sort** by a
     label, so a view built for the per-domain/per-layer rollup or ordering
     loses that; keep the grouping on `Product` (still a field) and reach for
     a label filter instead.
  4. Only then delete the field(s) — Project settings → the field → *Delete
     field* on a personal project; **Settings → Planning → Issue fields** on an
     organization, org-wide as above.

On a personal account there are no issue fields, so `task setup:github-project`
creates **Priority, Product, and Size** as project fields.

### The provisioned field values

What the setup scripts actually create. Every single-select is a **starter
set**: re-runs append missing options and never rename, reorder, or delete, so
options you add in the UI survive and a value added by a later template release
lands on the next run.

| Field | Type | Values | Provisioned by |
|---|---|---|---|
| **Status** | project single-select | Inbox, Icebox, Next, Todo, Shaping, Ready, Agent Queue, In Progress, Verifying, In Review, Ready to Merge, Done, Deployed, Accepted | `setup:github-project` |
| **Size** | project number | free numeric entry; the Fibonacci ladder (1, 2, 3, 5, 8, 13, 21) is a convention, not an option list | `setup:github-project` |
| **Priority** | project single-select | Urgent, High, Medium, Low | `setup:github-project` |
| **Product** | project text | free text | `setup:github-project` |

## Labels

Labels are **repo-level** and orthogonal to `Status` (pipeline position) and
`Type` (kind of work) — they tag cross-cutting *facets*, with one exception:
personal-account repos have no native issue Type, so six labels (`bug`,
`feature`, `documentation`, `question`, `task`, `research`) carry that
classification instead; an organization carries it in `Type` alone and never
applies any of the six. Four of them — `bug`, `feature`, `task`,
`research` — are form-backed, applied automatically by the matching issue
form; `documentation` and `question` have no dedicated form and are applied
by hand. Keep the rest in a few families, color-coded by family; the
vocabulary lives in
[`label-registry.json`](../label-registry.json) (the machine-readable manifest
the taxonomy table below is generated from) and the starter set is created by
`task setup:github-labels`:

- **Concerns** — cross-cutting facets worth filtering on: security,
  accessibility, performance, tech debt, internationalization
- **Source** — where the work came from (a customer request, AI authorship) —
  durable provenance, never removed
- **Workflow** — transient triage states; `blocked` is the non-issue-blocker
  flag described above
- **Layer** — which stack slice the change lives in
- **Domain** — which product capability the work serves (the *problem* space).
  Domain values are per-repository vocabulary — grow them from your product's
  own capabilities; the label family is the only surface for this taxonomy
- **Work type** — what kind of work the issue is, on personal-account repos
  where native issue Type is unavailable; the issue forms apply it, and org
  repos use native Type with no work-type label
- **Rigor** — which round-cap tier in [`.devflow.toml`](../.devflow.toml) an
  agent works the issue under (AGENTS.md, "Round caps are resolved, not stated
  here"). An agent reads it and never self-applies one. It is advisory rather
  than an authenticated gate: nothing verifies who applied it, and the
  **triage** role can label an issue with no push access — so AGENTS.md
  requires any cap or floor resolving below `default_rigor` to be stated in
  the PR body, keeping a reduced budget visible to the reviewer — the
  `min_rounds` floor included. Two present resolve per stage to the highest
  cap, and the floor likewise to the highest present, so a conflict can only
  ever buy more review.

The prose above describes what each family *means*; the actual values — names,
colors, writers, lifecycle — live in `label-registry.json` and appear in the
generated taxonomy table below, so vocabulary is never restated here.

Two more families name **model intelligence** rather than a facet of the work,
and their vocabulary is not hand-listed anywhere: it is rendered from
`agent-registry.json` (see [Agent families and harnesses](#agent-families-and-harnesses)),
so provisioning and documentation cannot fork from each other.

- **Suggest** — `suggest:<family>` — which agent family
  *should* implement the issue, set at triage. Advisory only: it routes
  nothing by itself and must never be read as Foreman arming (that is the
  `foreman:*` family). A model-level label (`suggest:<family>:<model>`, created on
  demand) **refines** the family label, never replaces it — apply both, so
  views filtered on the family labels keep seeing the issue
- **Claim** — `claim:<family>` — which agent family is working
  the issue *right now*, written by the agent itself (see **Claiming** below).
  Model-level (`claim:<family>:<model>`) refines it the same way

> **Transition — the retired `agent:*` family.** Repos seeded before the
> registry-driven vocabulary carry `agent:claude-code`-style labels instead of
> `claim:*`. Setup never deletes labels, and the vendored claim/release skills
> (harmon-devkit v0.23.0+) prefer `claim:*` and fall back to `agent:*` where
> only the legacy family exists — so existing claims keep working while live
> labels migrate (harmon-init#663), and everything below about the claim
> label applies to whichever family a repo carries. Do not seed `agent:*`
> into new repos; a repo carrying neither family tracks a claim by assignee
> and claim comment alone.

The `layer:` and `domain:` families are the *only* surface for this
taxonomy (see Fields) — there is no more paired project/issue field to keep
in step with, so extend the label lists alone as the product grows.

`suggest:*` and `claim:*` name the model **intelligence**, not the harness that
runs it — Claude Code vs. the `@claude` Action vs. the codex CLI is operational
detail that lives in the session context, not the label. Claims and suggestions
operate at the **family level** (`claim:claude`, `suggest:claude`): that is what
`task setup:github-labels` provisions and what the vendored claim skill applies,
since a claim applies an existing label rather than minting one. One unmigrated
exception: a **provider-rewired** Claude Code session (the shipped Kimi / DeepSeek
/ GLM wrappers) still claims `claim:claude` today, so its label names the
wrapper's base family rather than the model actually running — deriving the
rewired family into the claim label is future skill work. The registry vocabulary also
allows an optional model segment (`claim:claude:opus`), but standard provisioning
emits only family-level labels and does not add a model-level one — a model-pinned
label exists only where it was created by hand. The family vocabulary is
defined once in
[`agent-registry.json`](#agent-families-and-harnesses) — deliberately not
repeated here, because a hand-copied list is exactly the fork this section
says cannot happen; read the generated table below for the current families —
and provisioned by `task setup:github-labels` (mid-migration
— see the transition note under **Claiming** below); don't invent a per-repo slug. Foreman arming stays
separate and harness-centric (`foreman:<adapter>`) — a `suggest:*` label is
advice, never an arming signal.

GitHub labels live per-repository (there's no shared org label pool).
`setup-github-labels` seeds the set into one repo — run it in each, or set the
org's **default labels** (org Settings → Repository, UI-only) to seed *new* repos
(it won't change existing ones). It never deletes labels, so GitHub's defaults
remain until you prune them — including a pre-`ui`/`logic`/`data`/`integration`
repo's `layer:frontend`, `layer:backend`, and `layer:infra`, which you re-map and
delete by hand.

### Labels carry no permissions

**GitHub has no per-label permission.** Anyone with triage access to the repo
can apply or remove any label, and the label itself records nothing about who
did — a label is a string on an issue, not a capability. So a label can never
be the security boundary. The boundary is always in the **consumer**: whatever
reads a label to start work must independently establish who applied it, and
refuse when it cannot.

That rule has a hard form: **any label that triggers automation must have an
actor-verifying consumer.** Here that class is exactly the Foreman arming
labels. Every other family either triggers nothing, or is read by a consumer
that can only stop work:

| Family | Triggers execution? | How the consumer establishes trust |
|---|---|---|
| `foreman:<adapter>`, `foreman:approved` | **yes** — arms an issue for dispatch | Foreman reads the `labeled` **timeline event**, takes the actor from it, and requires that login in `trusted_actors` (`.foreman.toml`). Unattributable arming is a fail-closed refusal, never a dispatch — which is also why issue-field arming is refused outright: GitHub exposes no actor for a field change |
| the Claude Actions workflows | **no** — labels trigger nothing at all | Execution starts only on an explicit `@claude` mention naming `plan`, `implement`, or `review`, from a login on the workflow's sender allowlist. The allowlist is enforced in the job `if:` and re-asserted in a token-free step *before* any credential is minted |
| `claim:*` (and legacy `agent:*`) | **no** — read as a gate, not a trigger | Those workflows refuse to start on a target that already carries one. No actor check is needed for a signal that can only *withhold* execution: the worst outcome is a visible, reversible refusal |
| `autorelease: *` | **no** | release-please writes them on its own release PRs and reads only what it wrote; nothing dispatches from one |
| everything else | **no** | human-facing facets, read by people and saved views |

There are no `claude-plan` / `claude-implement` / `claude-review` **trigger**
labels, for exactly this reason: a `labeled` event carries an actor, but the
label sitting on the issue afterwards does not, so half the paths a
label-triggered workflow can start from have nobody to check. Label setup is
additive, so a repository standardized before those labels were retired may
still carry them live-but-inert — delete them by hand.

### Label or field?

Both surfaces can hold the same-looking datum, so the choice is made on
mechanics, not taste. Use a **label** when the datum must be any of:

- **multi-valued** — an issue can legitimately carry two at once;
- **visible without project scope** — readable from `gh issue list` and the
  issue page, with no Projects API token;
- **writable with plain repo scope** — no `project` scope, no org permission;
- **timeline-attributable** — the `labeled` event records who applied it and
  when;
- **available on personal repos** — org issue fields do not exist there.

Use a **field** when it is **single-valued planning metadata you slice the
board by**: `Status`, `Priority`, `Size`, `Product`.

The consequences are not stylistic. Foreman arming is labels because only
the label timeline names an arming actor. Claims are labels because a claim
must be writable and visible to an agent holding nothing but repo scope, on
personal and org repos alike. And there is deliberately no `Agent` field:
advisory routing and live ownership are two different facts, a single-select
could carry neither without duplicating the label vocabulary, and on an
organization the Projects V2 API could not write it at all. `Domain` and `Layer` were fields once
too, and were retired for the same reason: a label already covered every one of
the bullets above and nothing kept the two surfaces in sync (harmon-init#875).

### The complete label taxonomy

Every label family this repository knows about, **generated from the
machine-readable manifest** — [`label-registry.json`](../label-registry.json)
holds the families, values, colors, writers, lifecycle, and per-value
overrides, and `task test:label-registry` fails when this table drifts from
it. **Provisioned** means `task setup:github-labels` creates it; **tool-owned**
means the tool that uses it creates it on demand, and provisioning
deliberately leaves it alone.

<!-- label-taxonomy:begin -->
<!-- Generated from label-registry.json by `node scripts/label-registry-render.mjs docs-table`. Do not edit by hand — `task test:label-registry` fails on drift. -->

| Label / family | Writer | Reader | Trust class | Lifecycle |
|---|---|---|---|---|
| `sec`, `a11y`, `perf`, `tech-debt`, `i18n`, `l10n` | humans, at triage | humans, saved views | provisioned; inert | applied when true, removed when not |
| `customer-request`, `ai-generated` | whoever files or authors the work, human or agent | humans, saved views | provisioned; inert | durable provenance — never removed |
| `needs-triage` | humans, the issue forms, and the triage skill | humans, the Triage view | provisioned; inert | added freely at filing; removed only when classification is complete |
| `needs-requirements`, `blocked`, `waiting`, `needs-decision`, `needs-response`, `needs-communication` | humans, at triage | humans, the Triage view | provisioned; inert | transient — removed as soon as the state clears |
| `bug`, `feature`, `task`, `research` | the issue forms on personal-account repos; humans or agents at triage | humans, saved views | provisioned; inert | durable classification — org repos use native issue Type and no work-type label |
| `documentation` | GitHub ships it at repo creation; humans or agents apply it at triage | humans, saved views | not provisioned — a GitHub repo-creation default adopted into the work-type vocabulary | durable classification — org repos use native issue Type and no work-type label |
| `question` | GitHub ships it at repo creation; humans or agents apply it at triage | humans, saved views | not provisioned — a GitHub repo-creation default adopted into the work-type vocabulary | durable classification — org repos use native issue Type and no work-type label |
| `enhancement` (**retired**) | nobody — replaced by `feature` | humans, saved views | retired — the GitHub repo-creation default this vocabulary replaces with `feature`; never provisioned | rename BEFORE provisioning creates `feature` (`gh label edit enhancement --name feature`, association-preserving); once `feature` exists the rename is refused — re-label the issues and delete `enhancement` |
| `layer:{ui,logic,data,integration}` | humans or agents, at triage | humans, `gh issue list --label` | provisioned; inert | durable classification; the label family is the only surface — there is no paired project field |
| `domain:{boilerplates,scripts,agent-workflow,standardization,design,project-tracking,delivery}` | humans or agents, at triage | humans, `gh issue list --label` | provisioned; inert | durable classification; the label family is the only surface — there is no paired project field |
| `domain:auth` (**retired**) | nobody — retired | humans, `gh issue list --label` | retired — a generic starter value this repo never needed; no longer provisioned | no issues carry it — delete the live label |
| `domain:billing` (**retired**) | nobody — retired | humans, `gh issue list --label` | retired — a generic starter value this repo never needed; no longer provisioned | no issues carry it — delete the live label |
| `domain:platform` (**retired**) | nobody — retired | humans, `gh issue list --label` | retired — split across this repo's own domains; no longer provisioned | re-label its issues to the repo-specific domains, then delete the live label |
| `area:{ci,docs,deps,build,tests,tasks,release,devcontainer,pm,skills,gauntlet,templates,agents,security,scripts,shepherd,triage,track-work,standardize-repo,design,session-flow,foreman}` | humans or agents, at triage | humans, `gh issue list --label` | provisioned; inert | durable classification; area = solution space, domain = problem space, layer = stack slice |
| `rigor:{light,standard,deep}` | humans, at triage — **never an agent on itself** | agents, when entering the Dev Loop | provisioned; **read by agents** — selects a round-cap level, arms nothing | set when the default budget is wrong for the change; survives the work |
| `tier:{local,economy,standard,frontier,apex,adaptive}` | humans, at triage or planning — never an agent on itself | humans and agents — informational until the tier resolution config ships | provisioned; **informational** — classifies only until resolution semantics ship; arms nothing | set when the default tier would be wrong; strongest-wins resolution once semantics ship |
| `method:{oneshot,plan,plan-approved,orchestrate,council,human-led}` | humans, at triage or planning — never an agent on itself | humans and agents — informational until the method resolution config ships | provisioned; **informational** — classifies only until resolution semantics ship; arms nothing | set when the default method would be wrong; config-backed rank resolution once semantics ship |
| `suggest:<family>` | humans or agents, at planning | humans, the Agent queue view | provisioned from the registry (family level only); advisory — arms nothing | set at planning; survives the work and is never rewritten by a claim |
| `suggest:<family>:<model>` | humans or agents, at planning | humans | **tool-owned, created on demand** — seeding every model would be an unbounded roster | refines the family label; apply both |
| `claim:<family>` | the agent itself — a vendored claim skill, or a Claude Actions run | humans; the Claude Actions claim gate; `claim-release.yml` where the repo ships it | provisioned from the registry; a **gate**, never a trigger | added at claim, removed at release — by the workflow's `always()` step, or by `claim-release.yml` on close where the repo ships it |
| `claim:<family>:<model>` | the agent itself | humans; the Claude Actions claim gate; `claim-release.yml` where the repo ships it | **tool-owned, created on demand** | refines the family label; added at claim, removed at release |
| `agent:<harness>` (**retired**) | nobody — never seeded into a new repo | claim skills (and `claim-release.yml` where present), which still recognize it | legacy; inert | delete once live claims are re-mapped to `claim:*` |
| `foreman:<adapter>` | a trusted human, to arm an issue | Foreman | provisioned from the registry where the repo uses foreman (`--foreman`), for production-dispatchable adapters only; **actor-verified arming** | applied to arm; stays on the issue |
| `foreman:approved` | a trusted human | Foreman | provisioned (`--foreman`); **actor-verified arming** with the repo default backend | applied to arm; stays on the issue |
| `foreman:hold` | a human | Foreman | provisioned (`--foreman`); non-arming and always wins | applied to exclude, removed to re-include |
| `foreman:satisfied` | a human | Foreman's dependency graph | provisioned (`--foreman`); non-arming dependency override | applied per dependency decision |
| `foreman:external` | a human | Foreman's dependency graph | provisioned (`--foreman`); non-arming dependency override | applied per dependency decision |
| `foreman:dispatched` | Foreman, on the draft PR it opens | Foreman, humans | **tool-owned, auto-created** | added when the draft PR opens |
| `foreman:ready-for-review` | Foreman, on passing its readiness gate | Foreman, humans | **tool-owned, auto-created** | added at promotion; the hand-off to human review |
| `type:<commit-type>` | a human, optionally | Foreman, to pick the unit's conventional-commit type | **not provisioned** — an optional override of the native issue `Type` | applied when the native type is absent or wrong |
| `autorelease: pending`, `autorelease: tagged` | release-please | release-please | **tool-owned, auto-created**; note the space after the colon — not part of the `family:value` convention | pending on the open release PR, tagged once the release is cut |
| `duplicate`, `good first issue`, `help wanted`, `invalid`, `wontfix` | GitHub, at repo creation | humans | not provisioned, never deleted by setup | prune by hand if you do not want them |
<!-- label-taxonomy:end -->

One nuance the table compresses: `claim:claude` in a repo with **no label
provisioning at all** is tool-owned in practice — the Claude Actions run
auto-creates it with the registry's own color and description, so a later
provisioning run reconciles it rather than fighting it.

Foreman's PR-side labels are namespaced on purpose: every label Foreman reads
or writes lives under `foreman:`, so the arming inputs and the lifecycle
outputs are one legible namespace. `foreman:ready-for-review` is the accurate
name for what promotion means — the automated work is complete and a human is
now being asked to review it. Approval stays GitHub's native review decision,
and merging stays human-only.

### Agent families and harnesses

Every agent-vocabulary label comes from one machine-readable source,
`agent-registry.json`, validated against `agent-registry.schema.json`. Its two
axes are deliberately distinct: a **family** is the model intelligence doing
the reasoning, a **harness** is the executable that runs it. `suggest:` and
`claim:` name families; `foreman:<adapter>` names harness machinery.

The tables below are **generated** from that file — `task test:registry-docs`
regenerates them and fails on any difference, so they cannot drift from what
provisioning actually creates. Model-level labels are created on demand rather
than seeded. A `foreman:` selector is provisioned only for an adapter that
exists and is production-dispatchable in the pinned Foreman release: a selector
with no adapter behind it is a false capability that can strand armed work.
<!-- registry-tables:begin -->
<!-- Generated from agent-registry.json by `node scripts/agent-registry-labels.mjs docs-tables`. Do not edit by hand — `task test:registry-docs` fails on drift. -->

#### Model families

| Family | Name | Models |
| --- | --- | --- |
| `claude` | Claude | `fable`, `opus`, `sonnet`, `haiku` |
| `gpt` | GPT | `sol`, `terra`, `luna` |
| `mai` | MAI | `code-1-flash`, `thinking-1` |
| `qwen` | Qwen | `max`, `coder-plus`, `coder`, `coder-next`, `coder-30b` |
| `deepseek` | DeepSeek | `v4-pro`, `v4-flash` |
| `glm` | GLM | `5-2`, `4-7-flash` |
| `kimi` | Kimi | `k3` |
| `minimax` | MiniMax | `m3` |
| `gemini` | Gemini | `3-1-pro`, `3-6-flash`, `3-5-flash-lite` |
| `mistral` | Mistral | `devstral-small-2` |

`Model selected by` values:

- `runner-config` — the runner or repository/CLI configuration selects the model; labels do not.
- `workflow-config` — the GitHub Actions workflow input selects the model.
- `provider-wrapper` — the provider-rewired wrapper fixes the family; its runtime configuration selects the model.
- `harness-runtime` — the harness selects the model at runtime; for broker harnesses it selects the provider family too.

#### Harnesses

| Harness | Product | Family | Foreman adapter | Model selected by |
| --- | --- | --- | --- | --- |
| `claude-code` | Claude Code CLI | `claude` | `foreman:claude` — production, dispatchable | `runner-config` |
| `claude-code-action` | claude-code-action | `claude` | — | `workflow-config` |
| `claude-code-deepseek` | Claude Code provider wrapper | `deepseek` | `claude-code-deepseek` — production, not dispatchable, no label | `provider-wrapper` |
| `claude-code-glm` | Claude Code provider wrapper | `glm` | `claude-code-glm` — production, not dispatchable, no label | `provider-wrapper` |
| `claude-code-kimi` | Claude Code provider wrapper | `kimi` | `claude-code-kimi` — production, not dispatchable, no label | `provider-wrapper` |
| `claude-code-minimax` | Claude Code provider wrapper | `minimax` | — | `provider-wrapper` |
| `claude-code-qwen` | Claude Code provider wrapper | `qwen` | — | `provider-wrapper` |
| `claude-code-qwen-local` | Claude Code provider wrapper | `qwen` | — | `provider-wrapper` |
| `codex-cli` | OpenAI Codex CLI | `gpt` | `codex-cli` — production, not dispatchable, no label | `runner-config` |
| `copilot-cli` | GitHub Copilot CLI | any (multi-provider; default `mai`) | — | `harness-runtime` |
| `qwen-code` | Qwen Code CLI | `qwen` | — | `runner-config` |
| `antigravity` | Google Antigravity | `gemini` | — | `harness-runtime` |
| `opencode` | OpenCode | any (multi-provider) | — | `harness-runtime` |
| `pi` | Pi | any (multi-provider) | — | `harness-runtime` |
| `goose` | Block Goose | any (multi-provider) | — | `harness-runtime` |
| `cline` | Cline | any (multi-provider) | — | `harness-runtime` |
<!-- registry-tables:end -->

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
would destroy the planning routing it carries — the signal that narrows the
**Agent queue** view and lanes the board by intelligence — and would erase the
record that work routed to one family was picked up by another.

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

**During the rolling transition, the skills and the label/field provisioning move
on separate clocks.** The vendored `claim` / `shepherd` / `wrap` skills arrive via
`task sync:skills` and already speak `claim:*` / `suggest:*`. Migrating the
*provisioning* to that vocabulary is a separate rollout unit (registry-driven —
harmon-init#661/#663), so until it reaches a given repo, `task setup:github-labels`
still creates the legacy `agent:*` labels and `task setup:github-project` still
creates the retired `Agent` field. The rollout is ordered **skills first**:
harmon-init#663 ships the released devkit whose skills speak `claim:*` before any
live `agent:*` labels are renamed, so the skew a repo actually sees is new skills
against still-legacy provisioning. The skills absorb exactly that direction: a
claim prefers `claim:claude` and falls back to the legacy `agent:claude-code`
label when `claim:*` is not yet provisioned, and the release and stale-claim
sweeps still *recognize* a legacy `agent:*` claim so in-flight work started under
the old vocabulary is not stranded. That read-side recognition is also why a plain grep for the literal
`agent:claude-code` no longer proves a legacy *writer* is installed — the
automation check below accounts for it.

**An already-populated `Agent` field must be migrated before its routing is
trusted elsewhere.** Setup is additive-only — it never deletes the field or
copies its values — so on a board that routed issues through the `Agent` field,
those assignments are not automatically present as `suggest:*` labels. That
migration — backfilling `suggest:*` from existing `Agent` values and then
removing the field and re-keying planning, done safely against triage that is
still writing the field — is owned by the upstream unit harmon-init#662, and
this guide deliberately does not restate its procedure. Until it lands for a
repo, keep reading routing from the `Agent` field there rather than from a
half-migrated `suggest:*` set.

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

**How much a claim prevents depends on who is reading it.** The label is one
string, but it has two very different consumers:

- **Interactive sessions — a signal, not a lock.** None of these writes is
  atomic, and two sessions running as the same GitHub user are invisible to
  each other: the assignee converges, the label is idempotent, and the field is
  last-writer-wins. A claim makes concurrent work discoverable by a human; it
  does not prevent it.
- **The Claude Actions workflows — a fail-closed gate.** A run refuses to
  start on a target that already carries any `claim:*` or `agent:*` label, and
  says which one. That is enforcement, not advice, and it is why a stale claim
  blocks mentions on that issue until somebody removes the label.

The gap between the two is deliberate rather than unfinished: a workflow run
has one entry point to gate, while an interactive session can start anywhere,
so promising a lock there would be a promise the mechanism cannot keep.

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

A merged PR that deliberately uses `Refs` can leave the issue open after a
real partial delivery. No close event exists for automation to consume, so
`/wrap` handles that fourth outcome interactively. It streamlines release only
when a trusted complete claim record, a same-repository merged PR attributable
to the authenticated account, and the absence of a competing open PR or newer
claim activity all agree. The cleanup restores the claim chain's board status
(or a legacy record's direct prior status) instead of setting `Done`, restores
a proven displaced claim label for the still-open issue, removes every
distinct assignee proven claim-owned, and records both what landed and what
remains. Any ambiguous evidence requires maintainer confirmation rather than
an inferred release.

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

### The Claude Actions workflows

`claude-plan.yml`, `claude-implement.yml`, and `claude-review.yml` run Claude
Code on an issue or PR from inside GitHub Actions. Three properties define how
they start, and all three exist because of the label boundary above.

**Mention-only.** The single way a run starts is a comment or review body that
carries an `@claude` mention followed by `plan`, `implement`, or `review`.
There is no label trigger, no `issues: opened`, and no `issues: assigned`
trigger. Every one of those carries no actor the workflow can check on every
path.

**Sender-gated.** The mention only counts from a login on the workflow's
authorized-sender allowlist (the `claude_authorized_members` answer). The
answer is not the whole list: the review workflow additionally authorizes
`renovate[bot]` and `dependabot[bot]` as senders, so their update PRs can request
their own reviews — treat those fixed bot principals as part of the trust
surface when auditing. The allowlist is checked twice — in the job `if:`, and
again in a token-free step that re-asserts it *before* any App token is
minted — so a gap in the expression can never mint a credential.

**Claim-aware, fail-closed.** After the sender gate passes and before the token
is minted, the run acquires `claim:claude` on the target:

| Situation | What the run does |
|---|---|
| Target is unclaimed and the label lands | claims it and runs |
| Event has no issue or PR number | runs unclaimed — there is nothing to collide with |
| Target already carries any `claim:*` or `agent:*` label | **refuses**, naming the held label and the remedy |
| The label list cannot be read | **refuses** — it cannot prove the target is free |
| The label will not apply | **refuses** — it would work the target unmarked |

`suggest:*` is deliberately not matched: it is advice about who *should* do the
work, never ownership of it. The label is created if the repository does not
have it, with the registry's own color and description, so a later
`task setup:github-labels` reconciles that label instead of fighting it.

Release is loud, and bounded. An `always()` step releases the claim — but only
when *this* run acquired it, so a claim that was already there is never stolen.
It covers the failure, step-timeout and cancellation paths, which is why the
model step carries a cap well inside the job's: a job-level timeout kills the
runner outright and the cleanup never runs at all. A release that cannot be
confirmed retries once and then turns the job **red** with the marker still on
the issue, because a release reported as successful over a surviving label
would be permanent — the next run reads the claim, records that it did not
acquire it, and never cleans it either.

It is not a guarantee. Runner loss, a force-cancel, or the job cap firing can
strand `claim:claude` with no cleanup at all, and a stranded claim blocks
further mentions on that target until somebody removes the label by hand. That
residual is accepted rather than reconciled by a workflow of its own.

Because acquiring is a read-then-add, the three workflows share one job-level
`concurrency` group keyed on the target number, so two runs on the same issue
serialize instead of both reading "unclaimed". The group is job-level rather
than workflow-level on purpose: these workflows fire on every comment event and
filter in the job `if:`, so a workflow-level group would let ordinary comments
queue up and displace legitimate runs.

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
- **Agent queue** — board, keyed on **`Status: Agent Queue`** (the shaped-and-
  waiting lane before an agent picks work up), sorted by `Priority`. It may
  additionally filter by the concrete `suggest:<family>` labels you use — Projects
  V2 matches concrete label values, not a `suggest:*` glob, so OR the specific
  labels rather than the family prefix — and it never depends on an `Agent` field.
  To watch agent-routed work *across* the pipeline instead of just the queue lane,
  slice the board by the `suggest:*` / `claim:*` labels (below) rather than
  overloading this view.
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
- **Slice the board** — rather than a separate saved view per product, slice
  the one board by **`Product`** (still a field, so a view can group by it).
  One board, many lenses — how multiple products stay legible in one
  aggregating project instead of fragmenting into project-per-product. Domain
  and Layer are labels only (harmon-init#875): a view can still **filter** on
  `domain:*`/`layer:*` (add the label to the view's filter), it just cannot
  **group** by them the way a field allows — same as the agent split, which is
  a label question too (`suggest:*`/`claim:*` — filter, don't slice).

## Notes

- **Labels vs Type** — `Type` is a first-class, org-level issue field
  (Bug / Feature / Task / Research), separate from labels (see **Labels** above);
  don't reproduce it as a label.
- **Owner**, **Iteration/cycle** — additional fields/axes as the work needs them
  (**Milestones** have their own section above).
- An issue can belong to **multiple projects** — the org project plus a focused
  one is fine.
