import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class CaptureEngine {
    private var streams: [SCStream] = []
    private var sinks: [ScreenSink] = []
    private var microphone: MicrophoneCapture?
    private(set) var recorder: MediaRecorder?

    func screenshot(selection: CaptureSelection, directory: URL) async throws -> URL {
        let config = selection.configuration(video: false, cursor: false)
        let image = try await SCScreenshotManager.captureImage(contentFilter: selection.filter, configuration: config)
        let temporary = directory.appendingPathComponent(".snip-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureFailure("Couldn’t create the screenshot file.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureFailure("Couldn’t save the screenshot. Check available disk space.") }
        return try ArtifactStore.publish(temporary, directory: directory, kind: .screenshot)
    }

    func start(request: CaptureRequest, selection: CaptureSelection?,
               onFailure: @escaping @Sendable (String) -> Void) async throws -> Date {
        let videoConfig = selection?.configuration(video: true, cursor: request.showsCursor)
        let size = videoConfig.map { CGSize(width: $0.width, height: $0.height) }
        let recorder = try MediaRecorder(directory: request.directory, videoSize: size,
                                         audio: request.audio, onFailure: onFailure)
        self.recorder = recorder
        do {
            if let selection, let videoConfig {
                let sink = ScreenSink(recorder: recorder, source: .video, onFailure: onFailure)
                let stream = SCStream(filter: selection.filter, configuration: videoConfig, delegate: sink)
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: recorder.queue)
                sinks.append(sink)
                streams.append(stream)
            }
            if request.audio.system {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { throw CaptureFailure("No display is available for system audio capture.") }
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 2; config.height = 2
                config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
                config.queueDepth = 3
                config.capturesAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                config.excludesCurrentProcessAudio = true
                let sink = ScreenSink(recorder: recorder, source: .systemAudio, onFailure: onFailure)
                let stream = SCStream(filter: filter, configuration: config, delegate: sink)
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: recorder.queue)
                // Discard screen callbacks; never persist screen frames for audio capture.
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: recorder.queue)
                sinks.append(sink)
                streams.append(stream)
            }
            if request.audio.microphone {
                microphone = try MicrophoneCapture(recorder: recorder, onFailure: onFailure)
            }
            try recorder.begin(at: CMClockGetTime(CMClockGetHostTimeClock()))
            let startedAt = Date()
            for stream in streams { try await stream.startCapture() }
            try await microphone?.start()
            return startedAt
        } catch {
            await stopSources()
            recorder.discard()
            self.recorder = nil
            throw error
        }
    }

    func stop(request: CaptureRequest) async throws -> URL {
        guard let recorder else { throw CaptureFailure("There is no active recording.") }
        let endTime = CMClockGetTime(CMClockGetHostTimeClock())
        await stopSources()
        defer { self.recorder = nil }
        do {
            let raw = try await recorder.finish(at: endTime)
            let output = recorder.workingDirectory.appendingPathComponent("finished.\(request.kind.fileExtension)")
            try await MediaFinalizer.export(rawURL: raw, to: output, kind: request.kind)
            let published = try ArtifactStore.publish(output, directory: request.directory, kind: request.kind)
            try? FileManager.default.removeItem(at: recorder.workingDirectory)
            return published
        } catch {
            throw CaptureFailure("\(error.localizedDescription)\n\nAny recoverable recording is kept at:\n\(recorder.workingDirectory.path)")
        }
    }

    private func stopSources() async {
        // Stop failure callbacks before deliberate teardown.
        sinks.forEach { $0.disableFailures() }
        await microphone?.stop()
        microphone = nil
        for stream in streams { try? await stream.stopCapture() }
        streams.removeAll()
        sinks.removeAll()
    }
}

private final class ScreenSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let recorder: MediaRecorder
    private let source: MediaSource
    private let onFailure: @Sendable (String) -> Void
    private let failureLock = NSLock()
    private var failuresEnabled = true

    init(recorder: MediaRecorder, source: MediaSource, onFailure: @escaping @Sendable (String) -> Void) {
        self.recorder = recorder; self.source = source; self.onFailure = onFailure
    }
    func disableFailures() { failureLock.withLock { failuresEnabled = false } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if source == .video {
            guard type == .screen,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
        } else if type != .audio { return }
        let clock = stream.synchronizationClock ?? CMClockGetHostTimeClock()
        let hostTime = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
        recorder.append(sampleBuffer, source: source, hostTime: hostTime)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if failureLock.withLock({ failuresEnabled }) {
            onFailure("Capture was interrupted: \(error.localizedDescription)")
        }
    }
}

/// Session setup is complete before start; blocking session operations use the
/// control queue and sample callbacks run only on the recorder's serial queue.
private final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let control = DispatchQueue(label: "app.snip.microphone")
    private let recorder: MediaRecorder
    private var observers: [NSObjectProtocol] = []

    init(recorder: MediaRecorder, onFailure: @escaping @Sendable (String) -> Void) throws {
        self.recorder = recorder
        super.init()
        guard let device = AVCaptureDevice.default(for: .audio) else { throw CaptureFailure("No microphone is connected.") }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: recorder.queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CaptureFailure("The microphone is unavailable.") }
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil) { notification in
                let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "The microphone stopped working."
                onFailure(message)
            })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device, queue: nil) { _ in onFailure("The microphone was disconnected. The usable recording will be saved.") })
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async { [self] in
                session.startRunning()
                if session.isRunning { continuation.resume() }
                else { continuation.resume(throwing: CaptureFailure("Couldn’t start the microphone.")) }
            }
        }
    }
    func stop() async {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        await withCheckedContinuation { continuation in
            control.async { [self] in session.stopRunning(); continuation.resume() }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        let host = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
        recorder.append(sampleBuffer, source: .microphone, hostTime: host)
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
