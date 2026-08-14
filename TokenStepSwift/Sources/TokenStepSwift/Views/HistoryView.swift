import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering
    @State private var expandedDates = Set<String>()
    @State private var section: HistorySection = .overview
    @State private var range: HistoryRange = .thirtyDays
    var historyLimit: Int? = nil

    var body: some View {
        VStack(spacing: 22) {
            navigation
            if section != .daily { rangePicker }
            switch section {
            case .overview:
                overview
            case .tools:
                dimensionPage(
                    title: L("工具消耗"),
                    subtitle: L("按所选时间范围聚合，支持任意数量工具"),
                    rows: toolRows,
                    showsToolColor: true
                )
            case .models:
                dimensionPage(
                    title: L("模型消耗"),
                    subtitle: L("按所选时间范围聚合，支持任意数量模型"),
                    rows: modelRows,
                    showsToolColor: false
                )
            case .daily:
                dailyDetails
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 5) {
            ForEach(HistorySection.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        section = item
                    }
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.callout.weight(.heavy))
                        .foregroundStyle(section == item ? Color.tokenSurface : Color.tokenInk.opacity(0.68))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(section == item ? Color.tokenInk : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? [.isSelected] : [])
            }
        }
        .padding(5)
        .background(Color.tokenTrack.opacity(0.54), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var rangePicker: some View {
        HStack {
            Text(L("统计范围"))
                .font(.callout.weight(.heavy))
                .foregroundStyle(Color.tokenInk)
            Spacer()
            HStack(spacing: 0) {
                ForEach(HistoryRange.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            range = item
                        }
                    } label: {
                        Text(item.title)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(item == range ? Color.white : Color.tokenInk.opacity(0.62))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                item == range ? Color.tokenGreenDark : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(item == range ? [.isSelected] : [])
                }
            }
            .padding(2)
            .background(Color.tokenTrack.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .frame(width: 360)
            .allowsHitTesting(!isScreenshotRendering)
            .accessibilityLabel(L("时间范围"))
        }
    }

    private var overview: some View {
        VStack(spacing: 22) {
            HStack(spacing: 14) {
                HistoryOverviewMetric(label: L("累计 Token"), value: TokenStepFormat.tokens(selectedTotal, compact: true), detail: range.title)
                HistoryOverviewMetric(
                    label: L("费用估算"),
                    value: TokenStepFormat.estimatedMoney(selectedCost, coverage: selectedPricingCoverage),
                    detail: TokenStepFormat.pricingCoverage(selectedPricingCoverage)
                )
                HistoryOverviewMetric(label: L("活跃天数"), value: localizedDays(selectedActiveDays), detail: L("有 Token 记录"))
                HistoryOverviewMetric(label: L("日均 Token"), value: TokenStepFormat.tokens(selectedDailyAverage, compact: true), detail: L("按日历日计算"))
            }

            TokenCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Token 趋势"))
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(Color.tokenInk)
                            Text(L("柱越高，用量越多；细线是每日目标"))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(peakDayText)
                            .font(.callout.weight(.heavy))
                            .foregroundStyle(Color.tokenGreenDark)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.tokenMint.opacity(0.28), in: Capsule())
                    }
                    StackedActivityBarsView(
                        rows: selectedRows,
                        goal: appState.settings.dailyGoalTokens,
                        maxCount: min(range.chartDays, max(selectedRows.count, 1))
                    )
                    .frame(height: 108)
                }
            }

            TokenCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("连续活跃与圈数"))
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(Color.tokenInk)
                            Text(L("颜色越深，用量越高；描边是今天"))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(localizedStreakDescription(days: appState.activeStreak.days, isLowerBound: appState.activeStreak.isLowerBound))
                            .font(.callout.weight(.heavy))
                            .foregroundStyle(Color.tokenGreenDark)
                    }
                    ContributionWallView(
                        rows: selectedRows,
                        goal: appState.settings.dailyGoalTokens,
                        weeks: range.wallWeeks
                    )
                }
            }

            HStack(alignment: .top, spacing: 22) {
                HistoryCompactDimensionCard(title: L("主力工具"), rows: Array(toolRows.prefix(3)), showsToolColor: true)
                HistoryCompactDimensionCard(title: L("主力模型"), rows: Array(modelRows.prefix(3)), showsToolColor: false)
            }
        }
    }

    private func dimensionPage(
        title: String,
        subtitle: String,
        rows: [HistoryDimensionRow],
        showsToolColor: Bool
    ) -> some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(subtitle)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(LFormat("共 %d 项", rows.count))
                        .font(.callout.weight(.heavy))
                        .foregroundStyle(Color.tokenGreenDark)
                }
                if rows.isEmpty {
                    Text(L("等待下一次同步"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(rows) { row in
                            HistoryDimensionRowView(row: row, showsToolColor: showsToolColor)
                        }
                    }
                }
            }
        }
    }

    private var dailyDetails: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("每日明细"))
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

    private var selectedRows: [DailyUsage] {
        UsageCalendarWindow.rows(from: appState.snapshot.daily, days: range.days)
    }

    private var selectedTotal: Int { selectedRows.map(\.totalTokens).reduce(0, +) }
    private var selectedCost: Double { selectedRows.map(\.cost).reduce(0, +) }
    private var selectedActiveDays: Int { selectedRows.filter { $0.totalTokens > 0 }.count }
    private var selectedDailyAverage: Int {
        guard !selectedRows.isEmpty else { return 0 }
        return selectedTotal / selectedRows.count
    }
    private var selectedPricingCoverage: Double? {
        guard selectedRows.allSatisfy({ $0.pricedTokens != nil && $0.unpricedTokens != nil }) else { return nil }
        let priced = selectedRows.compactMap(\.pricedTokens).reduce(0, +)
        let unpriced = selectedRows.compactMap(\.unpricedTokens).reduce(0, +)
        guard priced + unpriced > 0 else { return 1 }
        return Double(priced) / Double(priced + unpriced)
    }
    private var peakDayText: String {
        guard let row = selectedRows.max(by: { $0.totalTokens < $1.totalTokens }), row.totalTokens > 0 else {
            return L("暂无峰值")
        }
        return LFormat("峰值 %@ · %@", row.date, TokenStepFormat.tokens(row.totalTokens, compact: true))
    }
    private var toolRows: [HistoryDimensionRow] { dimensionRows(\.tools) }
    private var modelRows: [HistoryDimensionRow] { dimensionRows(\.models) }

    private func dimensionRows(_ values: KeyPath<DailyUsage, [String: Int]>) -> [HistoryDimensionRow] {
        var totals: [String: Int] = [:]
        for row in selectedRows {
            for (name, tokens) in row[keyPath: values] where tokens > 0 {
                totals[name, default: 0] += tokens
            }
        }
        let grandTotal = max(1, totals.values.reduce(0, +))
        return totals.sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }.map { name, tokens in
            HistoryDimensionRow(name: name, tokens: tokens, percent: Double(tokens) * 100 / Double(grandTotal))
        }
    }

    private func localizedDays(_ count: Int) -> String {
        TokenStepLocalization.language == .en ? "\(count)d" : "\(count) 天"
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

private enum HistorySection: String, CaseIterable, Identifiable {
    case overview
    case tools
    case models
    case daily
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return L("总览")
        case .tools: return L("工具")
        case .models: return L("模型")
        case .daily: return L("每日")
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "chart.xyaxis.line"
        case .tools: return "hammer.fill"
        case .models: return "cpu.fill"
        case .daily: return "calendar"
        }
    }
}

