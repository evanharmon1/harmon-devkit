# Classification rubric

How to choose **Impact**, **Risk**, and **Complexity** for an issue, and what the **Tier** derived from them means.
The label registry gives each value one line; this is the long form behind those lines: a definition per axis, an
anchor and an example per value, the edge-case rules, and worked examples. **Priority** is a different axis with its
own rubric: [priority-rubric.md](priority-rubric.md).

This file defines what the values mean. Which skill writes them, and when, is that skill's own contract.

## The axes at a glance

| Axis | The question it answers | Scale | Who sets it | Stored as |
| --- | --- | --- | --- | --- |
| Impact | How much does finishing this matter? | minimal, low, medium, high, massive | AI or human | issue field on an organization repo; `impact:<value>` label on a personal-account repo |
| Risk | How bad is it if the change is done wrong? | trivial, low, medium, high, critical | AI or human | issue field on an organization repo; `risk:<value>` label on a personal-account repo |
| Complexity | How hard is it to do and verify correctly? | xs, s, m, l, xl | AI or human | issue field on an organization repo; `complexity:<value>` label on a personal-account repo |
| Tier | Which model stratum should work it? | local, economy, standard, frontier, apex | derived from Risk × Complexity; a human may pin it | `tier:<value>` label on every owner type |

Under the classification decision, Impact, Risk, and Complexity are each required for an issue to count as triaged;
which skill enforces that, and when, is that skill's own contract. The Tier is not required: it is a cache that a reader
recomputes when it is absent.

**Rate each axis on its own.** These are four different questions, and the commonest error is letting the answer to one
leak into another:

