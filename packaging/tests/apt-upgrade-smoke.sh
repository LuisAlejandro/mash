#!/bin/bash
# Prove that an installed machine can actually upgrade Mash from the repository.
#
#   packaging/tests/apt-upgrade-smoke.sh [--deb dist/letsmash_<version>_<arch>.deb]
#
# Runs on Linux (CI's ubuntu runner, or an ubuntu container on a maintainer
# machine). Two things are checked, in order:
#
#   1. The repository answers, and its signed index verifies against the keyring
#      the package ships. This is the one link no unit test can reach: the
#      signature is made on the host and trusted on the client.
#   2. apt resolves letsmash as upgradable.
#   3. With --deb <package> --install-system, install that package into the
#      current Linux system, then prove the source/keyring and a subsequent
#      --only-upgrade. That mode deliberately writes /etc and requires a
#      throwaway Ubuntu container or VM; it is never used by the default check.
#
# The default mode is read-only with respect to host APT configuration and
# caches: it uses a temporary sources file and temporary list/cache directories.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
HOST=apt.letsma.sh
SUITE=noble
KEYRING="$root/packaging/linux/letsmash-archive-keyring.gpg"
deb=""
install_system=0

while [ "$#" -gt 0 ]; do
  case "$1" in
  --deb)
    deb="${2:?--deb needs a path}"
    shift 2
    ;;
  --install-system)
    install_system=1
    shift
    ;;
  *)
    echo "unknown argument: $1" >&2
    exit 2
    ;;
  esac
done
[ "$install_system" = 0 ] || [ -n "$deb" ] || {
  echo "--install-system requires --deb and a throwaway Ubuntu container/VM" >&2
  exit 2
}

[ "$(uname -s)" = "Linux" ] || {
  echo "this proof runs on Linux; use an ubuntu:24.04 container on macOS" >&2
  exit 2
}
[ -f "$KEYRING" ] || {
  echo "missing the shipped keyring: $KEYRING" >&2
  exit 1
}

failures=0
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
ok() { printf 'ok    %s\n' "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sources="$tmp/letsmash.list"
apt_state="$tmp/apt-state"
apt_cache="$tmp/apt-cache"
mkdir -p "$apt_state/lists/partial" "$apt_cache/archives/partial"
cat >"$sources" <<EOF
deb [signed-by=$KEYRING] https://$HOST $SUITE main
EOF

apt_get() {
  apt-get -o Dir::Etc::SourceList="$sources" \
    -o Dir::Etc::SourceParts="-" \
    -o Dir::State::lists="$apt_state/lists" \
    -o Dir::State::status=/var/lib/dpkg/status \
    -o Dir::Cache="$apt_cache" \
    -o APT::Get::List-Cleanup="0" \
    -o Debug::NoLocking="1" \
    "$@"
}

echo "=== the repository answers"
release="$tmp/InRelease"
if curl -fsS --max-time 20 "https://$HOST/dists/$SUITE/InRelease" -o "$release"; then
  ok "InRelease fetched over TLS"
else
  fail "InRelease is not reachable over TLS"
fi

echo "=== the shipped keyring verifies the index"
if [ -s "$release" ]; then
  if gpgv --keyring "$KEYRING" "$release" >/dev/null 2>"$tmp/gpg.err"; then
    ok "signature verifies against packaging/linux/letsmash-archive-keyring.gpg"
    grep -m1 'using' "$tmp/gpg.err" | sed 's/^/      /'
  else
    fail "the shipped keyring does not verify the index"
    sed 's/^/      /' "$tmp/gpg.err" | head -3
  fi
fi

echo "=== apt sees a candidate"
if apt_get update >"$tmp/update.log" 2>&1; then
  ok "apt update accepts the source"
else
  fail "apt update rejected the source"
  grep -iE 'err|warn' "$tmp/update.log" | head -3 | sed 's/^/      /'
fi
policy="$(apt-cache -o Dir::Etc::SourceList="$sources" -o Dir::Etc::SourceParts="-" \
  -o Dir::State::lists="$apt_state/lists" -o Dir::State::status=/var/lib/dpkg/status \
  -o Dir::Cache="$apt_cache" policy letsmash 2>/dev/null)"
if printf '%s' "$policy" | grep -q "$HOST"; then
  ok "letsmash resolves from $HOST"
  printf '%s\n' "$policy" | grep -E 'Candidate|500 https' | head -2 | sed 's/^/      /'
else
  fail "letsmash does not resolve from $HOST (no package published yet?)"
fi

if [ "$install_system" = 1 ]; then
  echo "=== installing package into this disposable Linux system"
  [ -f "$deb" ] || {
    fail "no such package: $deb"
    exit 1
  }
  if apt-get update >"$tmp/system-update.log" 2>&1 &&
    apt-get install -y "$deb" >"$tmp/dpkg.log" 2>&1; then
    ok "package installed"
  else
    fail "package did not install"
    tail -3 "$tmp/dpkg.log" "$tmp/system-update.log" 2>/dev/null | sed 's/^/      /'
  fi
  if [ -f /etc/apt/sources.list.d/letsmash.sources ]; then
    ok "install configured the repository source"
    grep -qx "URIs: https://$HOST" /etc/apt/sources.list.d/letsmash.sources &&
      ok "source names $HOST" || fail "source does not name $HOST"
  else
    fail "install did not write /etc/apt/sources.list.d/letsmash.sources"
  fi
  if [ -f /usr/share/keyrings/letsmash-archive-keyring.gpg ]; then
    ok "the package shipped the keyring"
  else
    fail "the package did not install its keyring"
  fi
  echo "=== update indices using the package-installed source and keyring"
  if apt-get update >"$tmp/system-update.log" 2>&1; then
    ok "system apt update accepted the package-installed source"
  else
    fail "system apt update rejected the package-installed source"
    grep -iE 'err|warn' "$tmp/system-update.log" | tail -3 | sed 's/^/      /'
  fi
  echo "=== already-current upgrade is a no-op"
  if apt-get install --only-upgrade -y letsmash >"$tmp/upgrade.log" 2>&1; then
    ok "--only-upgrade completed"
  else
    fail "--only-upgrade failed"
    tail -3 "$tmp/upgrade.log" | sed 's/^/      /'
  fi
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "apt-upgrade-smoke: PASSED"
  exit 0
fi
echo "apt-upgrade-smoke: FAILED ($failures problem(s))"
exit 1
