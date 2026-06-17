# Ethics & licensing: the commercial-use gate

Read this during **Phase 4**. This repo ships commercial products, so **every font, icon, and image
must permit commercial use before it is committed.** This is a blocking gate: if any asset's license
is unclear, **stop and flag it to the user** — don't guess, and don't silently treat an unclear asset
as cleared. None of this is legal advice; when the stakes are high, the user should consult a
professional.

## Fonts — OFL / Apache only

- **Safe:** SIL Open Font License (OFL) and Apache-2.0 fonts — free for commercial use, embeddable,
  and modifiable. Good modern defaults: **Inter** (OFL), **IBM Plex** (OFL), **Geist** (OFL).
- **Reserved names:** an OFL font may carry a Reserved Font Name — you may use and even modify the
  font, but you can't ship a modified version under that name (don't call a derivative "Plex").
- **Reject proprietary faces:** Helvetica, **SF Pro** (Apple platforms only), Gotham, Proxima Nova, and
  other foundry/licensed fonts — unless the user has bought a license. If the design calls for one,
  flag it and propose the nearest OFL alternative.
- **Google Fonts** qualify (the library is OFL/Apache) — but **self-host** the `.woff2`
  (`assets-fonts-favicons.md`), don't hotlink.

## Icons — Lucide is safe

- **Lucide** is **ISC-licensed**: free commercial use, modification, and redistribution, with **no
  attribution required**. Use it (named imports — `components-and-states.md`).
- **Font Awesome Free** is CC-BY-4.0 → **requires attribution**; flag it if used. Pro requires a paid
  license.
- Any other set: check the license before adopting — and don't mix sets regardless (bundle size +
  visual consistency).

## Images & stock

- **"Free to download" ≠ "free for commercial use."** Confirm the actual license (Unsplash/Pexels
  terms, the specific CC variant, or purchased-stock terms).
- Watch **CC-BY** (attribution required), **CC-BY-SA** (share-alike — can force you to license your own
  work alike), and **NC** (non-commercial — disqualifying for a commercial product).
- AI-generated images carry the same copyright caveat as logos, below.

## AI-generated logos — the trap

A prompt-generated logo is not what most people assume:

- **Copyright:** purely AI-generated output is **not copyrightable in the US** — there's no human
  authorship (Thaler v. Perlmutter, affirmed; the Copyright Office requires human authorship). A pure
  AI logo gives you **zero copyright protection** against someone copying it.
- **Trademark:** it **can** be trademarked — trademark needs distinctive use in commerce, not human
  authorship. That's where brand protection actually comes from.
- **Practical advice to surface to the user:**
  - add meaningful **human modification** so the human-authored parts can carry copyright;
  - run a **clearance search** (USPTO TESS plus common-law/web) before adopting it, to avoid
    infringing an existing mark;
  - **use it in commerce** to build trademark rights;
  - generic AI logos may be refused registration absent acquired distinctiveness.
- Don't silently treat an AI logo as fully protected — flag this; it's a business decision.

## Vendor lock-in — flag, don't decide

When the design or its implementation introduces a vendor dependency, surface the lock-in tradeoff so
the user chooses consciously, and record genuine decisions as a **DDR** (see
`verification-and-signoff.md`):

- **Convex** (backend): open-source (FSL → Apache-2.0 after two years) and self-hostable, but
  self-hosting is single-node and you own migrations/backups/scaling; the programming model stays
  Convex-specific. Professional is ~$25/developer/month.
- **Cloudflare** (Pages / R2 / Workers): lower egress cost than S3, but platform-specific APIs.
- **Tailwind / shadcn:** **low** lock-in — shadcn copies source into your repo so you own it; Tailwind
  is just CSS.

These are conscious tradeoffs, not blockers. A genuine, debatable choice (a backend, a token
architecture, a palette-philosophy shift) warrants a DDR in `/decisions/` — not prose buried in
`DESIGN.md`.

## The gate

Before committing (Phase 4 → Phase 7): every font, icon, and image cleared for commercial use; any AI
logo flagged with the copyright/trademark reality; anything unclear stopped and raised with the user.
