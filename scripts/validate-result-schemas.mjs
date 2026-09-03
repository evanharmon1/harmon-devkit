#!/usr/bin/env node
// validate-result-schemas.mjs — schema-check one dev-flow-v2 result/record
// fixture, plus the receipt-validation checks a raw JSON Schema cannot
// express because they read a sibling field outside the instance a payload
// schema validates (envelope vs payload) or need context from other
// documents in the same run (prior passes, prior adjudications, the active
// run).
//
// Usage:
//   validate-result-schemas.mjs <kind> <file> [options]
//
//   kind: envelope | implementer | challenger | reviewer | integrator | adjudication | run
//   `envelope` dispatches on the instance's own `role` field (after the
//   envelope schema itself passes) and runs exactly the same payload +
//   receipt checks as invoking the role's own kind name directly — it is
//   not a payload-blind mode, just a way to validate a full result without
//   the caller having to already know its role.
//
//   --known-ids <file.json>       JSON array of finding ids already used
//                                 elsewhere in the run (challenger, reviewer,
//                                 and integrator) — rejects a collision (spec:
//                                 "a finding id is unique within the run by
//                                 construction").
//   --run-id <id>                 The active run's run_id. Must be given
//   --initiated-by <human|foreman>  together with --initiated-by — one
//                                 without the other is a usage error, not a
//                                 guaranteed-mismatch: rejects an envelope
//                                 whose `run` names a different run.
//   --pass <envelope.json>        (adjudication only, repeatable) the
//                                 envelope this document adjudicates: for
//                                 stage challenge, a REVIEWER envelope (a
//                                 pre-#635 trajectory) or a CHALLENGER one
//                                 (post-#635); stage review is REVIEWER-only
//                                 (that role never split); stage integration
//                                 is INTEGRATOR-only (the document's own
//                                 `stage` decides which set applies — read before
//                                 parsing the rest of argv, since --pass may
//                                 appear anywhere). Each file is itself
//                                 validated in full (envelope schema + its
//                                 role's payload + its own receipt checks,
//                                 no run context) before anything else
//                                 runs; an invalid --pass file fails
//                                 immediately, naming that file. With one or
//                                 more --pass, the document is cross-checked
//                                 against the UNION of their findings:
//                                 completeness, and that every pass agrees
//                                 with the others (and the document) on
//                                 run_id/initiated_by/stage/round/
//                                 reviewed_head — and, when --run-id/
//                                 --initiated-by are also given, that every
//                                 pass agrees with THAT active run too. For
//                                 stage challenge/review this also checks
//                                 reviewer_priority fidelity and that every
//                                 pass names a distinct finder; stage
//                                 integration skips both — an integrator
//                                 payload carries no finder and its
//                                 findings carry no reviewer-asserted
//                                 priority to compare against.
//   --known-adjudicated <file.json>  (adjudication only) JSON array of
//                                 finding ids already adjudicated in an
//                                 earlier round document of this run —
//                                 rejects a collision (a finding is
//                                 adjudicated in exactly one round document,
//                                 ever).
//   --adjudication <file.json>   (run only, repeatable) an adjudication
//                                 document. Each file is itself validated as
//                                 a full adjudication document before
//                                 anything else runs; an invalid file fails
//                                 immediately, naming that file. With one or
//                                 more --adjudication, every settlement's
//                                 finding_id must be adjudicated exactly
//                                 once across the supplied documents, with
//                                 disposition `defer`. Cross-checking an
//                                 --adjudication document against its
//                                 source pass(es) is out of scope for this
//                                 validator — it needs the run's full
//                                 trajectory, not just this one document —
//                                 and is left to the exit script (#636).
//   --no-adjudications           (run only) an explicit "confirmed zero":
//                                 there is genuinely no adjudication history
//                                 for this run yet (a fresh kickoff, or one
//                                 that never needed to adjudicate anything),
//                                 as opposed to --adjudication simply not
//                                 having been supplied. Runs the same
//                                 settlement checks --adjudication would,
//                                 against the empty set — any settlement at
//                                 all is then rejected, since nothing can
//                                 have adjudicated it. Satisfies --receipt's
//                                 requirement for `run` in place of a real
//                                 --adjudication file. Mutually exclusive
//                                 with --adjudication (a usage error).
//   --schemas-dir <dir>          Directory holding the *.schema.json family.
//                                 Overrides RESULT_SCHEMAS_DIR, which
//                                 overrides the default of `ai/schemas`
//                                 resolved relative to THIS SCRIPT's own
//                                 location (not the current working
//                                 directory) — so the validator finds its
//                                 schemas the same way regardless of the
//                                 caller's cwd.
//   --receipt                    Require every context flag applicable to
//                                 this invocation's <kind> (envelope kinds:
//                                 --run-id/--initiated-by; challenger,
//                                 reviewer, and integrator: also --known-ids;
//                                 adjudication: --pass and
//                                 --known-adjudicated; run: --adjudication)
//                                 — a missing one is a
//                                 usage error (exit 2), not a silently
//                                 narrower check. Without --receipt, an
//                                 omitted flag simply skips the checks it
//                                 would have fed (named in the success
//                                 message's "context skipped" list) — the
//                                 orchestrator's real invocation always
//                                 uses --receipt; a bare invocation is for
//                                 one-off schema/fixture work where the run
//                                 context genuinely is not available.
//
// The success message always names any applicable context flag that was
// NOT given, e.g. "reviewer result OK (role=reviewer, status=completed,
// context skipped: --known-ids, --run-id)" — so a bare (non-"--receipt")
// invocation's reduced guarantee is visible, not silent.
//
// Exit 0 and a one-line summary when the fixture is valid; exit 1 and every
// violation (one per line) otherwise. A usage error (bad kind, missing
// file, a paired flag given alone, or a --receipt-required flag missing)
// exits 2.
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { createSchemaValidator } from './lib/json-schema-subset.mjs'

const DEFAULT_SCHEMAS_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'ai', 'schemas')
const KINDS = ['envelope', 'implementer', 'challenger', 'reviewer', 'integrator', 'adjudication', 'run']
const FINDING_ID = /^(challenge|review|integration)-r([1-9][0-9]*)-(.+)-([1-9][0-9]*)$/
const SHA_PATTERN = /^[0-9a-f]{40}$/
// A bare positive integer (same-repo follow-up) or an owner/repo#N qualified
// form (a cross-repository follow-up) -- the same qualification track-work's
// own convention already requires for a bare #<n> anywhere it could mean two
// different trackers (harmon-devkit#639 gauntlet challenge round 3: the
// bare-only pattern made a schema-valid settlement impossible for the
// cross-repo case the integrate skill's own text documents).
const ISSUE_NUMBER_PATTERN = /^(?:[1-9][0-9]*|[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9][0-9]*)$/

function usage() {
  console.error(
    'usage: validate-result-schemas.mjs <envelope|implementer|challenger|reviewer|integrator|adjudication|run> <file> ' +
      '[--known-ids <file.json>] [--run-id <id> --initiated-by <human|foreman>] ' +
      '[--pass <file.json> ...] [--known-adjudicated <file.json>] [--adjudication <file.json> ...] ' +
      '[--no-adjudications] [--schemas-dir <dir>] [--receipt]'
  )
}

// resolveSchemasDir ARGV — a --schemas-dir flag can appear anywhere in argv
// (parseArgs below processes flags in a single left-to-right pass, but
// --pass/--adjudication resolve and validate their context files, which need
// SCHEMAS_DIR, DURING that same pass — so the directory must be known before
// parseArgs starts, not discovered mid-parse). Scanned independently of
// position for that reason; precedence is flag > RESULT_SCHEMAS_DIR env > the
// script-relative default.
function resolveSchemasDir(argv) {
  const flagIndex = argv.indexOf('--schemas-dir')
  if (flagIndex !== -1) {
    const dir = argv[flagIndex + 1]
    if (!dir) {
      console.error('validate-result-schemas: --schemas-dir requires a directory argument')
      usage()
      process.exit(2)
    }
    return path.resolve(dir)
  }
  if (process.env.RESULT_SCHEMAS_DIR) return path.resolve(process.env.RESULT_SCHEMAS_DIR)
  return DEFAULT_SCHEMAS_DIR
}

const SCHEMAS_DIR = resolveSchemasDir(process.argv.slice(2))

function loadJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (error) {
    console.error(`validate-result-schemas: cannot read valid JSON from ${file}: ${error.message}`)
    process.exit(1)
  }
}

function loadSchema(basename) {
  return loadJson(path.join(SCHEMAS_DIR, basename))
}

// loadIdArray FILE FLAG — a JSON array of strings, or exit 1 naming exactly
// what is wrong. Never silently disable the check a malformed file was
// meant to feed: `Array.isArray` guards downstream would otherwise treat
// "not an array" the same as "no flag given at all".
function loadIdArray(file, flag) {
  const data = loadJson(file)
  if (!Array.isArray(data) || !data.every((entry) => typeof entry === 'string')) {
    console.error(`validate-result-schemas: ${flag} file ${file} must be a JSON array of strings`)
    process.exit(1)
  }
  return data
}

// loadAndValidateContext FILE FLAG VALIDATE — load FILE and run VALIDATE
// (one of validateEnvelopeInstance / validateAdjudicationInstance) over it;
// any error fails immediately, naming FILE, before the primary document is
// ever cross-checked against it.
function loadAndValidateContext(file, flag, validate) {
  const data = loadJson(file)
  const errors = validate(data)
  if (errors.length > 0) {
    console.error(`validate-result-schemas: ${flag} file ${file} is invalid:`)
    for (const error of errors) console.error(`  FAIL: ${error}`)
    process.exit(1)
  }
  return data
}

