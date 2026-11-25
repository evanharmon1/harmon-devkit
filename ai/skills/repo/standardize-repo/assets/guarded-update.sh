#!/usr/bin/env bash
# guarded-update.sh — update mode's guarded procedure as a runnable asset.
#
# harmon-devkit#420 moves the guarded update out of fenced Markdown, one step
# per PR. This step ships `prepare` and `discover`; the rehearsal, preview,
# apply, reconcile, promotion and rollback still live in
# references/mode-update-preflight.md and references/mode-update-execution.md.
# The commands, guards, messages, state files and their order are the ones
# those references carried — moved, not redesigned.
#
# Run from the root of the repository being updated:
#
#   HARMON_INIT_REF=<release tag> assets/guarded-update.sh prepare
#   assets/guarded-update.sh discover
#   . assets/guarded-update.sh load        # bash: load into the current shell
#
# prepare   freezes the canonical source, the recorded baseline and the target
#           commit, creates the read-only offline template snapshot and the
#           guarded state directory, and prints the drift worklist. Inputs come
#           from the environment: HARMON_INIT_REF (required) and, only for a
#           legacy tag-valued _commit, ACCEPT_LEGACY_BASELINE=true — an explicit
#           maintainer recovery decision that is never defaulted.
# discover  converges the active target questions and seeds or validates the
#           reviewed answer map. It stops while any __REVIEW_REQUIRED__ value
#           stands; review the file, then rerun it. On a first run with no
#           reviewed data it starts from .copier-answers.yml, and an exported
#           USE_CODEQL / CODEQL_LANGUAGES / USE_FOREMAN / USE_CODEX_REVIEW /
#           USE_CODEX_CLOUD_REVIEW / USE_SKILLS_SYNC / USE_CODERABBIT overrides
#           the recorded answer exactly as a shell variable did in the Markdown.
# load      (sourced) defines run_guarded_copier and guarded_checkout_id and
#           restores the frozen values from the state directory (default
#           .copier-guarded-update): GUARDED_STATE, HARMON_INIT_SOURCE,
#           HARMON_INIT_COMMIT, RECORDED_COMMIT, GUARDED_TEMPLATE,
#           GUARDED_COPIER_CACHE, ORIGINAL_DATA, REVIEWED_DATA, the reviewed
#           capability answers once discover has written them, and
#           TARGET_DISCOVERY only while the latest discover run converged
#           (otherwise it leaves it unset). It is the one way the
#           Markdown steps that have not moved yet, and recovery after an
#           interruption, get those values back.
#
# Each subcommand is its own process, so it reloads what it needs from the
# guarded state directory instead of inheriting shell variables. Like the
# Markdown it replaces, it runs under errexit and nounset and deliberately not
# under pipefail (references/mode-update-basics.md, "How to run the snippets").

GUARDED_UPDATE_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

guarded_checkout_id() {
    if GUARDED_BRANCH="$(git symbolic-ref --quiet --short HEAD)"; then
        printf 'branch:%s\n' "$GUARDED_BRANCH"
    else
        printf '%s\n' detached
    fi
}

run_guarded_copier() {
    env \
        "COPIER_CACHE_DIR=$GUARDED_COPIER_CACHE" \
        GIT_CONFIG_COUNT=2 \
        "GIT_CONFIG_KEY_0=url.$GUARDED_TEMPLATE.insteadOf" \
        "GIT_CONFIG_VALUE_0=$HARMON_INIT_SOURCE.git" \
        "GIT_CONFIG_KEY_1=url.$GUARDED_TEMPLATE.insteadOf" \
        "GIT_CONFIG_VALUE_1=$HARMON_INIT_SOURCE" \
        copier "$@"
}

# Restore the values prepare froze. Every subcommand after prepare starts here.
guarded_update_load_frozen() {
    GUARDED_STATE="${1:-.copier-guarded-update}"
    HARMON_INIT_SOURCE=https://github.com/evanharmon1/harmon-init
    for GUARDED_RECORD in target-commit recorded-commit template-path cache-path; do
        test -s "$GUARDED_STATE/$GUARDED_RECORD" ||
            {
                echo "$GUARDED_STATE/$GUARDED_RECORD is missing; run prepare first or recover the guarded run" >&2
                return 1
            }
    done
    HARMON_INIT_COMMIT="$(cat "$GUARDED_STATE/target-commit")" &&
        RECORDED_COMMIT="$(cat "$GUARDED_STATE/recorded-commit")" &&
        GUARDED_TEMPLATE="$(cat "$GUARDED_STATE/template-path")" &&
        GUARDED_COPIER_CACHE="$(cat "$GUARDED_STATE/cache-path")" ||
        {
            echo "failed to read guarded update state" >&2
            return 1
        }
}

# The documented loader: frozen values, data paths, and — once discover has
# written them — the reviewed answers and the converged target render.
guarded_update_load() {
    guarded_update_load_frozen "$@" || return 1
    ORIGINAL_DATA="$GUARDED_STATE/original-data.yml"
    if test -e "$GUARDED_STATE/reviewed-data.yml"; then
        # On recovery, load the complete map instead of recomputing defaults.
        REVIEWED_DATA="$GUARDED_STATE/reviewed-data.yml"
        USE_FOREMAN="$(yq -r '.use_foreman' "$REVIEWED_DATA")"
        USE_CODEX_REVIEW="$(yq -r '.use_codex_review' "$REVIEWED_DATA")"
        USE_CODEX_CLOUD_REVIEW="$(
            yq -r '.use_codex_cloud_review // false' "$REVIEWED_DATA"
        )"
        USE_SKILLS_SYNC="$(yq -r '.use_skills_sync' "$REVIEWED_DATA")"
        SKILL_CATEGORIES="$(
            yq -o=json -I=0 '.skill_categories // []' "$REVIEWED_DATA"
        )"
        USE_CODERABBIT="$(yq -r '.use_coderabbit' "$REVIEWED_DATA")"
        USE_CODEQL="$(yq -r '.use_codeql' "$REVIEWED_DATA")"
        CODEQL_LANGUAGES="$(
            yq -o=json -I=0 '.codeql_languages' "$REVIEWED_DATA"
        )"
    fi
    if test -s "$GUARDED_STATE/target-discovery-path"; then
        TARGET_DISCOVERY="$(cat "$GUARDED_STATE/target-discovery-path")" ||
            {
                echo "failed to read the converged target render path" >&2
                return 1
            }
    else
        unset TARGET_DISCOVERY
    fi
    REVIEWED_DATA="$GUARDED_STATE/reviewed-data.yml"
}

