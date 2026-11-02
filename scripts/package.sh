#!/bin/bash
set -euo pipefail
SNIP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIP_APP="${1:-$SNIP_ROOT/build/DerivedData/Build/Products/Release/Snip.app}"
SNIP_OUTPUT="${2:-$SNIP_ROOT/dist/Snip-0.1.0-local.dmg}"
if [[ ! -d "$SNIP_APP" ]]; then echo "App not found: $SNIP_APP. Run scripts/build.sh Release first." >&2; exit 1; fi
mkdir -p "$SNIP_ROOT/build" "$(dirname "$SNIP_OUTPUT")"
SNIP_STAGE="$(mktemp -d "$SNIP_ROOT/build/dmg.XXXXXX")"
trap 'rm -rf "$SNIP_STAGE"' EXIT
ditto "$SNIP_APP" "$SNIP_STAGE/Snip.app"
ln -s /Applications "$SNIP_STAGE/Applications"
hdiutil create -volname Snip -srcfolder "$SNIP_STAGE" -format UDZO -ov "$SNIP_OUTPUT"
printf '\nPackaged: %s\n' "$SNIP_OUTPUT"

