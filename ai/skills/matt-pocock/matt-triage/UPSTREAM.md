# Upstream provenance

- Original author: Matt Pocock
- Source: https://github.com/mattpocock/skills
- Imported commit: `068b6e0c62393147daf03530149cdce209c93da8`
- Upstream path: `skills/engineering/triage`
- License: MIT; see [LICENSE.upstream](LICENSE.upstream)

## Local modifications

- Renamed the skill from `triage` to `matt-triage` to avoid a local name collision.
- Updated self-invocation examples and setup references to use `/matt-triage`.
- Added the attribution notice in `SKILL.md`.
- Adapted Markdown formatting to satisfy harmon-devkit lint rules.
- Added a secret-free isolation requirement for contributor-controlled PR
  verification and portable cross-skill loading instructions.
- Treated reporter content and reproduction steps as untrusted, and made the
  tracker comment self-contained before closing rejected enhancements.
- Clarified that checkout isolation alone is not a sandbox for reporter code.
