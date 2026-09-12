# Skills pin policy: keeping the vendored pin and `.devflow.toml` in step

Dev flow v2's stage skills — `/review`, `/integrate`, `/orchestrator` — operate
under a `schema_version = 2` `.devflow.toml` **and under nothing else**. They
carry no interpreter for the pre-v1 legacy shape (round caps directly on
`[rigor.<level>]`, plus `default_method` and `[method]`) or the v1 shape
(`rigor_order`, `[review.*]`, and the `[rigor.<level>].review` pointers), and
they never resolve one by hand: the shared reader `scripts/devflow-policy.mjs`
refuses an older shape with one actionable message
(harmon-devkit#604, `openspec/changes/dev-flow-v2` task 5.1).

That is a deliberate end to a compatibility layer, and it creates one problem
this guide answers: **skills sync and `copier update` run on independent
cadences**, so a repository can hold either half of the migration without the
other.

## The rule

> An unmigrated consumer stays on the last **pre-v2** skills release pin until
> its `.devflow.toml` migrates. Then, and only then, it advances the pin.

Read in order:

1. The repository's `.devflow.toml` is still legacy or v1. **Hold the pin.**
   Advancing it would vendor skills that refuse every run. The fix is
   `copier update`, not a skills bump.
2. `copier update` lands the `schema_version = 2` template (harmon-init
   v4.43.0 or later — the release carrying harmon-init#1159/#1167, which
   implement harmon-init#1081). **Now advance the pin**: bump `source.ref` in
   `.skills-sync.yaml` to a harmon-devkit release that ships the version-2
   stage skills, then run `task sync:skills` and commit.
3. Both halves migrated. Nothing to do until the next release.

Never advance the pin to get past a refusal, and never hand-decode a policy the
reader rejected. The refusal is the correct answer for a repository in state 1.

## The audit

`scripts/consumer-pin-audit.sh` reports which state a repository is in and
refuses both directions of skew:

```sh
task audit:consumer-pin                          # this repository
task audit:consumer-pin -- --repo-root ../other --json
```

It reads three things and compares them:

- **the pin actually vendored** — the `# ref:` line of
  `<dest>/.SKILLS_PROVENANCE`, which outranks `source.ref` in the manifest
  because anyone can edit the manifest without re-running the sync;
- **what those skills require** — the single `policy_schema_version` that every
  *managed* skill's `assets/policy-contract.json` agrees on (a set declaring
  two different versions is refused as indeterminate, not resolved to either).
  Only directories on
  the provenance `# managed:` line count, so a local skill (or, in
  harmon-devkit itself, a `.claude/skills/<name>` symlink into `ai/skills/`) is
  correctly excluded. A pre-Dev-flow-v2 skill ships no contract file and so
  requires nothing — which is exactly right for an unadvanced pin;
- **the policy shape** — from `devflow-policy.mjs detect`, the one
  implementation of shape detection.

The requirement is read from the skills themselves rather than from a version
table, so no list of release numbers has to be kept current here.

### Exit codes

| Code | Status | Meaning and fix |
|---|---|---|
| 0 | `compatible` | The vendored skills' declared version and the policy's agree (including "neither has migrated"). |
| 0 | `not-vendored` | No `.SKILLS_PROVENANCE` under `dest` and no unstamped **contract-carrying** skill beside it: nothing was vendored. Run `task sync:skills` first. See the limitation below. |
| 0 | `no-policy-consumer` | The policy has migrated, yet nothing vendored declares a policy contract — this consumer vendors no policy-consuming skill. This can happen in two ways: the pin is already at or past the first release shipping the version-2 stage skills and no managed skill declares a contract, **or** the pin is pre-boundary but the provenance stamp's categories exclude `universal` (the policy-consuming category), so advancing the pin would not add one either. Nothing needs to change. |
| 1 | `incompatible` | The vendored skills declare a policy schema version the repository's policy does not have. When the required version is within the toolchain's supported range, run `copier update`; when it exceeds it, upgrade the policy tooling. **Do not** advance the pin. |
| 2 | — | Usage error, or **indeterminate under the coherence invariant**. Never reported as a pass. Covers a missing manifest (including one that is not parseable YAML), an unreadable policy, a missing reader, a policy reader that exits successfully but emits output that is not a valid JSON object, a reader whose exit status contradicts its reported shape (exit 1 with `v2`), a damaged **modern** provenance stamp (no `# ref:` line, or a legacy-format stamp recording a post-boundary ref — see below), a managed name containing a path separator or `..` (path traversal), a managed entry that is a symlink (sync-skills.sh creates real directories), vendored skills declaring two different schema versions, a contract declaring a non-positive version (`0` is indistinguishable from "no contract"), a **mixed policy** carrying markers from more than one shape at once, and an **interrupted sync** — policy-consuming skills on disk with no stamp, which `sync-skills.sh` produces because it removes the stamp before copying and rewrites it last. A **legacy** stamp (no `# managed:` line, pre-boundary ref) is **not** damage — it is the older stamp generation that `sync-skills.sh`'s own `managed_names` still honours; the audit reads it from its recorded `# ref:` and the release boundary decides the verdict. |
| 3 | `pin-lag` | The policy migrated while the pin still predates the first release shipping the version-2 stage skills. Advance `source.ref` to a release whose stage skills declare the version the policy declares, then re-run `task sync:skills`. Where the policy has moved ahead of this toolchain entirely (a version the shipped reader does not support), the audit says so rather than sending you after a pin that cannot exist yet. |

A schema version names an **incompatible shape**, not a minimum capability
level — the reader itself requires `schema_version = 2` exactly — so the audit
compares for equality rather than "at least". By the same reasoning, vendored
skills declaring two different versions is a broken set that no single policy
can satisfy, and is reported indeterminate rather than resolved to either one.

### Pin lag is decided by a release boundary, not by skill names

Whether a migrated policy is ahead of its pin is settled by **one release
boundary** — the first harmon-devkit release whose `ai/skills/universal/`
ships the version-2 stage skills — and never by a list of skill names. Every
release from that boundary onward ships stage skills that declare a contract,
so a pin older than it necessarily predates them *whatever those skills were
called*, and a pin at or after it that still declares nothing is a consumer
that genuinely vendors no policy-consuming skill. Additionally, a
pre-boundary pin whose provenance stamp excludes the `universal` category
is also `no-policy-consumer` — advancing the pin would not add a policy
contract because the consumer never selected the policy-consuming category.

That matters because the retired `gauntlet` and `shepherd` stages are replaced
by `review` and `integrate` and are not supported: a name table would encode
dead vocabulary and need editing on every rename, and — as review round 4
found — listing only the new names silently mis-reported the one pin that
actually exists, since the last pre-v2 release shipped `gauntlet`/`shepherd`
and neither new name. The boundary constant lives in
`scripts/consumer-pin-audit.sh` with the `git ls-tree` evidence beside it, and
the suite reads that constant rather than restating a version, so bumping it
is a one-line change.

A pin that is not an orderable release tag (a branch, a SHA) cannot be
compared against the boundary at all, and is reported indeterminate rather
than guessed in either direction.

### One decidable rule for unstamped trees

With no provenance stamp, `sync-skills.sh`'s own rule is that **nothing is
managed** — so a contract-free directory beside a missing stamp is genuinely
indistinguishable from a local skill. This repository is the worked example: its
`.claude/skills` holds six real, tracked `openspec-*` directories that are
purely local.

The audit therefore decides only what it can prove. A **real (non-symlink)
directory carrying `assets/policy-contract.json` with no stamp** is vendored
version-2 residue — `sync-skills.sh` removes the stamp before copying and
rewrites it last, and only a vendored stage skill carries a contract — and that
is indeterminate, exit 2. Contract-free directories are **not guessed at**; the
`not-vendored` verdict says so and points at `task verify:skills`, which clones
the pinned ref and diffs, and so can answer by comparison what this audit
cannot answer by inspection.

Symlinked entries are skipped individually, never tree-wide: `cp -R` produces
real directories, so a symlink cannot be sync residue, and a source checkout
legitimately links to contract-carrying skills (this repository's
`.claude/skills/{review,integrate,orchestrator}` do exactly that).

*History, because the shape of this rule is the point.* An earlier version
counted **every** real directory as residue and then added a tree-wide "this
looks like a source checkout" exemption to undo the false positives. That
exemption produced a P1 in three consecutive review rounds — broadened, then
narrowed by link target, and still leaking tree-wide. It was deleted rather
than scoped a fourth time: it existed only to neutralise an undecidable check,
so removing both left one provable rule and nothing to leak.

### What this audit does *not* check

The pin audit answers **"do the pin and the policy agree?"** It does not verify
that the vendored tree matches what the pinned release actually shipped — that
is `sync-skills.sh verify` (`task verify:skills`), which clones the pinned ref
and diffs, so it catches drift such as a file deleted from inside a vendored
skill by comparison rather than by assumption.

The two are complementary and neither subsumes the other. In particular, a
managed skill whose `assets/policy-contract.json` has been deleted reads to the
pin audit as a skill that never declared one, because distinguishing the two
offline would need a table of which skills are expected to carry a contract —
and that is exactly the retired-stage-name table this design avoids. Run
`task verify:skills` for tree integrity; run `task audit:consumer-pin` for the
pin/policy question.

### The coherence invariant

The audit states one rule rather than a list of special cases:

> An input the shared reader refuses, or a stamp inconsistent with the tree, is
> **indeterminate — exit 2, never a pass.**

A pin verdict is only meaningful on inputs that are internally coherent, so
anything else has no verdict to give and guessing one is the fail-open the
script exists to prevent. It covers:

- a policy that is not exactly one shape the reader recognizes (`mixed`, or
  `unknown` declaring no version at all);
- a policy reader that exits successfully but emits output that is not a valid
  JSON object (exit 2, not the raw `jq` status that would be exit 5);
- a reader whose exit status contradicts its reported shape — exit 1 (refused)
  with shape `v2` is a contradiction, since exit 0 is required for a
  v2-compatible verdict;
- a contract whose version is not a positive integer;
- managed contracts that disagree on a version;
- a managed name containing a path separator or `..` (path traversal —
  matching `sync-skills.sh`'s `assert_sane_name` guard);
- a managed entry that is a symlink (`sync-skills.sh` creates real
  directories, so a symlinked managed entry is a stamp/tree mismatch);
- a provenance stamp that disagrees with the tree (missing `# ref:` line, a
  managed name with no directory or no `SKILL.md`, or vendored
  contract-carrying skills with no stamp at all).

A **legacy** stamp (no `# managed:` line) is **not** damage — it is the older
stamp generation that `sync-skills.sh`'s own `managed_names` still honours.
The audit reads it from its recorded `# ref:` and the release boundary decides
the verdict. A legacy stamp recording a post-boundary ref *is* indeterminate,
because the vendored skill set cannot be enumerated offline and cannot be
assumed pre-v2. `legacy` and `v1` are **not** incoherent — they are coherent
older shapes, and reporting on them is the audit's whole job. Neither is a
policy declaring a positive version this reader cannot operate: that is a
policy ahead of the toolchain, reported as such.

`scripts/test-consumer-pin-audit.sh` tests this as a **property** over every
incoherent input, so a newly discovered one is a new row in that table rather
than a new branch in the script.

Compatibility needs **both** a successful shape detection and an equal version,
not either alone. A policy declaring `schema_version = 2` while still carrying
a legacy marker detects as `mixed` — the reader refuses it — yet it does
declare version 2, so a version-equality test on its own would report it
compatible and undo the whole point of the check. `mixed` is therefore refused
before the pin is considered at all: no pin is right for a policy that is two
shapes at once. Conversely, testing the shape alone would let a version-2
policy satisfy a skill declaring version 3.

`scripts/devflow-policy.mjs` has its own documented exit codes (`detect`: 0
version 2, 1 an older or mixed shape, 2 unreadable; `resolve`: 0 resolved, 1
refused, 2 unreadable, 3 indeterminate cross-validation). `detect --json`
carries the actionable refusal in its `migration` field, which is where every
non-Node caller gets the wording rather than composing its own.

`task test:consumer-pin-audit` covers both directions of skew and the
older-shape refusals against fixture policies. It never reads this
repository's own `.devflow.toml`, which is deliberate — see below.

## harmon-devkit's own state

This repository is the **source** of the skills, not a consumer of them:
`.claude/skills/<name>` are symlinks into `ai/skills/universal/<name>`, and
there is no provenance stamp, so `task audit:consumer-pin` reports
`not-vendored` here. Its own `.devflow.toml` is still legacy and migrates
**only** through the maintainer's `copier update` (harmon-devkit#711) — never
through a DevKit task PR. That is why every test above is fixture-driven:
`task verify` has to stay green in a repository whose live policy is the very
shape the shipped skills refuse.

## Known consumers

The repositories that vendor these skills, and how to check each one:

| Repository | Check |
|---|---|
| `evanharmon1/harmon-init` | it *is* the template; its own root twin of `.devflow.toml` and its `.skills-sync.yaml` |
| `evanharmon1/harmon-devkit` | this repo — source, not consumer (above) |
| `evanharmon1/harmon-dotfiles` | `task audit:consumer-pin -- --repo-root <checkout>` |
| `harmonops/harmon-infra` | same |
| `ponderousdev/foreman` | same |
| any other `standardize-repo` consumer | same |

Confirming that every one of them is on a harmon-init release shipping the
version-2 template, or has migrated, is a maintainer step: it needs access to
each checkout and the judgement to schedule each `copier update`.

## See also

- [codex-review.md](codex-review.md) — the second-model review stages the
  round caps in `.devflow.toml` bound.
- [`../../openspec/changes/dev-flow-v2/specs/config/spec.md`](../../openspec/changes/dev-flow-v2/specs/config/spec.md)
  — the normative contract for shape detection and refusal.
