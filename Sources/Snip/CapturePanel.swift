import SwiftUI
import AppKit

struct CapturePanel: View {
    @Bindable var coordinator: CaptureCoordinator
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder").font(.system(size: 24, weight: .medium)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snip").font(.title2.weight(.semibold))
                    Text("Capture a moment.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
            }
            if coordinator.state == .idle { captureControls }
            else { activeCapture }
            if let message = coordinator.message {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Capture notice", systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold))
                    Text(message).font(.caption).textSelection(.enabled)
                    if let issue = coordinator.permissionIssue {
                        HStack {
                            Button(issue.permission.settingsTitle) { coordinator.openPermissionSettings(issue.permission) }
                            Button("Restart Snip") { coordinator.restartApp?() }
                                .disabled(coordinator.state.isBusy)
                        }.font(.caption)
                    }
                    HStack {
                        if coordinator.permissionIssue != nil {
                            Button("Show This App", action: coordinator.showCurrentApp)
                        }
                        Spacer()
                        Button("Dismiss", action: coordinator.dismissMessage)
                    }.font(.caption)
                }.padding(12).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            if let artifact = coordinator.artifact, coordinator.state == .idle {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Saved \(artifact.kind.title.lowercased())", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.green)
                    Text(artifact.url.lastPathComponent).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    HStack {
                        Button("Open") { NSWorkspace.shared.open(artifact.url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([artifact.url]) }
                        if artifact.kind == .screenshot {
                            Button("Copy", action: coordinator.copyScreenshot)
                        }
                    }.controlSize(.small)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            if let warning = coordinator.shortcutWarning {
                Text(warning).font(.caption2).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Text("⌃⌥⌘ S / R / A · X to stop").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit", action: quit).buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 370)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Capture mode", selection: $coordinator.selectedKind) {
                Text("Screenshot").tag(CaptureKind.screenshot)
                Text("Video").tag(CaptureKind.video)
                Text("Audio").tag(CaptureKind.audio)
            }.pickerStyle(.segmented).labelsHidden()
            if coordinator.selectedKind != .audio {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CAPTURE AREA").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Picker("Capture area", selection: $coordinator.area) {
                        ForEach(CaptureArea.allCases) { area in Text(area.rawValue).tag(area) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
            }
            if coordinator.selectedKind != .screenshot {
                audioControls
                Text(coordinator.selectedKind == .audio
                     ? "Save microphone, desktop audio, or both as an M4A file."
                     : "Save an MP4 video. Both audio sources are mixed into one track.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Save a full-resolution PNG, then open or copy it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { coordinator.begin() } label: {
                Label(actionTitle, systemImage: coordinator.selectedKind == .screenshot ? "camera" : "record.circle")
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(coordinator.selectedKind == .audio && coordinator.settings.audio(for: .audio).isEmpty)
        }
    }

    private var audioControls: some View {
        @Bindable var settings = coordinator.settings
        return HStack(spacing: 20) {
            if coordinator.selectedKind == .video {
                Toggle("System audio", isOn: $settings.videoSystemAudio)
                Toggle("Microphone", isOn: $settings.videoMicrophone)
            } else {
                Toggle("System audio", isOn: $settings.audioSystemAudio)
                Toggle("Microphone", isOn: $settings.audioMicrophone)
            }
        }.toggleStyle(.checkbox).font(.subheadline)
    }

    private var actionTitle: String {
        switch coordinator.selectedKind {
        case .screenshot: "Capture screenshot"
        case .video: "Record screen"
        case .audio: "Record audio"
        }
    }

    @ViewBuilder private var activeCapture: some View {
        VStack(spacing: 16) {
            switch coordinator.state {
            case .countdown(let count):
                Text("\(count)").font(.system(size: 52, weight: .light, design: .rounded)).monospacedDigit()
                Text("Recording starts shortly").foregroundStyle(.secondary)
                Button("Cancel", action: coordinator.cancel)
            case .recording:
                Label("Recording", systemImage: "record.circle.fill").foregroundStyle(.red).font(.headline)
                if let start = coordinator.startedAt {
                    Text(start, style: .timer).font(.system(size: 36, weight: .light, design: .monospaced))
                }
                Button(action: coordinator.stop) { Label("Stop recording", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            case .selecting:
                ProgressView()
                Text("Choose what to capture").foregroundStyle(.secondary)
                Button("Cancel", action: coordinator.cancel)
            case .starting:
                ProgressView()
                Text("Starting capture…").foregroundStyle(.secondary)
            case .finalizing:
                ProgressView()
                Text("Saving your recording…").font(.headline)
                Text("Finishing the file and mixing audio.").font(.caption).foregroundStyle(.secondary)
            case .idle: EmptyView()
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let coordinator: CaptureCoordinator
    var body: some View {
        Form {
            Section("Save captures") {
                Text(settings.directoryPath).font(.callout).textSelection(.enabled)
                Button("Choose folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = settings.directory
                    if panel.runModal() == .OK, let url = panel.url { settings.directoryPath = url.path }
                }
            }
            Section("Screen recording defaults") {
                Toggle("Include system audio", isOn: $settings.videoSystemAudio)
                Toggle("Include microphone", isOn: $settings.videoMicrophone)
                Toggle("Show mouse pointer in video", isOn: $settings.showsCursor)
            }
            Section("Audio recording defaults") {
                Toggle("Include system audio", isOn: $settings.audioSystemAudio)
                Toggle("Include microphone", isOn: $settings.audioMicrophone)
                Text("Uses the Mac’s default microphone. Change it in System Settings → Sound.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keyboard shortcuts") {
                LabeledContent("Screenshot", value: "⌃⌥⌘S")
                LabeledContent("Screen recording", value: "⌃⌥⌘R")
                LabeledContent("Audio recording", value: "⌃⌥⌘A")
                LabeledContent("Stop / cancel", value: "⌃⌥⌘X")
            }
            Section("Capture permissions") {
                Button("Screen & System Audio Recording…") { coordinator.openPermissionSettings(.screen) }
                Button("Microphone…") { coordinator.openPermissionSettings(.microphone) }
                Text("After enabling access, restart Snip if capture still fails. If you replaced the app, remove the old Screen Recording entry and add this copy again.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Restart Snip") { coordinator.restartApp?() }.disabled(coordinator.state.isBusy)
                    Button("Show This App", action: coordinator.showCurrentApp)
                }
            }
            Section {
                Text("Captures stay on your Mac. Snip has no account, uploads, or analytics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 470, height: 620)
    }
}
