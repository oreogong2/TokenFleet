import AppKit
import XCTest
@testable import TokenStepSwift

@MainActor
final class ScreenshotExporterTests: XCTestCase {
    func testGeneratedImageEncodesAsPNGAndJPGWithoutTIFFRoundTrip() throws {
        let image = solidImage(size: NSSize(width: 120, height: 80))

        let png = try ScreenshotExporter.pngData(from: image)
        let jpg = try ScreenshotExporter.jpgData(from: image)

        XCTAssertTrue(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        XCTAssertTrue(jpg.starts(with: [0xFF, 0xD8, 0xFF]))
        XCTAssertTrue(png.count > 100)
        XCTAssertTrue(jpg.count > 100)
    }

    func testEveryExportFailureNamesItsStage() {
        let messages = [
            ScreenshotExportError.renderFailed.errorDescription,
            ScreenshotExportError.pngEncodingFailed.errorDescription,
            ScreenshotExportError.jpgEncodingFailed.errorDescription,
            ScreenshotExportError.clipboardWriteFailed.errorDescription,
            ScreenshotExportError.downloadsUnavailable.errorDescription,
            ScreenshotExportError.fileWriteFailed.errorDescription
        ]

        XCTAssertTrue(messages.allSatisfy { ($0 ?? "").isEmpty == false })
        XCTAssertEqual(Set(messages.compactMap { $0 }).count, messages.count)
    }

    private func solidImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
}