function parseArgs(argv) {
  const [kind, file, ...rest] = argv
  if (!kind || !file || !KINDS.includes(kind)) {
    usage()
    process.exit(2)
  }
  // --pass's own expected role(s). --pass is parsed (and its file validated)
  // as the loop below reaches it, which may be before OR after this
  // document's own `stage` would otherwise be known — so peek at it now,
  // from the primary file already in hand, rather than discovering it
  // mid-parse.
  // Stage `review` has always been reviewer-only; stage `integration` is
  // integrator-only. Stage `challenge` now admits EITHER role: `reviewer`
  // for a pre-#635 trajectory (the single pre-split role covered both
  // stages) or `challenger` going forward — peeking a fixed single expected
  // role here would reject every legitimate challenger --pass outright.
  let passAllowedRoles = ['reviewer']
  if (kind === 'adjudication') {
    const peek = loadJson(file)
    if (peek && peek.stage === 'integration') passAllowedRoles = ['integrator']
    else if (peek && peek.stage === 'challenge') passAllowedRoles = ['reviewer', 'challenger']
  }
  const options = {
    knownIds: null,
    runId: null,
    initiatedBy: null,
    passes: [],
    knownAdjudicated: null,
    adjudications: [],
    receipt: false,
    noAdjudications: false
  }
  for (let i = 0; i < rest.length; i += 1) {
    switch (rest[i]) {
      case '--known-ids':
        options.knownIds = loadIdArray(rest[(i += 1)], '--known-ids')
        break
      case '--run-id':
        options.runId = rest[(i += 1)]
        break
      case '--initiated-by':
        options.initiatedBy = rest[(i += 1)]
        break
      case '--pass': {
        const passFile = rest[(i += 1)]
        const data = loadAndValidateContext(passFile, '--pass', (candidate) => {
          // Dispatch as `envelope` (self-dispatch on candidate's own role)
          // rather than asserting one fixed expected role, then separately
          // confirm that role is one this stage may legitimately produce —
          // this is what lets a challenge-stage --pass be either a
          // pre-#635 reviewer pass or a challenger pass without the two
          // being conflated or one being silently rejected.
          if (
            candidate &&
            typeof candidate.role === 'string' &&
            !passAllowedRoles.includes(candidate.role)
          ) {
            return [
              `$result.role: expected ${passAllowedRoles.join(' or ')}, found ${JSON.stringify(candidate.role)}`
            ]
          }
          const errors = validateEnvelopeInstance(candidate, 'envelope', {
            knownIds: null,
            runId: null,
            initiatedBy: null
          })
          // A blocked confidence-role pass (reviewer OR challenger) contributes
          // no pass at all (the orchestrator retries it once, spec §
          // Configuration) — a status: blocked envelope is a perfectly valid
          // standalone result (it just means the finder produced nothing), but
          // it is never a legitimate --pass: checkReviewerBlockedStatus already
          // forces its findings empty for either role, so there is never real
          // content to cross-check an adjudication against, unconditionally. A
          // blocked INTEGRATOR is different: checkIntegratorBlockedStatus
          // permits verdict findings/pending/escalate while blocked (only clean
          // is forbidden), so a blocked integrator CAN carry real findings —
          // evidence gathered before being cut short — and is accepted as
          // --pass context precisely when it does; one with none is rejected
          // for the same "nothing to adjudicate" reason.
          const isConfidenceRole = candidate && (candidate.role === 'reviewer' || candidate.role === 'challenger')
          if (errors.length === 0 && candidate.status === 'blocked') {
            const hasFindings =
              candidate.payload &&
              Array.isArray(candidate.payload.findings) &&
              candidate.payload.findings.length > 0
            if (isConfidenceRole || !hasFindings) {
              errors.push('$result.status: a blocked pass contributes no findings and cannot be used as --pass context')
            }
          }
          return errors
        })
        options.passes.push({ file: passFile, data })
        break
      }
      case '--known-adjudicated':
        options.knownAdjudicated = loadIdArray(rest[(i += 1)], '--known-adjudicated')
        break
      case '--adjudication': {
        const adjudicationFile = rest[(i += 1)]
        const data = loadAndValidateContext(adjudicationFile, '--adjudication', (candidate) =>
          validateAdjudicationInstance(candidate)
        )
        options.adjudications.push({ file: adjudicationFile, data })
        break
      }
      case '--schemas-dir':
        // Already resolved into SCHEMAS_DIR by resolveSchemasDir() before
        // parsing began; consume its value here so it isn't mistaken for an
        // unknown option.
        i += 1
        break
      case '--receipt':
        options.receipt = true
        break
      case '--no-adjudications':
        options.noAdjudications = true
        break
      default:
        console.error(`validate-result-schemas: unknown option ${rest[i]}`)
        usage()
        process.exit(2)
    }
  }
  // --run-id and --initiated-by are one pair, not two independent flags: one
  // given without the other can never legitimately match (initiated_by is a
  // required enum, never null), so it is a usage error, not a guaranteed
  // rejection for the wrong reason.
  if ((options.runId === null) !== (options.initiatedBy === null)) {
    console.error('validate-result-schemas: --run-id and --initiated-by must be given together')
    usage()
    process.exit(2)
  }
  // --no-adjudications asserts "confirmed zero" (a real, checkable fact);
  // --adjudication supplies actual documents. The two are answers to the
  // same question and cannot both be given.
  if (options.noAdjudications && options.adjudications.length > 0) {
    console.error('validate-result-schemas: --no-adjudications and --adjudication are mutually exclusive')
    usage()
    process.exit(2)
  }
  return { kind, file, options }
}

function parseFindingId(id) {
  const match = FINDING_ID.exec(id)
  if (!match) return null
  const [, stage, round, finder, n] = match
  return { stage, round: Number(round), finder, n: Number(n) }
}

// CONTEXT_FLAGS — the context flags applicable to each <kind>, in the fixed
// order the success message and --receipt report them (alphabetical by
// flag name), each paired with how to tell whether it was actually given.
// Shared by the "context skipped" success-message suffix and --receipt's
// requiredness check, so the two can never disagree about what applies.
const RUN_ID_FLAG = { flag: '--run-id', given: (o) => o.runId !== null }
const CONTEXT_FLAGS = {
  implementer: [RUN_ID_FLAG],
  challenger: [{ flag: '--known-ids', given: (o) => o.knownIds !== null }, RUN_ID_FLAG],
  reviewer: [{ flag: '--known-ids', given: (o) => o.knownIds !== null }, RUN_ID_FLAG],
  integrator: [{ flag: '--known-ids', given: (o) => o.knownIds !== null }, RUN_ID_FLAG],
  adjudication: [
    { flag: '--known-adjudicated', given: (o) => o.knownAdjudicated !== null },
    { flag: '--pass', given: (o) => o.passes.length > 0 },
    RUN_ID_FLAG
  ],
  run: [{ flag: '--adjudication', given: (o) => o.adjudications.length > 0 || o.noAdjudications }]
}

// applicableContextSpecs KIND ROLE — ROLE is only consulted for kind
// 'envelope' (which dispatches on the instance's own role and so inherits
// that role's context flags); every other kind ignores it. An
// unrecognised role (a garbage or missing `role` on an envelope-kind
// instance) falls back to the universal envelope baseline (--run-id only)
// rather than guessing at extras it cannot confirm apply.
function applicableContextSpecs(kind, role) {
  if (kind === 'envelope') return CONTEXT_FLAGS[role] ?? [RUN_ID_FLAG]
  return CONTEXT_FLAGS[kind] ?? []
}

function skippedContextFlags(kind, role, options) {
  return applicableContextSpecs(kind, role)
    .filter((spec) => !spec.given(options))
    .map((spec) => spec.flag)
}

// checkReceiptRequirements — with --receipt, every context flag applicable
// to this invocation must actually be given; a missing one is a usage
// error (exit 2), matching how --run-id given without --initiated-by is
// already treated as a usage error rather than a guaranteed rejection.
function checkReceiptRequirements(kind, role, options) {
  if (!options.receipt) return
  const missing = skippedContextFlags(kind, role, options)
  if (missing.length === 0) return
  for (const flag of missing) {
    console.error(`validate-result-schemas: --receipt requires ${flag} for kind ${kind}`)
  }
  usage()
  process.exit(2)
}

function validateAgainst(schema, instance, location) {
  const engine = createSchemaValidator(schema)
  try {
    engine.assertSupportedSchema(schema)
  } catch (error) {
    return [`${location}: invalid or unsupported schema: ${error.message}`]
  }
  return engine.validate(instance, schema, location)
}

// checkImplementerStatus — the completed/blocked conditional requirements
// from Foreman v1: cannot be a structural keyword because `status` lives on
// the envelope and the conditioned fields live in `payload` (a separate
// instance from the payload schema's point of view). See
// ai/schemas/README.md 'Composition'.
function checkImplementerStatus(envelope, errors) {
  const { status, payload } = envelope
  if (status === 'completed') {
    if (typeof payload.summary !== 'string' || payload.summary.trim() === '') {
      errors.push('$result.payload.summary: required (non-empty) when status is completed')
    }
    if (typeof payload.handoff !== 'string' || payload.handoff.trim() === '') {
      errors.push('$result.payload.handoff: required (non-empty) when status is completed')
    }
    if (!Array.isArray(payload.ac_test_map) || payload.ac_test_map.length === 0) {
      errors.push('$result.payload.ac_test_map: required (non-empty array) when status is completed')
    }
  } else if (status === 'blocked') {
    if (typeof payload.blocked_question !== 'string' || payload.blocked_question.trim() === '') {
      errors.push('$result.payload.blocked_question: required (non-empty) when status is blocked')
    }
  }
}

function checkActiveRun(envelope, options, errors) {
  if (options.runId === null) return
  const { run } = envelope
  if (run.run_id !== options.runId || run.initiated_by !== options.initiatedBy) {
    errors.push(
      `$result.run: run {run_id: ${JSON.stringify(run.run_id)}, initiated_by: ${JSON.stringify(
        run.initiated_by
      )}} is not the active run {run_id: ${JSON.stringify(options.runId)}, initiated_by: ${JSON.stringify(
        options.initiatedBy
      )}}`
    )
  }
}

// checkAdjudicationActiveRun — the envelope-shaped twin of checkActiveRun
// above, adapted for adjudication.schema.json's shape: the document has
// only `run_id` at its own top level (no wrapping envelope, and no
// `initiated_by` field to compare — adjudication.schema.json's own
// $comment explains why it is standalone, never wrapped in the envelope).
// Runs whenever --run-id/--initiated-by are given, exactly like the
// envelope version; --receipt now requires them for kind adjudication too
// (CONTEXT_FLAGS.adjudication), so this comparison is then unconditional.
function checkAdjudicationActiveRun(document, options, errors) {
  if (options.runId === null) return
  if (document.run_id !== options.runId) {
    errors.push(`$adjudication.run_id: ${document.run_id} is not the active run ${options.runId}`)
  }
}

// checkReviewerBlockedStatus — a blocked finder contributes no findings at
// all (spec § Configuration: the orchestrator retries it once), so
// envelope status: blocked means findings must be empty and every count
// zero — the same "blocked reviewer still validates against the same
// shape, just empty" design the schema and README already describe, made
// explicit as a receipt check. Cross-field (envelope status vs payload
// content), always runs for role reviewer — and, since result.challenger's
// pass core is field-for-field identical (findings + counts), reused
// unchanged for role challenger rather than duplicated as a twin function.
// attack_scenarios is challenger-only and gets its own status rule in
// checkChallengerAttackScenarios below, kept apart from this generic
// findings/counts check the same way that field is kept apart from the
// shared pass core in the schema itself.
function checkReviewerBlockedStatus(envelope, errors) {
  if (envelope.status !== 'blocked') return
  const { payload } = envelope
  if (Array.isArray(payload.findings) && payload.findings.length > 0) {
    errors.push('$result.payload.findings: must be empty when the envelope status is blocked')
  }
  if (payload.counts && typeof payload.counts === 'object') {
    for (const priority of ['P0', 'P1', 'P2', 'P3']) {
      if (payload.counts[priority] !== 0) {
        errors.push(`$result.payload.counts.${priority}: must be 0 when the envelope status is blocked`)
      }
    }
  }
}

// checkFindingIds — (b) no duplicate id within this pass, (c) no collision
// with ids already used elsewhere in the run (when --known-ids is given),
// (e) each id's stage/round/finder segments match this pass's own metadata,
// plus a counts-vs-tally cross-check. Generic over any payload shaped like
// the shared pass core (findings[] + stage/round/finder + counts), so it
// serves both role reviewer and role challenger without a role-specific
// branch.
function checkFindingIds(envelope, options, errors) {
  const { payload } = envelope
  if (!Array.isArray(payload.findings)) return
  const seen = new Set()
  const tally = { P0: 0, P1: 0, P2: 0, P3: 0 }
  for (const finding of payload.findings) {
    if (typeof finding.id !== 'string') continue
    if (seen.has(finding.id)) {
      errors.push(`$result.payload.findings: duplicate finding id ${finding.id} within this pass`)
    }
    seen.add(finding.id)
    if (Array.isArray(options.knownIds) && options.knownIds.includes(finding.id)) {
      errors.push(
        `$result.payload.findings: finding id ${finding.id} collides with a finding already in the run`
      )
    }
    const parsed = parseFindingId(finding.id)
    if (parsed) {
      if (parsed.stage !== payload.stage) {
        errors.push(
          `$result.payload.findings: finding id ${finding.id} names stage ${parsed.stage}, pass is ${payload.stage}`
        )
      }
      if (parsed.round !== payload.round) {
        errors.push(
          `$result.payload.findings: finding id ${finding.id} names round ${parsed.round}, pass is round ${payload.round}`
        )
      }
      if (parsed.finder !== payload.finder) {
        errors.push(
          `$result.payload.findings: finding id ${finding.id} names finder ${parsed.finder}, pass finder is ${payload.finder}`
        )
      }
    }
    if (Object.hasOwn(tally, finding.priority)) tally[finding.priority] += 1
  }
  if (payload.counts && typeof payload.counts === 'object') {
    for (const priority of ['P0', 'P1', 'P2', 'P3']) {
      if (payload.counts[priority] !== tally[priority]) {
        errors.push(
          `$result.payload.counts.${priority}: reports ${payload.counts[priority]}, findings actually contain ${tally[priority]}`
        )
      }
    }
  }
}

