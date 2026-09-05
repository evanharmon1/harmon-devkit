# Shared review instructions

The mode and severity prose every **local-CLI finder** is driven with
(`agent-registry.json` `finders[]`, surface `local-cli`). Kept as data rather
than inlined in one script because two scripts render it —
`scripts/codex-review.sh` and `scripts/finder-review.sh` — and the severity
scale is normative: `AGENTS.md` § "Second-Model Review" gates the local loop on
this exact P0-P3 scale, and `agent-registry.json`'s per-finder `severity_map`
maps every other finder's vocabulary onto it. Two copies of a normative scale
drift; one copy cannot.

| file | contents |
| --- | --- |
| `challenge.txt` | the adversarial mode instruction (stage `challenge`) |
| `review.txt` | the verification-checkpoint mode instruction (stage `review`) |
| `severity.txt` | the P0-P3 scale, its gating rule, and the label-is-a-hypothesis rule |

A finder whose CLI takes no instructions of its own — CodeRabbit's, which
analyses the repository on its own terms — is not driven with these; its
registry entry maps its native labels onto the same scale instead.
