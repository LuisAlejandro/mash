#!/usr/bin/env bash
# Run on the host after rsync delivers one complete release batch to incoming/.
#
# Installed by bootstrap-letsmash-repo.sh as /usr/local/bin/letsmash-import-incoming.
# Re-run bootstrap to refresh the installed copy from this file.
#
# Usage (from letsmash-repo):
#   letsmash-import-incoming noble <publish-id>          # both architectures
#   letsmash-import-incoming noble <publish-id> amd64    # one arch (repair only)
#   letsmash-import-incoming noble <publish-id> arm64
#
# Forked from dockershelf-apt's importer. Keeps the per-publish isolation,
# PUBLISH_ID validation, one lock held across the read/remove/include/export
# transaction, arch-scoped replace, one retry, and reprepro export. Drops their
# filename +<codename> filter, which Mash's plain version strings do not use.
#
# In batch mode it validates both packages before changing reprepro, imports
# both under one lock with automatic export disabled, and exports only after both
# succeed. An interrupted batch can leave an unadvertised package in reprepro's
# internal database, but the public indices remain at the previous version.
#
# Expects:
#   REPO_ROOT=/var/www/letsmash
#   INCOMING=/var/www/letsmash/incoming

set -euo pipefail

CODENAME="${1:?usage: letsmash-import-incoming <noble> <publish-id> [amd64|arm64]}"
PUBLISH_ID="${2:?usage: letsmash-import-incoming <noble> <publish-id> [amd64|arm64]}"
ARCH="${3:-}"
REPO_ROOT="${REPO_ROOT:-/var/www/letsmash}"
INCOMING="${INCOMING:-${REPO_ROOT}/incoming}"
GNUPGHOME="${GNUPGHOME:-${REPO_ROOT}/.gnupg}"
PUBLISH_LOCK="${PUBLISH_LOCK:-${REPO_ROOT}/.publish.lock}"
export GNUPGHOME

case "$REPO_ROOT" in
/var/www/debian | /var/www/debian/*)
  echo "refusing to operate on the Dockershelf repository" >&2
  exit 1
  ;;
esac
case "$CODENAME" in
noble) ;;
*)
  echo "unsupported suite: $CODENAME" >&2
  exit 1
  ;;
esac
if [[ ! "$PUBLISH_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "invalid PUBLISH_ID: ${PUBLISH_ID}" >&2
  exit 1
fi
case "$ARCH" in
"" | amd64 | arm64) ;;
*)
  echo "unsupported architecture: $ARCH" >&2
  exit 1
  ;;
esac

if [[ -n "$ARCH" ]]; then
  INCOMING="${INCOMING}/${ARCH}/${PUBLISH_ID}"
else
  INCOMING="${INCOMING}/${PUBLISH_ID}"
fi

if [[ -n "$PUBLISH_ID" ]]; then
  trap 'rm -rf "${INCOMING}" 2>/dev/null || true' EXIT
fi

shopt -s nullglob
debs=("${INCOMING}"/*.deb)
if [ "${#debs[@]}" -eq 0 ]; then
  echo "No .deb files in ${INCOMING}"
  exit 0
fi

# Validate the entire batch before changing reprepro. Batch mode is exactly one
# letsmash package for each supported architecture, at one version; arch mode is
# deliberately available for a maintainer repair, not for CI publication.
amd64_deb=""
arm64_deb=""
version=""
for deb in "${debs[@]}"; do
  pkg="$(dpkg-deb -f "$deb" Package)"
  deb_version="$(dpkg-deb -f "$deb" Version)"
  deb_arch="$(dpkg-deb -f "$deb" Architecture)"
  if [[ "$pkg" != letsmash ]]; then
    echo "refusing ${deb}: expected Package: letsmash, got $pkg" >&2
    exit 1
  fi
  case "$deb_arch" in
  amd64 | arm64) ;;
  *)
    echo "refusing ${deb}: unsupported Architecture: $deb_arch" >&2
    exit 1
    ;;
  esac
  if [[ -n "$ARCH" && "$deb_arch" != "$ARCH" ]]; then
    echo "refusing ${deb}: expected $ARCH, got $deb_arch" >&2
    exit 1
  fi
  if [[ -n "$version" && "$version" != "$deb_version" ]]; then
    echo "refusing batch with mixed versions: $version and $deb_version" >&2
    exit 1
  fi
  version="$deb_version"
  case "$deb_arch" in
  amd64)
    [[ -z "$amd64_deb" ]] || {
      echo "refusing batch with duplicate amd64 packages" >&2
      exit 1
    }
    amd64_deb="$deb"
    ;;
  arm64)
    [[ -z "$arm64_deb" ]] || {
      echo "refusing batch with duplicate arm64 packages" >&2
      exit 1
    }
    arm64_deb="$deb"
    ;;
  esac
done
if [[ -z "$ARCH" && (-z "$amd64_deb" || -z "$arm64_deb") ]]; then
  echo "batch must contain both amd64 and arm64 letsmash packages" >&2
  exit 1
fi

# The lock spans the complete batch. The prior per-architecture publisher could
# expose amd64 before arm64 finished; export exactly once after every package is
# indexed successfully.
exec 9>"$PUBLISH_LOCK"
flock -w 600 9

reprepro_locked() { reprepro "$@"; }
include_deb() {
  local deb="$1" arch pkg deb_version
  arch="$(dpkg-deb -f "$deb" Architecture)"
  pkg="$(dpkg-deb -f "$deb" Package)"
  deb_version="$(dpkg-deb -f "$deb" Version)"
  local arch_args=(-A "$arch")

  if reprepro_locked -b "$REPO_ROOT" "${arch_args[@]}" list "$CODENAME" "$pkg" 2>/dev/null |
    awk -v want="$deb_version" '$NF == want { found=1 } END { exit !found }'; then
    echo "Removing existing ${pkg}=${deb_version} from ${CODENAME}/${arch} before import..." >&2
    reprepro_locked --export=never -b "$REPO_ROOT" "${arch_args[@]}" remove "$CODENAME" "$pkg" || true
  fi

  if reprepro_locked --export=never -b "$REPO_ROOT" includedeb "$CODENAME" "$deb"; then
    echo "  imported ${pkg}=${deb_version} (${arch})"
    rm -f "$deb"
    return 0
  fi
  echo "reprepro includedeb failed for ${pkg} (${arch}); removing and retrying once..." >&2
  reprepro_locked --export=never -b "$REPO_ROOT" "${arch_args[@]}" remove "$CODENAME" "$pkg" || true
  reprepro_locked --export=never -b "$REPO_ROOT" includedeb "$CODENAME" "$deb"
  rm -f "$deb"
}

if [[ "$ARCH" = amd64 ]]; then
  include_deb "$amd64_deb"
elif [[ "$ARCH" = arm64 ]]; then
  include_deb "$arm64_deb"
else
  include_deb "$amd64_deb"
  include_deb "$arm64_deb"
fi
reprepro -b "$REPO_ROOT" export
echo "Done. letsmash=${version} is indexed for ${ARCH:-amd64+arm64} under ${REPO_ROOT}/dists/${CODENAME}/"
