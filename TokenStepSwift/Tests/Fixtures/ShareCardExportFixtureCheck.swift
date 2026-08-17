import AppKit
import Foundation
import SwiftUI
@testable import TokenStepSwift

enum ShareCardFixtureError: Error {
    case failed(String)
}

@MainActor
private final class RecordingClipboardWriter: ScreenshotClipboardWriting {
    var data: Data?

    func replacePNG(with data: Data) -> Bool {
        self.data = data
        return true
    }
}

@main
struct ShareCardExportFixtureCheck {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let rows = fixtureRows()
        let view = ShareDailyCardView(
            mode: .today,
            day: rows[2],
            previousDay: rows[1],
            dailyGoalTokens: 100_000_000,
            historyRows: rows,
            historyDays: 180,
            appearanceID: "share-card-fixture"
        )
        .environment(\.isScreenshotRendering, true)

        let image = try ScreenshotExporter.renderImage(view)
        try require(abs(image.size.width - 600) < 0.5, "unexpected share-card width")
        try require(abs(image.size.height - 840) < 0.5, "unexpected share-card height")

        let clipboard = RecordingClipboardWriter()
        try ScreenshotExporter.copy(view, clipboardWriter: clipboard)
        let png = clipboard.data
        try require(
            png?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true,
            "real share card did not reach the clipboard PNG stage"
        )

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TokenFleetShareCardFixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedURL = try ScreenshotExporter.saveJPGToDownloads(
            view,
            downloadsDirectory: directory,
            revealInFinder: false
        )
        let jpg = try Data(contentsOf: savedURL)
        try require(
            jpg.starts(with: [0xFF, 0xD8, 0xFF]),
            "real share card did not reach the saved JPEG stage"
        )

        print("TokenFleet share-card render/copy/save fixture passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw ShareCardFixtureError.failed(message)
        }
    }

    private static func fixtureRows() -> [DailyUsage] {
        [
            day("2026-08-11", 40_000_000),
            day("2026-08-12", 80_000_000),
            day("2026-08-13", 120_000_000)
        ]
    }

    private static func day(_ date: String, _ totalTokens: Int) -> DailyUsage {
        DailyUsage(
            date: date,
            tools: ["Codex": totalTokens],
            models: ["gpt-5": totalTokens],
            totalTokens: totalTokens,
            cost: Double(totalTokens) / 40_000_000,
            pricedTokens: totalTokens,
            unpricedTokens: 0,
            pricingVersion: "public-api-2026-08"
        )
    }
}
