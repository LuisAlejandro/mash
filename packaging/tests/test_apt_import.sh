#!/bin/bash
# Batch importer contract: validate both architectures, update under one lock,
# export once after both succeed, and never publish a partial release.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
importer="$root/packaging/apt/import-incoming.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mockbin="$tmp/bin"
repo="$tmp/repo"
state="$tmp/state"
mkdir -p "$mockbin" "$repo/incoming/release-a" "$repo/incoming/release-b" "$state"

cat >"$mockbin/dpkg-deb" <<'SH'
#!/bin/sh
file="$2"
field="$3"
case "$file" in
  *amd64.deb) arch=amd64 ;;
  *arm64.deb) arch=arm64 ;;
  *) exit 2 ;;
esac
case "$file" in
  *0.1.0*) version=0.1.0 ;;
  *0.2.0*) version=0.2.0 ;;
  *) version=0.0.0 ;;
esac
case "$field" in
  Package) echo letsmash ;;
  Version) echo "$version" ;;
  Architecture) echo "$arch" ;;
  *) exit 2 ;;
esac
SH

# macOS's base system has no flock utility. Emulate its critical-section
# lifetime with an exclusive mkdir held until the importing parent exits; this
# lets the repository's configured test runner prove overlapping batches
# serialize without installing a tool.
cat >"$mockbin/flock" <<'SH'
#!/bin/sh
lock="$MOCK_STATE/flock.lock"
owner="$PPID"
while ! mkdir "$lock" 2>/dev/null; do
  old="$(cat "$lock/owner" 2>/dev/null || true)"
  if [ -n "$old" ] && ! kill -0 "$old" 2>/dev/null; then
    rm -rf "$lock"
  else
    sleep 0.02
  fi
done
printf '%s\n' "$owner" >"$lock/owner"
(
  while kill -0 "$owner" 2>/dev/null; do sleep 0.02; done
  rm -rf "$lock"
) >/dev/null 2>&1 &
exit 0
SH

cat >"$mockbin/reprepro" <<'SH'
#!/bin/bash
set -euo pipefail
args=("$@")
arch=""
cmd=""
idx=0
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = "-A" ]; then arch="${args[$((i + 1))]}"; fi
  case "${args[$i]}" in list | remove | includedeb | export) cmd="${args[$i]}"; idx="$i"; break ;; esac
done
case "$cmd" in
  list)
    pkg="${args[$((idx + 2))]}"
    for a in amd64 arm64; do
      [ -n "$arch" ] && [ "$a" != "$arch" ] && continue
      f="$MOCK_STATE/$pkg.$a"
      [ -f "$f" ] && printf 'noble|main|%s: %s %s\n' "$a" "$pkg" "$(cat "$f")"
    done
    ;;
  remove)
    pkg="${args[$((idx + 2))]}"
    for a in amd64 arm64; do
      [ -n "$arch" ] && [ "$a" != "$arch" ] && continue
      rm -f "$MOCK_STATE/$pkg.$a"
    done
    ;;
  includedeb)
    deb="${args[$((idx + 2))]}"
    a="$(basename "$deb" | grep -oE '(amd64|arm64)\.deb$' | sed 's/\.deb//')"
    version="$(dpkg-deb -f "$deb" Version)"
    [ "${FAIL_ARCH:-}" != "$a" ] || exit 1
    printf '%s\n' "$version" >"$MOCK_STATE/letsmash.$a"
    ;;
  export)
    count=0
    [ ! -f "$MOCK_STATE/exports" ] || count="$(cat "$MOCK_STATE/exports")"
    printf '%s\n' "$((count + 1))" >"$MOCK_STATE/exports"
    ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$mockbin/dpkg-deb" "$mockbin/flock" "$mockbin/reprepro"

failures=0
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
ok() { printf 'ok    %s\n' "$1"; }

make_batch() {
  local batch="$1" version="$2"
  mkdir -p "$repo/incoming/$batch"
  : >"$repo/incoming/$batch/letsmash-${version}-linux-amd64.deb"
  : >"$repo/incoming/$batch/letsmash-${version}-linux-arm64.deb"
}
run_import() {
  PATH="$mockbin:$PATH" MOCK_STATE="$state" REPO_ROOT="$repo" \
    INCOMING="$repo/incoming" GNUPGHOME="$tmp/gnupg" PUBLISH_LOCK="$repo/.lock" \
    "$importer" noble "$1"
}

