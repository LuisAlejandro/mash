#!/bin/bash
# Stranger download. Refuses before any build when signing or notarization
# credentials are missing. Does not publish. Produces a signed, notarized,
# stapled Mash.dmg with the app, a /Applications shortcut, the Fresh source
# tarball, and the Fresh GPL notice.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so CI or another maintainer can select a different imported
# identity. In this repo CI imports the maintainer's cert, whose common name
# includes both the maintainer name and APPLE_TEAM_ID.
if [ -z "${MASH_SIGN_IDENTITY:-}" ]; then
    if [ -n "${APPLE_TEAM_ID:-}" ]; then
        MASH_SIGN_IDENTITY="Developer ID Application: Luis Alejandro Martínez Faneyth ($APPLE_TEAM_ID)"
    else
        MASH_SIGN_IDENTITY="Developer ID Application: Luis Alejandro Martínez Faneyth (4SCJW6LZ6T)"
    fi
fi
identity="$MASH_SIGN_IDENTITY"
dist="$root/dist"
download="$dist/download"

# Load Apple credentials from the repo-root .env when not already in the
# environment. The file holds APPLE_ID, APPLE_TEAM_ID and
# APPLE_APP_SPECIFIC_PASSWORD and is gitignored.
if [ -f "$root/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$root/.env"
    set +a
fi
# Accept either name for the app-specific password.
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:-${APPLE_APP_SPECIFIC_PASSWORD:-}}"

# In CI the identity is imported into a throwaway keychain that may not be in
# the default search list, so make sure it is searched before looking for it.
# The workflow locks that keychain 3600s after import. The Intel build now
# takes longer than that, so Developer ID signing began against a locked
# keychain and codesign waited on a dialog nobody can answer. Unlock again
# immediately before signing, and keep it unlocked for the rest of the job.
mash_unlock_signing_keychain() {
    [ -n "${MASH_KEYCHAIN:-}" ] || return 0
    security list-keychains -d user -s "$MASH_KEYCHAIN" $(security list-keychains -d user | tr -d '"') 2>/dev/null || true
    security set-keychain-settings -lut 21600 "$MASH_KEYCHAIN"
    security unlock-keychain -p "${MASH_KEYCHAIN_PASSWORD:-}" "$MASH_KEYCHAIN"
    echo "signing keychain unlocked"
}
mash_unlock_signing_keychain

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "No Developer ID Application identity. Refusing to assemble a stranger download." >&2
    exit 1
