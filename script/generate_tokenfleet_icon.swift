import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_tokenfleet_icon.swift OUTPUT.icns\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default

func color(_ red: Int, _ green: Int, _ blue: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat(red) / 255,
        green: CGFloat(green) / 255,
        blue: CGFloat(blue) / 255,
        alpha: alpha
    )
}

func drawIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true
    defer { NSGraphicsContext.restoreGraphicsState() }

    let side = CGFloat(pixels)
    let canvas = NSRect(x: 0, y: 0, width: side, height: side)
    NSColor.clear.setFill()
    canvas.fill()

    let inset = side * 0.055
    let tile = canvas.insetBy(dx: inset, dy: inset)
    let tilePath = NSBezierPath(
        roundedRect: tile,
        xRadius: side * 0.225,
        yRadius: side * 0.225
    )
    let background = NSGradient(
        starting: color(6, 30, 39),
        ending: color(11, 57, 66)
    )
    background?.draw(in: tilePath, angle: -52)

    color(120, 234, 216, alpha: 0.10).setStroke()
    tilePath.lineWidth = max(1, side * 0.012)
    tilePath.stroke()

    let barColor = color(92, 222, 201)
    let barWidth = side * 0.115
    let gap = side * 0.068
    let totalWidth = barWidth * 3 + gap * 2
    let startX = (side - totalWidth) / 2
    let baseline = side * 0.27
    let heights = [side * 0.26, side * 0.43, side * 0.61]
    let opacities: [CGFloat] = [0.52, 0.76, 1]

    for index in 0..<3 {
        let rect = NSRect(
            x: startX + CGFloat(index) * (barWidth + gap),
            y: baseline,
            width: barWidth,
            height: heights[index]
        )
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: barWidth / 2,
            yRadius: barWidth / 2
        )
        barColor.withAlphaComponent(opacities[index]).setFill()
        path.fill()
    }

    color(255, 184, 82).setFill()
    NSBezierPath(
        ovalIn: NSRect(
            x: side * 0.72,
            y: side * 0.73,
            width: side * 0.085,
            height: side * 0.085
        )
    ).fill()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

let variants: [(type: String, pixels: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
]

func bigEndianBytes(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}

do {
    var chunks = Data()
    for variant in variants {
        let png = try drawIcon(pixels: variant.pixels)
        chunks.append(Data(variant.type.utf8))
        chunks.append(bigEndianBytes(UInt32(png.count + 8)))
        chunks.append(png)
    }
    var icns = Data("icns".utf8)
    icns.append(bigEndianBytes(UInt32(chunks.count + 8)))
    icns.append(chunks)
    try fileManager.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try icns.write(to: outputURL, options: .atomic)
} catch {
    fputs("TokenFleet icon generation failed.\n", stderr)
    exit(1)
}
