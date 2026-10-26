#!/bin/bash
# Publish both built .deb files to Mash's APT repository and verify that APT can
# consume the resulting signed index.
#
#   packaging/apt/publish.sh <version> [dist-dir]
#
# Environment:
#   MASH_APT_HOST               apt.letsma.sh (default)
#   MASH_APT_USER               letsmash-repo (default)
#   MASH_APT_KEY                SSH private key file (optional: agent/default key)
#   MASH_APT_KNOWN_HOSTS_FILE   pinned host-key file; local ~/.ssh/known_hosts by default
#
# Requires both architectures. It refuses before contacting the host if any
# setting/artifact is missing and verifies the signed index and both Packages
# records before returning success. The release workflow keeps the GitHub
# release a draft until this command and an apt-upgrade smoke pass.
set -euo pipefail

version="${1:?usage: publish.sh <version> [dist-dir]}"
dist="${2:-dist}"
host="${MASH_APT_HOST:-apt.letsma.sh}"
user="${MASH_APT_USER:-letsmash-repo}"
key="${MASH_APT_KEY:-}"
known_hosts="${MASH_APT_KNOWN_HOSTS_FILE:-${HOME}/.ssh/known_hosts}"
suite="noble"
repo_root="/var/www/letsmash"
import_bin="/usr/local/bin/letsmash-import-incoming"

[ -r "$known_hosts" ] || {
  echo "pinned SSH host keys are missing: $known_hosts" >&2
  exit 1
}
if [ -n "$key" ] && [ ! -f "$key" ]; then
  echo "MASH_APT_KEY points at $key, which does not exist" >&2
  exit 1
fi

shopt -s nullglob
debs=("$dist"/letsmash_*.deb "$dist"/letsmash-*.deb)
[ "${#debs[@]}" -gt 0 ] || {
  echo "no letsmash packages in $dist" >&2
  exit 1
}

ssh_opts=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$known_hosts"
  -o GlobalKnownHostsFile=/dev/null
)
[ -n "$key" ] && ssh_opts+=(-i "$key")
# rsync's -e accepts one string; shell-escape each argv item instead of joining
# raw values, so paths/options remain a single argument.
rsync_ssh=ssh
for opt in "${ssh_opts[@]}"; do
  printf -v escaped '%q' "$opt"
  rsync_ssh+=" $escaped"
done
case "$version" in
"" | *[!0-9A-Za-z.+-]*)
  echo "invalid release version: $version" >&2
  exit 1
  ;;
esac
publish_id="${version//+/_}-$(date -u +%Y%m%d%H%M%S)"
deb_amd64=""
deb_arm64=""

# Validate the complete local batch before contacting the server; malformed or
# half-built releases never create a production incoming directory.
for deb in "${debs[@]}"; do
  pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
  file_version="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
  case "$deb" in
  *_amd64.deb | *-linux-amd64.deb) arch=amd64 ;;
  *_arm64.deb | *-linux-arm64.deb) arch=arm64 ;;
  *)
    echo "cannot tell the architecture from $deb" >&2
    exit 1
    ;;
  esac
  if [ "$pkg" != "letsmash" ] || [ "$file_version" != "$version" ]; then
    echo "refusing $deb: expected letsmash=$version, got ${pkg:-unknown}=${file_version:-unknown}" >&2
    exit 1
  fi
  if [ "$arch" = amd64 ]; then
    [ -z "$deb_amd64" ] || {
      echo "refusing duplicate amd64 packages" >&2
      exit 1
    }
    deb_amd64="$deb"
  else
    [ -z "$deb_arm64" ] || {
      echo "refusing duplicate arm64 packages" >&2
      exit 1
    }
    deb_arm64="$deb"
  fi
done
[ -n "$deb_amd64" ] && [ -n "$deb_arm64" ] || {
  echo "refusing to publish: both amd64 and arm64 packages are required" >&2
  exit 1
}

incoming="${repo_root}/incoming/${publish_id}"
remote_started=0
cleanup() {
  if [ "$remote_started" = 1 ]; then
    ssh "${ssh_opts[@]}" "${user}@${host}" "rm -rf '$incoming'" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
tmp="$(mktemp -d)"
trap cleanup EXIT

ssh "${ssh_opts[@]}" "${user}@${host}" "mkdir -p '$incoming'"
remote_started=1
for arch in amd64 arm64; do
  if [ "$arch" = amd64 ]; then deb="$deb_amd64"; else deb="$deb_arm64"; fi
  echo "staging $(basename "$deb") ($arch) as batch $publish_id"
  rsync -a --chmod=F644 -e "$rsync_ssh" "$deb" "${user}@${host}:${incoming}/"
done
# One host-side lock and one reprepro export publish both architectures as one
# release. A failed second transfer/import cannot expose an amd64-only candidate.
ssh "${ssh_opts[@]}" "${user}@${host}" "$import_bin '$suite' '$publish_id'"
remote_started=0

# A successful SSH import is not sufficient: verify the public HTTPS surfaces
# end-to-end, including that this package's embedded key accepts the signature.
keyring="packaging/linux/letsmash-archive-keyring.gpg"
curl -fsS --max-time 30 "https://${host}/dists/${suite}/InRelease" -o "$tmp/InRelease"
gpgv --keyring "$keyring" "$tmp/InRelease"

for arch in amd64 arm64; do
  packages="$tmp/Packages-${arch}.gz"
  curl -fsS --max-time 30 "https://${host}/dists/${suite}/main/binary-${arch}/Packages.gz" -o "$packages"
  python3 - "$packages" "$version" "$arch" <<'PY'
import gzip, sys
path, want_version, want_arch = sys.argv[1:]
text = gzip.open(path, "rt", encoding="utf-8").read()
for paragraph in text.strip().split("\n\n"):
    fields = {}
    for line in paragraph.splitlines():
        if ": " in line:
            key, value = line.split(": ", 1)
            fields[key] = value
    if fields.get("Package") == "letsmash" and fields.get("Version") == want_version and fields.get("Architecture") == want_arch:
        break
else:
    raise SystemExit(f"letsmash={want_version} ({want_arch}) missing from signed package index")
print(f"verified letsmash={want_version} ({want_arch}) in package index")
PY
done

echo "published and verified letsmash=$version at https://${host}/ (suite ${suite})"
