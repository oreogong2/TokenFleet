import XCTest
@testable import TokenStepSwift

final class UsageRelativePaceTests: XCTestCase {
    func testUsesUpToSevenPreviousActiveDaysAndExcludesZeroDays() throws {
        let rows = [
            day("2026-08-01", 10),
            day("2026-08-02", 20),
            day("2026-08-03", 0),
            day("2026-08-04", 30),
            day("2026-08-05", 40),
            day("2026-08-06", 50),
            day("2026-08-07", 60),
            day("2026-08-08", 70),
            day("2026-08-09", 80),
            day("2026-08-10", 90)
        ]

        let pace = try XCTUnwrap(
            UsageRelativePaceCalculator.comparison(for: rows.last!, in: rows)
        )

        XCTAssertEqual(pace.sampleCount, 7)
        XCTAssertEqual(pace.comparisonAverageTokens, 50, accuracy: 0.000_001)
        XCTAssertEqual(pace.differenceRatio, 0.8, accuracy: 0.000_001)
    }

    func testNeedsTwoPreviousActiveDays() {
        let rows = [day("2026-08-01", 10), day("2026-08-02", 20)]

        XCTAssertNil(UsageRelativePaceCalculator.comparison(for: rows.last!, in: rows))
    }

    func testComparisonNeverUsesFutureRows() throws {
        let target = day("2026-08-03", 30)
        let rows = [
            day("2026-08-01", 10),
            day("2026-08-02", 20),
            target,
            day("2026-08-04", 1_000)
        ]

        let pace = try XCTUnwrap(UsageRelativePaceCalculator.comparison(for: target, in: rows))

        XCTAssertEqual(pace.comparisonAverageTokens, 15, accuracy: 0.000_001)
        XCTAssertEqual(pace.differenceRatio, 1, accuracy: 0.000_001)
    }

    private func day(_ date: String, _ tokens: Int) -> DailyUsage {
        DailyUsage(date: date, tools: [:], totalTokens: tokens, cost: 0)
    }
}
