import AppKit
@preconcurrency import ScreenCaptureKit

struct CaptureSelection: @unchecked Sendable {
    let filter: SCContentFilter
    let region: CGRect?

    func configuration(video: Bool, cursor: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let size = CaptureGeometry.pixelSize(points: region?.size ?? filter.contentRect.size,
                                             scale: CGFloat(filter.pointPixelScale), video: video)
        config.width = Int(size.width)
        config.height = Int(size.height)
        if let region { config.sourceRect = region }
        config.showsCursor = video && cursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureDynamicRange = .SDR
        config.colorSpaceName = CGColorSpace.sRGB
        config.ignoreShadowsSingleWindow = true
        config.preservesAspectRatio = true
        config.scalesToFit = true
        return config
    }
}

@MainActor
final class SourcePicker: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<CaptureSelection, Error>?
    private let regionSelector = RegionSelector()

    func choose(area: CaptureArea, kind: CaptureKind) async throws -> CaptureSelection {
        if area == .region {
            try await Permissions.requireScreen()
            let region = try await regionSelector.select(confirmationTitle: kind == .screenshot ? "Capture" : "Record")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw CaptureFailure("The selected display is no longer connected.")
            }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            return CaptureSelection(filter: filter, region: region.rect)
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let picker = SCContentSharingPicker.shared
            var config = SCContentSharingPickerConfiguration()
            config.allowedPickerModes = area == .display ? .singleDisplay : .singleWindow
            config.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "local.snip.app"]
            config.allowsChangingSelectedContent = false
            picker.defaultConfiguration = config
            picker.add(self)
            picker.isActive = true
            picker.present(using: area == .display ? .display : .window)
        }
    }

    func cancel() {
        regionSelector.cancel()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        reset()
    }

    func reset() {
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let selection = CaptureSelection(filter: filter, region: nil)
        Task { @MainActor in
            self.continuation?.resume(returning: selection)
            self.continuation = nil
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.cancel() }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
            self.continuation = nil
            self.reset()
        }
    }
}

struct RegionSelection: Sendable {
    let displayID: CGDirectDisplayID
    let rect: CGRect
}

@MainActor
final class RegionSelector {
    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<RegionSelection, Error>?

