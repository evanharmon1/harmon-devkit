#!/usr/bin/env bash
# sync-devkit-release.sh — turn a published harmon-devkit release into a
# complete, verified pin-and-sync PR for this repo.
#
# This is the downstream (generated-repo) twin of harmon-init's root-only
# script. It handles a single .skills-sync.yaml manifest — no template twin,
# no copier render verification. Bumping that pin by hand is a two-step chore,
# and the release-PR merge at the harmon-devkit end is the only intentional
# human gate. Everything BETWEEN them is deterministic, so this helper does it:
#
#   resolve + validate a stable upstream release
#     -> rewrite the pin
#     -> `task sync:skills`
#     -> assert the diff touched nothing but the expected paths
#     -> verify (offline + secrets)
#     -> commit, force-push the rolling bot branch, open/update exactly ONE PR
#
# It never merges anything, and it never writes the base branch. A validation,
# scope, or verification failure aborts BEFORE the push, so a broken sync can
# never surface as an open PR.
#
# Usage:
#   sync-devkit-release.sh resolve [TAG]   # validate + print the tag to sync to
#   sync-devkit-release.sh pinned          # print the current pin
#   sync-devkit-release.sh run [TAG]       # the whole pipeline
#
# TAG defaults to $SYNC_DEVKIT_TAG, then to the latest stable upstream release.
# Env: GH_APP_SLUG — when set, the bot commit identity is derived from the App.
#      SYNC_DEVKIT_ALLOW_DOWNGRADE=true — permit pinning an older release than
#      the current one (manual recovery only).
# Depends on: git, gh, task. Unit-tested by scripts/test-sync-devkit-release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVKIT_REPO="evanharmon1/harmon-devkit"
MANIFEST=".skills-sync.yaml"
BASE_BRANCH="main"
# One deterministic branch -> one rolling PR. A newer release rewrites it
# instead of opening a second PR (see the force-push in cmd_run).
SYNC_BRANCH="bot/sync-harmon-devkit"

LF="
"

BODY_FILE=""
GT_TMP=""
cleanup() {
    [ -n "$BODY_FILE" ] && rm -f "$BODY_FILE"
    [ -n "$GT_TMP" ] && rm -f "$GT_TMP"
    return 0
}
trap cleanup EXIT

die() {
    echo "sync-devkit-release: $*" >&2
    exit 1
}

note() {
    echo "sync-devkit-release: $*"
}

need_bin() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

need_manifests() {
    [ -f "$MANIFEST" ] || die "manifest '$MANIFEST' not found"
}

# ── Tag validation ────────────────────────────────────────────────────
# A dispatch payload is untrusted input, so the tag is checked for SHAPE before
# it is used anywhere and for EXISTENCE against the upstream API before it is
# believed. Deliberately pure shell: no pipe into grep, so there is no way for
# an embedded newline to satisfy a per-line anchored regex and slip through.
looks_like_tag() {
    case "${1:-}" in
    v*) ;;
    *) return 1 ;;
    esac
    _llt_rest="${1#v}"
    # Only digits and dots may follow the 'v'. This one gate also rejects
    # newlines, whitespace, and every shell metacharacter.
    case "$_llt_rest" in
    "" | *[!0-9.]* | .* | *.) return 1 ;;
    esac
    case "$_llt_rest" in
    *..*) return 1 ;;
    esac
    _llt_dots="${_llt_rest//[!.]/}"
    [ "${#_llt_dots}" -eq 2 ]
}

assert_tag_shape() {
    [ -n "${1:-}" ] || die "empty harmon-devkit tag"
    looks_like_tag "$1" ||
        die "refusing tag '$1' — expected a stable v<major>.<minor>.<patch> harmon-devkit tag"
}

# cmd_resolve [TAG] — echo the harmon-devkit tag to sync to, and NOTHING else
# on stdout: callers capture it.
cmd_resolve() {
    _cr_tag="${1:-}"
    if [ -z "$_cr_tag" ]; then
        _cr_tag="$(gh api "repos/$DEVKIT_REPO/releases/latest" --jq '.tag_name')" ||
            die "could not resolve the latest stable $DEVKIT_REPO release"
    fi
    assert_tag_shape "$_cr_tag"
    # Independent confirmation that the tag is a real, published, stable
    # release — never take the payload's word for it. GitHub's
    # get-release-by-tag already 404s on drafts; the explicit checks keep the
    # rejection loud rather than incidental.
    _cr_meta="$(gh api "repos/$DEVKIT_REPO/releases/tags/$_cr_tag" \
        --jq '[.tag_name, (.draft|tostring), (.prerelease|tostring)] | join(" ")')" ||
        die "no published $DEVKIT_REPO release found for tag '$_cr_tag'"
    _cr_name="" _cr_draft="" _cr_pre=""
    read -r _cr_name _cr_draft _cr_pre <<EOF
$_cr_meta
EOF
    [ "$_cr_name" = "$_cr_tag" ] ||
        die "upstream release for '$_cr_tag' reports tag_name '$_cr_name' — refusing"
    [ "$_cr_draft" = "false" ] || die "refusing tag '$_cr_tag' — it is a draft release"
    [ "$_cr_pre" = "false" ] || die "refusing tag '$_cr_tag' — it is a prerelease"
    printf '%s\n' "$_cr_tag"
}

