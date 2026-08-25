#!/usr/bin/env node
// Discover the planning-safe label vocabulary for a target GitHub repository.
// The target's registries are data: this script never checks out or executes
// repository-owned code.

import { execFileSync } from 'node:child_process'
import process from 'node:process'
import { validateJsonSchema } from './validate-json-schema.mjs'

const usage = `Usage: discover-label-vocabulary.mjs --repo [host/]owner/repo

Reads label-registry.json from the target repository's current default branch,
intersects planning-safe entries with the live label inventory, and writes JSON.
If the registry is absent (HTTP 404), emits a conservative live-label fallback.`

function die(message, code = 1) {
  console.error(`breakdown-labels: ${message}`)
  process.exit(code)
}

let repoArg
for (let index = 2; index < process.argv.length; index += 1) {
  const argument = process.argv[index]
  if (argument === '--help' || argument === '-h') {
    console.log(usage)
    process.exit(0)
  }
  if (argument === '--repo' && process.argv[index + 1]) {
    repoArg = process.argv[++index]
    continue
  }
  die(`unexpected argument ${argument}`, 2)
}
if (!repoArg) die('--repo is required', 2)

const parts = repoArg.split('/')
if (parts.length !== 2 && parts.length !== 3) {
  die(`--repo must be [host/]owner/repo (got ${repoArg})`, 2)
}
const [host, owner, repository] =
  parts.length === 3 ? parts : ['github.com', parts[0], parts[1]]
const repo = `${host}/${owner}/${repository}`
const apiPath = `repos/${owner}/${repository}`

function gh(args, description) {
  try {
    return execFileSync('gh', args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    })
  } catch (error) {
    const stderr = String(error.stderr ?? '').trim()
    const wrapped = new Error(`${description} failed${stderr ? `: ${stderr}` : ''}`)
    wrapped.stderr = stderr
    wrapped.status = error.status
    throw wrapped
  }
}

function parseJson(text, description) {
  try {
    return JSON.parse(text)
  } catch (error) {
    die(`${description} is not valid JSON: ${error.message}`)
  }
}

function apiJson(path, description, fields = []) {
  return parseJson(
    gh(
      ['api', '--hostname', host, '--method', 'GET', path, ...fields.flatMap(([key, value]) => ['-f', `${key}=${value}`])],
      description
    ),
    description
  )
}

function apiJsonPages(path, description, fields = []) {
  return parseJson(
    gh(
      [
        'api',
        '--hostname',
        host,
        '--method',
        'GET',
        '--paginate',
        '--slurp',
        path,
        ...fields.flatMap(([key, value]) => ['-f', `${key}=${value}`])
      ],
      description
    ),
    description
  )
}

function fetchDefaultBranchFile(path, commit) {
  let response
  try {
    response = apiJson(
      `${apiPath}/contents/${path}`,
      `reading ${path} from ${repo}@${commit}`,
      [['ref', commit]]
    )
  } catch (error) {
    die(error.message)
  }
  if (
    response === null ||
    typeof response !== 'object' ||
    response.type !== 'file' ||
    response.encoding !== 'base64' ||
    typeof response.content !== 'string'
  ) {
    die(`${path} at ${repo}@${commit} is not a base64-encoded file`)
  }
  return Buffer.from(response.content.replaceAll('\n', ''), 'base64').toString('utf8')
}

const slugPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
const writerPattern = /^(human|trusted-human|agent|tool:[a-z0-9-]+)$/
const lifecycles = new Set(['durable', 'transient', 'claim-release', 'tool-managed'])
const axes = new Set([
  'classification',
  'strategy',
  'model',
  'work-type',
  'concern',
  'workflow',
  'provenance',
  'foreman',
  'release',
  'meta'
])
const sources = new Set(['inline', 'devflow', 'agent-registry', 'tool-owned'])
const registrySets = new Set(['suggest', 'claim', 'foreman-adapters'])
const registrySetPrefixes = new Map([
  ['suggest', 'suggest'],
  ['claim', 'claim'],
  ['foreman-adapters', 'foreman']
])
const familyKeys = new Set([
  'family',
  'prefix',
  'purpose',
  'axis',
  'source',
  'registry_set',
  'writers',
  'writer_note',
  'readers',
  'lifecycle',
  'lifecycle_note',
  'trust_note',
  'exclusive',
  'arming',
  'provision',
  'gate',
  'retired',
  'open_values',
  'placeholder',
  'color',
  'values'
])
const registryKeys = new Set(['$schema', 'schema_version', 'families'])
const valueKeys = new Set([
  'value',
  'description',
  'color',
  'writers',
  'writer_note',
  'readers',
  'lifecycle',
  'lifecycle_note',
  'trust_note',
  'arming',
  'provision',
  'retired'
])

