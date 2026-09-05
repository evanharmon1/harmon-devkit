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
- **what those skills require** — the highest `policy_schema_version` declared
  by any *managed* skill's `assets/policy-contract.json`. Only directories on
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
| 0 | `not-vendored` | No `.SKILLS_PROVENANCE` under `dest` and no unstamped policy-consuming skill beside it: nothing was vendored. Run `task sync:skills` first. |
| 0 | `no-policy-consumer` | The policy has migrated, but the vendored set contains none of the skills that resolve it, so there is no pin contract to satisfy. Advancing the pin would not add one; nothing needs to change. |
| 1 | `incompatible` | The vendored skills declare a policy schema version the repository's policy does not have. Run `copier update`; **do not** advance the pin. |
| 2 | — | Usage error or indeterminate. Never reported as a pass. Covers a missing manifest, an unreadable policy, a missing reader, a damaged provenance stamp (no `# ref:` or no `# managed:` line), vendored skills declaring two different schema versions, and an **interrupted sync** — policy-consuming skills on disk with no stamp, which `sync-skills.sh` produces because it removes the stamp before copying and rewrites it last. |
| 3 | `pin-lag` | The policy migrated and the policy-consuming skills *are* vendored but predate the contract. Advance `source.ref` and re-run `task sync:skills`. |

A schema version names an **incompatible shape**, not a minimum capability
level — the reader itself requires `schema_version = 2` exactly — so the audit
compares for equality rather than "at least". By the same reasoning, vendored
skills declaring two different versions is a broken set that no single policy
can satisfy, and is reported indeterminate rather than resolved to either one.

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
