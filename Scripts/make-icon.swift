import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("build/madmd.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func icon(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let square = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
    NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.23, blue: 0.30, alpha: 1), ending: NSColor(srgbRed: 0.055, green: 0.075, blue: 0.11, alpha: 1))!.draw(in: square, angle: -90)
    let path = NSBezierPath(); path.lineWidth = 57; path.lineJoinStyle = .round; path.lineCapStyle = .round
    path.move(to: NSPoint(x: 260, y: 380)); path.line(to: NSPoint(x: 260, y: 630)); path.line(to: NSPoint(x: 390, y: 485)); path.line(to: NSPoint(x: 520, y: 630)); path.line(to: NSPoint(x: 520, y: 380))
    NSColor(srgbRed: 0.94, green: 0.96, blue: 0.98, alpha: 1).setStroke(); path.stroke()
    let arrow = NSBezierPath(); arrow.lineWidth = 48; arrow.lineJoinStyle = .round; arrow.lineCapStyle = .round
    arrow.move(to: NSPoint(x: 710, y: 625)); arrow.line(to: NSPoint(x: 710, y: 390)); arrow.move(to: NSPoint(x: 635, y: 460)); arrow.line(to: NSPoint(x: 710, y: 380)); arrow.line(to: NSPoint(x: 785, y: 460))
    NSColor(srgbRed: 0.47, green: 0.73, blue: 1, alpha: 1).setStroke(); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try icon(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try icon(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
func number(_ value: UInt32) -> Data { var big = value.bigEndian; return withUnsafeBytes(of: &big) { Data($0) } }
var chunks = Data()
for (type, size) in [("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    let png = icon(size)
    chunks.append(Data(type.utf8)); chunks.append(number(UInt32(png.count + 8))); chunks.append(png)
}
let destination = root.appendingPathComponent("App/Resources/madmd.icns")
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try (Data("icns".utf8) + number(UInt32(chunks.count + 8)) + chunks).write(to: destination)
