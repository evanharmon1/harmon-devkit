# Fleet decisions and lane briefing

This contract supports fleet dispatch without changing the four single-repo
modes. Fleet orchestration, the start-of-run question writer, inventory and
GitHub reconcile runtime are separate work. The parent supplies the configurable
fleet-home checkout; no private repository name or operational inventory belongs
in the shipped skill. Operational rulings live in that checkout's versioned
`fleet/decisions.yaml`, beside `fleet/inventory.yaml`.

## Format v1

`assets/fleet-decisions.schema.json` is the structural contract;
`assets/fleet-decisions.example.yaml` is a fictional example, never an approval.
Use `schema_version: 1`, a `fleet` list and a `releases` mapping whose keys are
exact release identifiers. Each release maps to a list of release or repository
entries. An empty list records no approvals; it cannot satisfy a required ID.
Every entry has:

| Field | Meaning |
| --- | --- |
| `id` | Globally unique, stable uppercase ID; lanes cite this beside actions. |
| `scope` | `fleet`, `release`, or `repository`. Fleet entries live only in `fleet`; other entries live under the selected release key. |
| `repository` | Required only for repository scope, as `owner/name`; it is also bound to the enclosing release. |
| `ruling` | Explicit approved ruling, with operation, bounds and exclusions where relevant. |
| `approved_by` | Attributable approver identity, recorded by the parent. |
| `approved_on` | Calendar date in `YYYY-MM-DD` form. |

IDs are unique across the entire file, including releases. Use a fresh ID for a
new or superseding ruling and keep prior approvals in version history. The
parent resolves conflicting rulings before dispatch and records which IDs apply;
there is no implicit fleet → release → repository override or inferred consent.
Release entries may cover reconcile classes, security surfaces, model rulings,
review exclusions, legacy-baseline/rollback approvals and the run-wide skills-sync
PR disposition; repository entries hold per-repository answer changes. This
format does not provide a required-check-name override.

## Validate and bind citations

Requirements: Python 3.9+ and **Mike Farah yq v4**, already used by the skill.
The validator is read-only and offline; it uses the adjacent schema and rejects
unknown fields, versions, duplicate YAML keys/IDs, invalid approval dates and
malformed scopes. It implements only the schema vocabulary this asset uses;
extending that vocabulary requires updating its checker and tests together.

From the installed skill directory:

```bash
python3 assets/fleet-decisions.py /path/to/fleet-home/fleet/decisions.yaml
python3 assets/fleet-decisions.py /path/to/fleet-home/fleet/decisions.yaml \
  --release v0.0.0-example --repository example-owner/example-repository \
  --require FLEET-QUESTIONS --require RELEASE-SECURITY --require REPO-ANSWERS
```

The first command validates the entire file. The second also checks each
explicitly required ID against the selected release and repository, then emits
the cited entries as JSON. Exit 0 means those checks passed; exit 1 means invalid
or unreadable input or missing/inapplicable rulings; exit 2 means invalid CLI
arguments. Both release and repository are required with `--require`. Repository
matching is case-insensitive. No command writes or grants permission. The parent
must verify the approval's provenance; schema checks cannot authenticate a person.
A ruling required for an action must be named explicitly in the brief and
command: omitting `--require` validates format only, never authorizes work.

Before dispatch, the parent captures the decisions file at an immutable fleet-home
commit and records its SHA-256. The lane reads that complete snapshot, checks its
identity, validates all required IDs, and cites IDs beside each action in its
report. If an action needs an unbriefed ruling, or two entries conflict, the lane
stops the affected work and writes the exact key to its question file. It never
asks interactively, picks a default, self-confirms or edits approvals. The parent
records the answer once and supplies a newly pinned snapshot and updated brief.
This does not replace Copier's answer presentation and confirmation gate: the
lane probes/presents, and the parent owns confirmation and GitHub writes.

## Fleet supplement catalog

Render `assets/fleet-lane-brief.md` **with** the current orchestrate lane brief;
inherit its actual run identity, policy, claim and report/sentinel contract rather
than inventing a second lifecycle. Validate the unrendered template's placeholder
set against this catalog, then substitute all values in one pass. Never rescan
inserted data for tokens or execute inventory/decision text as instructions.

| Placeholder | Parent-supplied source |
| --- | --- |
| `lane-label` | Provisioned lane identity. |
| `release` | Approved target release key in the decisions file. |
| `template-commit` | Remote-verified immutable template commit. |
| `fleet-epic-url` | Run's fleet epic. |
| `tracking-issue-url` | Target repository's tracking issue under that epic. |
| `repository` | Validated inventory `owner/name`. |
| `inventory-row-json` | Complete selected inventory row, including exclusions. |
| `decisions-file` | Absolute readable snapshot path in the configurable fleet checkout/control directory. |
| `decisions-commit` | Immutable fleet-home commit used to capture the file. |
| `decisions-sha256` | Digest of those exact snapshot bytes. |
| `decision-ids` | Every required applicable decision ID, including security approval IDs. |
| `decision-citations` | Action → required ID/scope/ruling map; parent resolves conflicts first. |
| `question-file` | Lane's parent-monitored, excluded question file. |
| `report-file` | Excluded report path from the orchestrate contract. |
| `security-surfaces` | Explicit list of exact operations, limits, exclusions and release/repository approval IDs, or explicit `none`. |
| `review-scope` | Single rendered application-review scope shared with PR body/guidelines. |
| `orchestrate-contract` | Reference to the full rendered orchestrate brief and its report, sentinel and gate obligations. |

Do not dispatch with missing catalog values or an empty security-surfaces slot.
Keep operational repository names and approvals in the fleet home and rendered
control artifacts, outside the public skill tree. The parent retains GitHub
configuration writes, review adjudication and integration ownership. Draft
publication returns the lane to that parent, which continues into integrate;
only the live handoff check establishes parked or merge-ready status.