| Mix-up | Why it is wrong | Do this instead |
| --- | --- | --- |
| Rating Impact by how often the code path runs | Impact is core benefit versus marginal benefit, not common path versus uncommon path | Ask whether finishing the issue delivers something core or something marginal |
| Rating Risk by how bad the bug is | For a bug fix, the harm prevented is Impact; Risk is the danger of the fix | Score the harm under Impact and the fix's danger under Risk |
| Rating Complexity by how long it will take | Complexity is difficulty, never a time estimate | Judge how hard it is to understand, design, implement, and verify |
| Raising Impact because the change is risky or hard | Impact does not move with Risk or Complexity | Leave Impact on the outcome's value alone |
| Choosing a Tier because the issue feels important | The Tier is derived from Risk × Complexity, and Impact does not enter it | Set Risk and Complexity; the Tier follows |
| Reading Impact as urgency | Ordering belongs to Priority (set by a human) and Priority (AI) (an agent's suggestion), not to Impact | Leave ordering to the Priority rubric |

## Human work is a separate decision

Set `human` when completion is primarily a human's: actions, decisions, QA,
purchases, credentials, physical work, or a majority of `[HUMAN]` criteria.
Agent assistance does not change that decision; one human box on primarily
agent work does not by itself require the label. Follow harmon-init's **Human
work** paragraph in
[docs/project-management.md](https://github.com/evanharmon1/harmon-init/blob/main/docs/project-management.md).
Count every checkbox line in the acceptance-criteria section at any indentation,
including checked and untagged items in the total. This label does not replace
Impact, Risk, Complexity, or Tier. Agents may add it. Triage may remove it only for a non-collector without a `[HUMAN]` majority
whose remaining work the classifier judges agent-completable, through the guarded
helper; every removal is reported (SKILL.md step 2e). Filing never removes it.
Collectors keep `human` + `umbrella`.
Removal also refuses any heading indented one to three spaces anywhere in the
body because the acceptance-criteria section boundary is ambiguous.

## Impact

Impact is the expected significance of completing the issue: what finishing it buys the product's users or the
maintainer's current goals. Ask whether the benefit is **core or marginal**, not whether the affected path is common
or uncommon. It measures the value of the outcome, so it does not change with how hard or how dangerous the change is,
and it is not urgency.

### Impact anchors

| Value | Short form | Anchor | Example |
| --- | --- | --- | --- |
| minimal | Marginal benefit; most users would not notice it | Nobody is worse off if it never ships | Fix a typo in a code comment; rename an internal variable |
| low | Small benefit to a few users or a narrow use case | A real but small gain for one group | Add a flag that a single integration uses; clarify docs for a rarely used option |
| medium | Clear benefit to a meaningful share of users or goals | The people it reaches would notice and be glad | Cache the dependency install so every contributor's CI run is faster |
| high | Core benefit, or severe harm prevented even if rarely triggered | The core job works better, or a severe harm stops happening | Stop a retry path from double-charging a customer; fix silent data loss on an unusual path |
| massive | Transformative; current goals depend on it | The goals the project is working toward cannot be met without it | The capability a milestone exists to deliver; a migration the platform cannot ship without |

### Impact worked examples

- *"The deploy script prints the wrong hint text when a flag is missing."* → **minimal**. The benefit is marginal: most
  people never see the hint and no one is blocked.
- *"CI reinstalls dependencies on every run; caching them saves two minutes per contributor per push."* → **medium**.
  It is not core to the product, but it is a clear, repeated benefit to a meaningful share of the people working in
  the repository.
- *"The CSV export silently drops the last row when the row count is an exact multiple of 100."* → **high**. It is
  rarely triggered, but silent data loss is a severe harm prevented (edge-case rule 2).

## Risk

Risk is how consequential a failure is if the change is implemented incorrectly. It scores the danger of *making the
change*. Reach (how many users or how much data a mistake touches), reversibility (whether it can be undone, and how
cheaply), and detectability (whether anyone would notice in time) are the considerations; place the issue on the anchor
below whose description best fits what a mistake would do. Risk is not the harm the issue describes: for a bug fix,
that harm is Impact.

### Risk anchors

| Value | Short form | Anchor | Example |
| --- | --- | --- | --- |
| trivial | A mistake is harmless and trivially reversible | Nothing user-facing changes; a revert is one commit | Edit docs prose or a comment; add a test for existing behavior |
| low | A mistake is contained, caught quickly, and cheap to undo | One small surface; a failure shows up in CI or on first use | Add a lint rule; a new internal script with its own test; a feature flag that ships off |
| medium | A mistake breaks a feature or needs a careful rollback | A feature stops working, or undoing it takes more than a revert | Refactor a module that several features share; change a CI workflow that gates merges; a major dependency bump |
| high | A mistake reaches many users or their data; recovery is costly | Many users, or their data, get a wrong result and recovery costs real effort | Change a shared template or library that downstream repositories vendor; alter authentication or permission checks; a backfill that rewrites many records |
| critical | A mistake risks data loss, security exposure, or an irreversible outage | A wrong implementation can destroy data, expose secrets or private data, or take something down with no way back | A migration that deletes or rewrites production data without a tested restore; a change that widens access to credentials; infrastructure that cannot be rolled back |

### Risk worked examples

- *"Add a regression test for an already-fixed parsing bug."* → **trivial**. Nothing user-facing changes, and a revert is
  one commit.
- *"Move the shared date-formatting helper into its own module; six features import it."* → **medium**. A mistake breaks
  features, though tests or first use would catch it, and the data is untouched.
- *"Drop the legacy `orders_v1` table now that the migration is done."* → **critical**. If the migration missed
  anything the data is gone, and unless a restore has been tested there is no way back.

## Complexity

Complexity is how difficult the work is to understand, design, implement, and verify correctly, including how likely it
is to grow once started. Rate it on every issue. It is not a time estimate and not Effort (the human time estimate for
human tasks). Count the components touched, the design decisions still open, the unfamiliar context to learn, how wide
the verification must be, and how much is unknown. Unknowns push the value up, because uncertain work tends to grow.

**Rate the difficulty, not the hours or the file count.** A mechanical change applied by one script across hundreds of
files is as easy to understand as a change to one file, so rate the rule rather than the count. A one-line change in
subtle concurrent code can be hard to verify, so it can rate higher than a long mechanical edit. Work that no automated check
can prove — such as a visual change, prompt or model-output wording, or external-service behaviour — rates higher than
its size alone suggests. An `xl` is a signal to split the issue; label it `xl` while it is still one issue.

### Complexity anchors

| Value | Short form | Anchor | Example |
| --- | --- | --- | --- |
| xs | A tiny, well-understood change with obvious verification | One place, a known fix, one check proves it | Correct a wrong config key; bump a pin in one file |
| s | Small and local; a clear approach across a few files | The approach is clear and verification is a test or two | Add input validation to an existing script with a test case; add a field to one schema and its docs |
| m | Moderate; several components and some design choices | A few real choices across several components, with tests and docs | A new subcommand with tests and docs; a new workflow with its config, script, and test |
| l | Large; cross-cutting, with real design and wide verification | Many parts are touched, the decisions interact, and verification needs several kinds of check | A new skill with scripts, tests, docs, and vendoring; changing a convention used across the tree |
| xl | Very large or uncertain; likely to grow or need splitting | Too big to hold at once, with unknowns that will turn it into several issues | A migration across several repositories; "make it work everywhere" with unknown unknowns |

### Complexity worked examples

- *"Change the default log level from info to warn in one config file."* → **xs**. One place, a known change, and one
  check proves it.
- *"Adjust a prompt's wording to prevent tool hallucinations in an agent."* → **s**. A one-line edit, but no automated check
  can prove model-output wording, rating it higher than its size alone suggests.
- *"Add a retry policy to the payment client and thread idempotency keys through the client, the server, and the
  tests."* → **m**. Several components and real design choices, with fault-injection tests to write.
- *"Move every service from the old deploy pipeline to the new one."* → **xl**. It spans many services, what each one
  needs is not yet known, and it will probably turn into several issues.

## Edge-case rules

Each rule is stated here once. The Impact and Risk sections above and the Tier section below apply them.

1. **An edge case is not automatically low impact.** Impact turns on core benefit versus marginal benefit, not on common
   path versus uncommon path. Do not rate an issue down because only a few inputs trigger it; ask whether finishing it
   delivers something core or something marginal.
2. **A rarely triggered data-loss or double-charge bug can be high impact.** Severe harm prevented counts even when it
   is rarely triggered. A bug that double-charges about one order in three thousand is **high**.
3. **A frequent-screen polish can be low impact.** Everyone sees the screen, but the benefit is marginal. Nudging the
   spacing or hover colour of the home page's primary button is **low**, however many people look at it.
4. **For a bug fix, the harm prevented is Impact and the danger of the fix is Risk.** Score them separately, because
   they often differ: a one-word fix for a bug that stops backups is high Impact and low Risk; a rewrite to fix a
   cosmetic glitch is low Impact and high Risk.
5. **`local` is small-model-feasible work that may take a while.** It is a statement about what a small self-hosted
   model can do, possibly slowly. It does not mean quick, trivial, or unimportant. The Tier section expands on it.

## Tier

The Tier is the model stratum an issue suggests its implementer run at: `local`, `economy`, `standard`, `frontier`, or
`apex`. It is not a judgement about the issue; it is **derived**. The unpinned Tier is a pure function of Risk × Complexity
through the policy matrix, so it carries nothing beyond those two values, and in particular Impact does not enter it; a
human pin (below) is the one exception. It is stored as a **label**, `tier:<value>`, on every owner type, organization and personal-account repositories alike,
and is never an organization issue field. A writer sets at most one tier value on an issue. The scale is exactly these
five rungs: the derived Tier is never `adaptive`, and how an existing `adaptive` label is retired or migrated is the
registry and policy work's concern, not this rubric's. Which models sit in each tier is the model catalog's decision
(`agent-registry.json`), not this rubric's.

### How the Tier is derived

The matrix below reproduces the policy matrix that harmon-init ships in `.devflow.toml` (`[tier.matrix]`), so a
classifier can work offline. Where the repository's policy carries a matrix, **it wins on any disagreement and this
table is the one to fix**. Without a `[tier.matrix]` in the repository's policy, no Tier is derived or written: this
table is then for reading only. Look up the row for Complexity and the column for Risk.

| Complexity \ Risk | trivial | low | medium | high | critical |
| --- | --- | --- | --- | --- | --- |
| xs | local | local | economy | standard | frontier |
| s | local | economy | standard | standard | frontier |
| m | economy | standard | standard | frontier | apex |
| l | standard | standard | frontier | frontier | apex |
| xl | frontier | frontier | frontier | apex | apex |

Risk dominates: a tiny change with critical risk lands at `frontier`, while a large change with trivial risk lands
at only `standard`.

- **Written with its inputs.** Whoever writes Risk or Complexity writes the derived Tier in the same call, unless the
  issue carries `tier:pinned`, in which case it leaves the Tier label alone. An agent that writes the Tier writes the
  matrix's answer for the Risk and Complexity it just wrote, and nothing else. It never chooses a Tier for its own run
  and never adds `tier:pinned`.
- **A cache.** A reconciler corrects drift, and a reader that finds no Tier recomputes it from Risk and Complexity.
- **Pinnable by a human.** A human who disagrees with the derived Tier sets the `tier:<value>` label from the GitHub UI
  and adds `tier:pinned`. Nothing automated writes over a pinned Tier, even when Risk or Complexity later changes. The
  human removes `tier:pinned` to hand the Tier back to derivation, and replaces the existing tier label first when
  pinning a different tier. A pin is a label input like any other, so its provenance is checked: an interactive session
  confirms a pin the operator has not authorized, and unattended automation honors one only after verifying who applied
  it.
- **Implementer only.** A pin and a derived Tier each set only the implementer tier. How they rank against an operator
  instruction and the other tier inputs is execution-policy resolution, defined in the repository's policy and its
  `AGENTS.md`, not in this rubric.
- **Not a role override.** A scoped label such as `tier:implementer:frontier` is a human execution-policy override for
  one role. The unqualified `tier:<value>` is the issue's stored Tier.

### Tier anchors

| Value | Short form | Anchor (cells of the matrix) | Example |
| --- | --- | --- | --- |
| local | Work a small self-hosted model can do, possibly slowly | The smallest, safest work: `xs` or `s` at trivial risk, or `xs` at low risk | Fix a typo in a comment; add a test for existing behavior; a scripted rename |
| economy | Cheapest qualified hosted model first; escalation allowed | Small work with a little risk: `xs` at medium, `s` at low, `m` at trivial | Add validation to an existing script, with a test |
| standard | Reliable general-purpose coding model first | Ordinary feature and bug work: `xs` at high, `s` at medium or high, `m` at low or medium, `l` at trivial or low | A new subcommand with tests and docs; refactor a shared module |
| frontier | The heaviest hosted models; no warm-up on weaker ones | Risky or large work: `xs` or `s` at critical, `m` at high, `l` at medium or high, `xl` at trivial to medium | Rewrite payment retry logic; drop a legacy table |
| apex | The leading edge, above frontier | The biggest and riskiest: `m` or `l` at critical, `xl` at high or critical | Migrate production data to a new schema in place |

`local` is a statement about model capability, not time. A scripted change across many files can be `local` because a
small model can do it, only slowly; an issue that needs design judgement a small model cannot be trusted with is not
`local` however long the model is given (edge-case rule 5).

### Tier worked examples

| Issue | Risk | Complexity | Derived Tier |
| --- | --- | --- | --- |
| Fix a typo in a code comment | trivial | xs | local |
| A typo in one variable name makes the nightly backup job write to an empty path | low | xs | local |
| Add `--format json` to the status script, with a test | low | s | economy |
| Move the shared date-formatting helper into its own module | medium | m | standard |
| Rewrite the payment retry logic to stop double charges | high | m | frontier |
| Drop the legacy `orders_v1` table | critical | xs | frontier |
| Migrate production data to a new schema in place | critical | l | apex |

**A pin.** A human sets `tier:frontier` and adds `tier:pinned` on the `--format json` issue, whose derived Tier is
`economy`, because the status script feeds a billing report. The label stays `frontier` and no automated write changes
it, even if the issue's Risk or Complexity is later edited. When the human removes `tier:pinned`, the next write
re-derives `economy`.

## Whole-issue worked examples

- **Bug: "A retry after a gateway timeout charges the customer twice (about one order in 3,000)."**
  Impact **high**, because a double charge is severe harm prevented even though it is rarely triggered (rule 2). Risk
  **high**, because the fix changes the payment path every order uses, and a wrong fix can double-charge or drop
  charges for many customers; refunds can recover it, so it is not critical (rule 4 keeps the harm out of this
  score). Complexity **m**: idempotency keys across the client and the server, plus fault-injection tests. Tier
  **frontier** (m × high).
- **Bug: "A typo in one variable name makes the nightly backup job write to an empty path, so no backups are being
  taken."** Impact **high**: severe harm prevented. Risk **low**: the fix is a one-word rename and the next run shows
  whether it worked. Complexity **xs**. Tier **local** (xs × low). A high-impact issue can run at the lowest tier,
  because Impact does not enter the Tier.
- **Task: "Drop the legacy `orders_v1` table."** Impact **low**: nothing a user sees gets better. Risk **critical**:
  the data cannot be recovered unless a restore has been tested. Complexity **xs**. Tier **frontier** (xs ×
  critical). Risk dominates, so a tiny change gets a heavy model.
- **Feature: "Add `--format json` to the status script; one integration asked for it."** Impact **low**: a small
  benefit to one group. Risk **low**: contained, and it fails in the new test first. Complexity **s**: the script, a
  test, and a usage line. Tier **economy** (s × low).

Provenance: the harmon-init decision records "Classify issues by impact, risk, and complexity, and derive the tier"
(2026-09-30) and "Store the Tier as a label on every owner type" (2026-10-01).