# ── Manifests ─────────────────────────────────────────────────────────
# manifest_field FILE KEY [root] — the single value of a `KEY:` line.
#
# The optional third argument restricts the match to a TOP-LEVEL key. That is
# needed for `dest`, which appears once at column 0 for skills and again,
# indented, inside the optional `agents:` block — an unanchored match counts two
# and aborts. `ref` stays unanchored because it lives nested under `source:`.
manifest_field() {
    _mf_file="$1" _mf_key="$2" _mf_anchor="${3:-}"
    if [ "$_mf_anchor" = "root" ]; then
        _mf_grep="^${_mf_key}:"
        _mf_sed="s/^${_mf_key}:[[:space:]]*\\([^[:space:]#]*\\).*/\\1/p"
    else
        _mf_grep="^[[:space:]]*${_mf_key}:"
        _mf_sed="s/^[[:space:]]*${_mf_key}:[[:space:]]*\\([^[:space:]#]*\\).*/\\1/p"
    fi
    _mf_n="$(grep -c "$_mf_grep" "$_mf_file" || true)"
    [ "$_mf_n" = "1" ] ||
        die "expected exactly one '${_mf_key}:' line in $_mf_file (found $_mf_n)"
    sed -n "$_mf_sed" "$_mf_file"
}

set_pin() {
    _sp_file="$1" _sp_tag="$2"
    _sp_n="$(grep -c '^[[:space:]]*ref:' "$_sp_file" || true)"
    [ "$_sp_n" = "1" ] || die "expected exactly one 'ref:' line in $_sp_file (found $_sp_n)"
    # In-place via a temp copy: BSD and GNU `sed -i` take different arguments.
    # The tag passed assert_tag_shape, so it holds no sed replacement
    # metacharacter (&, \, |).
    _sp_tmp="$(mktemp)"
    sed "s|^\\([[:space:]]*ref:[[:space:]]*\\)[^[:space:]#]*|\\1${_sp_tag}|" "$_sp_file" >"$_sp_tmp"
    cat "$_sp_tmp" >"$_sp_file"
    rm -f "$_sp_tmp"
}

# cmd_pinned — the tag in the manifest.
cmd_pinned() {
    manifest_field "$MANIFEST" ref
}

# prov_field PROV FIELD — a `# FIELD: …` provenance header value. Single awk
# process on purpose: a `sed | head` pipeline can raise SIGPIPE and, under
# `pipefail`, turn a successful read into a script-killing failure.
prov_field() {
    [ -f "$1" ] || return 0
    awk -v k="$2" 'index($0, "# " k ":") == 1 {
        sub("^# " k ":[[:space:]]*", ""); print; exit
    }' "$1"
}

prov_ref() {
    [ -f "$1" ] || return 0
    awk 'index($0, "# ref:") == 1 {
        sub(/^# ref:[[:space:]]*/, ""); sub(/[[:space:]]*\(.*/, ""); print; exit
    }' "$1"
}

# version_key TAG — a fixed-width, lexicographically comparable key. String
# comparison, never arithmetic: a zero-padded key would be read as octal by
# `[ -lt ]`. printf's %d parses each component as base 10, so a tag written
# v1.08.0 still keys correctly.
version_key() {
    _vk_rest="${1#v}"
    _vk_tail="${_vk_rest#*.}"
    printf '%05d%05d%05d\n' "${_vk_rest%%.*}" "${_vk_tail%%.*}" "${_vk_tail#*.}"
}

# assert_not_a_downgrade TARGET CURRENT — a dispatch can be delivered late or
# out of order, and `concurrency` serializes runs without ordering them, so an
# older tag can arrive after the pin has already advanced. Rolling the pin
# backwards would open a bogus rollback PR that the next scheduled run (which
# resolves the LATEST release) immediately flips back. Manual intervention is a
# deliberate act, so it may still downgrade — that is the recovery path off a
# bad release.
assert_not_a_downgrade() {
    [ "${SYNC_DEVKIT_ALLOW_DOWNGRADE:-}" != "true" ] || return 0
    if [[ "$(version_key "$1")" < "$(version_key "$2")" ]]; then
        die "refusing to move the pin backwards ($2 -> $1) — replay a current release, or re-run the workflow manually with that tag to downgrade deliberately"
    fi
}

assert_safe_dest() {
    case "$1" in
    "" | "/" | "." | "..") die "refusing unsafe skills dest '$1'" ;;
    /*) die "refusing absolute skills dest '$1'" ;;
    ../* | */../* | */..) die "refusing skills dest with a '..' component: '$1'" ;;
    esac
}

