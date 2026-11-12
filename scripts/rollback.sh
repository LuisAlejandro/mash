#!/usr/bin/env bash
set -euo pipefail

FLOW_TYPE=${1:-release}
VERSION=${VERSION:-}
NON_INTERACTIVE=${NON_INTERACTIVE:-false}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
print_step() { echo -e "${GREEN}[UNDO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
source "$SCRIPT_DIR/lib.sh"

[[ "$FLOW_TYPE" = release ]] || { print_error "Usage: VERSION=x.y.z $0 release"; exit 1; }
if [[ -z "$VERSION" ]]; then
    current_branch=$(git branch --show-current)
    [[ "$current_branch" != release/* ]] || VERSION=${current_branch#release/}
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    print_error "Set VERSION=x.y.z or run from release/<version>"
    exit 1
}
release_require_command git
release_require_command gh
release_require_clean_worktree

BRANCH_NAME="release/$VERSION"
PREFIX="refs/maintainer-tools/releases/$VERSION"
MASTER_BRANCH=$(release_base_branch master)
DEVELOP_BRANCH=$(release_base_branch develop)
release_require_available_branches "$MASTER_BRANCH" "$DEVELOP_BRANCH" "$BRANCH_NAME"

# Plan and validate everything before cancelling jobs, deleting a release/tag,
# resetting a branch or making any other destructive change. Old releases that
# have no checkpoints require manual recovery; a previous tag is NEVER a safe
# default for develop, whose unreleased feature commits must survive.
BEFORE_MASTER=$(git rev-parse "$PREFIX/before-master^{commit}" 2>/dev/null) &&
BEFORE_DEVELOP=$(git rev-parse "$PREFIX/before-develop^{commit}" 2>/dev/null) || {
    print_error "Release $VERSION has no local checkpoint; refusing to guess rollback targets"
    exit 1
}
MAIN=$(git rev-parse "refs/heads/$MASTER_BRANCH")
DEV=$(git rev-parse "refs/heads/$DEVELOP_BRANCH")
TAG=$(git rev-parse --verify "refs/tags/$VERSION" 2>/dev/null || true)
COMMIT=$(git rev-parse --verify "$PREFIX/release" 2>/dev/null || true)
LOCAL_RELEASE=$(git rev-parse --verify "refs/heads/$BRANCH_NAME" 2>/dev/null || true)

if [[ -n "$TAG" ]]; then
    release_validate_finish "$VERSION"
    SAVED_MAIN=$(git rev-parse --verify "$PREFIX/after-master" 2>/dev/null) &&
    SAVED_DEV=$(git rev-parse --verify "$PREFIX/after-develop" 2>/dev/null) &&
    SAVED_TAG=$(git rev-parse --verify "$PREFIX/tag" 2>/dev/null) || {
        print_error "Release finish has no complete checkpoint; resume or recover it manually"
        exit 1
    }
    [[ "$MAIN" = "$SAVED_MAIN" && "$DEV" = "$SAVED_DEV" && "$TAG" = "$SAVED_TAG" ]] || {
        print_error "A base branch or tag moved after release; rollback stopped without changing anything"
        exit 1
    }
else
    [[ "$MAIN" = "$BEFORE_MASTER" && "$DEV" = "$BEFORE_DEVELOP" && -n "$LOCAL_RELEASE" ]] || {
        print_error "Unfinished release has changed base branches or no local branch; refusing to infer state"
        exit 1
    }
fi
if [[ -n "$LOCAL_RELEASE" && "$LOCAL_RELEASE" != "${COMMIT:-$BEFORE_DEVELOP}" ]]; then
    print_error "$BRANCH_NAME contains unrecorded work; refusing to delete it"
    exit 1
fi

REMOTE_REFS=$(git ls-remote origin "refs/heads/$MASTER_BRANCH" "refs/heads/$DEVELOP_BRANCH" \
    "refs/heads/$BRANCH_NAME" "refs/tags/$VERSION") || exit 1
remote_sha() { printf '%s\n' "$REMOTE_REFS" | awk -v ref="$1" '$2 == ref { print $1 }'; }
REMOTE_MAIN=$(remote_sha "refs/heads/$MASTER_BRANCH")
REMOTE_DEV=$(remote_sha "refs/heads/$DEVELOP_BRANCH")
REMOTE_TAG=$(remote_sha "refs/tags/$VERSION")
REMOTE_RELEASE=$(remote_sha "refs/heads/$BRANCH_NAME")
[[ "$REMOTE_MAIN" = "$MAIN" || "$REMOTE_MAIN" = "$BEFORE_MASTER" ]] &&
[[ "$REMOTE_DEV" = "$DEV" || "$REMOTE_DEV" = "$BEFORE_DEVELOP" ]] || {
    print_error "Remote base branch moved; refusing to overwrite another maintainer's work"
    exit 1
}
[[ -z "$REMOTE_TAG" || "$REMOTE_TAG" = "$TAG" ]] || {
    print_error "Remote tag differs from the checkpoint; rollback stopped"
    exit 1
}
[[ -z "$REMOTE_RELEASE" || "$REMOTE_RELEASE" = "${COMMIT:-$BEFORE_DEVELOP}" ]] || {
    print_error "Remote release branch contains unrecorded work; rollback stopped"
    exit 1
}

print_step "Rollback plan: $MASTER_BRANCH $MAIN -> $BEFORE_MASTER; $DEVELOP_BRANCH $DEV -> $BEFORE_DEVELOP"
print_step "The recorded release tag/branch will be removed; backup refs will remain local"
if [[ "$NON_INTERACTIVE" != true ]]; then
    read -p "Proceed with this rollback of $VERSION? (y/N): " -n 1 -r
    echo
    [[ "$REPLY" =~ ^[Yy]$ ]] || { print_error "Rollback cancelled"; exit 1; }
fi

release_cancel_matching_runs "$BRANCH_NAME" "$VERSION"
release_require_clean_worktree
# Cancel may take time. Compare-and-swap protects BOTH local and remote refs
# from concurrent updates instead of trusting mutable origin/* tracking refs.
[[ "$(git rev-parse "refs/heads/$MASTER_BRANCH")" = "$MAIN" &&
   "$(git rev-parse "refs/heads/$DEVELOP_BRANCH")" = "$DEV" ]] || {
    print_error "Local branch moved while waiting for Actions; rollback stopped"
    exit 1
}
leases=("--force-with-lease=refs/heads/$MASTER_BRANCH:$REMOTE_MAIN")
refspecs=("$BEFORE_MASTER:refs/heads/$MASTER_BRANCH")
if [[ "$MASTER_BRANCH" != "$DEVELOP_BRANCH" ]]; then
    leases+=("--force-with-lease=refs/heads/$DEVELOP_BRANCH:$REMOTE_DEV")
    refspecs+=("$BEFORE_DEVELOP:refs/heads/$DEVELOP_BRANCH")
fi
if [[ -n "$REMOTE_TAG" ]]; then
    leases+=("--force-with-lease=refs/tags/$VERSION:$REMOTE_TAG")
    refspecs+=(":refs/tags/$VERSION")
fi
if [[ -n "$REMOTE_RELEASE" ]]; then
    leases+=("--force-with-lease=refs/heads/$BRANCH_NAME:$REMOTE_RELEASE")
    refspecs+=(":refs/heads/$BRANCH_NAME")
fi
if ! git push --atomic "${leases[@]}" origin "${refspecs[@]}"; then
    print_error "Atomic rollback refused; local refs, tag and GitHub release were left intact"
    exit 1
fi

BACKUP="refs/maintainer-tools/rollbacks/$VERSION/${COMMIT:-$BEFORE_DEVELOP}"
{
    printf 'update %s %s\nupdate %s %s\n' "$BACKUP/master" "$MAIN" "$BACKUP/develop" "$DEV"
    [[ -z "$TAG" ]] || printf 'update %s %s\ndelete %s %s\n' "$BACKUP/tag" "$TAG" "refs/tags/$VERSION" "$TAG"
    printf 'update %s %s %s\n' "refs/heads/$MASTER_BRANCH" "$BEFORE_MASTER" "$MAIN"
    if [[ "$MASTER_BRANCH" != "$DEVELOP_BRANCH" ]]; then
        printf 'update %s %s %s\n' "refs/heads/$DEVELOP_BRANCH" "$BEFORE_DEVELOP" "$DEV"
    fi
    while read -r ref sha; do printf 'delete %s %s\n' "$ref" "$sha"; done < <(
        git for-each-ref --format='%(refname) %(objectname)' "$PREFIX/"
    )
} | git update-ref --stdin
case "$(git branch --show-current)" in
    "$MASTER_BRANCH") git reset --hard "$BEFORE_MASTER" ;;
    "$DEVELOP_BRANCH") git reset --hard "$BEFORE_DEVELOP" ;;
esac
if [[ -n "$LOCAL_RELEASE" ]]; then
    if [[ "$(git branch --show-current)" = "$BRANCH_NAME" ]]; then
        git checkout "$DEVELOP_BRANCH"
    fi
    git update-ref -d "refs/heads/$BRANCH_NAME" "$LOCAL_RELEASE"
fi
# Only now may the GitHub release be deleted. A bad target or a rejected push
# must never leave an otherwise working release without its tag/assets.
if gh release view "$VERSION" >/dev/null 2>&1; then
    gh release delete "$VERSION" --yes
fi
print_step "Rollback for release $VERSION completed; backup refs: $BACKUP"
