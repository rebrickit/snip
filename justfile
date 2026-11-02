set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

release_app := "build/DerivedData/Build/Products/Release/Snip.app"
local_dmg := "Snip-0.1.0-local.dmg"

# List available commands.
default:
    @just --list

# Build the app with Swift warnings treated as errors (Debug or Release).
build configuration="Debug":
    SNIP_EXTRA_SWIFT_FLAGS="${SNIP_EXTRA_SWIFT_FLAGS:-} -warnings-as-errors" ./scripts/build.sh "$1"

# Run all Swift tests; additional swift test arguments are forwarded intact.
test *args:
    ./scripts/test.sh -Xswiftc -warnings-as-errors "$@"

# Validate workflows, shell scripts, project metadata, and justfile formatting.
lint:
    just --unstable --fmt --check
    actionlint .github/workflows/*.yml
    shellcheck scripts/*.sh
    for script in scripts/*.sh; do bash -n "$script"; done
    plutil -lint Resources/Info.plist Resources/Snip.entitlements Snip.xcodeproj/project.pbxproj
    xmllint --noout Snip.xcodeproj/xcshareddata/xcschemes/Snip.xcscheme
    git diff --check

# Verify an existing app's signature and metadata, plus both Release architectures.
verify-app configuration="Release":
    codesign --verify --deep --strict "build/DerivedData/Build/Products/$1/Snip.app"
    plutil -lint "build/DerivedData/Build/Products/$1/Snip.app/Contents/Info.plist"
    # Check separately: Xcode 27's lipo rejects multiple -verify_arch arguments.
    if [[ "$1" == Release ]]; then for arch in arm64 x86_64; do lipo "{{ release_app }}/Contents/MacOS/Snip" -verify_arch "$arch"; done; fi

# Build and verify the universal app, then create and validate a local DMG.
package: (build "Release") (verify-app "Release")
    ./scripts/package.sh "{{ release_app }}" "dist/{{ local_dmg }}"
    hdiutil verify "dist/{{ local_dmg }}"
    cd dist && shasum -a 256 "{{ local_dmg }}" > "{{ local_dmg }}.sha256"

# Run the same validation as GitHub Actions on this Mac.
ci: lint test (build "Debug") (verify-app "Debug") package

# Sign and notarize using the SNIP_* credentials documented in README.md.
release:
    ./scripts/release.sh
