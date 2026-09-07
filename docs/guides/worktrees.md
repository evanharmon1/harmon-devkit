# Worktrees — when to make one, and how

A linked git worktree gives one line of work its own checked-out branch, so it
can change files and run the repo's tools without colliding with anyone else's
working tree — yours included. This guide is the decision rule for *when* a
worktree is worth its setup cost, and the one sanctioned way to create and
remove them. The mechanics and footguns of the tooling itself live in
[../conventions.md](../conventions.md) § Worktrees; running agents in them
from Herdr is [herdr.md](herdr.md).

## The decision rule

Ask three questions. If any answer is **yes**, default to a worktree — the
refinements below name the exceptions (chiefly: serial work on an otherwise
idle checkout).

1. **Will this work change tracked files and need to be committed?** Two
   sessions editing the same checkout step on each other's diffs, staged
   state, and `git status`, and a pull request needs its own branch checked
   out somewhere to commit on. This is the "one worktree per intended PR"
   heuristic — per unit of *committable* work.
2. **Will it run repo tooling that assumes a private, stable tree?**
   `task verify`, test suites, builds that write `dist/`, codegen, git hooks.
   They read the working tree at a moment in time; if something else is
   mid-edit you get phantom failures. Note what a worktree does *not*
   isolate: the host's ports, network, and shared home/global caches. Two
   parallel units whose tests bind a fixed port, or that share a package
   cache, still race — give each worker its own port/cache allocation on top
   of its own tree.
3. **Will it outlive a single turn, or need to be resumable?** A worktree is
   durable, *addressable* state: if the session dies, the branch and its
   edits survive on disk and another session can pick them up by name. A pane
   job's terminal context dies with the pane; whatever it wrote to disk
   (reports, scratch) persists but is nobody's responsibility — see the sweep.

If all three are **no**, you do not need a worktree. Work that *reads* the
repo and *writes somewhere else* — auditing, reviewing, research, reports,
label or issue hygiene via `gh`, anything whose output is a file in a scratch
directory or a change upstream on GitHub — is a **pane job**: a sibling
terminal with the repo as its cwd and no branch of its own. Commands that
write checkout-local state even though they feel read-only (`terraform plan`
writes `.terraform/`, builds write caches) count as *running the repo's
tooling*, question 2 — not as pane jobs in a shared checkout.

Compressed: **writes to the repo or runs its tooling → worktree (one per
PR-sized unit); reads the repo and writes elsewhere → pane.** The tell is
whether the work will ever run `git commit` **or** the repo's own tools.

## Refinements

- **A single agent still gets a worktree if you are working in the main
  checkout.** The collision is with you, not only with other agents.
- **Serial work on an idle checkout does not need one.** One change at a time
  with nobody else in the repo is a branch in the main checkout with less
  ceremony.
- **Worktree is not workspace.** The worktree decides *where* a session's cwd
  points; the terminal, panes, and agent still need a home (see
  [herdr.md](herdr.md)). Pane jobs reuse the workspace you already have.
- **The cost is the per-tree install.** Every worktree needs its own
  dependencies (`node_modules/`, `.venv/`, …) and its own hooks proof, which
  is exactly what `task worktree:new` pays for. Do not mint one for a two-line
  fix on an idle checkout; do mint one the moment work becomes parallel or
  long-lived.

## How: create, use, remove

**Create with `task worktree:new -- <name> [--branch <b>] [--base <ref>] [--no-install]`**
— never a bare `git worktree add`. The task creates `.worktrees/<name>` (the
one gitignored, lint-excluded location), creates or attaches the branch
(tracking a same-named remote branch rather than recreating it), bases a new
branch on the main worktree's verified HEAD, installs **this tree's**
dependencies, proves the git hooks fire inside it (`.git` is a *file* in a
linked worktree, so `-c core.hooksPath=.git/hooks` silently resolves to
nothing — a breaker the task exists to catch), prints the ready path, and
rolls the tree back if any step fails. One default to know: a **new** branch
is based on the *main worktree's* HEAD — first verified against that branch's
configured upstream, so a merely *stale* main is upgraded to the fresh
upstream tip (announced) while a *diverged* one refuses with a `--base`
remedy. The trap is a main checkout sitting on another feature branch: an
"independent" branch created now stacks on it and carries its commits into
the PR. For an independent PR, have the main
worktree on `main` first, or pass the base explicitly
(`--base origin/main`). The full option semantics and refusal cases are in
[../conventions.md](../conventions.md) § Worktrees.

**Work in it as a normal checkout.** `cd .worktrees/<name>`, then the ordinary
Dev Loop from `AGENTS.md`: edit → `task check` → `task verify` → the review
stages → push → PR. Commit boundaries and pushes are per worktree, so two
trees never share staged state.

**Remove with `task worktree:rm -- <name> [--force]`.** It refuses on
uncommitted work and on ignored local files such as a `.env` (which a plain
`git worktree remove` would silently delete), then prunes the registry and
clears gitlink debris. Ignored *directories* (`node_modules/`, `.venv/`,
`dist/`) do not block it — `worktree:new` reinstalls them.

## Pairing with Herdr

Herdr's own `worktree create` is a bare `git worktree add` plus a workspace;
it has no post-create hook and does not install anything. The sanctioned
composition is therefore **repo creates, Herdr binds**:

```bash
task worktree:new -- feat-x --branch feat/x          # runnable tree, hooks proven
herdr worktree open --path .worktrees/feat-x --label feat-x --no-focus
```

`worktree open` binds the existing checkout to a new Herdr workspace whose
root pane is ready for `herdr agent start`. When the work is verified and
pushed, close the Herdr side first and let the **repo** remove the tree:

```bash
herdr workspace close <id>      # panes + sessions only; the checkout stays
task worktree:rm -- feat-x      # guarded removal, registry prune
```

Do **not** use `herdr worktree remove` on a tree the repo created: it runs a
plain `git worktree remove`, which deletes ignored local files such as a
`.env` without the refusal `task worktree:rm` exists to give, and then the
task finds nothing left to guard. See [herdr.md](herdr.md) § Worktrees for
the alternatives and the sweep.

## The sweep

Closing a pane or workspace kills the processes in it, but nothing on disk —
a worktree, its branch, report or scratch files — is removed for you. End every fan-out
with: verify the results → close the panes/tabs you created → `git worktree
list` (or `herdr worktree list`, which also shows non-Herdr trees) → remove
what is finished → delete merged branches where the repo ships the task
(`task clean:branches` to review — it is a dry run by default — then
`task clean:branches -- --delete`) → clear scratch. Anything a worker deliberately detached
(`nohup`, a background server) survives its pane and is part of the sweep too.
