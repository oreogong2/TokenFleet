import SwiftUI

struct PopoverTodayRingCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let percent = TokenStepFormat.percent(appState.progress * 100)
        return TokenCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L("今日 Token 消耗"))
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Spacer()
                    Text(appState.today.date)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 20) {
                    TokenFleetGoalDial(
                        tokens: appState.today.totalTokens,
                        goal: appState.settings.dailyGoalTokens,
                        size: 132
                    )
                    .frame(width: 146)

                    VStack(alignment: .leading, spacing: 11) {
                        Text(L("今日目标进度"))
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text("\(L("今天已记录")) · \(percent)")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.tokenGreenDark)
                            .monospacedDigit()
                        Text(LFormat("每日目标 %@", TokenStepFormat.tokens(appState.settings.dailyGoalTokens, compact: true)))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            MetricPill(
                                label: L("API 标准价估算"),
                                value: TokenStepFormat.estimatedMoney(
                                    appState.today.cost,
                                    coverage: appState.today.pricingCoverage
                                )
                            )
                            Text(TokenStepFormat.pricingCoverage(appState.today.pricingCoverage))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            MetricPill(
                                label: L("连续活跃"),
                                value: localizedStreakDays(
                                    days: appState.activeStreak.days,
                                    isLowerBound: appState.activeStreak.isLowerBound
                                )
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let pace = appState.todayRelativePace {
                    HStack(spacing: 8) {
                        Label(L("相对节奏"), systemImage: "waveform.path.ecg")
                            .foregroundStyle(Color.tokenGreenDark)
                        Text(pace.summary)
                            .foregroundStyle(Color.tokenInk.opacity(0.72))
                        Spacer(minLength: 0)
                    }
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.tokenTrack.opacity(0.30), in: Capsule())
                }

                if !todaySourceRows.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L("今日来源"))
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            ForEach(todaySourceRows.indices, id: \.self) { index in
                                let row = todaySourceRows[index]
                                if index > 0 {
                                    Divider()
                                        .frame(height: 30)
                                }
                                TodaySourceMetric(name: row.name, tokens: row.tokens)
                            }
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
    }

    private var todaySourceRows: [(name: String, tokens: Int)] {
        let rows = appState.today.tools
            .filter { $0.value > 0 }
            .map { (name: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }
        guard rows.count > 3 else { return rows }

        return Array(rows.prefix(3))
    }
}

private struct TodaySourceMetric: View {
    var name: String
    var tokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(tokenToolColor(name))
                    .frame(width: 6, height: 6)
                Text(displayName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(TokenStepFormat.tokens(tokens, compact: true))
                .font(.caption.weight(.heavy))
                .foregroundStyle(Color.tokenInk.opacity(0.82))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayName: String {
        name == "Claude Code" ? "Claude" : name
    }
}
