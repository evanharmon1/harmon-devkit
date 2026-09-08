#!/usr/bin/env bash
set -euo pipefail

# BOT PROFILE ONLY. Single entrypoint for the bot devcontainer's fail-closed,
# non-interactive policy across every agent harness installed in the image,
# keyed by agent-registry.json's harness slugs.
#
#   bot-autonomy.sh apply     — write each covered, installed harness's bot
#                                policy (idempotent).
#   bot-autonomy.sh verify    — re-read each covered, installed harness's
#                                EFFECTIVE runtime state (never the file apply
#                                wrote) and fail if it diverges; also fail if
#                                a registered-but-unsupported harness has
#                                become installed with no real coverage.
#   bot-autonomy.sh coverage  — static check only, no container required:
#                                every agent-registry.json harness slug
#                                resolves to exactly one of a module, an
#                                alias, or an unsupported entry. Used by
#                                scripts/test-bot-autonomy.sh; not part of the
#                                post-create/post-start lifecycle.
#
# Coverage data lives beside this script's modules, never inline here:
#   .devcontainer/config/bot-autonomy/<slug>.sh   — a real module (apply,
#     verify, executable subcommands). Presence of the file IS membership in
#     the "module" bucket, so it can never drift from what actually dispatches.
#   .devcontainer/config/bot-autonomy/aliases.json      — slug -> target slug,
#     for a slug that launches another slug's module's executable under a
#     different provider configuration.
#   .devcontainer/config/bot-autonomy/unsupported.json  — slug -> {executable,
#     reason}. `executable` is a PATH-checkable binary name, or JSON `null`
#     when the slug has no standalone binary at all (e.g. a GitHub Action).
#     `reason` is documentation only and never changes verify's behavior: the
#     instant a named executable is found installed, its slug is treated
#     exactly like an uncovered slug and verify fails naming it, regardless of
#     why it was unsupported. See
#     https://github.com/evanharmon1/harmon-init/blob/main/openspec/changes/archive/2026-09-05-bot-autonomy-bootstrap/design.md - Decisions.
#
# See docs/architecture/security.md and
# https://github.com/evanharmon1/harmon-init/blob/main/openspec/specs/devcontainer/bot-autonomy/spec.md
# for the full contract.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Modules/tables are baked into the image alongside the rest of
# .devcontainer/config/ (COPY .devcontainer/config/ /usr/local/share/
# devcontainer-config/ in the Dockerfile); this script itself is not, so it
# always runs from the checkout. Prefer the baked copy — the reproducible,
# image-pinned source of truth — falling back to the checkout-relative one for
# local unit tests and any context without a built image.
CONFIG_DIR="${BOT_AUTONOMY_CONFIG_DIR:-}"
if [ -z "$CONFIG_DIR" ]; then
    if [ -d /usr/local/share/devcontainer-config/bot-autonomy ]; then
        CONFIG_DIR=/usr/local/share/devcontainer-config/bot-autonomy
    else
        CONFIG_DIR="$(cd "${SCRIPT_DIR}/../config/bot-autonomy" && pwd)"
    fi
fi
ALIASES_FILE="${BOT_AUTONOMY_ALIASES:-${CONFIG_DIR}/aliases.json}"
UNSUPPORTED_FILE="${BOT_AUTONOMY_UNSUPPORTED:-${CONFIG_DIR}/unsupported.json}"

# agent-registry.json lives at the repository root, never baked into the
# image (only .devcontainer/config/ is) — it is read from the checkout that
# post-create/post-start already run from (workspaceFolder is their cwd).
resolve_registry() {
    if [ -n "${BOT_AUTONOMY_REGISTRY:-}" ]; then
        printf '%s' "${BOT_AUTONOMY_REGISTRY}"
        return 0
    fi
    if [ -f "${PWD}/agent-registry.json" ]; then
        printf '%s' "${PWD}/agent-registry.json"
        return 0
    fi
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$root" ] && [ -f "${root}/agent-registry.json" ]; then
        printf '%s' "${root}/agent-registry.json"
        return 0
    fi
    return 1
}