// checkChallengerAttackScenarios — role challenger only. Same-document checks
// (no external context needed, unlike checkFindingIds' --known-ids cross-run
// collision case): (a) attack_scenarios must be non-empty when the envelope
// is completed, and empty when blocked — the field exists specifically so a
// clean round still proves the design was actually attacked rather than
// merely inspected (ai/schemas/README.md); a completed pass reporting zero
// scenarios defeats that purpose exactly the way an empty findings[] would
// not (findings may legitimately be empty on their own). (b) no duplicate
// attack_scenarios[].id within this pass — the schema's own description
// promises "unique within this pass", which is otherwise nowhere enforced;
// (c) every entry whose outcome is surfaced-finding must name a finding_id
// that actually appears in THIS pass's own findings[] — a scenario cannot
// claim to have surfaced a finding this pass never returned. The schema's own
// if/then already forces finding_id null for outcome:held and a string for
// outcome:surfaced-finding; this adds the one thing a schema keyword cannot
// check, that the string names a real sibling finding.
function checkChallengerAttackScenarios(envelope, errors) {
  const { status, payload } = envelope
  if (!Array.isArray(payload.attack_scenarios)) return
  if (status === 'completed' && payload.attack_scenarios.length === 0) {
    errors.push(
      '$result.payload.attack_scenarios: must be non-empty when the envelope status is completed — a clean pass still records what it attempted'
    )
  }
  if (status === 'blocked' && payload.attack_scenarios.length > 0) {
    errors.push('$result.payload.attack_scenarios: must be empty when the envelope status is blocked')
  }
  const findingIds = new Set(
    Array.isArray(payload.findings)
      ? payload.findings.filter((f) => typeof f.id === 'string').map((f) => f.id)
      : []
  )
  const seenScenarioIds = new Set()
  for (const scenario of payload.attack_scenarios) {
    if (typeof scenario.id === 'string') {
      if (seenScenarioIds.has(scenario.id)) {
        errors.push(
          `$result.payload.attack_scenarios: duplicate scenario id ${scenario.id} within this pass`
        )
      }
      seenScenarioIds.add(scenario.id)
    }
    if (scenario.outcome === 'surfaced-finding' && typeof scenario.finding_id === 'string') {
      if (!findingIds.has(scenario.finding_id)) {
        errors.push(
          `$result.payload.attack_scenarios: scenario ${JSON.stringify(scenario.id)} names finding_id ${scenario.finding_id}, which is not in this pass's own findings`
        )
      }
    }
  }
}

// checkHeadAgreement — every head-shaped field in a payload must equal the
// envelope's head (specs/dev-flow-v2.md § Results, "Heads must agree").
function checkHeadAgreement(kind, envelope, errors) {
  const { head, payload } = envelope
  if (
    (kind === 'reviewer' || kind === 'challenger') &&
    typeof payload.reviewed_head === 'string' &&
    payload.reviewed_head !== head
  ) {
    errors.push(
      `$result.payload.reviewed_head: ${payload.reviewed_head} does not match envelope head ${head}`
    )
  }
  if (kind === 'integrator' && payload.codex_cycle && typeof payload.codex_cycle === 'object') {
    if (typeof payload.codex_cycle.head === 'string' && payload.codex_cycle.head !== head) {
      errors.push(
        `$result.payload.codex_cycle.head: ${payload.codex_cycle.head} does not match envelope head ${head}`
      )
    }
    const accepted = payload.codex_cycle.accepted
    if (accepted && typeof accepted === 'object' && typeof accepted.reviewed_commit === 'string') {
      if (accepted.reviewed_commit !== head) {
        errors.push(
          `$result.payload.codex_cycle.accepted.reviewed_commit: ${accepted.reviewed_commit} does not match envelope head ${head}`
        )
      }
    }
  }
}

// checkIntegratorSettledAtAgreement — payload.settled_at ("when this
// integrator pass was produced") and the envelope's own produced_at name
// the SAME event: the integrator's one production instant, stamped once
// on the envelope and once inside its own payload. Exact equality, not a
// tolerance window: both fields are written by the SAME orchestrator call
// that builds this one JSON document, not read from two independent
// clocks or external systems the way e.g. a GitHub check's own timestamp
// would be — so a real difference between them is a mistake in what
// produced the envelope, not measurement noise to tolerate.
function checkIntegratorSettledAtAgreement(envelope, errors) {
  const settledAt = envelope.payload.settled_at
  if (typeof settledAt === 'string' && typeof envelope.produced_at === 'string' && settledAt !== envelope.produced_at) {
    errors.push(`$result.payload.settled_at: ${settledAt} does not match envelope produced_at ${envelope.produced_at}`)
  }
}

// checkIntegratorBlockedStatus — envelope status: blocked means the
// integrator did not complete its evidence-gathering pass, so it cannot
// simultaneously claim payload.verdict: clean (blocked implies verdict is
// one of pending/escalate/findings — whatever it actually observed before
// being cut short, never a completed clean read). Cross-field (envelope
// status vs payload verdict), so this is the envelope-level receipt check,
// like checkImplementerStatus.
function checkIntegratorBlockedStatus(envelope, errors) {
  if (envelope.status === 'blocked' && envelope.payload.verdict === 'clean') {
    errors.push('$result.payload.verdict: cannot be clean when the envelope status is blocked')
  }
}

// checkCodexCycleAcceptedScope — the schema's if/then requires `accepted`
// when exit_code is terminal (0/10); it does not forbid `accepted` for any
// OTHER exit code, since "required when" is the only shape if/then can
// express. `accepted` is evidence of a terminal result, so its presence
// alongside a non-terminal exit_code (11 pending, 12 retry, 13 escalate,
// 14 PR no longer open, 2 indeterminate) is contradictory and forbidden
// here, in the validator, the same way "required when" and "forbidden
// otherwise" are two separate assertions throughout this family.
function checkCodexCycleAcceptedScope(payload, errors) {
  const cycle = payload.codex_cycle
  if (!cycle || typeof cycle !== 'object') return
  if (![0, 10].includes(cycle.exit_code) && Object.hasOwn(cycle, 'accepted')) {
    errors.push(
      `$result.payload.codex_cycle.accepted: must be absent when exit_code is ${cycle.exit_code} (only 0/10 are terminal)`
    )
  }
}

// EXIT_CODE_VERDICT_CONSTRAINTS — what codex_cycle.exit_code implies about
// payload.verdict, per the SAME exit-code contract
// result.integrator.schema.json's codex_cycle.exit_code description
// documents, which is itself ai/skills/universal/integrate/assets/
// check-codex-cloud-review.sh's `check` subcommand: 0 clean, 10 findings,
// 11 pending, 12 retry, 13 escalate, 14 PR no longer open, 2
// indeterminate. checkIntegratorCleanVerdict separately requires exit_code
// 0 (with accepted present) when verdict IS clean — that is the OTHER
// direction of this same equivalence (clean implies 0); the 0 entry here
// is what closes the loop the other way (0 implies clean), the same
// two-direction shape every other exit code in this table already gets.
// 13 (escalate) and 2 (indeterminate) share the SAME equals rule: AGENTS.md's
// integration stage escalates when both Codex-cycle attempts are incomplete,
// which is exactly what an indeterminate result IS — there is no
// meaningful difference between "explicitly escalate" and "couldn't tell,
// so escalate" for what the orchestrator does next. Each entry is either
// `equals` (verdict must be exactly this value) or `excludes` (a set
// verdict must not be any member of).
const EXIT_CODE_VERDICT_CONSTRAINTS = {
  0: { equals: 'clean' },
  10: { equals: 'findings' },
  11: { equals: 'pending' },
  12: { equals: 'pending' },
  13: { equals: 'escalate' },
  14: { excludes: new Set(['clean', 'pending']) },
  2: { equals: 'escalate' }
}

// checkCodexCycleExitCodeVerdict — verdict and codex_cycle.exit_code are
// sibling fields of one payload instance, but the CONDITION each
// EXIT_CODE_VERDICT_CONSTRAINTS entry expresses is either "must equal
// exactly this value" for a specific exit_code (a fixed value a JSON
// Schema const could express) or "must not be ANY of these values" (a
// small enum-exclusion set) — and which exit_code selects which rule is
// itself data-dependent, which if/then's single conditional-per-node
// shape cannot encode as one schema-level rule the way
// checkIntegratorCleanVerdict's fixed verdict:clean condition can.
function checkCodexCycleExitCodeVerdict(payload, errors) {
  const cycle = payload.codex_cycle
  if (!cycle || typeof cycle !== 'object') return
  const constraint = EXIT_CODE_VERDICT_CONSTRAINTS[cycle.exit_code]
  if (!constraint) return
  if (constraint.equals && payload.verdict !== constraint.equals) {
    errors.push(
      `$result.payload.verdict: must be ${JSON.stringify(constraint.equals)} when codex_cycle.exit_code is ${cycle.exit_code}, found ${JSON.stringify(payload.verdict)}`
    )
  }
  if (constraint.excludes && constraint.excludes.has(payload.verdict)) {
    errors.push(
      `$result.payload.verdict: must not be ${JSON.stringify(payload.verdict)} when codex_cycle.exit_code is ${cycle.exit_code}`
    )
  }
}

// checkAppliedDispositionsUnique — applied_dispositions[].finding_id must
// be unique. Always runs for role integrator, independent of `verdict`:
// this is a structural defect in the array itself, not a clean-verdict
// rule, and rejecting it explicitly (rather than building a keep-last Map
// keyed by finding_id, which silently drops the earlier entry) is the
// point — a duplicate here means two different claims about the same
// finding's disposition, and neither one should be silently discarded.
function checkAppliedDispositionsUnique(payload, errors) {
  const seen = new Set()
  for (const entry of payload.applied_dispositions ?? []) {
    if (typeof entry.finding_id !== 'string') continue
    if (seen.has(entry.finding_id)) {
      errors.push(`$result.payload.applied_dispositions: duplicate finding_id ${entry.finding_id}`)
    }
    seen.add(entry.finding_id)
  }
}

