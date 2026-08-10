import XCTest
@testable import TokenStepSwift

final class HistoryDayDetailViewModelTests: XCTestCase {
    func testExactRowsGroupModelsUnderTheirActualTools() {
        let row = DailyUsage(
            date: "2026-08-09",
            tools: ["Claude Code": 70, "Codex": 30],
            models: ["shared-name": 100],
            atomicUsage: [
                DailyAtomicUsage(
                    tool: "Claude Code",
                    model: "shared-name",
                    inputTokens: 20,
                    outputTokens: 10,
                    cacheReadTokens: 35,
                    cacheWriteTokens: 5,
                    totalTokens: 70
                ),
                DailyAtomicUsage(
                    tool: "Codex",
                    model: "shared-name",
                    inputTokens: 10,
                    outputTokens: 10,
                    cacheReadTokens: 10,
                    cacheWriteTokens: 0,
                    totalTokens: 30
                )
            ],
            totalTokens: 100,
            cost: 0
        )

        let detail = HistoryDayDetailViewModel(row: row)

        XCTAssertEqual(detail.precision, .exact)
        XCTAssertEqual(detail.tools.count, 2)
        XCTAssertEqual(detail.tools.first(where: { $0.tool == "Claude Code" })?.models.first?.totalTokens, 70)
        XCTAssertEqual(detail.tools.first(where: { $0.tool == "Codex" })?.models.first?.totalTokens, 30)
        XCTAssertTrue(detail.exactTotalMatchesDay)
        XCTAssertTrue(detail.legacyTools.isEmpty)
        XCTAssertTrue(detail.legacyModels.isEmpty)
    }

    func testLegacyRowsExposeOnlySeparateMarginals() {
        let row = DailyUsage(
            date: "2026-08-08",
            tools: ["Claude Code": 70, "Codex": 30],
            models: ["claude-opus": 60, "gpt-5": 40],
            atomicUsage: nil,
            totalTokens: 100,
            cost: 0
        )

        let detail = HistoryDayDetailViewModel(row: row)

        XCTAssertEqual(detail.precision, .legacyMarginals)
        XCTAssertTrue(detail.tools.isEmpty)
        XCTAssertEqual(Set(detail.legacyTools.map(\.name)), ["Claude Code", "Codex"])
        XCTAssertEqual(Set(detail.legacyModels.map(\.name)), ["claude-opus", "gpt-5"])
        XCTAssertNil(detail.exactTotalTokens)
    }
}