guarded_update_prepare() {
    : "${HARMON_INIT_REF:?set to the deliberately selected latest harmon-init release tag}"
    HARMON_INIT_SOURCE=https://github.com/evanharmon1/harmon-init
    RECORDED_SOURCE="$(yq -r '._src_path // ""' .copier-answers.yml)"
    RECORDED_REF="$(yq -r '._commit // ""' .copier-answers.yml)"
    case "$RECORDED_SOURCE" in
    "$HARMON_INIT_SOURCE" | "$HARMON_INIT_SOURCE.git") ;;
    *)
        echo "_src_path must be the canonical harmon-init URL before update" >&2
        exit 1
        ;;
    esac
    git -C ~/git/harmon-init fetch "$HARMON_INIT_SOURCE" \
        '+refs/heads/main:refs/remotes/origin/main' --tags ||
        {
            echo "failed to refresh harmon-init from origin" >&2
            exit 1
        }
    test -n "$RECORDED_REF" ||
        {
            echo "_commit must name the recorded harmon-init baseline" >&2
            exit 1
        }
    if printf '%s\n' "$RECORDED_REF" | grep -Eq '^[0-9a-fA-F]{40}$'; then # shell-robustness: ok — this asset runs under errexit without pipefail, like the Markdown it replaces
        RECORDED_COMMIT="$(git -C ~/git/harmon-init rev-parse "$RECORDED_REF^{commit}")"
    else
        # Legacy Copier answers normally contain `git describe` output (usually a
        # release tag), which is not immutable evidence of the commit originally used.
        # An agent must not accept the current mapping silently.
        : "${ACCEPT_LEGACY_BASELINE:?obtain maintainer approval for the legacy baseline recovery}"
        test "$ACCEPT_LEGACY_BASELINE" = true ||
            {
                echo "ACCEPT_LEGACY_BASELINE must be exactly true" >&2
                exit 1
            }
        # This branch needs authenticated `gh` — `gh api` requires a credential even
        # for a public repository. Probe it separately so a missing/unauthenticated
        # CLI is not misreported as a tag/release problem.
        command -v gh >/dev/null 2>&1 ||
            {
                echo "legacy baseline recovery requires the gh CLI on PATH" >&2
                exit 1
            }
        gh auth status >/dev/null 2>&1 ||
            {
                echo "legacy baseline recovery requires authenticated gh; run gh auth login" >&2
                exit 1
            }
        RELEASE_ERR="$(mktemp -t harmon-init-release-err-XXXXXX)" ||
            {
                echo "failed to allocate the release probe buffer" >&2
                exit 1
            }
        if RELEASE_TARGET="$(
            gh api "repos/evanharmon1/harmon-init/releases/tags/$RECORDED_REF" \
                --jq '.target_commitish' 2>"$RELEASE_ERR"
        )"; then
            rm -f "$RELEASE_ERR"
        elif grep -q 'HTTP 404' "$RELEASE_ERR"; then
            rm -f "$RELEASE_ERR"
            echo "recorded tag has no matching GitHub release" >&2
            exit 1
        else
            echo "cannot read the GitHub release record for $RECORDED_REF:" >&2
            cat "$RELEASE_ERR" >&2
            rm -f "$RELEASE_ERR"
            exit 1
        fi
        RECORDED_COMMIT="$(git -C ~/git/harmon-init rev-parse "$RECORDED_REF^{commit}")"
        case "$RELEASE_TARGET" in
        "$RECORDED_COMMIT") ;;
        main)
            git -C ~/git/harmon-init merge-base --is-ancestor \
                "$RECORDED_COMMIT" origin/main ||
                {
                    echo "recorded tag is not on the release target branch" >&2
                    exit 1
                }
            ;;
        *)
            echo "GitHub release target must be the recorded commit or main" >&2
            exit 1
            ;;
        esac
    fi
    git -C ~/git/harmon-init merge-base --is-ancestor "$RECORDED_COMMIT" origin/main ||
        {
            echo "recorded _commit must resolve to a commit on origin/main" >&2
            exit 1
        }
    V3_TAG_OBJECT="$(
        git -C ~/git/harmon-init ls-remote --exit-code "$HARMON_INIT_SOURCE" \
            "refs/tags/v3.0.0" |
            awk 'NR == 1 { print $1 }'
    )" ||
        {
            echo "cannot verify the v3 migration boundary on origin" >&2
            exit 1
        }
    test -n "$V3_TAG_OBJECT" &&
        test "$(git -C ~/git/harmon-init rev-parse refs/tags/v3.0.0)" = \
            "$V3_TAG_OBJECT" ||
        {
            echo "local v3.0.0 tag does not match origin" >&2
            exit 1
        }
    V3_BASELINE_COMMIT="$(git -C ~/git/harmon-init rev-parse "v3.0.0^{commit}")"
    git -C ~/git/harmon-init merge-base --is-ancestor \
        "$V3_BASELINE_COMMIT" "$RECORDED_COMMIT" ||
        {
            echo "recorded baseline predates v3; use mode-adopt-existing.md" >&2
            exit 1
        }
    REMOTE_TAG_OBJECT="$(
        git -C ~/git/harmon-init ls-remote --exit-code "$HARMON_INIT_SOURCE" \
            "refs/tags/$HARMON_INIT_REF" |
            awk 'NR == 1 { print $1 }'
    )" ||
        {
            echo "HARMON_INIT_REF is not a tag published by origin" >&2
            exit 1
        }
    test -n "$REMOTE_TAG_OBJECT" &&
        test "$(git -C ~/git/harmon-init rev-parse "refs/tags/$HARMON_INIT_REF")" = "$REMOTE_TAG_OBJECT" &&
        git -C ~/git/harmon-init merge-base --is-ancestor "$HARMON_INIT_REF^{commit}" origin/main ||
        {
            echo "HARMON_INIT_REF must exactly match a release tag on origin/main" >&2
            exit 1
        }
    HARMON_INIT_COMMIT="$(git -C ~/git/harmon-init rev-parse "$HARMON_INIT_REF^{commit}")"
    # Check the skills pin against the verified target before any Copier run.
    # A missing manifest is normal for first adoption or when skills sync is off.
    if PIN_CHECK="$("$GUARDED_UPDATE_SKILL_DIR"/assets/check-pin-minimum.sh \
        ~/git/harmon-init "$HARMON_INIT_COMMIT" .skills-sync.yaml)"; then
        PIN_STATUS=0
    else
        PIN_STATUS=$?
    fi
    case "$PIN_STATUS" in
    0) echo "$PIN_CHECK" ;;
    1)
        echo "$PIN_CHECK" >&2
        echo "Set source.ref to the reported minimum, run task sync:skills in the same PR, and rerun this check before Copier." >&2
        exit 1
        ;;
    2)
        PIN_REASON="${PIN_CHECK#*\"reason\":\"}"
        if [ "$PIN_REASON" = "$PIN_CHECK" ]; then PIN_REASON=unspecified; else
            PIN_REASON="${PIN_REASON%%\"*}"
            PIN_REASON="${PIN_REASON:-unspecified}"
        fi
        echo "skills pin compatibility unknown: $PIN_REASON"
        ;;
    *)
        echo "Skills pin minimum check failed (exit $PIN_STATUS); stop before Copier." >&2
        exit 1
        ;;
    esac
    git -C ~/git/harmon-init merge-base --is-ancestor \
        "$RECORDED_COMMIT" "$HARMON_INIT_COMMIT" ||
        {
            echo "target release must descend from the recorded baseline" >&2
            exit 1
        }
    git -C ~/git/harmon-init show "$HARMON_INIT_COMMIT":copier.yml |
        grep -q '^use_coderabbit:' || # shell-robustness: ok — this asset runs under errexit without pipefail, like the Markdown it replaces
        {
            echo "latest harmon-init release does not support the CodeRabbit choice" >&2
            exit 1
        }
    git -C ~/git/harmon-init show "$HARMON_INIT_COMMIT":copier.yml |
        grep -q '^use_codex_cloud_review:' || # shell-robustness: ok — this asset runs under errexit without pipefail, like the Markdown it replaces
        {
            echo "latest harmon-init release does not support the Codex cloud review choice" >&2
            exit 1
        }
    git -C ~/git/harmon-init diff \
        "$RECORDED_COMMIT".."$HARMON_INIT_COMMIT" -- copier.yml
    GUARDED_TEMPLATE="$(mktemp -d -t harmon-init-guarded-XXXXXX)"
    GUARDED_COPIER_CACHE="$(mktemp -d -t copier-guarded-cache-XXXXXX)"
    git clone --no-checkout "$HARMON_INIT_SOURCE" "$GUARDED_TEMPLATE" ||
        {
            echo "failed to snapshot harmon-init from the canonical remote" >&2
            exit 1
        }
    git -C "$GUARDED_TEMPLATE" remote remove origin
    test "$(git -C "$GUARDED_TEMPLATE" rev-parse "$RECORDED_COMMIT^{commit}")" = \
        "$RECORDED_COMMIT" &&
        test "$(git -C "$GUARDED_TEMPLATE" rev-parse "$HARMON_INIT_COMMIT^{commit}")" = \
            "$HARMON_INIT_COMMIT" ||
        {
            echo "guarded template does not contain the validated commits" >&2
            exit 1
        }
    test "$(git -C "$GUARDED_TEMPLATE" rev-parse "$HARMON_INIT_REF^{commit}")" = \
        "$HARMON_INIT_COMMIT" ||
        {
            echo "guarded target tag mapping changed during snapshot creation" >&2
            exit 1
        }
    if ! printf '%s\n' "$RECORDED_REF" | grep -Eq '^[0-9a-fA-F]{40}$'; then # shell-robustness: ok — this asset runs under errexit without pipefail, like the Markdown it replaces
        test "$(git -C "$GUARDED_TEMPLATE" rev-parse "$RECORDED_REF^{commit}")" = \
            "$RECORDED_COMMIT" ||
            {
                echo "guarded baseline tag mapping changed during snapshot creation" >&2
                exit 1
            }
    fi
    for GUARDED_COMMIT in "$RECORDED_COMMIT" "$HARMON_INIT_COMMIT"; do
        if git -C "$GUARDED_TEMPLATE" cat-file -e \
            "$GUARDED_COMMIT:.gitmodules" 2>/dev/null; then
            echo "guarded updates do not support template commits with submodules" >&2
            exit 1
        fi
    done
    chmod -R a-w "$GUARDED_TEMPLATE"
    GUARDED_STATE=.copier-guarded-update
    GIT_EXCLUDE="$(git rev-parse --path-format=absolute --git-path info/exclude)"
    grep -qxF "/$GUARDED_STATE/" "$GIT_EXCLUDE" ||
        printf '%s\n' "/$GUARDED_STATE/" >>"$GIT_EXCLUDE" ||
        {
            echo "failed to ignore guarded update state" >&2
            exit 1
        }
    mkdir "$GUARDED_STATE" ||
        {
            echo "$GUARDED_STATE already exists; recover or remove it before retrying" >&2
            exit 1
        }
    git rev-parse HEAD >"$GUARDED_STATE/start-head" &&
        guarded_checkout_id >"$GUARDED_STATE/start-checkout" &&
        git hash-object .copier-answers.yml >"$GUARDED_STATE/canonical-answers-oid" &&
        printf '%s\n' "$HARMON_INIT_COMMIT" >"$GUARDED_STATE/target-commit" &&
        printf '%s\n' "$RECORDED_COMMIT" >"$GUARDED_STATE/recorded-commit" &&
        printf '%s\n' "$GUARDED_TEMPLATE" >"$GUARDED_STATE/template-path" &&
        printf '%s\n' "$GUARDED_COPIER_CACHE" >"$GUARDED_STATE/cache-path" &&
        cp .copier-answers.yml "$GUARDED_STATE/original-answers.yml" ||
        {
            echo "failed to initialize guarded update state" >&2
            exit 1
        }
    git -C "$GUARDED_TEMPLATE" show "$RECORDED_COMMIT":copier.yml |
        yq -r 'keys | .[] | select(test("^_") | not)' |
        LC_ALL=C sort -u >"$GUARDED_STATE/baseline-questions" &&
        git -C "$GUARDED_TEMPLATE" show "$HARMON_INIT_COMMIT":copier.yml |
        yq -r 'keys | .[] | select(test("^_") | not)' |
            LC_ALL=C sort -u >"$GUARDED_STATE/target-questions" &&
        LC_ALL=C comm -13 \
            "$GUARDED_STATE/baseline-questions" \
            "$GUARDED_STATE/target-questions" \
            >"$GUARDED_STATE/new-question-candidates" ||
        {
            echo "failed to derive new question candidates" >&2
            exit 1
        }
    test -z "$(git status --porcelain)" ||
        {
            echo "guarded preparation must leave the worktree clean" >&2
            exit 1
        }
    HARMON_INIT="$GUARDED_TEMPLATE" \
        HARMON_INIT_RECORDED_COMMIT="$RECORDED_COMMIT" \
        "$GUARDED_UPDATE_SKILL_DIR"/assets/diff-template.sh .
    # add --show to print the full per-file diff
    run_guarded_copier check-update --output-format json .
}