# module_slug_for <slug>  — prints <slug> and succeeds iff a module file
# exists for it. Membership in the "module" bucket is exactly "a file named
# <slug>.sh exists here" — there is no separate table to drift from that.
module_slug_for() {
    if [ -f "${CONFIG_DIR}/$1.sh" ]; then
        printf '%s' "$1"
        return 0
    fi
    return 1
}

# alias_target_for <slug>  — prints the target module slug and succeeds iff
# <slug> is a key in aliases.json.
alias_target_for() {
    local target
    target="$(jq -r --arg s "$1" '.[$s] // empty' "$ALIASES_FILE" 2>/dev/null)"
    [ -n "$target" ] || return 1
    printf '%s' "$target"
}

# unsupported_entry_for <slug>  — prints "<executable>\t<reason>" (executable
# is the literal string "null" for a structural, never-installable entry) and
# succeeds iff <slug> is a key in unsupported.json.
unsupported_entry_for() {
    local entry
    entry="$(jq -r --arg s "$1" '
        .[$s] // empty |
        select(. != null) |
        "\(.executable // "null")\t\(.reason // "")"
    ' "$UNSUPPORTED_FILE" 2>/dev/null)"
    [ -n "$entry" ] || return 1
    printf '%s' "$entry"
}

# module_executable <module-slug>  — asks the module itself which binary it
# governs, so this stays the module's own declaration rather than a second
# table here that could drift from it.
module_executable() {
    bash "${CONFIG_DIR}/$1.sh" executable
}

# module_always_dispatch <module-slug>  — true when apply/verify must run
# regardless of whether the module's declared executable is currently on
# PATH. Antigravity's own agy presence is exactly what apply/verify manage
# (ensure-antigravity-cli.sh removes it when the Copier option is disabled)
# — gating dispatch on "agy is on PATH" skips the disabled branch's
# settings restore precisely when the option is being disabled, the
# opposite of the intent. A module opts in via an `always_dispatch`
# subcommand printing exactly "true"; a module that does not implement the
# subcommand (everything except antigravity today) exits nonzero here and
# keeps the ordinary executable-presence gate.
module_always_dispatch() {
    [ "$(bash "${CONFIG_DIR}/$1.sh" always_dispatch 2>/dev/null)" = "true" ]
}

# resolve_module_for <slug>  — prints the module slug that governs <slug>,
# whether <slug> IS a module directly or ALIASES to one, and succeeds iff
# either holds. Dispatch resolves every covered slug through this one path
# so an aliased slug is governed by its target module even if the target's
# OWN slug is ever removed from the registry — apply/verify must not depend
# on the target still being independently iterated to get invoked.
resolve_module_for() {
    local slug="$1" target
    if module_slug_for "$slug" >/dev/null 2>&1; then
        printf '%s' "$slug"
        return 0
    fi
    if target="$(alias_target_for "$slug" 2>/dev/null)"; then
        printf '%s' "$target"
        return 0
    fi
    return 1
}

registry_slugs() {
    local registry
    registry="$(resolve_registry)" || {
        echo "bot-autonomy: agent-registry.json not found (checked \$BOT_AUTONOMY_REGISTRY, \${PWD}/agent-registry.json, and the git toplevel)" >&2
        return 1
    }
    jq -r '.harnesses[].slug' "$registry"
}

