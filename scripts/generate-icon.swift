import AppKit

// A code-drawn app icon; regenerate with `swift scripts/generate-icon.swift`.
let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(size) / 1024)
        transform.concat()
        let body = NSBezierPath(roundedRect: NSRect(x: 65, y: 65, width: 894, height: 894), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.21, blue: 0.36, alpha: 1),
                   ending: NSColor(srgbRed: 0.07, green: 0.09, blue: 0.18, alpha: 1))!.draw(in: body, angle: 80)
        NSColor(srgbRed: 0.72, green: 0.88, blue: 1, alpha: 1).setStroke()
        for (x, y, dx, dy) in [(285.0, 285.0, 1.0, 1.0), (739.0, 285.0, -1.0, 1.0),
                               (285.0, 739.0, 1.0, -1.0), (739.0, 739.0, -1.0, -1.0)] {
            let corner = NSBezierPath()
            corner.move(to: NSPoint(x: x + dx * 120, y: y))
            corner.line(to: NSPoint(x: x, y: y))
            corner.line(to: NSPoint(x: x, y: y + dy * 120))
            corner.lineWidth = 49
            corner.lineCapStyle = .round
            corner.lineJoinStyle = .round
            corner.stroke()
        }
        NSColor(srgbRed: 1, green: 0.34, blue: 0.37, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 414, y: 414, width: 196, height: 196)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}

// ICNS supports embedded PNG elements. Write the container directly so icon
// generation doesn't depend on the system icon conversion service.
func encodedLength(_ length: Int) -> Data {
    var value = UInt32(length).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var elements = Data()
for (tag, filename) in [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png")
] {
    let data = try Data(contentsOf: directory.appendingPathComponent(filename))
    elements.append(Data(tag.utf8))
    elements.append(encodedLength(data.count + 8))
    elements.append(data)
}
var icon = Data("icns".utf8)
icon.append(encodedLength(elements.count + 8))
icon.append(elements)
try icon.write(to: URL(fileURLWithPath: "Resources/AppIcon.icns"))

