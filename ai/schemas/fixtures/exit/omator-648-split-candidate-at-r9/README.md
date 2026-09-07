# omator-648-split-candidate-at-r9

Reconstruction of [ponderousdev/omator#648](https://github.com/ponderousdev/omator/pull/648) — the run that produced the **split strategy** (harmon-devkit [#747](https://github.com/evanharmon1/harmon-devkit/issues/747)) — from the issue's own account of it. It is the conformance case for `split_candidate`: the exit computation must be able to say *why* a stage capped, not only that it did.

The trajectory, as the issue records it:

| Round | Gating findings | Where |
|---|---|---|
| 1–2 | 3 | the change itself (`src/lane/import.ts`, `docs/unit-b.md`), all `original` |
| 3 | 1 | the F0 bounding class, `original` |
| 4–6 | 1 each | the bounding class again, each attributed to the **previous round's own fix** |
| 7 | 0 | a design change removed the bounding class and added the in-flight claim primitive |
| 8 | 3 | all in `src/lane/claim-primitive.ts`, all attributed to round 7 |
| 9 | 3 | all in `src/lane/claim-primitive.ts` — two of them introduced while fixing round 8's three |

`review` is capped at 9 here so the replay reaches round 9 rather than exiting earlier; the real run was a shepherd-stage loop, and the exit computation's stages are `challenge`/`review` only. Two things about the replay are worth stating plainly rather than leaving for a reader to rediscover:

- **The signal was available long before round 9.** Rounds 4, 5 and 6 each satisfy the same concentration-plus-round-provenance test on the bounding class, so an implementation reading this projection at round 5 would already have offered the split. That is the point of #747: the strategy existed only as a maintainer's judgement call made after nine rounds, and nothing exposed the evidence for proposing it earlier.
- **The verdict is unchanged.** `split_candidate` is a diagnostic. This fixture pins `capped`/`findings_remain` exactly as it would be without the signal — issue #747's "Out of scope" is explicit that the caps and the two-consecutive exit do not move.

Round 9's adjudication uses the `split` disposition with a `reference` naming the follow-up the split produced (omator#649), which is also this corpus's end-to-end exercise of that enum value and of the validator's "a split must name the issue it was filed as" check.

The sibling negative control is `omator-397-review-capped-at-r3`: also `capped`/`findings_remain`, also concentrated in one file, but with **no** finding attributable to an earlier round's fix — an under-reviewed 1,450-line spec rather than a loop feeding on itself. It asserts `split_candidate.detected == false`, so the two cases pin the discrimination from both sides.
