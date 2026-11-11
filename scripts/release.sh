#!/usr/bin/env bash
set -euo pipefail

VERSION_TYPE=${1:-patch}
APP_NAME=${2:-Release}
NON_INTERACTIVE=${NON_INTERACTIVE:-false}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_step() { echo -e "${GREEN}[RELEASE]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

source "$SCRIPT_DIR/lib.sh"

# Repository-specific gates override the shared preflight placeholder. Keep the
# override in generator configuration so a future sync cannot remove the gate.
release_run_preflight() {
    print_step "Running release preflight"
    "$SCRIPT_DIR/preflight.sh"
}

if [[ ! "$VERSION_TYPE" =~ ^(major|minor|patch|--resume)$ ]]; then
    print_error "Usage: $0 [major|minor|patch] or VERSION=x.y.z $0 --resume"
    exit 1
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    print_error "Not in a git repository"
    exit 1
fi

release_check_host_tools
release_require_clean_worktree
if [[ "$VERSION_TYPE" != "--resume" ]] &&
   ! git config --get gitflow.branch.master >/dev/null 2>&1 &&
   ! git config --get gitflow.branch.release.parent >/dev/null 2>&1; then
    print_warning "Git flow not initialized. Initializing with default settings..."
    git flow init -d
fi
MASTER_BRANCH=$(release_base_branch master)
DEVELOP_BRANCH=$(release_base_branch develop)
release_require_available_branches "$MASTER_BRANCH" "$DEVELOP_BRANCH"

if [[ "$VERSION_TYPE" = "--resume" ]]; then
    # Resume finish/push/draft after a checkout failure, never bump a second time.
    NEW_VERSION=${VERSION:-}
    if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_error "Set VERSION=x.y.z to resume an existing release"
        exit 1
    fi
    RELEASE_BRANCH_SHA=$(git rev-parse "refs/maintainer-tools/releases/$NEW_VERSION/release^{commit}") || {
        print_error "No saved checkpoint for $NEW_VERSION; refusing to infer a release to resume"
        exit 1
    }
else
    print_step "Checking out $DEVELOP_BRANCH branch"
    git checkout "$DEVELOP_BRANCH"
    print_step "Pulling latest changes"
    git pull --ff-only origin "$DEVELOP_BRANCH"

    # Resolve the version from the refreshed branch, not a stale local checkout.
    CURRENT_VERSION=$(grep '^current_version = ' .bumpversion.cfg | awk '{print $3}')
    if [[ ! "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_error "Current version is not a valid version"
        exit 1
    fi
    NEW_VERSION=$(bumpversion --dry-run --list "$VERSION_TYPE" 2>/dev/null | grep '^new_version=' | cut -d'=' -f2-)
    if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_error "New version is not a valid version"
        exit 1
    fi
    print_step "Current version: $CURRENT_VERSION; new version: $NEW_VERSION"
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -p "Proceed with release $NEW_VERSION? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Release cancelled"
            exit 1
        fi
    fi

    release_run_preflight
    # The exact before/after refs make rollback safe even when git-flow's merge
    # message contains no version. Never overwrite an earlier attempt's record.
    release_record_start "$NEW_VERSION"
    if ! git flow release start "$NEW_VERSION"; then
        release_forget_start "$NEW_VERSION"
        print_error "The release branch was not created; checkpoints removed so the attempt can be retried"
        exit 1
    fi
    if ! bumpversion --no-commit "$VERSION_TYPE"; then
        git checkout "$DEVELOP_BRANCH" 2>/dev/null || true
        git branch -D "release/$NEW_VERSION" 2>/dev/null || true
        release_forget_start "$NEW_VERSION"
        print_error "The version bump failed; the release branch and checkpoints were removed"
        exit 1
    fi
    release_run_post_bump_commands

    print_step "Updating changelog"
    if command -v gitchangelog >/dev/null 2>&1; then
        gitchangelog >"HISTORY.md"
    else
        print_warning "gitchangelog not found, skipping changelog update"
    fi

    # Only configured version files and the changelog belong in this commit.
    git add -- .bumpversion.cfg
    [[ ! -f "HISTORY.md" ]] || git add -- "HISTORY.md"
    while IFS= read -r version_file; do
        [[ -z "$version_file" ]] || git add -- "$version_file"
    done < <(awk '/^\[bumpversion:file:/ { sub(/^\[bumpversion:file:/, ""); sub(/\]$/, ""); print }' .bumpversion.cfg)

    git commit -S -m "Updating Changelog and version to $NEW_VERSION"
    release_record_commit "$NEW_VERSION"
    git tag -d "$NEW_VERSION" 2>/dev/null || true
    git push -u origin "release/$NEW_VERSION"
    RELEASE_BRANCH_SHA=$(git rev-parse HEAD)
    export PREVIOUS_VERSION="$CURRENT_VERSION"
fi

release_wait_for_branch_ci "release/$NEW_VERSION" "$RELEASE_BRANCH_SHA"
release_finish_release "$NEW_VERSION" "$APP_NAME"

# This repository builds assets at the exact tag before making its draft public.
print_step "Dispatching the artifact build for $NEW_VERSION"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh workflow run release.yml --ref "$NEW_VERSION" -f tag="$NEW_VERSION"; then
        print_step "Artifact build dispatched for $NEW_VERSION"
        print_step "The artifact workflow will publish the draft after every platform verifies"
    else
        print_warning "Could not dispatch the artifact build. Run it by hand:"
        print_warning "  gh workflow run release.yml --ref $NEW_VERSION -f tag=$NEW_VERSION"
    fi
else
    print_warning "gh is unavailable, so the artifact build was not dispatched."
    print_warning "Run: gh workflow run release.yml --ref $NEW_VERSION -f tag=$NEW_VERSION"
fi
print_step "Release $NEW_VERSION prepared as a draft; the build publishes it."

