import SwiftUI

/// The beta.8 chart intentionally uses one Token axis. Cache coverage stays
/// available as an explanatory detail, but it never shares a visual scale with
/// Token volume.
struct TodayAgentWorkCard: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering
    @State private var period: AgentWorkPeriod = .today
    @State private var dimension: AgentWorkDimension = .tool
    @State private var selectedValue = AgentWorkSelection.all

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            readingSummary
            filterRow
            metricStrip
            AgentWorkTokenChart(bars: chartBars, period: period)
            cacheDetail
        }
        .padding(15)
        .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.black.opacity(0.07)))
        .onChange(of: dimension) { _ in selectedValue = AgentWorkSelection.all }
        .onChange(of: period) { _ in
            if !availableValues.contains(selectedValue) {
                selectedValue = AgentWorkSelection.all
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Agent 工作强度"))
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Color.tokenInk)
                Text(L("看清 Token 主要在什么时间产生；不代表工时或生产力。"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                ForEach(AgentWorkPeriod.allCases) { item in
                    AgentWorkSegmentButton(title: item.title, selected: period == item) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            period = item
                        }
                    }
                }
            }
            .padding(3)
            .background(Color.tokenTrack.opacity(0.42), in: Capsule())
        }
    }

    private var readingSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L("一句话看懂"))
                .font(.caption.weight(.heavy))
                .foregroundStyle(Color.tokenGreenDark)
            Text(summarySentence)
                .font(.caption.weight(.heavy))
                .foregroundStyle(Color.tokenInk)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.tokenMint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(AgentWorkDimension.allCases) { item in
                    AgentWorkSegmentButton(title: item.title, selected: dimension == item) {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                            dimension = item
                        }
                    }
                }
            }
            .padding(3)
            .background(Color.tokenTrack.opacity(0.42), in: Capsule())

            if isScreenshotRendering {
                HStack(spacing: 7) {
                    Text(selectedValue == AgentWorkSelection.all ? dimension.allLabel : selectedValue)
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Color.tokenInk.opacity(0.76))
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .frame(minWidth: 150, maxWidth: 220, minHeight: 28)
                .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.black.opacity(0.09)))
            } else {
                Picker(dimension.filterLabel, selection: $selectedValue) {
                    Text(dimension.allLabel).tag(AgentWorkSelection.all)
                    ForEach(availableValues, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 150, maxWidth: 220)
            }

            Text(LFormat("%d 个%@ · 可继续扩展", availableValues.count, dimension.countNoun))
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var metricStrip: some View {
        HStack(spacing: 7) {
            AgentWorkMetricTile(
                title: period == .today ? L("今日 Token") : L("近 7 日 Token"),
                value: TokenStepFormat.tokens(selectedPeriodTokens, compact: true),
                detail: selectionDescription
            )
            AgentWorkMetricTile(
                title: period == .today ? L("活跃小时") : L("活跃天数"),
                value: period == .today ? "\(activeBarCount) / 24" : localizedDays(activeBarCount),
                detail: L("有 Token 记录")
            )
            AgentWorkMetricTile(
                title: period == .today ? L("峰值时段") : L("峰值日期"),
                value: peakLabel,
                detail: peakTokens > 0 ? TokenStepFormat.tokens(peakTokens, compact: true) : "--"
            )
            AgentWorkMetricTile(
                title: period == .today ? L("较近 7 日均值") : L("日均 Token"),
                value: comparisonText,
                detail: L("按 7 个日历日计算")
            )
        }
    }

    private var cacheDetail: some View {
        DisclosureGroup {
            Text(cacheExplanation)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.tokenGreenDark)
                Text(L("缓存详情"))
                    .font(.caption.weight(.heavy))
                Text(cacheRateText(selectedCacheHitRate))
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Color.tokenGreenDark)
            }
        }
        .tint(Color.tokenGreenDark)
    }

    private var trailingDates: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
                .map(DateFormatter.tokenStepDay.string(from:))
        }
    }

    private var periodDates: [String] {
        period == .today ? [DateFormatter.tokenStepDay.string(from: Date())] : trailingDates
    }

    private var periodWorks: [DailyAgentWork] {
        periodDates.map(appState.agentWork(for:))
    }

    private var periodUsage: [DailyUsage] {
        periodDates.map { date in
            appState.snapshot.daily.last(where: { $0.date == date })
                ?? DailyUsage(date: date, tools: [:], totalTokens: 0, cost: 0)
        }
    }

    private var availableValues: [String] {
        var totals: [String: Int] = [:]
        switch dimension {
        case .tool:
            for work in periodWorks {
                for source in work.sources where source.tokens > 0 {
                    totals[source.source, default: 0] += source.tokens
                }
            }
        case .model:
            for day in periodUsage {
                for (model, tokens) in day.models where tokens > 0 {
                    totals[model, default: 0] += tokens
                }
            }
        }
        return totals.sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }.map(\.key)
    }

    private var chartBars: [AgentWorkTokenBar] {
        switch period {
        case .today:
            let work = appState.todayAgentWork
            return (0..<24).map { hour in
                let bucket = work.bucket(hour: hour)
                return AgentWorkTokenBar(
                    id: String(format: "%02d", hour),
                    shortLabel: String(format: "%02d", hour),
                    fullLabel: String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24),
                    tokens: tokens(in: bucket)
                )
            }
        case .sevenDays:
            return Array(zip(periodDates, periodUsage)).map { date, day in
                AgentWorkTokenBar(
                    id: date,
                    shortLabel: shortDate(date),
                    fullLabel: date,
                    tokens: selectedTokens(in: day)
                )
            }
        }
    }

    private var selectedPeriodTokens: Int {
        chartBars.map(\.tokens).reduce(0, +) + selectedUnbucketedTokens
    }

    private var selectedUnbucketedTokens: Int {
        guard period == .today else { return 0 }
        let work = appState.todayAgentWork
        guard selectedValue == AgentWorkSelection.all else {
            // A legacy unbucketed total has no reliable tool/model assignment.
            return 0
        }
        return work.unbucketedTokens
    }

    private var activeBarCount: Int {
        chartBars.filter { $0.tokens > 0 }.count
    }

    private var peakBar: AgentWorkTokenBar? {
        chartBars.max {
            if $0.tokens == $1.tokens { return $0.id > $1.id }
            return $0.tokens < $1.tokens
        }
    }

    private var peakTokens: Int { peakBar?.tokens ?? 0 }

    private var peakLabel: String {
        guard let peakBar, peakBar.tokens > 0 else { return "--" }
        return peakBar.fullLabel
    }

    private var selectedSevenDayAverage: Int {
        let total = trailingDates.reduce(0) { partial, date in
            let day = appState.snapshot.daily.last(where: { $0.date == date })
                ?? DailyUsage(date: date, tools: [:], totalTokens: 0, cost: 0)
            return partial + selectedTokens(in: day)
        }
        return total / 7
    }

    private var comparisonText: String {
        guard period == .today else {
            return TokenStepFormat.tokens(selectedPeriodTokens / 7, compact: true)
        }
        let average = selectedSevenDayAverage
        guard average > 0 else { return L("样本不足") }
        let delta = Double(selectedPeriodTokens - average) / Double(average) * 100
        let prefix = delta >= 0 ? "+" : "−"
        return prefix + TokenStepFormat.percent(abs(delta))
    }

    private var summarySentence: String {
        guard let peakBar, peakBar.tokens > 0 else {
            return L("当前筛选下还没有可统计的 Token 时段。")
        }
        if period == .today {
            return LFormat("今天有 %d 个小时产生 Token，峰值在 %@", activeBarCount, peakBar.fullLabel)
        }
        return LFormat("近 7 天有 %d 个活跃日，峰值在 %@", activeBarCount, peakBar.fullLabel)
    }

    private var selectionDescription: String {
        selectedValue == AgentWorkSelection.all ? dimension.allLabel : selectedValue
    }

    private var selectedHourlyRows: [AgentWorkHourlySource] {
        periodWorks.flatMap(\.hourlyBuckets).flatMap(\.sources).filter(matchesSelection)
    }

    private var selectedCacheHitRate: Double? {
        let rows = selectedHourlyRows.filter { $0.tokens > 0 }
        guard !rows.isEmpty, rows.allSatisfy(\.cacheCoverageComplete) else { return nil }
        let totalInput = rows.map(\.inputTokens).reduce(0, +)
        guard totalInput > 0 else { return nil }
        return Double(rows.map(\.cachedInputTokens).reduce(0, +)) / Double(totalInput)
    }

    private var cacheExplanation: String {
        guard let rate = selectedCacheHitRate else {
            return L("当前筛选的缓存口径不完整；缓存不会进入工作强度主图。")
        }
        return LFormat("输入中有 %@ 复用了缓存。该指标只用于解释费用，不代表工作强度高低。", cacheRateText(rate))
    }

    private func matchesSelection(_ row: AgentWorkHourlySource) -> Bool {
        guard selectedValue != AgentWorkSelection.all else { return true }
        switch dimension {
        case .tool: return row.source == selectedValue
        case .model: return row.model == selectedValue
        }
    }

    private func tokens(in bucket: AgentWorkHourBucket) -> Int {
        bucket.sources.filter(matchesSelection).map(\.tokens).reduce(0, +)
    }

    private func selectedTokens(in day: DailyUsage) -> Int {
        guard selectedValue != AgentWorkSelection.all else { return day.totalTokens }
        switch dimension {
        case .tool: return day.tools[selectedValue] ?? 0
        case .model: return day.models[selectedValue] ?? 0
        }
    }

    private func shortDate(_ value: String) -> String {
        guard let date = DateFormatter.tokenStepDay.date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = TokenStepLocalization.locale
        formatter.dateFormat = TokenStepLocalization.language == .en ? "EEE" : "E"
        return formatter.string(from: date)
    }

    private func localizedDays(_ count: Int) -> String {
        TokenStepLocalization.language == .en ? "\(count)d" : "\(count) 天"
    }
}

