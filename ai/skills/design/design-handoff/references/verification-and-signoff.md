# Verification & sign-off: prove it, get approval, then close out

Read this during **Phases 5–7**. This is where you prove the implementation with numbers and
screenshots, get the user's explicit approval, and only **then** clean up and open a PR. Three gates
live here: rendered contrast, sign-off (blocks deleting the bundle), and the no-bypass commit
discipline.

## Phase 5 — Verify (don't trust a green build)

1. **Run the gates** through the repo's Taskfile, and **create any task that's missing** (from
   `assets/Taskfile.design.yml`):

   - `task lint:design` — static token-contrast gate (`scripts/check-contrast.mjs`) + off-palette
     scan.
   - `task check` — typecheck + lint + format (fast static verification).
   - `task verify` — the fuller pass (build, etc.).

   **Never use `--no-verify`** or otherwise skip git hooks — the hooks and CI are the authoritative
   gates, and bypassing them defeats the point. If a needed task doesn't exist in the repo, **add it**
   (copy `check-contrast.mjs` into `scripts/`, merge the design tasks) rather than skipping the check.

2. **Build** to confirm it compiles.
3. **Make it viewable.** Run the app (`task dev` / the project's run skill) and exercise every
   implemented screen.
4. **Screenshot every implemented view** — in both light and dark, for every state (default, empty,
   loading, error, disabled), and across key breakpoints (phone/tablet/desktop) and rendering engines
   (Chromium/Firefox/WebKit incl. mobile Safari). Playwright drives the whole matrix from one config —
   see `responsive-and-cross-browser.md`. These are what the user signs off against.
5. **Measure rendered contrast** (`accessibility-verification.md`): computed colors on the running
   page, both themes, every text role including long-form prose. Report the numbers. Fix and
   re-measure anything that fails **before** showing the user.

## Phase 6 — Sign-off gate (blocks deletion)

Do **not** assume the implementation is correct, and do **not** proceed to cleanup on your own
judgment. Before anything is deleted:

1. **Show the screenshots** (both themes, all states) and the measured contrast numbers.
2. **Compare to the bundle.** Put your screenshots beside the bundle's intent (`chats/chat1.md`, the
   prototype) and call out every delta you already know about — what you adapted, simplified, or
   deferred. Let the user decide with full information, not a happy summary.
3. **Ask explicitly** (`AskUserQuestion` or a direct question): "Does this match the intended design,
   or are there things to fix before I remove the handoff files?"
4. **Iterate until approved.** If the user wants changes, make them and re-verify. **Loop here — do not
   advance — until the user explicitly approves.** Approval is the user's call, never inferred from a
   green build or your own confidence.

The handoff bundle stays fully in place for this entire step — it is the reference the user compares
against.

## Phase 7 — Close out (only after explicit approval)

1. **Delete the bundle.** Once approved, delete `docs/design/handoff-<feature>/` so a stale runnable
   snapshot can't later mislead an agent into treating it as a source of truth. The one exception: if
   the design includes states not yet built, extract a _thin_ screenshot + intent note into the
   relevant spec first, then delete the rest. The durable records are the merged code,
   `DESIGN.md`/`globals.css`, `/brand`, and any DDR.
2. **Update the docs.** `docs/design/` (`brand.md`, `design-system.md`, `components.md`,
   `accessibility.md`, `ux.md`) and the `/brand` page whenever brand-level things changed — keep them
   in lockstep with `DESIGN.md`/`globals.css`. Update `README.md` if new scripts or usage were
   introduced.
3. **Flag decisions.** If the design embodied a genuine, debatable design-system decision (a new token
   architecture, a palette-philosophy shift, a vendor choice), tell the user it warrants a **DDR** in
   `/decisions/`. Architecture decisions don't belong in this skill or in `DESIGN.md` prose — they
   belong in a decision record.
4. **Commit & PR.** Use **Conventional Commits**. Commit on a **feature branch** — direct commits to
   `main` are blocked and wrong. The agent **never merges to `main` directly**: open a **PR** for human
   review of the diff.

## Definition-of-done recap (the gates, in order)

- **Licensing** (Phase 4) blocks **commit** — every asset cleared for commercial use.
- **Rendered contrast** (Phase 5) measured as **numbers**, both themes.
- **Sign-off** (Phase 6) blocks **deletion** — explicit user approval, never inferred.
- **Close-out** (Phase 7): `task verify` green, hooks not bypassed, bundle removed, docs + `/brand`
  updated, DDR flagged if warranted, Conventional Commit, PR opened (no direct merge to `main`).
