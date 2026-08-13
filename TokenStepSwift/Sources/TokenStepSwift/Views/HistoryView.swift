import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var expandedDates = Set<String>()
    var historyLimit: Int? = nil

    var body: some View {
        VStack(spacing: 22) {
            TokenCard {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L("近 8 个月活动墙"))
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(Color.tokenInk)
                            Text(L("颜色越深，用量越高；描边是今天"))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Text(LFormat("连续活跃 %d 天", appState.activeStreak.days))
                            Text("·")
                            Text(LFormat("%d 个活跃日", appState.snapshot.totals.activeDays))
                        }
                        .font(.callout.weight(.bold))
                        .foregroundStyle(Color.tokenGreenDark)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.tokenMint.opacity(0.28), in: Capsule())
                    }

                    ContributionWallView(
                        rows: Array(appState.snapshot.daily.suffix(238)),
                        goal: appState.settings.dailyGoalTokens
                    )
                }
            }

            StatsView()

            TokenCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L("全部明细"))
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(Color.tokenInk)
                            Text(historySummaryText)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        TokenToolLegend(tools: historyTools)
                    }

                    LazyVStack(spacing: 0) {
                        header
                        ForEach(historyRows) { row in
                            HistoryRow(
                                row: row,
                                isExpanded: expandedDates.contains(row.date),
                                toggleExpanded: { toggleExpanded(row.date) }
                            )
                        }
                    }
                }
            }
        }
    }

    private var historyRows: [DailyUsage] {
        let rows = appState.visibleHistoryRows
        guard let historyLimit else { return rows }
        return Array(rows.prefix(historyLimit))
    }

    private var historySummaryText: String {
        if let historyLimit {
            return LFormat("最近 %d 天，适合保存为截图", min(historyLimit, historyRows.count))
        }
        return LFormat("%d 条记录，向下滚动查看完整历史", appState.visibleHistoryRows.count)
    }

    private var historyTools: [String] {
        uniqueToolNames(in: historyRows)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Color.clear.frame(width: 12)
            Text(L("日期")).frame(width: 90, alignment: .leading)
            Text(L("Token 消耗")).frame(width: 150, alignment: .leading)
            Text(L("费用估算")).frame(width: 126, alignment: .leading)
            Text(L("工具")).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.heavy))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.tokenTrack.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toggleExpanded(_ date: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedDates.contains(date) {
                expandedDates.remove(date)
            } else {
                expandedDates.insert(date)
            }
        }
    }
}

private struct HistoryRow: View {
    var row: DailyUsage
    var isExpanded: Bool
    var toggleExpanded: () -> Void

