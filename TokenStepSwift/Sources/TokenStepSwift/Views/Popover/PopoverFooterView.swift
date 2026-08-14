import AppKit
import SwiftUI

struct PopoverFooterView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(L("本地统计"), systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(appState.settings.refreshIntervalSeconds == 0 ? L("手动刷新") : LFormat("刷新 %@", TokenStepFormat.intervalLabel(appState.settings.refreshIntervalSeconds)))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Button {
                if appState.isCommunitySyncEnrollmentCompatible {
                    MainWindowPresenter.shared.show(appState: appState, section: .community)
                } else {
                    SettingsWindowPresenter.shared.show(appState: appState)
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "person.3.sequence.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(communityButtonTitle)
                        if let detail = communityRankDetail {
                            Text(detail)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.tokenInk.opacity(0.56))
                        }
                    }
                    Spacer()
                    Image(systemName: appState.isCommunitySyncEnrollmentCompatible ? "chevron.right" : "link")
                }
                .font(.callout.weight(.heavy))
                .foregroundStyle(Color.tokenGreenDark)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.tokenMint.opacity(0.24), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.tokenGreen.opacity(0.18))
                )
            }
            .buttonStyle(.plain)
            .help(communityButtonTitle)
            .disabled(isScreenshotRendering)

            HStack(spacing: 10) {
                Button {
                    MainWindowPresenter.shared.show(appState: appState)
                } label: {
                    Label(L("打开仪表盘"), systemImage: "arrow.up.right")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.tokenGreen, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .shadow(color: Color.tokenGreenDark.opacity(0.14), radius: 10, x: 0, y: 6)
                }
                .buttonStyle(.plain)
                .help(L("打开仪表盘"))

                PopoverActionButton(title: L("刷新"), symbol: "arrow.clockwise") {
                    appState.refresh()
                }
                .disabled(appState.isRefreshing)

                PopoverActionButton(title: L("设置"), symbol: "gearshape") {
                    SettingsWindowPresenter.shared.show(appState: appState)
                }

                PopoverActionButton(title: L("退出"), symbol: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private var communityButtonTitle: String {
        return appState.isCommunitySyncEnrollmentCompatible ? L("社群排行") : L("连接社群")
    }

    private var communityRankDetail: String? {
        guard appState.isCommunitySyncEnrollmentCompatible else {
            return L("连接后显示本人真实名次")
        }
        guard let context = appState.communityRank else {
            return appState.isRefreshingCommunityRank ? L("读取中") : L("等待读取")
        }
        guard context.publicProfileEnabled else {
            return L("未参与公开排名")
        }
        guard let rank = context.rank else {
            return L("今日暂无名次")
        }
        if let percentage = context.exceededPercentage {
            return LFormat(
                "今日第 %d / %d 名 · 超过 %d%%",
                rank,
                context.totalEntries,
                percentage
            )
        }
        return LFormat("今日第 %d / %d 名", rank, context.totalEntries)
    }
}

private struct PopoverActionButton: View {
    var title: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .heavy))
                    .frame(height: 20)
                Text(title)
                    .font(.caption2.weight(.heavy))
            }
            .foregroundStyle(Color.tokenInk.opacity(0.78))
            .frame(width: 54, height: 54)
            .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color.black.opacity(0.055)))
            .shadow(color: Color.black.opacity(0.045), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