function assertObject(value, where) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    die(`${where} must be an object`)
  }
}

function assertKeys(value, allowed, where) {
  const unknown = Object.keys(value).filter((key) => !allowed.has(key))
  if (unknown.length > 0) die(`${where} has unsupported metadata: ${unknown.join(', ')}`)
}

function assertBoolean(value, where) {
  if (typeof value !== 'boolean') die(`${where} must be boolean`)
}

function assertWriters(value, where) {
  if (
    !Array.isArray(value) ||
    new Set(value).size !== value.length ||
    value.some((writer) => typeof writer !== 'string' || !writerPattern.test(writer))
  ) {
    die(`${where} must be a unique writer list`)
  }
}

function assertOptionalBoolean(value, key, where) {
  if (Object.hasOwn(value, key)) assertBoolean(value[key], `${where}.${key}`)
}

function validateRegistry(registry) {
  assertObject(registry, 'label-registry.json')
  assertKeys(registry, registryKeys, 'label-registry.json')
  if (registry.$schema !== './label-registry.schema.json') {
    die('label-registry.json has an unsupported $schema')
  }
  if (registry.schema_version !== 1) {
    die(`label-registry.json schema_version must be 1 (got ${registry.schema_version})`)
  }
  if (!Array.isArray(registry.families) || registry.families.length === 0) {
    die('label-registry.json families must be a non-empty array')
  }

  const familyIds = new Set()
  const provisionedNames = new Map()
  for (const [familyIndex, family] of registry.families.entries()) {
    const where = `family[${familyIndex}]`
    assertObject(family, where)
    assertKeys(family, familyKeys, where)
    for (const required of [
      'family',
      'prefix',
      'purpose',
      'axis',
      'source',
      'writers',
      'readers',
      'lifecycle',
      'exclusive',
      'provision',
      'values'
    ]) {
      if (!Object.hasOwn(family, required)) die(`${where} is missing ${required}`)
    }
    if (typeof family.family !== 'string' || !slugPattern.test(family.family)) {
      die(`${where}.family must be a lowercase slug`)
    }
    if (familyIds.has(family.family)) die(`duplicate family id ${family.family}`)
    familyIds.add(family.family)
    if (family.prefix !== null && (typeof family.prefix !== 'string' || !slugPattern.test(family.prefix))) {
      die(`${where}.prefix must be null or a lowercase slug`)
    }
    if (typeof family.purpose !== 'string' || family.purpose.length === 0) {
      die(`${where}.purpose must be a non-empty string`)
    }
    if (typeof family.axis !== 'string' || !axes.has(family.axis)) {
      die(`${where}.axis is unsupported: ${JSON.stringify(family.axis)}`)
    }
    if (!sources.has(family.source)) die(`${where}.source is unsupported: ${family.source}`)
    assertWriters(family.writers, `${where}.writers`)
    if (!lifecycles.has(family.lifecycle)) {
      die(`${where}.lifecycle is unsupported: ${family.lifecycle}`)
    }
    assertBoolean(family.exclusive, `${where}.exclusive`)
    assertBoolean(family.provision, `${where}.provision`)
    for (const key of ['arming', 'retired', 'open_values']) assertOptionalBoolean(family, key, where)
    if (family.retired !== true && family.writers.length === 0) {
      die(`${where} live families need at least one writer`)
    }
    if (!Array.isArray(family.values)) die(`${where}.values must be an array`)
    if (family.source === 'agent-registry') {
      if (!registrySets.has(family.registry_set)) {
        die(`${where} needs a supported registry_set`)
      }
      if (!family.placeholder) {
        die(`${where} agent-registry families need a placeholder`)
      }
      if (registrySetPrefixes.get(family.registry_set) !== family.prefix) {
        die(`${where}.registry_set ${family.registry_set} does not match prefix ${family.prefix}`)
      }
      if (family.values.length !== 0) {
        die(`${where} cannot mix agent-registry and inline values`)
      }
      if (family.retired !== true && family.provision !== true) {
        die(`${where} agent-registry labels must be provisioned`)
      }
      if (family.retired !== true && typeof family.color !== 'string') {
        die(`${where} agent-registry labels need a family color`)
      }
    } else if (Object.hasOwn(family, 'registry_set')) {
      die(`${where}.registry_set is only valid for agent-registry sources`)
    }
    if (family.source === 'tool-owned' && family.provision !== false) {
      die(`${where} tool-owned labels must not be provisioned`)
    }
    if (family.retired === true && family.provision !== false) {
      die(`${where} retired labels must not be provisioned`)
    }
    if (family.open_values === true && !family.placeholder) {
      die(`${where} open_values needs a placeholder`)
    }
    if (family.placeholder && family.open_values !== true && family.source !== 'agent-registry') {
      die(`${where}.placeholder requires open_values or an agent-registry source`)
    }
    if (
      (family.source === 'inline' || family.source === 'devflow') &&
      family.open_values !== true &&
      family.retired !== true &&
      family.values.length === 0
    ) {
      die(`${where} closed inline/devflow families need at least one value`)
    }
    if (family.arming === true && family.prefix !== 'foreman') {
      die(`${where} arming is only valid in the foreman namespace`)
    }

    const values = new Set()
    for (const [valueIndex, value] of family.values.entries()) {
      const valueWhere = `${where}.values[${valueIndex}]`
      assertObject(value, valueWhere)
      assertKeys(value, valueKeys, valueWhere)
      if (typeof value.value !== 'string' || value.value.length === 0) {
        die(`${valueWhere}.value must be a non-empty string`)
      }
      const name = family.prefix === null ? value.value : `${family.prefix}:${value.value}`
      const normalizedName = normalizeLabelName(name)
      if (values.has(normalizedName)) die(`${where} has case-insensitive duplicate label ${name}`)
      values.add(normalizedName)
      if (family.prefix !== null && !slugPattern.test(value.value)) {
        die(`${valueWhere}.value must be a lowercase slug when prefixed`)
      }
      if ([...name].length > 50) die(`${valueWhere} renders a label name over 50 characters`)
      if (Object.hasOwn(value, 'writers')) assertWriters(value.writers, `${valueWhere}.writers`)
      if (Object.hasOwn(value, 'writers') && value.writers.length === 0) {
        die(`${valueWhere}.writers cannot be empty`)
      }
      if (Object.hasOwn(value, 'lifecycle') && !lifecycles.has(value.lifecycle)) {
        die(`${valueWhere}.lifecycle is unsupported: ${value.lifecycle}`)
      }
      for (const key of ['arming', 'retired']) assertOptionalBoolean(value, key, valueWhere)
      if ((family.arming === true || value.arming === true) && family.prefix !== 'foreman') {
        die(`${valueWhere} arming is only valid in the foreman namespace`)
      }
      if (Object.hasOwn(value, 'provision') && value.provision !== false) {
        die(`${valueWhere}.provision may only override to false`)
      }
      const provisioned =
        family.provision === true &&
        family.retired !== true &&
        value.provision !== false &&
        value.retired !== true
      if (provisioned) {
        if (typeof value.description !== 'string' || value.description.length === 0) {
          die(`${valueWhere} provisioned labels need a description`)
        }
        if (typeof value.color !== 'string' && typeof family.color !== 'string') {
          die(`${valueWhere} provisioned labels need a color`)
        }
        if (provisionedNames.has(name)) {
          die(`${valueWhere} duplicates provisioned label ${name} from ${provisionedNames.get(name)}`)
        }
        provisionedNames.set(name, family.family)
      }
    }
  }
}