make_batch release-a 0.1.0
if run_import release-a >"$tmp/first.log" 2>&1; then
  ok "both architectures imported in one batch"
else
  fail "first batch import failed"
  tail -4 "$tmp/first.log" | sed 's/^/      /'
fi
[ "$(cat "$state/letsmash.amd64" 2>/dev/null)" = 0.1.0 ] && ok "amd64 indexed" || fail "amd64 missing"
[ "$(cat "$state/letsmash.arm64" 2>/dev/null)" = 0.1.0 ] && ok "arm64 indexed" || fail "arm64 missing"
[ "$(cat "$state/exports" 2>/dev/null)" = 1 ] && ok "one export after both imports" || fail "expected one export"
[ ! -d "$repo/incoming/release-a" ] && ok "batch staging cleaned" || fail "staging remains"

make_batch release-b 0.1.0
if run_import release-b >"$tmp/replace.log" 2>&1; then
  ok "same-version retry succeeds"
else
  fail "same-version retry failed"
fi
[ "$(cat "$state/exports" 2>/dev/null)" = 2 ] && ok "retry exports once" || fail "retry export count wrong"
[ "$(cat "$state/letsmash.amd64" 2>/dev/null)" = 0.1.0 ] &&
  [ "$(cat "$state/letsmash.arm64" 2>/dev/null)" = 0.1.0 ] &&
  ok "same-version replacement retains both architectures" || fail "replacement lost an architecture"

make_batch incomplete 0.2.0
rm -f "$repo/incoming/incomplete/letsmash-0.2.0-linux-arm64.deb"
if run_import incomplete >"$tmp/incomplete.log" 2>&1; then
  fail "incomplete batch was accepted"
else
  ok "incomplete batch rejected before reprepro"
fi
[ "$(cat "$state/exports" 2>/dev/null)" = 2 ] && ok "incomplete batch did not export" || fail "incomplete batch changed indices"

make_batch failed-import 0.2.0
if FAIL_ARCH=arm64 run_import failed-import >"$tmp/failed-import.log" 2>&1; then
  fail "batch with a failed arm64 include was accepted"
else
  ok "failed second-architecture import aborts the batch"
fi
[ "$(cat "$state/exports" 2>/dev/null)" = 2 ] && ok "failed batch did not publish indices" || fail "failed batch exported partial indices"
make_batch failed-import 0.2.0
if run_import failed-import >"$tmp/retry.log" 2>&1; then
  ok "retry of failed batch succeeds"
else
  fail "retry of failed batch did not recover"
fi
[ "$(cat "$state/exports" 2>/dev/null)" = 3 ] && ok "retry exported once after both architectures" || fail "retry export count wrong"

if PATH="$mockbin:$PATH" MOCK_STATE="$state" REPO_ROOT="$repo" INCOMING="$repo/incoming" \
  "$importer" noble '../../etc' >"$tmp/path.log" 2>&1; then
  fail "path traversal accepted"
else
  ok "path traversal rejected"
fi

# Two independent complete releases may arrive concurrently. The mock flock
# holds an exclusive lock until each importer process exits.
make_batch concurrent-a 0.2.0
make_batch concurrent-b 0.2.0
run_import concurrent-a >"$tmp/concurrent-a.log" 2>&1 &
p1=$!
run_import concurrent-b >"$tmp/concurrent-b.log" 2>&1 &
p2=$!
wait "$p1"
r1=$?
wait "$p2"
r2=$?
[ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && ok "concurrent release batches serialize" || fail "concurrent publish failed"
[ "$(cat "$state/exports" 2>/dev/null)" = 5 ] && ok "each successful batch exported once" || fail "concurrent export count wrong"

if [ "$failures" -eq 0 ]; then
  echo "test_apt_import: PASSED"
  exit 0
fi
echo "test_apt_import: FAILED ($failures problem(s))"
exit 1
