#!/usr/bin/env bash

# Shared release gates for release scripts.
# Managed by maintainer-tools 0.4.4. Do not edit directly.

RELEASE_CI_WORKFLOW=${RELEASE_CI_WORKFLOW:-push.yml}
RELEASE_CI_TIMEOUT_SECONDS=${RELEASE_CI_TIMEOUT_SECONDS:-2700}
RELEASE_CI_POLL_SECONDS=${RELEASE_CI_POLL_SECONDS:-15}

release_require_command() {
    local command_name=$1

    if ! command -v "$command_name" >/dev/null 2>&1; then
        print_error "Required command is missing: $command_name"
        exit 1
    fi
}

release_require_clean_worktree() {
    if [[ -n "$(git status --porcelain)" ]]; then
        print_error "Working directory is not clean (modified or untracked files present)"
        git status --short >&2
        exit 1
    fi
}

release_check_host_tools() {
    local signing_key
    local tool

    print_step "Checking host release tools"
    for tool in git gh bumpversion gpg; do
        release_require_command "$tool"
    done


    if ! git flow version >/dev/null 2>&1; then
        print_error "git-flow is not available (run: git flow version)"
        exit 1
    fi



    if ! gh auth status >/dev/null 2>&1; then
        print_error "GitHub CLI is not authenticated (run: gh auth login)"
        exit 1
    fi

    signing_key=$(git config --get user.signingkey || true)
    if [[ -z "$signing_key" ]]; then
        print_error "Git user.signingkey is not configured"
        exit 1
    fi

    if ! gpg --list-secret-keys "$signing_key" >/dev/null 2>&1; then
        print_error "GPG signing key is not available locally: $signing_key"
        exit 1
    fi

    print_step "Host release tools check passed"
}


release_run_preflight() {
    print_step "Skipping release preflight (not configured for this repo)"
}


release_enable_noninteractive_git() {
    print_step "Configuring git for non-interactive mode"
    git config --local core.editor ":"
    git config --local merge.ours.driver true
    export GIT_MERGE_AUTOEDIT=no
    export GPG_TTY
    GPG_TTY=$(tty) 2>/dev/null || true
}

release_cleanup_noninteractive_git() {
    git config --local --unset core.editor 2>/dev/null || true
    git config --local --unset merge.ours.driver 2>/dev/null || true
}

release_wait_for_branch_ci() {
    local branch_name=$1
    local commit_sha=$2
    local start_time
    local run_id
    local run_url
    local status
    local conclusion

    release_require_command gh
    if ! gh auth status >/dev/null 2>&1; then
        print_error "GitHub CLI is not authenticated; cannot verify release branch CI"
        exit 1
    fi

    print_step "Waiting for GitHub Actions on $branch_name ($commit_sha)"
    start_time=$(date +%s)

    while true; do
        run_id=$(gh run list \
            --workflow "$RELEASE_CI_WORKFLOW" \
            --branch "$branch_name" \
            --commit "$commit_sha" \
            --limit 1 \
            --json databaseId \
            --jq '.[0].databaseId // ""')

        if [[ -n "$run_id" ]]; then
            run_url=$(gh run view "$run_id" --json url --jq '.url')
            print_step "Found CI run $run_id: $run_url"
            if gh run watch "$run_id" --exit-status; then
                print_step "Release branch CI passed"
                return 0
            fi

            status=$(gh run view "$run_id" --json status --jq '.status')
            conclusion=$(gh run view "$run_id" --json conclusion --jq '.conclusion')
            print_error "Release branch CI failed: status=$status conclusion=$conclusion"
            print_error "Run URL: $run_url"
            exit 1
        fi

        if (( $(date +%s) - start_time > RELEASE_CI_TIMEOUT_SECONDS )); then
            print_error "Timed out waiting for GitHub Actions run on $branch_name"
            print_error "Workflow: $RELEASE_CI_WORKFLOW; commit: $commit_sha"
            exit 1
        fi

        sleep "$RELEASE_CI_POLL_SECONDS"
    done
}

