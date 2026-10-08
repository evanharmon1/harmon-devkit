# floor-p2-round-then-empty-round-converges

harmon-devkit#1240 challenge round 2. `min_rounds = 3`. Round 1 adjudicates to P2 only and its fix moves the head; round 2 on the moved head is empty. The empty round is below the floor, so the `empty_round` exit is unavailable, but two consecutive zero-P0/P1 rounds converge on the two-consecutive rule whatever the floor (AGENTS.md: "Those rounds may be empty"; `min_rounds` constrains the empty-round exit alone). Before the fix an empty round below the floor returned `continue` without consulting round 1.
