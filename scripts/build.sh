#!/bin/bash
set -euo pipefail
SNIP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIP_CONFIGURATION="${1:-Debug}"
case "$SNIP_CONFIGURATION" in Debug|Release) ;; *) echo "Usage: $0 [Debug|Release]" >&2; exit 2;; esac
SNIP_ARCHS="$(uname -m)"
if [[ "$SNIP_CONFIGURATION" == Release ]]; then SNIP_ARCHS="arm64 x86_64"; fi
SNIP_SIGNING_ARGS=()
if [[ -n "${SNIP_SIGN_ID:-}" ]]; then SNIP_SIGNING_ARGS+=("CODE_SIGN_IDENTITY=$SNIP_SIGN_ID"); fi
if [[ -n "${SNIP_TEAM_ID:-}" ]]; then SNIP_SIGNING_ARGS+=("DEVELOPMENT_TEAM=$SNIP_TEAM_ID"); fi
if [[ -n "${SNIP_BUNDLE_ID:-}" ]]; then SNIP_SIGNING_ARGS+=("PRODUCT_BUNDLE_IDENTIFIER=$SNIP_BUNDLE_ID"); fi
xcodebuild -project "$SNIP_ROOT/Snip.xcodeproj" -scheme Snip \
    -configuration "$SNIP_CONFIGURATION" -derivedDataPath "$SNIP_ROOT/build/DerivedData" \
    -destination 'generic/platform=macOS' \
    "ARCHS=$SNIP_ARCHS" ONLY_ACTIVE_ARCH=NO ${SNIP_SIGNING_ARGS[@]+"${SNIP_SIGNING_ARGS[@]}"} \
    "OTHER_SWIFT_FLAGS=${SNIP_EXTRA_SWIFT_FLAGS:-}" \
    "CLANG_MODULE_CACHE_PATH=$SNIP_ROOT/build/ModuleCache" build
printf '\nBuilt: %s\n' "$SNIP_ROOT/build/DerivedData/Build/Products/$SNIP_CONFIGURATION/Snip.app"

