# DESIGN.md

AI-facing statement of design intent for **Harmon DevKit**. This file
carries the *why* and the prose rules that code and config can't encode — read
it before making design, UX, or structural decisions. `AGENTS.md` covers how to
work in the repo; this covers what "good" looks like for the product itself.

> TODO: replace the placeholders below with this project's real intent as it
> takes shape. Keep it short and opinionated — a few firm rules beat a long
> wishlist.

## Purpose

My personal developer kit: reusable templates and boilerplates, standalone scripts, and AI assets (skills, prompts, agents).

TODO: who is this for, what is it trying to achieve, and what would make it
clearly *worse* if changed? State the single most important quality (e.g.
"boringly reliable", "fast to read", "delightful to demo").

## Principles

- **Clarity over cleverness.** Optimize for the next reader (often an AI agent).
- **Consistency is a feature.** Reuse existing patterns before inventing new ones.
- **Simple by default.** Add structure only when complexity demands it.
- **Accessible by default.** TODO: state the bar (e.g. WCAG 2.2 AA) where it applies.

## Non-negotiables

TODO: list the handful of rules that must never be violated (the "source of
truth" files, naming conventions, data-handling rules, security boundaries).
When a non-negotiable lives in code/config, name the file here and note that the
file wins if they disagree.

## Decisions & when to deviate

Significant or hard-to-reverse design choices get an ADR in
[`docs/decisions/`](docs/decisions/). Deviating from a rule here is allowed when
justified — record *why* in an ADR rather than silently drifting.