# ── Diff scope ────────────────────────────────────────────────────────
# --no-renames so every change is exactly one path; -z so a path is never
# quoted or split.
changed_paths_z() {
    git diff --no-renames --name-only -z HEAD
    git ls-files --others --exclude-standard -z
}

# assert_expected_scope DEST — fail closed unless every changed path is one of
# the manifest, a provenance stamp, a vendored skill/agent the sync owns, or a
# portable `.agents/skills/` compatibility symlink that
# scripts/link-agent-skills.sh maintains as the second command of
# `task sync:skills`. The owned set is the UNION of the pre-sync (HEAD) and
# post-sync `# managed:` lines: a skill the new pin dropped appears only in the
# old list, one it added only in the new. Anything else — a local skill's
# contents, an unrelated file — is an unexpected write and aborts the run before
# anything is committed or pushed.
# managed_from_stamp PROV — the `# managed:` names recorded on a provenance
# stamp, taken from BOTH the committed and working-tree copies so a name the
# sync just added or just removed is allowed either way.
managed_from_stamp() {
    {
        git show "HEAD:$1" 2>/dev/null || true
        cat "$1" 2>/dev/null || true
    } | awk 'index($0, "# managed:") == 1 {
            sub(/^# managed:[[:space:]]*/, "")
            n = split($0, parts, ",")
            for (i = 1; i <= n; i++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
                if (parts[i] != "") print parts[i]
            }
        }'
}

# agents_dest_from_manifest — the agents dest the manifest declares, or
# empty when it has no `agents:` block. Read with yq when available and by a
# narrow grep otherwise, because this runs in CI where yq is present but also on
# a maintainer's machine where it may not be.
agents_dest_from_manifest() {
    if command -v yq >/dev/null 2>&1; then
        _adfm="$(yq -r '.agents.dest // ""' "$MANIFEST" 2>/dev/null || true)"
        [ "$_adfm" != "null" ] || _adfm=""
        printf '%s' "$_adfm"
        return 0
    fi
    sed -n '/^agents:/,$p' "$MANIFEST" |
        sed -n 's/^[[:space:]]*dest:[[:space:]]*//p' | head -n 1 |
        sed 's/[[:space:]]*#.*//' | tr -d '"'"'"''
}

