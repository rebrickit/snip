import Testing
import Foundation
@testable import SnipCore

private func expectTransition(_ result: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(result, sourceLocation: sourceLocation)
}

@Test func lifecycleRejectsOverlappingOperations() {
    var lifecycle = CaptureLifecycle()
    expectTransition(lifecycle.begin())
    expectTransition(!lifecycle.begin())
    expectTransition(lifecycle.transition(to: .countdown(3)))
    expectTransition(!lifecycle.transition(to: .recording))
    expectTransition(lifecycle.transition(to: .countdown(2)))
    expectTransition(lifecycle.transition(to: .countdown(1)))
    expectTransition(lifecycle.transition(to: .starting))
    expectTransition(!lifecycle.cancel())
    expectTransition(lifecycle.transition(to: .recording))
    expectTransition(lifecycle.transition(to: .finalizing))
    expectTransition(!lifecycle.transition(to: .finalizing))
    expectTransition(!lifecycle.begin())
    lifecycle.finish()
    expectTransition(lifecycle.begin())
    expectTransition(lifecycle.cancel())
    #expect(lifecycle.state == .idle)
}

@Test func cancelDuringCountdownAllowsFreshCapture() {
    var lifecycle = CaptureLifecycle()
    expectTransition(lifecycle.begin())
    expectTransition(lifecycle.transition(to: .countdown(3)))
    expectTransition(lifecycle.cancel())
    expectTransition(!lifecycle.transition(to: .starting))
    expectTransition(lifecycle.begin())
}

@Test func regionUsesDisplayLocalTopLeftPoints() throws {
    let display = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
    let selection = CGRect(x: -1800, y: 1000, width: 300, height: 200)
    let source = try #require(CaptureGeometry.sourceRect(selection: selection, displayFrame: display))
    #expect(source == CGRect(x: 120, y: 80, width: 300, height: 200))
    #expect(CaptureGeometry.pixelSize(points: source.size, scale: 2, video: false) == CGSize(width: 600, height: 400))
    #expect(CaptureGeometry.pixelSize(points: source.size, scale: 1, video: false) == source.size)
}

@Test func regionClampsToOneDisplayAndRejectsEmptySelection() {
    let display = CGRect(x: 100, y: -900, width: 1440, height: 900)
    let selected = CGRect(x: 90, y: -910, width: 100, height: 100)
    #expect(CaptureGeometry.sourceRect(selection: selected, displayFrame: display) == CGRect(x: 0, y: 810, width: 90, height: 90))
    #expect(CaptureGeometry.sourceRect(selection: .zero, displayFrame: display) == nil)
}

@Test func videoDimensionsAreEvenAndBounded() {
    #expect(CaptureGeometry.pixelSize(points: CGSize(width: 3024, height: 1964), scale: 2, video: true) == CGSize(width: 3840, height: 2492))
    #expect(CaptureGeometry.pixelSize(points: CGSize(width: 333, height: 111), scale: 1, video: true) == CGSize(width: 332, height: 110))
}

@Test func filenamesDoNotOverwriteExistingCaptures() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try ArtifactStore.prepare(directory: dir)
    defer { try? FileManager.default.removeItem(at: dir) }
    let date = Date(timeIntervalSince1970: 1000)
    let first = ArtifactStore.uniqueURL(directory: dir, kind: .screenshot, date: date)
    try Data("original".utf8).write(to: first)
    let second = ArtifactStore.uniqueURL(directory: dir, kind: .screenshot, date: date)
    #expect(first != second)
    #expect(second.lastPathComponent.hasSuffix("-1.png"))
    #expect(try String(contentsOf: first, encoding: .utf8) == "original")
    let partial = dir.appendingPathComponent(".partial")
    try Data("completed".utf8).write(to: partial)
    let published = try ArtifactStore.publish(partial, directory: dir, kind: .audio)
    #expect(published.pathExtension == "m4a")
    #expect(!FileManager.default.fileExists(atPath: partial.path))
}

