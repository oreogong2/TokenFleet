import Foundation

struct UsageStreak: Equatable {
    var days: Int
    var endingDate: String?
    var isActiveToday: Bool
    var isLowerBound: Bool
}

struct UsageStreakMeasurement: Equatable {
    var days: Int
    var isLowerBound: Bool
}

enum UsageStreakCalculator {
    static func current(
        rows: [DailyUsage],
        historyDays: Int? = nil,
        now: Date = Date(),
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    ) -> UsageStreak {
        let activeDates = Set(rows.filter { $0.totalTokens > 0 }.map(\.date))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: now)
        let today = dayString(startOfToday, timeZone: timeZone)
        let isActiveToday = activeDates.contains(today)
        let endingDay = isActiveToday
            ? startOfToday
            : calendar.date(byAdding: .day, value: -1, to: startOfToday)
        guard let endingDay else {
            return UsageStreak(
                days: 0,
                endingDate: nil,
                isActiveToday: isActiveToday,
                isLowerBound: false
            )
        }
        let endingDate = dayString(endingDay, timeZone: timeZone)
        let days = consecutiveDays(
            endingOn: endingDay,
            activeDates: activeDates,
            calendar: calendar,
            timeZone: timeZone
        )
        return UsageStreak(
            days: days,
            endingDate: days > 0 ? endingDate : nil,
            isActiveToday: isActiveToday,
            isLowerBound: isTruncatedByHistoryWindow(
                days: days,
                endingDay: endingDay,
                historyDays: historyDays,
                now: now,
                calendar: calendar
            )
        )
    }

    static func measurement(
        endingOn date: String,
        rows: [DailyUsage],
        historyDays: Int? = nil,
        now: Date = Date(),
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    ) -> UsageStreakMeasurement {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let endingDay = dateFormatter(timeZone: timeZone).date(from: date) else {
            return UsageStreakMeasurement(days: 0, isLowerBound: false)
        }
        let activeDates = Set(rows.filter { $0.totalTokens > 0 }.map(\.date))
        let days = consecutiveDays(
            endingOn: endingDay,
            activeDates: activeDates,
            calendar: calendar,
            timeZone: timeZone
        )
        return UsageStreakMeasurement(
            days: days,
            isLowerBound: isTruncatedByHistoryWindow(
                days: days,
                endingDay: endingDay,
                historyDays: historyDays,
                now: now,
                calendar: calendar
            )
        )
    }

    static func days(
        endingOn date: String,
        rows: [DailyUsage],
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    ) -> Int {
        measurement(endingOn: date, rows: rows, timeZone: timeZone).days
    }

    private static func isTruncatedByHistoryWindow(
        days: Int,
        endingDay: Date,
        historyDays: Int?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard days > 0, let historyDays, historyDays > 0,
              let oldestCountedDay = calendar.date(
                  byAdding: .day,
                  value: -(days - 1),
                  to: endingDay
              ),
              let firstRetainedDay = calendar.date(
                  byAdding: .day,
                  value: -(historyDays - 1),
                  to: calendar.startOfDay(for: now)
              )
        else {
            return false
        }
        return calendar.isDate(oldestCountedDay, inSameDayAs: firstRetainedDay)
    }

    private static func consecutiveDays(
        endingOn endingDay: Date,
        activeDates: Set<String>,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> Int {
        var days = 0
        var cursor = endingDay
        while activeDates.contains(dayString(cursor, timeZone: timeZone)) {
            days += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }
        return days
    }

    private static func dayString(_ date: Date, timeZone: TimeZone) -> String {
        dateFormatter(timeZone: timeZone).string(from: date)
    }

    private static func dateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