// checkIntegratorFindingIds — findings[].id must be unique within the
// payload (no schema keyword expresses cross-array uniqueness on a
// sub-key, same reasoning as checkFindingIds' reviewer-side duplicate
// check) AND unique within the run (given prior-run context, --known-ids
// — same semantics as checkFindingIds' reviewer-side collision check: an
// integration finding id is unique within the run by construction exactly
// like a reviewer finding id); its <round> segment (the r<N>) must equal
// integration_round (result.integrator.schema.json's findings[]
// description) — the id's grammar names WHICH integrator pass surfaced
// the finding, so a mismatch is two fields disagreeing about the same
// fact. This is integration_round, never codex_cycle.cycle: cycle counts
// Codex cycles specifically and is null whenever no Codex cycle ran this
// pass, while integration_round counts the pass itself and is always
// present — see integration_round's own schema description for the full
// distinction between it, cycle, and attempt. Its finder segment must
// also be non-empty — the schema's own [a-z0-9-]+ pattern already
// guarantees this structurally, restated here because parseFindingId's
// shared (.+) group is looser than any one schema's own character class.
// Always runs for role integrator.
function checkIntegratorFindingIds(envelope, options, errors) {
  const { payload } = envelope
  if (!Array.isArray(payload.findings)) return
  const expectedRound = payload.integration_round
  const seen = new Set()
  for (const finding of payload.findings) {
    if (typeof finding.id !== 'string') continue
    if (seen.has(finding.id)) {
      errors.push(`$result.payload.findings: duplicate finding id ${finding.id} within this payload`)
    }
    seen.add(finding.id)
    if (Array.isArray(options.knownIds) && options.knownIds.includes(finding.id)) {
      errors.push(
        `$result.payload.findings: finding id ${finding.id} collides with a finding already in the run`
      )
    }
    const parsed = parseFindingId(finding.id)
    if (!parsed) continue
    if (parsed.round !== expectedRound) {
      errors.push(
        `$result.payload.findings: finding id ${finding.id} names round ${parsed.round}, integration_round is ${expectedRound}`
      )
    }
    if (parsed.finder.length === 0) {
      errors.push(`$result.payload.findings: finding id ${finding.id} has an empty finder segment`)
    }
  }
}

// checkAppliedDispositionsKnownFindingIds — optional (--known-ids
// supplied): every applied_dispositions[].finding_id must be either a
// finding this payload's OWN findings[] just raised, or one --known-ids
// already knows about (a finding from an earlier cycle this disposition
// is now resolving). Without --known-ids there is no way to distinguish
// "a legitimate reference to an older finding" from "a typo or garbage
// finding_id", so this stays unchecked entirely until the flag supplies
// that universe — the same reasoning --known-ids already uses for the
// collision check above.
function checkAppliedDispositionsKnownFindingIds(payload, knownIds, errors) {
  if (!Array.isArray(knownIds)) return
  const currentFindingIds = new Set(
    (payload.findings ?? []).filter((finding) => typeof finding.id === 'string').map((finding) => finding.id)
  )
  const known = new Set(knownIds)
  for (const entry of payload.applied_dispositions ?? []) {
    if (typeof entry.finding_id !== 'string') continue
    if (!currentFindingIds.has(entry.finding_id) && !known.has(entry.finding_id)) {
      errors.push(
        `$result.payload.applied_dispositions: finding_id ${entry.finding_id} is neither one of this payload's own findings nor in --known-ids`
      )
    }
  }
}

// checkIntegratorCleanVerdict — a `clean` verdict is a claim about the
// WHOLE payload, not just its own field: at least one check must actually
// have run (AGENTS.md's readiness gate: an empty check list is
// indeterminate, not a pass) and every one of them green-or-skipped, no
// thread may be left unanswered, the Codex cycle (if any) must itself be
// clean, and every finding raised must be accounted for by an applied
// disposition of `decline` or `file` specifically — `fix`/`restructure`/
// `delete` all change code (so the changed code has never itself been
// through a cycle) and `defer` explicitly carries the finding forward;
// none of the four leaves the head exactly as claimed. Same-document,
// always runs for role integrator — `verdict` and everything it
// constrains are all sibling fields of one payload instance.
function checkIntegratorCleanVerdict(payload, errors) {
  if (payload.verdict !== 'clean') return
  if (!Array.isArray(payload.checks) || payload.checks.length === 0) {
    errors.push('$result.payload.checks: must be non-empty when verdict is clean — an empty check list is indeterminate, not a pass')
  }
  for (const check of payload.checks ?? []) {
    if (check.required === true) {
      if (check.bucket !== 'pass') {
        errors.push(
          `$result.payload.checks: ${check.name} is required but has bucket ${JSON.stringify(check.bucket)}, incompatible with verdict clean`
        )
      }
    } else if (check.bucket !== 'pass' && check.bucket !== 'skipping') {
      errors.push(
        `$result.payload.checks: ${check.name} has bucket ${JSON.stringify(check.bucket)}, incompatible with verdict clean`
      )
    }
  }
  if (Array.isArray(payload.unanswered_thread_roots) && payload.unanswered_thread_roots.length > 0) {
    errors.push('$result.payload.unanswered_thread_roots: must be empty when verdict is clean')
  }
  const cycle = payload.codex_cycle
  if (cycle !== null && cycle !== undefined) {
    if (cycle.exit_code !== 0 || !cycle.accepted) {
      errors.push(
        '$result.payload.codex_cycle: must be null, or exit_code 0 with accepted present, when verdict is clean'
      )
    }
  }
  const appliedTo = new Map(
    (payload.applied_dispositions ?? [])
      .filter((entry) => typeof entry.finding_id === 'string')
      .map((entry) => [entry.finding_id, entry.disposition])
  )
  // A clean verdict is a claim that the head needs no further review. Only
  // decline and file leave the head exactly as it is; fix/restructure/
  // delete all change code (so the changed code has never itself been
  // through a cycle), and defer explicitly carries the finding forward —
  // none of the four is compatible with "nothing outstanding."
  const currentFindingIds = new Set(
    (payload.findings ?? []).filter((finding) => typeof finding.id === 'string').map((finding) => finding.id)
  )
  for (const finding of payload.findings ?? []) {
    if (typeof finding.id !== 'string') continue
    const disposition = appliedTo.get(finding.id)
    if (disposition === undefined) {
      errors.push(
        `$result.payload.findings: finding ${finding.id} has no applied disposition, required when verdict is clean`
      )
    } else if (disposition !== 'decline' && disposition !== 'file') {
      errors.push(
        `$result.payload.applied_dispositions: finding ${finding.id}'s disposition ${disposition} is incompatible with verdict clean (only decline or file leave the head unchanged — fix/restructure/delete change code the next cycle would need to review, and defer carries the finding forward)`
      )
    }
  }
  // The loop above only reaches applied_dispositions entries for THIS
  // payload's own findings[]. An entry can also reference a finding
  // supplied via --known-ids (a prior cycle's finding this run is now
  // resolving) — checkAppliedDispositionsKnownFindingIds allows that
  // reference to exist, but never examines ITS disposition, so a clean
  // verdict could carry a known-id's defer forward unexamined. Every
  // applied_dispositions entry gets the same defer check here, regardless
  // of which universe its finding_id belongs to.
  for (const entry of payload.applied_dispositions ?? []) {
    if (
      entry.disposition === 'defer' &&
      typeof entry.finding_id === 'string' &&
      !currentFindingIds.has(entry.finding_id)
    ) {
      errors.push(
        `$result.payload.applied_dispositions: finding ${entry.finding_id}'s disposition defer is incompatible with verdict clean, even when supplied via --known-ids rather than raised by this payload — a clean verdict claims nothing is outstanding, and defer explicitly carries the finding forward`
      )
    }
  }
}

// validateEnvelopeInstance INSTANCE KIND OPTIONS — the full envelope +
// payload + receipt-validation pipeline, shared by the top-level `<kind>
// <file>` invocation and by --pass's own pre-validation of the reviewer
// envelope it names (kind: 'reviewer', OPTIONS carrying no run context).
function validateEnvelopeInstance(instance, kind, options) {
  const envelopeSchema = loadSchema('result.envelope.schema.json')
  const errors = validateAgainst(envelopeSchema, instance, '$result')

  // `envelope` dispatches on the instance's own role — it is NOT a
  // payload-blind mode. A caller who already knows the role (kind is one of
  // implementer/reviewer/integrator) gets the extra assertion that the
  // instance's role agrees with what they expected.
  if (errors.length === 0) {
    if (kind !== 'envelope' && instance.role !== kind) {
      errors.push(`$result.role: expected ${kind}, found ${JSON.stringify(instance.role)}`)
    } else {
      const role = instance.role
      const payloadSchema = loadSchema(`result.${role}.schema.json`)
      errors.push(...validateAgainst(payloadSchema, instance.payload, '$result.payload'))
      if (errors.length === 0) {
        checkActiveRun(instance, options, errors)
        if (role === 'implementer') checkImplementerStatus(instance, errors)
        if (role === 'reviewer' || role === 'challenger') {
          checkReviewerBlockedStatus(instance, errors)
          checkFindingIds(instance, options, errors)
        }
        if (role === 'challenger') checkChallengerAttackScenarios(instance, errors)
        if (role === 'integrator') {
          checkIntegratorBlockedStatus(instance, errors)
          checkCodexCycleAcceptedScope(instance.payload, errors)
          checkCodexCycleExitCodeVerdict(instance.payload, errors)
          checkAppliedDispositionsUnique(instance.payload, errors)
          checkAppliedDispositionsKnownFindingIds(instance.payload, options.knownIds, errors)
          checkIntegratorCleanVerdict(instance.payload, errors)
          checkIntegratorFindingIds(instance, options, errors)
          checkIntegratorSettledAtAgreement(instance, errors)
        }
        checkHeadAgreement(role, instance, errors)
      }
    }
  }
  checkTimestampRealness(instance, errors, '$result')
  return errors
}

