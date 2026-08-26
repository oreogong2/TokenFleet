import SwiftUI

final class HistoryPresentationState: ObservableObject {
    @Published var section: HistorySection
    @Published var range: HistoryRange
    @Published var expandedDates: Set<String>

    init(
        section: HistorySection = .overview,
        range: HistoryRange = .all,
        expandedDates: Set<String> = []
    ) {
        self.section = section
        self.range = range
        self.expandedDates = expandedDates
    }
}

enum HistoryContributionLayout {
    static let cellSize: CGFloat = 12
    static let cellSpacing: CGFloat = 3
    static let maximumWidth: CGFloat = 600
    static let maximumHeight: CGFloat = 102

    static func gridWidth(weeks: Int) -> CGFloat {
        let columns = max(1, weeks)
        return CGFloat(columns) * cellSize
            + CGFloat(max(0, columns - 1)) * cellSpacing
    }

    static var gridHeight: CGFloat {
        7 * cellSize + 6 * cellSpacing
    }
}

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering
    @ObservedObject private var presentation: HistoryPresentationState
    var historyLimit: Int? = nil

    init(
        historyLimit: Int? = nil,
        initialSection: HistorySection = .overview,
        initialRange: HistoryRange = .all,
        initialExpandedDates: Set<String> = [],
        presentation: HistoryPresentationState? = nil
    ) {
        self.historyLimit = historyLimit
        _presentation = ObservedObject(
            wrappedValue: presentation ?? HistoryPresentationState(
                section: initialSection,
                range: initialRange,
                expandedDates: initialExpandedDates
            )
        )
    }

    var body: some View {
        VStack(spacing: 11) {
            controls
            switch section {
            case .overview:
                overview
            case .tools:
                dimensionPage(
                    title: L("工具消耗"),
                    subtitle: L("按所选时间范围聚合，支持任意数量工具"),
                    rows: toolRows,
                    showsToolColor: true,
                    kind: .tool
                )
            case .models:
                dimensionPage(
                    title: L("模型消耗"),
                    subtitle: L("按所选时间范围聚合，支持任意数量模型"),
                    rows: modelRows,
                    showsToolColor: false,
                    kind: .model
                )
            case .daily:
                dailyDetails
            }
        }
    }

    private var section: HistorySection {
        get { presentation.section }
        nonmutating set { presentation.section = newValue }
    }

    private var range: HistoryRange {
        get { presentation.range }
        nonmutating set { presentation.range = newValue }
    }

    private var expandedDates: Set<String> {
        get { presentation.expandedDates }
        nonmutating set { presentation.expandedDates = newValue }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            navigation
                .frame(width: 540)
            if section != .daily {
                Divider().frame(height: 24)
                rangePicker
            }
        }
        .padding(5)
        .background(Color.tokenTrack.opacity(0.54), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var navigation: some View {
        HStack(spacing: 5) {
            ForEach(HistorySection.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        section = item
                    }
                } label: {
                    Text(item.title)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(section == item ? Color.tokenSurface : Color.tokenInk.opacity(0.68))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(section == item ? Color.tokenInk : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var rangePicker: some View {
        HStack(spacing: 5) {
            Text(L("时间"))
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(HistoryRange.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            range = item
                        }
                    } label: {
                        Text(item.title)
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(item == range ? Color.white : Color.tokenInk.opacity(0.62))
                            .padding(.horizontal, 8)
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
            .allowsHitTesting(!isScreenshotRendering)
            .accessibilityLabel(L("时间范围"))
        }
    }

    private var activityTitle: String {
        guard range == .all else { return range.activityTitle }
        return LFormat("全部历史 · 最近 %d 天活动热力图", wallRows.count)
    }

    private var trendTitle: String {
        guard range == .all else { return range.trendTitle }
        return LFormat("全部历史 · 最近 %d 周 Token 趋势", displayedTrendRows.count)
    }

    private var overview: some View {
        VStack(spacing: 11) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                HistoryOverviewMetric(label: L("累计 Token"), value: TokenStepFormat.tokens(selectedTotal, compact: true), detail: range.title)
                HistoryOverviewMetric(
                    label: L("API 标准价估算"),
                    value: TokenStepFormat.estimatedMoney(selectedCost, coverage: selectedPricingCoverage),
                    detail: TokenStepFormat.pricingCoverage(selectedPricingCoverage)
                )
                HistoryOverviewMetric(label: L("可估价 Token"), value: TokenStepFormat.pricingCoverage(selectedPricingCoverage), detail: L("未定价不按 0"))
                HistoryOverviewMetric(label: L("历史活跃"), value: localizedDays(selectedActiveDays), detail: L("有 Token 记录"))
                HistoryOverviewMetric(label: L("日均 Token"), value: TokenStepFormat.tokens(selectedDailyAverage, compact: true), detail: L("按日历日计算"))
                HistoryOverviewMetric(label: L("单日峰值"), value: peakTokenValue, detail: peakDayLabel)
                HistoryOverviewMetric(label: L("本月日均"), value: TokenStepFormat.tokens(currentMonthDailyAverage, compact: true), detail: L("按上海日界计算"))
                HistoryOverviewMetric(label: L("达标天数"), value: localizedDays(selectedGoalDays), detail: range.title)
            }

            HStack(alignment: .top, spacing: 11) {
                HistoryVisualCard(
                    title: activityTitle,
                    subtitle: L("每格一天；颜色越深，Token 用量越高")
                ) {
                    ContributionWallView(
                        rows: wallRows,
                        goal: appState.settings.dailyGoalTokens,
                        weeks: range.wallWeeks,
                        cellSize: HistoryContributionLayout.cellSize,
                        cellSpacing: HistoryContributionLayout.cellSpacing,
                        showsSummary: false
                    )
                    .frame(
                        width: HistoryContributionLayout.maximumWidth,
                        height: HistoryContributionLayout.maximumHeight,
                        alignment: .leading
                    )
                    .clipped()
                }
                .frame(width: 628)

                HistoryVisualCard(
                    title: trendTitle,
                    subtitle: range.usesWeeklyTrend ? L("按周汇总，包含缓存 Token") : L("按日汇总，包含缓存 Token")
                ) {
                    StackedActivityBarsView(
                        rows: displayedTrendRows,
                        goal: trendGoal,
                        maxCount: max(displayedTrendRows.count, 1)
                    )
                    .frame(height: 102)
                }
                .frame(width: 300)
            }

            HStack(alignment: .top, spacing: 11) {
                HistoryCompactDimensionCard(title: L("工具分布"), subtitle: L("总览只展示 Top 3；完整列表请点击“按工具”"), rows: Array(toolRows.prefix(3)), showsToolColor: true)
                    .frame(width: 464)
                HistoryCompactDimensionCard(title: L("模型分布"), subtitle: L("只展示有可靠模型字段的聚合"), rows: Array(modelRows.prefix(3)), showsToolColor: false)
                    .frame(width: 464)
            }
        }
    }

    private func dimensionPage(
        title: String,
        subtitle: String,
        rows: [HistoryDimensionRow],
        showsToolColor: Bool,
        kind: HistoryDimensionKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(LFormat("完整列表 · 共 %d 项，不截断", rows.count))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(range.title)
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Color.tokenGreenDark)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.tokenTrack.opacity(0.38), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(subtitle)
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(LFormat("共 %d 项", rows.count))
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Color.tokenGreenDark)
                }
                if rows.isEmpty {
                    Text(L("等待下一次同步"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
                } else {
                    LazyVStack(spacing: 0) {
                        HistoryDimensionTableHeader(kind: kind)
                        ForEach(rows) { row in
                            HistoryDimensionRowView(
                                row: row,
                                showsToolColor: showsToolColor,
                                kind: kind
                            )
                        }
                    }
                }
            }
            .padding(14)
            .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.black.opacity(0.08)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("旧数据说明"))
                        .font(.system(size: 8, weight: .heavy))
                    Text(L("早期记录可能缺少工具、模型或缓存分项；缺失项明确显示“不完整”，不会补造工具 × 模型交叉值，也不会按 0 参与费用解释。"))
                        .font(.system(size: 7, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color(red: 0.44, green: 0.34, blue: 0.10))
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 1.0, green: 0.97, blue: 0.86), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.32)))

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

    private var wallRows: [DailyUsage] {
        UsageCalendarWindow.contributionRows(from: selectedRows, weeks: range.wallWeeks)
    }

    /// The 90-day and all-time views promise weekly bars in the confirmed UI.
    /// Aggregate from the most recent accounting day backwards so every full
    /// bar represents seven Asia/Shanghai calendar days; only the oldest bar
    /// may be a partial week.
    private var trendRows: [DailyUsage] {
        guard range.usesWeeklyTrend else { return selectedRows }
        var groups: [[DailyUsage]] = []
        var end = selectedRows.count
        while end > 0 {
            let start = max(0, end - 7)
            groups.append(Array(selectedRows[start..<end]))
            end = start
        }
        return groups.reversed().map(aggregateTrendWeek)
    }

    private var displayedTrendRows: [DailyUsage] {
        Array(trendRows.suffix(range.trendCount))
    }

    private var trendGoal: Int {
        range.usesWeeklyTrend ? appState.settings.dailyGoalTokens * 7 : appState.settings.dailyGoalTokens
    }

    private func aggregateTrendWeek(_ rows: [DailyUsage]) -> DailyUsage {
        var tools: [String: Int] = [:]
        var models: [String: Int] = [:]
        for row in rows {
            for (name, tokens) in row.tools { tools[name, default: 0] += tokens }
            for (name, tokens) in row.models { models[name, default: 0] += tokens }
        }

        let exactAtomicUsage: [DailyAtomicUsage]? = rows.allSatisfy { $0.atomicUsage != nil }
            ? rows.flatMap { $0.atomicUsage ?? [] }
            : nil
        let exactPricing = rows.allSatisfy { $0.pricedTokens != nil && $0.unpricedTokens != nil }
        let pricingVersions = Set(rows.compactMap(\.pricingVersion))
        let firstDate = rows.first?.date ?? ""
        let lastDate = rows.last?.date ?? firstDate

        return DailyUsage(
            date: firstDate == lastDate ? firstDate : "\(firstDate) – \(lastDate)",
            tools: tools,
            models: models,
            atomicUsage: exactAtomicUsage,
            totalTokens: rows.reduce(0) { $0 + $1.totalTokens },
            cost: rows.reduce(0) { $0 + $1.cost },
            pricedTokens: exactPricing ? rows.compactMap(\.pricedTokens).reduce(0, +) : nil,
            unpricedTokens: exactPricing ? rows.compactMap(\.unpricedTokens).reduce(0, +) : nil,
            pricingVersion: pricingVersions.count == 1 ? pricingVersions.first : nil
        )
    }

    private var selectedTotal: Int { selectedRows.map(\.totalTokens).reduce(0, +) }
    private var selectedCost: Double { selectedRows.map(\.cost).reduce(0, +) }
    private var selectedActiveDays: Int { selectedRows.filter { $0.totalTokens > 0 }.count }
    private var selectedGoalDays: Int {
        selectedRows.filter { $0.totalTokens >= appState.settings.dailyGoalTokens }.count
    }
    private var selectedDailyAverage: Int {
        guard !selectedRows.isEmpty else { return 0 }
        return selectedTotal / selectedRows.count
    }
    private var currentMonthRows: [DailyUsage] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let dayCount = max(1, calendar.component(.day, from: Date()))
        return UsageCalendarWindow.rows(
            from: appState.snapshot.daily,
            days: dayCount
        )
    }
    private var currentMonthDailyAverage: Int {
        guard !currentMonthRows.isEmpty else { return 0 }
        return currentMonthRows.map(\.totalTokens).reduce(0, +) / currentMonthRows.count
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
    private var peakTokenValue: String {
        guard let row = selectedRows.max(by: { $0.totalTokens < $1.totalTokens }), row.totalTokens > 0 else {
            return L("暂无")
        }
        return TokenStepFormat.tokens(row.totalTokens, compact: true)
    }
    private var peakDayLabel: String {
        selectedRows.max(by: { $0.totalTokens < $1.totalTokens })?.date ?? L("暂无峰值")
    }
    private var toolRows: [HistoryDimensionRow] { dimensionRows(\.tools, kind: .tool) }
    private var modelRows: [HistoryDimensionRow] { dimensionRows(\.models, kind: .model) }

    private func dimensionRows(
        _ values: KeyPath<DailyUsage, [String: Int]>,
        kind: HistoryDimensionKind
    ) -> [HistoryDimensionRow] {
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
            let activeDays = selectedRows.filter { $0[keyPath: values][name, default: 0] > 0 }.count
            var cost = 0.0
            var pricedTokens = 0
            var unpricedTokens = 0
            var exactTokens = 0
            var sourceTools = Set<String>()

            for day in selectedRows {
                for atomic in day.atomicUsage ?? [] {
                    let matches = kind == .tool ? atomic.tool == name : atomic.model == name
                    guard matches else { continue }
                    exactTokens += atomic.totalTokens
                    sourceTools.insert(atomic.tool)
                    let usage = TokenPricingUsage(
                        inputTokens: atomic.inputTokens,
                        outputTokens: atomic.outputTokens,
                        cacheReadTokens: atomic.cacheReadTokens,
                        cacheWriteTokens: atomic.cacheWriteTokens,
                        totalTokens: atomic.totalTokens,
                        breakdownComplete: atomic.breakdownComplete
                    )
                    if let estimate = TokenPricingCatalog.estimate(
                        tool: atomic.tool,
                        model: atomic.model,
                        usage: usage,
                        date: day.date
                    ) {
                        cost += estimate.costUSD
                        pricedTokens += estimate.pricedTokens
                        unpricedTokens += estimate.unpricedTokens
                    } else {
                        unpricedTokens += atomic.totalTokens
                    }
                }
            }

            if exactTokens < tokens {
                unpricedTokens += tokens - exactTokens
            }
            if kind == .model, sourceTools.isEmpty {
                for model in appState.snapshot.models where model.model == name {
                    if let tool = model.tool, !tool.isEmpty {
                        sourceTools.insert(tool)
                    }
                }
            }
            let coverageTotal = pricedTokens + unpricedTokens
            let coverage = coverageTotal > 0
                ? Double(pricedTokens) / Double(coverageTotal)
                : nil
            return HistoryDimensionRow(
                name: name,
                tokens: tokens,
                percent: Double(tokens) * 100 / Double(grandTotal),
                activeDays: activeDays,
                estimatedCost: exactTokens > 0 ? cost : nil,
                pricingCoverage: coverage,
                sourceTools: sourceTools.sorted()
            )
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

enum HistorySection: String, CaseIterable, Identifiable {
    case overview
    case tools
    case models
    case daily
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return L("总览")
        case .tools: return L("按工具")
        case .models: return L("按模型")
        case .daily: return L("每日明细")
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

enum HistoryRange: String, CaseIterable, Identifiable {
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
        case .sevenDays: return L("7 天")
        case .thirtyDays: return L("30 天")
        case .ninetyDays: return L("90 天")
        case .all: return L("全部")
        }
    }
    var trendCount: Int {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .ninetyDays: return 13
        case .all: return 34
        }
    }
    var activityTitle: String {
        switch self {
        case .sevenDays: return L("近 7 天活动热力图")
        case .thirtyDays: return L("近 30 天活动热力图")
        case .ninetyDays: return L("近 90 天活动热力图")
        case .all: return L("全部活动热力图")
        }
    }
    var trendTitle: String {
        switch self {
        case .sevenDays: return L("近 7 天 Token 趋势")
        case .thirtyDays: return L("近 30 天 Token 趋势")
        case .ninetyDays: return L("近 13 周 Token 趋势")
        case .all: return L("全部 Token 趋势")
        }
    }
    var usesWeeklyTrend: Bool { self == .ninetyDays || self == .all }
    var wallWeeks: Int {
        switch self {
        case .sevenDays: return 1
        case .thirtyDays: return 5
        case .ninetyDays: return 13
        case .all: return 34
        }
    }
}