assert_expected_scope() {
    _aes_dest="$1"
    _aes_prov="$_aes_dest/.SKILLS_PROVENANCE"
    # Agents ride the same manifest, so the sync writes their dest too. This
    # check FAILS CLOSED — without teaching it the agents paths, every
    # `.claude/agents/*.md` the sync legitimately wrote would read as a rogue
    # write and abort the automated pin-bump PR.
    _aes_adest="$(agents_dest_from_manifest)"
    _aes_aprov=""
    _aes_aallow=""
    if [ -n "$_aes_adest" ]; then
        _aes_aprov="$_aes_adest/.AGENTS_PROVENANCE"
        _aes_aallow="$(managed_from_stamp "$_aes_aprov")"
    fi
    _aes_allow="$(
        managed_from_stamp "$_aes_prov"
    )"
    # scripts/link-agent-skills.sh (the second command in `task sync:skills`)
    # writes a `.agents/skills/<name>` compatibility symlink for EVERY Claude
    # skill — managed or local — so the same skills are visible through the
    # cross-harness .agents standard. That dest is not in the manifest; it is
    # link-agent-skills.sh's own, resolved the same way here. An unsafe value
    # (absolute, or with a `..` component) disarms the allowance rather than
    # trusting it: portable links then read as rogue writes and abort, which is
    # the safe failure.
    _aes_pdir="${AGENT_SKILLS_DIR:-.agents/skills}"
    # Normalize the spelling before matching it against git's canonical changed
    # paths: strip a leading "./", collapse "//" (empty components), and drop a
    # trailing "/" so an equivalent repo-relative value (./.agents/skills,
    # .agents/skills/, .agents//skills) matches as it should. "." and ".."
    # components are left for the safety case below — a `..` traversal must stay
    # rejected, not be normalized away.
    while case "$_aes_pdir" in ./*) true ;; *) false ;; esac do
        _aes_pdir="${_aes_pdir#./}"
    done
    while case "$_aes_pdir" in *//*) true ;; *) false ;; esac do
        _aes_pdir="${_aes_pdir//\/\//\/}"
    done
    while case "$_aes_pdir" in */) true ;; *) false ;; esac do
        _aes_pdir="${_aes_pdir%/}"
    done
    case "$_aes_pdir" in
    "" | "/" | "." | ".." | /* | ../* | */../* | */..) _aes_pdir="" ;;
    esac
    # An AGENT_SKILLS_DIR overlapping the skills or agents dest would route the
    # portable-link allowance inside a tree the sync promises never to touch
    # (or, containing a dest, approve paths the dest's own block already
    # rejected), so disarm it: those paths then read as rogue writes and abort
    # — fail-closed. Both directions matter: pdir inside a dest, and a dest
    # inside pdir.
    if [ -n "$_aes_pdir" ]; then
        case "$_aes_pdir" in "$_aes_dest" | "$_aes_dest"/*) _aes_pdir="" ;; esac
    fi
    if [ -n "$_aes_pdir" ]; then
        case "$_aes_dest" in "$_aes_pdir" | "$_aes_pdir"/*) _aes_pdir="" ;; esac
    fi
    if [ -n "$_aes_pdir" ] && [ -n "$_aes_adest" ]; then
        case "$_aes_pdir" in "$_aes_adest" | "$_aes_adest"/*) _aes_pdir="" ;; esac
    fi
    if [ -n "$_aes_pdir" ] && [ -n "$_aes_adest" ]; then
        case "$_aes_adest" in "$_aes_pdir" | "$_aes_pdir"/*) _aes_pdir="" ;; esac
    fi
    # Delimited membership test (no `grep` subprocess): a pipeline whose reader
    # exits early can report SIGPIPE under `pipefail` and reject a legitimate
    # path.
    _aes_haystack="${LF}${_aes_allow}${LF}"

    _aes_bad=""
    while IFS= read -r -d '' _aes_p; do
        [ -n "$_aes_p" ] || continue
        case "$_aes_p" in
        "$MANIFEST" | "$_aes_prov") continue ;;
        esac
        if [ -n "$_aes_aprov" ] && [ "$_aes_p" = "$_aes_aprov" ]; then
            continue
        fi
        _aes_ok=0
        case "$_aes_p" in
        "$_aes_dest"/*)
            _aes_name="${_aes_p#"$_aes_dest"/}"
            _aes_name="${_aes_name%%/*}"
            case "$_aes_haystack" in
            *"${LF}${_aes_name}${LF}"*) _aes_ok=1 ;;
            esac
            ;;
        esac
        # A managed AGENT: flat `<dest>/<name>.md`, allowed only when that name
        # is on the agents stamp — a local agent the sync must never touch is
        # not on it, so an unexpected write to one still aborts the run.
        if [ "$_aes_ok" -eq 0 ] && [ -n "$_aes_adest" ]; then
            case "$_aes_p" in
            "$_aes_adest"/*.md)
                _aes_aname="${_aes_p#"$_aes_adest"/}"
                case "$_aes_aname" in
                */*) ;;
                *)
                    _aes_aname="${_aes_aname%.md}"
                    case "${LF}${_aes_aallow}${LF}" in
                    *"${LF}${_aes_aname}${LF}"*) _aes_ok=1 ;;
                    esac
                    ;;
                esac
                ;;
            esac
        fi
        # A portable `.agents/skills/<name>` symlink that link-agent-skills.sh
        # creates as part of `task sync:skills`. Without this allowance every
        # NEW managed skill's symlink reads as a rogue write and aborts the
        # pin-bump PR — latent until a devkit release adds skills the repo never
        # vendored before (v0.34.0 added three at once, breaking the sync).
        # Allowed when <name> is managed (a dropped skill's removed symlink
        # passes too: the name survives on the HEAD stamp) OR a matching skill
        # directory still exists under the skills dest — a local skill the sync
        # must never touch, but whose compatibility link is still the sync's to
        # maintain. A native portable skill at the same path would already have
        # aborted the run in the link step's divergent-name check.
        if [ "$_aes_ok" -eq 0 ] && [ -n "$_aes_pdir" ]; then
            case "$_aes_p" in
            "$_aes_pdir"/*)
                _aes_pname="${_aes_p#"$_aes_pdir"/}"
                # Only a flat .agents/skills/<name> symlink is the link step's
                # output. A nested path beneath a managed name is not something
                # it writes — and an entry replaced with a directory or an
                # arbitrary-target symlink is a rogue object the link step's
                # divergent-name check does not catch for a dropped skill — so
                # do not blanket-approve <name>/anything: leave _aes_ok at 0
                # and let it read as a rogue write (fail-closed).
                case "$_aes_pname" in
                */*) ;; # nested path → not a flat symlink → reject
                "" | "." | "..") ;;
                *)
                    case "$_aes_haystack" in
                    *"${LF}${_aes_pname}${LF}"*) _aes_ok=1 ;;
                    esac
                    if [ "$_aes_ok" -eq 0 ] && [ -d "$_aes_dest/$_aes_pname" ]; then
                        _aes_ok=1
                    fi
                    ;;
                esac
                ;;
            esac
        fi
        [ "$_aes_ok" -eq 1 ] || _aes_bad="${_aes_bad}  - ${_aes_p}${LF}"
    done < <(changed_paths_z)

    if [ -n "$_aes_bad" ]; then
        echo "sync-devkit-release: the sync wrote paths it does not own:" >&2
        printf '%s' "$_aes_bad" >&2
        die "expected only the skills-sync manifest, the provenance stamps, managed skills under $_aes_dest/, managed agents under ${_aes_adest:-<none>}/, and portable skill links under ${_aes_pdir:-<none>}/ — inspect by hand"
    fi
}

