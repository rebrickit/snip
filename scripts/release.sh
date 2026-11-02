#!/bin/bash
set -euo pipefail
SNIP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${SNIP_BUNDLE_ID:?Set SNIP_BUNDLE_ID to your permanent reverse-DNS app identifier}"
: "${SNIP_TEAM_ID:?Set SNIP_TEAM_ID to your Apple Developer team ID}"
: "${SNIP_SIGN_ID:?Set SNIP_SIGN_ID to your Developer ID Application signing identity}"
: "${SNIP_NOTARY_PROFILE:?Set SNIP_NOTARY_PROFILE to a notarytool Keychain profile}"
if [[ "$SNIP_BUNDLE_ID" == local.snip.app || "$SNIP_SIGN_ID" != 'Developer ID Application:'* ]]; then
    echo "Use a permanent bundle identifier and a Developer ID Application identity for distribution." >&2
    exit 2
fi
SNIP_ARCHIVE="$SNIP_ROOT/build/Snip.xcarchive"
SNIP_APP="$SNIP_ARCHIVE/Products/Applications/Snip.app"
mkdir -p "$SNIP_ROOT/dist"
xcodebuild -project "$SNIP_ROOT/Snip.xcodeproj" -scheme Snip -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$SNIP_ROOT/build/ReleaseDerivedData" \
    -archivePath "$SNIP_ARCHIVE" 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    "PRODUCT_BUNDLE_IDENTIFIER=$SNIP_BUNDLE_ID" "DEVELOPMENT_TEAM=$SNIP_TEAM_ID" \
    "CODE_SIGN_IDENTITY=$SNIP_SIGN_ID" OTHER_CODE_SIGN_FLAGS=--timestamp \
    "OTHER_SWIFT_FLAGS=${SNIP_EXTRA_SWIFT_FLAGS:-}" \
    "CLANG_MODULE_CACHE_PATH=$SNIP_ROOT/build/ModuleCache" archive
codesign --verify --deep --strict "$SNIP_APP"
SNIP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SNIP_APP/Contents/Info.plist")"
SNIP_ZIP="$SNIP_ROOT/build/Snip-notarization.zip"
SNIP_DMG="$SNIP_ROOT/dist/Snip-$SNIP_VERSION.dmg"
ditto -c -k --keepParent "$SNIP_APP" "$SNIP_ZIP"
xcrun notarytool submit "$SNIP_ZIP" --keychain-profile "$SNIP_NOTARY_PROFILE" --wait
xcrun stapler staple "$SNIP_APP"
"$SNIP_ROOT/scripts/package.sh" "$SNIP_APP" "$SNIP_DMG"
codesign --sign "$SNIP_SIGN_ID" --timestamp "$SNIP_DMG"
xcrun notarytool submit "$SNIP_DMG" --keychain-profile "$SNIP_NOTARY_PROFILE" --wait
xcrun stapler staple "$SNIP_DMG"
xcrun stapler validate "$SNIP_APP"
xcrun stapler validate "$SNIP_DMG"
spctl --assess --type execute --verbose "$SNIP_APP"
shasum -a 256 "$SNIP_DMG" > "$SNIP_DMG.sha256"
printf '\nReady for distribution: %s\n' "$SNIP_DMG"
