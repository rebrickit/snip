#!/bin/bash
set -euo pipefail
SNIP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SNIP_ROOT"
export CLANG_MODULE_CACHE_PATH="$SNIP_ROOT/build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$SNIP_ROOT/build/ModuleCache"
# --disable-sandbox allows SwiftPM to run within an existing managed sandbox.
# This package has no external dependencies or build plugins.
swift test --disable-sandbox --scratch-path "$SNIP_ROOT/build/swift" \
    --cache-path "$SNIP_ROOT/build/swift-cache" --config-path "$SNIP_ROOT/build/swift-config" \
    --security-path "$SNIP_ROOT/build/swift-security" "$@"

