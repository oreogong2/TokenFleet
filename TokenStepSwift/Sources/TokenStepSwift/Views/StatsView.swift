import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var range: StatsRange = .thirtyDays

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 18) {
                StatHeroMetric(label: L("Token 消耗"), value: TokenStepFormat.tokens(selectedTokens), symbol: "waveform.path.ecg")
                StatHeroMetric(
                    label: "\(L("费用估算")) · \(TokenStepFormat.pricingCoverage(selectedPricingCoverage))",
                    value: TokenStepFormat.estimatedMoney(selectedCost, coverage: selectedPricingCoverage),
                    symbol: "dollarsign.circle"
                )
                StatHeroMetric(label: L("活跃天数"), value: localizedDays(selectedActiveDays), symbol: "flame")
            }

            recentActivityCard

            HStack(alignment: .top, spacing: 22) {
                usageList(title: L("按客户端"), subtitle: range.label, rows: toolRows)
                usageList(title: L("按模型"), subtitle: "Top \(min(modelRows.count, 10)) / \(modelRows.count)", rows: Array(modelRows.prefix(10)))
            }
        }
    }

    private var recentActivityCard: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(range.title)
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(L("柱越高，用量越多；颜色代表客户端"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(L("时间范围"), selection: $range) {
                        ForEach(StatsRange.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 310)
                    TokenToolLegend(tools: recentTools, showsGoalLine: true)
                    Text(LFormat("今天 %@", TokenStepFormat.tokens(appState.today.totalTokens, compact: true)))
                        .font(.callout.weight(.bold))
                        .foregroundStyle(Color.tokenGreenDark)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.tokenMint.opacity(0.28), in: Capsule())
                }

                StackedActivityBarsView(rows: selectedRows, goal: appState.settings.dailyGoalTokens, maxCount: range.chartDays)
                    .frame(height: 96)
            }
        }
    }

    private func usageList(title: String, subtitle: String, rows: [UsageStatRow]) -> some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Spacer()
                    Text(subtitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if rows.isEmpty {
                    Text(L("等待下一次同步"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                } else {
                    ForEach(rows) { row in
                        UsageProgressRow(
                            name: row.name,
                            value: "\(TokenStepFormat.tokens(row.value, compact: true)) · \(TokenStepFormat.percent(row.percent))",
                            percent: row.percent,
                            color: row.color
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func localizedDays(_ count: Int) -> String {
        TokenStepLocalization.language == .en ? "\(count)d" : "\(count) 天"
    }

    private var recentTools: [String] {
        uniqueToolNames(in: selectedRows)
    }

    private var selectedRows: [DailyUsage] {
        guard let days = range.days else { return appState.snapshot.daily }
        return Array(appState.snapshot.daily.suffix(days))
    }

    private var selectedTokens: Int {
        selectedRows.reduce(0) { $0 + $1.totalTokens }
    }

    private var selectedCost: Double {
        selectedRows.reduce(0) { $0 + $1.cost }
    }

    private var selectedPricingCoverage: Double? {
        let pricedValues = selectedRows.compactMap(\.pricedTokens)
        let unpricedValues = selectedRows.compactMap(\.unpricedTokens)
        guard pricedValues.count == selectedRows.count,
              unpricedValues.count == selectedRows.count
        else {
            return nil
        }
        let priced = pricedValues.reduce(0, +)
        let unpriced = unpricedValues.reduce(0, +)
        guard priced + unpriced > 0 else { return 1 }
        return Double(priced) / Double(priced + unpriced)
    }

    private var selectedActiveDays: Int {
        selectedRows.filter { $0.totalTokens > 0 }.count
    }

    private var toolRows: [UsageStatRow] {
        let values = aggregate(\.tools)
        return values.map { name, value in
            UsageStatRow(name: name, value: value, percent: percent(value), color: tokenToolColor(name))
        }
    }

    private var modelRows: [UsageStatRow] {
        aggregate(\.models).map { name, value in
            UsageStatRow(name: name, value: value, percent: percent(value), color: .tokenGreenDark)
        }
    }

    private func aggregate(_ keyPath: KeyPath<DailyUsage, [String: Int]>) -> [(String, Int)] {
        var values: [String: Int] = [:]
        for day in selectedRows {
            for (name, value) in day[keyPath: keyPath] {
                values[name, default: 0] += value
            }
        }
        return values.sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }
    }

    private func percent(_ value: Int) -> Double {
        guard selectedTokens > 0 else { return 0 }
        return Double(value) * 100 / Double(selectedTokens)
    }
}

private enum StatsRange: String, CaseIterable, Identifiable {
    case sevenDays
    case thirtyDays
    case ninetyDays
    case all

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .all: nil
        }
    }

    var chartDays: Int {
        min(days ?? 90, 90)
    }

    var label: String {
        switch self {
        case .sevenDays: L("近 7 天")
        case .thirtyDays: L("近 30 天")
        case .ninetyDays: L("近 90 天")
        case .all: L("全部")
        }
    }

    var title: String {
        self == .all ? L("全部用量（图表显示最近 90 天）") : label
    }
}

private struct StatHeroMetric: View {
    var label: String
    var value: String
    var symbol: String

    var body: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 15) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.tokenMint.opacity(0.24))
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.tokenGreenDark)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 7) {
                    Text(value)
                        .font(.system(size: 29, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.tokenInk)
                        .minimumScaleFactor(0.62)
                        .lineLimit(1)
                    Text(label)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct UsageStatRow: Identifiable {
    var id: String { name }
    var name: String
    var value: Int
    var percent: Double
    var color: Color
}
