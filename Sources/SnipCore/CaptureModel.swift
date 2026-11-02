import Foundation
import CoreGraphics

public enum CaptureKind: String, Sendable, CaseIterable {
    case screenshot, video, audio

    public var fileExtension: String {
        switch self {
        case .screenshot: "png"
        case .video: "mp4"
        case .audio: "m4a"
        }
    }

    public var title: String {
        switch self {
        case .screenshot: "Screenshot"
        case .video: "Screen recording"
        case .audio: "Audio recording"
        }
    }
}

public enum CaptureArea: String, Sendable, CaseIterable, Identifiable {
    case display = "Display", window = "Window", region = "Region"
    public var id: String { rawValue }
}

public struct AudioSources: Sendable, Equatable {
    public var system: Bool
    public var microphone: Bool
    public init(system: Bool, microphone: Bool) {
        self.system = system
        self.microphone = microphone
    }
    public var isEmpty: Bool { !system && !microphone }
}

public struct CaptureRequest: Sendable {
    public let kind: CaptureKind
    public let area: CaptureArea
    public let audio: AudioSources
    public let showsCursor: Bool
    public let directory: URL

    public init(kind: CaptureKind, area: CaptureArea, audio: AudioSources,
                showsCursor: Bool, directory: URL) {
        self.kind = kind
        self.area = area
        self.audio = audio
        self.showsCursor = showsCursor
        self.directory = directory
    }
}

public enum CaptureState: Equatable, Sendable {
    case idle, selecting, countdown(Int), starting, recording, finalizing
    public var isBusy: Bool { self != .idle }
    public var canCancel: Bool {
        switch self {
        case .selecting, .countdown: true
        default: false
        }
    }
}

/// The UI and shortcuts share this state machine, so a second request cannot
/// race an outstanding picker, countdown, or file finalization.
public struct CaptureLifecycle: Sendable {
    public private(set) var state: CaptureState = .idle
    public init() {}

    @discardableResult public mutating func begin() -> Bool {
        guard state == .idle else { return false }
        state = .selecting
        return true
    }

    @discardableResult public mutating func transition(to next: CaptureState) -> Bool {
        let allowed: Bool
        switch (state, next) {
        case (.selecting, .countdown(3)), (.selecting, .starting),
             (.countdown(3), .countdown(2)), (.countdown(2), .countdown(1)),
             (.countdown(1), .starting), (.starting, .recording),
             (.starting, .finalizing), (.recording, .finalizing): allowed = true
        default: allowed = false
        }
        guard allowed else { return false }
        state = next
        return true
    }

    @discardableResult public mutating func cancel() -> Bool {
        guard state.canCancel else { return false }
        state = .idle
        return true
    }
    public mutating func finish() { state = .idle }
}

public struct CaptureArtifact: Sendable, Identifiable {
    public let id = UUID()
    public let kind: CaptureKind
    public let url: URL
    public init(kind: CaptureKind, url: URL) { self.kind = kind; self.url = url }
}

public struct CaptureFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

