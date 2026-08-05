# Verification reads set an explicit `--limit`

A `gh … list` run to **verify state** — did the labels get created, is the PR
closed, is the issue claimed — sets an explicit `--limit`, or `--paginate` for
`gh api`. The default returns one page, so a verification that reads truncated
output reports **absence that is actually pagination** — and reports it with
exactly the confidence of a real answer.

This is the dedup search's failure mode (SKILL.md §3) pointed at a different
question, and it costs more here. A dedup search that truncates files a
duplicate: annoying, visible, recoverable at triage. A *verification* that
truncates says the write did not land, and the caller acts on it — re-running
provisioning, reporting a green step as failed, filing an issue for a bug that
does not exist. Nothing downstream can tell that zero from a true one.

## The defaults

| Command | Returns without a flag |
| --- | --- |
| `gh issue list` | 30 |
| `gh pr list` | 30 |
| `gh label list` | 30 |
| `gh api <endpoint>` | one page |

## Observed violation (2026-08-04, harmon-init)

Immediately after eleven `foreman:*` labels were created, this returned **0**:

```sh
gh label list --repo <owner/repo> --json name \
  --jq '[.[].name | select(startswith("foreman:"))] | length'
```

The labels existed. The default 30-label page, ordered alphabetically, did not
reach `foreman:*`. `--limit 100` returned all eleven. A post-merge verification
came one step from reporting provisioning as failed.

**`--jq` filters what was fetched, not what exists.** That is the whole
mechanism, and it is why the command reads as safe: the projection *looks* like
a query for `foreman:*` labels, so `0` reads as "no such labels". The selection
ran locally, over a page already cut to 30. Every `--jq`, `grep`, or `select`
over list output has this shape — a filter narrows what the fetch returned and
can never widen it.

## Size the limit to the namespace, not to the answer

A verification's limit cannot be sized to what you expect to find, because what
you expect to find is the thing being measured. Size it to the ceiling of the
namespace being read:

```sh
gh label list --repo <owner/repo> --limit 1000 --json name -q '.[].name' |
  grep -qx '<label>'
```

Verification reads are cheap and run once, so a generous limit costs nothing
worth saving; `gh` pages internally to satisfy a `--limit` above 100 rather
than failing.

## Strongest form: ask about the one thing

A filtered count over a list is the shape that fails silently. Where the API
addresses the object directly, ask for it and read the exit status — a 404 is
an answer, not an empty page:

```sh
gh api "repos/<owner>/<repo>/labels/<name>" --silent && echo present
```

Exit 0 present, exit 1 absent. `--silent` drops the response *body*, not the
error: a miss still prints `gh: Not Found (HTTP 404)` to stderr, so read the
status rather than the output, and redirect stderr where a clean miss is the
expected case.

Same for a single issue or PR: `gh issue view <n>` and `gh pr view <n>` ask
about one object and cannot truncate. Reach for a list only when the question
is genuinely about a set.

## Where this already applies

- SKILL.md §3 — the dedup search and the open-PR listing, both `--limit 200`.
- [`cross-repo-work.md`](cross-repo-work.md) — the same search, bound to the
  repo being filed into.
- `/preflight` reads the whole `agent:*` label family with `--limit 1000`
  before concluding a repo has no such family: the exact shape above, where
  the wrong answer silently reclassifies a claimed issue as unclaimed.
