import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            hero
            todayBreakdownStrip
            TodayAgentWorkCard()
        }
    }

    private var hero: some View {
        let lap = appState.todayLap
        return TokenCard {
            HStack(alignment: .center, spacing: 22) {
                TokenFleetGoalDial(
                    tokens: appState.today.totalTokens,
                    goal: appState.settings.dailyGoalTokens,
                    size: 145
                )
                .frame(width: 165)

                VStack(alignment: .leading, spacing: 10) {
                    Text(lap.lapStatusText)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.tokenGreenDark)
                        .monospacedDigit()

                    Text(TokenStepFormat.tokens(appState.today.totalTokens))
                        .font(.system(size: 43, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.tokenInk)
                        .monospacedDigit()
                        .minimumScaleFactor(0.62)
                        .lineLimit(1)

                    Text(
                        "\(lap.perLapGoalText) · "
                            + LFormat("今日真实进度 %@", TokenStepFormat.percent(appState.progress * 100))
                    )
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.secondary)

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 7
                    ) {
                        TodayHeroMetric(
                            label: L("API 标准价估算"),
                            value: TokenStepFormat.estimatedMoney(
                                appState.today.cost,
                                coverage: appState.today.pricingCoverage
                            )
                        )
                        TodayHeroMetric(
                            label: L("可估价 Token"),
                            value: TokenStepFormat.pricingCoverage(appState.today.pricingCoverage)
                        )
                        TodayHeroMetric(
                            label: L("连续活跃"),
                            value: localizedStreakDays(
                                days: appState.activeStreak.days,
                                isLowerBound: appState.activeStreak.isLowerBound
                            )
                        )
                        TodayHeroMetric(label: L("社群排名"), value: communityRankValue)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var pricingDetail: some View {
        if let priced = appState.today.pricedTokens,
           let unpriced = appState.today.unpricedTokens,
           let version = appState.today.pricingVersion {
            Text(
                LFormat(
                    "已计价 %@ · 未计价 %@ · %@",
                    TokenStepFormat.tokens(priced, compact: true),
                    TokenStepFormat.tokens(unpriced, compact: true),
                    version
                )
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var todayBreakdownStrip: some View {
        HStack(alignment: .top, spacing: 12) {
            TodayBreakdownCard(title: L("今日模型消耗"), rows: todayModelRows)
            TodayBreakdownCard(title: L("今日工具消耗"), rows: todayToolRows)
        }
    }

    private var todayToolRows: [TodayBreakdownRow] {
        let total = appState.today.totalTokens
        guard total > 0 else { return [] }
        return orderedToolEntries(appState.today.tools).map { name, tokens in
            TodayBreakdownRow(
                name: name,
                tokens: tokens,
                percent: Double(tokens) * 100 / Double(total),
                color: tokenToolColor(name)
            )
        }
    }

    private var todayModelRows: [TodayBreakdownRow] {
        breakdownRows(from: appState.today.models)
    }

    private func breakdownRows(from values: [String: Int]) -> [TodayBreakdownRow] {
        let total = appState.today.totalTokens
        guard total > 0 else { return [] }
        return values
            .filter { $0.value > 0 }
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }
            .map { name, tokens in
                TodayBreakdownRow(
                    name: name,
                    tokens: tokens,
                    percent: Double(tokens) * 100 / Double(total),
                    color: nil
                )
            }
    }

    private var communityRankValue: String {
        guard appState.isCommunitySyncEnrollmentCompatible else { return L("未连接") }
        guard let rank = appState.communityRank?.rank,
              let total = appState.communityRank?.totalEntries
        else { return L("等待读取") }
        return "#\(rank) / \(total)"
    }
}

private struct TodayHeroMetric: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.heavy))
                .foregroundStyle(Color.tokenInk)
                .minimumScaleFactor(0.58)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.tokenTrack.opacity(0.25),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
