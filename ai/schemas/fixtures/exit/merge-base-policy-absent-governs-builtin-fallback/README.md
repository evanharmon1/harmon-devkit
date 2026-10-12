# merge-base-policy-absent-governs-builtin-fallback

harmon-devkit#1345: `dev-flow-exit.mjs --merge-base-policy-absent` says the
merge base has no `.devflow.toml` (a branch that adds it), so the built-in
fallback governs the exit, exactly as `devflow-policy.mjs resolve` resolves it.

The run, policy and heads are `capped-clean`'s, byte for byte. Under the
branch's own `policy.toml` (`[rounds.standard] review = 2`) the same two clean
rounds are `capped`/`clean`; under the built-in fallback (`review = 3`) they
are `converged`/`empty_round`. A regression that drops the flag — or never
passes `mergeBasePolicyAbsent` to `resolvePolicy` — lets the branch policy
govern and turns this fixture into `capped-clean`.