struct PopoverAgentWorkStrip: View {
    @EnvironmentObject private var appState: AppState
    static let destination: AppSection = .today

    private var work: DailyAgentWork { appState.todayAgentWork }

    var body: some View {
        Button {
            MainWindowPresenter.shared.show(appState: appState, section: Self.destination)
        } label: {
            HStack(spacing: 8) {
                Label(AgentWorkCopy.agentActivity, systemImage: "bolt.horizontal.circle.fill")
                Text(popoverSummary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.heavy))
            .foregroundStyle(Color.tokenInk.opacity(0.78))
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.black.opacity(0.055)))
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L("打开今日页"))
    }

    private var popoverSummary: String {
        [
            TokenStepFormat.tokens(work.totalTokens, compact: true),
            AgentWorkCopy.recordedShort("\(work.activeHours)/24"),
            "\(AgentWorkCopy.cacheShort) \(cacheRateText(work.cacheHitRate))"
        ].joined(separator: " · ")
    }
}

private struct AgentWorkMetricTile: View {
    var title: String
    var value: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.heavy))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.tokenInk)
                .lineLimit(1)
                .minimumScaleFactor(0.56)
                .monospacedDigit()
            Text(detail)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.tokenTrack.opacity(0.24), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AgentWorkTokenChart: View {
    var bars: [AgentWorkTokenBar]
    var period: AgentWorkPeriod
    @State private var hoveredID: String?

    private var maximum: Int { max(1, bars.map(\.tokens).max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(period == .today ? L("每小时 Token") : L("每日 Token"))
                    .font(.callout.weight(.heavy))
                    .foregroundStyle(Color.tokenInk)
                Spacer()
                Text(hoverSummary)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                let spacing: CGFloat = period == .today ? 3 : 10
                let width = max(5, (proxy.size.width - spacing * CGFloat(max(bars.count - 1, 0))) / CGFloat(max(bars.count, 1)))
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(bars) { bar in
                        let height = bar.tokens > 0
                            ? max(5, proxy.size.height * CGFloat(bar.tokens) / CGFloat(maximum))
                            : 2
                        RoundedRectangle(cornerRadius: min(4, width / 2), style: .continuous)
                            .fill(bar.tokens > 0 ? Color.tokenGreen : Color.tokenTrack)
                            .frame(width: width, height: height)
                            .frame(width: width, height: proxy.size.height, alignment: .bottom)
                            .contentShape(Rectangle())
                            .onHover { hovering in hoveredID = hovering ? bar.id : (hoveredID == bar.id ? nil : hoveredID) }
                            .help("\(bar.fullLabel)\n\(TokenStepFormat.tokens(bar.tokens))")
                    }
                }
            }
            .frame(height: 96)

            HStack {
                if period == .today {
                    ForEach(["00", "06", "12", "18", "24"], id: \.self) { label in
                        Text(label)
                        if label != "24" { Spacer() }
                    }
                } else {
                    ForEach(bars) { bar in
                        Text(bar.shortLabel).frame(maxWidth: .infinity)
                    }
                }
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(10)
        .background(Color.tokenSurface.opacity(0.64), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.black.opacity(0.055)))
    }

    private var hoverSummary: String {
        guard let hoveredID, let bar = bars.first(where: { $0.id == hoveredID }) else {
            return L("柱子越高，表示这个时段使用的 Token 越多")
        }
        return "\(bar.fullLabel) · \(TokenStepFormat.tokens(bar.tokens, compact: true))"
    }
}

