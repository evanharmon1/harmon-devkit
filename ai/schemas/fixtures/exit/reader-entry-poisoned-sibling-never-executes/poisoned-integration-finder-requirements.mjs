// POISONED — a branch-controlled integration helper must not execute before
// dev-flow-exit.mjs delegates to the trusted --closure reader.
throw new Error("POISON: integration helper top-level code executed");

export function codexRequired() {}
