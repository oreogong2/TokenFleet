import SwiftUI

struct PopoverFooterView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering

    var body: some View {
        HStack(spacing: 7) {
            PopoverFooterButton(title: L("今日")) {
                MainWindowPresenter.shared.show(appState: appState, section: .today)
            }

            PopoverFooterButton(title: L("社群榜单"), prominent: true) {
                if appState.isCommunitySyncEnrollmentCompatible {
                    MainWindowPresenter.shared.show(appState: appState, section: .community)
                } else {
                    SettingsWindowPresenter.shared.show(appState: appState)
                }
            }

            PopoverFooterButton(title: appState.isRefreshing ? L("同步中") : L("刷新")) {
                appState.refresh()
            }
            .disabled(appState.isRefreshing)

            PopoverFooterButton(title: L("设置")) {
                SettingsWindowPresenter.shared.show(appState: appState)
            }
        }
        // Exported review images should keep the same colors as the real app,
        // while remaining inert if a hosted screenshot view is ever displayed.
        .allowsHitTesting(!isScreenshotRendering)
        .padding(11)
        .background(Color.tokenCanvas.opacity(0.62))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
        }
    }
}

private struct PopoverFooterButton: View {
    var title: String
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(prominent ? Color.white : Color.tokenInk.opacity(0.76))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    prominent ? Color.tokenGreen : Color.tokenSurface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(prominent ? Color.tokenGreen : Color.black.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