private func regionEditor() -> RegionEditor {
    var editor = RegionEditor(bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
    editor.beginDrag(at: CGPoint(x: 100, y: 100))
    editor.endDrag(at: CGPoint(x: 300, y: 200))
    return editor
}

@Test func regionRemainsEditableAfterDrawingAndCanBeReplaced() {
    var editor = regionEditor()
    #expect(!editor.isDragging)
    #expect(editor.selection == CGRect(x: 100, y: 100, width: 200, height: 100))
    editor.beginDrag(at: CGPoint(x: 600, y: 500))
    editor.endDrag(at: CGPoint(x: 400, y: 300))
    #expect(editor.selection == CGRect(x: 400, y: 300, width: 200, height: 200))
    editor.clear()
    #expect(editor.selection == nil)
    editor.beginDrag(at: CGPoint(x: 20, y: 20))
    editor.endDrag(at: CGPoint(x: 20, y: 20))
    #expect(editor.selection == nil)
}

@Test(arguments: [
    (RegionHandle.topLeft, CGRect(x: 140, y: 100, width: 160, height: 130)),
    (.top, CGRect(x: 100, y: 100, width: 200, height: 130)),
    (.topRight, CGRect(x: 100, y: 100, width: 240, height: 130)),
    (.right, CGRect(x: 100, y: 100, width: 240, height: 100)),
    (.bottomRight, CGRect(x: 100, y: 130, width: 240, height: 70)),
    (.bottom, CGRect(x: 100, y: 130, width: 200, height: 70)),
    (.bottomLeft, CGRect(x: 140, y: 130, width: 160, height: 70)),
    (.left, CGRect(x: 140, y: 100, width: 160, height: 100))
])
func resizingRegionKeepsOppositeEdgesFixed(handle: RegionHandle, expected: CGRect) throws {
    var editor = regionEditor()
    let start = handle.position(in: try #require(editor.selection))
    #expect(editor.hit(at: start) == .resize(handle))
    editor.beginDrag(at: start)
    editor.endDrag(at: CGPoint(x: start.x + 40, y: start.y + 30))
    #expect(editor.selection == expected)
}

@Test func regionHitTestingDistinguishesEdgesInteriorAndOutside() {
    let editor = regionEditor()
    #expect(editor.hit(at: CGPoint(x: 140, y: 205)) == .resize(.top))
    #expect(editor.hit(at: CGPoint(x: 95, y: 135)) == .resize(.left))
    #expect(editor.hit(at: CGPoint(x: 200, y: 150)) == .move)
    #expect(editor.hit(at: CGPoint(x: 400, y: 300)) == .draw)
}

@Test func movingRegionPreservesSizeAndClampsToDisplay() {
    var editor = regionEditor()
    editor.beginDrag(at: CGPoint(x: 200, y: 150))
    editor.updateDrag(to: CGPoint(x: 2000, y: -100))
    #expect(editor.selection == CGRect(x: 600, y: 0, width: 200, height: 100))
    editor.endDrag(at: CGPoint(x: 220, y: 170))
    #expect(editor.selection == CGRect(x: 120, y: 120, width: 200, height: 100))
}

@Test func resizingRegionClampsToDisplayAndCannotInvert() {
    var editor = regionEditor()
    editor.beginDrag(at: CGPoint(x: 100, y: 200))
    editor.endDrag(at: CGPoint(x: -100, y: 900))
    #expect(editor.selection == CGRect(x: 0, y: 100, width: 300, height: 500))
    editor = regionEditor()
    editor.beginDrag(at: CGPoint(x: 300, y: 150))
    editor.endDrag(at: CGPoint(x: -100, y: 150))
    #expect(editor.selection == CGRect(x: 100, y: 100, width: 2, height: 100))
}

@Test func editedRegionMapsToScreenshotAndVideoCaptureCoordinates() throws {
    var editor = regionEditor()
    editor.beginDrag(at: CGPoint(x: 300, y: 200))
    editor.endDrag(at: CGPoint(x: 500, y: 350))
    let selection = try #require(editor.selection)
    let display = CGRect(x: -800, y: 100, width: 800, height: 600)
    let global = selection.offsetBy(dx: display.minX, dy: display.minY)
    let source = try #require(CaptureGeometry.sourceRect(selection: global, displayFrame: display))
    #expect(source == CGRect(x: 100, y: 250, width: 400, height: 250))
    #expect(CaptureGeometry.pixelSize(points: source.size, scale: 2, video: false) == CGSize(width: 800, height: 500))
    #expect(CaptureGeometry.pixelSize(points: source.size, scale: 2, video: true) == CGSize(width: 800, height: 500))
}
