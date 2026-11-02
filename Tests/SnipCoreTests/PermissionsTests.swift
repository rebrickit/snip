import Foundation
import Testing
import AVFoundation
import ScreenCaptureKit
@testable import SnipCore

@Test @MainActor func screenPermissionUsesTheCaptureFrameworkCheck() async throws {
    var checks = 0
    try await Permissions.requireScreen {
        // Success from the capture framework must be enough to proceed; no
        // separate Core Graphics preflight is allowed to reject this session.
        checks += 1
    }
    #expect(checks == 1)
}

@Test @MainActor func screenPermissionDenialProvidesTargetedRecovery() async throws {
    do {
        try await Permissions.requireScreen {
            throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        }
        Issue.record("A denied capture must not proceed.")
    } catch let failure as CapturePermissionFailure {
        #expect(failure.permission == .screen)
        #expect(!failure.isRestricted)
        #expect(failure.localizedDescription.contains("restart Snip"))
    }
}

@Test @MainActor func unrelatedCaptureFailuresAreNotMisreportedAsPermissions() async throws {
    let failures = [
        NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStart.rawValue),
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
        NSError(domain: AVFoundationErrorDomain, code: AVError.encoderNotFound.rawValue),
        NSError(domain: NSCocoaErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
    ]
    for original in failures {
        #expect(Permissions.permissionFailure(for: original) == nil)
        do {
            try await Permissions.requireScreen { throw original }
            Issue.record("The underlying failure must be preserved.")
        } catch {
            #expect((error as NSError).domain == original.domain)
            #expect((error as NSError).code == original.code)
        }
    }
}

@Test @MainActor func microphoneDenialAndRestrictionStayDistinct() throws {
    let denial = NSError(domain: AVFoundationErrorDomain, code: AVError.applicationIsNotAuthorizedToUseDevice.rawValue)
    #expect(Permissions.permissionFailure(for: denial)?.permission == .microphone)
    let restricted = CapturePermissionFailure(.microphone, isRestricted: true)
    let mapped = try #require(Permissions.permissionFailure(for: restricted))
    #expect(mapped.isRestricted)
    #expect(mapped.localizedDescription.contains("administrator"))
}

@Test func permissionLinksTargetDifferentSettingsPanes() {
    // Older Foundation versions return nil from URL.query for this custom
    // scheme. Verify the complete link passed to System Settings instead.
    #expect(CapturePermission.screen.settingsURL.absoluteString ==
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    #expect(CapturePermission.microphone.settingsURL.absoluteString ==
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    #expect(CapturePermission.screen.settingsURL != CapturePermission.microphone.settingsURL)
}