private enum HistoryDimensionKind {
    case tool
    case model
}

private struct HistoryDimensionRow: Identifiable {
    var id: String { name }
    var name: String
    var tokens: Int
    var percent: Double
    var activeDays: Int
    var estimatedCost: Double?
    var pricingCoverage: Double?
    var sourceTools: [String]
}

private struct HistoryDimensionTableHeader: View {
    var kind: HistoryDimensionKind

    var body: some View {
        HStack(spacing: 10) {
            Text(L("项目")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("Token")).frame(width: 110, alignment: .trailing)
            Text(L("费用估算")).frame(width: 112, alignment: .trailing)
            Text(kind == .tool ? L("活跃天数") : L("来源工具"))
                .frame(width: 110, alignment: .trailing)
            Text(kind == .tool ? L("占比") : L("覆盖率"))
                .frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 7, weight: .heavy))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.tokenTrack.opacity(0.38))
    }
}

private struct HistoryOverviewMetric: View {
    var label: String
    var value: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.tokenInk)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.58)
            Text(detail).font(.system(size: 6, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.black.opacity(0.08)))
    }
}

private struct HistoryDimensionRowView: View {
    var row: HistoryDimensionRow
    var showsToolColor: Bool
    var kind: HistoryDimensionKind

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                if showsToolColor {
                    Circle().fill(tokenToolColor(row.name)).frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.tokenInk)
                        .lineLimit(1)
                    Text(localizedDays(row.activeDays))
                        .font(.system(size: 6, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(TokenStepFormat.tokens(row.tokens, compact: true))
                .font(.system(size: 9, weight: .heavy))
                .monospacedDigit()
                .frame(width: 110, alignment: .trailing)
            Text(costText)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(row.pricingCoverage == nil ? Color.secondary : Color.tokenInk.opacity(0.72))
                .frame(width: 112, alignment: .trailing)
            Text(kind == .tool
                 ? localizedDays(row.activeDays)
                 : row.sourceTools.isEmpty ? L("不完整") : row.sourceTools.joined(separator: " · "))
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .trailing)
            Text(kind == .tool ? TokenStepFormat.percent(row.percent) : coverageText)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(
                    kind == .tool || (row.pricingCoverage ?? 0) > 0
                        ? Color.tokenGreenDark
                        : Color.orange
                )
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1) }
    }

    private func localizedDays(_ count: Int) -> String {
        TokenStepLocalization.language == .en ? "\(count)d" : "\(count) 天"
    }

    private var coverageText: String {
        guard let coverage = row.pricingCoverage else { return L("不完整") }
        return TokenStepFormat.percent(coverage * 100)
    }

    private var costText: String {
        guard let cost = row.estimatedCost else { return L("不完整") }
        return TokenStepFormat.estimatedMoney(cost, coverage: row.pricingCoverage)
    }
}

