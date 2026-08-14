import AppKit
import SwiftUI

struct StatusBarLabelView: View {
    var tokens: Int
    var lap: TokenStepLapProgress
    var refreshing: Bool
    var theme: TokenStepTheme
    var language: TokenStepLanguage
    var showsTokenCount: Bool

    var body: some View {
        HStack(alignment: .center, spacing: showsTokenCount ? 6 : 0) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(
                    Array([CGFloat(7), CGFloat(12), CGFloat(17)].enumerated()),
                    id: \.offset
                ) { index, height in
                    Capsule()
                        .fill(Color.primary.opacity(refreshing && index == 1 ? 0.42 : 0.88))
                        .frame(width: 3.5, height: height)
                }
            }
            .frame(width: 18, height: 18, alignment: .bottom)

            if showsTokenCount {
                Text(TokenStepFormat.tokens(tokens, compact: true, language: language))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, showsTokenCount ? 2 : 1)
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "TokenFleet · \(TokenStepFormat.tokens(tokens, compact: true, language: language)) · "
                + "\(L("今日目标进度")) \(TokenStepFormat.percent(lap.rawProgress * 100))"
        )
        .id("\(theme.id)-\(language.resolved.id)-\(showsTokenCount)")
    }
}

struct TokenStepBackdrop: View {
    var body: some View {
        ZStack {
            Color.tokenCanvas
            LinearGradient(
                colors: [
                    Color.tokenMint.opacity(0.10),
                    Color.clear,
                    Color.tokenGreen.opacity(0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct TokenFleetSignalMark: View {
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Color.tokenSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .stroke(Color.tokenGreen.opacity(0.18), lineWidth: max(1, size * 0.018))
                )

            HStack(alignment: .bottom, spacing: size * 0.07) {
                signalBar(height: 0.31, opacity: 0.48)
                signalBar(height: 0.53, opacity: 0.72)
                signalBar(height: 0.74, opacity: 1)
            }
            .frame(height: size * 0.62, alignment: .bottom)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func signalBar(height: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill(Color.tokenGreenDark.opacity(opacity))
            .frame(width: size * 0.12, height: size * height)
    }
}

/// TokenFleet's daily-goal visualization: a segmented signal dial instead of
/// the inherited multi-lap fitness ring. The dial fills once, while the center
/// keeps showing the uncapped percentage when usage exceeds the daily goal.
struct TokenFleetGoalDial: View {
    var tokens: Int
    var goal: Int
    var size: CGFloat = 168

    private let segmentCount = 36

    private var rawProgress: Double {
        Double(max(tokens, 0)) / Double(max(goal, 1))
    }

    private var completedSegments: Int {
        min(segmentCount, max(0, Int(ceil(min(rawProgress, 1) * Double(segmentCount)))))
    }

    var body: some View {
        ZStack {
            ForEach(0..<segmentCount, id: \.self) { index in
                Capsule()
                    .fill(segmentColor(index))
                    .frame(width: max(3, size * 0.026), height: max(8, size * 0.075))
                    .offset(y: -(size / 2 - size * 0.064))
                    .rotationEffect(.degrees(Double(index) / Double(segmentCount) * 360))
            }

            Circle()
                .fill(Color.tokenSurface.opacity(0.92))
                .frame(width: size * 0.73, height: size * 0.73)
                .overlay(Circle().stroke(Color.tokenGreen.opacity(0.09), lineWidth: 1))

            VStack(spacing: max(3, size * 0.025)) {
                HStack(alignment: .bottom, spacing: max(2, size * 0.014)) {
                    signalBar(height: size * 0.075, opacity: 0.48)
                    signalBar(height: size * 0.11, opacity: 0.72)
                    signalBar(height: size * 0.15, opacity: 1)
                }

                Text(TokenStepFormat.tokens(tokens, compact: true))
                    .font(.system(size: size * 0.15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .monospacedDigit()
                    .minimumScaleFactor(0.58)
                    .lineLimit(1)
                    .frame(maxWidth: size * 0.62)

                Text(LFormat("目标 %@", TokenStepFormat.percent(rawProgress * 100)))
                    .font(.system(size: max(9, size * 0.065), weight: .bold, design: .rounded))
                    .foregroundStyle(rawProgress >= 1 ? Color.tokenGreenDark : .secondary)
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(L("今日 Token 消耗")) \(TokenStepFormat.tokens(tokens)) · "
                + "\(L("今日目标进度")) \(TokenStepFormat.percent(rawProgress * 100))"
        )
    }

    private func signalBar(height: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill(Color.tokenGreenDark.opacity(opacity))
            .frame(width: max(3, size * 0.024), height: height)
    }

    private func segmentColor(_ index: Int) -> Color {
        if index < completedSegments {
            return rawProgress >= 1 && index >= segmentCount - 3
                ? Color.orange.opacity(0.92)
                : Color.tokenGreenDark.opacity(0.92)
        }
        return Color.tokenTrack.opacity(0.78)
    }
}

struct ErrorBanner: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.quaternary))
    }
}

struct UsageRecalibrationNotice: View {
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.tokenGreen)
                .padding(.top, 1)
            Text(L("TokenFleet 已按真实增量重新校准历史 Token。数字可能变小，但历史记录没有丢失。"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.tokenInk.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("关闭"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.tokenMint.opacity(0.20), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tokenGreen.opacity(0.18))
        )
    }
}

struct PricingReestimationNotice: View {
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "dollarsign.arrow.circlepath")
                .foregroundStyle(Color.tokenGreen)
                .padding(.top, 1)
            Text(L("TokenFleet 已按新的公开价格目录重新估算历史金额。Token 消耗与原始记录没有变化，估算仍不等于账单。"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.tokenInk.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("关闭"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.tokenMint.opacity(0.20), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tokenGreen.opacity(0.18))
        )
    }
}

struct MetricPill: View {
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.bold))
                .foregroundStyle(Color.tokenInk)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.tokenSurface, in: Capsule())
        .overlay(Capsule().stroke(Color.black.opacity(0.055)))
    }
}

