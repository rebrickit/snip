import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: CaptureCoordinator
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var shortcuts: GlobalShortcuts?
    private var timer: Timer?
    private var restarting = false

    override init() {
        coordinator = CaptureCoordinator(settings: AppSettings())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Snip")
            button.target = self
            button.action = #selector(togglePanel)
        }
        popover.behavior = .transient
        let panelController = NSHostingController(rootView: CapturePanel(
            coordinator: coordinator,
            openSettings: { [weak self] in self?.openSettings() },
            quit: { NSApp.terminate(nil) }))
        panelController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panelController
        popover.contentSize = panelController.view.fittingSize
        coordinator.hidePanel = { [weak self] in self?.popover.performClose(nil) }
        coordinator.showPanel = { [weak self] in self?.showPanel() }
        coordinator.restartApp = { [weak self] in self?.restart() }
        let shortcuts = GlobalShortcuts { [weak self] identifier in
            switch identifier {
            case 0: self?.coordinator.begin(.screenshot)
            case 1: self?.coordinator.begin(.video)
            case 2: self?.coordinator.begin(.audio)
            case 3: self?.coordinator.stop()
            default: break
            }
        }
        self.shortcuts = shortcuts
        coordinator.shortcutWarning = shortcuts.register()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
                                                           name: NSWorkspace.willSleepNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        showPanel()
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatus() {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch coordinator.state {
        case .recording:
            symbol = "record.circle.fill"
            let elapsed = max(0, Int(Date().timeIntervalSince(coordinator.startedAt ?? Date())))
            button.title = String(format: " %02d:%02d", elapsed / 60, elapsed % 60)
            button.contentTintColor = .systemRed
        case .countdown(let seconds):
            symbol = "record.circle"
            button.title = " \(seconds)"
            button.contentTintColor = .systemOrange
        case .finalizing, .starting:
            symbol = "hourglass"
            button.title = ""
            button.contentTintColor = nil
        default:
            symbol = "viewfinder"
            button.title = ""
            button.contentTintColor = nil
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Snip")
        button.toolTip = coordinator.state == .recording ? "Snip is recording — click to stop" : "Snip — screen and audio capture"
    }

    private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(settings: coordinator.settings, coordinator: coordinator))
            let window = NSWindow(contentViewController: controller)
            window.title = "Snip Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func restart() {
        guard !coordinator.state.isBusy, !restarting else { return }
        restarting = true
        // The replacement registers shortcuts at launch. Release ours first so
        // the brief overlap cannot leave the new process with conflicts.
        shortcuts?.unregister()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] app, error in
            let failure = error?.localizedDescription ?? (app == nil ? "macOS didn’t launch the app." : nil)
            Task { @MainActor in
                guard let self else { return }
                if let failure {
                    self.restarting = false
                    self.coordinator.shortcutWarning = self.shortcuts?.register()
                    self.coordinator.message = "Couldn’t restart Snip: \(failure) Quit and reopen this copy manually."
                    self.showPanel()
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    @objc private func willSleep() { coordinator.prepareForSleep() }
    @objc private func displaysChanged() {
        if coordinator.selectedKind != .audio {
            coordinator.interrupted("Recording stopped because the display configuration changed.")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator.state.isBusy else { return .terminateNow }
        if coordinator.state.canCancel { coordinator.cancel() }
        else if coordinator.state == .recording { coordinator.stop() }
        Task {
            while coordinator.state.isBusy {
                if coordinator.state == .recording { coordinator.stop() }
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts?.unregister()
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
}

