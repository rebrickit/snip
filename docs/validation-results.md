# Validation — 2026-11-02

Environment: Apple silicon Mac, macOS 27.0.1, Xcode 27.0, Swift 6.4. Deployment target: macOS 15.0.

- **Passed:** 22 Swift Testing tests, including permission routing and recovery classification, all eight region resize handles, region movement and boundary clamping, edited-region capture coordinates, real H.264/AAC encoding and decoding, two-source audio mixing at 44.1/48 kHz, a microphone starting 100 ms late, static-video duration, empty/repeated finalization, capture state transitions, multi-display coordinates, and collision-safe filenames.
- **Passed:** Debug build and universal Release build (`x86_64 arm64`).
- **Passed:** local ad hoc code-signature verification and plist/project validation.
- **Passed:** final local DMG checksum verification, read-only mount, packaged universal app signature, and Applications shortcut. The verification volume was detached afterward; a SHA-256 checksum accompanies the DMG.
- **Passed:** native panel and resizable region overlay rendered off-screen and visually inspected for layout, including the eight handles and confirmation buttons. This is not an interactive capture test.
- **Passed:** release script refuses to proceed without a configured release identity.
- **Passed:** local build script preserves the Xcode signing configuration by default and passes explicit signing identity, team, and bundle identifier overrides intact.

The permission regression tests inject capture-framework results; they do not grant or reset OS permissions. Actual grant/revoke behavior, permission-pane navigation, and the Restart Snip action still require interactive verification. ScreenCaptureKit is now the authorization check for region/system-audio actions, rather than a Core Graphics preflight-only rejection. The local binary remains ad hoc signed because no signing certificate is installed; old grants can still require manual reassignment after rebuilding.

The workspace sandbox blocks native media codecs, drawing, and disk-image services. The media tests, off-screen rendering, and packaging were therefore run with those local services available. Compiler macros used the documented `SNIP_EXTRA_SWIFT_FLAGS=-disable-sandbox` build option within the workspace sandbox.

Interactive computer inspection timed out. Real screen/microphone capture, OS permission prompts, external devices, long-duration recording, macOS 15 runtime behavior, and Intel runtime behavior still require the [manual checks](verification.md). Universal compilation does not establish runtime validation on those systems.

Developer ID signing and notarization were not run: no signing identity was available, and the agreed deliverable is release tooling with credentials supplied later. The local DMG must not be represented as a notarized public release.
