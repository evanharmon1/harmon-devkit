---
name: dev-flow-support
description: >-
  Internal runtime support for the universal dev-flow v2 stage skills — policy
  resolution, result-schema validation, record rendering, and stage-exit
  computation. Do not invoke directly.
disable-model-invocation: true
user-invocable: false
---

# Dev flow support

This package gives `review`, `integrate`, `orchestrate`, and `retro` one
implementation each of the mechanical steps the dev-flow v2 lifecycle depends
on. It is a `SKILL.md`-bearing package only so current and legacy
category-sync engines vendor it with the universal category; it has no
user-facing workflow.

It exists because a stage skill that invokes a repository-root `scripts/`
path installs into a consumer repository that cannot run it (harmon-devkit#974).
The skills sync is the only distribution channel for this runtime: a script one
skill uses lives in that skill's own `assets/`, and a script several skills
share lives here. Nothing is shipped through the harmon-init template.

## Assets

| Asset | Used by | What it does |
|---|---|---|
| `assets/devflow-policy.mjs` | review, integrate, orchestrate | Resolve rigor, strategy, rounds, breadth, and role tiers from `.devflow.toml` and `agent-registry.json`. |
| `assets/validate-result-schemas.mjs` | review, integrate, orchestrate | Schema-check one brief, result, adjudication, run, or plan document, plus the receipt checks a raw schema cannot express. |
| `assets/render-dev-flow.sh` → `assets/render-dev-flow.mjs` | review, integrate, retro | Render a run record into its PR-body and comment projections. |
| `assets/dev-flow-exit.sh` → `assets/dev-flow-exit.mjs` | review, retro | Compute a confidence stage's exit verdict from the run record. |
| `assets/lib/toml-lite.mjs` | the readers above | Restricted TOML parser. |
| `assets/lib/json-schema-subset.mjs` | the validators above | Hand-rolled JSON Schema subset validator. |
| `assets/lib/run-exit-fixtures.mjs` | `assets/test-dev-flow-exit.sh` | Fixture driver for the stage-exit corpus. |
| `assets/schemas/` | `validate-result-schemas.mjs`, `render-dev-flow.mjs` | The package's own copy of the shared JSON Schemas — the default schemas directory, so a vendored consumer validates without a separate schema sync. |

The tests for these assets live beside them (`assets/test-*.sh`) and are wired
into harmon-devkit's `task verify` through root Taskfile targets that call the
asset paths.

## Calling it from another skill

Resolve this package relative to the calling asset's own **physical**
directory, never from a repository root — the same shape
`track-work/assets/check-issue-metadata.sh` uses for `issue-title-support`:

```sh
asset_dir="$(cd "$(dirname "$0")" && pwd -P)"
support_dir="$asset_dir/../../dev-flow-support/assets"
```

`pwd -P` matters. Categories are flattened on vendor, so the sibling package is
two levels up in a consumer's `.claude/skills/` tree; in harmon-devkit's own
source tree it is two levels up from `ai/skills/universal/<skill>/assets` as
well, and the `.agents/skills/<name>` dogfood entries are symlinks whose
physical target is that same source path. A logical `pwd` would resolve
`../../` against the symlink and miss.

A `.mjs` asset uses a path relative to its own file for the same reason.

## Resolving the assets from an agent file

The section above is for another skill's *script* resolving this package via
`$0` / `import.meta.url`. An **agent file** (`ai/agents/reviewer.md`,
`ai/agents/challenger.md`, `ai/agents/integrator.md`) has no such anchor — it
is prose run by an LLM in a shell, not a script with a physical location of
its own — so it must resolve this package's `assets/` the same way
`devflow-policy.mjs` resolves its own vendored copy: probe, in order, the
vendored skill layouts that `CLOSURE_READER_PATHS`
(`assets/devflow-policy.mjs`) carries — `ai/skills/universal/`, then
`.claude/skills/`, then `.agents/skills/` — and use the first one that exists.
An agent file that needs this package's `assets/` directory names this rule by
section title and file instead of re-enumerating the layouts, and sets it
once:

```sh
for c in ai/skills/universal/dev-flow-support/assets .claude/skills/dev-flow-support/assets .agents/skills/dev-flow-support/assets; do
    [ -d "$c" ] && { DEV_FLOW_SUPPORT="$c"; break; }
done
```

Keep this candidate list in the same order as `CLOSURE_READER_PATHS` in
`assets/devflow-policy.mjs` — that array is the one place the vendored layouts
are actually enumerated; this snippet is a derived copy, not a second source
of truth, and must be updated if that array's order or membership changes.

## Schemas

`ai/schemas/` in harmon-devkit remains the authoring source of truth: its
README, its conformance fixture corpus, and Foreman's reference all point
there. `assets/schemas/` is a byte-identical copy that travels with the
package, so a consumer that vendored only skills still has the schemas its
vendored validators default to. `task test:schema-parity` fails the build when
the two diverge.

A consumer that *also* wants the schemas at a stable top-level path may add the
optional `schemas:` block to its `.skills-sync.yaml`; it is not required, and
this package does not depend on it.