// checkAdjudicationEntries — internal self-consistency, always run: no
// duplicate finding_id within the document; reviewer_priority's nullness
// matches its stage (non-null — one of P0-P3 — for challenge/review, since
// every reviewer finding carries one; null for integration, since an
// integrator finding carries no reviewer-asserted priority to copy — the
// schema only bounds the SHAPE of whichever it is, not which stage gets
// which, since `stage` is a sibling field the payload-only enum/type check
// cannot see). For challenge/review, override is present (with a reason)
// exactly when adjudicated_priority differs from reviewer_priority. For
// integration, override is unconditionally null — there is no reviewer
// priority for adjudicated_priority to differ FROM, so the
// differs-from-what comparison this rule is built on does not apply; an
// override here would claim a disagreement that cannot exist.
function checkAdjudicationEntries(document, errors) {
  if (!Array.isArray(document.adjudications)) return
  const seen = new Set()
  const isIntegration = document.stage === 'integration'
  for (const entry of document.adjudications) {
    if (typeof entry.finding_id === 'string') {
      if (seen.has(entry.finding_id)) {
        errors.push(`$adjudication.adjudications: duplicate finding_id ${entry.finding_id}`)
      }
      seen.add(entry.finding_id)
    }
    // Every adjudication explains itself (the schema's own required-field
    // description for `reason`) and cites evidence — minLength:1 alone
    // accepts a whitespace-only string, leaving the durable orchestrator
    // verdict without a usable rationale despite passing the schema. Same
    // trimmed-non-empty rule already applied to override.reason below.
    if (typeof entry.reason !== 'string' || entry.reason.trim() === '') {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}].reason: required (non-empty after trimming whitespace)`
      )
    }
    if (typeof entry.evidence !== 'string' || entry.evidence.trim() === '') {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}].evidence: required (non-empty after trimming whitespace)`
      )
    }
    // reference's shape (type/value both present) is a schema keyword; a
    // VALUE that cannot actually identify the declared resource is not —
    // the same reasoning checkSettlementReferenceType already applies to
    // run.settlements[].reference, reused verbatim here (challenge r1) so
    // durable adjudication evidence cannot be structurally valid but
    // unusable ({type:"sha", value:"x"}, {type:"issue_number", value:"0"}).
    // Type-value shape alone does not bind the reference to the disposition
    // it is meant to evidence: {disposition:"file", reference:{type:"sha"}}
    // passed schema and value-format checks alike despite the SHA never
    // confirming a filed issue. The three dispositions a reference can
    // meaningfully evidence at adjudication time (schema description above:
    // "declined or filed directly") map exactly as checkSettlementReferenceType
    // already maps them for a resolved defer's eventual settlement — fix to
    // the commit that fixed it, decline to the comment explaining why, file
    // to the issue it was filed as (challenge r2). A reference on any OTHER
    // disposition is rejected outright rather than left unconstrained
    // (challenge r3): restructure and delete have no settlement analogue to
    // evidence with, and defer's own evidence belongs on its eventual
    // settlement instead — the schema description's own "never deferred"
    // promise, which was previously only documented, not enforced.
    if (entry.reference && typeof entry.reference === 'object') {
      const { reference } = entry
      const expectedReferenceType = { fix: 'sha', file: 'issue_number', decline: 'comment_id' }
      const expected = expectedReferenceType[entry.disposition]
      if (!expected) {
        errors.push(
          `$adjudication.adjudications[finding_id=${entry.finding_id}].reference: disposition ${entry.disposition} cannot carry a reference — only fix, decline, and file can be evidenced at adjudication time`
        )
      } else if (reference.type !== expected) {
        errors.push(
          `$adjudication.adjudications[finding_id=${entry.finding_id}].reference.type: disposition ${entry.disposition} requires type ${expected}, found ${JSON.stringify(reference.type)}`
        )
      } else if (reference.type === 'sha' && typeof reference.value === 'string' && !SHA_PATTERN.test(reference.value)) {
        errors.push(
          `$adjudication.adjudications[finding_id=${entry.finding_id}].reference.value: type sha requires a 40-hex value`
        )
      } else if (
        reference.type === 'issue_number' &&
        typeof reference.value === 'string' &&
        !ISSUE_NUMBER_PATTERN.test(reference.value)
      ) {
        errors.push(
          `$adjudication.adjudications[finding_id=${entry.finding_id}].reference.value: type issue_number requires a positive integer string or an owner/repo#<n> qualified string`
        )
      } else if (
        reference.type === 'comment_id' &&
        typeof reference.value === 'string' &&
        reference.value.trim() === ''
      ) {
        errors.push(
          `$adjudication.adjudications[finding_id=${entry.finding_id}].reference.value: type comment_id requires a non-empty value`
        )
      }
    }
    if (isIntegration) {
      if (entry.reviewer_priority !== null) {
        errors.push(
          `$adjudication.adjudications[finding_id=${entry.finding_id}].reviewer_priority: must be null for stage integration (no reviewer pass to copy a priority from)`
        )
      }
      if (entry.override !== null) {
        errors.push(
          `$adjudication.adjudications[finding_id=${entry.finding_id}].override: must be null for stage integration (there is no reviewer priority for adjudicated_priority to differ from)`
        )
      }
      if (entry.disposition === 'defer') {
        errors.push(
          `$adjudication.adjudications[finding_id=${entry.finding_id}].disposition: defer is not allowed for stage integration (an integration finding needs a terminal answer: fix, restructure, delete, decline, or file)`
        )
      }
      continue
    }
    if (entry.reviewer_priority === null) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}].reviewer_priority: must not be null outside stage integration`
      )
      continue
    }
    if (entry.reviewer_priority === entry.adjudicated_priority) {
      if (entry.override !== null) {
        errors.push(
          `$adjudication.adjudications[finding_id=${entry.finding_id}].override: must be null when adjudicated_priority equals reviewer_priority`
        )
      }
    } else if (
      entry.override === null ||
      typeof entry.override !== 'object' ||
      typeof entry.override.reason !== 'string' ||
      entry.override.reason.trim() === ''
    ) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}].override: required (with a reason) when adjudicated_priority (${entry.adjudicated_priority}) differs from reviewer_priority (${entry.reviewer_priority})`
      )
    }
  }
}

// checkAdjudicationIdAttribution — self-contained (no --pass needed): a
// finding id's <stage>-r<round> segments are part of its own grammar, so
// they must equal the document's own stage/round without any external
// context at all.
function checkAdjudicationIdAttribution(document, errors) {
  for (const entry of document.adjudications ?? []) {
    if (typeof entry.finding_id !== 'string') continue
    const parsed = parseFindingId(entry.finding_id)
    if (!parsed) continue
    if (parsed.stage !== document.stage) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}]: names stage ${parsed.stage}, document is stage ${document.stage}`
      )
    }
    if (parsed.round !== document.round) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}]: names round ${parsed.round}, document is round ${document.round}`
      )
    }
  }
}

// checkAdjudicationUniqueAcrossRun — mirrors checkFindingIds' --known-ids
// collision check exactly, one document at a time: a finding is adjudicated
// in exactly one round document, ever, so any id already adjudicated by an
// earlier round (--known-adjudicated) is a collision here too.
function checkAdjudicationUniqueAcrossRun(document, options, errors) {
  if (!Array.isArray(options.knownAdjudicated)) return
  for (const entry of document.adjudications ?? []) {
    if (typeof entry.finding_id === 'string' && options.knownAdjudicated.includes(entry.finding_id)) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}]: already adjudicated in an earlier round document of this run`
      )
    }
  }
}

// checkAdjudicationAgainstPass — cross-checks an adjudication document
// against the pass(es) it adjudicates (--pass, repeatable — a logical
// challenge/review round is one pass per configured finder at the same
// reviewed_head, spec § Configuration; a logical integration round is
// exactly ONE integrator envelope, so more than one --pass for stage
// integration is rejected outright, naming the extra file, before
// anything else in this function runs). Every pass agrees with every
// other on its full run identity — run_id AND initiated_by, the pair that
// names a run (result.envelope.schema.json's `run` description) — and,
// for challenge/review, stage/round/reviewed_head too (mismatch names the
// offending pass file); when the caller also supplies
// --run-id/--initiated-by (OPTIONS, the active run), every pass is
// checked against that identity too, not only against each other. Every
// finding across the
// UNION of the passes has exactly one adjudication entry, no entry names
// an id absent from every pass; and, for challenge/review, each entry's
// reviewer_priority matches its finding's own priority, and every pass
// names a distinct finder. Stage integration skips both of those last
// two: an integrator payload carries no `finder` (there is exactly one
// integrator per attempt, never multiple finders producing multiple
// passes) and its findings carry no reviewer-asserted `priority` to
// compare against (ai/schemas/README.md). The head binding is NOT
// skipped, though: `document.reviewed_head` is still checked, just
// against the (single) pass's ENVELOPE `head` rather than a
// `payload.reviewed_head` field integrator payloads don't have. Without
// --pass, none of this runs — the document is still schema-valid and
// self-consistent on its own (checkAdjudicationEntries), just not
// cross-checked against anything external.
function checkAdjudicationAgainstPass(document, passes, options, errors) {
  if (passes.length === 0) return
  const isIntegration = document.stage === 'integration'
  // A challenge/review round is one pass PER FINDER (so more than one
  // --pass is normal); an integration round is exactly one integrator
  // envelope — there is only ever one integrator per attempt, so a
  // second --pass here is never legitimate, and the multi-pass agreement
  // checks below (which read fields like payload.stage/round/finder that
  // an integrator payload doesn't even have) do not apply to it either.
  if (isIntegration && passes.length > 1) {
    errors.push(
      `$adjudication: stage integration accepts at most one --pass (an integration round is exactly one integrator envelope) — found an extra one at ${passes[1].file}`
    )
    return
  }
  // Every --pass must belong to the SAME run identity: its own run_id AND
  // initiated_by, not just run_id — a run's identity is the pair (see
  // result.envelope.schema.json's `run` description). When the caller also
  // supplies --run-id/--initiated-by (the active run it considers this
  // adjudication to be checked against), every pass is checked against
  // THAT identity too, not only against each other.
  for (const { file, data } of passes) {
    if (options.runId !== null && (data.run.run_id !== options.runId || data.run.initiated_by !== options.initiatedBy)) {
      errors.push(
        `$adjudication: --pass ${file} has run {run_id: ${JSON.stringify(data.run.run_id)}, initiated_by: ${JSON.stringify(
          data.run.initiated_by
        )}} which is not the active run {run_id: ${JSON.stringify(options.runId)}, initiated_by: ${JSON.stringify(
          options.initiatedBy
        )}}`
      )
    }
  }
  const [reference, ...rest] = passes
  for (const other of rest) {
    if (other.data.run.run_id !== reference.data.run.run_id) {
      errors.push(
        `$adjudication: --pass ${other.file} has run_id ${other.data.run.run_id}, disagreeing with ${reference.file}'s ${reference.data.run.run_id}`
      )
    }
    if (other.data.run.initiated_by !== reference.data.run.initiated_by) {
      errors.push(
        `$adjudication: --pass ${other.file} has initiated_by ${other.data.run.initiated_by}, disagreeing with ${reference.file}'s ${reference.data.run.initiated_by}`
      )
    }
    if (other.data.payload.stage !== reference.data.payload.stage) {
      errors.push(
        `$adjudication: --pass ${other.file} has stage ${other.data.payload.stage}, disagreeing with ${reference.file}'s ${reference.data.payload.stage}`
      )
    }
    if (other.data.payload.round !== reference.data.payload.round) {
      errors.push(
        `$adjudication: --pass ${other.file} has round ${other.data.payload.round}, disagreeing with ${reference.file}'s ${reference.data.payload.round}`
      )
    }
    if (other.data.payload.reviewed_head !== reference.data.payload.reviewed_head) {
      errors.push(
        `$adjudication: --pass ${other.file} has reviewed_head ${other.data.payload.reviewed_head}, disagreeing with ${reference.file}'s ${reference.data.payload.reviewed_head}`
      )
    }
    // A confidence round aggregates passes from ONE stage role (challenge ->
    // challenger, review -> reviewer) — never a mix. This only bites for
    // stage challenge, where a --pass may now be EITHER role (a pre-#635
    // reviewer trajectory or a #635 challenger one, see passAllowedRoles
    // above): allowing that per-file is correct, but the passes making up
    // ONE round must still all agree with each other, or a round could
    // combine two different evidence contracts (result.challenger findings
    // alongside result.reviewer ones) into one adjudication.
    if (!isIntegration && other.data.role !== reference.data.role) {
      errors.push(
        `$adjudication: --pass ${other.file} has role ${other.data.role}, disagreeing with ${reference.file}'s ${reference.data.role} — a round aggregates passes from one role, never a mix`
      )
    }
  }

  // A challenge/review round is one pass per configured finder (spec §
  // Configuration); a retry REPLACES that finder's pass, it never joins a
  // second one at its side. Two --pass files naming the same finder are
  // therefore never a legitimate two-finder round — reject and name the
  // finder. Not applicable to integration: no `finder` field exists there.
  if (!isIntegration) {
    const finderSeenAt = new Map()
    for (const { file, data } of passes) {
      const finder = data.payload.finder
      if (finderSeenAt.has(finder)) {
        errors.push(
          `$adjudication: --pass ${file} repeats finder ${finder}, already supplied by ${finderSeenAt.get(finder)} — a round is one pass per finder`
        )
      } else {
        finderSeenAt.set(finder, file)
      }
    }
  }

  const passFindings = new Map()
  for (const { data } of passes) {
    for (const finding of data.payload.findings ?? []) {
      if (typeof finding.id === 'string') passFindings.set(finding.id, finding)
    }
  }
  const adjudicated = new Set()
  for (const entry of document.adjudications ?? []) {
    if (typeof entry.finding_id !== 'string') continue
    adjudicated.add(entry.finding_id)
    const finding = passFindings.get(entry.finding_id)
    if (!finding) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}]: names a finding id absent from every --pass`
      )
      continue
    }
    if (!isIntegration && entry.reviewer_priority !== finding.priority) {
      errors.push(
        `$adjudication.adjudications[finding_id=${entry.finding_id}].reviewer_priority: ${entry.reviewer_priority} does not match the pass finding's own priority ${finding.priority}`
      )
    }
  }
  for (const id of passFindings.keys()) {
    if (!adjudicated.has(id)) {
      errors.push(`$adjudication.adjudications: pass finding ${id} has no adjudication entry`)
    }
  }

  const { run: referenceRun, payload: referencePayload } = reference.data
  if (document.run_id !== referenceRun.run_id) {
    errors.push(`$adjudication.run_id: ${document.run_id} does not match the pass envelope's run.run_id ${referenceRun.run_id}`)
  }
  if (isIntegration) {
    // An integrator payload has no reviewed_head field of its own — the
    // equivalent fact lives on the ENVELOPE (reference.data.head), so the
    // head-binding check compares against that instead of referencePayload.
    if (document.reviewed_head !== reference.data.head) {
      errors.push(
        `$adjudication.reviewed_head: ${document.reviewed_head} does not match the pass envelope's head ${reference.data.head}`
      )
    }
    // Likewise, an integrator payload has no `round` field — the
    // equivalent fact is WHICH integrator pass this round is
    // (integration_round, the SAME field checkIntegratorFindingIds reads
    // off the pass's own finding ids — never codex_cycle.cycle, which is
    // null whenever no Codex cycle ran this pass and so cannot stand in
    // for the pass's own ordinal), so the document's `round` is checked
    // against integration_round.
    const expectedRound = reference.data.payload.integration_round
    if (document.round !== expectedRound) {
      errors.push(
        `$adjudication.round: ${document.round} does not match the pass envelope's integration_round ${expectedRound}`
      )
    }
    return
  }
  if (document.stage !== referencePayload.stage) {
    errors.push(`$adjudication.stage: ${document.stage} does not match the pass payload's stage ${referencePayload.stage}`)
  }
  if (document.round !== referencePayload.round) {
    errors.push(`$adjudication.round: ${document.round} does not match the pass payload's round ${referencePayload.round}`)
  }
  if (document.reviewed_head !== referencePayload.reviewed_head) {
    errors.push(
      `$adjudication.reviewed_head: ${document.reviewed_head} does not match the pass payload's reviewed_head ${referencePayload.reviewed_head}`
    )
  }
}