release_verify_remote_tag() {
    local version=$1
    local max_retries=${2:-5}
    local retry_delay=${3:-3}
    local attempt

    print_step "Verifying tag was pushed to remote"

    for attempt in $(seq 1 "$max_retries"); do
        if git ls-remote --tags origin | grep -q "refs/tags/$version$"; then
            print_step "Tag $version found on remote"
            return 0
        fi

        if [[ "$attempt" -lt "$max_retries" ]]; then
            print_warning "Tag not found on remote, retrying in ${retry_delay}s... (attempt $attempt/$max_retries)"
            sleep "$retry_delay"
            # Verification is read-only. The finish step already pushed exactly
            # this release atomically; retrying must not publish unrelated tags.
        fi
    done

    print_error "Tag $version was not found on remote after $max_retries attempts"
    print_error "Please verify the push manually: git push origin --tags"
    exit 1
}

release_build_notes() {
    local current_version=$1
    local new_version=$2
    local description_text=""
    local release_content=""
    local repo_slug=""

    if [[ -f "RELEASE_DESCRIPTION.md" ]]; then
        description_text=$(<"RELEASE_DESCRIPTION.md")
    fi

    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        repo_slug=$(gh repo view --json owner,name -q '.owner.login + "/" + .name')
    else
        repo_slug=$(git config --get remote.origin.url | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')
    fi

    if [[ -f "HISTORY.md" ]]; then
        # HISTORY headings are markdown ("## 1.2.3 (date)"). Anchoring on the
        # version alone matched nothing, so every release body shipped an empty
        # "What's new" section that had to be pasted in by hand afterwards.
        release_content=$(awk "/^#* *$new_version \(/ { flag=1; next } flag && /^#* *[0-9]+\.[0-9]+\.[0-9]+ \(/ { exit } flag" HISTORY.md)
        printf '%s\n\n## What'\''s new in %s\n%s\n\nRead [HISTORY](HISTORY.md) for more info.\n\n**Full Changelog**: https://github.com/%s/compare/%s...%s' \
            "$description_text" \
            "$new_version" \
            "$release_content" \
            "$repo_slug" \
            "$current_version" \
            "$new_version"
    else
        printf '%s' "$description_text"
    fi
}

release_create_github_release() {
    local version=$1
    local title=$2
    local notes=$3

    print_step "Publishing GitHub release"
    if ! command -v gh >/dev/null 2>&1; then
        print_warning "GitHub CLI not found, skipping GitHub release creation"
        return 0
    fi

    if ! gh auth status >/dev/null 2>&1; then
        print_warning "GitHub CLI not authenticated. Please run 'gh auth login' first."
        print_warning "You can create the GitHub release manually later."
        return 0
    fi

    if gh release view "$version" >/dev/null 2>&1; then
        print_warning "GitHub release $version already exists, skipping creation"
        return 0
    fi

    print_step "Creating draft GitHub release $version"
    if gh release create "$version" \
        --title "$title" \
        --notes "$notes" \
        --draft; then
        print_step "Draft release created; the artifact workflow owns publication."
    else
        print_warning "Failed to create GitHub release. You can create it manually later."
    fi
}

release_cancel_matching_runs() {
    local branch_name=$1 version=$2 workflow branch run_ids run_id pending
    local deadline=$((SECONDS + RELEASE_CI_TIMEOUT_SECONDS))
    release_require_command gh
    if ! gh auth status >/dev/null 2>&1; then
        print_error "GitHub CLI is not authenticated; rollback stopped"
        return 1
    fi
    # A cancelling release run can still dispatch an artifact run. Wait for all
    # matching runs to be terminal before touching any release refs.
    while true; do
        pending=false
        for workflow in push.yml release.yml artifacts.yml; do
            for branch in "$branch_name" "$version"; do
                run_ids=$(gh api --method GET --paginate \
                    "repos/{owner}/{repo}/actions/workflows/$workflow/runs" \
                    -f branch="$branch" -F per_page=100 \
                    --jq '.workflow_runs[] | select(.status != "completed") | .id') || {
                    print_error "Could not list $workflow runs on $branch; rollback stopped"
                    return 1
                }
                for run_id in $run_ids; do
                    pending=true
                    print_step "Cancelling $workflow run $run_id on $branch"
                    gh run cancel "$run_id" >/dev/null 2>&1 ||
                        print_warning "Could not cancel $run_id; checking again"
                done
            done
        done
        [[ "$pending" = true ]] || return 0
        if (( SECONDS >= deadline )); then
            print_error "Timed out waiting for release runs to stop; rollback stopped"
            return 1
        fi
        sleep "$RELEASE_CI_POLL_SECONDS"
    done
}

# git-flow-next stores topic parent/startpoint; AVH stores master/develop.
# Resolve the actual release bases, not a legacy key left behind by migration.
release_base_branch() {
    case "$1" in
        master) git config --get gitflow.branch.release.parent || git config --get gitflow.branch.master || echo master ;;
        develop) git config --get gitflow.branch.release.startpoint || git config --get gitflow.branch.develop || echo develop ;;
        *) return 2 ;;
    esac
}