function validateAgentRegistry(registry) {
  assertObject(registry, 'agent-registry.json')
  if (registry.$schema !== './agent-registry.schema.json') {
    die('agent-registry.json has an unsupported $schema')
  }
  if (registry.schema_version !== 2 && registry.schema_version !== 3) {
    die(`agent-registry.json schema_version must be 2 or 3 (got ${registry.schema_version})`)
  }
  for (const namespace of ['suggest', 'claim']) {
    const contract = registry.labels?.[namespace]
    const scopes = new Set(contract?.scopes ?? [])
    if (
      !contract ||
      contract.prefix !== namespace ||
      contract.axis !== 'model' ||
      contract.arming !== false ||
      !Array.isArray(contract.scopes) ||
      scopes.size !== 2 ||
      !scopes.has('family') ||
      !scopes.has('model')
    ) {
      die(`agent-registry.json labels.${namespace} has an unsupported namespace contract`)
    }
  }
  if (!Array.isArray(registry.families)) die('agent-registry.json families must be an array')
  const families = new Map()
  for (const [index, family] of registry.families.entries()) {
    if (!family || typeof family !== 'object' || !slugPattern.test(family.slug ?? '')) {
      die(`agent-registry.json family[${index}] has an invalid slug`)
    }
    if (families.has(family.slug)) die(`agent-registry.json has duplicate family ${family.slug}`)
    if (!Array.isArray(family.models)) die(`agent family ${family.slug} models must be an array`)
    const models = new Set()
    for (const model of family.models) {
      if (!model || typeof model !== 'object' || !slugPattern.test(model.slug ?? '')) {
        die(`agent family ${family.slug} has an invalid model slug`)
      }
      if (models.has(model.slug)) die(`agent family ${family.slug} has duplicate model ${model.slug}`)
      models.add(model.slug)
    }
    families.set(family.slug, { models })
  }
  const adapters = new Map()
  for (const [index, adapter] of (registry.foreman_adapters ?? []).entries()) {
    if (!adapter || typeof adapter !== 'object' || !slugPattern.test(adapter.slug ?? '')) {
      die(`agent-registry.json foreman_adapters[${index}] has an invalid slug`)
    }
    if (adapters.has(adapter.slug)) die(`agent-registry.json has duplicate adapter ${adapter.slug}`)
    adapters.set(adapter.slug, adapter)
  }
  return { families, adapters }
}

