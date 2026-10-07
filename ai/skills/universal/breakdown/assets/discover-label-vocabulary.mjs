#!/usr/bin/env node
// Discover the planning-safe label vocabulary for a target GitHub repository.
// The target's registries are data: this script never checks out or executes
// repository-owned code.

import { execFileSync } from 'node:child_process'
import process from 'node:process'
import { accessSync, constants } from 'node:fs'
import { fileURLToPath } from 'node:url'
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
const registrySetPrefixes = new Map([
  ['claim', 'claim'],
  ['foreman-adapters', 'foreman'],
  ['tier-roles', null]
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
      // Model namespaces are opaque, schema-validated registry data. They
      // are never planning candidates; only claim is expanded below.
      if (!registrySetPrefixes.has(family.registry_set) &&
          !(family.axis === 'model' && family.registry_set === family.prefix)) {
        die(`${where} needs a supported registry_set`)
      }
      if (!family.placeholder) {
        die(`${where} agent-registry families need a placeholder`)
      }
      if (registrySetPrefixes.has(family.registry_set) &&
          registrySetPrefixes.get(family.registry_set) !== family.prefix) {
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
  for (const namespace of ['claim']) {
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
// authoring time unconditionally — discovery must not offer values that
// the create gate refuses, including human Priority/Effort and derived Tier.
const executionControlPrefixes = new Set(['strategy', 'rigor', 'tier', 'method', 'priority', 'effort'])
const ratingPrefixes = new Set(['impact', 'risk', 'complexity'])
const helperOwnedPrefixes = new Set([...ratingPrefixes, 'priority-ai'])
function isRatingLabel(name) {
  return [...helperOwnedPrefixes].some((prefix) => name.startsWith(`${prefix}:`))
}

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
    !['model', 'strategy', 'foreman'].includes(family.axis) &&
    !helperOwnedPrefixes.has(family.prefix) &&
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
const ownerType = repositoryMetadata.owner?.type
if (!['User', 'Organization'].includes(ownerType)) {
  die(`repository metadata for ${repo} has no supported owner type`)
}

// The shared reader owns rating storage and provisioned on-scale values,
// including on targets whose label manifest predates classification ratings.
const classificationHelper = fileURLToPath(new URL('../../triage/assets/triage-apply.sh', import.meta.url))
try {
  accessSync(classificationHelper, constants.X_OK)
} catch {
  die('shared classification reader is missing; vendor the triage skill alongside breakdown')
}
let classification
try {
  classification = parseJson(execFileSync(classificationHelper, [
    'classification-axes', '--repo', `${owner}/${repository}`
  ], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, GH_HOST: host }
  }), 'shared classification reader output')
} catch (error) {
  die(`could not read provisioned Impact, Risk and Complexity; check triage's classification-axes reader: ${String(error.stderr ?? error.message).trim()}`)
}
const storage = ownerType === 'Organization' ? 'field' : 'label'
if (classification?.owner_type !== ownerType || classification?.storage !== storage ||
    !Array.isArray(classification.required) ||
    [...ratingPrefixes].some((axis) => {
      const entry = classification.axes?.[axis]
      return typeof entry?.provisioned !== 'boolean' || !Array.isArray(entry?.values) ||
        entry.values.some((value) => typeof value !== 'string')
    })) {
  die('shared classification reader returned an invalid or mismatched catalogue; update the vendored triage skill')
}
// Priority and Tier may be in the shared read, but are not agent proposals.
classification = {
  owner_type: ownerType,
  storage,
  required: classification.required.filter((axis) => ratingPrefixes.has(axis)),
  axes: Object.fromEntries([...ratingPrefixes].map((axis) => [axis, classification.axes[axis]]))
}
const issueFields = storage === 'field' ? classification.axes : {}

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

const ratingFamilies = storage === 'label' ? [...ratingPrefixes].map((axis) => ({
  family: axis,
  prefix: axis,
  purpose: `Provisioned ${axis} ratings from triage's classification rubric`,
  axis: 'classification',
  source: 'classification-helper',
  writers: ['agent'],
  lifecycle: 'durable',
  exclusive: true,
  arming: false,
  provision: true,
  retired: false,
  open_values: false,
  labels: classification.axes[axis].values.flatMap((value) => {
    const label = live.get(normalizeLabelName(`${axis}:${value}`))
    return label ? [{ name: label.name, description: label.description ?? '',
      writers: ['agent'], lifecycle: 'durable', arming: false,
      provision: true, retired: false }] : []
  })
})).filter((family) => family.labels.length > 0) : []

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
    'suggest:',
    ...[...executionControlPrefixes].map((prefix) => `${prefix}:`)
  ]
  const labels = liveLabels
    .filter((label) => {
      const normalized = normalizeLabelName(label.name)
      return !excludedPrefixes.some((prefix) => normalized.startsWith(prefix)) &&
        !isRatingLabel(normalized)
    })
    .sort((left, right) => left.name.localeCompare(right.name))
  process.stdout.write(
    `${JSON.stringify(
      {
        mode: 'live-label-fallback',
        repository: repo,
        owner_type: ownerType,
        issue_fields: issueFields,
        classification,
        default_branch: defaultBranch,
        default_branch_commit: defaultBranchCommit,
        verified_semantics: false,
        work_type_selection: 'human-confirmation-required',
        warning:
          'label-registry.json is absent; family, writer, lifecycle, and exclusivity semantics are unknown',
        excluded_prefixes: excludedPrefixes,
        families: ratingFamilies,
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

// An emitted planning family must be disjoint from every other source.
// Excluded sources can overlap each other; null owns no prefix namespace.
// Matching rating-axis declarations are superseded by the authoritative helper.
function supersededRatingDeclaration(family) {
  return ratingPrefixes.has(family.family) && family.prefix === family.family &&
    family.axis === 'classification'
}
function assertDisjointSources(sources) {
  for (const source of sources.filter((candidate) => candidate.planning)) {
    for (const other of sources) {
      if (source === other) continue
      let collision
      if (source.family === other.family) collision = `family id ${source.family}`
      else if (source.prefix !== null && source.prefix === other.prefix) collision = `prefix ${source.prefix}`
      else {
        for (const name of source.names) {
          if (other.names.has(name) || (other.prefix !== null && name.startsWith(`${other.prefix}:`))) {
            collision = `label ${name}`
            break
          }
        }
        if (!collision && source.prefix !== null) {
          for (const name of other.names) {
            if (name.startsWith(`${source.prefix}:`)) {
              collision = `label ${name}`
              break
            }
          }
        }
      }
      if (collision) die(`collision: ${collision} is shared by ${source.origin} and ${other.origin}`)
    }
  }
}

function generatedNames(family) {
  if (family.source !== 'agent-registry') return []
  if (family.axis === 'model' && family.registry_set === family.prefix) {
    return [...agentVocabulary.families.keys()].map((slug) => `${family.prefix}:${slug}`)
  }
  if (family.registry_set === 'foreman-adapters') {
    return [...agentVocabulary.adapters.entries()]
      .filter(([, adapter]) => adapter.provision_label === true)
      .map(([slug]) => `${family.prefix}:${slug}`)
  }
  return []
}


const resultFamilies = new Map()
// claim:/agent:/foreman: are live ownership/dispatch controls; the
// execution-control prefixes (see safe()'s definition) belong here too — a
// prefix-less family (family.prefix === null, so safe()'s own check never
// sees them) can still enumerate a VALUE that renders to a reserved-looking
// concrete name (e.g. a value literally "strategy:plan" on a family with no
// prefix), and that must be refused exactly like a family that declares the
// prefix directly.
const reservedConcretePrefixes = [
  'suggest:',
  'claim:',
  'agent:',
  'foreman:',
  ...[...executionControlPrefixes].map((prefix) => `${prefix}:`)
]

function addCandidate(family, name, value = {}) {
  const normalized = normalizeLabelName(name)
  // Check rendered names too: a prefix-less family cannot bypass the shared
  // reader's rating vocabulary by enumerating arbitrary rating labels.
  if (isRatingLabel(normalized)) return
  if (reservedConcretePrefixes.some((prefix) => normalized.startsWith(prefix))) {
    die(`planning-safe family ${family.family} declares reserved label ${name}`)
  }
  const liveLabel = live.get(normalized)
  if (!liveLabel) return
  if (!resultFamilies.has(family.family)) resultFamilies.set(family.family, outputFamily(family))
  resultFamilies.get(family.family).labels.push({
    name: liveLabel.name,
    description: liveLabel.description ?? '',
    writers: value.writers ?? family.writers,
    lifecycle: value.lifecycle ?? family.lifecycle,
    arming: family.arming === true || value.arming === true,
    provision: family.provision === true && value.provision !== false,
    retired: family.retired === true || value.retired === true
  })
  return true
}

const planningFamilies = new Set()
function emitCandidate(family, name, value = {}) {
  if (addCandidate(family, name, value)) planningFamilies.add(family)
}
for (const family of registry.families) {
  if (supersededRatingDeclaration(family)) continue
  for (const value of family.values) {
    const name = family.prefix === null ? value.value : `${family.prefix}:${value.value}`
    if (safe(family, value)) emitCandidate(family, name, value)
  }
  for (const name of generatedNames(family)) {
    if (safe(family)) emitCandidate(family, name)
  }
  if (!safe(family) || family.open_values !== true) continue
  if (family.prefix === null) {
    die(`planning-safe open family ${family.family} has no prefix and cannot be interpreted safely`)
  }
  const declared = new Set(family.values.map((value) => normalizeLabelName(`${family.prefix}:${value.value}`)))
  for (const [normalized, label] of live) {
    if (normalized.startsWith(`${family.prefix}:`) && !declared.has(normalized)) {
      emitCandidate(family, label.name)
    }
  }
}

const manifestSources = registry.families.flatMap((family, index) => supersededRatingDeclaration(family) ? [] : [{
  origin: `manifest family[${index}] ${family.family}`,
  family: family.family,
  planning: planningFamilies.has(family),
  prefix: family.prefix,
  names: new Set([
    ...family.values.map((value) => family.prefix === null ? value.value : `${family.prefix}:${value.value}`),
    ...generatedNames(family),
    ...(family.open_values === true && family.prefix !== null ?
      liveLabels.filter((label) => normalizeLabelName(label.name).startsWith(`${family.prefix}:`))
        .map((label) => label.name) : [])
  ].map(normalizeLabelName))
}])
assertDisjointSources([
  ...manifestSources,
  ...[...ratingPrefixes].map((axis) => ({
    origin: `classification-helper family ${axis}`,
    family: axis,
    planning: storage === 'field' ? classification.axes[axis].provisioned &&
      classification.axes[axis].values.length > 0 : ratingFamilies.some((family) => family.family === axis),
    prefix: axis,
    names: new Set(classification.axes[axis].values.map((value) => `${axis}:${value}`))
  }))
])


for (const family of resultFamilies.values()) {
  family.labels.sort((left, right) => left.name.localeCompare(right.name))
}

process.stdout.write(
  `${JSON.stringify(
    {
      mode: 'registry',
      repository: repo,
      owner_type: ownerType,
      issue_fields: issueFields,
      classification,
      default_branch: defaultBranch,
      default_branch_commit: defaultBranchCommit,
      verified_semantics: true,
      work_type_selection: 'registry-semantics',
      families: [...resultFamilies.values(), ...ratingFamilies]
    },
    null,
    2
  )}\n`
)