private enum HistoryRange: String, CaseIterable, Identifiable {
    case sevenDays
    case thirtyDays
    case ninetyDays
    case all
    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        case .all: return nil
        }
    }
    var title: String {
        switch self {
        case .sevenDays: return L("近 7 天")
        case .thirtyDays: return L("近 30 天")
        case .ninetyDays: return L("近 90 天")
        case .all: return L("全部")
        }
    }
    var chartDays: Int { min(days ?? 90, 90) }
    var wallWeeks: Int {
        switch self {
        case .sevenDays: return 1
        case .thirtyDays: return 5
        case .ninetyDays: return 13
        case .all: return 34
        }
    }
}

private struct HistoryDimensionRow: Identifiable {
    var id: String { name }
    var name: String
    var tokens: Int
    var percent: Double
}

private struct HistoryOverviewMetric: View {
    var label: String
    var value: String
    var detail: String

    var body: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.callout.weight(.bold)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                Text(detail).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct HistoryDimensionRowView: View {
    var row: HistoryDimensionRow
    var showsToolColor: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if showsToolColor {
                    Circle().fill(tokenToolColor(row.name)).frame(width: 9, height: 9)
                }
                Text(row.name).font(.callout.weight(.heavy)).foregroundStyle(Color.tokenInk).lineLimit(2)
                Spacer()
                Text(TokenStepFormat.tokens(row.tokens, compact: true)).font(.callout.weight(.heavy)).monospacedDigit()
                Text(TokenStepFormat.percent(row.percent)).font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.tokenTrack)
                    Capsule()
                        .fill(showsToolColor ? tokenToolColor(row.name) : Color.tokenGreen)
                        .frame(width: proxy.size.width * min(max(row.percent / 100, 0), 1))
                }
            }
            .frame(height: 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.tokenTrack.opacity(0.22), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct HistoryCompactDimensionCard: View {
    var title: String
    var rows: [HistoryDimensionRow]
    var showsToolColor: Bool

    var body: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.title3.weight(.heavy)).foregroundStyle(Color.tokenInk)
                if rows.isEmpty {
                    Text(L("等待下一次同步")).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        HistoryDimensionRowView(row: row, showsToolColor: showsToolColor)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
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