// validateAdjudicationInstance INSTANCE — schema + the always-on internal
// checks, shared by the top-level `adjudication <file>` invocation and by
// --adjudication's own pre-validation before it is used as run-kind
// context.
function validateAdjudicationInstance(instance) {
  const schema = loadSchema('adjudication.schema.json')
  const errors = validateAgainst(schema, instance, '$adjudication')
  if (errors.length === 0) {
    checkAdjudicationEntries(instance, errors)
    checkAdjudicationIdAttribution(instance, errors)
  }
  checkTimestampRealness(instance, errors, '$adjudication')
  return errors
}

function checkSettlements(document, errors) {
  if (!Array.isArray(document.settlements)) return
  const seen = new Set()
  for (const entry of document.settlements) {
    if (typeof entry.finding_id !== 'string') continue
    if (seen.has(entry.finding_id)) {
      errors.push(`$run.settlements: duplicate finding_id ${entry.finding_id} — one settlement per finding`)
    }
    seen.add(entry.finding_id)
  }
}

// checkSettlementReferenceType — a settlement's reference.type must match
// its disposition (fix -> sha, file -> issue_number, decline -> comment_id)
// and the value must be shaped for that type. Same-document: disposition
// and reference are sibling fields of one settlement entry.
function checkSettlementReferenceType(document, errors) {
  const expectedType = { fix: 'sha', file: 'issue_number', decline: 'comment_id' }
  for (const [index, entry] of (document.settlements ?? []).entries()) {
    const reference = entry.reference
    if (!reference || typeof reference !== 'object') continue
    const expected = expectedType[entry.disposition]
    if (expected && reference.type !== expected) {
      errors.push(
        `$run.settlements[${index}].reference.type: disposition ${entry.disposition} requires type ${expected}, found ${JSON.stringify(reference.type)}`
      )
      continue
    }
    if (reference.type === 'sha' && typeof reference.value === 'string' && !SHA_PATTERN.test(reference.value)) {
      errors.push(`$run.settlements[${index}].reference.value: type sha requires a 40-hex value`)
    } else if (
      reference.type === 'issue_number' &&
      typeof reference.value === 'string' &&
      !ISSUE_NUMBER_PATTERN.test(reference.value)
    ) {
      errors.push(`$run.settlements[${index}].reference.value: type issue_number requires a positive integer string or an owner/repo#<n> qualified string`)
    } else if (reference.type === 'comment_id' && typeof reference.value === 'string' && reference.value.trim() === '') {
      errors.push(`$run.settlements[${index}].reference.value: type comment_id requires a non-empty value`)
    }
  }
}

// ALLOWED_EDGES — the run-span subset of docs/product/domain.md's "Dev
// flow" lifecycle (§ Lifecycles, the `stateDiagram-v2` under "Dev flow —
// the lifecycle of one change"): stages 1-10 (kickoff..integration, the
// run's own defined span — see run.schema.json's stage enum $comment),
// with every `--> escalate` edge from that diagram deliberately excluded,
// since `escalate` is not itself a stage_transitions value — an escalated
// run instead ends its last real transition's `exit` and sets
// `outcome: "escalated"` (already enforced below, unrelated to this
// table). This is an exact transcription, not a derived "any forward
// index" approximation: challenge, for instance, can reach review or loop
// back to implement, but — unlike a plain monotonic-index rule would
// allow — can never jump straight to security or integration, because the
// diagram draws no such edge.
const ALLOWED_EDGES = {
  kickoff: new Set(['claim']),
  claim: new Set(['explore', 'plan']),
  explore: new Set(['plan']),
  plan: new Set(['implement']),
  implement: new Set(['verify', 'integration']),
  verify: new Set(['challenge', 'review', 'security']),
  challenge: new Set(['implement', 'review']),
  review: new Set(['implement', 'security']),
  security: new Set(['integration', 'implement']),
  integration: new Set(['implement'])
}

// checkStageTransitionsOrder — array-wide coherence the schema's minItems/
// per-entry required/enum keywords cannot express (no positional "first
// item" or "permitted-edge-between-siblings" keyword in this subset
// engine): the first entry is kickoff, and every later entry is reached
// from the one right before it by an edge ALLOWED_EDGES actually lists —
// never any other transition, including a repeat of the SAME entry twice
// in a row (no stage has an edge to itself). A stage on a legal remediation
// loop (e.g. challenge, reached again via verify after looping back through
// implement) CAN recur later in the array — this checks only the pairwise
// edge from each entry's immediate predecessor, never a once-per-array
// uniqueness rule. Every entry but the last also records how/why it ended.
// An entry whose own `stage` failed the schema's enum is skipped here
// (parseFindingId-style "shape violations are the schema's job, not this
// check's"). Whether verify's other two listed edges (verify -> review,
// verify -> security) are legitimate on a given run's FIRST pass depends
// on the resolved .devflow.toml challenge/review caps — config this
// single-document validator does not have — so that history-sensitivity
// is intentionally NOT checked here; it belongs to the exit script (#636).
function checkStageTransitionsOrder(document, errors) {
  const transitions = document.stage_transitions
  if (!Array.isArray(transitions) || transitions.length === 0) return
  if (transitions[0].stage !== 'kickoff') {
    errors.push(
      `$run.stage_transitions[0].stage: must be "kickoff" (the run's first transition), found ${JSON.stringify(transitions[0].stage)}`
    )
  }
  let previousStage = Object.hasOwn(ALLOWED_EDGES, transitions[0].stage) ? transitions[0].stage : null
  let everVisitedIntegration = previousStage === 'integration'
  for (let index = 1; index < transitions.length; index += 1) {
    const transition = transitions[index]
    if (!Object.hasOwn(ALLOWED_EDGES, transition.stage)) continue
    if (previousStage !== null) {
      const edgeListed = ALLOWED_EDGES[previousStage].has(transition.stage)
      // implement -> integration is the diagram's REMEDIATION RETURN edge
      // ("remediation fix verified and pushed") — it presupposes a prior
      // trip to integration to remediate FROM. On the run's first pass
      // through implement, the only legal forward edge is to verify; a
      // first-visit implement -> integration would skip verify/challenge/
      // review/security entirely, which the diagram never permits.
      const isPrematureRemediationReturn =
        previousStage === 'implement' && transition.stage === 'integration' && !everVisitedIntegration
      if (!edgeListed || isPrematureRemediationReturn) {
        errors.push(
          `$run.stage_transitions[${index}].stage: ${transition.stage} is not a valid transition from ${previousStage} (docs/product/domain.md § Lifecycles)`
        )
      }
    }
    if (transition.stage === 'integration') everVisitedIntegration = true
    previousStage = transition.stage
  }
  // While the run is still going (outcome: null), the LAST entry is the
  // run's current stage and has nothing to record an exit for yet; every
  // earlier entry has already been left, so it must have one. Once outcome
  // is decided (non-null — the run has ended, one way or another), the run
  // is no longer "still in" any stage, so the last entry owes an exit too.
  const ended = document.outcome !== null && document.outcome !== undefined
  for (const [index, transition] of transitions.entries()) {
    if (index === transitions.length - 1 && !ended) continue
    if (typeof transition.exit !== 'string' || transition.exit.trim() === '') {
      errors.push(`$run.stage_transitions[${index}].exit: required (non-empty)`)
    }
  }
  // Reaching ready-for-review always means the run got through integration
  // (the readiness gate promotes a draft PR integrated out of that stage —
  // AGENTS.md's Dev Loop), so the last stage_transitions entry must BE
  // integration, not merely have progressed at all.
  if (document.outcome === 'ready-for-review') {
    const lastIndex = transitions.length - 1
    if (transitions[lastIndex].stage !== 'integration') {
      errors.push(
        `$run.stage_transitions[${lastIndex}].stage: must be "integration" when outcome is "ready-for-review", found ${JSON.stringify(transitions[lastIndex].stage)}`
      )
    }
  }
}

// isChronologicallyBefore A B — true iff timestamp A is strictly before B.
// Compares via Date, not raw string ordering: two otherwise-identical
// instants can be spelled with or without a fractional-seconds suffix
// (e.g. "...:00Z" vs "...:00.500Z"), and lexicographic string comparison
// gets that pair backwards ('.' sorts below 'Z'). A malformed value (also
// checkTimestampRealness's job, not this one's) parses to NaN, and every
// comparison against NaN is false — so a bad timestamp here simply never
// trips a chronology error, rather than tripping one for the wrong reason.
function isChronologicallyBefore(a, b) {
  return new Date(a).getTime() < new Date(b).getTime()
}

