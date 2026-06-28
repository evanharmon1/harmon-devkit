# Tests

How testing works in Harmon DevKit.

## Layers

| Layer | Tool | Command |
|---|---|---|
| Lint / static analysis | shellcheck, yamllint, markdownlint, actionlint | `task check` |
| Tests | TODO: pick a test runner | `task test` |
| Secrets | gitleaks | `task security:secrets` |

## Conventions

- Test files live in `tests/` at the repo root (or co-located per framework convention).
- `task verify` is the local merge gate; CI runs the same task targets.
- TODO: document coverage expectations and fixtures as the suite grows.