    private var detail: HistoryDayDetailViewModel {
        HistoryDayDetailViewModel(row: row)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggleExpanded) {
                HStack(spacing: 16) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(row.date)
                        .frame(width: 90, alignment: .leading)
                        .foregroundStyle(Color.tokenInk.opacity(0.72))
                    Text(TokenStepFormat.tokens(row.totalTokens))
                        .fontWeight(.heavy)
                        .foregroundStyle(Color.tokenInk)
                        .frame(width: 150, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TokenStepFormat.estimatedMoney(row.cost, coverage: row.pricingCoverage))
                        Text(TokenStepFormat.pricingCoverage(row.pricingCoverage))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                        .frame(width: 126, alignment: .leading)
                        .foregroundStyle(Color.tokenInk.opacity(0.72))
                    HStack(spacing: 8) {
                        ForEach(summaryTools.prefix(3), id: \.self) { tool in
                            Circle()
                                .fill(tokenToolColor(tool))
                                .frame(width: 7, height: 7)
                        }
                        Text(summaryTools.isEmpty ? L("无") : summaryTools.joined(separator: " · "))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Color.tokenInk.opacity(0.72))
                }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedDetail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.055))
                .frame(height: 1)
        }
    }

    private var summaryTools: [String] {
        switch detail.precision {
        case .exact:
            return detail.tools.map(\.tool)
        case .legacyMarginals:
            return detail.legacyTools.map(\.name)
        }
    }

    @ViewBuilder
    private var expandedDetail: some View {
        switch detail.precision {
        case .exact:
            VStack(spacing: 10) {
                ForEach(detail.tools) { tool in
                    HistoryToolDetailView(tool: tool)
                }
                if !detail.exactTotalMatchesDay {
                    HistoryDetailNotice(
                        systemImage: "exclamationmark.triangle.fill",
                        text: L("原子明细与当日总计不一致，本次仅展示已采集的精确明细。"),
                        color: .orange
                    )
                }
            }
            .padding(.leading, 44)
            .padding(.trailing, 16)
            .padding(.bottom, 14)
        case .legacyMarginals:
            VStack(alignment: .leading, spacing: 12) {
                HistoryDetailNotice(
                    systemImage: "clock.arrow.circlepath",
                    text: L("旧数据仅有工具与模型的独立汇总，无法还原它们的对应关系。"),
                    color: .secondary
                )
                HStack(alignment: .top, spacing: 14) {
                    HistoryMarginalList(title: L("工具汇总"), rows: detail.legacyTools, showsToolColor: true)
                    HistoryMarginalList(title: L("模型汇总"), rows: detail.legacyModels, showsToolColor: false)
                }
            }
            .padding(.leading, 44)
            .padding(.trailing, 16)
            .padding(.bottom, 14)
        }
    }
}

private struct HistoryToolDetailView: View {
    var tool: HistoryToolDetail
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(tokenToolColor(tool.tool))
                        .frame(width: 9, height: 9)
                    Text(tool.tool)
                        .font(.callout.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Text(LFormat("%d 个模型", tool.models.count))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(TokenStepFormat.tokens(tool.totalTokens))
                        .font(.callout.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(tool.models) { model in
                        HistoryAtomicModelRow(model: model)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(Color.tokenTrack.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct HistoryAtomicModelRow: View {
    var model: DailyAtomicUsage

    var body: some View {
        HStack(spacing: 10) {
            Text(model.model)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.tokenInk.opacity(0.82))
                .lineLimit(2)
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            if model.breakdownComplete {
                HistoryTokenMetric(label: L("输入"), tokens: model.inputTokens)
                HistoryTokenMetric(label: L("输出"), tokens: model.outputTokens)
                HistoryTokenMetric(label: L("缓存读"), tokens: model.cacheReadTokens)
                HistoryTokenMetric(label: L("缓存写"), tokens: model.cacheWriteTokens)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle.fill")
                    Text(L("仅总量 · 分项不完整"))
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 318, alignment: .trailing)
            }
            HistoryTokenMetric(label: L("总计"), tokens: model.totalTokens, emphasized: true)
        }
        .padding(.vertical, 8)
        .background(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.045)).frame(height: 1)
        }
    }
}

private struct HistoryTokenMetric: View {
    var label: String
    var tokens: Int
    var emphasized = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(TokenStepFormat.tokens(tokens, compact: true))
                .font(.caption.weight(emphasized ? .heavy : .semibold))
                .foregroundStyle(emphasized ? Color.tokenInk : Color.tokenInk.opacity(0.74))
                .monospacedDigit()
        }
        .frame(width: 72, alignment: .trailing)
    }
}

private struct HistoryMarginalList: View {
    var title: String
    var rows: [HistoryMarginalDetail]
    var showsToolColor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.heavy))
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(L("无可用汇总"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 7) {
                        if showsToolColor {
                            Circle().fill(tokenToolColor(row.name)).frame(width: 7, height: 7)
                        }
                        Text(row.name).lineLimit(1)
                        Spacer()
                        Text(TokenStepFormat.tokens(row.totalTokens))
                            .fontWeight(.heavy)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.tokenInk.opacity(0.78))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tokenTrack.opacity(0.24), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct HistoryDetailNotice: View {
    var systemImage: String
    var text: String
    var color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.tokenInk.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
