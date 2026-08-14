import Foundation
import XCTest
@testable import TokenStepSwift

final class UsageCalendarWindowTests: XCTestCase {
    func testSevenDayWindowUsesCalendarDaysAndFillsCollectorGaps() throws {
        let endingAt = try XCTUnwrap(DateFormatter.tokenStepDay.date(from: "2026-08-14"))
        let rows = UsageCalendarWindow.rows(
            from: [
                usage(date: "2026-08-01", tokens: 900),
                usage(date: "2026-08-10", tokens: 100),
                usage(date: "2026-08-14", tokens: 300),
            ],
            days: 7,
            endingAt: endingAt
        )

        XCTAssertEqual(rows.map(\.date), [
            "2026-08-08", "2026-08-09", "2026-08-10", "2026-08-11",
            "2026-08-12", "2026-08-13", "2026-08-14",
        ])
        XCTAssertEqual(rows.map(\.totalTokens).reduce(0, +), 400)
        XCTAssertEqual(rows.filter { $0.totalTokens == 0 }.count, 5)
        XCTAssertFalse(rows.contains { $0.date == "2026-08-01" })
        XCTAssertEqual(rows.first { $0.date == "2026-08-11" }?.atomicUsage?.count, 0)
        XCTAssertEqual(rows.first { $0.date == "2026-08-11" }?.pricedTokens, 0)
    }

    func testAllWindowFillsFromEarliestRetainedDayThroughToday() throws {
        let endingAt = try XCTUnwrap(DateFormatter.tokenStepDay.date(from: "2026-08-14"))
        let rows = UsageCalendarWindow.rows(
            from: [
                usage(date: "2026-08-10", tokens: 100),
                usage(date: "2026-08-14", tokens: 300),
                usage(date: "2026-08-20", tokens: 999),
            ],
            days: nil,
            endingAt: endingAt
        )

        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.first?.date, "2026-08-10")
        XCTAssertEqual(rows.last?.date, "2026-08-14")
        XCTAssertEqual(rows.map(\.totalTokens).reduce(0, +), 400)
    }

    private func usage(date: String, tokens: Int) -> DailyUsage {
        DailyUsage(
            date: date,
            tools: ["Codex": tokens],
            models: ["gpt-test": tokens],
            totalTokens: tokens,
            cost: Double(tokens),
            pricedTokens: tokens,
            unpricedTokens: 0
        )
    }
}
