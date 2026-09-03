// POISONED — stands in for a branch checkout where dev-flow-exit.mjs's own
// SIBLING devflow-policy.mjs was modified. This throws immediately at
// TOP LEVEL, before exporting anything real, simulating an arbitrary
// malicious side effect (fake output, exfiltration, process.exit()). It
// must never run at all when --closure is given — post-merge cloud review
// (dev-flow-exit.mjs:32, confirmed): a static top-level import of this
// file would execute this throw before tryDelegateToClosure ever got a
// chance to redirect to the trusted copy. If this test ever fails with
// "POISON: top-level code executed" visible in stderr, the deferred-import
// fix in dev-flow-exit.mjs has regressed.
throw new Error("POISON: top-level code executed");

// Never reached (the throw above fires first) — present only so ESM's
// static linking phase resolves the same named exports the real
// devflow-policy.mjs provides, so a run that (wrongly) reaches this file
// fails via the throw above, not an unrelated "module does not provide an
// export named X" linking error.
export class PolicyError extends Error {}
export function resolvePolicy() {}
export function crossValidate() {}