struct TokenCard<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(24)
            .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.black.opacity(0.07)))
            .shadow(color: Color.black.opacity(0.05), radius: 18, x: 0, y: 10)
    }
}

struct ScreenshotMenuButton: View {
    var copyTitle: String
    var saveTitle: String
    var help: String
    var copyAction: () -> Void
    var saveAction: () -> Void

    var body: some View {
        Menu {
            Button {
                copyAction()
            } label: {
                Label(copyTitle, systemImage: "doc.on.clipboard")
            }

            Button {
                saveAction()
            } label: {
                Label(saveTitle, systemImage: "square.and.arrow.down")
            }
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Color.tokenInk.opacity(0.76))
                .frame(width: 34, height: 34)
                .background(Color.tokenSurface, in: Circle())
                .overlay(Circle().stroke(Color.black.opacity(0.07)))
                .shadow(color: Color.black.opacity(0.055), radius: 9, x: 0, y: 5)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct UsageProgressRow: View {
    var name: String
    var value: String
    var percent: Double
    var color: Color = .tokenGreen

    var body: some View {
        HStack(spacing: 14) {
            Text(name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.tokenInk.opacity(0.76))
                .lineLimit(1)
                .frame(width: 132, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.tokenTrack)
                    if percent > 0 {
                        Capsule()
                            .fill(color)
                            .frame(width: max(5, proxy.size.width * min(max(percent, 0), 100) / 100))
                    }
                }
            }
            .frame(height: 8)

            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 132, alignment: .trailing)
        }
        .frame(height: 24)
    }
}

struct ActivityBarsView: View {
    var rows: [DailyUsage]
    var goal: Int
    var maxCount: Int = 30
    @State private var hoveredDayID: DailyUsage.ID?

