@preconcurrency import AVFoundation
import Foundation

public enum MediaSource: Sendable, Hashable { case video, systemAudio, microphone }

/// All mutable writer state is confined to `queue`. Capture delegates deliver
/// directly on this queue; no unbounded sample queues or whole recordings in RAM.
public final class MediaRecorder: @unchecked Sendable {
    public let queue = DispatchQueue(label: "app.snip.media", qos: .userInitiated)
    public let workingDirectory: URL
    public let rawURL: URL
    private let writer: AVAssetWriter
    private var inputs: [MediaSource: AVAssetWriterInput] = [:]
    private var epoch: CMTime?
    private var lastTimes: [MediaSource: CMTime] = [:]
    private var lastVideo: CMSampleBuffer?
    private var finishing = false
    private var didReportFailure = false
    private let onFailure: @Sendable (String) -> Void

    public init(directory: URL, videoSize: CGSize?, audio: AudioSources,
                onFailure: @escaping @Sendable (String) -> Void) throws {
        workingDirectory = directory.appendingPathComponent(".snip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        rawURL = workingDirectory.appendingPathComponent("recoverable.mov")
        writer = try AVAssetWriter(outputURL: rawURL, fileType: .mov)
        self.onFailure = onFailure
        if let size = videoSize {
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(max(2_000_000, size.width * size.height * 5)),
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60
                ]
            ]
            try addInput(.video, type: .video, settings: settings)
        }
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
        ]
        if audio.system { try addInput(.systemAudio, type: .audio, settings: audioSettings) }
        if audio.microphone { try addInput(.microphone, type: .audio, settings: audioSettings) }
    }

    private func addInput(_ source: MediaSource, type: AVMediaType, settings: [String: Any]) throws {
        let input = AVAssetWriterInput(mediaType: type, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureFailure("The selected recording format isn’t supported.") }
        writer.add(input)
        inputs[source] = input
    }

    public func begin(at hostTime: CMTime) throws {
        try queue.sync {
            guard epoch == nil, !finishing else { throw CaptureFailure("This recording has already started.") }
            guard writer.startWriting() else { throw writer.error ?? CaptureFailure("Couldn’t start writing the recording.") }
            writer.startSession(atSourceTime: .zero)
            epoch = hostTime
        }
    }

    public func append(_ sample: CMSampleBuffer, source: MediaSource, hostTime: CMTime) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finishing, let epoch, let input = inputs[source],
              sample.isValid, CMSampleBufferDataIsReady(sample), hostTime.isNumeric else { return }
        let relativeTime = hostTime - epoch
        guard relativeTime >= .zero else { return }
        if let last = lastTimes[source], relativeTime <= last { return }
        guard writer.status == .writing else {
            report(writer.error?.localizedDescription ?? "Recording stopped unexpectedly.")
            return
        }
        guard input.isReadyForMoreMediaData else {
            // Video may drop frames under load. Audio loss ends the session visibly.
            if source != .video { report("The disk couldn’t keep up with audio recording. The usable portion will be saved.") }
            return
        }
        do {
            let retimed = try Self.retime(sample, presentationTime: relativeTime)
            guard input.append(retimed) else {
                report(writer.error?.localizedDescription ?? "Couldn’t write captured media.")
                return
            }
            lastTimes[source] = relativeTime
            if source == .video { lastVideo = sample }
        } catch { report(error.localizedDescription) }
    }

    public static func retime(_ sample: CMSampleBuffer, presentationTime: CMTime) throws -> CMSampleBuffer {
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        let status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count,
                                                          arrayToFill: &timing, entriesNeededOut: nil)
        guard status == noErr else { throw CaptureFailure("Couldn’t read media timing (\(status)).") }
        let delta = presentationTime - sample.presentationTimeStamp
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + delta
            if timing[index].decodeTimeStamp.isValid { timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + delta }
        }
        var copy: CMSampleBuffer?
        let result = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
            sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard result == noErr, let copy else { throw CaptureFailure("Couldn’t synchronize media timing (\(result)).") }
        return copy
    }

    public func finish(at hostTime: CMTime) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !finishing else {
                    continuation.resume(throwing: CaptureFailure("Recording is already being finalized."))
                    return
                }
                finishing = true
                guard let epoch, !lastTimes.isEmpty, writer.status == .writing else {
                    writer.cancelWriting()
                    continuation.resume(throwing: writer.error ?? CaptureFailure("No media was received. Check capture permissions and the selected source."))
                    return
                }
                if inputs[.video] != nil && lastVideo == nil {
                    writer.cancelWriting()
                    continuation.resume(throwing: CaptureFailure("No screen frames were received. Check Screen Recording access and try again."))
                    return
                }
                let end = max(hostTime - epoch, (lastTimes.values.max() ?? .zero) + CMTime(value: 1, timescale: 30))
                // ScreenCaptureKit emits sparse frames on a static desktop. Hold
                // the final image through Stop rather than shortening the movie.
                if let lastVideo, let input = inputs[.video], input.isReadyForMoreMediaData,
                   let tail = try? Self.retime(lastVideo, presentationTime: end - CMTime(value: 1, timescale: 30)),
                   tail.presentationTimeStamp > (lastTimes[.video] ?? .zero) {
                    input.append(tail)
                }
                writer.endSession(atSourceTime: end)
                inputs.values.forEach { $0.markAsFinished() }
                writer.finishWriting { [self] in
                    if writer.status == .completed { continuation.resume(returning: rawURL) }
                    else { continuation.resume(throwing: writer.error ?? CaptureFailure("Couldn’t finish the recording.")) }
                }
            }
        }
    }

    public func discard() {
        queue.sync {
            finishing = true
            if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
        }
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    private func report(_ message: String) {
        guard !didReportFailure else { return }
        didReportFailure = true
        onFailure(message)
    }
}

