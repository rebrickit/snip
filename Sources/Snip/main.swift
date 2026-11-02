import AppKit
#if DEBUG
import SwiftUI
#endif

let application = NSApplication.shared
#if DEBUG
// Off-screen UI smoke check: renders only Snip's own views, with no screen or
// microphone capture and no changes to the user's persistent preferences.
if let flag = CommandLine.arguments.firstIndex(of: "--render-preview") ?? CommandLine.arguments.firstIndex(of: "--render-region-preview"),
   CommandLine.arguments.count > flag + 1 {
    let defaults = UserDefaults(suiteName: "local.snip.preview.\(UUID().uuidString)")!
    let model = CaptureCoordinator(settings: AppSettings(defaults: defaults))
    application.setActivationPolicy(.prohibited)
    application.finishLaunching()
    let view: NSView
    let size: CGSize
    if CommandLine.arguments[flag] == "--render-region-preview" {
        let region = RegionView.preview()
        view = NSView(frame: region.frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.lightGray.cgColor
        view.addSubview(region)
        size = region.frame.size
    } else {
        let panel = CapturePanel(coordinator: model, openSettings: {}, quit: {})
            .environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor))
        view = NSHostingView(rootView: panel)
        size = view.fittingSize
    }
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    do {
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        exit(0)
    } catch {
        fputs("Preview rendering failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
#endif
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

