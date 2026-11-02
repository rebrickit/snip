import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

public enum CapturePermission: Sendable, Equatable {
    case screen, microphone

    public var settingsTitle: String {
        switch self {
        case .screen: "Screen Recording Settings"
        case .microphone: "Microphone Settings"
        }
    }

    public var settingsURL: URL {
        let anchor = self == .screen ? "Privacy_ScreenCapture" : "Privacy_Microphone"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public struct CapturePermissionFailure: LocalizedError, Sendable {
    public let permission: CapturePermission
    public let isRestricted: Bool

    public init(_ permission: CapturePermission, isRestricted: Bool = false) {
        self.permission = permission
        self.isRestricted = isRestricted
    }

    public var errorDescription: String? {
        if isRestricted { return "Microphone access is restricted by macOS or your administrator. Changing the permission switch may not be available." }
        switch permission {
        case .screen:
            return "Screen recording access isn’t available to this copy of Snip. Enable Snip in Screen & System Audio Recording, then restart Snip. If access is already enabled after an app update, remove the old Snip entry and add this copy again."
        case .microphone:
            return "Microphone access isn’t available to this copy of Snip. Enable Snip in Microphone settings, then restart Snip if capture still fails."
        }
    }
}

@MainActor
public enum Permissions {
    /// Check the actual ScreenCaptureKit operation, rather than rejecting a
    /// capture solely on Core Graphics' preflight state in the current process.
    /// This operation can request permission, so call it only after a user action.
    public static func requireScreen(verifyingAccess: @MainActor () async throws -> Void = {
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }) async throws {
        do { try await verifyingAccess() }
        catch {
            if let failure = permissionFailure(for: error) { throw failure }
            throw error
        }
    }

    public static func requireMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
        case .restricted:
            throw CapturePermissionFailure(.microphone, isRestricted: true)
        default: break
        }
        throw CapturePermissionFailure(.microphone)
    }

    /// Keep file, encoder, and source errors distinct from authorization errors.
    /// Also recognize permission failures returned directly by the native picker.
    public static func permissionFailure(for error: Error) -> CapturePermissionFailure? {
        if let failure = error as? CapturePermissionFailure { return failure }
        let error = error as NSError
        if error.domain == SCStreamErrorDomain, error.code == SCStreamError.Code.userDeclined.rawValue {
            return CapturePermissionFailure(.screen)
        }
        if error.domain == AVFoundationErrorDomain, error.code == AVError.applicationIsNotAuthorizedToUseDevice.rawValue {
            return CapturePermissionFailure(.microphone)
        }
        return nil
    }

    @discardableResult public static func openPrivacy(_ permission: CapturePermission) -> Bool {
        if NSWorkspace.shared.open(permission.settingsURL) { return true }
        // Pane anchors can change between OS releases. Still open Settings and
        // let the UI show the exact pane name instead of silently doing nothing.
        return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
