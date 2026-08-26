import Foundation

/// Builds a dense Asia/Shanghai accounting-day window from sparse collector
/// rows. Collectors intentionally omit zero-usage days, while charts and
/// calendar-day averages must keep those days inside the selected range.
enum UsageCalendarWindow {
    private static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    static func rows(
        from sparseRows: [DailyUsage],
        days: Int?,
        endingAt now: Date = Date()
    ) -> [DailyUsage] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let end = calendar.startOfDay(for: now)

        var rowByDate: [String: DailyUsage] = [:]
        for row in sparseRows {
            guard let date = DateFormatter.tokenStepDay.date(from: row.date),
                  date <= end,
                  DateFormatter.tokenStepDay.string(from: date) == row.date
            else { continue }
            rowByDate[row.date] = row
        }

        let start: Date
        if let days {
            guard days > 0,
                  let calculated = calendar.date(byAdding: .day, value: -(days - 1), to: end)
            else { return [] }
            start = calculated
        } else {
            guard let firstKey = rowByDate.keys.min(),
                  let firstDate = DateFormatter.tokenStepDay.date(from: firstKey)
            else { return [] }
            start = firstDate
        }

        let span = calendar.dateComponents([.day], from: start, to: end).day ?? -1
        guard span >= 0 else { return [] }
        return (0...span).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else {
                return nil
            }
            let key = DateFormatter.tokenStepDay.string(from: date)
            return rowByDate[key] ?? emptyRow(for: key)
        }
    }

    /// Returns the exact selected accounting-day rows that fit in the wall.
    /// The grid is intentionally sequential rather than Monday-anchored: a
    /// seven-day range must keep all seven selected days even when it crosses
    /// a calendar-week boundary.
    static func contributionRows(
        from rows: [DailyUsage],
        weeks: Int
    ) -> [DailyUsage] {
        let capacity = max(1, weeks) * 7
        return Array(rows.sorted { $0.date < $1.date }.suffix(capacity))
    }

    private static func emptyRow(for date: String) -> DailyUsage {
        DailyUsage(
            date: date,
            tools: [:],
            models: [:],
            atomicUsage: [],
            totalTokens: 0,
            cost: 0,
            pricedTokens: 0,
            unpricedTokens: 0
        )
    }
}
