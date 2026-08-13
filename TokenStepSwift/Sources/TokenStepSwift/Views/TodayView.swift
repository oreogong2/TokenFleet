import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 22) {
            hero
            todayBreakdownStrip
            TodayAgentWorkCard()
            metricStrip
        }
    }

    private var hero: some View {
        let percent = TokenStepFormat.percent(appState.progress * 100)
        return TokenCard {
            HStack(alignment: .center, spacing: 34) {
                TokenFleetGoalDial(
                    tokens: appState.today.totalTokens,
                    goal: appState.settings.dailyGoalTokens,
                    size: 184
                )
                .frame(width: 222)

                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 12) {
                        TokenFleetSignalMark(size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("今日目标进度"))
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(Color.tokenInk)
                            Text("\(L("今天已记录")) · \(percent)")
                                .font(.callout.weight(.bold))
                                .foregroundStyle(Color.tokenGreenDark)
                                .monospacedDigit()
                        }
                    }

                    HStack(spacing: 10) {
                        MetricPill(label: L("每日目标"), value: TokenStepFormat.tokens(appState.settings.dailyGoalTokens, compact: true))
                        MetricPill(
                            label: L("API 标准价估算"),
                            value: TokenStepFormat.estimatedMoney(
                                appState.today.cost,
                                coverage: appState.today.pricingCoverage
                            )
                        )
                        MetricPill(label: L("本月均值"), value: TokenStepFormat.tokens(appState.monthAverage, compact: true))
                    }

                    HStack(spacing: 12) {
                        if let pace = appState.todayRelativePace {
                            Label(pace.summary, systemImage: "waveform.path.ecg")
                                .foregroundStyle(Color.tokenGreenDark)
                        }
                        Text(TokenStepFormat.pricingCoverage(appState.today.pricingCoverage))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.weight(.semibold))

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

                Spacer(minLength: 0)
            }
        }
    }

    private var metricStrip: some View {
        HStack(spacing: 18) {
            CompactMetricCard(label: L("累计 Token 消耗"), value: TokenStepFormat.tokens(appState.snapshot.totals.tokens), detail: L("所有本机记录"))
            CompactMetricCard(label: L("活跃天数"), value: localizedDays(appState.snapshot.totals.activeDays), detail: L("有 AI 使用的日期"))
            CompactMetricCard(
                label: L("连续活跃"),
                value: localizedStreakDays(
                    days: appState.activeStreak.days,
                    isLowerBound: appState.activeStreak.isLowerBound
                ),
                detail: appState.activeStreak.isActiveToday ? L("今天已续上") : L("等待今天续上")
            )
            CompactMetricCard(label: L("达标天数"), value: localizedDays(appState.goalDays), detail: L("达到每日目标"))
        }
    }

    private var todayBreakdownStrip: some View {
        HStack(alignment: .top, spacing: 22) {
            TodayBreakdownCard(title: L("今日客户端"), rows: todayToolRows, maxRows: 3)
            TodayBreakdownCard(title: L("今日模型"), rows: todayModelRows, maxRows: 4)
        }
    }

    private func localizedDays(_ count: Int) -> String {
        TokenStepLocalization.language == .en ? "\(count)d" : "\(count) 天"
    }

    private var todayToolRows: [TodayBreakdownRow] {
        let total = appState.today.totalTokens
        guard total > 0 else { return [] }
        let primaryTools = ["Codex", "Claude Code"]
        let primaryRows = primaryTools.map { name in
            TodayBreakdownRow(
                name: name,
                tokens: appState.today.tools[name] ?? 0,
                percent: Double(appState.today.tools[name] ?? 0) * 100 / Double(total),
                color: tokenToolColor(name)
            )
        }
        let extraRows = appState.today.tools
            .filter { !primaryTools.contains($0.key) && $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { name, tokens in
                TodayBreakdownRow(
                    name: name,
                    tokens: tokens,
                    percent: Double(tokens) * 100 / Double(total),
                    color: tokenToolColor(name)
                )
            }
        return primaryRows + extraRows
    }

    private var todayModelRows: [TodayBreakdownRow] {
        breakdownRows(from: appState.today.models) { _ in nil }
    }

    private func breakdownRows(from values: [String: Int], color: (String) -> Color?) -> [TodayBreakdownRow] {
        let total = appState.today.totalTokens
        guard total > 0 else { return [] }
        return values
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { name, tokens in
                TodayBreakdownRow(
                    name: name,
                    tokens: tokens,
                    percent: Double(tokens) * 100 / Double(total),
                    color: color(name)
                )
            }
    }
}

private struct CompactMetricCard: View {
    var label: String
    var value: String
    var detail: String

    var body: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 27, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .minimumScaleFactor(0.66)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
