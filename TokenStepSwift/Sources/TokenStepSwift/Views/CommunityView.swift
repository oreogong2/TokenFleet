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
        .onAppear {
            if !isScreenshotRendering {
                appState.refreshCommunityRank()
            }
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
                    Text(L("TokenFleet 社群排行"))
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.tokenInk)
                    Text(L("和一群人一起，看见进步的速度。"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Label(connectionLabel, systemImage: connectionSymbol)
                        .font(.callout.weight(.heavy))
                        .foregroundStyle(connectionTint)
                    if let context = connectedRankContext {
                        Label(context, systemImage: "chart.line.uptrend.xyaxis")
                            .font(.callout.weight(.heavy))
                            .foregroundStyle(Color.tokenGreenDark)
                    }
                }

                Spacer(minLength: 20)

                VStack(spacing: 10) {
                    Button {
                        appState.openCommunityLeaderboard(isScreenshotRendering: isScreenshotRendering)
                    } label: {
                        Label(L("打开完整榜单"), systemImage: "arrow.up.right")
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
                value: rankValue,
                detail: rankDetail
            )
            CommunityMetricCard(
                label: L("自动同步"),
                value: syncStateLabel,
                detail: "\(LFormat("连续活跃 %d 天", appState.activeStreak.days)) · \(lastSyncLabel)"
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

    private var connectedRankContext: String? {
        guard appState.isCommunitySyncEnrollmentCompatible,
              let rank = appState.communityRank?.rank,
              let total = appState.communityRank?.totalEntries
        else {
            return nil
        }
        if let percentage = appState.communityRank?.exceededPercentage {
            return LFormat("今日第 %d / %d 名 · 超过 %d%%", rank, total, percentage)
        }
        return LFormat("今日第 %d / %d 名", rank, total)
    }

    private var rankValue: String {
        guard appState.isCommunitySyncEnrollmentCompatible else {
            return L("尚未连接")
        }
        if let context = appState.communityRank {
            guard context.publicProfileEnabled else {
                return L("未参与公开排名")
            }
            if let rank = context.rank {
                return LFormat("第 %d / %d 名", rank, context.totalEntries)
            }
            return L("今日暂无名次")
        }
        if appState.isRefreshingCommunityRank { return L("读取中") }
        if appState.communityRankError != nil { return L("暂时不可用") }
        return L("等待读取")
    }

    private var rankDetail: String {
        guard appState.isCommunitySyncEnrollmentCompatible else {
            return L("连接后显示本人真实名次")
        }
        if let context = appState.communityRank {
            guard context.publicProfileEnabled else {
                return L("公开资料关闭，不参与社群排名")
            }
            if let percentage = context.exceededPercentage {
                return LFormat("超过 %d%% 的成员", percentage)
            }
            return L("今天同步用量后出现名次")
        }
        return appState.communityRankError ?? L("从社群榜安全读取")
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
