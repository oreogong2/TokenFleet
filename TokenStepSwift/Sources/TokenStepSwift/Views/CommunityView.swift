import Foundation
import SwiftUI

struct CommunityView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering

    var body: some View {
        VStack(spacing: 22) {
            hero
            statusGrid
            privacyCard
        }
    }

    private var hero: some View {
        TokenCard {
            HStack(alignment: .center, spacing: 28) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.tokenMint.opacity(0.34))
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(Color.tokenGreenDark)
                }
                .frame(width: 112, height: 112)

                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Token 消耗排行榜"))
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.tokenInk)
                    Text(L("和一群人一起，看见进步的速度。"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Label(connectionLabel, systemImage: connectionSymbol)
                        .font(.callout.weight(.heavy))
                        .foregroundStyle(connectionTint)
                }

                Spacer(minLength: 20)

                VStack(spacing: 10) {
                    Button {
                        appState.openCommunityLeaderboard(isScreenshotRendering: isScreenshotRendering)
                    } label: {
                        Label(L("打开排行榜"), systemImage: "arrow.up.right")
                            .font(.headline.weight(.heavy))
                            .frame(width: 142, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tokenGreenDark)
                    .disabled(appState.communityLeaderboardURL(isScreenshotRendering: isScreenshotRendering) == nil)

                    Button {
                        SettingsWindowPresenter.shared.show(appState: appState)
                    } label: {
                        Text(appState.isCommunitySyncEnrollmentCompatible ? L("管理同步") : L("连接社群榜"))
                            .font(.callout.weight(.bold))
                            .frame(width: 142, height: 36)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isScreenshotRendering)
                }
            }
        }
    }

    private var statusGrid: some View {
        HStack(spacing: 18) {
            CommunityMetricCard(
                label: L("今日用量"),
                value: TokenStepFormat.tokens(appState.today.totalTokens),
                detail: L("进入榜单后按公开口径排序")
            )
            CommunityMetricCard(
                label: L("今日排名"),
                value: appState.isCommunitySyncEnrollmentCompatible ? L("打开榜单查看") : L("尚未连接"),
                detail: L("不在本地猜测或缓存名次")
            )
            CommunityMetricCard(
                label: L("自动同步"),
                value: syncStateLabel,
                detail: lastSyncLabel
            )
        }
    }

    private var privacyCard: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("公开与同步边界"))
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Color.tokenInk)
                HStack(alignment: .top, spacing: 24) {
                    CommunityBoundaryItem(symbol: "chart.bar.fill", text: L("公开昵称、排名、聚合 Token、工具、模型与日趋势"))
                    CommunityBoundaryItem(symbol: "lock.shield.fill", text: L("不上传提示词、回复、代码、文件路径或会话正文"))
                    CommunityBoundaryItem(symbol: "key.fill", text: L("设备凭据只保存在 macOS 钥匙串"))
                }
            }
        }
    }

    private var connectionLabel: String {
        appState.isCommunitySyncEnrollmentCompatible ? L("已连接社群榜") : L("尚未连接社群榜")
    }

    private var connectionSymbol: String {
        appState.isCommunitySyncEnrollmentCompatible ? "checkmark.circle.fill" : "circle.dashed"
    }

    private var connectionTint: Color {
        appState.isCommunitySyncEnrollmentCompatible ? .tokenGreenDark : .secondary
    }

    private var syncStateLabel: String {
        if appState.isTeamSyncing { return L("同步中") }
        guard appState.isCommunitySyncEnrollmentCompatible else { return L("未连接") }
        return appState.settings.teamSyncEnabled ? L("已开启") : L("已暂停")
    }

    private var lastSyncLabel: String {
        guard let date = appState.teamSyncState?.lastSyncAt else { return L("尚无同步记录") }
        let formatter = DateFormatter()
        formatter.locale = TokenStepLocalization.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return LFormat("上次同步：%@", formatter.string(from: date))
    }
}

private struct CommunityMetricCard: View {
    var label: String
    var value: String
    var detail: String

    var body: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .minimumScaleFactor(0.62)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CommunityBoundaryItem: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.tokenGreenDark)
            Text(text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.tokenInk.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
