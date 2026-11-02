import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import SnipCore

private func audioSample(frequency: Double, frame: Int, frames: Int = 1024,
                         rate: Double = 48_000, epoch: Double = 1000) throws -> CMSampleBuffer {
    var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
        mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    try #require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format) == noErr)
    let samples = (0..<frames).flatMap { offset -> [Float] in
        let value = Float(0.5 * sin(2 * .pi * frequency * Double(frame + offset) / rate))
        return [value, value]
    }
    let byteCount = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    try #require(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr)
    let buffer = try #require(block)
    try samples.withUnsafeBytes { bytes in
        try #require(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: buffer,
                                                  offsetIntoDestination: 0, dataLength: byteCount) == noErr)
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
        presentationTimeStamp: CMTime(seconds: epoch + Double(frame) / rate, preferredTimescale: 48_000),
        decodeTimeStamp: .invalid)
    var sampleSize = 8
    var sample: CMSampleBuffer?
    try #require(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: buffer,
        formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}

private func videoSample(at seconds: Double) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    try #require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
    let image = try #require(pixel)
    CVPixelBufferLockBaseAddress(image, [])
    memset(CVPixelBufferGetBaseAddress(image), 100, CVPixelBufferGetBytesPerRow(image) * 48)
    CVPixelBufferUnlockBaseAddress(image, [])
    var format: CMVideoFormatDescription?
    try #require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: image, formatDescriptionOut: &format) == noErr)
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
    try #require(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
        formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
}

private func decodeAudio(_ url: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let track = try #require(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
    ])
    reader.add(output)
    try #require(reader.startReading())
    var samples: [Float] = []
    while let sample = output.copyNextSampleBuffer(), let data = sample.dataBuffer {
        let count = CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size
        var chunk = [Float](repeating: 0, count: count)
        let status = chunk.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!)
        }
        try #require(status == noErr)
        samples.append(contentsOf: stride(from: 0, to: chunk.count, by: 2).map { chunk[$0] })
    }
    try #require(reader.status == .completed)
    return samples
}

private func amplitude(_ samples: [Float], frequency: Double) -> Double {
    let count = Double(samples.count)
    let cosine = samples.enumerated().reduce(0.0) { $0 + Double($1.element) * cos(2 * .pi * frequency * Double($1.offset) / 48_000) }
    let sine = samples.enumerated().reduce(0.0) { $0 + Double($1.element) * sin(2 * .pi * frequency * Double($1.offset) / 48_000) }
    return 2 * sqrt(cosine * cosine + sine * sine) / count
}

@Test func retimingPreservesAudioDurationAndRelativeOffsets() throws {
    let sample = try audioSample(frequency: 440, frame: 0)
    let retimed = try MediaRecorder.retime(sample, presentationTime: CMTime(seconds: 0.25, preferredTimescale: 48_000))
    #expect(abs(retimed.presentationTimeStamp.seconds - 0.25) < 0.0001)
    #expect(retimed.duration == sample.duration)
    #expect(retimed.numSamples == sample.numSamples)
}

