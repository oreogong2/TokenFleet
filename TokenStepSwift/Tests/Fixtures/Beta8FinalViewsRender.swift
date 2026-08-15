import AppKit
import Foundation
import SwiftUI
@testable import TokenStepSwift

enum Beta8FinalViewsRenderError: Error {
    case failed(String)
}

@MainActor
private final class Beta8RecordingClipboardWriter: ScreenshotClipboardWriting {
    var data: Data?

    func replacePNG(with data: Data) -> Bool {
        self.data = data
        return true
    }
}

@main
struct Beta8FinalViewsRender {
    private static let serverOrigin = Beta8CommunityRenderFixture.serverOrigin

    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        try validateIsolation()
        try validateSparseCalendarWindow()
        try seedAppSupport()

        guard let rawOutputDirectory = ProcessInfo.processInfo.environment[
            "TOKENFLEET_BETA8_RENDER_DIR"
        ], !rawOutputDirectory.isEmpty else {
            throw Beta8FinalViewsRenderError.failed(
                "TOKENFLEET_BETA8_RENDER_DIR is required"
            )
        }
        let outputDirectory = URL(
            fileURLWithPath: rawOutputDirectory,
            isDirectory: true
        ).standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let rank = Beta8CommunityRenderFixture.rank()
        let leaderboard = Beta8CommunityRenderFixture.leaderboard()
        try require(rank.isValid, "fixture rank must satisfy the public contract")
        try require(leaderboard.isValid, "fixture leaderboard must satisfy the public contract")
        try require(
            !leaderboard.entries.contains(where: { $0.publicID == rank.publicID }),
            "fixture owner must stay outside Top 10"
        )
        try require(
            rank.rank == 18 && rank.primaryTool == "Codex"
                && rank.primaryModel == "gpt-5.6-sol"
                && rank.totals?.estimatedCost != nil,
            "fixture owner must retain its signed public summary beyond Top 10"
        )

        let appState = AppState(testingCommunityServerOrigin: serverOrigin)
        appState.applyCommunityRenderFixture(rank: rank, leaderboard: leaderboard)
        appState.applyQuotaRenderFixture(
            codex: fixtureQuota(fiveHourUsed: 23, sevenDayUsed: 41),
            claude: fixtureQuota(fiveHourUsed: 36, sevenDayUsed: 58)
        )
        try require(
            appState.isCommunitySyncEnrollmentCompatible,
            "render fixture must bind the existing member to the fixed community origin"
        )
        try validateCurrentHistoryCapture(appState: appState)

        let popover = PopoverPanelView()
            .environmentObject(appState)
            .environment(\.colorScheme, .light)
            .environment(\.isScreenshotRendering, true)
        let popoverImage = try writePNG(
            popover,
            to: outputDirectory.appendingPathComponent("01-single-screen-entry.png")
        )
        try require(abs(popoverImage.size.width - 625) < 0.5, "unexpected popover width")
        try require(popoverImage.size.height >= 420, "popover render is unexpectedly short")

        let todayPage = DashboardScreenshotView(section: .today)
            .environmentObject(appState)
            .environment(\.colorScheme, .light)
            .environment(\.isScreenshotRendering, true)
        let todayImage = try writePNG(
            todayPage,
            to: outputDirectory.appendingPathComponent("02-today-window.png")
        )
        try require(
            abs(todayImage.size.width - 1_180) < 0.5
                && abs(todayImage.size.height - 1_080) < 0.5,
            "unexpected today main-window capture size"
        )

        let historyPage = DashboardScreenshotView(section: .history)
            .environmentObject(appState)
            .environment(\.colorScheme, .light)
            .environment(\.isScreenshotRendering, true)
        let historyImage = try writePNG(
            historyPage,
            to: outputDirectory.appendingPathComponent("03-history-activity.png")
        )
        try require(
            abs(historyImage.size.width - 1_180) < 0.5
                && abs(historyImage.size.height - 760) < 0.5,
            "unexpected sparse-history current-page capture size"
        )
        try validateHistoryContributionGeometry()

        for historySection in HistorySection.allCases {
            let expandedDates: Set<String> = historySection == .daily
                ? [DateFormatter.tokenStepDay.string(from: Date())]
                : []
            let page = DashboardScreenshotView(
                section: .history,
                historySection: historySection,
                historyRange: .all,
                historyExpandedDates: expandedDates
            )
            .environmentObject(appState)
            .environment(\.colorScheme, .light)
            .environment(\.isScreenshotRendering, true)
            let image = try writePNG(
                page,
                to: outputDirectory.appendingPathComponent(
                    "03-section-\(historySection.rawValue).png"
                )
            )
            try require(
                abs(image.size.width - 1_180) < 0.5
                    && abs(image.size.height - 760) < 0.5,
                "unexpected \(historySection.rawValue) history capture size"
            )
        }