cmd_apply() {
    local slug module_slug exe failed=0 slugs modules_seen=""
    # A `while read < <(registry_slugs)` here would silently swallow a
    # registry_slugs failure: the exit status of a while loop whose body
    # never runs (immediate EOF from an empty/failed process substitution)
    # is 0, not the substituted command's — the exact silent-failure shape
    # this whole change exists to eliminate. Capture into a variable first,
    # via a plain command substitution, so its exit code is checkable.
    slugs="$(registry_slugs)" || return 1
    while IFS= read -r slug; do
        module_slug="$(resolve_module_for "$slug" 2>/dev/null)" || continue
        # Dedup: an aliased slug and its target can both appear in the same
        # registry pass (or two aliases can share a target) — apply that
        # module's policy exactly once per run.
        case " $modules_seen " in
        *" $module_slug "*) continue ;;
        esac
        modules_seen="$modules_seen $module_slug"
        exe="$(module_executable "$module_slug")"
        if ! command -v "$exe" >/dev/null 2>&1 && ! module_always_dispatch "$module_slug"; then
            echo "==> bot-autonomy: ${module_slug} executable '${exe}' not present; skipping apply"
            continue
        fi
        echo "==> bot-autonomy: applying ${module_slug}..."
        if ! bash "${CONFIG_DIR}/${module_slug}.sh" apply; then
            echo "bot-autonomy: apply failed for ${module_slug}" >&2
            failed=1
        fi
    done <<<"$slugs"
    if [ "$failed" -ne 0 ]; then
        echo "bot-autonomy: apply failed — see above" >&2
        return 1
    fi
    echo "==> bot-autonomy: apply complete."
}

