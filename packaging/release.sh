#!/bin/bash
# Stranger download. Refuses before any build when signing or notarization
# credentials are missing. Does not publish.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "No Developer ID Application identity. Refusing to assemble a stranger download." >&2
    exit 1
fi
if [ -z "${MASH_NOTARY_KEYCHAIN_PROFILE:-}" ] && { [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${APPLE_APP_PASSWORD:-}" ]; }; then
    echo "No notarization credentials. Refusing to assemble a stranger download." >&2
    exit 1
fi

"$root/packaging/build.sh"
download="$root/dist/download"
rm -rf "$download"
mkdir -p "$download"
ditto "$root/dist/Mash.app" "$download/Mash.app"
cp "$root/dist/fresh-0.5.1-patched.tar.gz" "$download/fresh-0.5.1-patched.tar.gz"
cp "$root/packaging/fresh-gpl-notice.txt" "$download/FRESH-LICENSE.txt"
codesign --force --deep --sign "Developer ID Application" "$download/Mash.app"
ditto -c -k --keepParent "$download/Mash.app" "$download/Mash.zip"
if [ -n "${MASH_NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    xcrun notarytool submit "$download/Mash.zip" --keychain-profile "$MASH_NOTARY_KEYCHAIN_PROFILE" --wait
else
    xcrun notarytool submit "$download/Mash.zip" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --wait
fi
xcrun stapler staple "$download/Mash.app"
rm -f "$download/Mash.zip"
echo "stranger download is in $download"
