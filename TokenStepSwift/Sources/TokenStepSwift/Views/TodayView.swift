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
        let progress = min(max(appState.progress, 0), 1)
        let percent = TokenStepFormat.percent(appState.progress * 100)
        return TokenCard {
            HStack(alignment: .center, spacing: 34) {
                ZStack {
                    ProgressRingView(progress: progress, lineWidth: 20, color: .tokenGreenDark)
                    VStack(spacing: 6) {
                        Text(TokenStepFormat.tokens(appState.today.totalTokens))
                            .font(.system(size: 42, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.tokenInk)
                            .minimumScaleFactor(0.42)
                            .lineLimit(1)
                        Text(LFormat("目标 %@", TokenStepFormat.tokens(appState.settings.dailyGoalTokens, compact: true)))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 160)
                }
                .frame(width: 204, height: 204)

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("今日目标进度"))
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(percent)
                            .font(.system(size: 44, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.tokenGreenDark)
                            .monospacedDigit()
                    }

                    ProgressView(value: progress)
                        .tint(Color.tokenGreenDark)
                        .frame(maxWidth: 360)

                    HStack(spacing: 10) {
                        MetricPill(label: L("每日目标"), value: TokenStepFormat.tokens(appState.settings.dailyGoalTokens, compact: true))
                        MetricPill(label: L("消耗金额"), value: TokenStepFormat.money(appState.today.cost))
                        MetricPill(label: L("本月均值"), value: TokenStepFormat.tokens(appState.monthAverage, compact: true))
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
