# Fleet report contract

`assets/fleet-report.py` uses Python 3's standard library. It renders a per-run
fleet report on the epic and a per-repository report on each tracking issue.
The inventory remains cross-run state; this asset creates no dashboard, issue,
PR, configuration, secret, or readiness decision.

## Commands and ownership

From the standardize-repo skill directory:

```sh
python3 assets/fleet-report.py render --input /path/to/run-report.json
python3 assets/fleet-report.py write --input /path/to/run-report.json
```

`render` prints JSON containing `reports[]` with `issue`, `kind`, and `body`.
It makes no GitHub calls. Its bodies contain the delimiters to seed when the
parent creates the epic and tracking issues through track-work. `write` is an
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
unchanged bodies). Exit 2 means invalid input, refused identity, failed read or
write, or mismatched readback. Stop the affected publication and report the
error; never treat it as a green report. A partial write is possible: GitHub
has no multi-issue transaction. Retry from the same complete input after fixing
the cause; fresh reads and task identities avoid duplicate publication. A failed
write is never compensated by deleting content.

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
        {"item": "image", "probe": "build succeeded and pushed on merged head", "action": "none", "class": "observation"},
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
  default-branch image head/build result, workspace staleness and rebuild command
  as available. This asset performs no probes or rebuilds itself.
- `post_merge_metadata` is optional nonempty text; absent renders `not run`.
  It reports pending/completed/failed metadata work without implying PR readiness.

## Marked regions

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

`write` preflights all report marker pairs before any mutation, then re-reads
the live issue body immediately before each edit. Missing, repeated, reversed
or inline delimiters refuse the edit. The regenerated region includes only its
own delimiters and content; all bytes outside it are retained, including human
prose, acceptance criteria and trailing newlines. A byte-identical result makes
no edit. Every edit is read back and compared exactly. GitHub body replacement
is last-write-wins: serialize publishers; the fresh-read/readback contract is
not an atomic compare-and-swap guarantee.

## Human-only routing

The parent follows track-work's **Human tasks go to a collector** procedure.
Before publication, lazily provision the epic's `(HUMAN):` collector through
that procedure if one does not yet exist, including full metadata, `human` and
`umbrella`, the scope's milestone and epic sub-issue relationship. This reporter
appends to an existing collector; it does not synthesize an issue draft or
bypass the metadata/approval guard to create one. A missing collector fails with
that provisioning instruction before any report writes.

Discovery lists both states in the epic's repository and matches the exact
`Collector scope: milestone N` line when the epic has a milestone; otherwise
`Collector scope: owner/repo#N`. Open matches take precedence. With no open match,
the most recently completed closed match is reopened; duplicate/not-planned
closures are never reopened. Multiple open matches refuse publication for
track-work to reconcile. A saturated listing is indeterminate. A collector
must retain its title prefix, scope, labels and milestone (or epic parent URL)
on the fresh read. It cannot be the epic or a tracking issue.

Human tasks are unchecked criteria under `### owner` headings within
`## Acceptance criteria`. Each carries the source tracking issue, probe evidence,
item name and a stable hidden `fleet-human` identity derived from source and task.
Repeated snapshots, updated probe evidence, or an existing human tick never
append that task twice or untick it. Preserve the hidden identity on manual edits.
Only the human completes a task; this asset never ticks or removes criteria.
The input producer retains reported human rows for the run so their tracking
issue source lines remain visible even after the probe is repaired; update their
probe/action values to describe the repaired state instead of dropping history.

The collector append is confirmed first. The tracking report then includes a
plain **Human follow-up (tracked in owner/repo#N)** source line under its human
out-of-scope section, never an acceptance checkbox. A failed source edit can be
retried without another collector append. Missing collector, permission failure,
ambiguous scope and readback failure remain explicit publication failures.
