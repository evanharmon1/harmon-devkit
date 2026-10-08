# sparse-head-map-without-repo-root-not-retained

harmon-devkit#1240. `run/heads.json` records round 2's head with a parent the map has no entry for, so the walk runs off the map before it meets round 1's head. That is inconclusive, not a "no": the engine falls through to `--repo-root` when one is given (covered with a real git history in `test-dev-flow-exit.sh`). With no `--repo-root` the ancestry stays `unknown` and round 1 is not retained, so one clean round is not reported as two.