# ── Verification ──────────────────────────────────────────────────────
# run_untrusted CMD… — run a subprocess WITHOUT the repo-write App token.
#
# The sync clones harmon-devkit and the verification runs task subprocesses.
# Those inherit this process's environment, so leaving GH_TOKEN in it would hand
# a contents:write + pull-requests:write credential to every one of them — the
# exact exposure the non-persisted push credential exists to avoid. Everything
# they reach is public (harmon-devkit, registries), so nothing here needs the
# token; only `gh` and the single `git push` do.
run_untrusted() {
    env -u GH_TOKEN -u GITHUB_TOKEN "$@"
}

# verify:skills:offline proves manifest↔vendored consistency cheaply;
# security:secrets catches a credential that reached a harmon-devkit release
# before the sync PR's own CI could. The full byte-drift check (verify:skills)
# is left to the sync PR's CI, which runs it before branch protection allows
# a merge.
run_verification() {
    for _rv_target in verify:skills:offline security:secrets; do
        note "verifying: task $_rv_target"
        run_untrusted task "$_rv_target" ||
            die "verification failed at 'task $_rv_target' — nothing pushed, no PR touched"
    done
}

# configure_identity — commit as the CI GitHub App rather than as whatever the
# runner defaults to. A no-op when GH_APP_SLUG is unset (local runs, tests).
configure_identity() {
    _ci_slug="${GH_APP_SLUG:-}"
    [ -n "$_ci_slug" ] || return 0
    case "$_ci_slug" in
    *[!a-zA-Z0-9-]*) die "refusing unexpected GitHub App slug '$_ci_slug'" ;;
    esac
    _ci_uid="$(gh api "/users/${_ci_slug}[bot]" --jq '.id')" ||
        die "could not resolve the user id for '${_ci_slug}[bot]'"
    case "$_ci_uid" in
    "" | *[!0-9]*) die "unexpected user id '$_ci_uid' for '${_ci_slug}[bot]'" ;;
    esac
    git config user.name "${_ci_slug}[bot]"
    git config user.email "${_ci_uid}+${_ci_slug}[bot]@users.noreply.github.com"
}

write_pr_body() {
    _wb_old="$1" _wb_new="$2" _wb_prov="$3"
    # The agents rows are built here rather than inlined below so the body stays
    # honest when the manifest has no `agents:` block: an empty string collapses
    # to nothing instead of an "agents: (none)" row nobody needs.
    _wb_adest="$(agents_dest_from_manifest)"
    _wb_arow=""
    _wb_aline=""
    if [ -n "$_wb_adest" ] && [ -f "$_wb_adest/.AGENTS_PROVENANCE" ]; then
        _wb_arow="| vendored agents | $(prov_field "$_wb_adest/.AGENTS_PROVENANCE" managed) |${LF}"
        _wb_aline="- \`${_wb_adest}/.AGENTS_PROVENANCE\` and the managed agent files were re-vendored from that tag.${LF}"
    fi
    BODY_FILE="$(mktemp)"
    cat >"$BODY_FILE" <<EOF
Automated pin-and-sync of the vendored harmon-devkit agent skills${_wb_adest:+ and shared subagents}.

| | |
| --- | --- |
| previous pin | \`${_wb_old}\` |
| new pin | \`${_wb_new}\` |
| upstream release | https://github.com/${DEVKIT_REPO}/releases/tag/${_wb_new} |
| categories | $(prov_field "$_wb_prov" categories) |
| vendored skills | $(prov_field "$_wb_prov" managed) |
${_wb_arow}
## What changed

- \`${MANIFEST}\` pin \`${_wb_new}\`.
- \`${_wb_prov}\` and the managed skill directories were re-vendored from that tag.
${_wb_aline}
Nothing else — the run aborts if the sync writes a path it does not own.

## Verification

\`task verify:skills:offline\` and \`task security:secrets\` passed on this
commit before the branch was pushed; the PR's own CI runs the full drift check
(\`task verify:skills\`) before branch protection allows a merge.

## Merging

**Merging stays manual.** This PR is opened by the scheduled
\`sync-harmon-devkit.yml\` workflow; no automation merges it. A newer stable
harmon-devkit release rewrites this same branch rather than opening a second
PR.
EOF
}

# open_pr_number — the number of the open sync PR, or empty.
#
# `--head` filters by branch NAME only — gh cannot qualify it with an owner —
# so a fork PR whose head branch happens to be called $SYNC_BRANCH is returned
# too. Editing that would rewrite an unrelated contributor's PR with a
# trusted-looking title and leave the real sync PR unopened, so cross-repository
# heads are dropped. `// empty` matters as well: without it jq prints the
# string "null" and the caller would go on to edit PR "null".
open_pr_number() {
    _pn="$(gh pr list --head "$SYNC_BRANCH" --base "$BASE_BRANCH" --state open \
        --json number,isCrossRepository \
        --jq 'map(select(.isCrossRepository == false)) | .[0].number // empty')" ||
        die "could not list open PRs for $SYNC_BRANCH"
    case "$_pn" in
    *[!0-9]*) die "unexpected PR number '$_pn' for $SYNC_BRANCH" ;;
    esac
    printf '%s\n' "$_pn"
}

