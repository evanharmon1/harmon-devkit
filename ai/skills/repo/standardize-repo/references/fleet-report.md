# Fleet report contract

`assets/fleet-report.py` uses Python 3's standard library and requires GitHub CLI
2.94.0 or newer for the issue `parent` JSON field. It renders a per-run fleet
report on the epic and a per-repository report on each tracking issue.
The inventory remains cross-run state; this asset creates no dashboard, issue,
PR, configuration, secret, or readiness decision.

## Commands and ownership

From the standardize-repo skill directory:

```sh
python3 assets/fleet-report.py render --input /path/to/run-report.json
python3 assets/fleet-report.py write --input /path/to/run-report.json
```

`render` prints JSON containing `reports[]` with `issue`, `kind`, and `body`.
It reads the existing targets and, when human tasks are present, resolves their
collector without writing or reopening it. It previews the complete epic and
tracking bodies, including human follow-ups and all prose outside the marked
region. It also checks whether their proposed collector update fits and
shows pending routing when a size refusal prevents confirmation. Follow the guarded
track-work provisioning steps under [Marked regions](#marked-regions). `write` is an
explicit GitHub mutation command: run it only under the parent's authorization
for those targets. It edits existing issue bodies, without changing titles,
labels, claims, PRs, or report input. `--gh /path/to/gh` injects a single
executable path for tests; it is never shell code. GitHub.com issue identities
are explicit `repo` and `number` pairs; this version does not support other hosts.

At **each lane transition** (including planned, working, draft publication,
needs-review, blocked, parked, merge-ready, merged, closed, and no-change), the
lane returns its updated input row to the parent. The parent refreshes the run
snapshot and runs `python3 assets/fleet-report.py write --input /path/to/run-report.json`.
The parent runs that same command again **after its reconcile writes and
re-probes**, including post-merge metadata and image results. Serialize report
writes for one run, including human collector appends, across lanes and owners;
lanes never race to publish the shared epic. This command reports lifecycle
facts supplied by the run; it never grants readiness or derives a handoff check.

Exit 0 means render succeeded, or all requested writes were confirmed (including
unchanged bodies). Exit 2 means invalid input, refused identity, an oversized
body, failed read or write, or mismatched readback. `write` measures each full
proposed body against GitHub's 65,536-character limit, counted in Unicode
code points, before its first mutation.
It skips oversized edits and reports their issue identities and sizes after
publishing the remaining eligible bodies. It also skips reopening a completed
collector when the proposed body already exceeds the limit. GitHub has no
multi-issue transaction. Retry incomplete publication from the same complete
input after fixing the cause. Fresh reads and task identities avoid duplicate
publication.

With typical repository names, the epic reaches the ceiling at about 162
repositories and the collector at about 306. With maximum-length owner and
repository names, the estimates are about 61 and 99 respectively. Preserved
prose, the rebuild queue and other report content can lower either ceiling.
Beyond the ceiling, the overflow diagnostic names the skipped issue.

## Input version 1

The parent projects its run record, lane evidence and probe results into this
JSON snapshot. Keep it outside shipped assets and omit credentials, secret
values and private inventory paths. Reconcile and devcontainer producers need
only supply the optional arrays below; they do not need a new reporting writer.
Array order is retained for answers, non-adoption and probes; repositories and
collector owners are sorted by repository/owner for a deterministic report.
There are no generated timestamps.

```json
{
  "version": 1,
  "run": {
    "release": "v9.0.0",
    "epic": {"repo": "example/fleet", "number": 10}
  },
  "rebuild_queue": [
    {"wave": 1, "workspace": "example-workspace", "command": "devcontainer up --workspace-folder /workspace"}
  ],
  "repositories": [
    {
      "repository": "example/app",
      "tracking_issue": {"repo": "example/app", "number": 20},
      "pr": 21,
      "head": "0123456789abcdef0123456789abcdef01234567",
      "state": "working",
      "answers_changed": [
        {"key": "devcontainer", "before": false, "after": true}
      ],
      "non_adoption": ["Keep the repository's custom deployment task"],
      "non_adoption_count": 1,
      "skills_pin": {
        "repository": "example/app",
        "open_sync_prs": [],
        "pin": "v1.0.0",
        "minimum": "v1.0.0",
        "latest": "v2.0.0",
        "verdict": "ok",
        "pin_lag": "behind v2.0.0",
        "ruling": "merge-first",
        "planned_action": {"sync_prs": "none", "pin": "leave", "target": null}
      },
      "reconcile": [
        {"item": "repo-settings", "probe": "matches", "action": "none", "class": "agent-apply"},
        {"item": "ci-app", "probe": "token mint failed", "action": "pending", "class": "human-only", "task": "Install the CI App"}
      ],
      "devcontainer": [
        {"item": "definition", "probe": "rendered", "action": "none", "class": "observation"},
        {"item": "image", "probe": "workflow-run conclusion: success; push: unknown: push not observable without the packages scope", "action": "none", "class": "observation"},
        {"item": "workspace", "probe": "stale", "action": "rebuild queued: run the workspace rebuild command", "class": "human-only", "task": "Rebuild the workspace after the wave merges"}
      ],
      "post_merge_metadata": "pending merge"
    }
  ]
}
```

- `version`, `run.release`, `run.epic`, and nonempty `repositories` are required.
  A run is identified by the epic's repository and number; one epic per run.
- Each row requires a unique `repository`, its same-repository `tracking_issue`,
  and `state`. References use positive issue numbers and `owner/name` strings.
  The epic and tracking targets must all differ. No repository is inferred from
  the shell's current directory or gh defaults.
- `state` is one of `planned`, `working`, `draft`, `needs-review`, `parked`,
  `merge-ready`, `merged`, `closed`, `blocked`, `no-change`. These are report
  values, not a second set of labels. `pr` is a positive PR number or null;
  `head` is a full lowercase 40-hex commit SHA or null. Absent values mean no PR
  or head evidence, not a successful check.
- `answers_changed` defaults to an empty array. Entries require `key`, `before`
  and `after`; values can be JSON scalars or structures, escaped for Markdown.
  Exclude sensitive answers before supplying the snapshot.
- `non_adoption` defaults to an empty string array; the count is derived from
  it. If `non_adoption_count` is supplied, it must equal the list length.
- `skills_pin` accepts the repository's JSON object from
  `assets/skills-sync-preflight.sh` unchanged, or null/absent for `not run`.
  The report summarizes pin, minimum, latest, lag, verdict, ruling, planned
  action and reason. The producer owns its preflight verdict.
- `reconcile` and `devcontainer` are optional arrays. Absent or empty arrays
  render **not run**. Every row has unique `item` text within its array and
  nonempty `probe`, `action`, `class` text. Include empirical evidence in
  `probe`, actual action or pending status in `action`, and the classified
  producer value in `class`. `human-only` also requires a nonempty `task`.
  Devcontainer rows carry definition, CI verification and required-check status,
  the devcontainer-build workflow run conclusion for the merged head, workspace
  staleness and rebuild command as available. The conclusion does not by itself
  prove an image was built. This asset performs no probes or rebuilds itself.
- `rebuild_queue` is an optional array projected by the parent from every
  workspace named by the decisions file. Each unique workspace has a positive
  `wave` and a nonempty `command`. The epic sorts by wave, then workspace,
  and shows each command verbatim in GitHub’s rendered view for the maintainer to run after that wave merges.
  A rebuild command must be a single line and cannot contain control characters.
  Commands render as code spans; the report never executes them.
- `assets/devcontainer-probe.sh --repo OWNER/NAME --checkout PATH --head SHA
  --base DEFAULT_BRANCH [--merged-head SHA] [--gh EXECUTABLE]` emits the
  `devcontainer` array. It reads head checks, effective branch rules and, after
  merge, the devcontainer-build workflow run conclusion for the exact merged head;
  missing or unreadable evidence is unknown. Push is always unknown because it is
  not observable without the packages scope. It makes no
  GitHub writes and needs no packages scope. The checkout must contain the
  named commits. The staleness row reports whether its comparison can run, not
  whether the running image is fresh.
- `post_merge_metadata` is optional nonempty text; absent renders `not run`.
  It reports pending/completed/failed metadata work without implying PR readiness.

The epic's Reconcile column contains per-repository counts for pass, fail,
manual, unknown, not run, and other outcomes when present. The linked tracking
issue carries the full set of rows and evidence.

## Reconcile probe

Run the probe in the target's trusted checkout with Python 3 and go-task.
For a standalone probe, from the standardize-repo skill directory:

```sh
assets/reconcile-probe.sh "$TARGET" > "$RECONCILE_ROWS"
```

With the applied-state verifier, pass `--reconcile-output "$RECONCILE_ROWS"`
to capture the same array and keep the advisory from the same ruleset run.
Use a scratch output file outside the target and copy its JSON array into the
repository's `reconcile` field. Retain the probe's stderr separately when the
gap report needs the full ruleset diff.

The probe calls the target's `audit:github` without task arguments and
`audit:ruleset` when available. It reads `checklist-classes.json` in that
checkout. A checklist row preserves its catalog class and the audit outcome
and reason. A failed item with a catalog write task is `pending`. Other
items use `none`. Human-only items use the catalog write task or its checklist
label as the task text. Passing human-only rows stay in the report and do not
create collector tasks. The ruleset comparison reports one observation row
with the outcome and, for drift, the number of added and removed diff lines.

Manual and unknown results retain those outcomes. Audit exit 2 or an incomplete
or inconsistent result adds an unknown run observation. The probe checks for the
target catalog before running the audit task and reports a missing catalog as
unknown. A missing audit task reports `not run`. If the probe cannot produce an
array, report it as `not run`. The probe makes no GitHub write. The lane returns
rows to the parent.

## Marked regions

Each delimiter occupies its own line and follows
`<!-- fleet-report:<owner>/<repo>#<N>:<section>:begin|end -->`, with lowercase
owner and repository names (letters, digits, underscores, periods, and hyphens),
a positive decimal issue number without leading zeros, and section
`fleet` or `repository`.

1. Create the epic through track-work with its normal authoring check and
   receipt verification. Use GitHub's returned issue number in the epic's
   marker pair.
2. Add that pair to the epic body. Run track-work's authoring check on the
   full proposed body with the epic's current title and metadata, then verify
   the receipt against `gh issue edit <epic-number> --repo <owner/repo> --body-file <draft>`.
   Run that edit with the same body file after receipt verification passes.
3. Include the repository marker pair in each tracking issue draft before
   running its track-work authoring check and receipt-backed create. Use
   the epic's repository and number even when the tracking issue lives in
   a different repository.

The epic body must contain exactly one pair of standalone marker lines:

```markdown
<!-- fleet-report:example/fleet#10:fleet:begin -->
<!-- fleet-report:example/fleet#10:fleet:end -->
```

Every tracking issue uses that same epic identity with `repository` as kind:

```markdown
<!-- fleet-report:example/fleet#10:repository:begin -->
<!-- fleet-report:example/fleet#10:repository:end -->
```

`write` checks all report marker pairs and complete proposed bodies before any
mutation. It re-reads each epic or tracking body immediately before its edit
and refuses a body that changed since preflight. Missing, repeated, reversed
or inline delimiters refuse publication. The regenerated region includes only
its own delimiters and content, preserving prose, criteria and trailing
newlines outside it. A byte-identical result makes no edit. Each edit is read
back and compared exactly. Serialize publishers because GitHub body replacement
is last-write-wins.

## Human-only routing

The parent follows track-work's **Human tasks go to a collector** procedure.
Before publication, lazily provision the epic's `(HUMAN):` collector through
that procedure if one does not yet exist, including full metadata, `human` and
`umbrella`, the scope's milestone and epic sub-issue relationship. This
reporter updates an existing collector. A missing collector fails with that
provisioning instruction before any report writes.

Discovery lists both states in the epic's repository and matches the
`Collector scope: milestone N` line when the epic has a milestone; otherwise
`Collector scope: owner/repo#N` (repository identity is case-insensitive).
Open matches take precedence. With no open match, select the most recently
completed closed match. Reopen a completed collector when the proposed body
contains a pending criterion. Otherwise preserve its state. Multiple open
matches refuse publication for track-work to reconcile. A saturated listing is
indeterminate. A collector
must retain its title prefix, scope, labels and milestone (or epic parent URL)
on the fresh read. It cannot be the epic or a tracking issue.

The collector has one reporter-managed criterion per repository with human
follow-ups, grouped under `### owner` headings within `## Acceptance criteria`.
The entry is rewritten in place with the current count and tracking issue
link, including a zero count after all tasks pass. Its hidden `fleet-human`
marker binds a stable repository key and the current task-set digest. Keep
the marker when editing the collector. A tick survives only when the rendered
line is identical apart from the checkbox value. Growth and shrink both make
the existing entry pending, so a task beginning to pass can reopen a completed
collector for the human to confirm the new set.

Existing per-task collector rows, including human ticks, stay in place. Their
tasks are recognized by the original marker or the normalized task text and
trailing `(from <source>)`, including the older `(from owner/repo#N; item: X)`
form. Embedded `(from …)` text is part of the task. Matching removes Markdown
escapes, collapses whitespace, and resolves local `#N` sources against the
collector repository. Repository identities compare case-insensitively.
A missing or repeated `## Acceptance criteria` section refuses publication.
The collector body must use a restricted line format: blank lines, plain prose
outside the section, `##` headings, simple `### owner` headings, and task lines.
Ambiguous syntax, including fences, HTML, indented or tabbed headings, setext
underlines and thematic breaks, refuses with a line number before any write.
Move such content out of the collector or simplify it before retrying; the
reporter does not attempt to interpret arbitrary Markdown boundaries. Appends
preserve consistent LF or CRLF line endings; mixed line endings are refused.
Only the human completes a task. The input producer retains reported human
rows for the run and updates their probe and action to describe repaired
state. The tracking issue still shows passing rows as probe evidence.

The tracker publishes the task details before the collector changes its line
to name that set. While its line is pending publication, the tracker uses
**publication pending** under `### Out of scope`. The reporter switches this
to **Human follow-up (tracked in owner/repo#N)** after it confirms the
collector line. An unchanged, confirmed line allows the tracker to keep its
routed wording. An oversized or failed initial tracking edit leaves that
repository's collector line intact. If a collector edit exceeds the limit,
affected trackers keep their pending routing. A reopen triggers a fresh read
and size check before the collector body edit. A retry uses current issue
bodies and changes only what still needs publication. Missing collectors,
permission failures, ambiguous scope and readback failures are reported.