// Execution-control families, whatever a manifest claims about their
// writers. track-work's check-issue-metadata.sh rejects these at
// authoring time unconditionally (FORBIDDEN_RE, plus an axis backstop for
// strategy/foreman/model families under any other prefix) — planning
// vocabulary that the next gate always refuses is not planning-safe. Prefix,
// not axis: axis "model" is shared with the legitimately plannable
// suggest-model/claim-model refinement families, so axis alone would
// over-exclude.
const executionControlPrefixes = new Set(['strategy', 'rigor', 'tier', 'method'])

function safe(family, value = {}) {
  const writers = value.writers ?? family.writers
  const lifecycle = value.lifecycle ?? family.lifecycle
  const retired = family.retired === true || value.retired === true
  const arming = family.arming === true || value.arming === true
  const gated = Object.hasOwn(family, 'gate')
  return (
    writers.includes('agent') &&
    lifecycle === 'durable' &&
    !retired &&
    !arming &&
    !gated &&
    !executionControlPrefixes.has(family.prefix)
  )
}

function outputFamily(family) {
  return {
    family: family.family,
    prefix: family.prefix,
    purpose: family.purpose,
    axis: family.axis,
    source: family.source,
    writers: family.writers,
    lifecycle: family.lifecycle,
    exclusive: family.exclusive,
    arming: family.arming === true,
    provision: family.provision,
    retired: family.retired === true,
    open_values: family.open_values === true,
    labels: []
  }
}

let repositoryMetadata
try {
  repositoryMetadata = apiJson(apiPath, `reading repository metadata for ${repo}`)
} catch (error) {
  die(error.message)
}
if (!repositoryMetadata.default_branch || typeof repositoryMetadata.default_branch !== 'string') {
  die(`repository metadata for ${repo} has no default_branch`)
}
const defaultBranch = repositoryMetadata.default_branch

