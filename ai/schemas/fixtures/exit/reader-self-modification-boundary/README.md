# reader-self-modification-boundary

`poisoned-devflow-policy.mjs` is a mutated copy of the shared policy reader
(its built-in breadth default is changed from 8/3 to 999999/999999) —
standing in for a branch that edited the reader's own resolution code instead
of `.devflow.toml`.
`ai/skills/universal/dev-flow-support/assets/lib/run-exit-fixtures.mjs`
invokes it with `--closure <temp dir>`, where the temp dir is built at test
time from whatever
`ai/skills/universal/dev-flow-support/assets/devflow-policy.mjs` the
repository currently ships (never a copy committed here, so this fixture
cannot drift from the real reader). expected.json's breadth values are the
UN-tampered built-in default, proving the poisoned code's own constant was
never reached.

Two details are deliberate and worth not "fixing":

- **The committed copy's own header comments still name the pre-#974
  `scripts/` paths.** It is a frozen snapshot of a reader at a point in time,
  which is exactly what a merge-base copy is; rewriting its internals would
  make it a copy of nothing.
- **The temp closure is built in the `scripts/` layout**, so this fixture
  doubles as the regression that
  [#974](https://github.com/evanharmon1/harmon-devkit/issues/974)'s `--closure`
  probe still finds a reader at the layout every merge base predating the
  relocation carries. A branch in flight when that change merged has to be
  able to resolve its own merge base.
