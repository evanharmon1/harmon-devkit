# provenance-share-at-threshold-diverging

harmon-devkit#1073 criterion 1, adjudicated against the existing `provenance_share` predicate (`min = 0.5`, `exclude_classes = ["design"]`) rather than a second predicate. Round 2 has two gating findings: one on a line round 1's fix added (verified `round:1` by `history.json`) and one verified `original`. A share of exactly 0.5 meets the threshold, so the engine returns `diverging` with `action: "fix-delete-restructure-or-split"`.