@Test func bothAudioSourcesSurviveAsOneMixedTrack() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try ArtifactStore.prepare(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try MediaRecorder(directory: directory, videoSize: nil,
        audio: AudioSources(system: true, microphone: true)) { message in Issue.record(CaptureFailure(message)) }
    try recorder.begin(at: CMTime(seconds: 1000, preferredTimescale: 48_000))
    // Different native sample rates verify AVFoundation's conversion per input.
    for packet in 0..<30 {
        let system = try audioSample(frequency: 440, frame: packet * 1024)
        let mic = try audioSample(frequency: 880, frame: packet * 1024, rate: 44_100)
        recorder.queue.sync {
            recorder.append(system, source: .systemAudio, hostTime: system.presentationTimeStamp)
            recorder.append(mic, source: .microphone, hostTime: mic.presentationTimeStamp)
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    let raw = try await recorder.finish(at: CMTime(seconds: 1000.75, preferredTimescale: 48_000))
    let output = directory.appendingPathComponent("mixed.m4a")
    try await MediaFinalizer.export(rawURL: raw, to: output, kind: .audio)
    let asset = AVURLAsset(url: output)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
    let decoded = try await decodeAudio(output)
    #expect(decoded.count > 25_000)
    #expect(amplitude(decoded, frequency: 440) > 0.15)
    #expect(amplitude(decoded, frequency: 880) > 0.15)
}

@Test func staticVideoLastsUntilStopAndContainsNoAudioWhenDisabled() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try ArtifactStore.prepare(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try MediaRecorder(directory: directory, videoSize: CGSize(width: 64, height: 48),
        audio: AudioSources(system: false, microphone: false)) { message in Issue.record(CaptureFailure(message)) }
    try recorder.begin(at: CMTime(seconds: 1000, preferredTimescale: 600))
    let sample = try videoSample(at: 1000)
    recorder.queue.sync { recorder.append(sample, source: .video, hostTime: sample.presentationTimeStamp) }
    try await Task.sleep(for: .milliseconds(100))
    let raw = try await recorder.finish(at: CMTime(seconds: 1002, preferredTimescale: 600))
    let output = directory.appendingPathComponent("static.mp4")
    try await MediaFinalizer.export(rawURL: raw, to: output, kind: .video)
    let asset = AVURLAsset(url: output)
    #expect(try await asset.load(.duration).seconds >= 1.95)
    #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
    #expect(try await video.load(.naturalSize) == CGSize(width: 64, height: 48))
    let reader = try AVAssetReader(asset: asset)
    let pixels = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(pixels)
    try #require(reader.startReading())
    #expect(pixels.copyNextSampleBuffer()?.imageBuffer != nil)
    reader.cancelReading()
}

@Test func videoAndMixedAudioExportWithAlignedTimelines() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try ArtifactStore.prepare(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try MediaRecorder(directory: directory, videoSize: CGSize(width: 64, height: 48),
        audio: AudioSources(system: true, microphone: true)) { Issue.record(CaptureFailure($0)) }
    try recorder.begin(at: CMTime(seconds: 1000, preferredTimescale: 48_000))
    for packet in 0..<20 {
        let system = try audioSample(frequency: 440, frame: packet * 1024)
        // A microphone that starts 100 ms later must retain that offset.
        let mic = try audioSample(frequency: 880, frame: packet * 1024, epoch: 1000.1)
        let video = try videoSample(at: 1000 + Double(packet) / 30)
        recorder.queue.sync {
            recorder.append(system, source: .systemAudio, hostTime: system.presentationTimeStamp)
            recorder.append(mic, source: .microphone, hostTime: mic.presentationTimeStamp)
            recorder.append(video, source: .video, hostTime: video.presentationTimeStamp)
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    let raw = try await recorder.finish(at: CMTime(seconds: 1000.7, preferredTimescale: 48_000))
    let output = directory.appendingPathComponent("combined.mp4")
    try await MediaFinalizer.export(rawURL: raw, to: output, kind: .video)
    let asset = AVURLAsset(url: output)
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    #expect(abs(try await asset.load(.duration).seconds - 0.7) < 0.05)
    let samples = try await decodeAudio(output)
    #expect(amplitude(samples, frequency: 440) > 0.12)
    #expect(amplitude(samples, frequency: 880) > 0.12)
    // Track timeRange can include an empty edit before its first packet, so
    // verify timing in decoded samples rather than relying on container ranges.
    let beforeMicrophoneStarts = Array(samples.prefix(3000))
    #expect(amplitude(beforeMicrophoneStarts, frequency: 440) > 0.15)
    #expect(amplitude(beforeMicrophoneStarts, frequency: 880) < 0.03)
    let afterBothStart = Array(samples.dropFirst(8000).prefix(8000))
    #expect(amplitude(afterBothStart, frequency: 440) > 0.15)
    #expect(amplitude(afterBothStart, frequency: 880) > 0.15)
}

@Test func emptyAndRepeatedFinalizationFailWithoutPublishingAFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try ArtifactStore.prepare(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try MediaRecorder(directory: directory, videoSize: nil,
        audio: AudioSources(system: false, microphone: true)) { Issue.record(CaptureFailure($0)) }
    try recorder.begin(at: CMTime(seconds: 1000, preferredTimescale: 600))
    await #expect(throws: (any Error).self) {
        _ = try await recorder.finish(at: CMTime(seconds: 1001, preferredTimescale: 600))
    }
    await #expect(throws: (any Error).self) {
        _ = try await recorder.finish(at: CMTime(seconds: 1001, preferredTimescale: 600))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { $0.hasPrefix(".snip-") })
}

