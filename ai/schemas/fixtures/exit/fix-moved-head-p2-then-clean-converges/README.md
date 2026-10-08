# fix-moved-head-p2-then-clean-converges

harmon-devkit#1240. Challenge round 1 adjudicates to a single P2 whose fix moved the head; round 2 reviews the moved head and is empty. The invocation passes no `--heads` and no `--repo-root`, so the only ancestry evidence is the run directory's own `run/heads.json`. Before the fix the engine read no head map, resolved round 1's head as `unknown`, and reported `retained_rounds: [2]`, `rounds_counted: 1`. `test-dev-flow-exit.sh` also runs the issue's own verify command (`--verification-only`) against this fixture.
