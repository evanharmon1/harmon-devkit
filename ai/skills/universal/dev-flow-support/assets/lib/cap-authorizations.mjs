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
// disagree about which rounds are admitted. Integration uses charged cycle counts, never adjudication pass rounds.
// Retries and carried heads retain the same cumulative spend.
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
// Pure functions over plain values, plus a small CLI adapter for shell consumers.

// run.schema.json's cap_authorizations[] entry, field for field.
// stage: enum ["challenge", "review", "integration"]
const STAGES = new Set(["challenge", "review", "integration"]);
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

// A codex_cycle is a cumulative snapshot, not an increment per integrator pass.
// Re-reading it (retry/carry) spends nothing. Older producers omit both split
// counters and charge every cycle. Only reserve supplies `next`, after its
// existing classifier has decided whether the new cycle is charged or exempt.
function integrationCycleAccounting(cycle, { run = null, cap, next = null } = {}) {
  const uint = (n) => Number.isSafeInteger(n) && n >= 0;
  let ordinal = cycle == null ? 0 : cycle.cycle;
  const split = cycle != null && (Object.hasOwn(cycle, "charged") || Object.hasOwn(cycle, "exempt"));
  let charged = split ? cycle.charged : ordinal;
  let exempt = split ? cycle.exempt : 0;
  if (!uint(ordinal) || !uint(charged) || !uint(exempt) || charged + exempt !== ordinal) {
    throw new Error("integration cycle requires non-negative integer charged + exempt counts equal to cycle");
  }
  if (next !== null) {
    if (next !== "charged" && next !== "exempt") throw new Error("next cycle must be charged or exempt");
    ordinal += 1;
    if (next === "charged") charged += 1;
    else exempt += 1;
  }
  if (cap !== undefined && !uint(cap)) throw new Error("integration cap must be a non-negative integer");
  const ceiling = authorizedCeiling(run, "integration", cap);
  return {
    cycle: ordinal, charged, exempt, ceiling,
    authorized: isAuthorizedOverCap(run, "integration", charged, cap),
    admitted: cap === undefined || (cap === 0 ? ordinal === 0 : charged <= ceiling),
  };
}

export { integrationCycleAccounting };

// Shell adapter. A supplied record is never silently ignored: it must be
// readable and belong to the caller's run before any authorization is used.
async function main(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    if (!["--run", "--run-id", "--cap", "--cycle", "--next"].includes(key) || argv[i + 1] === undefined || Object.hasOwn(args, key)) {
      throw new Error("expected --cycle JSON [--cap N] [--run FILE --run-id ID] [--next charged|exempt]");
    }
    args[key] = argv[i + 1];
  }
  let run = null;
  if (args["--run"]) {
    const { readFileSync } = await import("node:fs");
    run = JSON.parse(readFileSync(args["--run"], "utf8"));
    if (!args["--run-id"] || run.run_id !== args["--run-id"]) throw new Error("authorization record does not match --run-id");
    // Reserve must reject the whole collection that readiness would reject,
    // even when one valid entry alone would authorize the requested cycle.
    if (Object.hasOwn(run, "cap_authorizations")) {
      if (!Array.isArray(run.cap_authorizations)) throw new Error("cap_authorizations must be an array");
      const seen = new Set();
      for (const entry of run.cap_authorizations) {
        if (!isWellFormed(entry)) throw new Error("cap_authorizations contains a malformed entry");
        const key = `${entry.stage}:${entry.round}`;
        if (seen.has(key)) throw new Error("cap_authorizations contains a duplicate (stage, round)");
        seen.add(key);
      }
    }
  }
  const result = integrationCycleAccounting(JSON.parse(args["--cycle"]), {
    run, cap: args["--cap"] === undefined ? undefined : Number(args["--cap"]), next: args["--next"] ?? null,
  });
  console.log(JSON.stringify(result));
}

const { pathToFileURL } = await import("node:url");
const { realpathSync } = await import("node:fs");
const isMain = (() => {
  try {
    return process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href;
  } catch {
    return false;
  }
})();
if (isMain) {
  main(process.argv.slice(2)).catch((err) => {
    console.error(`cap-authorizations: ${err.message}`);
    process.exitCode = 1;
  });
}