    var visibleRows: [DailyUsage] {
        Array(rows.suffix(maxCount))
    }

    var body: some View {
        GeometryReader { proxy in
            let days = visibleRows
            let gap: CGFloat = 5
            let width = max(4, (proxy.size.width - gap * CGFloat(max(days.count - 1, 0))) / CGFloat(max(days.count, 1)))
            let maxTokens = max(goal, days.map(\.totalTokens).max() ?? 1, 1)

            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(height: 1)
                        .offset(y: -proxy.size.height * CGFloat(goal) / CGFloat(maxTokens))

                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(days) { day in
                            RoundedRectangle(cornerRadius: min(4, width / 2), style: .continuous)
                                .fill(contributionColor(tokens: day.totalTokens, goal: goal))
                                .frame(width: width, height: max(4, proxy.size.height * CGFloat(day.totalTokens) / CGFloat(maxTokens)))
                                .frame(width: width, height: proxy.size.height, alignment: .bottom)
                                .contentShape(Rectangle())
                                .onHover { isHovering in
                                    hoveredDayID = isHovering ? day.id : (hoveredDayID == day.id ? nil : hoveredDayID)
                                }
                                .help(dailyUsageHoverText(day, goal: goal))
                        }
                    }
                }

                if let hoveredDay {
                    ActivityHoverBadge(day: hoveredDay, goal: goal)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: hoveredDayID)
        }
    }

    private var hoveredDay: DailyUsage? {
        visibleRows.first { $0.id == hoveredDayID }
    }
}

struct StackedActivityBarsView: View {
    var rows: [DailyUsage]
    var goal: Int
    var maxCount: Int = 30
    @State private var hoveredDayID: DailyUsage.ID?

    var visibleRows: [DailyUsage] {
        Array(rows.suffix(maxCount))
    }

    var body: some View {
        GeometryReader { proxy in
            let days = visibleRows
            let gap: CGFloat = 5
            let width = max(4, (proxy.size.width - gap * CGFloat(max(days.count - 1, 0))) / CGFloat(max(days.count, 1)))
            let maxTokens = max(goal, days.map(\.totalTokens).max() ?? 1, 1)

            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
                    .offset(y: -proxy.size.height * CGFloat(goal) / CGFloat(maxTokens))

                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(days) { day in
                        StackedActivityBar(
                            day: day,
                            goal: goal,
                            maxTokens: maxTokens,
                            width: width,
                            height: proxy.size.height
                        )
                        .frame(width: width, height: proxy.size.height, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            hoveredDayID = isHovering ? day.id : (hoveredDayID == day.id ? nil : hoveredDayID)
                        }
                        .help(dailyUsageHoverText(day, goal: goal))
                    }
                }
            }

                if let hoveredDay {
                    ActivityHoverBadge(day: hoveredDay, goal: goal)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: hoveredDayID)
        }
    }

    private var hoveredDay: DailyUsage? {
        visibleRows.first { $0.id == hoveredDayID }
    }
}

private struct StackedActivityBar: View {
    var day: DailyUsage
    var goal: Int
    var maxTokens: Int
    var width: CGFloat
    var height: CGFloat

    private var segments: [(name: String, tokens: Int)] {
        orderedToolEntries(day.tools)
    }

