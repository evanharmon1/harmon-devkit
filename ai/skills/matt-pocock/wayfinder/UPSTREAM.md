# Upstream provenance

- Original author: Matt Pocock
- Source: https://github.com/mattpocock/skills
- Imported commit: `068b6e0c62393147daf03530149cdce209c93da8`
- Upstream path: `skills/engineering/wayfinder`
- License: MIT; see [LICENSE.upstream](LICENSE.upstream)

## Local modifications

- Added the attribution notice in `SKILL.md`.
- Added portable cross-skill loading, conflict-safe map updates, recoverable
  claims, staged ticket publication, safe external-mutation confirmation, and
  isolated parallel research guidance.
- Made claim ownership exclusive and reordered resolution so derived map and
  dependency changes publish before a ticket exposes its dependents.
- Simplified the concurrency model to one active map writer and made map/ticket
  creation resumable with deterministic publication keys.