# pr_title N — the current title of PR N. A failed read is indeterminate, not
# stale metadata: repairing an unchanged ready-for-review PR would demote it,
# and a later reconciliation has no authority to restore that human handoff.
pr_title() {
    gh pr view "$1" --json title --jq '.title // empty' 2>/dev/null
}

# ensure_pr_draft N [HEAD] — fail closed unless PR N is confirmed draft and,
# when HEAD is supplied, points at that exact verified commit. A rolling
# sync PR may have been promoted after its previous head passed review; before
# replacing that head, and again after editing its metadata, return it to the
# draft workbench so no unverified revision is published to reviewers.
ensure_pr_draft() {
    _epd_pr="$1" _epd_expected="${2:-}"
    _epd_snapshot="$(gh pr view "$_epd_pr" --json headRefOid,isDraft \
        --jq '[.headRefOid, (.isDraft | tostring)] | join(" ")' 2>/dev/null)" ||
        die "could not confirm the head and draft state of PR #$_epd_pr"
    IFS=' ' read -r _epd_head _epd_state <<EOF
$_epd_snapshot
EOF
    if [ -n "$_epd_expected" ] && [ "$_epd_head" != "$_epd_expected" ]; then
        die "PR #$_epd_pr points at $_epd_head, not the verified head $_epd_expected"
    fi
    case "$_epd_state" in
    true) return 0 ;;
    false)
        note "returning sync PR #$_epd_pr to draft"
        gh pr ready --undo "$_epd_pr" ||
            die "could not return PR #$_epd_pr to draft"
        _epd_snapshot="$(gh pr view "$_epd_pr" --json headRefOid,isDraft \
            --jq '[.headRefOid, (.isDraft | tostring)] | join(" ")' 2>/dev/null)" ||
            die "could not confirm PR #$_epd_pr became draft"
        IFS=' ' read -r _epd_head _epd_state <<EOF
$_epd_snapshot
EOF
        if [ -n "$_epd_expected" ] && [ "$_epd_head" != "$_epd_expected" ]; then
            die "PR #$_epd_pr changed to $_epd_head while returning it to draft (expected $_epd_expected)"
        fi
        [ "$_epd_state" = "true" ] ||
            die "PR #$_epd_pr remained non-draft after conversion"
        ;;
    *) die "unexpected draft state '$_epd_state' for PR #$_epd_pr" ;;
    esac
}

open_or_update_pr() {
    _pr_title="$1" _pr_existing="$2" _pr_expected="${3:-}"
    if [ -n "$_pr_existing" ]; then
        note "updating the open sync PR #$_pr_existing"
        gh pr edit "$_pr_existing" --title "$_pr_title" --body-file "$BODY_FILE" ||
            die "could not update PR #$_pr_existing"
        ensure_pr_draft "$_pr_existing" "$_pr_expected"
    else
        note "opening a sync PR"
        gh pr create --draft --base "$BASE_BRANCH" --head "$SYNC_BRANCH" \
            --title "$_pr_title" --body-file "$BODY_FILE" ||
            die "could not open the sync PR"
        _pr_created="$(gh pr view "$SYNC_BRANCH" --json number --jq '.number // empty' 2>/dev/null)" ||
            die "could not resolve the newly created sync PR"
        case "$_pr_created" in
        '' | *[!0-9]*) die "could not resolve the newly created sync PR" ;;
        esac
        ensure_pr_draft "$_pr_created" "$_pr_expected"
    fi
}

# fetch_sync_branch — refresh refs/remotes/origin/$SYNC_BRANCH exactly once.
# The ref is dropped first so that after this it exists if and only if the
# branch exists upstream: `actions/checkout --fetch-depth 0` populates
# remote-tracking refs, and a branch deleted since then would otherwise be read
# as still present.
SYNC_BRANCH_FETCHED=0
fetch_sync_branch() {
    [ "$SYNC_BRANCH_FETCHED" -eq 0 ] || return 0
    SYNC_BRANCH_FETCHED=1
    git update-ref -d "refs/remotes/origin/$SYNC_BRANCH" 2>/dev/null || true
    # "the branch is not there" and "origin was unreachable" must not look the
    # same: both would leave the ref absent, and the second silently disarms
    # the guards that read it — the older-tag floor and the no-churn check —
    # so a transient blip could regress an open sync PR. ls-remote --exit-code
    # separates them: 0 = present, 2 = genuinely absent, anything else = error.
    _fsb_rc=0
    git_remote ls-remote --exit-code --heads origin "$SYNC_BRANCH" >/dev/null 2>&1 || _fsb_rc=$?
    case "$_fsb_rc" in
    0) ;;
    2) return 0 ;;
    *) die "could not reach origin to look for $SYNC_BRANCH (git exit $_fsb_rc) — refusing to proceed as if no sync PR were in flight" ;;
    esac
    git_remote fetch --quiet origin "+refs/heads/$SYNC_BRANCH:refs/remotes/origin/$SYNC_BRANCH" ||
        die "could not fetch $SYNC_BRANCH from origin"
    return 0
}