let branchMetadata
let defaultBranchCommit = null
let defaultPaths
try {
  branchMetadata = apiJson(
    `${apiPath}/branches/${encodeURIComponent(defaultBranch)}`,
    `resolving ${repo}'s default branch ${defaultBranch}`
  )
  } catch (error) {
    let branchRefs
    try {
    branchRefs = apiJson(
      `${apiPath}/git/matching-refs/heads/`,
        `checking whether ${repo} has any branch refs`
      )
    } catch (refsError) {
      if (/Git Repository is empty.*HTTP 409/i.test(refsError.stderr)) {
        branchRefs = []
      } else {
        die(`${error.message}; ${refsError.message}; empty-repository state cannot be established safely`)
      }
  }
  if (
    !Array.isArray(branchRefs) ||
    branchRefs.some((ref) => typeof ref?.ref !== 'string' || !ref.ref.startsWith('refs/heads/'))
  ) {
    die(`branch-ref metadata for ${repo} has an unexpected shape`)
  }
  if (branchRefs.length > 0) die(error.message)
  defaultPaths = new Set()
}
if (branchMetadata) {
  defaultBranchCommit = branchMetadata?.commit?.sha
  if (typeof defaultBranchCommit !== 'string' || !/^[0-9a-f]{40}$/.test(defaultBranchCommit)) {
    die(`default branch metadata for ${repo} has no full commit SHA`)
  }

  let defaultTree
  try {
    defaultTree = apiJson(
      `${apiPath}/git/trees/${defaultBranchCommit}`,
      `reading ${repo}'s default-branch root tree`
    )
  } catch (error) {
    die(`${error.message}; registry absence cannot be established safely`)
  }
  if (defaultTree?.truncated === true) {
    die(`${repo}'s default-branch root tree is truncated; registry absence is indeterminate`)
  }
  if (
    !Array.isArray(defaultTree?.tree) ||
    defaultTree.tree.some((entry) => typeof entry?.path !== 'string')
  ) {
    die(`${repo}'s default-branch tree has an unexpected shape`)
  }
  defaultPaths = new Set(defaultTree.tree.map((entry) => entry.path))
}

let liveLabelPages
try {
  liveLabelPages = apiJsonPages(
    `${apiPath}/labels`,
    `listing live labels for ${repo}`,
    [['per_page', '100']]
  )
} catch (error) {
  die(error.message)
}
if (!Array.isArray(liveLabelPages) || liveLabelPages.some((page) => !Array.isArray(page))) {
  die(`live label pages for ${repo} have an unexpected shape`)
}
const liveLabels = liveLabelPages.flat()
if (
  !Array.isArray(liveLabels) ||
  liveLabels.some((label) => !label || typeof label.name !== 'string')
) {
  die(`live labels for ${repo} have an unexpected shape`)
}
function normalizeLabelName(name) {
  return name.toLocaleLowerCase('en-US')
}

const live = new Map()
for (const label of liveLabels) {
  const normalized = normalizeLabelName(label.name)
  if (live.has(normalized)) {
    die(`live labels for ${repo} contain case-insensitive duplicate ${label.name}`)
  }
  live.set(normalized, label)
}

if (!defaultPaths.has('label-registry.json')) {
  // Same execution-control exclusion as the registry path's safe() (see its
  // definition for why: track-work's check-issue-metadata.sh rejects these
  // at authoring time unconditionally, so no registry is no license to
  // recommend them either), plus claim/agent/foreman — live ownership and
  // dispatch controls with no registry to declare them by axis at all here.
  const excludedPrefixes = [
    'claim:',
    'agent:',
    'foreman:',
    ...[...executionControlPrefixes].map((prefix) => `${prefix}:`)
  ]
  const labels = liveLabels
    .filter((label) => {
      const normalized = normalizeLabelName(label.name)
      return !excludedPrefixes.some((prefix) => normalized.startsWith(prefix))
    })
    .sort((left, right) => left.name.localeCompare(right.name))
  process.stdout.write(
    `${JSON.stringify(
      {
        mode: 'live-label-fallback',
        repository: repo,
        default_branch: defaultBranch,
        default_branch_commit: defaultBranchCommit,
        verified_semantics: false,
        work_type_selection: 'human-confirmation-required',
        warning:
          'label-registry.json is absent; family, writer, lifecycle, and exclusivity semantics are unknown',
        excluded_prefixes: excludedPrefixes,
        labels
      },
      null,
      2
    )}\n`
  )
  process.exit(0)
}