// checkRunChronology — same-document ordering the schema's per-field
// pattern keyword cannot express (it proves a value LOOKS like a
// timestamp, never that it falls in the right place relative to another
// field): started_at must be no later than the first stage_transitions
// entry's entered_at; entered_at must be non-decreasing across entries;
// promotion.promoted_at must be no earlier than the last entry's
// entered_at; every intervention's `at` and every settlement's
// `settled_at` must be no earlier than started_at, and no later than
// promotion.promoted_at when the run has been promoted; and a
// settlement's `settled_at` must additionally be no earlier than the
// run's first `integration` transition's entered_at (a deferred finding
// is settled during integration, never before the run has even reached
// it). Always runs — every value compared lives in this one
// run.schema.json document.
function checkRunChronology(document, errors) {
  const startedAt = document.started_at
  const transitions = Array.isArray(document.stage_transitions) ? document.stage_transitions : []
  if (
    typeof startedAt === 'string' &&
    transitions.length > 0 &&
    typeof transitions[0].entered_at === 'string' &&
    isChronologicallyBefore(transitions[0].entered_at, startedAt)
  ) {
    errors.push(
      `$run.stage_transitions[0].entered_at: ${transitions[0].entered_at} must not be before started_at ${startedAt}`
    )
  }
  let previousEnteredAt = null
  for (const [index, transition] of transitions.entries()) {
    if (typeof transition.entered_at !== 'string') continue
    if (previousEnteredAt !== null && isChronologicallyBefore(transition.entered_at, previousEnteredAt)) {
      errors.push(
        `$run.stage_transitions[${index}].entered_at: ${transition.entered_at} must not be before the previous entry's entered_at ${previousEnteredAt}`
      )
    }
    previousEnteredAt = transition.entered_at
  }
  const lastEnteredAt =
    transitions.length > 0 && typeof transitions[transitions.length - 1].entered_at === 'string'
      ? transitions[transitions.length - 1].entered_at
      : null
  if (
    document.promotion &&
    typeof document.promotion === 'object' &&
    typeof document.promotion.promoted_at === 'string' &&
    lastEnteredAt !== null &&
    isChronologicallyBefore(document.promotion.promoted_at, lastEnteredAt)
  ) {
    errors.push(
      `$run.promotion.promoted_at: ${document.promotion.promoted_at} must not be before the last stage_transitions entry's entered_at ${lastEnteredAt}`
    )
  }
  if (typeof startedAt === 'string') {
    for (const [index, intervention] of (document.interventions ?? []).entries()) {
      if (typeof intervention.at === 'string' && isChronologicallyBefore(intervention.at, startedAt)) {
        errors.push(`$run.interventions[${index}].at: ${intervention.at} must not be before started_at ${startedAt}`)
      }
    }
    for (const [index, settlement] of (document.settlements ?? []).entries()) {
      if (typeof settlement.settled_at === 'string' && isChronologicallyBefore(settlement.settled_at, startedAt)) {
        errors.push(
          `$run.settlements[${index}].settled_at: ${settlement.settled_at} must not be before started_at ${startedAt}`
        )
      }
    }
  }
  // Upper bound: a settlement resolves a finding BEFORE the run can be
  // promoted (the readiness gate requires every deferred finding settled
  // first — checkDeferredFindingsSettledBeforePromotion), so once promoted
  // no settlement should postdate that promotion. Every human intervention
  // is bounded the same way: promotion is the last thing an agent does in
  // this run's own span (AGENTS.md's Dev Loop — merge is a separate human
  // decision afterward), so nothing recorded as an intervention DURING the
  // run can postdate it either.
  if (document.promotion && typeof document.promotion === 'object' && typeof document.promotion.promoted_at === 'string') {
    const promotedAt = document.promotion.promoted_at
    for (const [index, intervention] of (document.interventions ?? []).entries()) {
      if (typeof intervention.at === 'string' && isChronologicallyBefore(promotedAt, intervention.at)) {
        errors.push(
          `$run.interventions[${index}].at: ${intervention.at} must not be after promotion.promoted_at ${promotedAt}`
        )
      }
    }
    for (const [index, settlement] of (document.settlements ?? []).entries()) {
      if (typeof settlement.settled_at === 'string' && isChronologicallyBefore(promotedAt, settlement.settled_at)) {
        errors.push(
          `$run.settlements[${index}].settled_at: ${settlement.settled_at} must not be after promotion.promoted_at ${promotedAt}`
        )
      }
    }
  }
  // Lower bound, more specific than started_at above: a deferred finding is
  // settled DURING integration (specs/dev-flow-v2.md — settlement narrows a
  // defer to fix/decline/file, which the readiness gate requires before
  // promotion, and the readiness gate is what integration converges
  // toward), so no settlement should predate the run's first arrival there.
  const firstIntegrationEntry = transitions.find((transition) => transition.stage === 'integration')
  if (firstIntegrationEntry && typeof firstIntegrationEntry.entered_at === 'string') {
    const firstIntegrationAt = firstIntegrationEntry.entered_at
    for (const [index, settlement] of (document.settlements ?? []).entries()) {
      if (typeof settlement.settled_at === 'string' && isChronologicallyBefore(settlement.settled_at, firstIntegrationAt)) {
        errors.push(
          `$run.settlements[${index}].settled_at: ${settlement.settled_at} must not be before the first integration transition's entered_at ${firstIntegrationAt}`
        )
      }
    }
  }
}

// checkRunPromotionOutcome — promotion is non-null if and only if outcome
// is "ready-for-review", in both directions: a promoted run that reports a
// different outcome, or a ready-for-review outcome with no promotion
// entry, are both inconsistent documents. Reaching ready-for-review always
// means a PR exists (the readiness gate promotes a draft PR — there is no
// promotion without one), so both of those states additionally require a
// non-null `pr`. `pr` itself can go non-null earlier than either — AGENTS.md's
// Dev Loop opens the draft PR and only then enters the `integration` stage
// (that is what the draft PR's existence kicks off: integration, Codex
// cloud review cycles) — so a non-null `pr`, on its own, always requires
// stage_transitions to already record having reached `integration`; it is
// never legitimate for the PR to exist ahead of the run's own record of
// entering the stage the PR's existence triggers.
function checkRunPromotionOutcome(document, errors) {
  const promoted = document.promotion !== null && document.promotion !== undefined
  const ready = document.outcome === 'ready-for-review'
  if (promoted && !ready) {
    errors.push(`$run.promotion: present but outcome is ${JSON.stringify(document.outcome)}, not "ready-for-review"`)
  }
  if (ready && !promoted) {
    errors.push('$run.promotion: must be non-null when outcome is "ready-for-review"')
  }
  if ((promoted || ready) && (document.pr === null || document.pr === undefined)) {
    errors.push('$run.pr: must be non-null when outcome is "ready-for-review" or promotion is present')
  }
  const hasPr = document.pr !== null && document.pr !== undefined
  const hasIntegrationEntry =
    Array.isArray(document.stage_transitions) && document.stage_transitions.some((transition) => transition.stage === 'integration')
  if (hasPr && !hasIntegrationEntry) {
    errors.push('$run.pr: must be null unless stage_transitions records having reached "integration"')
  }
}

// checkEvidenceCommentsUniqueness — evidence_comments[].id is unique (it is
// the harvester's own lookup key), and each (marker.destination, marker.stage,
// marker.round, marker.sequence) tuple is unique (that tuple IS the
// deterministic marker the spec describes — two comments cannot legitimately
// share one). destination and round join stage/sequence in the key because
// they are what let a stage's per-round issue comment and that same stage's
// PR rollup comment coexist at sequence 1 without colliding: same stage,
// different destination/round.
function checkEvidenceCommentsUniqueness(document, errors) {
  const seenIds = new Set()
  const seenMarkers = new Set()
  for (const [index, comment] of (document.evidence_comments ?? []).entries()) {
    if (typeof comment.id === 'string') {
      if (seenIds.has(comment.id)) {
        errors.push(`$run.evidence_comments[${index}].id: duplicate comment id ${comment.id}`)
      }
      seenIds.add(comment.id)
    }
    const marker = comment.marker
    if (
      marker &&
      typeof marker.run_id === 'string' &&
      typeof marker.stage === 'string' &&
      (typeof marker.destination === 'string' || marker.destination === null) &&
      (typeof marker.round === 'number' || marker.round === null) &&
      typeof marker.sequence === 'number'
    ) {
      const key = JSON.stringify([marker.destination, marker.stage, marker.round, marker.sequence])
      if (seenMarkers.has(key)) {
        errors.push(
          `$run.evidence_comments[${index}].marker: duplicate marker (destination=${marker.destination}, stage=${marker.stage}, round=${marker.round}, sequence=${marker.sequence})`
        )
      }
      seenMarkers.add(key)
    }
  }
}

// checkEvidenceMarkerRunId — every evidence comment's marker names the SAME
// run it was posted for; a marker naming a foreign run_id could otherwise
// be adopted by the wrong run's harvester (spec § Evidence, "a deterministic
// marker — run_id, stage, sequence"). Context-free: both fields live in the
// one run.schema.json document, no external input needed.
function checkEvidenceMarkerRunId(document, errors) {
  if (!Array.isArray(document.evidence_comments)) return
  for (const [index, comment] of document.evidence_comments.entries()) {
    const marker = comment.marker
    if (marker && typeof marker.run_id === 'string' && marker.run_id !== document.run_id) {
      errors.push(
        `$run.evidence_comments[${index}].marker.run_id: ${marker.run_id} does not match the run's own run_id ${document.run_id}`
      )
    }
  }
}

// checkEvidenceMarkerStageVisited — an evidence comment's marker.stage
// names one of the run's own defined stages structurally (the schema's
// enum), but nothing schema-level proves this run's OWN history actually
// reached it — that fact lives in stage_transitions, a sibling array in
// the SAME document (unlike checkAdjudicationStagesVisited, which checks
// an EXTERNAL --adjudication document's stage against this run's history,
// this needs no context flag at all).
function checkEvidenceMarkerStageVisited(document, errors) {
  if (!Array.isArray(document.evidence_comments)) return
  const visitedStages = new Set((document.stage_transitions ?? []).map((transition) => transition.stage))
  for (const [index, comment] of document.evidence_comments.entries()) {
    const marker = comment.marker
    if (marker && typeof marker.stage === 'string' && !visitedStages.has(marker.stage)) {
      errors.push(
        `$run.evidence_comments[${index}].marker.stage: ${marker.stage} never appears in this run's stage_transitions`
      )
    }
  }
}

// checkEvidenceMarkerPrDestinationRequiresPr — a marker.destination of "pr"
// claims the per-stage rollup comment was posted to the draft PR, which the
// same run document says happens only "once the draft PR exists" (the
// marker.destination description above). A sibling field in the SAME
// document, `pr`, is exactly the run's own record of whether that PR
// exists yet (null until it does) — so a "pr"-destination marker alongside
// a null `pr` claims evidence at a destination the document's own other
// half says has not been created, context-free like
// checkEvidenceMarkerStageVisited above.
function checkEvidenceMarkerPrDestinationRequiresPr(document, errors) {
  if (!Array.isArray(document.evidence_comments)) return
  if (document.pr !== null && document.pr !== undefined) return
  for (const [index, comment] of document.evidence_comments.entries()) {
    const marker = comment.marker
    if (marker && marker.destination === 'pr') {
      errors.push(
        `$run.evidence_comments[${index}].marker.destination: "pr" requires a non-null $run.pr — this run has no PR yet`
      )
    }
  }
}

// checkEvidenceMarkerSequenceContiguity — spec § Evidence: sequence is
// "the Nth comment continuing this stage's evidence when GitHub's size
// limit forces a split" — which only makes sense counting from 1 with no
// gaps, WITHIN one (destination, stage, round) grouping, not across the
// whole array: a stage's per-round issue comment and that same stage's PR
// rollup comment are different groupings (different destination/round) and
// each starts its own split count at 1. checkEvidenceCommentsUniqueness
// already proves no two comments share a (destination, stage, round,
// sequence) tuple; this proves the sequence NUMBERS themselves, sorted
// within each grouping, are exactly 1..N — neither starting elsewhere nor
// skipping one.
function checkEvidenceMarkerSequenceContiguity(document, errors) {
  const sequencesByGroup = new Map()
  for (const comment of document.evidence_comments ?? []) {
    const marker = comment.marker
    if (
      !marker ||
      typeof marker.stage !== 'string' ||
      (typeof marker.destination !== 'string' && marker.destination !== null) ||
      (typeof marker.round !== 'number' && marker.round !== null) ||
      typeof marker.sequence !== 'number'
    ) {
      continue
    }
    const groupKey = JSON.stringify([marker.destination, marker.stage, marker.round])
    if (!sequencesByGroup.has(groupKey)) {
      sequencesByGroup.set(groupKey, { destination: marker.destination, stage: marker.stage, round: marker.round, sequences: [] })
    }
    sequencesByGroup.get(groupKey).sequences.push(marker.sequence)
  }
  for (const { destination, stage, round, sequences } of sequencesByGroup.values()) {
    const sorted = [...sequences].sort((a, b) => a - b)
    const contiguousFromOne = sorted.every((sequence, index) => sequence === index + 1)
    if (!contiguousFromOne) {
      errors.push(
        `$run.evidence_comments: marker (destination=${destination}, stage=${stage}, round=${round})'s sequences must start at 1 and be contiguous, found [${sorted.join(', ')}]`
      )
    }
  }
}

