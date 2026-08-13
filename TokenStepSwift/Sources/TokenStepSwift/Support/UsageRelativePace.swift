import Foundation

struct UsageRelativePace: Equatable {
    var currentTokens: Int
    var comparisonAverageTokens: Double
    var sampleCount: Int

    var differenceRatio: Double {
        guard comparisonAverageTokens > 0 else { return 0 }
        return (Double(currentTokens) - comparisonAverageTokens) / comparisonAverageTokens
    }

    var summary: String {
        if abs(differenceRatio) < 0.01 {
            return LFormat("与近 %d 个活跃日基本持平", sampleCount)
        }
        if differenceRatio > 0 {
            return LFormat(
                "比近 %d 个活跃日高 %@",
                sampleCount,
                TokenStepFormat.percent(differenceRatio * 100)
            )
        }
        return LFormat(
            "比近 %d 个活跃日低 %@",
            sampleCount,
            TokenStepFormat.percent(abs(differenceRatio) * 100)
        )
    }
}

enum UsageRelativePaceCalculator {
    /// Compares one day with up to seven preceding active days. Calendar-zero days
    /// are excluded and at least two genuine comparison samples are required.
    static func comparison(
        for day: DailyUsage,
        in rows: [DailyUsage],
        sampleLimit: Int = 7,
        minimumSamples: Int = 2
    ) -> UsageRelativePace? {
        guard day.totalTokens > 0, sampleLimit > 0, minimumSamples > 0 else { return nil }
        let samples = rows
            .filter { $0.date < day.date && $0.totalTokens > 0 }
            .sorted { $0.date < $1.date }
            .suffix(sampleLimit)
        guard samples.count >= minimumSamples else { return nil }
        let total = samples.reduce(0.0) { $0 + Double($1.totalTokens) }
        let average = total / Double(samples.count)
        guard average > 0, average.isFinite else { return nil }
        return UsageRelativePace(
            currentTokens: day.totalTokens,
            comparisonAverageTokens: average,
            sampleCount: samples.count
        )
    }
}