guarded_update_discover() {
    guarded_update_load_frozen || exit 1
    # The render path is recorded only when this run converges; a run that stops
    # must not leave an earlier run's render for load to restore.
    rm -f "$GUARDED_STATE/target-discovery-path" ||
        {
            echo "failed to clear the previous converged target render" >&2
            exit 1
        }
    REVIEWED_DATA="$GUARDED_STATE/reviewed-data.yml"
    ORIGINAL_DATA="$GUARDED_STATE/original-data.yml"
    yq 'with_entries(select(.key | test("^_") | not))' \
        "$GUARDED_STATE/original-answers.yml" >"$ORIGINAL_DATA" ||
        {
            echo "failed to prepare recorded answers for discovery" >&2
            exit 1
        }
    # >>> classifier-detector >>>
    # use_codex_cloud_review's use_skills_sync / universal-category requirements are
    # a proxy for "the cloud-review classifier is installed": in a consumer repo the
    # integrate skill and its check-codex-cloud-review.sh reach the repo only via
    # skills sync of the universal category. A skills-source repo hosts that
    # classifier natively in its own tree, so it satisfies the intent directly and
    # is exempt (matching Copier's validator, which gates the option on
    # use_codex_review alone). The guards below waive both requirements only when
    # the classifier helper ($SKILLS_SOURCE_CLASSIFIER, check-codex-cloud-review.sh)
    # is a real, repo-shipped executable — proven from Git's
    # index, not the filesystem. The authoritative test is the tracked mode being
    # `100755`: `git ls-files --stage` reports it, and a `100755` blob is by
    # definition tracked, a regular file, non-symlink, and executable for every
    # fresh clone. A filesystem `[ -x ]` is the wrong test — under
    # `core.fileMode=false` or a mount that reports everything executable it passes
    # for a `100644` blob a Linux clone checks out non-runnable. Require the working
    # tree to also hold that regular file (`-f`), so a staged-but-deleted path does
    # not qualify. The requirements stay in force for every other repo.
    #
    # That tracked mode is necessary but nowhere near sufficient on its own: a
    # one-line stub committed `100755` at the right path would pass it and prove
    # nothing about the skill being usable. So "ships the classifier natively"
    # additionally requires the integrate skill's entry point and the helper's own
    # structure, and it requires them from CODE rather than from prose.
    #
    # Anchoring on the usage strings (`reserve --state`, …) was the obvious version
    # of that and is not enough: a no-op helper whose comments merely PRINT those
    # five forms satisfies every one of them, and a waived config with such a stub
    # is worse than no waiver — the integrator's `check` would read its exit 0 as clean
    # evidence and the composition fails OPEN. So the verb probes anchor on the
    # dispatch `case` arms in the helper's executable body, and are joined by two
    # pairs from the exit-code contract the integrator actually depends on: `emit pending`
    # with `exit 11`, and `emit escalate` with `exit 13`. Those two verdicts are the
    # bounded-attempt lifecycle — a helper that cannot say "still waiting" or "both
    # windows elapsed" cannot drive the stage no matter what its banner claims —
    # and 11/13 are unusual enough that nothing satisfies them incidentally.
    # `classifier_code_has` strips leading whitespace and drops every `#` line
    # first, so no comment can answer a probe.
    #
    # The `SKILL.md` probe likewise checks the frontmatter rather than the path: a
    # helper with no valid skill around it is a stripped tree, not a shipped skill.
    # It splits in two, because the two halves have genuinely different natures.
    #
    # STRUCTURE is checked statically: the file must open with `---` and the block
    # must CLOSE with a second one. These stay hand-rolled because yq does NOT fail
    # closed on either — verified against yq v4, not assumed. Under
    # `--front-matter=extract`, a file with no frontmatter at all, and an unclosed
    # block whose body happens to be valid YAML, both parse happily and resolve
    # `.name`, so a bare `name: integrate` sitting in a file's BODY would satisfy
    # the value probe. The two checks mirror `verify-skills.sh`'s `head -n 1` test
    # and its `frontmatter_is_closed`, which remains canonical for layout.
    #
    # VALUES are resolved by yq rather than re-implemented. This section already
    # hard-requires yq v4 for the guarded update, so the detector may assume it.
    # The hand-rolled grammar this replaces had to learn YAML one finding at a
    # time — quoted scalars, block-scalar headers, chomping and indentation
    # indicators in either order, the null spellings, and comments composing with
    # every one of them — and each round closed an instance while the next spelling
    # waited. A parser already knows the whole grammar, so that family of findings
    # ends here rather than being enumerated further.
    # `tag == "!!str"` is the load-bearing part: it is what makes `null`, `~`, `[]`,
    # `{ }`, numbers, and booleans fail, which is precisely the "reads like a value,
    # is not one" set the hand-written reject list was chasing.
    #
    # A yq failure — malformed YAML, or an invalid header like `|0` — answers false,
    # so no waiver. That is the safe direction, and unlike the ignore probes it is
    # deliberately NOT an exit-2 "cannot tell" condition: a SKILL.md that does not
    # parse is a definite answer, namely that this is not a valid skills source.
    # Every probe sits in the `if` condition, where a non-zero exit selects the
    # else-branch instead of tripping errexit — these are questions about the repo,
    # not failures.
    #
    # What this still CANNOT prove, plainly: runtime behavior. A read-only stage
    # must not render or execute the repo under update, so every probe above is
    # static, and a tree that passes could still hold a helper that is broken when
    # run — or one deliberately forged to match these anchors, since any static
    # shape can be reproduced by something that does nothing. Issue 336 accepts
    # that residual explicitly. What the probes buy is the accidental case they
    # were written for: a stub, a stripped tree, or a half-vendored copy no longer
    # waives three guards by looking right from a distance.
    # The asset probe set is check-codex-cloud-review.sh (the classifier's static
    # interface) and require-marker.sh (its marker dependency). Together with the
    # entry-point checks below, they identify the native source; they do not verify
    # a complete vendor or the behavior of any asset. The classifier itself sources
    # asset-freshness.sh and trusted-registry.sh; a vendor missing either cannot run
    # it, even though this probe still identifies the source. Other prescribed assets are
    # deliberately excluded because their presence is not needed for this identity
    # test. Review this list whenever the procedures prescribe a new asset:
    # BEGIN unprobed procedure assets
    # dev-flow-support/assets/dev-flow-exit.mjs — stage exit calculation
    # dev-flow-support/assets/dev-flow-exit.sh — stage exit wrapper
    # dev-flow-support/assets/devflow-policy.mjs — policy resolution
    # dev-flow-support/assets/lib/merge-base-policy.sh — merge-base policy loading
    # dev-flow-support/assets/lib/toml-lite.mjs — policy parsing
    # dev-flow-support/assets/render-dev-flow.mjs — run record rendering
    # dev-flow-support/assets/render-dev-flow.sh — rendering wrapper
    # dev-flow-support/assets/run-record.mjs — run record management
    # dev-flow-support/assets/stage-labels.mjs — stage and activity label projection
    # dev-flow-support/assets/schemas/run.schema.json — run record schema
    # dev-flow-support/assets/settle-wait.sh — settlement polling
    # dev-flow-support/assets/validate-result-schemas.mjs — result validation
    # implement/assets/record-implementer.sh — implementer record management
    # integrate/assets/drive-codex-cycle.sh — owner-only cycle orchestration writes
    # integrate/assets/drive-handoff.sh — owner-only handoff writes after an integrator result
    # integrate/assets/gh-ro.sh — GitHub read operations
    # integrate/assets/gh-write-broker.sh — GitHub write operations
    # integrate/assets/promote.sh — promotion procedure
    # integrate/assets/readiness-gate.sh — handoff evaluation
    # integrate/assets/trusted-registry.sh — registry validation
    # integrate/assets/update-branch.sh — branch catch-up
    # orchestrate/assets/consumer-pin-audit.sh — consumer pin audit
    # orchestrate/assets/settle-wait.sh — orchestrator settlement polling
    # track-work/assets/clear-needs-review.sh — issue label cleanup
    # track-work/assets/file-review-finding.sh — finding tracking
    # track-work/assets/lifecycle-labels.sh — lifecycle label transitions
    # END unprobed procedure assets
    SKILLS_SOURCE_CLASSIFIER="ai/skills/universal/integrate/assets/check-codex-cloud-review.sh"
    SKILLS_SOURCE_MARKER="ai/skills/universal/integrate/assets/require-marker.sh"
    SKILLS_SOURCE_INTEGRATE_SKILL="ai/skills/universal/integrate/SKILL.md"
    # Match a POSIX ERE against the helper's code only: leading whitespace stripped,
    # every comment line dropped. Called only after the `-f` test on
    # $SKILLS_SOURCE_CLASSIFIER in the `if` condition below passes.
    #
    # It is one awk pass over the file, deliberately NOT a pipeline. The obvious
    # `sed | grep -v | grep -qE` form is broken under `pipefail`: `grep -q` exits at
    # the first match, the upstream stages die of SIGPIPE (141), and the whole
    # pipeline then reports failure — so on a real classifier, where every anchor
    # matches early, every probe "fails" and the waiver is denied to exactly the
    # repo it exists for. This asset runs without `pipefail` (see its header), but
    # this probe is safe under it anyway because there is no pipe. awk owns the input,
    # so the early `exit` costs nothing and still runs END.
    # The pattern arrives through the environment rather than `-v`, which would
    # escape-process it and mangle the `\)` in the case-arm anchors.
    classifier_code_has() {
        CLASSIFIER_PROBE="$1" awk '
    BEGIN { pat = ENVIRON["CLASSIFIER_PROBE"] }
    { line = $0; sub(/^[[:space:]]*/, "", line) }
    line ~ /^#/ { next }
    line ~ pat { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$SKILLS_SOURCE_CLASSIFIER"
    }
    # The entry point must be a REGULAR file, proven from the index the same way
    # the classifier path is: `git ls-files --stage` reports the tracked mode, and
    # only `100644`/`100755` are regular blobs. A `120000` is a symlink, which
    # `verify-skills.sh` also refuses by finding skills with `-type f` — a symlinked
    # SKILL.md resolves fine in this checkout and can dangle in a fresh clone, or
    # point outside the skill tree entirely. Checked before the frontmatter awk,
    # which would happily read straight through the link.
    classifier_skill_is_regular_file() {
        case "$(git ls-files --stage -- "$SKILLS_SOURCE_INTEGRATE_SKILL" 2>/dev/null | cut -c1-6)" in
        100644 | 100755) return 0 ;;
        esac
        return 1
    }
    classifier_skill_frontmatter_ok() {
        awk '
    NR == 1 && $0 != "---" { exit }
    $0 == "---" { fence++ }
    END { exit (fence >= 2) ? 0 : 1 }
  ' "$SKILLS_SOURCE_INTEGRATE_SKILL" &&
            yq --front-matter=extract -e '
      ((.name | tag) == "!!str") and (.name == "integrate") and
      ((.description | tag) == "!!str") and (.description != "")
    ' "$SKILLS_SOURCE_INTEGRATE_SKILL" >/dev/null 2>&1
    }
    if [ -f "$SKILLS_SOURCE_MARKER" ] &&
        [ "$(git ls-files --stage -- "$SKILLS_SOURCE_MARKER" 2>/dev/null | cut -c1-6)" = "100755" ] &&
        [ -f "$SKILLS_SOURCE_CLASSIFIER" ] &&
        [ "$(git ls-files --stage -- "$SKILLS_SOURCE_CLASSIFIER" 2>/dev/null | cut -c1-6)" = "100755" ] &&
        git ls-files --error-unmatch -- "$SKILLS_SOURCE_INTEGRATE_SKILL" >/dev/null 2>&1 &&
        classifier_skill_is_regular_file &&
        classifier_skill_frontmatter_ok &&
        classifier_code_has '^reserve\)' &&
        classifier_code_has '^attach\)' &&
        classifier_code_has '^check\)' &&
        classifier_code_has '^show\)' &&
        classifier_code_has '^reap\)' &&
        classifier_code_has '^emit pending ' &&
        classifier_code_has '^exit 11$' &&
        classifier_code_has '^emit escalate ' &&
        classifier_code_has '^exit 13$'; then
        SHIPS_CLASSIFIER_NATIVELY=true
    else
        SHIPS_CLASSIFIER_NATIVELY=false
    fi
    # <<< classifier-detector <<<
    # >>> guarded-render-variables >>>
    if test -e "$REVIEWED_DATA"; then
        yq -e \
            'tag == "!!map" and
     ([.[] | select(. == "__REVIEW_REQUIRED__")] | length == 0)' \
            "$REVIEWED_DATA" >/dev/null ||
            {
                echo "review every existing entry and replace all __REVIEW_REQUIRED__ values" >&2
                exit 1
            }
        USE_FOREMAN="$(yq -r '.use_foreman' "$REVIEWED_DATA")"
        USE_CODEX_REVIEW="$(yq -r '.use_codex_review' "$REVIEWED_DATA")"
        USE_CODEX_CLOUD_REVIEW="$(
            yq -r '.use_codex_cloud_review // false' "$REVIEWED_DATA"
        )"
        USE_SKILLS_SYNC="$(yq -r '.use_skills_sync' "$REVIEWED_DATA")"
        USE_CODERABBIT="$(yq -r '.use_coderabbit' "$REVIEWED_DATA")"
        USE_CODEQL="$(yq -r '.use_codeql' "$REVIEWED_DATA")"
        CODEQL_LANGUAGES="$(yq -o=json -I=0 '.codeql_languages' "$REVIEWED_DATA")"
    else
        if [ "${USE_CODEQL+x}" != x ]; then
            yq -e 'has("use_codeql") and (.use_codeql | tag == "!!bool")' \
                .copier-answers.yml >/dev/null ||
                {
                    echo "use_codeql must be a boolean in .copier-answers.yml" >&2
                    exit 1
                }
            USE_CODEQL="$(yq -r '.use_codeql' .copier-answers.yml)"
        fi
        : "${CODEQL_LANGUAGES:=$(yq -o=json -I=0 '.codeql_languages // []' .copier-answers.yml)}"
        : "${USE_FOREMAN:=$(yq -r '.use_foreman // false' .copier-answers.yml)}"
        : "${USE_CODEX_REVIEW:=$(yq -r '.use_codex_review // false' .copier-answers.yml)}"
        : "${USE_CODEX_CLOUD_REVIEW:=$(yq -r '.use_codex_cloud_review // false' .copier-answers.yml)}"
        : "${USE_SKILLS_SYNC:=$(yq -r '.use_skills_sync // false' .copier-answers.yml)}"
        : "${USE_CODERABBIT:=$(yq -r '.use_coderabbit // false' .copier-answers.yml)}"
    fi
    case "$USE_FOREMAN" in true | false) ;; *)
        echo "USE_FOREMAN must be true or false" >&2
        exit 1
        ;;
    esac
    case "$USE_CODEX_REVIEW" in true | false) ;; *)
        echo "USE_CODEX_REVIEW must be true or false" >&2
        exit 1
        ;;
    esac
    case "$USE_CODEX_CLOUD_REVIEW" in true | false) ;; *)
        echo "USE_CODEX_CLOUD_REVIEW must be true or false" >&2
        exit 1
        ;;
    esac
    case "$USE_SKILLS_SYNC" in true | false) ;; *)
        echo "USE_SKILLS_SYNC must be true or false" >&2
        exit 1
        ;;
    esac
    [ "$USE_CODEX_CLOUD_REVIEW" != "true" ] || [ "$USE_CODEX_REVIEW" = "true" ] ||
        {
            echo "use_codex_cloud_review requires use_codex_review" >&2
            exit 1
        }
    [ "$USE_CODEX_CLOUD_REVIEW" != "true" ] || [ "$USE_SKILLS_SYNC" = "true" ] ||
        [ "$SHIPS_CLASSIFIER_NATIVELY" = "true" ] ||
        {
            echo "use_codex_cloud_review requires use_skills_sync (waived when this repo ships the classifier natively at $SKILLS_SOURCE_CLASSIFIER)" >&2
            exit 1
        }
    case "$USE_CODERABBIT" in true | false) ;; *)
        echo "USE_CODERABBIT must be true or false" >&2
        exit 1
        ;;
    esac
    if [ "$USE_CODEQL" = "false" ]; then
        CODEQL_LANGUAGES='[]'
    elif [ "$USE_CODEQL" != "true" ] ||
        ! printf '%s\n' "$CODEQL_LANGUAGES" |
        yq -e '(tag == "!!seq") and (length > 0) and
      ([.[] | select(. != "javascript-typescript" and . != "python")] | length == 0)' - >/dev/null; then
        echo "CODEQL_LANGUAGES must be a nonempty YAML list of supported first-party languages" >&2
        exit 1
    fi
    CODEQL_LANGUAGES="$(
        printf '%s\n' "$CODEQL_LANGUAGES" | yq -o=json -I=0 '.'
    )"
    # <<< guarded-render-variables <<<
    # >>> active-question-discovery >>>
    DISCOVERY_DATA="$GUARDED_STATE/discovery-data.yml"
    DISCOVERY_LOG="$GUARDED_STATE/discovery-copier.log"
    DISCOVERY_ADMITTED_LOG="$GUARDED_STATE/discovery-copier-admitted.log"
    : >"$GUARDED_STATE/active-target-questions"
    if test -e "$REVIEWED_DATA"; then
        yq -r 'keys | .[]' "$REVIEWED_DATA" |
            LC_ALL=C sort -u >"$GUARDED_STATE/reviewed-data-keys" ||
            {
                echo "failed to list reviewed data keys" >&2
                exit 1
            }
    else
        : >"$GUARDED_STATE/reviewed-data-keys"
    fi
    DISCOVERY_STABLE=false
    for DISCOVERY_ROUND in 1 2 3 4 5 6 7 8 9 10; do
        # Admit every reviewed key the prior pass did not mark active, so a question
        # gated on a newly active answer renders with its reviewed value. A render is
        # accepted only when every admitted key is active in it.
        LC_ALL=C comm -23 \
            "$GUARDED_STATE/reviewed-data-keys" \
            "$GUARDED_STATE/active-target-questions" \
            >"$GUARDED_STATE/discovery-admitted-keys" ||
            {
                echo "failed to derive admitted reviewed keys" >&2
                exit 1
            }
        rm -f "$DISCOVERY_ADMITTED_LOG"
        while :; do
            LC_ALL=C sort -u \
                "$GUARDED_STATE/active-target-questions" \
                "$GUARDED_STATE/discovery-admitted-keys" \
                >"$GUARDED_STATE/discovery-seed-keys" ||
                {
                    echo "failed to derive discovery seed keys" >&2
                    exit 1
                }
            ACTIVE_REVIEWED="$GUARDED_STATE/active-reviewed-data.yml"
            printf '%s\n' '{}' >"$ACTIVE_REVIEWED" ||
                {
                    echo "failed to initialize active reviewed data" >&2
                    exit 1
                }
            if test -e "$REVIEWED_DATA"; then
                while IFS= read -r ACTIVE_KEY; do
                    if ACTIVE_KEY="$ACTIVE_KEY" \
                        yq -e 'has(strenv(ACTIVE_KEY))' "$REVIEWED_DATA" >/dev/null; then
                        ACTIVE_VALUE="$(
                            ACTIVE_KEY="$ACTIVE_KEY" \
                                yq -o=json -I=0 '.[strenv(ACTIVE_KEY)]' "$REVIEWED_DATA"
                        )" &&
                            ACTIVE_KEY="$ACTIVE_KEY" ACTIVE_VALUE="$ACTIVE_VALUE" \
                                yq -i \
                                '.[strenv(ACTIVE_KEY)] = (strenv(ACTIVE_VALUE) | from_json)' \
                                "$ACTIVE_REVIEWED" ||
                            {
                                echo "failed to select active reviewed value" >&2
                                exit 1
                            }
                    fi
                done <"$GUARDED_STATE/discovery-seed-keys"
            fi
            DISCOVERY_CANDIDATE="$(mktemp "$GUARDED_STATE/discovery-data.XXXXXX")" ||
                {
                    echo "failed to create discovery-data candidate" >&2
                    exit 1
                }
            yq eval-all \
                'select(fileIndex == 0) * select(fileIndex == 1)' \
                "$ORIGINAL_DATA" "$ACTIVE_REVIEWED" >"$DISCOVERY_CANDIDATE" ||
                {
                    rm -f "$DISCOVERY_CANDIDATE"
                    echo "failed to merge discovery answers" >&2
                    exit 1
                }
            mv "$DISCOVERY_CANDIDATE" "$DISCOVERY_DATA" ||
                {
                    rm -f "$DISCOVERY_CANDIDATE"
                    echo "failed to publish discovery answers" >&2
                    exit 1
                }
            TARGET_DISCOVERY="$(mktemp -d -t copier-target-discovery-XXXXXX)" ||
                {
                    echo "failed to create target discovery directory" >&2
                    exit 1
                }
            if ! run_guarded_copier copy --trust --defaults --skip-tasks \
                --vcs-ref="$HARMON_INIT_COMMIT" \
                --data-file="$DISCOVERY_DATA" \
                "$HARMON_INIT_SOURCE" "$TARGET_DISCOVERY" >"$DISCOVERY_LOG" 2>&1; then
                rm -rf "$TARGET_DISCOVERY"
                if test -s "$GUARDED_STATE/discovery-admitted-keys"; then
                    # Keep this render's diagnostic: it names the question the reviewed
                    # data really lacks. Then retry with only the prior pass's active keys.
                    mv "$DISCOVERY_LOG" "$DISCOVERY_ADMITTED_LOG" ||
                        {
                            echo "failed to keep the admitted discovery diagnostic" >&2
                            exit 1
                        }
                    : >"$GUARDED_STATE/discovery-admitted-keys"
                    continue
                fi
                if test -e "$DISCOVERY_ADMITTED_LOG"; then
                    echo "Copier rejected this round's answers with reviewed keys admitted (output: $DISCOVERY_ADMITTED_LOG):" >&2
                    grep -F 'Validation error for question' "$DISCOVERY_ADMITTED_LOG" >&2 ||
                        tail -n 20 "$DISCOVERY_ADMITTED_LOG" >&2
                    echo "and with only the prior round's active keys:" >&2
                fi
                grep -F 'Validation error for question' "$DISCOVERY_LOG" >&2 ||
                    tail -n 20 "$DISCOVERY_LOG" >&2
                echo "target question discovery failed in round $DISCOVERY_ROUND (Copier output: $DISCOVERY_LOG)" >&2
                echo "if a reviewed answer activates a question whose validator rejects its default, add an approved value for that question to $REVIEWED_DATA, remove keys for questions that are no longer active, then rerun discovery" >&2
                exit 1
            fi
            yq -r 'keys | .[] | select(test("^_") | not)' \
                "$TARGET_DISCOVERY/.copier-answers.yml" |
                LC_ALL=C sort -u >"$GUARDED_STATE/active-target-questions.next" ||
                {
                    echo "failed to derive active target questions" >&2
                    exit 1
                }
            LC_ALL=C comm -12 \
                "$GUARDED_STATE/discovery-admitted-keys" \
                "$GUARDED_STATE/active-target-questions.next" \
                >"$GUARDED_STATE/discovery-admitted-active" ||
                {
                    echo "failed to check admitted reviewed keys" >&2
                    exit 1
                }
            if cmp -s \
                "$GUARDED_STATE/discovery-admitted-keys" \
                "$GUARDED_STATE/discovery-admitted-active"; then
                break
            fi
            # An admitted key is inactive here: drop it and render again, so no
            # inactive question's value is passed into an accepted render.
            rm -rf "$TARGET_DISCOVERY"
            mv \
                "$GUARDED_STATE/discovery-admitted-active" \
                "$GUARDED_STATE/discovery-admitted-keys" ||
                {
                    echo "failed to narrow admitted reviewed keys" >&2
                    exit 1
                }
        done
        if cmp -s \
            "$GUARDED_STATE/active-target-questions" \
            "$GUARDED_STATE/active-target-questions.next"; then
            rm -f "$GUARDED_STATE/active-target-questions.next"
            DISCOVERY_STABLE=true
            break
        fi
        mv \
            "$GUARDED_STATE/active-target-questions.next" \
            "$GUARDED_STATE/active-target-questions" ||
            {
                echo "failed to advance active question discovery" >&2
                exit 1
            }
    done
    test "$DISCOVERY_STABLE" = true ||
        {
            echo "active question discovery did not converge in 10 rounds" >&2
            exit 1
        }
    # <<< active-question-discovery <<<
    LC_ALL=C comm -12 \
        "$GUARDED_STATE/new-question-candidates" \
        "$GUARDED_STATE/active-target-questions" \
        >"$GUARDED_STATE/active-new-questions" ||
        {
            echo "failed to derive active new questions" >&2
            exit 1
        }
    {
        cat "$GUARDED_STATE/active-new-questions"
        printf '%s\n' \
            use_foreman use_codex_review use_codex_cloud_review use_skills_sync \
            use_coderabbit use_codeql codeql_languages
        if [ "$USE_CODEX_CLOUD_REVIEW" = "true" ]; then
            printf '%s\n' skill_categories
        fi
    } |
        LC_ALL=C sort -u |
        LC_ALL=C comm -12 - "$GUARDED_STATE/active-target-questions" \
            >"$GUARDED_STATE/reviewed-keys" ||
        {
            echo "failed to derive the complete active review set" >&2
            exit 1
        }
    for CAPABILITY_KEY in \
        use_foreman use_codex_review use_skills_sync use_coderabbit use_codeql codeql_languages; do
        grep -qxF "$CAPABILITY_KEY" "$GUARDED_STATE/reviewed-keys" ||
            {
                echo "required capability question is not active: $CAPABILITY_KEY" >&2
                exit 1
            }
    done
    # skill_categories is a conditional question activated by use_skills_sync, so a
    # skills-source repo running with use_skills_sync=false (native classifier) has
    # it inactive by design. Require it active only when the sync/universal path is
    # what installs the classifier — the same carve-out the later guards apply.
    if [ "$USE_CODEX_CLOUD_REVIEW" = "true" ] && [ "$SHIPS_CLASSIFIER_NATIVELY" != "true" ]; then
        grep -qxF skill_categories "$GUARDED_STATE/reviewed-keys" ||
            {
                echo "required skill_categories question is not active" >&2
                exit 1
            }
    fi
    find "$TARGET_DISCOVERY" \( -type f -o -type l \) -print |
        sed "s#^$TARGET_DISCOVERY/##" |
        LC_ALL=C sort -u >"$GUARDED_STATE/target-managed-paths" ||
        {
            echo "failed to inventory target render paths" >&2
            exit 1
        }
    if test -e "$REVIEWED_DATA"; then
        REVIEWED_KEYSET_OID="$(
            yq -r 'keys | .[]' "$REVIEWED_DATA" |
                LC_ALL=C sort -u |
                git hash-object --stdin
        )" ||
            {
                echo "failed to hash the reviewed keyset" >&2
                exit 1
            }
    else
        REVIEWED_KEYSET_OID=""
    fi
    REQUIRED_KEYSET_OID="$(
        git hash-object "$GUARDED_STATE/reviewed-keys"
    )"
    if ! test -e "$REVIEWED_DATA" ||
        test "$REVIEWED_KEYSET_OID" != "$REQUIRED_KEYSET_OID"; then
        REVIEWED_CANDIDATE="$(mktemp "$GUARDED_STATE/reviewed-data.XXXXXX")" ||
            {
                echo "failed to create reviewed-data candidate" >&2
                exit 1
            }
        printf '%s\n' '{}' >"$REVIEWED_CANDIDATE" ||
            {
                rm -f "$REVIEWED_CANDIDATE"
                echo "failed to initialize reviewed-data candidate" >&2
                exit 1
            }
        while IFS= read -r REVIEWED_KEY; do
            if ! REVIEWED_KEY="$REVIEWED_KEY" yq -i \
                '.[strenv(REVIEWED_KEY)] = "__REVIEW_REQUIRED__"' \
                "$REVIEWED_CANDIDATE"; then
                rm -f "$REVIEWED_CANDIDATE"
                echo "failed to seed reviewed question: $REVIEWED_KEY" >&2
                exit 1
            fi
        done <"$GUARDED_STATE/reviewed-keys"
        if ! USE_FOREMAN="$USE_FOREMAN" \
            USE_CODEX_REVIEW="$USE_CODEX_REVIEW" \
            USE_CODEX_CLOUD_REVIEW="$USE_CODEX_CLOUD_REVIEW" \
            USE_SKILLS_SYNC="$USE_SKILLS_SYNC" \
            USE_CODERABBIT="$USE_CODERABBIT" \
            USE_CODEQL="$USE_CODEQL" \
            CODEQL_LANGUAGES="$CODEQL_LANGUAGES" \
            yq -i \
            '.use_foreman = (strenv(USE_FOREMAN) == "true") |
       .use_codex_review = (strenv(USE_CODEX_REVIEW) == "true") |
       .use_skills_sync = (strenv(USE_SKILLS_SYNC) == "true") |
       .use_coderabbit = (strenv(USE_CODERABBIT) == "true") |
       .use_codeql = (strenv(USE_CODEQL) == "true") |
       .codeql_languages = (strenv(CODEQL_LANGUAGES) | from_json)' \
            "$REVIEWED_CANDIDATE"; then
            rm -f "$REVIEWED_CANDIDATE"
            echo "failed to seed reviewed capability answers" >&2
            exit 1
        fi
        if grep -qxF use_codex_cloud_review "$GUARDED_STATE/reviewed-keys" &&
            ! USE_CODEX_CLOUD_REVIEW="$USE_CODEX_CLOUD_REVIEW" \
                yq -i \
                '.use_codex_cloud_review =
          (strenv(USE_CODEX_CLOUD_REVIEW) == "true")' \
                "$REVIEWED_CANDIDATE"; then
            rm -f "$REVIEWED_CANDIDATE"
            echo "failed to seed reviewed Codex cloud answer" >&2
            exit 1
        fi
        mv "$REVIEWED_CANDIDATE" "$REVIEWED_DATA" ||
            {
                rm -f "$REVIEWED_CANDIDATE"
                echo "failed to publish reviewed data" >&2
                exit 1
            }
        echo "the active question set changed; review every key in $REVIEWED_DATA, replace all __REVIEW_REQUIRED__ values, then rerun discovery" >&2
        exit 1
    fi
    while IFS= read -r REVIEWED_KEY; do
        REVIEWED_KEY="$REVIEWED_KEY" yq -e \
            'has(strenv(REVIEWED_KEY)) and
     .[strenv(REVIEWED_KEY)] != "__REVIEW_REQUIRED__"' \
            "$REVIEWED_DATA" >/dev/null ||
            {
                echo "missing explicit reviewed value for $REVIEWED_KEY" >&2
                exit 1
            }
    done <"$GUARDED_STATE/reviewed-keys"
    USE_FOREMAN="$(yq -r '.use_foreman' "$REVIEWED_DATA")"
    USE_CODEX_REVIEW="$(yq -r '.use_codex_review' "$REVIEWED_DATA")"
    USE_CODEX_CLOUD_REVIEW="$(
        yq -r '.use_codex_cloud_review // false' "$REVIEWED_DATA"
    )"
    USE_SKILLS_SYNC="$(yq -r '.use_skills_sync' "$REVIEWED_DATA")"
    SKILL_CATEGORIES="$(yq -o=json -I=0 '.skill_categories // []' "$REVIEWED_DATA")"
    USE_CODERABBIT="$(yq -r '.use_coderabbit' "$REVIEWED_DATA")"
    USE_CODEQL="$(yq -r '.use_codeql' "$REVIEWED_DATA")"
    CODEQL_LANGUAGES="$(yq -o=json -I=0 '.codeql_languages' "$REVIEWED_DATA")"
    case "$USE_FOREMAN" in true | false) ;; *)
        echo "reviewed use_foreman must be boolean" >&2
        exit 1
        ;;
    esac
    case "$USE_CODEX_REVIEW" in true | false) ;; *)
        echo "reviewed use_codex_review must be boolean" >&2
        exit 1
        ;;
    esac
    case "$USE_CODEX_CLOUD_REVIEW" in true | false) ;; *)
        echo "reviewed use_codex_cloud_review must be boolean" >&2
        exit 1
        ;;
    esac
    case "$USE_SKILLS_SYNC" in true | false) ;; *)
        echo "reviewed use_skills_sync must be boolean" >&2
        exit 1
        ;;
    esac
    [ "$USE_CODEX_CLOUD_REVIEW" != "true" ] || [ "$USE_CODEX_REVIEW" = "true" ] ||
        {
            echo "use_codex_cloud_review requires use_codex_review" >&2
            exit 1
        }
    [ "$USE_CODEX_CLOUD_REVIEW" != "true" ] || [ "$USE_SKILLS_SYNC" = "true" ] ||
        [ "$SHIPS_CLASSIFIER_NATIVELY" = "true" ] ||
        {
            echo "use_codex_cloud_review requires use_skills_sync (waived when this repo ships the classifier natively at $SKILLS_SOURCE_CLASSIFIER)" >&2
            exit 1
        }
    [ "$USE_CODEX_CLOUD_REVIEW" != "true" ] || [ "$SHIPS_CLASSIFIER_NATIVELY" = "true" ] ||
        printf '%s\n' "$SKILL_CATEGORIES" | yq -e 'contains(["universal"])' - >/dev/null ||
        {
            echo "use_codex_cloud_review requires the universal skill category (waived when this repo ships the classifier natively at $SKILLS_SOURCE_CLASSIFIER)" >&2
            exit 1
        }
    case "$USE_CODERABBIT" in true | false) ;; *)
        echo "reviewed use_coderabbit must be boolean" >&2
        exit 1
        ;;
    esac
    case "$USE_CODEQL" in true | false) ;; *)
        echo "reviewed use_codeql must be boolean" >&2
        exit 1
        ;;
    esac
    printf '%s\n' "$TARGET_DISCOVERY" >"$GUARDED_STATE/target-discovery-path" ||
        {
            echo "failed to record the converged target render" >&2
            exit 1
        }
}

guarded_update_usage() {
    echo "usage: guarded-update.sh prepare|discover    (run from the repository root)" >&2
    echo "       . guarded-update.sh load [state-dir]  (bash; restores the frozen values)" >&2
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    case "${1:-}" in
    load)
        shift
        guarded_update_load "$@"
        ;;
    *)
        guarded_update_usage
        return 2
        ;;
    esac
else
    set -eu
    case "${1:-}" in
    prepare) guarded_update_prepare ;;
    discover) guarded_update_discover ;;
    *)
        guarded_update_usage
        exit 2
        ;;
    esac
fi
