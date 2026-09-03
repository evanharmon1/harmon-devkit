# reader-entry-poisoned-sibling-never-executes

Distinct from `reader-self-modification-boundary`, which poisons
`devflow-policy.mjs` and runs it AS the entry (proving devflow-policy.mjs's
own `--closure` check protects it). Here `dev-flow-exit.mjs` itself — the
real, unmodified entry point a caller actually invokes — is run from a
scratch directory next to `poisoned-devflow-policy.mjs`, its sibling, with
`--closure` pointing at a fully trusted copy built fresh from whatever this
repo currently ships.

`poisoned-devflow-policy.mjs` throws immediately at top level. Before the
post-merge cloud review fix, `dev-flow-exit.mjs` statically imported its
sibling `devflow-policy.mjs` at module load — before `main()`'s own
`--closure` check ever ran — so this throw would have fired unconditionally,
regardless of `--closure`. The fix defers that import to inside `main()`,
after the `--closure` delegation check returns. `expected.json` asserts an
ordinary clean verdict, proving delegation to the trusted copy completed
normally — the only way that happens is if the poisoned sibling's top-level
code never ran at all.
