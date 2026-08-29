# Domain model

The conceptual model of Harmon DevKit — the core concepts, how they relate,
their lifecycles, and the business rules that govern them. This is the shared
**ubiquitous language**: name things here the same way they are named in code,
specs, and conversation.

## Concepts

The core entities/nouns and what each means.

| Concept | Definition |
|---|---|
| TODO | TODO |

## Relationships

How the concepts relate — ownership, cardinality, dependencies.

```mermaid
erDiagram
    TODO_A ||--o{ TODO_B : "TODO: relationship"
```

## Lifecycles

The states a key entity moves through, and what triggers each transition.

### Dev flow — the lifecycle of one change

The stages a change moves through from an issue to a merged, released change.
Optional stages are marked; the rest run on every change. Stage names are the
canonical vocabulary — skills, agents, config keys, and round records use the
stage name, never a synonym (`gauntlet` is retired; see the glossary).

| # | Stage | What happens | Optional |
|---|---|---|---|
| 1 | kickoff | Open the session on an issue; resolve rigor, tier, strategy from config and labels. | |
| 2 | claim | Mark the issue as being worked (assignee, `claim:*` label, claim comment). | |
| 3 | explore | Research / scout the codebase or external sources before committing to a design. | yes |
| 4 | plan | Design or spec the change; write the plan the implementer will be briefed with. | |
| 5 | implement | The implementer produces the change on a branch and returns a result. | |
| 6 | verify | The deterministic gate (`task verify`, or `task check` on a docs-only diff) — the only stage that is a **check**. | |
| 7 | challenge | Adversarial second-model rounds on design and approach, to convergence. Raises confidence; never authoritative. | |
| 8 | review | Verification-lens second-model rounds on correctness, consistency, tests. Raises confidence; never authoritative. | |
| 9 | security | `task security` — secret scan, SAST, dependency audit. A check. | |
| 10 | integration | Open the draft PR, carry it through CI, requested reviews, and the readiness gate to ready-for-review. | |
| 11 | merge | A human merges. Always. | |
| 12 | deployment | Deploy the merged change, normally a GitHub Action. | yes |
| 13 | release | Cut a release, normally via the rolling release PR. | yes |
| 14 | smoke | Post-deploy smoke test, normally a GitHub Action. | yes |
| 15 | retro | Read the run record and round trajectory; file improvement issues. | yes |
| 16 | wrap | Release the claim, close out the session. | |

```mermaid
stateDiagram-v2
    [*] --> kickoff
    kickoff --> claim
    claim --> explore
    claim --> plan
    explore --> plan
    plan --> implement
    implement --> verify
    verify --> challenge
    challenge --> implement : findings to fix
    challenge --> review : converged / capped
    review --> implement : findings to fix
    review --> security : converged / capped
    security --> integration
    integration --> merge : ready-for-review, human decision
    merge --> deployment
    merge --> release
    deployment --> smoke
    smoke --> retro
    release --> retro
    merge --> wrap
    retro --> wrap
    wrap --> [*]
```

Stages 5–10 are what the orchestrator drives without a human (the
"unattended" span the dev-flow success metric measures); a human owns 11 and
whatever is optional.

## Business rules & invariants

The rules that must always hold — constraints, validations, policies. These are
what specs and their acceptance criteria enforce (see
[../../specs/](../../specs/)).

- TODO: rule or invariant (e.g. "a TODO_A always has at least one TODO_B").
