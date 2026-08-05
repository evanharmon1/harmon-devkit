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
gh label list --repo <owner/repo> --limit 1000 --json name -q '.[].name'
```

Verification reads are cheap and run once, so a generous limit costs nothing
worth saving; `gh` pages internally to satisfy a `--limit` above 100 rather
than failing. Capture that output and check the exit status before reading
anything into it — see the next section for why the obvious one-liner throws
the status away.

## A failed read is *unknown*, never *absent*

Truncation is one way a read reports nothing; the others are a network blip,
an expired token, a rate limit, a typo'd repo. They are the same defect —
something the reader did not see, reported as something that does not exist —
and only the first is fixed by `--limit`. So the limit is necessary and not
sufficient: check that the read **succeeded** before you believe its emptiness.

```sh
labels="$(gh label list --repo <owner/repo> --limit 1000 --json name -q '.[].name')" \
  || { echo 'label read failed — unknown, not absent' >&2; exit 2; }
grep -qx '<label>' <<<"$labels"
```

Assigning first and testing after is the whole point: piping `gh` straight
into `grep` discards its exit status, so a failed fetch reads as a clean miss.
Exit 2 rather than 1 keeps "could not verify" distinct from "verified absent"
— the same three-way reading the `set-issue-status.sh` exit codes use in
SKILL.md §6, and the same reason `/implement` treats a failed identity lookup
as unknown rather than unclaimed.

**Addressing one object directly does not escape this.** `gh api
"repos/<owner>/<repo>/labels/<name>"` looks stronger than listing — one
object, nothing to truncate — but it collapses more states into the same
signal, not fewer:

- Bad credentials exit non-zero exactly as a miss does (`HTTP 401`), so exit
  status alone cannot mean "absent".
- A wrong or unreadable **repo** returns `404` too, identically to a present
  repo with no such label.
- A name containing `/` is read as extra path segments, so it 404s on routing
  rather than on absence. (`gh` percent-encodes spaces on its own, so
  `good first issue` is fine — which is what makes the `/` case easy to miss.)

Use it when you control the name and want the object's *contents*; do not use
it as an existence test for a name you did not validate. For that, the
checked-list form above is both simpler and harder to fool. `gh issue view
<n>` and `gh pr view <n>` are safe in the same narrow sense: a number is not
path-sensitive, and a failure still has to be read as unknown.

## Where this already applies

- SKILL.md §3 — the dedup search and the open-PR listing, both `--limit 200`.
- [`cross-repo-work.md`](cross-repo-work.md) — the same search, bound to the
  repo being filed into.
- `/preflight` reads the whole `agent:*` label family with `--limit 1000`
  before concluding a repo has no such family: the exact shape above, where
  the wrong answer silently reclassifies a claimed issue as unclaimed.
