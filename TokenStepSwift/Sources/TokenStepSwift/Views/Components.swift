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
            TokenFleetMenuBarProgressRing(
                progress: lap.currentLapProgress,
                refreshing: refreshing
            )

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

/// A compact, template-color goal ring for macOS's native menu bar.
/// Keeping it to 16 points makes it readable without consuming status-item space.
private struct TokenFleetMenuBarProgressRing: View {
    var progress: Double
    var refreshing: Bool

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.26), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(
                    Color.primary.opacity(refreshing ? 0.46 : 0.96),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
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
            Circle()
                .fill(Color.tokenSurface)
                .overlay(
                    Circle()
                        .stroke(Color.tokenGreen.opacity(0.18), lineWidth: max(1, size * 0.018))
                )

            Circle()
                .trim(from: 0.06, to: 0.78)
                .stroke(
                    Color.tokenGreenDark,
                    style: StrokeStyle(lineWidth: max(2, size * 0.13), lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One clean ring keeps the confirmed "one hundred million per lap" memory
/// without restoring the old multi-ring fitness skin.
struct TokenFleetGoalDial: View {
    var tokens: Int
    var goal: Int
    var size: CGFloat = 168

    private var lap: TokenStepLapProgress {
        TokenStepLapProgress(tokens: tokens, goal: goal)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.tokenTrack.opacity(0.9), lineWidth: size * 0.105)
            Circle()
                .trim(from: 0, to: min(max(lap.currentLapProgress, 0), 1))
                .stroke(
                    lap.color,
                    style: StrokeStyle(lineWidth: size * 0.105, lineCap: .butt)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: max(4, size * 0.028)) {
                Text(TokenStepFormat.tokens(tokens, compact: true))
                    .font(.system(size: size * 0.17, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .monospacedDigit()
                    .minimumScaleFactor(0.58)
                    .lineLimit(1)
                    .frame(maxWidth: size * 0.62)

                Text(lap.lapTitle)
                    .font(.system(size: max(10, size * 0.07), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tokenGreenDark)
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(L("今日 Token 消耗")) \(TokenStepFormat.tokens(tokens)) · "
                + lap.lapStatusText
        )
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
            Text(L("TokenFleet 已在本次用量刷新中采用新的公开价格目录。价格目录本身只影响金额估算；Token 仍来自本地用量记录，估算不等于账单。"))
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
            .padding(16)
            .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.black.opacity(0.07)))
            .shadow(color: Color.black.opacity(0.035), radius: 10, x: 0, y: 5)
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
    var cellSize: CGFloat = 15
    var cellSpacing: CGFloat = 5
    var showsSummary = true

    var body: some View {
        let columnCount = max(1, weeks)
        let visibleRows = UsageCalendarWindow.contributionRows(from: rows, weeks: columnCount)
        let todayKey = DateFormatter.tokenStepDay.string(from: Date())

        VStack(alignment: .leading, spacing: showsSummary ? 16 : 0) {
            HStack(alignment: .top, spacing: cellSpacing) {
                ForEach(0..<columnCount, id: \.self) { week in
                    VStack(spacing: cellSpacing) {
                        ForEach(0..<7, id: \.self) { dayIndex in
                            let slot = week * 7 + dayIndex
                            if visibleRows.indices.contains(slot) {
                                let row = visibleRows[slot]
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(contributionColor(tokens: row.totalTokens, goal: goal))
                                    .frame(width: cellSize, height: cellSize)
                                    .overlay {
                                        if row.date == todayKey {
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .stroke(Color.tokenGreenDark, lineWidth: 1.5)
                                        }
                                    }
                            } else {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.clear)
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }

            if showsSummary {
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
                            .frame(width: cellSize, height: cellSize)
                    }
                    Text(L("多"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
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
    case "WorkBuddy":
        return Color(red: 0.94, green: 0.63, blue: 0.16)
    case "CodeBuddy":
        return Color(red: 0.18, green: 0.56, blue: 0.94)
    case "Qoder":
        return Color(red: 0.48, green: 0.35, blue: 0.90)
    case "Kimi":
        return Color(red: 0.18, green: 0.68, blue: 0.58)
    case "OpenCode":
        return Color(red: 0.16, green: 0.61, blue: 0.78)
    case "Grok":
        return Color(red: 0.14, green: 0.16, blue: 0.20)
    case "Qwen Code":
        return Color(red: 0.43, green: 0.32, blue: 0.88)
    case "Cline":
        return Color(red: 0.93, green: 0.32, blue: 0.38)
    case "Copilot CLI", "Copilot Chat":
        return Color(red: 0.20, green: 0.48, blue: 0.78)
    case "Antigravity":
        return Color(red: 0.16, green: 0.66, blue: 0.54)
    case "Droid":
        return Color(red: 0.92, green: 0.40, blue: 0.28)
    case "dsh":
        return Color(red: 0.12, green: 0.57, blue: 0.70)
    case "Pi":
        return Color(red: 0.88, green: 0.23, blue: 0.56)
    case "OpenClaw":
        return Color(red: 0.95, green: 0.34, blue: 0.20)
    case "Codex via CC Switch", "Claude Code via CC Switch", "Gemini via CC Switch":
        return Color(red: 0.10, green: 0.64, blue: 0.72)
    default:
        return Color.tokenInk.opacity(0.44)
    }
}

func orderedToolEntries(_ tools: [String: Int]) -> [(name: String, tokens: Int)] {
    let preferred = ["Codex", "Claude Code", "Cursor", "Copilot Chat", "Copilot CLI", "Cline", "OpenCode", "OpenClaw", "CodeBuddy", "Qoder", "Antigravity", "Droid", "dsh", "Pi", "Grok", "Qwen Code", "WorkBuddy", "Kimi", "ZCode", "Hermes", "Hermes Agent", "Codex via CC Switch", "Claude Code via CC Switch"]
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
