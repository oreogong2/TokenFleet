import Foundation

struct UsageStreak: Equatable {
    var days: Int
    var endingDate: String?
    var isActiveToday: Bool
}

enum UsageStreakCalculator {
    static func current(
        rows: [DailyUsage],
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
            return UsageStreak(days: 0, endingDate: nil, isActiveToday: isActiveToday)
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
            isActiveToday: isActiveToday
        )
    }

    static func days(
        endingOn date: String,
        rows: [DailyUsage],
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    ) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let endingDay = dateFormatter(timeZone: timeZone).date(from: date) else { return 0 }
        let activeDates = Set(rows.filter { $0.totalTokens > 0 }.map(\.date))
        return consecutiveDays(
            endingOn: endingDay,
            activeDates: activeDates,
            calendar: calendar,
            timeZone: timeZone
        )
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
