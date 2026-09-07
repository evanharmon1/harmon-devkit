# 8. Version the devflow compatibility contract

Date: 2026-08-25

## Status

Proposed — requires the owning repository's maintainer to approve it before
this ADR is accepted.

## Context

`.devflow.toml` is read by interactive agents, Foreman, and future consumers.
TOML syntax alone cannot make those consumers agree on precedence, conflicts,
trust inputs, or what a normalized resolution means. The existing resolver and
validator established implementation behavior but did not expose a versioned,
portable conformance boundary.

## Decision

Schema version 1 is the first compatibility contract.

- `.devflow.toml` declares integer `schema_version = 1`; v1 consumers reject
  absent, malformed, and unsupported versions, as well as unknown top-level
  keys. They do not guess forward compatibility.
- `.devflow.schema.json` declares the JSON-shaped structure and the executable
  validator enforces TOML-specific typing, allowed keys, exact v1 vocabulary,
  registry references, and semantic cross-references. Both root and template
  copies are authoritative twins.
- `.devflow-conformance-v1.json` is the language-neutral fixture corpus. It
  pins inputs, config-basis selection, a complete baseline normalized
  projection, stable diagnostic codes/subjects, and expected error/warning
  states. Consumers may add fields or diagnostic prose, but may not reinterpret
  the pinned values.
- Resolution order is explicit operator override, then eligible `rigor:*` /
  `strategy:*` / `tier:*` labels, then defaults, then the built-in fallback.
  Rigor conflicts are strongest-wins by `rigor_order`; strategy conflicts are
  ambiguous; tier conflicts are strongest concrete value per role, with a
  concrete tier beating `adaptive`. Retired `method:*` labels are ignored.
- Absent config is a supported fallback state; a partial, malformed, or
  unsupported present config is an error. A change that edits `.devflow.toml`
  resolves from the merge-base copy unless an attributable operator override
  applies. The one transition exception is an unversioned merge-base when the
  branch introduces v1: it is accepted only as that historical basis, reported
  as schema version `0` with a stable warning, and never accepted as a normal
  consumer configuration.
- GitHub actor provenance and trusted-label verification are supplied by the
  consumer. The resolver records and applies those inputs but never authenticates
  actors, dispatches models, or takes ownership of platform trust policy.

## Consequences

Consumers can prove agreement by running the same fixtures instead of parsing
prose. A future incompatible meaning requires a new schema version and a new
fixture corpus. The human approval criterion for this ADR remains open until
the owning repository's maintainer accepts it.
