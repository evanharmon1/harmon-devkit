---
name: wayfinder
description: Plan a huge chunk of work — more than one agent session can hold — as a shared map of decision tickets on your issue tracker, and resolve them one at a time until the way to the destination is clear.
disable-model-invocation: true
---

> Originally written by Matt Pocock and redistributed under the MIT License.
> See [UPSTREAM.md](UPSTREAM.md) for provenance and local modifications.

A loose idea has arrived — too big for one agent session, and wrapped in fog: the way from here to the **destination** isn't visible yet. Wayfinding is about finding that way, not charging at the destination. This skill charts the way as a **shared map** on the repo's issue tracker, then works its **decision tickets** — questions whose resolution is a decision, not slices of a build to execute — one at a time until the route is clear.

The destination varies per effort, and naming it is the first act of charting — it shapes every ticket. It might be a spec to hand off and iterate on, a decision to lock before planning starts, or a change made in place like a data-structure migration. The map is domain-agnostic — engineering work, course content, whatever fits the shape.

## Plan, don't do

Wayfinder is **planning** by default: each ticket resolves a decision, and the map is done when the way is clear — nothing left to decide before someone goes and does the thing. The pull to just do the work is usually the signal you've reached the edge of the map and it's time to hand off. An effort can override this in its **Notes** — carrying execution into the map itself — but absent that, produce decisions, not deliverables.

## Refer by name

Every map and ticket is an issue, so it has a **name** — its title. In everything the human reads — narration and map events — refer to it by that name, never by a bare id, number, or slug. A wall of `#42, #43, #44` is illegible; names read at a glance. The id and URL don't vanish — a name wraps its link — but they ride _inside_ the name, never stand in for it.

## The Map

The map is a single issue on this repo's issue tracker, labelled `wayfinder:map` — the canonical artifact. Its tickets are child issues of the map.

The map is an **index**, not a store. It lists the decisions made and points at the tickets that hold their detail; a decision lives in exactly one place — its ticket — so the map never restates it, only gists it and links.

**Where the map, its child tickets, blocking, and frontier queries physically live is tracker-specific.** The issue tracker should have been provided to you. If not, tell the user to run `/setup-matt-pocock-skills`. Consult the tracker doc's "Wayfinding operations" section for how _this_ repo expresses them. If no tracker has been provided, default to the local-markdown tracker.

### The map body

The map body is an immutable starting snapshot after creation. Never rewrite it
during ticket resolution. Decisions, fog changes, and scope changes are
append-only **map event comments** that link the affected tickets; the current
view is derived from that event log plus child-ticket state. This avoids a
cross-tracker locking protocol and prevents concurrent sessions from erasing
one another's map edits. Trackers without atomic append, including the local
Markdown format, are explicitly single-writer. Research workers may run
concurrently only as read-only helpers that return artifacts to their ticket's
session. Open tickets are **not** listed — they are open child issues, found by
query.

```markdown
## Destination

<what reaching the end of this map looks like — the spec, decision, or change this effort is finding its way to. One or two lines; every session orients to it before choosing a ticket.>

## Notes

<domain; skills every session should consult; standing preferences for this effort>

## Decisions so far

<!-- immutable at creation; subsequent decisions are append-only map event comments -->

## Not yet specified

<!-- see "Fog of war": in-scope fog you can't ticket yet; graduates as the frontier advances -->

## Out of scope

<!-- see "Out of scope": work ruled beyond the destination; closed, never graduates -->
```

### Tickets

Each ticket is a **child issue** of the map; the tracker's issue id is its identity. Its body is the question, sized to one 100K token agent session:

```markdown
## Question

<the decision or investigation this ticket resolves>
```

