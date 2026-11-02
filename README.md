# Snip

A native macOS menu bar utility for screenshots, screen recording, and audio recording. Requires **Apple silicon and macOS 15 or later**. Built with Swift 6, SwiftUI, AppKit, ScreenCaptureKit, and AVFoundation; no third-party dependencies, accounts, uploads, or analytics.

## Build and run

Install Xcode 16 or later and select it with `xcode-select`. Install the command runner with `brew install just`. Open `Snip.xcodeproj` and run the **Snip** scheme, or use:

```sh
just build
open build/DerivedData/Build/Products/Debug/Snip.app
```

The app opens a menu bar panel. It has no Dock icon. Local builds use an ad hoc signature and the bundle identifier `local.snip.app`; no Apple Developer membership is needed to build locally. Use a stable location and signing identity when testing privacy permissions. Rebuilding an ad hoc app can cause macOS to ask for permission again.

If you have an installed Apple Development certificate, set it in the Xcode target or pass `SNIP_SIGN_ID='Apple Development: Your Name (TEAMID)' SNIP_TEAM_ID=TEAMID just build`. The build script honors the project's signing configuration when these overrides are absent; it no longer forces ad hoc signing over a configured certificate. Keep the bundle identifier and signing identity stable across builds to retain macOS permission grants.

In an already sandboxed development environment, Swift's compiler macro sandbox may fail to start. For that environment only:

```sh
SNIP_EXTRA_SWIFT_FLAGS=-disable-sandbox just build
```

## Capture

- **Screenshot:** choose Display, Window, or Region. Display/window uses the system picker. For Region, draw a rectangle, drag any edge or corner to resize it, and drag inside to move it. Press Return or click **Capture** when ready; Escape cancels. Saves a PNG at native pixel resolution, with Open, Show in Finder, and Copy actions.
- **Video:** choose the same capture areas and enable optional System audio and/or Microphone. Region selection can be resized and moved before you press Return or click **Record** to start the three-second countdown. The region stays fixed during recording. Stop from the panel or global shortcut. Saves a 30 fps SDR H.264 MP4 with an even-sized frame and a maximum 3840-pixel long edge. Static desktop frames are held until Stop.
- **Audio:** enable System audio, Microphone, or both. Saves an AAC M4A with no video track. Microphone-only mode does not require screen access.
- Both enabled audio sources are mixed into one stereo track with equal headroom. System audio is independent of the video window selection and excludes Snip's own output. The microphone follows the default input selected in macOS Sound settings.
- Captures save automatically to `~/Movies/Snip`. Change the folder and audio/cursor defaults in Settings. Filenames never overwrite an existing capture.

| Shortcut | Action |
| --- | --- |
| Control–Option–Command–S | Screenshot |
| Control–Option–Command–R | Screen recording |
| Control–Option–Command–A | Audio recording |
| Control–Option–Command–X | Stop recording or cancel selection/countdown |

Only one operation runs at a time. Menu bar status shows the countdown, recording time, and finalization state. Quitting finishes an active recording before the app exits. Sleep, capture interruption, or a disconnected microphone ends recording and attempts to save usable media.

Permissions are requested when used. Region capture and desktop audio require **System Settings → Privacy & Security → Screen & System Audio Recording**. Microphone recording requires **Microphone** access. Follow any macOS request to quit and reopen the app after changing permissions. Protected content can be omitted by macOS.

If capture fails even though access is enabled:

1. Quit older copies and run one copy of `Snip.app` from a stable location, preferably Applications. Launch the app with Finder or `open`, rather than directly running its executable.
2. Use the error's **Screen Recording Settings** or **Microphone Settings** button, then **Restart Snip** after changing access.
3. If you replaced/rebuilt the local ad hoc app, the enabled Screen Recording entry may belong to the previous build. Remove that entry in System Settings and add the current app again; **Show This App** reveals the exact copy. Restart it afterward. This does not require granting Full Disk Access or Accessibility access.