        for historyRange in HistoryRange.allCases {
            let page = DashboardScreenshotView(
                section: .history,
                historySection: .overview,
                historyRange: historyRange
            )
            .environmentObject(appState)
            .environment(\.colorScheme, .light)
            .environment(\.isScreenshotRendering, true)
            let image = try writePNG(
                page,
                to: outputDirectory.appendingPathComponent(
                    "03-range-\(historyRange.rawValue).png"
                )
            )
            try require(
                abs(image.size.width - 1_180) < 0.5
                    && abs(image.size.height - 760) < 0.5,
                "unexpected \(historyRange.rawValue) history range capture size"
            )
        }

        let communityPage = DashboardScreenshotView(section: .community)
            .environmentObject(appState)
            .environment(\.colorScheme, .light)
            .environment(\.isScreenshotRendering, true)
        let communityImage = try writePNG(
            communityPage,
            to: outputDirectory.appendingPathComponent("04-app-community-rank.png")
        )
        try require(
            abs(communityImage.size.width - 1_180) < 0.5
                && abs(communityImage.size.height - 760) < 0.5,
            "unexpected App current-page capture size"
        )

        for section in TokenFleetSettingsSection.allCases {
            let settingsPage = SettingsWindowScreenshotView(section: section)
                .environmentObject(appState)
                .environment(\.colorScheme, .light)
                .environment(\.isScreenshotRendering, true)
            let image = try writePNG(
                settingsPage,
                to: outputDirectory.appendingPathComponent(
                    "06-settings-\(section.rawValue).png"
                )
            )
            try require(
                abs(image.size.width - 980) < 0.5
                    && abs(image.size.height - 760) < 0.5,
                "unexpected \(section.rawValue) settings capture size"
            )
        }

        let poster = CommunityRankingShareView(
            rank: rank,
            leaderboard: leaderboard,
            appearanceID: appState.appearanceID,
            leaderboardURL: URL(string: "\(serverOrigin)/rank")
        )
        .environment(\.colorScheme, .light)
        .environment(\.isScreenshotRendering, true)

        let posterURL = outputDirectory.appendingPathComponent("05-share-ranking.png")
        let posterImage = try writePNG(poster, to: posterURL)
        try require(
            abs(posterImage.size.width - 600) < 0.5
                && abs(posterImage.size.height - 800) < 0.5,
            "ranking poster must be a 600 x 800 point canvas"
        )
        let savedPosterPNG = try Data(contentsOf: posterURL)
        try validatePosterPNG(savedPosterPNG, stage: "saved")

        let clipboard = Beta8RecordingClipboardWriter()
        try ScreenshotExporter.copy(poster, clipboardWriter: clipboard)
        guard let clipboardPNG = clipboard.data else {
            throw Beta8FinalViewsRenderError.failed(
                "ranking poster did not reach the clipboard PNG stage"
            )
        }
        try validatePosterPNG(clipboardPNG, stage: "clipboard")