cmd_verify() {
    local slug module_slug exe entry unsupported_exe unsupported_reason failed=0 slugs modules_seen=""
    slugs="$(registry_slugs)" || return 1
    while IFS= read -r slug; do
        if module_slug="$(resolve_module_for "$slug" 2>/dev/null)"; then
            case " $modules_seen " in
            *" $module_slug "*) continue ;;
            esac
            modules_seen="$modules_seen $module_slug"
            exe="$(module_executable "$module_slug")"
            if ! command -v "$exe" >/dev/null 2>&1 && ! module_always_dispatch "$module_slug"; then
                continue
            fi
            if ! bash "${CONFIG_DIR}/${module_slug}.sh" verify; then
                echo "bot-autonomy: verify failed for ${module_slug} (registry slug '${slug}')" >&2
                failed=1
            fi
        elif entry="$(unsupported_entry_for "$slug" 2>/dev/null)"; then
            unsupported_exe="${entry%%$'\t'*}"
            unsupported_reason="${entry#*$'\t'}"
            if [ "$unsupported_exe" != "null" ] && command -v "$unsupported_exe" >/dev/null 2>&1; then
                echo "bot-autonomy: verify failed — '${slug}' executable '${unsupported_exe}' is installed but has no bot-autonomy module or alias (${unsupported_reason})" >&2
                failed=1
            fi
        else
            echo "bot-autonomy: verify failed — registry slug '${slug}' has no module, alias, or unsupported entry (bot-autonomy's coverage tables are out of date relative to agent-registry.json)" >&2
            failed=1
        fi
    done <<<"$slugs"

    # Defense in depth, the reverse direction: every module FILE on disk —
    # not only the ones THIS registry pass happened to reach — is checked
    # directly. A branch that removes or renames a slug from
    # agent-registry.json while the pinned image still installs that
    # module's executable would otherwise leave it completely unmanaged:
    # the forward, registry-driven loop above never even sees a slug that
    # no longer exists, so it cannot report the divergence on its own.
    local module_file m_slug m_exe
    for module_file in "${CONFIG_DIR}"/*.sh; do
        [ -f "$module_file" ] || continue
        m_slug="$(basename "$module_file" .sh)"
        case " $modules_seen " in
        *" $m_slug "*) continue ;;
        esac
        m_exe="$(module_executable "$m_slug")"
        if command -v "$m_exe" >/dev/null 2>&1; then
            echo "bot-autonomy: verify failed — '${m_slug}' executable '${m_exe}' is installed but no current agent-registry.json slug (direct or aliased) resolves to its module" >&2
            failed=1
        fi
    done

    if [ "$failed" -ne 0 ]; then
        echo "bot-autonomy: verify failed — see above" >&2
        return 1
    fi
    echo "==> bot-autonomy: verify passed."
}

# Static-only: every registry slug resolves to exactly one bucket. No
# container, no installed executables required — this is what
# scripts/test-bot-autonomy.sh (part of `task verify`) runs on every PR,
# independent of any devcontainer paths filter.
cmd_coverage() {
    [ -f "$ALIASES_FILE" ] || {
        echo "bot-autonomy: aliases table not found at ${ALIASES_FILE}" >&2
        return 1
    }
    [ -f "$UNSUPPORTED_FILE" ] || {
        echo "bot-autonomy: unsupported table not found at ${UNSUPPORTED_FILE}" >&2
        return 1
    }
    if ! jq -e '
        to_entries | all(
            (.value | has("executable")) and
            (.value.executable == null or (.value.executable | type == "string" and length > 0))
        )
    ' "$UNSUPPORTED_FILE" >/dev/null; then
        echo "bot-autonomy: coverage failed — ${UNSUPPORTED_FILE} has an entry whose executable is not a non-empty string or null" >&2
        return 1
    fi

    local slug hits detail failed=0 target entry slugs modules_reachable=""
    slugs="$(registry_slugs)" || return 1
    while IFS= read -r slug; do
        hits=0
        detail=""
        if module_slug_for "$slug" >/dev/null 2>&1; then
            hits=$((hits + 1))
            detail="module"
            modules_reachable="$modules_reachable $slug"
        fi
        if target="$(alias_target_for "$slug" 2>/dev/null)"; then
            hits=$((hits + 1))
            detail="${detail:+${detail},}alias->${target}"
            # An alias is only real coverage if its target actually resolves
            # to a module — a misspelled or removed target would otherwise
            # let both the alias AND its (non-existent) target go unverified
            # at runtime while this static check reports them covered.
            if module_slug_for "$target" >/dev/null 2>&1; then
                modules_reachable="$modules_reachable $target"
            else
                echo "bot-autonomy: coverage failed — '${slug}' aliases to '${target}', which has no module" >&2
                failed=1
            fi
        fi
        if entry="$(unsupported_entry_for "$slug" 2>/dev/null)"; then
            hits=$((hits + 1))
            detail="${detail:+${detail},}unsupported(${entry%%$'\t'*})"
        fi
        case "$hits" in
        0)
            echo "bot-autonomy: coverage failed — '${slug}' has no module, alias, or unsupported entry" >&2
            failed=1
            ;;
        1)
            echo "OK  ${slug}  ${detail}"
            ;;
        *)
            echo "bot-autonomy: coverage failed — '${slug}' is covered by more than one bucket (${detail})" >&2
            failed=1
            ;;
        esac
    done <<<"$slugs"

    # Defense in depth, the reverse direction (same reasoning as verify's own
    # check): every module FILE on disk must be reachable from the CURRENT
    # registry, not just orphaned in place. Catches a registry edit that
    # drops the last slug (or alias) pointing at a module at review time,
    # before any container ever runs verify against it.
    local module_file m_slug
    for module_file in "${CONFIG_DIR}"/*.sh; do
        [ -f "$module_file" ] || continue
        m_slug="$(basename "$module_file" .sh)"
        case " $modules_reachable " in
        *" $m_slug "*) continue ;;
        esac
        echo "bot-autonomy: coverage failed — module '${m_slug}' has no registry slug (direct or aliased) resolving to it" >&2
        failed=1
    done

    [ "$failed" -eq 0 ]
}

mode="${1:-}"
case "$mode" in
apply) cmd_apply ;;
verify) cmd_verify ;;
coverage) cmd_coverage ;;
*)
    echo "Usage: $0 <apply|verify|coverage>" >&2
    exit 2
    ;;
esac