Each ticket carries a `wayfinder:<type>` label — one of `research`, `prototype`, `grilling`, `task` (see [Ticket Types](#ticket-types)).

The active writer marks its selected ticket claimed before work so ownership is
visible. Release the claim when abandoning or failing the work. If a claim from
an earlier session remains, ask the maintainer whether to reclaim it before
continuing; never infer that a stale-looking claim is abandoned.

Blocking uses the tracker's **native** dependency relationship — essential because it renders the frontier _visually_ in the tracker's own UI, so the human sees what's takeable without opening the map. Only a tracker that lacks native blocking falls back to a body convention. A ticket is **unblocked** when every ticket blocking it is closed; the **frontier** is the open, unblocked, unclaimed children — the edge of the known.

The answer isn't part of the body — it's recorded on resolution (see [Work through the map](#work-through-the-map)). Assets created while resolving a ticket are linked from the issue, not pasted in.

## Ticket Types

Every ticket is either **HITL** — human in the loop, worked _with_ a human who speaks for themselves — or **AFK**, driven by the agent alone. A HITL ticket only resolves through that live exchange; the agent never stands in for the human's side of it (a grilling agent that answers its own questions has broken this).

- **Research** (AFK): Reading documentation, third-party APIs, or local resources like knowledge bases to surface a fact a decision waits on. Resolved by a subagent that loads and follows the `research` skill. Use when knowledge outside the current working directory is required.
- **Prototype** (HITL): Raise the fidelity of the discussion by making a cheap, rough, concrete artifact to react to — an outline, a rough take, a stub, or UI/logic code, by loading and following the `prototype` skill. Links the prototype as an asset. Use when "how should it look" or "how should it behave" is the key question.
- **Grilling** (HITL): Conversation. The default case. Always load and follow both the `grilling` and `domain-modeling` skills.
- **Task** (HITL or AFK): Manual work that must happen before a _decision_ can be made — nothing to decide, prototype, or research, but the discussion is blocked until it's done. Signing up for a service so its API can be judged, provisioning access, moving data so its shape can be seen. This is the one type that _does_ rather than decides — and it earns its place by unblocking a decision, not by delivering the destination. The agent may drive a reversible, already-authorized task alone; any permission change, paid resource, credential operation, destructive action, or external data mutation requires a concrete plan and the user's explicit confirmation first. Otherwise it hands the human a precise checklist (HITL). Resolved when the work is done; the answer records what was done and any resulting facts (credentials location, new URLs, row counts) later tickets depend on.

## Fog of war

The map is _deliberately_ incomplete: don't chart what you can't yet see. Beyond the live tickets lies the **fog of war** — the dim view of decisions and investigations you can tell are coming but can't yet pin down, because they hang on questions still open. Resolving a ticket clears the fog ahead of it, graduating whatever's now specifiable into fresh tickets — one at a time, until the way to the destination is clear and no tickets remain.

The map's **Not yet specified** section is where that dim view is written down: the suspected question, the area to revisit later. It's the undiscovered frontier _toward_ the destination — everything here is in scope, just not sharp enough to ticket. Write as loosely or as fully as the view allows; it doubles as a signpost for collaborators reading where the effort is headed.

**Fog or ticket?** The test is whether you can state the question precisely now — _not_ whether you can answer it now.

- **Ticket when** the question is already sharp — even if it's blocked and you can't act on it yet.
- **Not yet specified when** you can't yet phrase it that sharply. Don't pre-slice the fog into ticket-sized pieces: it's coarser than a ticket, and one patch may graduate into several tickets, or none, once the frontier reaches it.

The effective fog excludes anything a later map event marks decided,
graduated into a live ticket, or out of scope.

## Out of scope

Fog only ever gathers _toward_ the destination. The destination fixes the scope, so work beyond it is **out of scope** — it isn't fog, and it doesn't belong in **Not yet specified**. It gets its own **Out of scope** section on the map: work you've consciously ruled out of _this_ effort. Scope, not sharpness, lands it here.

Out-of-scope work never graduates — the frontier stops at the destination — so it returns only if the destination is redrawn, and then as a fresh effort, not a resumption.

Ruling something out of scope is a scoping act, not a step on the route. When a ticket that already exists turns out to sit past the destination — mis-scoped in while charting, or exposed by a resolution — **close it** (a closed ticket is unambiguously off the frontier) and append an out-of-scope map event with the gist and reason, linking the closed ticket. It is not a decision event, because a scope boundary is not a step on the route.

## Invocation

Two modes. Either way, **never resolve more than one ticket per session** — with the exception of research tickets.

### Chart the map

User invokes with a loose idea.

1. **Name the destination.** Load and follow both the `grilling` and `domain-modeling` skills to pin down what this map is finding its way to — the spec, decision, or change. The destination fixes the scope, so it's settled first.
2. **Map the frontier.** Grill again, **breadth-first** this time: fan out across the whole space rather than deep on any one thread, surfacing the open decisions and the first steps takeable now. **If this surfaces no fog** — the way to the destination is already clear, the whole journey small enough for one session — you don't need a map. Stop and ask the user how they'd like to proceed.
3. **Create the map** (label `wayfinder:map`) with a deterministic publication key derived from its destination. Search for and reconcile that key before creating anything, so an ambiguous success can be resumed without a duplicate. Fill Destination and Notes, leave Decisions-so-far empty, and sketch the fog into **Not yet specified**.
4. **Create the tickets you can specify now** with deterministic keys derived from the map key and ticket question. Reconcile each key before creation. Create them as child issues of the map with the tracker's non-frontier `wayfinder:staging` state — then wire blocking edges in a **second pass** (issues need ids before they can reference each other). Only after every child link and blocking edge succeeds, remove `wayfinder:staging` from the whole batch. On partial failure, leave every affected ticket staged, record the identifiers that were created, and resume by key rather than publishing duplicates. Wiring sorts them into the frontier and the blocked; everything you can't yet specify stays in the fog — the **Not yet specified** section.
5. Stop — charting is one session's work; it hand-resolves nothing. Research
   tickets run later through the normal work-through flow, where their returned
   artifacts can be published and linked before resolution.

### Work through the map

User invokes with a map (URL or number). A ticket is **optional** — without one, you pick the next decision, not the user.

1. Load the **map** snapshot and its append-only event comments — the low-res
   view, not every ticket body.
2. Choose the ticket. If the user named one, use it. Otherwise take the first frontier ticket in order. **Claim it** before any work.
3. Resolve it — **zoom as needed**: fetch the full body of any related or closed ticket on demand; load and follow whichever skills the `## Notes` block names. If in doubt, load and follow both the `grilling` and `domain-modeling` skills.
4. Record the resolution answer without closing the ticket yet. Add newly-surfaced tickets (create-stage-wire-publish); when fog becomes specifiable, create its keyed tickets and append a map event naming what graduated instead of rewriting the original fog text. If the answer reveals a ticket — this one or another — sits beyond the destination, close or cancel it with a rationale and append an out-of-scope map event. If the decision invalidates another ticket, close or cancel it with a rationale so its history remains; actual deletion requires the user's explicit confirmation. Append one decision event with the resolved ticket's link and one-line gist. Never replace the map body.
5. Verify the map, new dependency edges, invalidations, and graduated fog are all durably published. Only then **close** the resolved ticket, which exposes its dependents to the frontier. If any derived write fails, leave the ticket open and claimed so stale dependent work cannot start, then report the partial state for recovery.

For remote trackers whose comments and issue creation are atomic appends,
different unblocked tickets may run in parallel. The local-Markdown tracker is
single-writer; finish one session before another continues its map.
