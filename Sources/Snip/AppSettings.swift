import Foundation
import Observation

@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    var directoryPath: String { didSet { defaults.set(directoryPath, forKey: "directory") } }
    var videoSystemAudio: Bool { didSet { defaults.set(videoSystemAudio, forKey: "videoSystem") } }
    var videoMicrophone: Bool { didSet { defaults.set(videoMicrophone, forKey: "videoMic") } }
    var audioSystemAudio: Bool { didSet { defaults.set(audioSystemAudio, forKey: "audioSystem") } }
    var audioMicrophone: Bool { didSet { defaults.set(audioMicrophone, forKey: "audioMic") } }
    var showsCursor: Bool { didSet { defaults.set(showsCursor, forKey: "cursor") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["videoSystem": true, "videoMic": false,
                                     "audioSystem": false, "audioMic": true, "cursor": true])
        directoryPath = defaults.string(forKey: "directory") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Snip").path
        videoSystemAudio = defaults.bool(forKey: "videoSystem")
        videoMicrophone = defaults.bool(forKey: "videoMic")
        audioSystemAudio = defaults.bool(forKey: "audioSystem")
        audioMicrophone = defaults.bool(forKey: "audioMic")
        showsCursor = defaults.bool(forKey: "cursor")
    }

    var directory: URL { URL(fileURLWithPath: directoryPath, isDirectory: true) }
    func audio(for kind: CaptureKind) -> AudioSources {
        switch kind {
        case .screenshot: AudioSources(system: false, microphone: false)
        case .video: AudioSources(system: videoSystemAudio, microphone: videoMicrophone)
        case .audio: AudioSources(system: audioSystemAudio, microphone: audioMicrophone)
        }
    }
}

