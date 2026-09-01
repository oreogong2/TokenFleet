import SwiftUI

struct DashboardScreenshotView: View {
    @EnvironmentObject private var appState: AppState
    var section: AppSection
    var historySection: HistorySection = .overview
    var historyRange: HistoryRange = .all
    var historyExpandedDates: Set<String> = []
    var historyPresentation: HistoryPresentationState? = nil

    private var captureHeight: CGFloat {
        section == .today ? 1_080 : 760
    }

    private var windowBodyHeight: CGFloat {
        captureHeight - 41
    }

    private var detailViewportHeight: CGFloat {
        windowBodyHeight - 44
    }

    var body: some View {
        VStack(spacing: 0) {
            captureTitleBar
            HStack(spacing: 0) {
                captureSidebar
                Rectangle()
                    .fill(Color.black.opacity(0.06))
                    .frame(width: 1)
                VStack(alignment: .leading, spacing: 18) {
                    captureHeader
                    VStack(alignment: .leading, spacing: 0) {
                        detailView
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                }
                .frame(width: 939, height: detailViewportHeight, alignment: .topLeading)
                .clipped()
                .padding(.horizontal, 25)
                .padding(.vertical, 22)
            }
            .frame(width: 1_180, height: windowBodyHeight)
        }
        .background(TokenStepBackdrop())
        .frame(width: 1_180, height: captureHeight)
        .id(appState.appearanceID)
    }

    private var captureTitleBar: some View {
        TokenFleetScreenshotTitleBar(
            title: "TokenFleet \(UpdateService.currentVersion) · \(section.title)"
        )
    }

    private var captureSidebar: some View {
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
                ForEach(AppSection.allCases) { item in
                    captureNavigationItem(item.title, selected: item == section)
                }
                captureNavigationItem(L("设置"), selected: false)
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 24)
        }
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(Color.tokenSurface.opacity(0.94))
    }

    private func captureNavigationItem(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.callout.weight(.bold))
            .foregroundStyle(selected ? Color.tokenInk : Color.tokenInk.opacity(0.62))
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 11)
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

    private var captureHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(section.title)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                Text(section.subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 9) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.tokenGreen)
                        .frame(width: 7, height: 7)
                    Text(L("已同步"))
                        .font(.callout.weight(.bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.tokenSurface, in: Capsule())
                .overlay(Capsule().stroke(Color.black.opacity(0.06)))
                Text("\(L("更新")) \(TokenStepFormat.generatedTime(appState.snapshot.generatedAt))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch section {
        case .today:
            TodayView()
        case .history:
            HistoryView(
                initialSection: historyPresentation?.section ?? historySection,
                initialRange: historyPresentation?.range ?? historyRange,
                initialExpandedDates: historyPresentation?.expandedDates ?? historyExpandedDates,
                presentation: historyPresentation
            )
        case .community:
            CommunityView()
        }
    }
}

struct SettingsWindowScreenshotView: View {
    @EnvironmentObject private var appState: AppState
    var section: TokenFleetSettingsSection

    var body: some View {
        VStack(spacing: 0) {
            TokenFleetScreenshotTitleBar(
                title: LFormat("TokenFleet %@ · 设置", UpdateService.currentVersion)
            )
            SettingsView(captureMode: true, initialSection: section)
        }
        .frame(width: 980, height: 760)
        .id(appState.appearanceID)
    }
}

private struct TokenFleetScreenshotTitleBar: View {
    var title: String

    var body: some View {
        ZStack {
            Rectangle().fill(Color.tokenTrack.opacity(0.66))
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25))
                Spacer()
            }
            .frame(height: 10)
            .padding(.horizontal, 14)
        }
        .frame(height: 41)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
        }
    }
}
