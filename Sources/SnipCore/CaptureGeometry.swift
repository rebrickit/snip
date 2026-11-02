import Foundation
import CoreGraphics

public enum CaptureGeometry {
    /// AppKit uses a bottom-left origin; ScreenCaptureKit's sourceRect uses
    /// top-left coordinates relative to the selected display, in points.
    public static func sourceRect(selection: CGRect, displayFrame: CGRect) -> CGRect? {
        let rect = selection.standardized.intersection(displayFrame)
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { return nil }
        return CGRect(x: rect.minX - displayFrame.minX,
                      y: displayFrame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    public static func pixelSize(points: CGSize, scale: CGFloat, video: Bool) -> CGSize {
        let width = max(1, (points.width * scale).rounded())
        let height = max(1, (points.height * scale).rounded())
        guard video else { return CGSize(width: width, height: height) }
        let ratio = min(1, 3840 / max(width, height))
        // H.264's 4:2:0 output requires even dimensions.
        return CGSize(width: max(2, floor(width * ratio / 2) * 2),
                      height: max(2, floor(height * ratio / 2) * 2))
    }
}

public enum RegionHandle: CaseIterable, Equatable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    fileprivate var horizontal: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .topRight, .right, .bottomRight: 1
        default: 0
        }
    }

    fileprivate var vertical: Int {
        switch self {
        case .topLeft, .top, .topRight: 1
        case .bottomLeft, .bottom, .bottomRight: -1
        default: 0
        }
    }

    public func position(in rect: CGRect) -> CGPoint {
        CGPoint(x: horizontal < 0 ? rect.minX : horizontal > 0 ? rect.maxX : rect.midX,
                y: vertical < 0 ? rect.minY : vertical > 0 ? rect.maxY : rect.midY)
    }
}

public enum RegionHit: Equatable, Sendable {
    case draw, move, resize(RegionHandle)
}

/// All coordinates are local AppKit points. Editing never changes displays;
/// conversion to capture coordinates happens only when the user confirms.
public struct RegionEditor: Sendable {
    public let bounds: CGRect
    public private(set) var selection: CGRect?
    public var isDragging: Bool { drag != nil }
    private var drag: Drag?
    private let minimumSize: CGFloat = 2
    private let hitRadius: CGFloat = 8

    private struct Drag: Sendable {
        let action: RegionHit
        let anchor: CGPoint
        let original: CGRect?
    }

    public init(bounds: CGRect) { self.bounds = bounds }

    public func hit(at point: CGPoint) -> RegionHit {
        guard let selection else { return .draw }
        // Nearest handle wins, including when a very small selection causes
        // handle targets to overlap. Handles take priority over the interior.
        let nearest = RegionHandle.allCases.min {
            distanceSquared(point, $0.position(in: selection)) < distanceSquared(point, $1.position(in: selection))
        }!
        if distanceSquared(point, nearest.position(in: selection)) <= hitRadius * hitRadius {
            return .resize(nearest)
        }
        if point.x >= selection.minX && point.x <= selection.maxX {
            if abs(point.y - selection.maxY) <= hitRadius { return .resize(.top) }
            if abs(point.y - selection.minY) <= hitRadius { return .resize(.bottom) }
        }
        if point.y >= selection.minY && point.y <= selection.maxY {
            if abs(point.x - selection.minX) <= hitRadius { return .resize(.left) }
            if abs(point.x - selection.maxX) <= hitRadius { return .resize(.right) }
        }
        return selection.contains(point) ? .move : .draw
    }

    public mutating func beginDrag(at point: CGPoint) {
        let action = hit(at: point)
        drag = Drag(action: action, anchor: clamped(point), original: selection)
        if action == .draw { selection = nil }
    }

    public mutating func updateDrag(to point: CGPoint) {
        guard let drag else { return }
        let point = clamped(point)
        let dx = point.x - drag.anchor.x
        let dy = point.y - drag.anchor.y
        switch drag.action {
        case .draw:
            selection = CGRect(x: min(drag.anchor.x, point.x), y: min(drag.anchor.y, point.y),
                               width: abs(dx), height: abs(dy))
        case .move:
            guard let original = drag.original else { return }
            selection = CGRect(x: min(max(original.minX + dx, bounds.minX), bounds.maxX - original.width),
                               y: min(max(original.minY + dy, bounds.minY), bounds.maxY - original.height),
                               width: original.width, height: original.height)
        case .resize(let handle):
            guard let original = drag.original else { return }
            var left = original.minX, right = original.maxX
            var bottom = original.minY, top = original.maxY
            if handle.horizontal < 0 { left = max(bounds.minX, min(original.minX + dx, right - minimumSize)) }
            if handle.horizontal > 0 { right = min(bounds.maxX, max(original.maxX + dx, left + minimumSize)) }
            if handle.vertical < 0 { bottom = max(bounds.minY, min(original.minY + dy, top - minimumSize)) }
            if handle.vertical > 0 { top = min(bounds.maxY, max(original.maxY + dy, bottom + minimumSize)) }
            selection = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
        }
    }

    public mutating func endDrag(at point: CGPoint) {
        updateDrag(to: point)
        drag = nil
        if let selection, selection.width < minimumSize || selection.height < minimumSize {
            self.selection = nil
        }
    }

    public mutating func clear() { selection = nil; drag = nil }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }
}