Snip now checks screen authorization through ScreenCaptureKit itself instead of rejecting capture based only on the Core Graphics preflight result. Encoder, disk, and source errors retain their own messages and do not show misleading permission recovery buttons. Permission recovery never resets macOS permissions automatically. [Apple explains why ad hoc rebuilds can lose authorization](https://developer.apple.com/forums/thread/819406).

Recordings are streamed into a hidden `.snip-<UUID>` working directory inside the capture folder. Finalization mixes audio and copies encoded video without recompressing it. Successful captures remove their working directory. A failure preserves any recoverable `.mov` and displays its path; Finder's Command–Shift–Period shows hidden files. Incomplete files from a crash may not be playable. There is no automatic recovery UI.

## Tests

```sh
just test
```

Swift Testing covers capture state transitions, cancellation, multi-display geometry, filename collisions, timestamp normalization, mixed audio from different sample rates, audio-only output, and static-video duration. The media tests encode and decode actual files generated from synthetic samples; they need no screen or microphone permission. Tests compile the shared media/model sources as the `SnipCore` Swift package. The Xcode app compiles the same sources directly.

Debug builds also support off-screen layout checks: `Snip.app/Contents/MacOS/Snip --render-preview panel.png` or `--render-region-preview region.png`. These render only Snip's own views, without capturing the desktop or microphone. A managed sandbox must allow access to native drawing/codec services for rendering and media integration tests.

See [the manual verification checklist](docs/verification.md) for permissions, real devices, and release checks.

## Code quality and CI

The `justfile` is the shared entry point for local development and GitHub Actions. Run `just` to list recipes. The existing scripts remain available for direct use.

```sh
brew install just actionlint shellcheck
just lint
just ci
```

`just lint` checks GitHub Actions with actionlint, shell scripts with ShellCheck and Bash's parser, plist/project/scheme syntax, justfile formatting, and whitespace errors. `just build` and `just test` treat Swift compiler warnings as errors; test arguments are forwarded, for example `just test --filter region`.

`just ci` runs linting, all unit and synthetic-media tests, and Apple silicon Debug and Release builds. It verifies app signatures and that each binary contains only `arm64`, creates a local DMG, verifies the disk image, and writes a SHA-256 checksum. These checks require an Apple silicon Mac and Xcode; media tests and packaging also need access to native codec and disk-image services. In a managed compiler sandbox, use `SNIP_EXTRA_SWIFT_FLAGS=-disable-sandbox just ci` and allow those native services.

The [CI workflow](.github/workflows/ci.yml) runs on pull requests, pushes to `master`, and manual dispatch. It uses Apple silicon runners on macOS 15 with Xcode 16.4 and macOS 26 with Xcode 26.6. Successful runs retain local DMGs and checksums for seven days. They are ad hoc signed development artifacts, not notarized releases. Actions are pinned to commit SHAs, and [Dependabot](.github/dependabot.yml) proposes grouped weekly updates. No signing secrets are needed.

## Package a local build

```sh
just package
```

This produces an Apple silicon (`arm64`) app and `dist/Snip-0.1.0-local.dmg`, containing Snip and an Applications shortcut. The local DMG is **not notarized**. It is intended for development, not public distribution.

## Sign and notarize for distribution

The release script requires an installed **Developer ID Application** certificate with its private key and an Apple Developer Program account. Set up a Keychain profile interactively:

```sh
xcrun notarytool store-credentials SnipNotary
```

Then configure the release identity; do not put passwords or private keys in this repository:

```sh
export SNIP_BUNDLE_ID=com.yourcompany.snip
export SNIP_TEAM_ID=YOURTEAMID
export SNIP_SIGN_ID='Developer ID Application: Your Name (YOURTEAMID)'
export SNIP_NOTARY_PROFILE=SnipNotary
just release
```

The script archives an Apple silicon app with Hardened Runtime, verifies the signature, submits the app to Apple's notarization service, staples its ticket, builds and signs the DMG, notarizes/staples the DMG, verifies Gatekeeper acceptance, and writes a SHA-256 checksum. It stops on failures and never silently substitutes an unsigned release. A successful release is `dist/Snip-0.1.0.dmg`. Hosting and automatic updates are outside v1.

The only Hardened Runtime exception is microphone input. App Sandbox is disabled for this direct-distribution build. Set a permanent bundle identifier before releasing; changing it changes the app's macOS privacy identity.

## Layout

- `Sources/Snip`: UI, selection overlays, native capture adapters, and orchestration.
- `Sources/SnipCore`: capture model, permission checks and recovery, coordinate conversion, file publishing, media writing, and finalization.
- `Tests/SnipCoreTests`: deterministic model tests and synthetic-media integration tests.
- `scripts`: local build, test, packaging, and credential-dependent release commands.

V1 does not include webcam capture, pause/resume, annotations, trimming, cloud sharing, automatic updates, or App Store submission.