if (!defaultPaths.has('label-registry.schema.json')) {
  die(`label-registry.json is present but label-registry.schema.json is absent at ${defaultBranchCommit}`)
}
const registryText = fetchDefaultBranchFile('label-registry.json', defaultBranchCommit)
const registrySchemaText = fetchDefaultBranchFile('label-registry.schema.json', defaultBranchCommit)
const registry = parseJson(registryText, `label-registry.json from ${repo}@${defaultBranchCommit}`)
const registrySchema = parseJson(
  registrySchemaText,
  `label-registry.schema.json from ${repo}@${defaultBranchCommit}`
)
let schemaErrors
try {
  schemaErrors = validateJsonSchema(registry, registrySchema)
} catch (error) {
  die(`label-registry.schema.json cannot be interpreted safely: ${error.message}`)
}
if (schemaErrors.length > 0) die(`label-registry.json fails its schema: ${schemaErrors.join('; ')}`)
validateRegistry(registry)

let agentVocabulary = { families: new Map(), adapters: new Map() }
if (registry.families.some((family) => family.source === 'agent-registry')) {
  for (const path of ['agent-registry.json', 'agent-registry.schema.json']) {
    if (!defaultPaths.has(path)) die(`${path} is required by an agent-registry label source`)
  }
  const agentText = fetchDefaultBranchFile('agent-registry.json', defaultBranchCommit)
  const agentSchemaText = fetchDefaultBranchFile('agent-registry.schema.json', defaultBranchCommit)
  const agentRegistry = parseJson(
    agentText,
    `agent-registry.json from ${repo}@${defaultBranchCommit}`
  )
  const agentSchema = parseJson(
    agentSchemaText,
    `agent-registry.schema.json from ${repo}@${defaultBranchCommit}`
  )
  try {
    schemaErrors = validateJsonSchema(agentRegistry, agentSchema)
  } catch (error) {
    die(`agent-registry.schema.json cannot be interpreted safely: ${error.message}`)
  }
  if (schemaErrors.length > 0) die(`agent-registry.json fails its schema: ${schemaErrors.join('; ')}`)
  agentVocabulary = validateAgentRegistry(agentRegistry)
}

const resultFamilies = new Map()
const candidateOwners = new Map()
const declaredOwners = new Map()
const knownConcrete = new Set()
// claim:/agent:/foreman: are live ownership/dispatch controls; the
// execution-control prefixes (see safe()'s definition) belong here too — a
// prefix-less family (family.prefix === null, so safe()'s own check never
// sees them) can still enumerate a VALUE that renders to a reserved-looking
// concrete name (e.g. a value literally "strategy:plan" on a family with no
// prefix), and that must be refused exactly like a family that declares the
// prefix directly.
const reservedConcretePrefixes = [
  'claim:',
  'agent:',
  'foreman:',
  ...[...executionControlPrefixes].map((prefix) => `${prefix}:`)
]

function isModelSuggestion(name) {
  const [prefix, family, model, ...rest] = name.split(':')
  return (
    rest.length === 0 &&
    prefix === 'suggest' &&
    slugPattern.test(family ?? '') &&
    slugPattern.test(model ?? '')
  )
}

function isCanonicalModelPair(openFamily, candidateFamily) {
  return (
    (openFamily.family === 'suggest-model' || openFamily.family === 'claim-model') &&
    candidateFamily?.source === 'agent-registry' &&
    candidateFamily.registry_set === openFamily.family.replace('-model', '')
  )
}

function reserveConcrete(family, name) {
  const normalized = normalizeLabelName(name)
  const prior = declaredOwners.get(normalized)
  if (prior && prior !== family.family) {
    die(`label ${name} is declared by both family ${prior} and family ${family.family}`)
  }
  declaredOwners.set(normalized, family.family)
  knownConcrete.add(normalized)
}

function addCandidate(family, name, value = {}, extra = {}) {
  const normalized = normalizeLabelName(name)
  if (family.prefix === null && isModelSuggestion(normalized)) {
    die(
      `planning-safe family ${family.family} declares model-shaped suggestion ${name} ` +
      'outside the paired suggest-model path'
    )
  }
  if (reservedConcretePrefixes.some((prefix) => normalized.startsWith(prefix))) {
    die(`planning-safe family ${family.family} declares reserved label ${name}`)
  }
  const liveLabel = live.get(normalized)
  if (!liveLabel) return
  const prior = candidateOwners.get(normalized)
  if (prior && prior !== family.family) {
    die(
      `label ${liveLabel.name} is ambiguous between planning-safe families ${prior} and ${family.family}`
    )
  }
  candidateOwners.set(normalized, family.family)
  if (!resultFamilies.has(family.family)) resultFamilies.set(family.family, outputFamily(family))
  resultFamilies.get(family.family).labels.push({
    name: liveLabel.name,
    description: liveLabel.description ?? '',
    writers: value.writers ?? family.writers,
    lifecycle: value.lifecycle ?? family.lifecycle,
    arming: family.arming === true || value.arming === true,
    provision: family.provision === true && value.provision !== false,
    retired: family.retired === true || value.retired === true,
    ...extra
  })
}

