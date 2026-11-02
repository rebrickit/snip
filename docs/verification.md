# Manual verification

Run on macOS 15 and the current macOS before a public release, including an Intel Mac if distributing the universal build. Automated media tests cannot verify system privacy prompts, picker behavior, or hardware clock stability.

## Screen capture

- Launch Snip; verify its menu bar panel, readable light/dark appearance, and Settings.
- Capture a display, window, and region. Inspect PNG dimensions at 1× and 2× backing scale. Check Copy by pasting into Preview.
- With monitors above/left of the main display and different scaling factors, select regions near each edge. The image must contain precisely that area and never span monitors.
- Cancel Apple's picker and press Escape in region selection. No capture should be written; another capture must start normally.
- For both screenshots and video, draw a region and release the mouse: capture must wait. Resize all eight handles and the edges between handles; drag inside to move. Check boundaries and tiny selections. Press Return or click Capture/Record to confirm the edited area; verify Cancel and Escape write no file.
- Start a region on a different monitor after drawing one: only the new selection should remain. Confirm controls must stay reachable when the region touches a display edge or fills the display.
- Record a moving window, resize it, and move it between displays. Check framing, cursor visibility, and playback in QuickTime.
- Record an unchanged desktop for 30 seconds. The video must remain visible through the full duration.
- Stop from the panel and from Control–Option–Command–X while another app is focused.

## Audio and duration

- Video: test no audio, microphone only, desktop only, and both.
- Audio-only: test microphone, desktop, and both. Check that QuickTime identifies an audio file and both sources are audible when selected.
- Record a window from one application while a different application plays audio. Desktop audio should still be included.
- Record with the system default microphone at both 44.1 kHz and 48 kHz where supported. Test a USB or Bluetooth input and device removal.
- Record silence, a very short clip, and a sustained 30-minute session. Inspect memory in Activity Monitor for bounded usage; verify beginning/end audio-video synchronization (target less than 100 ms drift).
- Closing the popover must not stop recording. Quitting and sleep must stop capture and attempt to save.

## Permissions and failures

- With a fresh app privacy identity, microphone-only recording asks only for Microphone permission.
- Deny screen or microphone access, follow the app's recovery message, grant access, and retry/relaunch as requested by macOS.
- If access was already enabled for an older build, verify the error offers the appropriate settings pane, Restart Snip, and Show This App. Remove/re-add only the current Snip entry manually and confirm the new copy can capture. With a development certificate configured, rebuild and confirm access persists.
- Restart from Snip's settings and verify only one menu bar item remains and global shortcuts still work. The restart action must be disabled during capture/finalization.
- Encoder, full-disk, and missing-source failures must not be presented as permission denials.
- Cancel during countdown; repeatedly press start/stop shortcuts. There must be no duplicate streams or corrupt published files.
- Change/disconnect the selected display and close the selected window during capture. The app should remain responsive and save usable media or report a recoverable failure.
- Choose an unwritable/unavailable destination; test a nearly full removable volume. Errors must be visible, existing files untouched, and any recovery path reported accurately.
- Interrupt an export or relaunch after a crash. Check the hidden working directory; the app must never claim an incomplete output was saved successfully.

## Distribution

- Run `just ci` for linting, tests, Debug and universal Release builds, signature/architecture checks, and DMG validation. Use `just package` to repeat only the Release build and packaging checks.
- Mount the local DMG; verify the app and Applications shortcut. Copy the app to a stable test location and launch it.
- With Developer ID credentials available, run `just release` and retain notarization logs with the release.
- On a clean Mac, download the final notarized DMG, mount it, install, and launch without bypassing Gatekeeper. Check stapled tickets with the network disconnected.

Record actual outcomes separately from this checklist; an unchecked scenario is not a passing test.