// checkAdjudicationRunIdMatchesRun — each --adjudication document's own
// run_id must equal the run record's run_id: a foreign run's adjudication
// document could otherwise settle a finding_id that only coincidentally
// collides with one from THIS run (finding ids are unique within a run,
// not globally). Named per offending file, same as the pass-agreement
// checks above.
function checkAdjudicationRunIdMatchesRun(document, adjudications, errors) {
  for (const { file, data } of adjudications) {
    if (data.run_id !== document.run_id) {
      errors.push(
        `$run: --adjudication ${file} has run_id ${data.run_id}, not this run's own run_id ${document.run_id}`
      )
    }
  }
}

// checkAdjudicationsUnionUnique — across the UNION of every supplied
// --adjudication document, a finding_id may be adjudicated at most once —
// independent of settlements. checkSettlementsAgainstAdjudications below
// only notices a cross-document collision when some settlement happens to
// reference the colliding finding_id; a finding double-adjudicated (two
// genuinely different round documents both claiming it, or literally the
// same document supplied twice) but never settled would otherwise pass
// unnoticed. Runs whenever one or more --adjudication files are supplied;
// with zero or one document, no cross-document collision is possible.
function checkAdjudicationsUnionUnique(adjudications, errors) {
  const seenAt = new Map()
  for (const { file, data } of adjudications) {
    for (const entry of data.adjudications ?? []) {
      if (typeof entry.finding_id !== 'string') continue
      if (seenAt.has(entry.finding_id)) {
        errors.push(
          `$run: finding ${entry.finding_id} is adjudicated more than once across the supplied --adjudication documents (${seenAt.get(entry.finding_id)}, ${file})`
        )
      } else {
        seenAt.set(entry.finding_id, file)
      }
    }
  }
}

// checkAdjudicationStagesVisited — a --adjudication document adjudicates a
// round of some stage (challenge/review/integration), but nothing proves
// the run ever actually WAS in that stage — that fact lives in a
// different document (run.schema.json's own stage_transitions). An
// adjudication naming a stage the run's own history never records
// entering is a document about a round this run could not have run.
// Runs alongside the other --adjudication-dependent checks, under the
// same --adjudication/--no-adjudications gating in main().
function checkAdjudicationStagesVisited(document, adjudications, errors) {
  const visitedStages = new Set((document.stage_transitions ?? []).map((transition) => transition.stage))
  for (const { file, data } of adjudications) {
    if (typeof data.stage === 'string' && !visitedStages.has(data.stage)) {
      errors.push(
        `$run: --adjudication ${file} has stage ${data.stage}, which never appears in this run's stage_transitions`
      )
    }
  }
}

// checkSettlementsAgainstAdjudications — every settlement's finding must be
// adjudicated exactly once across the union of the supplied --adjudication
// documents, with disposition defer (settlements only ever terminalize a
// deferred finding). The caller only reaches this with an ADJUDICATIONS
// array that is either non-empty (one or more --adjudication) or
// deliberately empty (--no-adjudications, a confirmed "zero documents") —
// there is no internal early-return on an empty array here, because for
// --no-adjudications an empty array must still reject every settlement
// (nothing can have adjudicated it), not silently pass. Without either
// flag, main() never calls this at all — settlements are still checked for
// internal duplicate finding_id (checkSettlements) but not against any
// adjudication.
function checkSettlementsAgainstAdjudications(document, adjudications, errors) {
  const byFindingId = new Map()
  for (const { file, data } of adjudications) {
    for (const entry of data.adjudications ?? []) {
      if (typeof entry.finding_id !== 'string') continue
      if (!byFindingId.has(entry.finding_id)) byFindingId.set(entry.finding_id, [])
      byFindingId.get(entry.finding_id).push({ disposition: entry.disposition, file })
    }
  }
  for (const [index, settlement] of (document.settlements ?? []).entries()) {
    const matches = byFindingId.get(settlement.finding_id) ?? []
    if (matches.length === 0) {
      errors.push(
        `$run.settlements[${index}]: finding ${settlement.finding_id} is not adjudicated in any supplied --adjudication document`
      )
      continue
    }
    if (matches.length > 1) {
      errors.push(
        `$run.settlements[${index}]: finding ${settlement.finding_id} is adjudicated more than once across the supplied --adjudication documents (${matches
          .map((match) => match.file)
          .join(', ')})`
      )
      continue
    }
    if (matches[0].disposition !== 'defer') {
      errors.push(
        `$run.settlements[${index}]: finding ${settlement.finding_id} was adjudicated ${matches[0].disposition}, not defer, in ${matches[0].file}`
      )
    }
  }
}

// checkDeferredFindingsSettledBeforePromotion — the converse of
// checkSettlementsAgainstAdjudications above (which forbids a settlement
// of anything but a deferred finding): a run cannot claim
// outcome: ready-for-review while a finding the supplied --adjudication
// documents deferred still has no settlement at all. "At most one
// settlement per finding" is already enforced (checkSettlements); this is
// the "at least one, once promoted" half, and only applies once promoted
// — a run still short of ready-for-review may legitimately have
// unsettled deferrals in flight.
function checkDeferredFindingsSettledBeforePromotion(document, adjudications, errors) {
  if (adjudications.length === 0 || document.outcome !== 'ready-for-review') return
  const settledIds = new Set(
    (document.settlements ?? [])
      .map((entry) => entry.finding_id)
      .filter((id) => typeof id === 'string')
  )
  for (const { data } of adjudications) {
    for (const entry of data.adjudications ?? []) {
      if (entry.disposition === 'defer' && typeof entry.finding_id === 'string' && !settledIds.has(entry.finding_id)) {
        errors.push(
          `$run.settlements: deferred finding ${entry.finding_id} has no settlement, required when outcome is ready-for-review`
        )
      }
    }
  }
}

// checkTimestampRealness — every *_at / at field must be a REAL instant, not
// merely regex-shaped: "2026-02-30T10:00:00Z" matches every schema's
// timestamp pattern but names a day that does not exist. JS's Date parser
// silently rolls an impossible date over into the next real one, so a
// round-trip through it — and back to the same Y-M-D h:m:s — is exactly the
// test. One generic walk over the whole instance (any object key equal to
// "at" or ending in "_at") rather than a per-schema keyword, since the
// subset engine's `pattern` keyword can only check shape, never calendar
// validity, and every schema in this family uses the same timestamp shape.
const TIMESTAMP_KEY = /(^at$|_at$)/
const TIMESTAMP_PARTS = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/

function isRealInstant(value) {
  const input = TIMESTAMP_PARTS.exec(value)
  if (!input) return true // shape violations are the schema pattern's job, not this check's
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return false
  const rendered = TIMESTAMP_PARTS.exec(parsed.toISOString())
  if (!rendered) return false
  // Compare Y-M-D h:m:s (index 1-6); fractional seconds are deliberately
  // excluded from the comparison, since normalising "no fraction" vs
  // ".000" vs any other valid fractional spelling of the same instant is
  // not what this check is proving.
  for (let i = 1; i <= 6; i += 1) {
    if (input[i] !== rendered[i]) return false
  }
  return true
}

function checkTimestampRealness(value, errors, location) {
  if (value === null || typeof value !== 'object') return
  if (Array.isArray(value)) {
    value.forEach((item, index) => checkTimestampRealness(item, errors, `${location}[${index}]`))
    return
  }
  for (const [key, child] of Object.entries(value)) {
    const childLocation = `${location}.${key}`
    if (TIMESTAMP_KEY.test(key) && typeof child === 'string' && !isRealInstant(child)) {
      errors.push(`${childLocation}: ${JSON.stringify(child)} is not a real instant`)
    }
    checkTimestampRealness(child, errors, childLocation)
  }
}

function main() {
  const { kind, file, options } = parseArgs(process.argv.slice(2))
  const instance = loadJson(file)
  const role = kind === 'envelope' ? instance.role : kind
  checkReceiptRequirements(kind, role, options)

  if (kind === 'adjudication') {
    const errors = validateAdjudicationInstance(instance)
    if (errors.length === 0) {
      checkAdjudicationActiveRun(instance, options, errors)
      if (options.passes.length > 0) checkAdjudicationAgainstPass(instance, options.passes, options, errors)
      checkAdjudicationUniqueAcrossRun(instance, options, errors)
    }
    const skipped = skippedContextFlags(kind, role, options)
    const suffix = skipped.length > 0 ? ` (context skipped: ${skipped.join(', ')})` : ''
    report(errors, `adjudication record OK${suffix}`)
    return
  }

  if (kind === 'run') {
    const schema = loadSchema('run.schema.json')
    const errors = validateAgainst(schema, instance, '$run')
    if (errors.length === 0) {
      checkSettlements(instance, errors)
      checkEvidenceMarkerRunId(instance, errors)
      checkEvidenceMarkerStageVisited(instance, errors)
      checkEvidenceMarkerPrDestinationRequiresPr(instance, errors)
      checkEvidenceMarkerSequenceContiguity(instance, errors)
      checkEvidenceCommentsUniqueness(instance, errors)
      checkRunPromotionOutcome(instance, errors)
      checkSettlementReferenceType(instance, errors)
      checkStageTransitionsOrder(instance, errors)
      checkRunChronology(instance, errors)
      // --no-adjudications asserts "confirmed zero", which runs the SAME
      // checks as one-or-more --adjudication documents, just against the
      // empty set: checkSettlementsAgainstAdjudications then rejects every
      // existing settlement (none of them can be adjudicated by nothing),
      // exactly the "any settlement -> error" contract this flag promises.
      if (options.adjudications.length > 0 || options.noAdjudications) {
        checkAdjudicationRunIdMatchesRun(instance, options.adjudications, errors)
        checkAdjudicationsUnionUnique(options.adjudications, errors)
        checkAdjudicationStagesVisited(instance, options.adjudications, errors)
        checkSettlementsAgainstAdjudications(instance, options.adjudications, errors)
        checkDeferredFindingsSettledBeforePromotion(instance, options.adjudications, errors)
      }
    }
    checkTimestampRealness(instance, errors, '$run')
    const skipped = skippedContextFlags(kind, role, options)
    const suffix = skipped.length > 0 ? ` (context skipped: ${skipped.join(', ')})` : ''
    report(errors, `run record OK${suffix}`)
    return
  }

  const errors = validateEnvelopeInstance(instance, kind, options)
  const skipped = skippedContextFlags(kind, role, options)
  const skippedPart = skipped.length > 0 ? `, context skipped: ${skipped.join(', ')}` : ''
  report(errors, `${kind} result OK (role=${instance.role ?? 'n/a'}, status=${instance.status ?? 'n/a'}${skippedPart})`)
}

function report(errors, okMessage) {
  if (errors.length > 0) {
    for (const error of errors) console.error(`FAIL: ${error}`)
    process.exit(1)
  }
  console.log(okMessage)
}

main()