private struct AgentWorkTokenBar: Identifiable {
    var id: String
    var shortLabel: String
    var fullLabel: String
    var tokens: Int
}

private struct AgentWorkSegmentButton: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.heavy))
                .foregroundStyle(selected ? Color.tokenSurface : Color.tokenInk.opacity(0.62))
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background(selected ? Color.tokenInk : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private enum AgentWorkSelection {
    static let all = "__all__"
}

private enum AgentWorkPeriod: String, CaseIterable, Identifiable {
    case today
    case sevenDays
    var id: String { rawValue }
    var title: String { self == .today ? AgentWorkCopy.today : AgentWorkCopy.sevenDays }
}

private enum AgentWorkDimension: String, CaseIterable, Identifiable {
    case tool
    case model
    var id: String { rawValue }
    var title: String { self == .tool ? L("按工具") : L("按模型") }
    var filterLabel: String { self == .tool ? L("筛选工具") : L("筛选模型") }
    var allLabel: String { self == .tool ? L("全部工具") : L("全部模型") }
    var countNoun: String { self == .tool ? L("工具") : L("模型") }
}

enum AgentWorkCopy {
    static var today: String { localized("今日", "Today", "今日") }
    static var sevenDays: String { localized("近 7 天", "Last 7 Days", "近 7 天") }
    static var agentActivity: String { localized("Agent 活跃", "Agent Activity", "Agent 活躍") }
    static var recordedHours: String { localized("有记录小时", "Hours with Records", "有記錄小時") }
    static var cacheShort: String { localized("缓存", "Cache", "快取") }
    static func recordedShort(_ value: String) -> String {
        localized("记录 \(value)", "Recorded \(value)", "記錄 \(value)")
    }
    static func hourLabel(_ hour: Int) -> String {
        localized("\(hour)时", "\(hour)h", "\(hour)時")
    }

    private static func localized(_ zhHans: String, _ en: String, _ zhHant: String) -> String {
        switch TokenStepLocalization.language {
        case .en: return en
        case .zhHant: return zhHant
        case .zhHans, .system: return zhHans
        }
    }
}

private func cacheRateText(_ rate: Double?) -> String {
    guard let rate else { return "--" }
    return TokenStepFormat.percent(min(max(rate, 0), 1) * 100)
}