        print("TokenFleet beta.8 final Swift views render/copy/save fixture passed")
        print(outputDirectory.path)
    }

    private static func validateIsolation() throws {
        guard let override = ProcessInfo.processInfo.environment[
            "TOKENFLEET_TEST_APP_SUPPORT_ROOT"
        ], !override.isEmpty else {
            throw Beta8FinalViewsRenderError.failed(
                "TOKENFLEET_TEST_APP_SUPPORT_ROOT is required"
            )
        }
        let expected = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        try require(
            AppPaths.appSupportRoot.standardizedFileURL == expected,
            "fixture refused to use non-test App Support"
        )
    }

    private static func validateSparseCalendarWindow() throws {
        guard let endingAt = DateFormatter.tokenStepDay.date(from: "2026-08-14") else {
            throw Beta8FinalViewsRenderError.failed("cannot create calendar-window fixture date")
        }
        let rows = UsageCalendarWindow.rows(
            from: [
                DailyUsage(date: "2026-08-01", tools: ["Codex": 900], totalTokens: 900, cost: 9),
                DailyUsage(date: "2026-08-10", tools: ["Codex": 100], totalTokens: 100, cost: 1),
                DailyUsage(date: "2026-08-14", tools: ["Codex": 300], totalTokens: 300, cost: 3),
            ],
            days: 7,
            endingAt: endingAt
        )
        try require(rows.count == 7, "seven-day history must contain seven calendar buckets")
        try require(
            rows.first?.date == "2026-08-08" && rows.last?.date == "2026-08-14",
            "seven-day history crossed its calendar boundary"
        )
        try require(
            rows.map(\.totalTokens).reduce(0, +) == 400
                && rows.filter({ $0.totalTokens == 0 }).count == 5,
            "sparse history was not zero-filled without importing older activity"
        )
    }

    private static func validateHistoryContributionGeometry() throws {
        try require(
            abs(HistoryContributionLayout.gridHeight - 102) < 0.01,
            "history contribution grid must show all seven rows"
        )
        for range in HistoryRange.allCases {
            try require(
                HistoryContributionLayout.gridWidth(weeks: range.wallWeeks)
                    <= HistoryContributionLayout.maximumWidth,
                "\(range.rawValue) contribution grid exceeds its visible width"
            )
        }
    }

    @MainActor
    private static func validateCurrentHistoryCapture(appState: AppState) throws {
        let presentation = HistoryPresentationState()
        let currentPage = DashboardScreenshotView(
            section: .history,
            historyPresentation: presentation
        )
        .environmentObject(appState)
        .environment(\.colorScheme, .light)
        .environment(\.isScreenshotRendering, true)

        presentation.section = .tools
        presentation.range = .sevenDays

        let expectedPage = DashboardScreenshotView(
            section: .history,
            historySection: .tools,
            historyRange: .sevenDays
        )
        .environmentObject(appState)
        .environment(\.colorScheme, .light)
        .environment(\.isScreenshotRendering, true)

        let currentPNG = try ScreenshotExporter.pngData(
            from: ScreenshotExporter.renderImage(currentPage)
        )
        let expectedPNG = try ScreenshotExporter.pngData(
            from: ScreenshotExporter.renderImage(expectedPage)
        )
        try require(
            currentPNG == expectedPNG,
            "current-page capture ignored the live history section or range"
        )
    }

    private static func seedAppSupport() throws {
        let calendar = Calendar(identifier: .gregorian)
        let todayKey = DateFormatter.tokenStepDay.string(from: Date())
        let today = DateFormatter.tokenStepDay.date(from: todayKey) ?? Date()
        let totals = [
            128_000_000, 176_000_000, 93_000_000, 242_000_000,
            308_000_000, 415_000_000, 267_000_000, 528_000_000,
            394_000_000, 612_000_000, 486_000_000, 734_000_000,
            645_000_000, 1_088_000_000
        ]
        let sparseGapIndexes: Set<Int> = [2, 7, 11]
        let days: [DailyUsage] = totals.enumerated().compactMap { index, total in
            guard !sparseGapIndexes.contains(index) else { return nil }
            guard let date = calendar.date(
                byAdding: .day,
                value: index - (totals.count - 1),
                to: today
            ) else { return nil }
            let codex = Int(Double(total) * 0.82)
            let claude = total - codex
            let sol = Int(Double(total) * 0.61)
            let terra = codex - sol
            let opus = claude
            return DailyUsage(
                date: DateFormatter.tokenStepDay.string(from: date),
                tools: ["Codex": codex, "Claude Code": claude],
                models: [
                    "gpt-5.6-sol": sol,
                    "claude-opus-4.1": opus,
                    "gpt-5.6-terra": terra
                ],
                atomicUsage: [
                    atomicUsage(tool: "Codex", model: "gpt-5.6-sol", tokens: sol),
                    atomicUsage(tool: "Codex", model: "gpt-5.6-terra", tokens: terra),
                    atomicUsage(tool: "Claude Code", model: "claude-opus-4.1", tokens: opus),
                ],
                totalTokens: total,
                cost: Double(total) / 790_000,
                pricedTokens: Int(Double(total) * 0.94),
                unpricedTokens: total - Int(Double(total) * 0.94),
                pricingVersion: "public-api-2026-08"
            )
        }
        let grandTotal = days.map(\.totalTokens).reduce(0, +)
        let codexTotal = days.compactMap { $0.tools["Codex"] }.reduce(0, +)
        let claudeTotal = grandTotal - codexTotal
        let solTotal = days.compactMap { $0.models["gpt-5.6-sol"] }.reduce(0, +)
        let opusTotal = days.compactMap { $0.models["claude-opus-4.1"] }.reduce(0, +)
        let terraTotal = grandTotal - solTotal - opusTotal

        let snapshot = UsageSnapshot(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            timezone: "Asia/Shanghai",
            totals: UsageTotals(
                tokens: grandTotal,
                cost: days.map(\.cost).reduce(0, +),
                activeDays: days.count,
                pricedTokens: Int(Double(grandTotal) * 0.94),
                unpricedTokens: grandTotal - Int(Double(grandTotal) * 0.94),
                pricingVersion: "public-api-2026-08"
            ),
            daily: days,
            rhythms: [todayRhythm(date: todayKey)],
            agentWork: [todayAgentWork(date: todayKey)],
            tools: [
                ToolUsage(
                    tool: "Codex",
                    tokens: codexTotal,
                    percent: Double(codexTotal) * 100 / Double(grandTotal)
                ),
                ToolUsage(
                    tool: "Claude Code",
                    tokens: claudeTotal,
                    percent: Double(claudeTotal) * 100 / Double(grandTotal)
                )
            ],
            models: [
                ModelUsage(
                    model: "gpt-5.6-sol",
                    tool: "Codex",
                    tokens: solTotal,
                    percent: Double(solTotal) * 100 / Double(grandTotal)
                ),
                ModelUsage(
                    model: "claude-opus-4.1",
                    tool: "Claude Code",
                    tokens: opusTotal,
                    percent: Double(opusTotal) * 100 / Double(grandTotal)
                ),
                ModelUsage(
                    model: "gpt-5.6-terra",
                    tool: "Codex",
                    tokens: terraTotal,
                    percent: Double(terraTotal) * 100 / Double(grandTotal)
                )
            ],
            sources: [
                "Codex": SourceInfo(
                    status: "ok",
                    files: 684,
                    records: 2_912,
                    accountingRevision: UsageCollector.codexAccountingRevision
                ),
                "Claude Code": SourceInfo(status: "ok", files: 84, records: 1_204)
            ]
        )
        let settings = TokenStepSettings(
            dailyGoalTokens: 100_000_000,
            refreshIntervalSeconds: 0,
            historyDays: 180,
            theme: .green,
            autoUpdateEnabled: false,
            askBeforeDownloadingUpdates: true,
            requireVerifiedUpdates: true,
            tokenIslandEnabled: false,
            tokenIslandPlacement: .menuBar,
            showCodexQuota: true,
            showExperimentalAgentSources: true,
            language: .zhHans,
            skippedUpdateVersion: nil,
            teamSyncEnabled: false,
            teamSyncServerURL: serverOrigin
        )

        try writeJSON(snapshot, to: AppPaths.usageJSON)
        try writeJSON(settings, to: AppPaths.settingsJSON)
        try FileManager.default.createDirectory(
            at: AppPaths.autostartDefaultMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture\n".utf8).write(
            to: AppPaths.autostartDefaultMarker,
            options: .atomic
        )
    }

    private static func atomicUsage(tool: String, model: String, tokens: Int) -> DailyAtomicUsage {
        let input = Int(Double(tokens) * 0.40)
        let output = Int(Double(tokens) * 0.10)
        let cacheRead = tokens - input - output
        return DailyAtomicUsage(
            tool: tool,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: 0,
            totalTokens: tokens,
            breakdownComplete: true
        )
    }

    private static func fixtureQuota(
        fiveHourUsed: Double,
        sevenDayUsed: Double
    ) -> CodexQuotaSnapshot {
        CodexQuotaSnapshot(
            fetchedAt: Date(),
            fiveHour: CodexQuotaWindow(
                kind: .fiveHour,
                usedPercent: fiveHourUsed,
                resetsAt: Date().addingTimeInterval(2 * 3_600)
            ),
            sevenDay: CodexQuotaWindow(
                kind: .sevenDay,
                usedPercent: sevenDayUsed,
                resetsAt: Date().addingTimeInterval(3 * 86_400)
            )
        )
    }

    private static func todayRhythm(date: String) -> DailyRhythm {
        let values = [
            0, 0, 0, 0, 0, 0, 32_000_000, 44_000_000,
            61_000_000, 86_000_000, 118_000_000, 92_000_000,
            64_000_000, 48_000_000, 71_000_000, 95_000_000,
            128_000_000, 107_000_000, 78_000_000, 42_000_000,
            22_000_000, 0, 0, 0
        ]
        return DailyRhythm(
            date: date,
            buckets: values.enumerated().map { HourlyTokenBucket(hour: $0, tokens: $1) },
            totalTokens: values.reduce(0, +),
            peakHour: 16,
            peakTokens: 128_000_000,
            activeHours: values.filter { $0 > 0 }.count,
            firstActiveHour: 6,
            lastActiveHour: 20,
            primaryTag: .steadyCruise,
            companionTag: .afternoonBurst
        )
    }

    private static func todayAgentWork(date: String) -> DailyAgentWork {
        let active: [Int: Int] = [
            6: 32_000_000, 7: 44_000_000, 8: 61_000_000,
            9: 86_000_000, 10: 118_000_000, 11: 92_000_000,
            12: 64_000_000, 13: 48_000_000, 14: 71_000_000,
            15: 95_000_000, 16: 128_000_000, 17: 107_000_000,
            18: 78_000_000, 19: 42_000_000, 20: 22_000_000
        ]
        let buckets = (0..<24).map { hour -> AgentWorkHourBucket in
            guard let tokens = active[hour] else {
                return AgentWorkHourBucket(hour: hour, sources: [])
            }
            let output = max(1, Int(Double(tokens) * 0.035))
            let input = tokens - output
            return AgentWorkHourBucket(
                hour: hour,
                sources: [
                    AgentWorkHourlySource(
                        source: hour.isMultiple(of: 4) ? "Claude Code" : "Codex",
                        model: hour.isMultiple(of: 4) ? "claude-opus-4.1" : "gpt-5.6-sol",
                        tokens: tokens,
                        inputTokens: input,
                        cachedInputTokens: Int(Double(input) * 0.91),
                        outputTokens: output,
                        cacheCoverageComplete: true
                    )
                ]
            )
        }
        let total = buckets.map(\.totalTokens).reduce(0, +)
        let claude = buckets.flatMap(\.sources)
            .filter { $0.source == "Claude Code" }
            .map(\.tokens)
            .reduce(0, +)
        let codex = total - claude
        return DailyAgentWork(
            date: date,
            totalTokens: total,
            activeHours: active.count,
            modelRequestCount: 2_589,
            toolCallCount: 3_886,
            sources: [
                AgentWorkSource(
                    source: "Codex",
                    tokens: codex,
                    modelRequestCount: 2_261,
                    toolCallCount: 3_512
                ),
                AgentWorkSource(
                    source: "Claude Code",
                    tokens: claude,
                    modelRequestCount: 328,
                    toolCallCount: 374
                )
            ],
            inputTokens: Int(Double(total) * 0.965),
            cachedInputTokens: Int(Double(total) * 0.87),
            outputTokens: total - Int(Double(total) * 0.965),
            cacheCoverageComplete: true,
            hourlyBuckets: buckets,
            unbucketedTokens: 0
        )
    }

    @MainActor
    private static func writePNG<V: View>(_ view: V, to url: URL) throws -> NSImage {
        let image = try ScreenshotExporter.renderImage(view)
        let png = try ScreenshotExporter.pngData(from: image)
        try png.write(to: url, options: .atomic)
        try require(
            png.starts(with: [0x89, 0x50, 0x4E, 0x47]),
            "rendered file is not a PNG"
        )
        return image
    }

    private static func validatePosterPNG(_ data: Data, stage: String) throws {
        try require(
            data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
            "\(stage) ranking poster is not a PNG"
        )
        guard let bitmap = NSBitmapImageRep(data: data) else {
            throw Beta8FinalViewsRenderError.failed(
                "\(stage) ranking poster cannot be decoded"
            )
        }
        try require(
            bitmap.pixelsWide == 1_200 && bitmap.pixelsHigh == 1_600,
            "\(stage) ranking poster must be exactly 1200 x 1600 pixels"
        )
        try require(
            bottomLeftQRCodeDarkPixelCount(in: bitmap) > 500,
            "\(stage) ranking poster is missing its public-board QR code"
        )
    }

    private static func bottomLeftQRCodeDarkPixelCount(in bitmap: NSBitmapImageRep) -> Int {
        let xRange = 50..<min(bitmap.pixelsWide, 260)
        let lowerRange = 0..<min(bitmap.pixelsHigh, 300)
        let upperRange = max(0, bitmap.pixelsHigh - 300)..<bitmap.pixelsHigh
        return max(
            darkPixelCount(in: bitmap, xRange: xRange, yRange: lowerRange),
            darkPixelCount(in: bitmap, xRange: xRange, yRange: upperRange)
        )
    }

    private static func darkPixelCount(
        in bitmap: NSBitmapImageRep,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> Int {
        var count = 0
        for y in yRange {
            for x in xRange {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                let red = Double(color.redComponent)
                let green = Double(color.greenComponent)
                let blue = Double(color.blueComponent)
                let alpha = Double(color.alphaComponent)
                let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
                if alpha > 0.8, luminance < 0.28 {
                    count += 1
                }
            }
        }
        return count
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() {
            throw Beta8FinalViewsRenderError.failed(message)
        }
    }
}