# Checkpoints are local Git refs shared by linked worktrees, not guessed merge
# messages. Missing or moved checkpoints must stop rollback before any deletion.
release_record_start() {
    local version=$1 prefix="refs/maintainer-tools/releases/$1"
    local master_branch develop_branch before_master before_develop
    master_branch=$(release_base_branch master)
    develop_branch=$(release_base_branch develop)
    release_require_available_branches "$master_branch" "$develop_branch" || return 1
    if [[ -n "$(git for-each-ref --format='%(refname)' "$prefix/")" ]]; then
        print_error "Release $version already has checkpoints; resume it instead of starting another bump"
        return 1
    fi
    if git show-ref --verify --quiet "refs/tags/$version"; then
        print_error "Tag $version already exists; refusing to replace an existing release"
        return 1
    fi
    before_master=$(git rev-parse "refs/heads/$master_branch^{commit}") || return 1
    before_develop=$(git rev-parse "refs/heads/$develop_branch^{commit}") || return 1
    printf 'create %s %s\ncreate %s %s\n' \
        "$prefix/before-master" "$before_master" \
        "$prefix/before-develop" "$before_develop" | git update-ref --stdin
}

# A failed start must not leave checkpoints behind: they make the next attempt
# refuse with "already has checkpoints" and there is no release to resume yet.
release_forget_start() {
    local prefix="refs/maintainer-tools/releases/$1"
    git for-each-ref --format='delete %(refname) %(objectname)' "$prefix/" \
        | git update-ref --stdin
}

release_record_commit() {
    local prefix="refs/maintainer-tools/releases/$1" before_develop commit
    before_develop=$(git rev-parse "$prefix/before-develop^{commit}") || return 1
    commit=$(git rev-parse HEAD) || return 1
    if [[ "$(git show -s --format=%P "$commit")" != "$before_develop" ]]; then
        print_error "Release bump is not directly based on its recorded develop checkpoint"
        return 1
    fi
    printf 'create %s %s\n' "$prefix/release" "$commit" | git update-ref --stdin
}

