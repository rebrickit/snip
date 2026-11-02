import AppKit
import Observation
import OSLog

@MainActor @Observable
final class CaptureCoordinator {
    let settings: AppSettings
    var selectedKind: CaptureKind = .screenshot
    var area: CaptureArea = .region
    private(set) var lifecycle = CaptureLifecycle()
    private(set) var startedAt: Date?
    private(set) var artifact: CaptureArtifact?
    var message: String?
    private(set) var permissionIssue: CapturePermissionFailure?
    var shortcutWarning: String?
    @ObservationIgnored var hidePanel: (() -> Void)?
    @ObservationIgnored var showPanel: (() -> Void)?
    @ObservationIgnored var restartApp: (() -> Void)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private let picker = SourcePicker()
    @ObservationIgnored private let engine = CaptureEngine()
    @ObservationIgnored private var request: CaptureRequest?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pendingInterruption: String?
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.snip.app", category: "capture")

    init(settings: AppSettings) { self.settings = settings }
    var state: CaptureState { lifecycle.state }

    func begin(_ kind: CaptureKind? = nil) {
        guard lifecycle.begin() else { return }
        let kind = kind ?? selectedKind
        selectedKind = kind
        message = nil
        permissionIssue = nil
        pendingInterruption = nil
        let id = UUID()
        generation = id
        let request = CaptureRequest(kind: kind, area: area, audio: settings.audio(for: kind),
                                     showsCursor: settings.showsCursor, directory: settings.directory)
        self.request = request
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                guard kind != .audio || !request.audio.isEmpty else { throw CaptureFailure("Choose Microphone, System audio, or both before recording.") }
                try ArtifactStore.prepare(directory: request.directory)
                if request.audio.microphone { try await Permissions.requireMicrophone() }
                try Task.checkCancellation()
                if request.audio.system { try await Permissions.requireScreen() }
                try Task.checkCancellation()
                hidePanel?()
                // Give the popover a display cycle to disappear before selection.
                try await Task.sleep(for: .milliseconds(150))
                let selection = kind == .audio ? nil : try await picker.choose(area: request.area, kind: kind)
                try Task.checkCancellation()
                if kind == .screenshot, let selection {
                    lifecycle.transition(to: .starting)
                    try await Task.sleep(for: .milliseconds(150))
                    let url = try await engine.screenshot(selection: selection, directory: request.directory)
                    complete(url: url, kind: kind)
                } else {
                    for remaining in (1...3).reversed() {
                        lifecycle.transition(to: .countdown(remaining))
                        showPanel?()
                        try await Task.sleep(for: .seconds(1))
                    }
                    try Task.checkCancellation()
                    hidePanel?()
                    lifecycle.transition(to: .starting)
                    startedAt = try await engine.start(request: request, selection: selection) { [weak self] reason in
                        Task { @MainActor in
                            guard self?.generation == id else { return }
                            self?.interrupted(reason)
                        }
                    }
                    lifecycle.transition(to: .recording)
                    if let pendingInterruption { interrupted(pendingInterruption) }
                }
            } catch is CancellationError {
                if generation == id { reset() }
            } catch {
                if generation == id {
                    log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                    permissionIssue = Permissions.permissionFailure(for: error)
                    message = permissionIssue?.localizedDescription ?? error.localizedDescription
                    reset()
                    showPanel?()
                }
            }
        }
    }

    func cancel() {
        guard state.canCancel else { return }
        operation?.cancel()
        picker.cancel()
        // Keep the operation busy until its cancellation handler finishes, so
        // an old picker cannot reset the state of a new capture.
    }

    func stop() {
        if state.canCancel { cancel(); return }
        guard state == .recording, let request, lifecycle.transition(to: .finalizing) else { return }
        showPanel?()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await engine.stop(request: request)
                complete(url: url, kind: request.kind)
            } catch {
                log.error("Finalization failed: \(error.localizedDescription, privacy: .public)")
                permissionIssue = Permissions.permissionFailure(for: error)
                message = permissionIssue?.localizedDescription ?? error.localizedDescription
                reset()
                showPanel?()
            }
        }
    }

    func interrupted(_ reason: String) {
        if state == .starting { pendingInterruption = reason; return }
        guard state == .recording else { return }
        message = reason
        stop()
    }

    func prepareForSleep() {
        if state.canCancel { cancel() }
        else { interrupted("Recording stopped because the Mac is going to sleep.") }
    }

    func copyScreenshot() {
        guard let artifact, artifact.kind == .screenshot, let image = NSImage(contentsOf: artifact.url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    func openPermissionSettings(_ permission: CapturePermission) {
        hidePanel?()
        if !Permissions.openPrivacy(permission) {
            message = "Couldn’t open System Settings. Open it from the Apple menu, then choose Privacy & Security → \(permission.settingsTitle.replacingOccurrences(of: " Settings", with: ""))."
            showPanel?()
        }
    }

    func showCurrentApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func dismissMessage() { message = nil; permissionIssue = nil }

    private func complete(url: URL, kind: CaptureKind) {
        artifact = CaptureArtifact(kind: kind, url: url)
        log.info("Capture saved successfully.")
        reset()
        showPanel?()
    }

    private func reset() {
        picker.reset()
        lifecycle.finish()
        request = nil
        startedAt = nil
        pendingInterruption = nil
    }
}