for (const family of registry.families) {
  if (family.source !== 'agent-registry') {
    for (const value of family.values) {
      const name = family.prefix === null ? value.value : `${family.prefix}:${value.value}`
      reserveConcrete(family, name)
      if (safe(family, value)) addCandidate(family, name, value)
    }
  } else if (family.source === 'agent-registry') {
    let names = []
    if (family.registry_set === 'suggest' || family.registry_set === 'claim') {
      names = [...agentVocabulary.families.keys()].map((slug) => `${family.prefix}:${slug}`)
    } else if (family.registry_set === 'foreman-adapters') {
      names = [...agentVocabulary.adapters.entries()]
        .filter(([, adapter]) => adapter.provision_label === true)
        .map(([slug]) => `${family.prefix}:${slug}`)
    }
    for (const name of names) {
      reserveConcrete(family, name)
      if (safe(family)) addCandidate(family, name)
    }
  }
}

for (const family of registry.families.filter((candidate) => candidate.open_values === true)) {
  if (family.prefix === null) continue
  const conflictingFamily = registry.families.find(
    (candidate) =>
      candidate.family !== family.family &&
      candidate.prefix === family.prefix &&
      !isCanonicalModelPair(family, candidate)
  )
  if (conflictingFamily) {
    die(
      `planning-safe open family ${family.family} overlaps prefix ${family.prefix} with ` +
      `family ${conflictingFamily.family}; excluded labels cannot be reclassified safely`
    )
  }
  const conflictingConcrete = [...candidateOwners].find(([name, owner]) => {
    const ownerFamily = registry.families.find((candidate) => candidate.family === owner)
    return (
      owner !== family.family &&
      name.startsWith(`${family.prefix}:`) &&
      !isCanonicalModelPair(family, ownerFamily)
    )
  })
  if (conflictingConcrete) {
    const [name, owner] = conflictingConcrete
    die(
      `planning-safe concrete label ${live.get(name)?.name ?? name} from family ${owner} overlaps ` +
      `open family ${family.family} prefix ${family.prefix}; semantics cannot be verified safely`
    )
  }
}

for (const family of registry.families) {
  if (!safe(family) || family.open_values !== true) continue
  if (family.prefix === null) {
    die(`planning-safe open family ${family.family} has no prefix and cannot be interpreted safely`)
  }

  if (family.family === 'suggest-model') {
    const baseFamily = registry.families.find(
      (candidate) =>
        candidate.source === 'agent-registry' &&
        candidate.registry_set === 'suggest' &&
        candidate.prefix === family.prefix &&
        safe(candidate)
    )
    if (!baseFamily) die('suggest-model has no planning-safe suggest family to pair with')
    for (const [familySlug, details] of agentVocabulary.families) {
      const base = `${family.prefix}:${familySlug}`
      const liveBase = live.get(normalizeLabelName(base))
      if (!liveBase) continue
      for (const model of details.models) {
        const name = `${base}:${model}`
        const normalized = normalizeLabelName(name)
        if (!knownConcrete.has(normalized) && live.has(normalized)) {
          addCandidate(family, name, {}, { requires: [liveBase.name] })
        }
      }
    }
    continue
  }

  for (const [normalized, label] of live) {
    if (!normalized.startsWith(`${family.prefix}:`) || knownConcrete.has(normalized)) continue
    addCandidate(family, label.name)
  }
}

for (const family of resultFamilies.values()) {
  family.labels.sort((left, right) => left.name.localeCompare(right.name))
}

process.stdout.write(
  `${JSON.stringify(
    {
      mode: 'registry',
      repository: repo,
      default_branch: defaultBranch,
      default_branch_commit: defaultBranchCommit,
      verified_semantics: true,
      work_type_selection: 'registry-semantics',
      families: [...resultFamilies.values()]
    },
    null,
    2
  )}\n`
)