    var body: some View {
        let totalHeight = max(4, height * CGFloat(day.totalTokens) / CGFloat(max(maxTokens, 1)))

        VStack(spacing: 0) {
            if day.totalTokens > 0, segments.isEmpty {
                RoundedRectangle(cornerRadius: min(4, width / 2), style: .continuous)
                    .fill(contributionColor(tokens: day.totalTokens, goal: goal))
                    .frame(width: width, height: totalHeight)
            } else {
                ForEach(Array(segments.reversed()), id: \.name) { segment in
                    RoundedRectangle(cornerRadius: min(4, width / 2), style: .continuous)
                        .fill(tokenToolColor(segment.name))
                        .frame(
                            width: width,
                            height: max(1, totalHeight * CGFloat(segment.tokens) / CGFloat(max(day.totalTokens, 1)))
                        )
                }
            }
        }
        .frame(width: width, height: totalHeight, alignment: .bottom)
        .background {
            if day.totalTokens <= 0 {
                RoundedRectangle(cornerRadius: min(4, width / 2), style: .continuous)
                    .fill(Color.tokenTrack)
                    .frame(width: width, height: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: min(4, width / 2), style: .continuous))
    }
}

private struct ActivityHoverBadge: View {
    var day: DailyUsage
    var goal: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(day.date)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Text(TokenStepFormat.tokens(day.totalTokens))
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Color.tokenInk)
                    .monospacedDigit()
                Text(lapText)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(contributionColor(tokens: day.totalTokens, goal: goal))
            }
            if !toolSummary.isEmpty {
                Text(toolSummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.tokenSurface.opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.black.opacity(0.06)))
        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
    }

    private var lapText: String {
        guard goal > 0, day.totalTokens > 0 else { return "0%" }
        let progress = Double(day.totalTokens) / Double(goal) * 100
        return TokenStepFormat.percent(progress)
    }

    private var toolSummary: String {
        orderedToolEntries(day.tools)
            .prefix(2)
            .map { "\($0.name) \(TokenStepFormat.tokens($0.tokens, compact: true))" }
            .joined(separator: " · ")
    }
}

private func dailyUsageHoverText(_ day: DailyUsage, goal: Int) -> String {
    let progress = goal > 0 ? TokenStepFormat.percent(Double(day.totalTokens) / Double(goal) * 100) : "0%"
    let tools = orderedToolEntries(day.tools)
        .map { "\($0.name) \(TokenStepFormat.tokens($0.tokens, compact: true))" }
        .joined(separator: " · ")
    if tools.isEmpty {
        return "\(day.date)\n\(TokenStepFormat.tokens(day.totalTokens)) · \(progress)"
    }
    return "\(day.date)\n\(TokenStepFormat.tokens(day.totalTokens)) · \(progress)\n\(tools)"
}

struct TokenToolLegend: View {
    var tools: [String]
    var showsGoalLine = false