# remote_sync_tree — the tree the pushed sync branch already holds, or empty
# when the branch does not exist upstream. Trees, not commit SHAs: a rebuilt
# commit differs only by committer timestamp, so comparing SHAs would report a
# change on every run.
remote_sync_tree() {
    fetch_sync_branch
    git rev-parse --quiet --verify "refs/remotes/origin/$SYNC_BRANCH^{tree}" 2>/dev/null || return 0
}

# sync_branch_pin — the tag an already-pushed sync branch carries, or empty.
# The base branch alone is not enough to detect an out-of-order event: while a
# sync PR is open, the base pin stays stale, so a delayed older event would
# look like a legitimate move forward and force the open PR backwards.
sync_branch_pin() {
    fetch_sync_branch
    _sbp_yaml="$(git show "refs/remotes/origin/$SYNC_BRANCH:$MANIFEST" 2>/dev/null)" ||
        return 0
    awk '/^[[:space:]]*ref:/ {
        sub(/^[[:space:]]*ref:[[:space:]]*/, ""); sub(/[[:space:]#].*/, ""); print; exit
    }' <<EOF
$_sbp_yaml
EOF
}

# git_remote ARGS… — a git command that talks to origin, authenticated when a
# token is available.
#
# The token is deliberately not persisted into .git/config (the repo-wide
# `persist-credentials: false` hardening — see docs/architecture/security.md).
# The token is written to a temp file and the credential helper reads from it
# so the token lands in neither argv nor the environment — hooks and any other
# process inspecting /proc/*/cmdline cannot recover it. The file is chmod 600
# and removed immediately after the git command completes. The sync and
# verification subprocesses run with GH_TOKEN scrubbed separately (see
# run_untrusted); git commit is also wrapped with env -u (line 622). The empty
# first helper clears any inherited helper list so ours answers.
git_remote() {
    if [ -n "${GH_TOKEN:-}" ]; then
        _gt_tmp="$(mktemp)"
        printf 'username=x-access-token\npassword=%s\n' "$GH_TOKEN" >"$_gt_tmp"
        chmod 600 "$_gt_tmp"
        GT_TMP="$_gt_tmp"
        env -u GH_TOKEN -u GITHUB_TOKEN \
            git -c credential.helper= \
            -c credential.helper="!f() { cat \"$_gt_tmp\"; }; f" \
            "$@"
        _gt_rc=$?
        rm -f "$_gt_tmp"
        GT_TMP=""
        return $_gt_rc
    else
        # Local/manual run: rely on whatever credentials the operator's git has.
        git "$@"
    fi
}

push_sync_branch() {
    git_remote push --force origin "HEAD:refs/heads/$SYNC_BRANCH"
}

# assert_on_base — everything below reads the WORKING TREE, and the force-push
# publishes whatever the sync branch inherits from its start point, so the
# checkout must actually be the base branch and must match what origin holds.
# `actions/checkout` guarantees both in CI; locally this refuses to build the
# bot branch on a stale or ahead `main`, which would otherwise publish
# unrelated local commits under a bot title. The scope check cannot catch that:
# it inspects the working tree against HEAD, not HEAD against origin.
assert_on_base() {
    _aob_head="$(git rev-parse --abbrev-ref HEAD)"
    [ "$_aob_head" = "$BASE_BRANCH" ] ||
        die "HEAD is '$_aob_head', not '$BASE_BRANCH' — run the sync from the base branch"
    git_remote fetch --quiet origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" ||
        die "could not fetch origin/$BASE_BRANCH — cannot confirm the sync would start from the real base"
    [ "$(git rev-parse HEAD)" = "$(git rev-parse "refs/remotes/origin/$BASE_BRANCH")" ] ||
        die "local $BASE_BRANCH is not at origin/$BASE_BRANCH — fetch and reset first (a force-push would publish the difference)"
}

cmd_run() {
    _run_tag="${1:-${SYNC_DEVKIT_TAG:-}}"
    need_bin git
    need_bin gh
    need_bin task
    need_manifests
    [ -z "$(git status --porcelain)" ] ||
        die "working tree is not clean — refusing to build a sync commit on top of local changes"
    assert_on_base

    _run_target="$(cmd_resolve "$_run_tag")"
    _run_current="$(cmd_pinned)"
    _run_dest="$(manifest_field "$MANIFEST" dest root)"
    assert_safe_dest "$_run_dest"
    _run_prov="$_run_dest/.SKILLS_PROVENANCE"

    _run_adest="$(agents_dest_from_manifest)"
    # Always run the idempotent sync — no early no-op return. The sync:skills
    # task is cheap and idempotent; git diff --cached --quiet already catches
    # the no-change case after it runs, so a no-op-path correctness gap
    # (missing/corrupt managed directories, stale provenance, category changes)
    # cannot cause weekly reconciliation to silently skip a needed repair.
    # Called as a bare statement so a failure aborts here: inside the command
    # substitutions below, `set -e` would not see it and the run would continue
    # with the guards silently disarmed.
    fetch_sync_branch
    # The floor is the newest tag already in flight: the base pin, or the open
    # sync branch's pin when it is ahead (the PR has not merged yet).
    _run_floor="$_run_current"
    _run_branch_pin="$(sync_branch_pin)"
    if looks_like_tag "$_run_branch_pin" &&
        [[ "$(version_key "$_run_floor")" < "$(version_key "$_run_branch_pin")" ]]; then
        _run_floor="$_run_branch_pin"
    fi
    assert_not_a_downgrade "$_run_target" "$_run_floor"
    note "syncing $_run_current -> $_run_target"

    configure_identity
    # Always branch from the base, never from whatever the branch held last
    # run: that is what makes a newer release deterministically supersede an
    # older open sync PR instead of stacking on top of it.
    env -u GH_TOKEN -u GITHUB_TOKEN git checkout -B "$SYNC_BRANCH" "$BASE_BRANCH" >/dev/null

    set_pin "$MANIFEST" "$_run_target"
    run_untrusted task sync:skills ||
        die "'task sync:skills' failed at $_run_target — nothing pushed"
    assert_expected_scope "$_run_dest"

    _run_title="fix: sync harmon-devkit skills to $_run_target"

    git add -A
    if git diff --cached --quiet; then
        note "the sync produced no change — nothing to commit"
        return 0
    fi
    env -u GH_TOKEN -u GITHUB_TOKEN git commit -m "$_run_title" >/dev/null

    # The scheduled reconciliation fires while the sync PR is still open, and
    # the pins on the base branch stay stale until it merges — so every run
    # rebuilds the identical commit. Stop here when the pushed branch already
    # holds that tree AND its PR is open: pushing would churn the branch, reset
    # review state, and re-trigger the PR's CI daily for no change. Verification
    # is skipped too — this exact tree already passed it on the open PR.
    _run_open_pr="$(open_pr_number)"
    if [ -n "$_run_open_pr" ] && [ "$(remote_sync_tree)" = "$(git rev-parse 'HEAD^{tree}')" ]; then
        # The branch is right, but the PR's metadata may not be: a previous run
        # can push successfully and then fail at `gh pr edit`, and the title is
        # load-bearing (squash-merge feeds it to release-please, so a stale one
        # would name the wrong tag or fail the release-content guard). Repair it
        # here rather than leaving it wrong until someone notices. Either way
        # the push and the verification are skipped — this exact tree already
        # passed them on the open PR.
        _run_open_title="$(pr_title "$_run_open_pr")" ||
            die "could not read the title of PR #$_run_open_pr — refusing to change its handoff state"
        if [ "$_run_open_title" = "$_run_title" ]; then
            note "PR #$_run_open_pr already carries this exact sync at $_run_target — leaving it untouched"
            return 0
        fi
        note "PR #$_run_open_pr has the right branch but stale metadata — repairing it"
        write_pr_body "$_run_current" "$_run_target" "$_run_prov"
        open_or_update_pr "$_run_title" "$_run_open_pr" ""
        return 0
    fi

    run_verification

    # Force-push: this branch is owned solely by this workflow and is rebuilt
    # from the base every run, so its remote history is disposable by design.
    # Only $SYNC_BRANCH is ever written — never $BASE_BRANCH.
    # Convert an existing PR before the push: doing this afterward would expose
    # the replacement head as ready-for-review during the network/write window.
    if [ -n "$_run_open_pr" ]; then
        ensure_pr_draft "$_run_open_pr"
    fi
    note "pushing $SYNC_BRANCH"
    push_sync_branch || die "could not push $SYNC_BRANCH"

    write_pr_body "$_run_current" "$_run_target" "$_run_prov"
    open_or_update_pr "$_run_title" "$_run_open_pr" "$(git rev-parse HEAD)"
    note "done — merging $SYNC_BRANCH stays a human decision"
}

case "${1:-}" in
resolve)
    need_bin gh
    cmd_resolve "${2:-${SYNC_DEVKIT_TAG:-}}"
    ;;
pinned)
    need_manifests
    cmd_pinned
    ;;
run) cmd_run "${2:-}" ;;
*)
    echo "usage: sync-devkit-release.sh {resolve|pinned|run} [TAG]" >&2
    exit 2
    ;;
esac
