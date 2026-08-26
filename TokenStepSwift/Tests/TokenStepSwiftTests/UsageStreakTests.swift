import Foundation
import XCTest
@testable import TokenStepSwift

final class UsageStreakTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    func testActiveTodayCountsBackThroughConsecutiveCalendarDays() {
        let rows = [
            day("2026-08-09", 1),
            day("2026-08-10", 10),
            day("2026-08-11", 20),
            day("2026-08-12", 30),
            day("2026-08-13", 40)
        ]

        let streak = UsageStreakCalculator.current(
            rows: rows,
            now: date("2026-08-13 19:00"),
            timeZone: timeZone
        )

        XCTAssertEqual(streak.days, 5)
        XCTAssertTrue(streak.isActiveToday)
        XCTAssertEqual(streak.endingDate, "2026-08-13")
        XCTAssertFalse(streak.isLowerBound)
    }

    func testInactiveTodayKeepsYesterdayStreakDiscoverableUntilDayEnds() {
        let rows = [
            day("2026-08-10", 10),
            day("2026-08-11", 20),
            day("2026-08-12", 30)
        ]

        let streak = UsageStreakCalculator.current(
            rows: rows,
            now: date("2026-08-13 08:00"),
            timeZone: timeZone
        )

        XCTAssertEqual(streak.days, 3)
        XCTAssertFalse(streak.isActiveToday)
        XCTAssertEqual(streak.endingDate, "2026-08-12")
    }

    func testGapBreaksStreakAndHistoricalDayCanBeCalculated() {
        let rows = [
            day("2026-08-09", 10),
            day("2026-08-11", 20),
            day("2026-08-12", 30),
            day("2026-08-13", 40)
        ]

        XCTAssertEqual(UsageStreakCalculator.days(endingOn: "2026-08-13", rows: rows), 3)
        XCTAssertEqual(UsageStreakCalculator.days(endingOn: "2026-08-09", rows: rows), 1)
    }

    func testStreakAtRetentionBoundaryIsReportedAsLowerBound() {
        let rows = [
            day("2026-08-11", 10),
            day("2026-08-12", 20),
            day("2026-08-13", 30)
        ]
        let now = date("2026-08-13 19:00")

        let current = UsageStreakCalculator.current(
            rows: rows,
            historyDays: 3,
            now: now,
            timeZone: timeZone
        )
        let historical = UsageStreakCalculator.measurement(
            endingOn: "2026-08-13",
            rows: rows,
            historyDays: 3,
            now: now,
            timeZone: timeZone
        )

        XCTAssertEqual(current.days, 3)
        XCTAssertTrue(current.isLowerBound)
        XCTAssertEqual(historical, UsageStreakMeasurement(days: 3, isLowerBound: true))
    }

    private func day(_ date: String, _ tokens: Int) -> DailyUsage {
        DailyUsage(date: date, tools: [:], totalTokens: tokens, cost: 0)
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)!
    }
}