    var body: some View {
        HStack(spacing: 12) {
            ForEach(uniqueTools, id: \.self) { tool in
                HStack(spacing: 5) {
                    Circle()
                        .fill(tokenToolColor(tool))
                        .frame(width: 8, height: 8)
                    Text(tool)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if showsGoalLine {
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(.secondary.opacity(0.45))
                        .frame(width: 16, height: 1)
                    Text(L("每日目标"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var uniqueTools: [String] {
        var seen = Set<String>()
        return tools.filter { tool in
            guard !seen.contains(tool) else { return false }
            seen.insert(tool)
            return true
        }
    }
}

struct ContributionWallView: View {
    var rows: [DailyUsage]
    var goal: Int
    var weeks: Int = 34

    private var rowByDate: [String: DailyUsage] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.date, $0) })
    }

    var body: some View {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let rawStart = calendar.date(byAdding: .day, value: -(weeks * 7 - 1), to: today) ?? today
        let weekday = calendar.component(.weekday, from: rawStart)
        let mondayOffset = (weekday + 5) % 7
        let start = calendar.date(byAdding: .day, value: -mondayOffset, to: rawStart) ?? rawStart

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 5) {
                ForEach(0..<weeks, id: \.self) { week in
                    VStack(spacing: 5) {
                        ForEach(0..<7, id: \.self) { dayIndex in
                            let day = calendar.date(byAdding: .day, value: week * 7 + dayIndex, to: start) ?? today
                            let key = DateFormatter.tokenStepDay.string(from: day)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(day > today ? Color.clear : contributionColor(tokens: rowByDate[key]?.totalTokens ?? 0, goal: goal))
                                .frame(width: 15, height: 15)
                                .overlay {
                                    if calendar.isDate(day, inSameDayAs: today) {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .stroke(Color.tokenGreenDark, lineWidth: 1.5)
                                    }
                                }
                        }
                    }
                }
            }

            HStack {
                MetricPill(label: L("活跃"), value: localizedDays(rows.filter { $0.totalTokens > 0 }.count))
                MetricPill(label: L("达标"), value: localizedDays(rows.filter { $0.totalTokens >= goal }.count))
                MetricPill(label: L("最高"), value: TokenStepFormat.tokens(rows.map(\.totalTokens).max() ?? 0, compact: true))
                Spacer()
                Text(L("少"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach([0, Int(Double(goal) * 0.25), Int(Double(goal) * 0.7), goal, goal * 2, goal * 3], id: \.self) { value in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(contributionColor(tokens: value, goal: goal))
                        .frame(width: 15, height: 15)
                }
                Text(L("多"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func localizedDays(_ count: Int) -> String {
        TokenStepLocalization.language == .en ? "\(count)d" : "\(count) 天"
    }
}

func contributionColor(tokens: Int, goal: Int) -> Color {
    guard tokens > 0 else { return Color.tokenTrack }
    if tokens >= max(goal, 1) {
        return TokenStepLapProgress(tokens: tokens, goal: goal).color
    }
    let progress = Double(tokens) / Double(max(goal, 1))
    switch progress {
    case 0.65...: return TokenStepThemeRuntime.palette.activity4.color
    case 0.35..<0.65: return TokenStepThemeRuntime.palette.activity3.color
    case 0.12..<0.35: return TokenStepThemeRuntime.palette.activity2.color
    default: return TokenStepThemeRuntime.palette.activity1.color
    }
}

func localizedStreakDays(days: Int, isLowerBound: Bool) -> String {
    let prefix = isLowerBound ? "≥" : ""
    return TokenStepLocalization.language == .en
        ? "\(prefix)\(days)d"
        : "\(prefix)\(days) 天"
}

func localizedStreakDescription(days: Int, isLowerBound: Bool) -> String {
    LFormat(isLowerBound ? "至少连续活跃 %d 天" : "连续活跃 %d 天", days)
}

func tokenToolColor(_ tool: String) -> Color {
    switch tool {
    case "Codex":
        return .tokenGreen
    case "Claude Code":
        return Color(red: 0.88, green: 0.42, blue: 0.24)
    case "Hermes", "Hermes Agent":
        return Color(red: 0.50, green: 0.28, blue: 0.92)
    case "ZCode":
        return Color(red: 0.20, green: 0.52, blue: 0.92)
    case "Codex via CC Switch", "Claude Code via CC Switch", "Gemini via CC Switch":
        return Color(red: 0.10, green: 0.64, blue: 0.72)
    default:
        return Color.tokenInk.opacity(0.44)
    }
}

func orderedToolEntries(_ tools: [String: Int]) -> [(name: String, tokens: Int)] {
    let preferred = ["Codex", "Claude Code", "ZCode", "Hermes", "Hermes Agent", "Codex via CC Switch", "Claude Code via CC Switch"]
    var entries: [(name: String, tokens: Int)] = preferred.compactMap { name in
        guard let value = tools[name], value > 0 else { return nil }
        return (name, value)
    }
    entries.append(contentsOf: tools
        .filter { key, value in !preferred.contains(key) && value > 0 }
        .sorted { $0.value > $1.value }
        .map { ($0.key, $0.value) })
    return entries
}

func uniqueToolNames(in rows: [DailyUsage], fallback: [String] = ["Codex", "Claude Code"], limit: Int = 4) -> [String] {
    var seen = Set<String>()
    var names: [String] = []
    for day in rows {
        for entry in orderedToolEntries(day.tools) where !seen.contains(entry.name) {
            seen.insert(entry.name)
            names.append(entry.name)
            if names.count >= limit {
                return names
            }
        }
    }
    return names.isEmpty ? fallback : names
}
