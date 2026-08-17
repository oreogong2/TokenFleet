import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case today
    case history
    case community

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: L("今日消耗")
        case .history: L("历史活动")
        case .community: L("社群排行")
        }
    }

    var sidebarTitle: String {
        switch self {
        case .today: L("今日消耗")
        case .history: L("历史活动")
        case .community: L("社群排行")
        }
    }

    var subtitle: String {
        switch self {
        case .today: L("今天的 Token 使用节奏")
        case .history: L("长期节奏和所有历史记录")
        case .community: L("和一群人一起，看见进步的速度")
        }
    }

    var systemImage: String {
        switch self {
        case .today: "waveform.path.ecg.rectangle.fill"
        case .history: "square.grid.3x3.fill"
        case .community: "person.3.fill"
        }
    }

    var screenshotFilePrefix: String {
        switch self {
        case .today: "today"
        case .history: "history"
        case .community: "community"
        }
    }

    var saveScreenshotTitle: String {
        L("保存当前页 PNG")
    }
}

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering
    @ObservedObject var navigation: MainWindowNavigation
    @StateObject private var historyPresentation = HistoryPresentationState()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .id(appState.appearanceID)
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(width: 1)
            content
                .id(appState.appearanceID)
        }
        .background(TokenStepBackdrop().id(appState.appearanceID))
        .onAppear {
            if !isScreenshotRendering {
                appState.refreshForForeground()
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TokenFleetSignalMark(size: 30)
                Text("TokenFleet")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
            }
            .padding(.top, 22)
            .padding(.horizontal, 18)
            .padding(.bottom, 20)

            VStack(spacing: 5) {
                ForEach(AppSection.allCases) { section in
                    SidebarNavButton(
                        section: section,
                        selected: navigation.section == section
                    ) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            navigation.select(section)
                        }
                    }
                }
                SidebarSettingsButton {
                    SettingsWindowPresenter.shared.show(appState: appState)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 24)
        }
        .frame(width: 190)
        .background(Color.tokenSurface.opacity(0.94))
    }

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 18) {
                    pageHeader
                    if let error = appState.lastError {
                        ErrorBanner(message: error) {
                            appState.clearError()
                        }
                    }
                    if appState.showsUsageRecalibrationNotice {
                        UsageRecalibrationNotice {
                            appState.dismissUsageRecalibrationNotice()
                        }
                    } else if appState.showsPricingReestimationNotice {
                        PricingReestimationNotice {
                            appState.dismissPricingReestimationNotice()
                        }
                    }
                    detailView
                }
                .frame(maxWidth: 920, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 25)
            .padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(navigation.section.title)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                Text(navigation.section.subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 9) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(appState.isRefreshing ? Color.secondary.opacity(0.7) : Color.tokenGreen)
                            .frame(width: 7, height: 7)
                        Text(appState.isRefreshing ? L("同步中") : L("已同步"))
                            .font(.callout.weight(.bold))
                    }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    .background(Color.tokenSurface, in: Capsule())
                    .overlay(Capsule().stroke(Color.black.opacity(0.06)))

                    ScreenshotMenuButton(
                        copyTitle: L("复制当前页截图"),
                        saveTitle: navigation.section.saveScreenshotTitle,
                        help: L("截取当前页"),
                        copyAction: copyCurrentPageScreenshot,
                        saveAction: saveCurrentPageScreenshot
                    )
                }

                Text("\(L("更新")) \(TokenStepFormat.generatedTime(appState.snapshot.generatedAt))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var currentPageScreenshot: some View {
        DashboardScreenshotView(
            section: navigation.section,
            historyPresentation: historyPresentation
        )
            .environmentObject(appState)
            .environment(\.isScreenshotRendering, true)
    }

    private func copyCurrentPageScreenshot() {
        do {
            try ScreenshotExporter.copy(currentPageScreenshot)
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func saveCurrentPageScreenshot() {
        do {
            try ScreenshotExporter.save(
                currentPageScreenshot,
                suggestedFileName: ScreenshotExporter.suggestedFileName(prefix: navigation.section.screenshotFilePrefix)
            )
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigation.section {
        case .today:
            TodayView(toolExpansionRequest: navigation.todayToolExpansionRequest)
        case .history:
            HistoryView(
                presentation: historyPresentation
            )
        case .community:
            CommunityView()
        }
    }
}

private struct SidebarNavButton: View {
    var section: AppSection
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(section.sidebarTitle)
                .font(.callout.weight(.bold))
                .foregroundStyle(selected ? Color.tokenInk : Color.tokenInk.opacity(0.62))
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 11)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .background(
                    selected ? Color.tokenSurface : Color.clear,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.black.opacity(0.055))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct SidebarSettingsButton: View {
    @State private var isHovering = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(L("设置"))
                .font(.callout.weight(.bold))
                .foregroundStyle(Color.tokenInk.opacity(isHovering ? 0.92 : 0.68))
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 11)
                .background(
                    Color.tokenGreen.opacity(isHovering ? 0.12 : 0.055),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .animation(.easeInOut(duration: 0.16), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(L("设置"))
    }
}

private struct SidebarPrivacyStatus: View {
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.tokenGreenDark)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(L("本地统计"))
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Color.tokenGreenDark)
                Text(L("不上传代码或对话"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.tokenGreen.opacity(0.055))
        )
    }
}