fi
if [ -z "${MASH_NOTARY_KEYCHAIN_PROFILE:-}" ] && { [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${APPLE_APP_PASSWORD:-}" ]; }; then
    echo "No notarization credentials. Refusing to assemble a stranger download." >&2
    echo "Run: xcrun notarytool store-credentials mash" >&2
    exit 1
fi
for cmd in SetFile; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "$cmd is required to lay out the branded disk image." >&2
        exit 1
    }
done

# 1. Build the app bundle (ad-hoc signed inside; we re-sign below). Set
# MASH_SKIP_BUILD=1 to repackage an already-built app after signing fixes.
if [ "${MASH_SKIP_BUILD:-0}" = "1" ]; then
    [ -d "$dist/Mash.app" ] || { echo "dist/Mash.app is missing." >&2; exit 1; }
else
    "$root/packaging/build.sh"
fi

# 2. Stage the disk image contents.
rm -rf "$download"
mkdir -p "$download"
ditto "$dist/Mash.app" "$download/Mash.app"
cp "$dist/fresh-0.5.1-patched.tar.gz" "$download/fresh-0.5.1-patched.tar.gz"
cp "$root/packaging/fresh-gpl-notice.txt" "$download/FRESH-LICENSE.txt"
ln -s /Applications "$download/Applications"
# Printed because this stage has no other output: a silent gap after the build
# is indistinguishable from a stall, which is exactly how a wedged signing run
# went unnoticed until the job's timeout killed it.
echo "staged the bundle for signing"
mash_unlock_signing_keychain

# 3. Developer ID sign every piece of code in the bundle, innermost first.
# codesign --deep only reaches nested code in the standard locations
# (Contents/MacOS, Frameworks, PlugIns, XPCServices); everything parked under
# Contents/Resources - the bundled tools, node_modules, the notifier - keeps
# whatever ad-hoc signature build.sh left on it and the notary rejects the
# whole archive. Walk the tree explicitly instead.
# Every signature here is timestamped, which means every one depends on Apple's
# timestamp authority answering. It intermittently does not:
#
#     dist/Mash.dmg: The timestamp service is not available.
#
# That is not a signing error and the artifact is fine, so a few spaced retries
# recover it. Without them one unlucky response throws away a 45-minute build
# and blocks the release.
#
# The failure is not always an error, though: the same service sometimes hangs
# instead of answering, and then codesign waits without printing a line and
# never returns, so the retry below never runs and the job burns its whole
# timeout on one signature. alarm() survives exec, so the timer still fires
# inside codesign and turns a hang into a retryable failure.
codesign_deadline="${MASH_CODESIGN_TIMEOUT:-300}"
mash_codesign_bounded() {
    perl -e 'alarm shift @ARGV; exec @ARGV' "$codesign_deadline" codesign "$@"
}

mash_codesign() {
    local attempt=1 limit=4 delay=15
    while :; do
        if mash_codesign_bounded "$@"; then
            return 0
        fi
        [ "$attempt" -lt "$limit" ] || return 1
        echo "codesign failed or timed out after ${codesign_deadline}s (attempt $attempt of $limit); retrying in ${delay}s" >&2
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

sign_item() {
    local path="$1" ent="${2:-}"
    if [ -n "$ent" ]; then
        mash_codesign --force --options runtime --timestamp \
            --entitlements "$ent" --sign "$identity" "$path"
    else
        mash_codesign --force --options runtime --timestamp --sign "$identity" "$path"
    fi
}

candidates="$(mktemp)"
machos="$(mktemp)"
bundles="$(mktemp)"
dmg_mnt=""
scratch=""
cleanup() {
    if [ -n "$dmg_mnt" ]; then
        hdiutil detach "$dmg_mnt" >/dev/null 2>&1 || true
    fi
    rm -f "$candidates" "$machos" "$bundles"
    [ -z "$scratch" ] || rm -f "$scratch"
}
trap cleanup EXIT

# -perm -u+x and the library extensions are a cheap prefilter; `file` then
# confirms Mach-O, which also catches the .exe-named arm64 plugin binary.
find "$download/Mash.app" -type f \
    \( -perm -u+x -o -name '*.dylib' -o -name '*.so' -o -name '*.node' \) \
    >"$candidates"
# '|@|' cannot occur in a path, so the separator cut is unambiguous. A
# universal binary additionally emits one continuation line per slice in the
# form 'path (for architecture x86_64):<tab>type', which has to be unwrapped
# before deduping. Deepest first so nested seals are always computed over
# code that is already final.
file -F '|@|' -f "$candidates" | grep 'Mach-O' |
    sed -e 's/|@|.*//' -e 's/ (for architecture [^)]*):.*//' |
    sort -u | awk -F/ '{print NF"\t"$0}' | sort -rn | cut -f2- >"$machos"
echo "signing $(wc -l <"$machos" | tr -d ' ') binaries"

while IFS= read -r path; do
    case "$path" in
        # Node.js Foundation already ships this one Developer ID signed and
        # notarized. Re-signing it would drop the JIT entitlements V8 needs.
        "$download/Mash.app/Contents/Resources/node/bin/node") continue ;;
        "$download/Mash.app/Contents/Resources/python/"*)
            sign_item "$path" "$root/packaging/entitlements-python.plist" ;;
        *) sign_item "$path" ;;
    esac
done <"$machos"

# Nested bundles next, deepest first, then the app itself last.
find "$download/Mash.app" -depth -type d \
    \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' \
    -o -name '*.plugin' -o -name '*.bundle' \) >"$bundles"
echo "signing $(wc -l <"$bundles" | tr -d ' ') bundles"
while IFS= read -r path; do
    [ "$path" = "$download/Mash.app" ] || sign_item "$path"
done <"$bundles"
# The app last, over everything above. Its executable is the terminal, so this
# signature carries every TCC entitlement Mash and its panes need.
sign_item "$download/Mash.app" "$root/packaging/entitlements.plist"
echo "every binary and bundle is Developer ID signed"

# Verify. codesign --verify --deep stops at the same locations --deep signs,
# so each item is checked on its own. This is the check that would have caught
# the --deep run that produced an Invalid notarization.
while IFS= read -r path; do
    case "$path" in
        "$download/Mash.app/Contents/Resources/node/bin/node") continue ;;
    esac
    info="$(codesign -dvvv "$path" 2>&1)"
    codesign --verify --strict "$path" || {
        echo "signature does not verify: ${path#"$download"/}" >&2
        exit 1
    }
    grep -q '^Authority=Developer ID Application' <<<"$info" || {
        echo "not Developer ID signed: ${path#"$download"/}" >&2
        exit 1
    }
    grep -q 'flags=.*runtime' <<<"$info" || {
        echo "hardened runtime not enabled: ${path#"$download"/}" >&2
        exit 1
    }
    grep -q '^Timestamp=' <<<"$info" || {
        echo "no secure timestamp: ${path#"$download"/}" >&2
        exit 1
    }
