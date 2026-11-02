@preconcurrency import AVFoundation
import Foundation

public enum MediaFinalizer {
    /// Decode/mix only audio. H.264 packets pass through unchanged, avoiding a
    /// second video encode. This also guarantees exactly one output audio track.
    public static func export(rawURL: URL, to outputURL: URL, kind: CaptureKind) async throws {
        let asset = AVURLAsset(url: rawURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = kind == .video ? try await asset.loadTracks(withMediaType: .video) : []
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: kind == .video ? .mp4 : .m4a)
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
        if let video = videoTracks.first {
            let formats = try await video.load(.formatDescriptions)
            let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
            input.transform = try await video.load(.preferredTransform)
            pairs.append((output, input))
        }
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
            ])
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                // Equal headroom prevents two full-scale inputs clipping.
                parameters.setVolume(1 / Float(audioTracks.count), at: .zero)
                return parameters
            }
            output.audioMix = mix
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000
            ])
            pairs.append((output, input))
        }
        guard !pairs.isEmpty, kind != .video || !videoTracks.isEmpty else {
            throw CaptureFailure("The recording has no usable media tracks.")
        }
        for (output, input) in pairs {
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw CaptureFailure("Couldn’t prepare the recording for export.")
            }
            reader.add(output)
            writer.add(input)
        }
        guard writer.startWriting() else { throw writer.error ?? CaptureFailure("Couldn’t create the final file.") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? CaptureFailure("Couldn’t read the recorded media.")
        }
        let pump = ExportPump(reader: reader, writer: writer, pairs: pairs)
        try await pump.run()
    }
}

/// AVFoundation's readiness callbacks and completion all share one serial queue.
private final class ExportPump: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]
    let queue = DispatchQueue(label: "app.snip.export", qos: .userInitiated)
    var remaining: Int
    var completed = Set<Int>()
    var continuation: CheckedContinuation<Void, Error>?
    var resolved = false

    init(reader: AVAssetReader, writer: AVAssetWriter, pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]) {
        self.reader = reader; self.writer = writer; self.pairs = pairs
        remaining = pairs.count
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                for index in pairs.indices {
                    pairs[index].1.requestMediaDataWhenReady(on: queue) { [self] in drain(index) }
                }
            }
        }
    }

    private func drain(_ index: Int) {
        guard !resolved, !completed.contains(index) else { return }
        let (output, input) = pairs[index]
        while input.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    fail(reader.error ?? CaptureFailure("Reading the recording failed."))
                    return
                }
                input.markAsFinished()
                completed.insert(index)
                remaining -= 1
                if remaining == 0 {
                    writer.finishWriting { [self] in
                        queue.async { [self] in
                            guard !resolved else { return }
                            resolved = true
                            if writer.status == .completed { continuation?.resume() }
                            else { continuation?.resume(throwing: writer.error ?? CaptureFailure("Export failed.")) }
                            continuation = nil
                        }
                    }
                }
                return
            }
            if !input.append(sample) {
                fail(writer.error ?? CaptureFailure("The capture folder may be full or unavailable."))
                return
            }
        }
    }

    private func fail(_ error: Error) {
        guard !resolved else { return }
        resolved = true
        reader.cancelReading()
        writer.cancelWriting()
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
