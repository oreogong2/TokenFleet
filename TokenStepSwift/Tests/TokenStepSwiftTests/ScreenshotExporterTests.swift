import AppKit
import SwiftUI
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

    func testSwiftUIExportUsesDeterministicTwoTimesPixelScale() throws {
        _ = NSApplication.shared
        let view = Color.tokenMint.frame(width: 120, height: 80)

        let image = try ScreenshotExporter.renderImage(view)
        let png = try ScreenshotExporter.pngData(from: image)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))

        XCTAssertEqual(image.size.width, 120, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 80, accuracy: 0.5)
        XCTAssertEqual(bitmap.pixelsWide, 240)
        XCTAssertEqual(bitmap.pixelsHigh, 160)
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

    func testRealShareCardRendersCopiesAndSavesThroughExporter() throws {
        _ = NSApplication.shared
        let rows = shareRows()
        let view = ShareDailyCardView(
            mode: .today,
            day: rows[2],
            previousDay: rows[1],
            dailyGoalTokens: 100_000_000,
            historyRows: rows,
            historyDays: 180,
            appearanceID: "share-card-test"
        )
        .environment(\.isScreenshotRendering, true)

        let image = try ScreenshotExporter.renderImage(view)
        XCTAssertEqual(image.size.width, 600, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 840, accuracy: 0.5)
        XCTAssertTrue(try ScreenshotExporter.pngData(from: image).starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let clipboard = RecordingClipboardWriter()
        try ScreenshotExporter.copy(view, clipboardWriter: clipboard)
        XCTAssertTrue(clipboard.data?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenFleetShareCard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedURL = try ScreenshotExporter.saveJPGToDownloads(
            view,
            downloadsDirectory: directory,
            revealInFinder: false
        )
        let saved = try Data(contentsOf: savedURL)
        XCTAssertEqual(savedURL.deletingLastPathComponent(), directory)
        XCTAssertTrue(saved.starts(with: [0xFF, 0xD8, 0xFF]))
    }

    func testYesterdayShareCardRendersZeroUsageAndLongModelNames() throws {
        _ = NSApplication.shared
        let day = DailyUsage(
            date: "2026-08-13",
            tools: [:],
            models: [String(repeating: "very-long-model-", count: 20): 0],
            totalTokens: 0,
            cost: 0,
            pricedTokens: 0,
            unpricedTokens: 0,
            pricingVersion: "public-api-2026-08"
        )
        let view = ShareDailyCardView(
            mode: .yesterday,
            day: day,
            previousDay: nil,
            dailyGoalTokens: 100_000_000,
            historyRows: [day],
            historyDays: 180,
            appearanceID: "share-card-zero-test"
        )
        .environment(\.isScreenshotRendering, true)

        let image = try ScreenshotExporter.renderImage(view)
        XCTAssertTrue(try ScreenshotExporter.jpgData(from: image).starts(with: [0xFF, 0xD8, 0xFF]))
    }

    private func solidImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    private final class RecordingClipboardWriter: ScreenshotClipboardWriting {
        var data: Data?

        func replacePNG(with data: Data) -> Bool {
            self.data = data
            return true
        }
    }

    private func shareRows() -> [DailyUsage] {
        [
            DailyUsage(
                date: "2026-08-11",
                tools: ["Codex": 40_000_000],
                models: ["gpt-5": 40_000_000],
                totalTokens: 40_000_000,
                cost: 1.25,
                pricedTokens: 40_000_000,
                unpricedTokens: 0,
                pricingVersion: "public-api-2026-08"
            ),
            DailyUsage(
                date: "2026-08-12",
                tools: ["Codex": 60_000_000, "Claude Code": 20_000_000],
                models: ["gpt-5": 60_000_000, "claude-sonnet-4": 20_000_000],
                totalTokens: 80_000_000,
                cost: 2.5,
                pricedTokens: 80_000_000,
                unpricedTokens: 0,
                pricingVersion: "public-api-2026-08"
            ),
            DailyUsage(
                date: "2026-08-13",
                tools: ["Codex": 105_000_000, "Claude Code": 15_000_000],
                models: ["gpt-5": 105_000_000, "claude-sonnet-4": 15_000_000],
                totalTokens: 120_000_000,
                cost: 4.75,
                pricedTokens: 110_000_000,
                unpricedTokens: 10_000_000,
                pricingVersion: "public-api-2026-08"
            )
        ]
    }
}