done <"$machos"
while IFS= read -r path; do
    [ "$path" = "$download/Mash.app" ] && continue
    info="$(codesign -dvvv "$path" 2>&1)"
    codesign --verify --strict "$path" || {
        echo "signature does not verify: ${path#"$download"/}" >&2
        exit 1
    }
    grep -q '^Authority=Developer ID Application' <<<"$info" || {
        echo "not Developer ID signed: ${path#"$download"/}" >&2
        exit 1
    }
done <"$bundles"
codesign --verify --deep --strict --verbose=2 "$download/Mash.app"

# 4. Build the DMG.
#
# The volume gets Mash's icon: Finder reads `.VolumeIcon.icns` at the root,
# but only when the root also carries the `kHasCustomIcon` flag. The flag has
# to be set on a mounted image, because `hdiutil create` drops the staged
# folder's FinderInfo when it lays the filesystem out. So build read-write,
# mount, set both, then convert to compressed.
#
# The window itself is deliberately plain. A background picture and fixed icon
# positions live in a `.DS_Store`, which only Finder writes reliably, and
# driving Finder from a release script needs Automation permission that CI
# does not have. branding/dmg-background.png is kept for that future work.
rm -f "$dist/Mash.dmg"
cp "$root/packaging/Mash.icns" "$download/.VolumeIcon.icns"
scratch="$dist/.mash-dmg.rw.dmg"
rm -f "$scratch"
echo "building the disk image"
hdiutil create -volname "Mash" -srcfolder "$download" -ov -format UDRW "$scratch" >/dev/null
# hdiutil prints tab-separated columns, and the mount point is the last one.
# Splitting on whitespace loses it the moment the volume is named "/Volumes/Mash
# 1" -- which happens whenever another "Mash" volume is already mounted -- and
# leaves dmg_mnt holding just "1".
dmg_mnt="$(hdiutil attach -nobrowse "$scratch" |
    awk -F'	' 'NF > 2 && $NF ~ /^\// { print $NF }' | tail -1)"
case "$dmg_mnt" in
/*) ;;
*)
    echo "could not read the mount point of $scratch" >&2
    exit 1
    ;;
esac
SetFile -a C "$dmg_mnt/.VolumeIcon.icns"
SetFile -a C "$dmg_mnt"
sync
hdiutil detach "$dmg_mnt" >/dev/null
dmg_mnt=""
hdiutil convert "$scratch" -format UDZO -o "$dist/Mash.dmg" >/dev/null
rm -f "$scratch"
scratch=""
echo "disk image built"

# 5. Sign the disk image itself.
mash_codesign --force --timestamp --sign "$identity" "$dist/Mash.dmg"

# 6. Notarize the DMG and wait for Apple. `notarytool submit --wait` dies
# with SIGBUS while printing its progress on this archive, so submit without
# waiting and poll the submission instead.
if [ -n "${MASH_NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    notary_auth=(--keychain-profile "$MASH_NOTARY_KEYCHAIN_PROFILE")
else
    notary_auth=(
        --apple-id "$APPLE_ID"
        --team-id "$APPLE_TEAM_ID"
        --password "$APPLE_APP_PASSWORD"
    )
fi
submission="$(xcrun notarytool submit "$dist/Mash.dmg" "${notary_auth[@]}" \
    --no-wait --output-format json | plutil -extract id raw -o - -)"
[ -n "$submission" ] || { echo "notarytool did not return a submission id." >&2; exit 1; }
echo "notarization submission $submission"

state="In Progress"
for poll in $(seq 1 160); do
    state="$(xcrun notarytool info "$submission" "${notary_auth[@]}" \
        --output-format json | plutil -extract status raw -o - -)"
    [ "$state" = "In Progress" ] || break
    # One line per minute or so: silence here is indistinguishable from a stall.
    [ "$poll" -gt 1 ] && [ "$((poll % 4))" -ne 1 ] || echo "notarization $state (poll $poll)"
    sleep 15
done
echo "notarization ended as $state"
if [ "$state" != "Accepted" ]; then
    echo "notarization ended as $state" >&2
    xcrun notarytool log "$submission" "${notary_auth[@]}" || true
    exit 1
fi

# 7. Staple the ticket to the DMG so offline installs verify.
xcrun stapler staple "$dist/Mash.dmg"

# 8. Gatekeeper sanity check.
spctl --assess --type open --context context:primary-signature -v "$dist/Mash.dmg" || true

echo "stranger download is in $dist/Mash.dmg"
