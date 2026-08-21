#!/usr/bin/env bash
# worktree-lock.sh — the per-path lifecycle lock protocol SHARED by
# worktree-new.sh and worktree-rm.sh, which source this file. One
# implementation on purpose: both commands must run identical lock
# semantics, and a correction applied to one copy of a duplicated protocol
# is a divergence, not a fix. Requires the sourcing script to define die()
# and to run under set -euo pipefail.
# ── Per-path lifecycle locks ─────────────────────────────────────────
# worktree:new and worktree:rm serialize per worktree path (harmon-init#839,
# #784): concurrent creations of `parent` and `parent/child` could otherwise
# both read the pre-creation registry, pass the ancestry checks, and
# register the nested layout those checks exist to refuse — and a removal's
# later steps could act on a worktree recreated at the same path mid-run.
#
# The protocol, shared by both scripts:
# - An operation on NAME holds every ancestor path SHARED and NAME itself
#   EXCLUSIVE. Ancestors are shared so sibling operations — feat/a and
#   feat/b both passing through feat — stay fully concurrent; an operation
#   ON an ancestor takes it exclusively and refuses while any live
#   descendant holds it, and vice versa.
# - Everything is TRY-acquired: contention refuses immediately rather than
#   queueing, so no deadlock is possible and no caller waits minutes to
#   then be refused at the registry.
# - A stale entry is broken by RENAMING it aside first — rename is atomic
#   and single-winner, so two breakers can never both "succeed" and then
#   delete each other's fresh lock. Only entries with a RECORDED owner
#   proven dead are ever broken; ownerless entries always refuse with a
#   manual remedy, because a crash inside the claim window cannot be told
#   apart from a suspension.
# - Liveness is judged with ps(1) — `kill -0` reports EPERM for another
#   user's live process, which reads as dead — plus the recorded process
#   start time where ps can report it, so a reused PID does not keep a dead
#   owner's lock alive. Only owners recorded on THIS host are judged; a
#   foreign host's entry refuses with the remedy, never a guess. Residuals,
#   stated: two PID namespaces sharing one hostname over one checkout
#   cannot be told apart from here (default container hostnames differ,
#   which is the intended guard). An acquirer that crashes inside the
#   two-statement claim window leaves an ownerless entry needing the
#   manual remedy its refusal message names. And an operation spawned into
#   its wrapper's process group (a non-job-control shell, a CI/task
#   runner) records that INHERITED pgid: kill the operation alone and the
#   surviving wrapper keeps the group non-empty, so the lock reads alive
#   and refuses with the manual remedy instead of self-breaking
#   (harmon-init#916). Accepted, in the fail-closed direction: a group
#   survivor cannot be told apart from the operation's own still-running
#   children post-mortem — children reparent but keep their pgid, and the
#   dead pid's ancestry is gone — so breaking there is a data-loss path;
#   and taking a dedicated process group instead would detach the
#   operation from terminal job control, so a caller's Ctrl-C no longer
#   reaches it and the "stuck live lock" this would fix is reproduced by
#   the fix itself.
# - Lock entries live in the COMMON git dir (shared across linked
#   worktrees; `--git-path` would resolve per-worktree). `/` in names is
#   encoded as `%` and entry suffixes use `+`; both characters are outside
#   the name charset both scripts enforce, so encodings cannot collide.
lock_root="$(git rev-parse --path-format=absolute --git-common-dir)/worktree-locks"
lock_host="$(hostname)"
lock_uid="$(id -u)"
# An operation can hold more than one exclusive lock — its worktree-path
# leaf plus a branch-namespace lock (acquire_branch_lock below) — so the
# held set is an array; a scalar slot would let the second acquisition
# orphan the first at release.
held_excl=()
# Marker paths are ABSOLUTE and the repository path may contain whitespace,
# so held markers live in a bash array — a space-joined scalar would split
# one path into several words at release and remove nothing.
held_shared=()
release_locks() {
    for _held_x in ${held_excl[@]+"${held_excl[@]}"}; do
        rm -rf "$lock_root/$_held_x+lock"
    done
    held_excl=()
    # The holders directory itself is deliberately never removed: an rmdir
    # here races a sibling's marker publication (mkdir -p sees the dir,
    # rmdir empties it away, the marker write then fails spuriously). An
    # empty holders dir is a few bytes of permanent bookkeeping; the
    # session-cleanup surface (#838) is where sweeping it belongs.
    for _held in ${held_shared[@]+"${held_shared[@]}"}; do
        rm -f "$_held"
    done
    held_shared=()
}
lock_stamp() {
    # The start stamp is recorded and compared under one pinned locale and
    # timezone: lstart renders via the locale's %c, so two invocations
    # differing in LC_TIME or TZ would otherwise disagree about the same
    # process and misread it as PID reuse.
    # The nonce makes every stamp unique per ACQUISITION: lstart has
    # one-second resolution, so a same-second PID reuse could otherwise
    # reproduce a dead owner's stamp exactly and slip past the
    # content-equality revalidation that guards breaking.
    printf '%s %s %s %s %s %s\n' "$$" "$lock_host" "$lock_uid" \
        "$(ps -o pgid= -p $$ 2>/dev/null | sed 's/^ *//;s/ *$//' | grep . || echo 0)" \
        "n$$.$(date +%s).$RANDOM$RANDOM$RANDOM" \
        "$(LC_ALL=C TZ=UTC ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//;s/ *$//')"
}
lock_owner_alive() {
    # $1 = recorded "pid host uid pgid [start-time]". Anything unparseable,
    # and any owner from another host, is treated as alive: breaking is only
    # ever allowed on positive evidence of death.
    _own_pid="${1%% *}"
    _own_rest="${1#* }"
    _own_host="${_own_rest%% *}"
    _own_uid=""
    _own_pgid=""
    _own_start=""
    case "$_own_rest" in *" "*) _own_rest="${_own_rest#* }" ;; *) _own_rest="" ;; esac
    _own_uid="${_own_rest%% *}"
    case "$_own_rest" in *" "*) _own_rest="${_own_rest#* }" ;; *) _own_rest="" ;; esac
    _own_pgid="${_own_rest%% *}"
    # Field 5 is the per-acquisition nonce; it exists for stamp uniqueness
    # and plays no part in liveness, so it is skipped here.
    case "$_own_rest" in *" "*) _own_rest="${_own_rest#* }" ;; *) _own_rest="" ;; esac
    case "$_own_rest" in *" "*) _own_start="${_own_rest#* }" ;; esac
    [ "$_own_host" = "$lock_host" ] || return 0
    case "$_own_pid" in "" | *[!0-9]*) return 0 ;; esac
    # Liveness is judged only for owners recorded with OUR OWN uid: no
    # hidepid-style restriction hides a user's processes from that same
    # user, so a same-uid absence is real death, while a foreign or
    # unrecorded uid can never be distinguished from permission filtering
    # and fails closed. ps is additionally probed against our own pid so a
    # sandbox denying ps entirely reads as indeterminate, not dead.
    [ "$_own_uid" = "$lock_uid" ] || return 0
    [ -n "$(ps -p $$ -o pid= 2>/dev/null)" ] || return 0
    # The recorded SHELL dying is not the operation dying: a SIGKILLed or
    # OOM-culled wrapper can leave children — git worktree remove, a hook,
    # an installer — still mutating the tree. The stamp therefore records
    # the process GROUP, which those children inherit, and death requires
    # BOTH the pid evidence to fail (gone, or start-time mismatch = reuse)
    # AND the group to be empty. A child that setsid()s out of the group is
    # the documented residual.
    _pid_dead=0
    if [ -z "$(ps -p "$_own_pid" -o pid= 2>/dev/null)" ]; then
        _pid_dead=1
    elif [ -n "$_own_start" ]; then
        _now_start="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$_own_pid" 2>/dev/null | sed 's/^ *//;s/ *$//')"
        if [ -n "$_now_start" ] && [ "$_now_start" != "$_own_start" ]; then
            _pid_dead=1
        fi
    fi
    [ "$_pid_dead" -eq 1 ] || return 0
    # Group evidence fails CLOSED: a stamp that could not capture a pgid,
    # and a scan that cannot even see our own group, prove nothing about
    # the operation's children — and "no proof" must read as alive.
    case "$_own_pgid" in "" | 0 | *[!0-9]*) return 0 ;; esac
    _group_scan="$(ps -Ao pgid= 2>/dev/null || true)"
    _self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
    if [ -z "$_self_pgid" ] ||
        [ -z "$(printf '%s\n' "$_group_scan" | awk -v g="$_self_pgid" '$1 == g {print; exit}')" ]; then
        return 0
    fi
    if [ -n "$(printf '%s\n' "$_group_scan" | awk -v g="$_own_pgid" '$1 == g {print; exit}')" ]; then
        return 0
    fi
    return 1
}
lock_try_break() {
    # $1 = lock dir, $2 = the owner content it was judged dead on. Breaking
    # is serialized under its own one-shot lock and REVALIDATED inside it:
    # without that, a second breaker still holding yesterday's judgement
    # can rename away the fresh lock the first breaker's successor just
    # acquired. Content equality is the validation — a re-acquired lock
    # carries a different stamp. Ownerless entries are never judged
    # breakable at all, so an empty judgement never reaches this function. Returns 0 only when this
    # caller performed the break.
    _break="$1+break"
    if ! mkdir "$_break" 2>/dev/null; then
        # A break mutex is NEVER reclaimed, by policy: reclaiming
        # recovery-state needs its own serialization, and that recursion
        # has no bottom — every rename-aside of a re-creatable well-known
        # path re-opens the same stale-observation TOCTOU one level down.
        # The recursion terminates here instead: level-0 locks self-heal
        # under the break mutex, and a breaker that died inside its
        # milliseconds-long window leaves a dir only a human removes —
        # named precisely, with the remedy, rather than guessed at.
        _break_owner="$(cat "$_break/owner" 2>/dev/null || true)"
        if [ -n "$_break_owner" ] && ! lock_owner_alive "$_break_owner"; then
            die "a crashed lock-recovery attempt left $_break behind (${_break_owner}) — verify that process is gone, remove that directory, and re-run"
        fi
        return 1
    fi
    lock_stamp >"$_break/owner"
    _break_now="$(cat "$1/owner" 2>/dev/null || true)"
    if [ "$_break_now" != "$2" ]; then
        rm -rf "$_break"
        return 1
    fi
    if mv "$1" "$lock_root/.dead.$$" 2>/dev/null; then
        rm -rf "$lock_root/.dead.$$"
    fi
    rm -rf "$_break"
    return 0
}
ancestor_holders_quiet() {
    # $1 = encoded ancestor key. True when no LIVE holder marker other than
    # our own exists for it — the rmdir walk consults this so an emptied
    # shared parent is never deleted out from under a live sibling
    # operation (any number of which may hold the ancestor concurrently; a
    # bounded retry on the claiming side cannot absorb unbounded
    # deletions, so the deleting side yields instead). Unreadable or
    # ownerless markers read as live: fail closed.
    for _q_marker in "$lock_root/$1+holders"/*; do
        [ -e "$_q_marker" ] || continue
        _q_ours=0
        for _q_held in ${held_shared[@]+"${held_shared[@]}"}; do
            if [ "$_q_held" = "$_q_marker" ]; then
                _q_ours=1
                break
            fi
        done
        [ "$_q_ours" -eq 1 ] && continue
        _q_owner="$(cat "$_q_marker" 2>/dev/null || true)"
        if lock_owner_alive "${_q_owner:-0 unreadable}"; then
            return 1
        fi
    done
    return 0
}
acquire_excl() {
    # $1 = encoded path, $2 = display path
    _excl="$lock_root/$1+lock"
    _excl_tries=0
    while ! mkdir "$_excl" 2>/dev/null; do
        if [ ! -d "$_excl" ]; then
            die "cannot create lock $_excl — the lock name may exceed a filesystem limit; shorten the worktree name"
        fi
        _excl_owner="$(cat "$_excl/owner" 2>/dev/null || true)"
        _excl_tries=$((_excl_tries + 1))
        if [ "$_excl_tries" -le 2 ]; then
            if [ -n "$_excl_owner" ] && ! lock_owner_alive "$_excl_owner"; then
                lock_try_break "$_excl" "$_excl_owner" || true
                continue
            fi
            # An OWNERLESS entry is deliberately never reclaimed: nothing
            # can distinguish a crash inside the two-statement claim window
            # from a suspension, and reclaiming a suspended acquirer's lock
            # hands out two exclusive owners. The refusal below names the
            # manual remedy for the vanishingly rare crash case.
        fi
        die "another worktree operation holds '$2' (${_excl_owner:-owner not yet recorded}; lock $_excl) — if that process is gone, remove the lock directory and re-run"
    done
    lock_stamp >"$_excl/owner"
    held_excl=(${held_excl[@]+"${held_excl[@]}"} "$1")
    # Exclusive also means: no live descendant operation may be holding
    # this path shared. Dead holders are pruned; a live one refuses (the
    # EXIT trap releases the exclusive lock just taken).
    for _marker in "$lock_root/$1+holders"/*; do
        [ -e "$_marker" ] || continue
        _marker_owner="$(cat "$_marker" 2>/dev/null || true)"
        # An empty marker — a holder inside its publication window, or one
        # crashed there — is never swept, for the same undecidability that
        # protects ownerless locks; the refusal names the manual remedy.
        if lock_owner_alive "${_marker_owner:-0 unreadable}"; then
            die "a worktree operation under '$2/' is in progress (${_marker_owner:-holder unreadable}; $_marker) — if that process is gone, remove the marker file and re-run"
        fi
        rm -f "$_marker"
    done
}
acquire_shared() {
    # $1 = encoded path, $2 = display path. Marker first, exclusive-check
    # second — the exclusive side checks in the opposite order, so however
    # the two interleave at least one of them sees the other and refuses.
    mkdir -p "$lock_root/$1+holders" 2>/dev/null ||
        die "cannot create lock marker under $lock_root/$1+holders — the lock name may exceed a filesystem limit; shorten the worktree name"
    # The marker file is claimed with mktemp, never named by bare PID: two
    # PID namespaces (a container and its host over one bind-mounted
    # checkout) can run identical PIDs, and a shared name would let one
    # holder overwrite the other and a single release delete the exclusion
    # both depend on.
    _marker_path="$(mktemp "$lock_root/$1+holders/holder.XXXXXX")" ||
        die "cannot claim a holder marker under $lock_root/$1+holders"
    lock_stamp >"$_marker_path"
    held_shared=(${held_shared[@]+"${held_shared[@]}"} "$_marker_path")
    _shared_excl="$lock_root/$1+lock"
    if [ -d "$_shared_excl" ]; then
        _shared_owner="$(cat "$_shared_excl/owner" 2>/dev/null || true)"
        if lock_owner_alive "${_shared_owner:-0 unreadable}"; then
            die "another worktree operation holds '$2' (${_shared_owner:-owner not yet recorded}; lock $_shared_excl) — if that process is gone, remove the lock directory and re-run"
        fi
        lock_try_break "$_shared_excl" "$_shared_owner" || true
    fi
}
acquire_branch_lock() {
    # $1 = branch name. Serializes branch-ref publication and attachment
    # across operations whose PATH locks never contend — `new x --branch b`
    # and `new y --branch b` lock the paths x and y, yet both write or
    # attach the one branch b, and without this lock the loser's rollback
    # can delete the ref out from under the winner's checked-out worktree
    # (harmon-init#916, challenge round 2). The key lives in a namespace no
    # path key can produce: path components cannot contain '=', so
    # 'branch=<name>' never collides with a worktree-path lock. Lowercased
    # and length-clamped exactly as path keys are, for the same reasons.
    _bl_enc="$(printf 'branch=%s' "$1" | tr '/' '%' | tr '[:upper:]' '[:lower:]')"
    # Measured in BYTES, not characters: branch names are not charset-
    # restricted the way worktree names are, so a multibyte name can pass a
    # character count while its flattened basename exceeds NAME_MAX
    # (review r1). Path keys need no such care — their charset is ASCII.
    if [ "$(printf '%s' "$_bl_enc" | wc -c | tr -d ' ')" -gt 200 ]; then
        # The hashed form KEEPS the 'branch=' prefix: a bare 'h<cksum>' key
        # lands in the path-key namespace, where the creation whitelist
        # admits a worktree literally named that string — the operation
        # would then contend with its own path lock and refuse itself
        # (PR #932 cloud review).
        _bl_enc="branch=h$(printf '%s' "$_bl_enc" | cksum | tr ' \t' '--')"
    fi
    acquire_excl "$_bl_enc" "branch '$1'"
}
acquire_path_locks() {
    _lock_rest="$1"
    _lock_prefix=""
    mkdir -p "$lock_root"
    while [ -n "$_lock_rest" ]; do
        _lock_seg="${_lock_rest%%/*}"
        case "$_lock_rest" in
        */*) _lock_rest="${_lock_rest#*/}" ;;
        *) _lock_rest="" ;;
        esac
        _lock_prefix="${_lock_prefix:+$_lock_prefix/}$_lock_seg"
        # Lowercased: the default macOS filesystem is case-insensitive, so
        # `Foo` and `foo` are ONE worktree path and must contend on one
        # key. On case-sensitive systems this over-serializes two genuinely
        # distinct names — refusal, the safe direction, never under-locking.
        _lock_enc="$(printf '%s' "$_lock_prefix" | tr '/' '%' | tr '[:upper:]' '[:lower:]')"
        # A very long nested name would exceed NAME_MAX as one flat lock
        # basename although every real path component is valid — and such a
        # worktree may already exist, so refusing would strand it. Long
        # encodings collapse to a checksum key; a (astronomically unlikely)
        # collision only over-serializes two names, never under-locks one.
        if [ "${#_lock_enc}" -gt 200 ]; then
            # Hashed from the NORMALIZED key, not the raw prefix: hashing
            # the original case would let long case-aliases of one path
            # diverge into distinct keys, undoing the lowercasing above.
            _lock_enc="h$(printf '%s' "$_lock_enc" | cksum | tr ' \t' '--')"
        fi
        if [ -z "$_lock_rest" ]; then
            acquire_excl "$_lock_enc" "$_lock_prefix"
        else
            acquire_shared "$_lock_enc" "$_lock_prefix"
        fi
    done
}
