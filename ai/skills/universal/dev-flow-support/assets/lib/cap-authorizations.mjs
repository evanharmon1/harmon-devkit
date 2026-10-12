// cap-authorizations.mjs — the one predicate for "is round N of stage S
// authorized above the resolved cap" (harmon-devkit#1239).
//
// A resolved cap is a ceiling the agent never raises on its own. A maintainer
// may still order a round above it; run.json's optional `cap_authorizations[]`
// records each such instruction, one entry per (stage, round), with the actor
// who gave it, the instruction verbatim, and when. This module is the only
// place that turns those entries into an effective ceiling. dev-flow-exit.mjs
// (own-stage check, cross-stage scan and the capped-final-round exit) and
// render-dev-flow.mjs (the cap-consistency check and the
// `round n/cap (authorized)` projection) both call it, so the two cannot
// disagree about which rounds are admitted. Only challenge and review rounds
// can be authorized; integration is not supported yet.
//
// Invariants:
//   - The resolved cap is never rewritten. The ceiling is computed in memory
//     and reported beside the cap; nothing here reads a raised copy of
//     policy.json as authority.
//   - Contiguity: rounds cap+1..N are admitted only when EVERY one of them is
//     authorized. A gap stops the ceiling at the last contiguous round, so an
//     authorization for round 6 alone admits nothing above a cap of 3.
//   - A cap of 0 is a disabled stage, not a ceiling of zero rounds: it is
//     never lifted. Opening a disabled stage changes the topology the run
//     resolved (stage-skipping, the cross-stage emptiness rule), which is a
//     policy change rather than one more round.
//   - Fail closed on shape: isWellFormed mirrors run.schema.json's
//     cap_authorizations[] entry shape exactly — the key set is exactly
//     {stage, round, actor, instruction, at} (the schema's
//     additionalProperties: false) and each field meets the constraint the
//     schema states for it. An entry the schema would reject
//     (validate-result-schemas.mjs `run` refuses it outright) authorizes
//     nothing here, so a reader that never ran the validator can only see a
//     LOWER ceiling, never a higher one. A change to that entry schema must
//     change this predicate with it.
//
// Pure functions over plain values; no imports, no top-level side effects.

// run.schema.json's cap_authorizations[] entry, field for field.
// stage: enum ["challenge", "review"]
const STAGES = new Set(["challenge", "review"]);
// at: the instant pattern the schema requires
const TIMESTAMP = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$/;
// required + additionalProperties: false — exactly these keys, no others
const ENTRY_KEYS = ["actor", "at", "instruction", "round", "stage"];

// actor, instruction: string, minLength 1, pattern \S
function nonBlank(value) {
  return typeof value === "string" && value.length >= 1 && /\S/.test(value);
}

function isWellFormed(entry) {
  if (entry === null || typeof entry !== "object" || Array.isArray(entry)) return false;
  const keys = Object.keys(entry).sort();
  if (keys.length !== ENTRY_KEYS.length || keys.some((key, i) => key !== ENTRY_KEYS[i])) return false;
  return (
    STAGES.has(entry.stage) &&
    // round: integer, minimum 1
    Number.isInteger(entry.round) &&
    entry.round >= 1 &&
    nonBlank(entry.actor) &&
    nonBlank(entry.instruction) &&
    typeof entry.at === "string" &&
    TIMESTAMP.test(entry.at)
  );
}

// The set of round numbers authorized for `stage` in a run record (run.json's
// parsed object, or null/undefined when there is none).
function authorizedRounds(run, stage) {
  const entries = run && Array.isArray(run.cap_authorizations) ? run.cap_authorizations : [];
  const rounds = new Set();
  for (const entry of entries) {
    if (isWellFormed(entry) && entry.stage === stage) rounds.add(entry.round);
  }
  return rounds;
}

// The highest round of `stage` the record admits: `cap` itself, raised by one
// for each consecutive authorized round above it. Returns `cap` unchanged
// when it is not a positive integer.
function authorizedCeiling(run, stage, cap) {
  if (!Number.isInteger(cap) || cap < 1) return cap;
  const rounds = authorizedRounds(run, stage);
  let ceiling = cap;
  while (rounds.has(ceiling + 1)) ceiling += 1;
  return ceiling;
}

// True when `round` lies above the resolved cap and the record authorizes it
// (and every round between). A round at or below the cap is not "authorized";
// it never needed to be.
function isAuthorizedOverCap(run, stage, round, cap) {
  return Number.isInteger(cap) && cap >= 1 && Number.isInteger(round) && round > cap && round <= authorizedCeiling(run, stage, cap);
}

export { authorizedCeiling, authorizedRounds, isAuthorizedOverCap };
