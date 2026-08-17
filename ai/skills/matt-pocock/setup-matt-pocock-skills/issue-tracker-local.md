# Issue tracker: Local Markdown

Issues and specs for this repo live as markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The spec is `.scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01` — never a single combined tickets file
- Triage category is recorded as a `Category:` line (`bug` or `enhancement`)
  and state is recorded separately as a `Status:` line near the top of each
  issue file (see `triage-labels.md` for the mapped role strings)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/` (creating the directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the issue number directly.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `.scratch/<effort>/map.md` — the Notes / Decisions-so-far / Fog body. Before changing it, acquire an exclusive repository-local writer lock, record a hash of the version read, and replace it atomically only if that hash is unchanged. If the environment cannot provide those guarantees, serialize map changes through one writer instead of permitting parallel edits.
- **Child ticket**: `.scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records the ticket type (`research`/`prototype`/`grilling`/`task`); a `Status:` line records `claimed`/`resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every file it lists is `resolved`.
- **Frontier**: scan `.scratch/<effort>/issues/` for files that are open, unblocked, and unclaimed; first by number wins.
- **Claim**: under the same exclusive-write rule, set `Status: claimed` plus
  timestamped owner metadata, save, re-read, and proceed only if this session
  is the single recorded owner.
- **Resolve**: append the answer under an `## Answer` heading, publish and
  verify the derived map/ticket changes, then set `Status: resolved` last.
