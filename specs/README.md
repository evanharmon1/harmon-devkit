# Specs

Task-scoped specifications — the **source of truth for WHAT to build**. A spec
captures the intent, requirements, and acceptance criteria for a feature or
change before it is built, in a form a contributor or AI agent can implement
against. (Specs cover *what* and *why*; `docs/architecture/` covers *how*, and
`docs/decisions/` records *why a choice was made*.)

## How to write a spec

1. Copy the [spec template](_template.md) to a task-scoped file, e.g.
   `specs/user-login.md`.
2. Fill in the problem, goal, requirements, and **Given / When / Then**
   acceptance criteria.
3. Keep one spec per feature/change; link it from the implementing PR, and
   update or supersede it as the work evolves.
