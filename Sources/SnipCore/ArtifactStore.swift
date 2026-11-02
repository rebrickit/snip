import Foundation

public enum ArtifactStore {
    public static func prepare(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw CaptureFailure("The capture folder isn’t writable. Choose another folder in Settings.")
        }
    }

    public static func uniqueURL(directory: URL, kind: CaptureKind, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Snip \(kind.rawValue) \(formatter.string(from: date))"
        var suffix = 0
        while true {
            let name = stem + (suffix == 0 ? "" : "-\(suffix)") + "." + kind.fileExtension
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            suffix += 1
        }
    }

    /// Move, rather than copy, a completed file into the user-visible namespace.
    /// moveItem refuses to overwrite an existing file, including external races.
    public static func publish(_ temporaryURL: URL, directory: URL, kind: CaptureKind) throws -> URL {
        for _ in 0..<20 {
            let destination = uniqueURL(directory: directory, kind: kind)
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                return destination
            } catch {
                guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
            }
        }
        throw CaptureFailure("Couldn’t choose an unused capture filename. Please try again.")
    }
}
