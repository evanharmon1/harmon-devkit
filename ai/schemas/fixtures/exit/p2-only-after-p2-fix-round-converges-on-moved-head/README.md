# p2-only-after-p2-fix-round-converges-on-moved-head

harmon-devkit#1240 and #1073 criterion 2. Round 1 adjudicates to P2 only and its fix moves the head; round 2 reviews the moved head and also adjudicates to P2 only. Two consecutive zero-P0/P1 rounds end the stage on round 2 itself (`predicates_satisfied`, no `next_round`) — no confirmation pass is owed. Ancestry comes from `run/heads.json` alone; before the fix the engine dropped round 1 and answered `continue/below_threshold`.
