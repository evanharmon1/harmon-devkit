# Evolving an established design system

Read this during **Phase 2** in **`evolve-design-system`** mode — when the bundle deliberately changes the design
system itself (not a single feature). The doctrine is the same as everywhere: the repo is truth, the
bundle is a proposal. Evolve means reconciling a proposed token change into canonical `globals.css`
**carefully and versioned** — never a blind overwrite, because much of a bundle's token block is a
re-emission that may have drifted from canonical. If the change adds a new role, cross-check
`deliverables-checklist.md` so the system stays complete (e.g. a new semantic color also needs its
`-foreground`, its `/brand` swatch, and a contrast pass).

## 1. Diff before you write

Parse the **current** semantic tokens from `globals.css` and the **incoming** set from the bundle, and
produce a three-bucket diff:

- **Added** — semantic tokens in the bundle that don't exist in canonical.
- **Changed** — same token name, different value. Use an OKLCH **closeness tolerance** so a rounding
  difference isn't flagged as a real change (see `token-reconciliation.md`).
- **Removed / renamed** — present in canonical, absent from the bundle.

Show this diff to the user and apply only the deltas they approve. The re-emitted bundle is not
authority; the diff is the unit of change.

## 2. Classify the change with SemVer

Version the token set (the industry norm — IBM Carbon, Salesforce, and the W3C Design Tokens spec all
version tokens). Record the version in `DESIGN.md` (or a `tokens` header):

- **patch** — value tweaks that don't change a token's role (e.g. nudging `--primary` lightness).
- **minor** — additive, backward-compatible new tokens (a new `--warning`, a new surface).
- **major** — renamed/removed tokens or role changes (breaking).

Batch breaking changes into a single major release rather than scattering them across handoffs.

## 3. Handle breaking changes with aliasing + deprecation (not deletion)

Treat tokens like API endpoints — version, alias, and deprecate slowly:

- When a token is renamed or removed, **alias** the old name to the new value for a migration window
  (keep the old `--token` pointing at the new var).
- **Search the codebase** for every reference to the old token and migrate them.
- **Delete only after** all references are migrated. Don't yank a token out from under the components
  that use it — that's the costly path everyone warns about.

**The wholesale-replacement exception.** When the bundle replaces the brand outright and every
consumer of the old tokens is rewritten **in the same change** (a ground-up site redesign), skip the
aliasing window: there is no migration period because nothing downstream survives to migrate. That
is still evolve *governance* — classify it **major**, record the DDR (note explicitly that all
consumers were migrated in-change, which satisfies "delete only after migrated") — but the token
write itself follows the `establish-design-system` recipe in `token-reconciliation.md`: canonical
values fresh from the bundle, `.dark` authored, gates re-run from zero.

## 4. Record a DDR with the version bump

Every system change is a **DDR** in `docs/decisions/` — your design-system changelog and governance trail.
A token-change DDR carries: a unique ID (e.g. `DDR-0xx`), status, context (why the change), the decision
(the exact token delta), alternatives considered, consequences (which components are affected, what
migration is needed), and the resulting **SemVer bump**. DDRs are append-only (the ADR tradition) — if a
later change reverses one, write a new superseding DDR rather than editing the old one. This gives Claude
Code a durable, queryable rationale trail for why the system is the way it is.

## 5. `/brand` is the regression check

After any system change, the `/brand` route renders every token and core component, so drift or breakage
is visually obvious — treat it as a visual test surface. Re-run the screenshot sweep
(`responsive-and-cross-browser.md`) and the contrast gate (`accessibility-verification.md`): a token
change can quietly break a contrast pair or a component that depended on the old value.

## Why this care

A system's tokens are referenced across the whole app, so changing them ripples. Renaming a token after
hundreds of components reference it means touching every reference — which is why `establish-design-system` builds
semantic naming in from the start and `evolve-design-system` aliases rather than renames in place. This discipline is
what lets the system change without breaking everything downstream — the difference between a design
system and a pile of values.
