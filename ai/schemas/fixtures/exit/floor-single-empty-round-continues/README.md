# floor-single-empty-round-continues

harmon-devkit#1240 challenge round 2. `min_rounds = 3`. A single empty round below the floor has no preceding round to confirm it and may not take the `empty_round` exit, so the stage continues. Guards the fall-through from converging a lone clean round.