release_require_available_branches() {
    local own worktree="" line branch requested
    own=$(git rev-parse --show-toplevel) || return 1
    own=$(cd "$own" && pwd -P)
    while IFS= read -r line; do
        case "$line" in
            worktree\ *) worktree=${line#worktree } ;;
            branch\ refs/heads/*)
                branch=${line#branch refs/heads/}
                for requested in "$@"; do
                    if [[ "$branch" = "$requested" && "$(cd "$worktree" && pwd -P)" != "$own" ]]; then
                        print_error "$branch is checked out in $worktree; refusing to change another worktree"
                        return 1
                    fi
                done
                ;;
        esac
    done < <(git worktree list --porcelain)
}

# A normal release is one bump from pre-release develop, followed by either a
# fast-forward or one merge into each base. A filename allowlist cannot prove
# this: a README-only feature commit is still work rollback must not discard.
release_validate_finish() {
    local version=$1 prefix="refs/maintainer-tools/releases/$1"
    local master_branch develop_branch before_master before_develop commit main dev tag parents
    master_branch=$(release_base_branch master)
    develop_branch=$(release_base_branch develop)
    before_master=$(git rev-parse "$prefix/before-master^{commit}" 2>/dev/null) &&
    before_develop=$(git rev-parse "$prefix/before-develop^{commit}" 2>/dev/null) &&
    commit=$(git rev-parse "$prefix/release^{commit}" 2>/dev/null) || {
        print_error "Release $version has no complete local checkpoint; refusing to guess rollback targets"
        return 1
    }
    main=$(git rev-parse "refs/heads/$master_branch^{commit}") || return 1
    dev=$(git rev-parse "refs/heads/$develop_branch^{commit}") || return 1
    tag=$(git rev-parse "refs/tags/$version^{commit}" 2>/dev/null) || {
        print_error "Release $version has no local tag; refusing to infer completed state"
        return 1
    }
    if [[ "$(git show -s --format=%P "$commit")" != "$before_develop" || "$tag" != "$main" ]]; then
        print_error "Release $version does not match its checkpoints or a base branch has advanced"
        return 1
    fi
    if [[ "$main" != "$commit" ]]; then
        parents=$(git show -s --format=%P "$main")
        if [[ "$parents" != "$before_master $commit" || "$(git rev-parse "$main^{tree}")" != "$(git rev-parse "$commit^{tree}")" ]]; then
            print_error "$master_branch contains work outside release $version; refusing to rewind it"
            return 1
        fi
    fi
    if [[ "$dev" != "$commit" && "$dev" != "$before_develop" ]]; then
        parents=$(git show -s --format=%P "$dev")
        if [[ "$parents" != "$before_develop $main" && "$parents" != "$before_develop $commit" ]] ||
           [[ "$(git rev-parse "$dev^{tree}")" != "$(git rev-parse "$commit^{tree}")" ]]; then
            print_error "$develop_branch contains work outside release $version; refusing to rewind it"
            return 1
        fi
    fi
}

release_record_finish() {
    local version=$1 prefix="refs/maintainer-tools/releases/$1"
    local master_branch develop_branch commit main dev tag
    release_validate_finish "$version" || return 1
    master_branch=$(release_base_branch master)
    develop_branch=$(release_base_branch develop)
    commit=$(git rev-parse "$prefix/release")
    main=$(git rev-parse "refs/heads/$master_branch")
    dev=$(git rev-parse "refs/heads/$develop_branch")
    tag=$(git rev-parse "refs/tags/$version")
    if ! git merge-base --is-ancestor "$commit" "$dev"; then
        print_error "$develop_branch has not received release $version; finish the merge-back before publishing"
        return 1
    fi
    printf 'create %s %s\ncreate %s %s\ncreate %s %s\n' \
        "$prefix/after-master" "$main" "$prefix/after-develop" "$dev" \
        "$prefix/tag" "$tag" | git update-ref --stdin
}

release_finish_release() {
    local version=$1 app_name=$2 previous_version prefix="refs/maintainer-tools/releases/$1"
    local master_branch develop_branch commit main dev saved
    master_branch=$(release_base_branch master)
    develop_branch=$(release_base_branch develop)
    release_require_clean_worktree
    release_require_available_branches "$master_branch" "$develop_branch" "release/$version" || return 1
    commit=$(git rev-parse "$prefix/release^{commit}" 2>/dev/null) || {
        print_error "No checkpoint for release $version; refusing to finish an unidentified release"
        return 1
    }
    previous_version=${PREVIOUS_VERSION:-$(git describe --tags --abbrev=0 "$prefix/before-master")}
    release_enable_noninteractive_git
    trap release_cleanup_noninteractive_git EXIT

    # A failed checkout can leave a signed tag/master but no develop merge.
    # Resume that state without another version bump or another git-flow finish.
    if ! git show-ref --verify --quiet "refs/tags/$version"; then
        if [[ "$(git rev-parse "refs/heads/release/$version")" != "$commit" ||
              "$(git rev-parse "refs/heads/$master_branch")" != "$(git rev-parse "$prefix/before-master")" ||
              "$(git rev-parse "refs/heads/$develop_branch")" != "$(git rev-parse "$prefix/before-develop")" ]]; then
            print_error "Release or base branches moved after checkpoint; finish stopped before changing them"
            return 1
        fi
        print_step "Finishing git flow release"
        # -p means push in git-flow AVH but preserve-merges in git-flow-next.
        # Do not let either implementation publish a half-finished release.
        if ! git flow release finish -s -m "Release version $version" "$version"; then
            print_error "Release finish stopped; local state is preserved and no publication follows"
            print_error "Resolve the reported checkout/merge error, then resume: VERSION=$version ./scripts/release.sh --resume"
            return 1
        fi
    fi
    release_validate_finish "$version" || return 1
    if git show-ref --verify --quiet "$prefix/after-master"; then
        for saved in "$master_branch:after-master" "$develop_branch:after-develop"; do
            [[ "$(git rev-parse "refs/heads/${saved%:*}")" = "$(git rev-parse "$prefix/${saved#*:}")" ]] || {
                print_error "Completed release checkpoint differs from the current base branches"
                return 1
            }
        done
        [[ "$(git rev-parse "refs/tags/$version")" = "$(git rev-parse "$prefix/tag")" ]] || return 1
    else
        dev=$(git rev-parse "refs/heads/$develop_branch")
        if ! git merge-base --is-ancestor "$commit" "$dev"; then
            main=$(git rev-parse "refs/heads/$master_branch")
            git checkout "$develop_branch" || return 1
            git merge --no-ff "$main" -m "Merge branch '$master_branch' into $develop_branch" || return 1
        fi
        release_record_finish "$version" || return 1
    fi

    print_step "Pushing both base branches and this release tag atomically"
    if [[ "$master_branch" = "$develop_branch" ]]; then
        git push --atomic origin "$master_branch" "refs/tags/$version" || return 1
    else
        git push --atomic origin "$master_branch" "$develop_branch" "refs/tags/$version" || return 1
    fi
    # Cleanup comes after the full publication of refs, never before it.
    git push origin --delete "release/$version" 2>/dev/null || true
    if [[ "$(git branch --show-current)" != "release/$version" ]]; then
        git branch -d "release/$version" 2>/dev/null || true
    fi
    release_verify_remote_tag "$version"
    release_create_github_release "$version" "$app_name $version" "$(release_build_notes "$previous_version" "$version")"
}

release_read_post_bump_commands() {
    if [[ ! -f .bumpversion.cfg ]]; then
        return 0
    fi

    awk '
        /^\[maintainer-tools\]/ { in_section=1; next }
        /^\[/ && in_section { exit }
        in_section && /^post_bump_commands[[:space:]]*=/ {
            line = $0
            sub(/^post_bump_commands[[:space:]]*=[[:space:]]*/, "", line)
            if (length(line) > 0) {
                print line
            }
            exit
        }
    ' .bumpversion.cfg
}

release_run_post_bump_commands() {
    local command

    while IFS= read -r command; do
        [[ -z "$command" ]] && continue
        print_step "Running post-bump command: $command"
        bash -c "$command"
    done < <(release_read_post_bump_commands)
}

release_resolve_branch_version() {
    local branch_prefix=$1
    local current_branch
    local version

    current_branch=$(git branch --show-current)
    version=${VERSION:-${current_branch#${branch_prefix}/}}

    if [[ "$current_branch" != "${branch_prefix}/"* && -z "${VERSION:-}" ]]; then
        print_error "Must run from ${branch_prefix}/<version> or set VERSION=<version>"
        exit 1
    fi

    if ! echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        print_error "Version is not valid: $version"
        exit 1
    fi

    printf '%s' "$version"
}
