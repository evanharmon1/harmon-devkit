# Tests

How testing works in Harmon DevKit.

## Layers

| Layer | Tool | Command |
|---|---|---|
| Lint / static analysis | shellcheck, yamllint, markdownlint, actionlint | `task check` |
| Tests | TODO: pick a test runner | `task test` |
| Application security | Semgrep CE locally | `task security:sast` |
| Optional second opinion | Snyk Code + Open Source, manual | `task security:sast:snyk` / `task security:sca:snyk` |
| Secrets | gitleaks | `task security:secrets` |
| Dependencies | package-manager audit | `task security:audit` |

## Conventions

- Test files live in `tests/` at the repo root (or co-located per framework convention).
- `task verify` is the local merge gate; CI runs the same task targets.
- TODO: document coverage expectations and fixtures as the suite grows.
