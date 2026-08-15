import SwiftUI

struct PopoverTodayRingCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            toolBreakdown
        }
        .background(Color.tokenSurface)
    }

    private var hero: some View {
        let lap = appState.todayLap
        return HStack(alignment: .center, spacing: 20) {
            TokenFleetGoalDial(
                tokens: appState.today.totalTokens,
                goal: appState.settings.dailyGoalTokens,
                size: 150
            )
            .frame(width: 160)

            VStack(alignment: .leading, spacing: 4) {
                Text(lap.lapStatusText)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenGreenDark)
                    .monospacedDigit()

                Text(TokenStepFormat.tokens(appState.today.totalTokens))
                    .font(.system(size: 43, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .monospacedDigit()
                    .minimumScaleFactor(0.66)
                    .lineLimit(1)

                Text(lap.perLapGoalText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 7) {
                    PopoverMetric(
                        label: L("API 标准价估算"),
                        value: TokenStepFormat.estimatedMoney(
                            appState.today.cost,
                            coverage: appState.today.pricingCoverage
                        )
                    )
                    PopoverMetric(
                        label: L("连续活跃"),
                        value: localizedStreakDays(
                            days: appState.activeStreak.days,
                            isLowerBound: appState.activeStreak.isLowerBound
                        )
                    )
                    PopoverMetric(label: L("社群排名"), value: communityRankValue, emphasized: true)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
    }

    private var toolBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("今日工具消耗"))
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.tokenInk)
                    Text(L("按客户端汇总 · 主力工具优先"))
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(LFormat("%d 个工具", toolRows.count))
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(Color.tokenGreenDark)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.tokenMint.opacity(0.5), in: Capsule())
            }

            if toolRows.isEmpty {
                Text(L("等待下一次同步"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            } else {
                ForEach(Array(toolRows.prefix(3).enumerated()), id: \.element.name) { _, row in
                    PopoverToolRow(row: row, total: appState.today.totalTokens)
                }
            }

            HStack {
                Text(toolRows.count > 3
                     ? L("单屏优先显示主力工具 Top 3")
                     : LFormat("当前显示 %d / %d", min(toolRows.count, 3), toolRows.count))
                    .foregroundStyle(.secondary)
                Spacer()
                if toolRows.count > 3 {
                    Button {
                        MainWindowPresenter.shared.show(appState: appState, section: .today)
                    } label: {
                        Text(L("查看今日全部工具 →"))
                            .foregroundStyle(Color.tokenGreenDark)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 7, weight: .bold))
            .padding(.top, 7)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.black.opacity(0.07)).frame(height: 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var toolRows: [(name: String, tokens: Int)] {
        orderedToolEntries(appState.today.tools)
            .filter { $0.tokens > 0 }
    }

    private var communityRankValue: String {
        guard appState.isCommunitySyncEnrollmentCompatible else { return L("未连接") }
        guard let rank = appState.communityRank?.rank,
              let total = appState.communityRank?.totalEntries
        else { return L("等待读取") }
        return "#\(rank) / \(total)"
    }
}

private struct PopoverMetric: View {
    var label: String
    var value: String
    var emphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(emphasized ? Color.tokenGreenDark : Color.tokenInk)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tokenCanvas.opacity(0.62), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.black.opacity(0.07)))
    }
}

private struct PopoverToolRow: View {
    var row: (name: String, tokens: Int)
    var total: Int

    private var percent: Double {
        guard total > 0 else { return 0 }
        return Double(row.tokens) / Double(total)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(row.name)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.tokenInk.opacity(0.82))
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.tokenTrack)
                    Capsule()
                        .fill(tokenToolColor(row.name))
                        .frame(width: max(row.tokens > 0 ? 4 : 0, proxy.size.width * percent))
                }
            }
            .frame(height: 6)
            Text(TokenStepFormat.tokens(row.tokens, compact: true))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
        .frame(height: 18)
    }
}