private struct HistoryCompactDimensionCard: View {
    var title: String
    var subtitle: String
    var rows: [HistoryDimensionRow]
    var showsToolColor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.tokenInk)
                Text(subtitle).font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
                if rows.isEmpty {
                    Text(L("等待下一次同步")).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        HistoryCompactDimensionRow(row: row, showsToolColor: showsToolColor)
                    }
                }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.black.opacity(0.08)))
    }
}

private struct HistoryCompactDimensionRow: View {
    var row: HistoryDimensionRow
    var showsToolColor: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showsToolColor {
                Circle().fill(tokenToolColor(row.name)).frame(width: 7, height: 7)
            }
            Text(row.name)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(Color.tokenInk)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(TokenStepFormat.tokens(row.tokens, compact: true))
                .font(.system(size: 8, weight: .heavy))
                .monospacedDigit()
            Text(TokenStepFormat.percent(row.percent))
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(Color.tokenGreenDark)
                .frame(width: 48, alignment: .trailing)
        }
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.05)).frame(height: 1)
        }
    }
}

private struct HistoryVisualCard<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .heavy)).foregroundStyle(Color.tokenInk)
            Text(subtitle).font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.black.opacity(0.08)))
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
                    HistoryToolDetailView(tool: tool, date: row.date)
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
    var date: String
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
                        HistoryAtomicModelRow(model: model, date: date)
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
    var date: String

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
            VStack(alignment: .trailing, spacing: 2) {
                Text(L("估算"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(costText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(costText == L("未定价") ? Color.orange : Color.tokenInk.opacity(0.74))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .background(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.045)).frame(height: 1)
        }
    }

    private var costText: String {
        let usage = TokenPricingUsage(
            inputTokens: model.inputTokens,
            outputTokens: model.outputTokens,
            cacheReadTokens: model.cacheReadTokens,
            cacheWriteTokens: model.cacheWriteTokens,
            totalTokens: model.totalTokens,
            breakdownComplete: model.breakdownComplete
        )
        guard let estimate = TokenPricingCatalog.estimate(
            tool: model.tool,
            model: model.model,
            usage: usage,
            date: date
        ) else {
            return L("未定价")
        }
        let amount = TokenStepFormat.money(estimate.costUSD)
        return estimate.unpricedTokens > 0
            ? LFormat("%@ + 部分未定价", amount)
            : amount
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