    func select(confirmationTitle: String) async throws -> RegionSelection {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            NSApp.activate(ignoringOtherApps: true)
            for screen in NSScreen.screens {
                let panel = SelectionPanel(contentRect: screen.frame, styleMask: .borderless,
                                           backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.level = .screenSaver
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.hasShadow = false
                panel.acceptsMouseMovedEvents = true
                panel.isReleasedWhenClosed = false
                let view = RegionView(frame: CGRect(origin: .zero, size: screen.frame.size), confirmationTitle: confirmationTitle)
                view.onBeginInteraction = { [weak self, weak view] in
                    guard let self, let view else { return }
                    for panel in self.panels {
                        if let other = panel.contentView as? RegionView, other !== view { other.clearSelection() }
                    }
                }
                view.onCancel = { [weak self] in self?.cancel() }
                view.onSelect = { [weak self] local in
                    let global = local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                    guard let rect = CaptureGeometry.sourceRect(selection: global, displayFrame: screen.frame),
                          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
                    self?.complete(RegionSelection(displayID: number.uint32Value, rect: rect))
                }
                panel.contentView = view
                panels.append(panel)
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(view)
            }
        }
    }

    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        close()
    }

    private func complete(_ selection: RegionSelection) {
        continuation?.resume(returning: selection)
        continuation = nil
        close()
    }

    private func close() {
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        NSCursor.arrow.set()
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class RegionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onBeginInteraction: (() -> Void)?
    private var editor: RegionEditor
    private var dragHit: RegionHit?
    private var tracking: NSTrackingArea?
    private let confirmationTitle: String
    private let toolbar = NSVisualEffectView()
    private let confirmButton = NSButton()
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    init(frame: CGRect, confirmationTitle: String) {
        self.confirmationTitle = confirmationTitle
        editor = RegionEditor(bounds: CGRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 10
        toolbar.isHidden = true
        addSubview(toolbar)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        confirmButton.title = confirmationTitle
        confirmButton.target = self
        confirmButton.action = #selector(confirmSelection)
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"
        confirmButton.setAccessibilityLabel("\(confirmationTitle) selected region")
        let buttons = NSStackView(views: [cancelButton, confirmButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 10),
            buttons.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -10)
        ])
        setAccessibilityLabel("Screen region selector")
        setAccessibilityHelp("Drag to select an area. Drag its edges or corners to resize, or drag inside to move. Press Return to \(confirmationTitle.lowercased()) or Escape to cancel.")
    }

    required init?(coder: NSCoder) { nil }

    func clearSelection() {
        editor.clear()
        dragHit = nil
        updatePresentation()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancelSelection()
        case 36, 76: confirmSelection()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        onBeginInteraction?()
        let point = convert(event.locationInWindow, from: nil)
        dragHit = editor.hit(at: point)
        editor.beginDrag(at: point)
        updatePresentation()
        updateCursor(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        editor.updateDrag(to: point)
        updatePresentation()
        updateCursor(at: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        editor.endDrag(at: point)
        dragHit = nil
        updatePresentation()
        updateCursor(at: point)
    }

    @objc private func confirmSelection() {
        guard !editor.isDragging, let selection = editor.selection else { return }
        onSelect?(selection)
    }

    @objc private func cancelSelection() { onCancel?() }

    private func updateCursor(at point: CGPoint) {
        if !toolbar.isHidden, toolbar.frame.contains(point) { NSCursor.arrow.set(); return }
        switch dragHit ?? editor.hit(at: point) {
        case .draw: NSCursor.crosshair.set()
        case .move: (editor.isDragging ? NSCursor.closedHand : NSCursor.openHand).set()
        case .resize(let handle): handle.cursor.set()
        }
    }

    private func updatePresentation() {
        needsDisplay = true
        confirmButton.isEnabled = editor.selection != nil && !editor.isDragging
        toolbar.isHidden = !confirmButton.isEnabled
        guard let selection = editor.selection else { return }
        let size = toolbar.fittingSize
        let margin: CGFloat = 12
        let x = max(margin, min(selection.midX - size.width / 2, bounds.maxX - size.width - margin))
        let below = selection.minY - size.height - margin
        let above = selection.maxY + margin
        // Prefer outside the region; keep controls reachable for full-screen
        // selections by putting them inside when neither outside edge fits.
        let y = below >= margin ? below
            : above + size.height <= bounds.maxY - 100 ? above : selection.minY + margin
        toolbar.frame = CGRect(origin: CGPoint(x: x, y: max(margin, y)), size: size)
    }

    #if DEBUG
    static func preview() -> RegionView {
        let view = RegionView(frame: CGRect(x: 0, y: 0, width: 900, height: 560), confirmationTitle: "Capture")
        view.editor.beginDrag(at: CGPoint(x: 130, y: 120))
        view.editor.endDrag(at: CGPoint(x: 650, y: 400))
        view.editor.beginDrag(at: CGPoint(x: 650, y: 400))
        view.editor.endDrag(at: CGPoint(x: 730, y: 420))
        view.updatePresentation()
        return view
    }
    #endif

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(bounds)
        let shade = NSBezierPath(rect: bounds)
        if let selection = editor.selection { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.36).setFill()
        shade.fill()
        if let selection = editor.selection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            for handle in RegionHandle.allCases {
                let point = handle.position(in: selection)
                let marker = NSBezierPath(roundedRect: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), xRadius: 2, yRadius: 2)
                NSColor.white.setFill()
                marker.fill()
                NSColor.black.withAlphaComponent(0.6).setStroke()
                marker.lineWidth = 1
                marker.stroke()
            }
        }
        let label = editor.selection.map {
            "\(Int($0.width)) × \(Int($0.height)) pt · Drag edges to resize · Drag inside to move\nReturn to \(confirmationTitle.lowercased()) · Esc to cancel"
        } ?? "Drag to select an area · Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        let width = min(size.width, max(0, bounds.width - 32))
        (label as NSString).draw(with: CGRect(x: (bounds.width - width) / 2, y: bounds.height - 90, width: width, height: 60),
                                options: .usesLineFragmentOrigin, attributes: attributes)
    }
}

private extension RegionHandle {
    var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch self {
        case .topLeft: position = .topLeft
        case .top: position = .top
        case .topRight: position = .topRight
        case .right: position = .right
        case .bottomRight: position = .bottomRight
        case .bottom: position = .bottom
        case .bottomLeft: position = .bottomLeft
        case .left: position = .left
        }
        return NSCursor.frameResize(position: position, directions: [.inward, .outward])
    }
}

