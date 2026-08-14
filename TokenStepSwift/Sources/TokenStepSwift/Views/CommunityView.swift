import Foundation
import SwiftUI

struct CommunityView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering

    var body: some View {
        VStack(spacing: 22) {
            hero
            leaderboardCard
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
            HStack(alignment: .center, spacing: 26) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(L("TokenFleet 社群排行"))
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.tokenInk)
                    Text(L("和一群人一起，看见进步的速度。"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Label(connectionLabel, systemImage: connectionSymbol)
                        .font(.callout.weight(.heavy))
                        .foregroundStyle(connectionTint)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(rankNumber)
                        .font(.system(size: 58, weight: .black, design: .rounded))
                        .foregroundStyle(Color.tokenGreenDark)
                        .monospacedDigit()
                    Text(rankTotal)
                        .font(.callout.weight(.heavy))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 160, alignment: .trailing)

                VStack(spacing: 9) {
                    if isScreenshotRendering {
                        Label(L("分享排名"), systemImage: "square.and.arrow.up")
                            .font(.headline.weight(.heavy))
                            .frame(width: 144, height: 42)
                            .foregroundStyle(.white)
                            .background(
                                Color.tokenGreenDark,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                    } else {
                        Menu {
                            Button(L("复制排名海报"), action: copyRankingPoster)
                            Button(L("保存排名海报 PNG"), action: saveRankingPoster)
                        } label: {
                            Label(L("分享排名"), systemImage: "square.and.arrow.up")
                                .font(.headline.weight(.heavy))
                                .frame(width: 144, height: 42)
                        }
                        .menuStyle(.borderlessButton)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.tokenGreenDark)
                        .disabled(!canShareRanking)
                    }

                    Button {
                        appState.openCommunityLeaderboard(isScreenshotRendering: isScreenshotRendering)
                    } label: {
                        Label(L("打开完整榜单"), systemImage: "arrow.up.right")
                            .font(.callout.weight(.bold))
                            .frame(width: 144, height: 34)
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.communityLeaderboardURL(isScreenshotRendering: isScreenshotRendering) == nil)

                    Button {
                        SettingsWindowPresenter.shared.show(appState: appState)
                    } label: {
                        Text(appState.isCommunitySyncEnrollmentCompatible ? L("管理同步") : L("连接社群榜"))
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.tokenGreenDark)
                    .disabled(isScreenshotRendering)
                }
            }
        }
    }

    private var leaderboardCard: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("今日 Top 10"))
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(L("主力工具优先于主力模型；费用是公开 API 标准价等价估算"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(leaderboardStatus)
                        .font(.callout.weight(.heavy))
                        .foregroundStyle(Color.tokenGreenDark)
                }

                CommunityLeaderboardHeader()

                if leaderboardEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(leaderboardEmptyTitle)
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(leaderboardEmptyDetail)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
                    .padding(.horizontal, 16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(leaderboardEntries) { entry in
                            CommunityLeaderboardRow(
                                entry: entry,
                                isCurrentUser: entry.publicID == appState.communityRank?.publicID
                            )
                        }
                    }
                }
            }
        }
    }

    private var privacyCard: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("公开与同步边界"))
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Color.tokenInk)
                HStack(alignment: .top, spacing: 24) {
                    CommunityBoundaryItem(symbol: "chart.bar.fill", text: L("公开昵称、排名、聚合 Token、工具、模型与日趋势"))
                    CommunityBoundaryItem(symbol: "lock.shield.fill", text: L("不上传提示词、回复、代码、文件路径或会话正文"))
                    CommunityBoundaryItem(symbol: "externaldrive.badge.checkmark", text: L("同一成员可连接多台设备，用量按成员聚合"))
                }
            }
        }
    }

    private var leaderboardEntries: [TeamSyncPublicLeaderboardEntry] {
        appState.communityLeaderboard?.entries ?? []
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

    private var rankNumber: String {
        guard appState.isCommunitySyncEnrollmentCompatible else { return "--" }
        guard appState.communityRank?.publicProfileEnabled == true else { return "--" }
        guard let rank = appState.communityRank?.rank else { return "--" }
        return "#\(rank)"
    }

    private var rankTotal: String {
        guard let total = appState.communityRank?.totalEntries else {
            return appState.isRefreshingCommunityRank ? L("排名读取中") : L("今日排名")
        }
        return LFormat("全榜 %d 人", total)
    }

    private var leaderboardStatus: String {
        if appState.isRefreshingCommunityLeaderboard { return L("榜单读取中") }
        if let board = appState.communityLeaderboard {
            return LFormat("全榜 %d 人 · 显示前 %d", board.totalEntries, board.entries.count)
        }
        return appState.communityLeaderboardError ?? L("等待读取")
    }

    private var leaderboardEmptyTitle: String {
        if !appState.isCommunitySyncEnrollmentCompatible { return L("连接社群后查看 App 内榜单") }
        if appState.isRefreshingCommunityLeaderboard { return L("正在读取今日榜单") }
        return L("今日还没有公开排名")
    }

    private var leaderboardEmptyDetail: String {
        if !appState.isCommunitySyncEnrollmentCompatible {
            return L("连接后只读取公开聚合榜单，不会把设备凭据带进公开请求。")
        }
        return appState.communityLeaderboardError ?? L("成员同步今天的可验证用量后会显示在这里。")
    }

    private var canShareRanking: Bool {
        appState.communityRank?.rank != nil && appState.communityLeaderboard != nil
    }

    @ViewBuilder
    private var rankingPoster: some View {
        if let rank = appState.communityRank,
           let leaderboard = appState.communityLeaderboard {
            CommunityRankingShareView(
                rank: rank,
                leaderboard: leaderboard,
                appearanceID: appState.appearanceID,
                leaderboardURL: appState.communityServerOrigin.flatMap {
                    try? TeamSyncProtocol.endpointURL(
                        serverURL: $0,
                        path: TeamSyncProtocolConfiguration.publicLeaderboardPath
                    )
                }
            )
            .environment(\.isScreenshotRendering, true)
        }
    }

    private func copyRankingPoster() {
        guard canShareRanking else { return }
        do {
            try ScreenshotExporter.copy(rankingPoster)
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func saveRankingPoster() {
        guard canShareRanking else { return }
        do {
            try ScreenshotExporter.save(
                rankingPoster,
                suggestedFileName: ScreenshotExporter.suggestedFileName(prefix: "community-ranking")
            )
        } catch {
            appState.lastError = error.localizedDescription
        }
    }
}

private struct CommunityLeaderboardHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text(L("排名")).frame(width: 46, alignment: .leading)
            Text(L("昵称")).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            Text(L("主力工具")).frame(width: 126, alignment: .leading)
            Text(L("主力模型")).frame(width: 152, alignment: .leading)
            Text(L("Token")).frame(width: 116, alignment: .trailing)
            Text(L("API 估算")).frame(width: 116, alignment: .trailing)
        }
        .font(.caption.weight(.heavy))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.tokenTrack.opacity(0.58), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CommunityLeaderboardRow: View {
    var entry: TeamSyncPublicLeaderboardEntry
    var isCurrentUser: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.rank.map { "#\($0)" } ?? "--")
                .font(.headline.weight(.black))
                .foregroundStyle(entry.rank.map(rankColor) ?? .secondary)
                .frame(width: 46, alignment: .leading)
            HStack(spacing: 7) {
                Text(entry.nickname).font(.callout.weight(.heavy)).lineLimit(1)
                if isCurrentUser {
                    Text(L("我"))
                        .font(.caption2.weight(.black))
                        .foregroundStyle(Color.tokenSurface)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.tokenGreenDark, in: Capsule())
                }
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            CommunityDimensionValue(name: entry.primaryTool, count: entry.toolCount)
                .frame(width: 126, alignment: .leading)
            CommunityDimensionValue(name: entry.primaryModel, count: entry.modelCount)
                .frame(width: 152, alignment: .leading)
            Text(TokenStepFormat.tokens(entry.tokenValue, compact: true))
                .font(.callout.weight(.heavy))
                .monospacedDigit()
                .frame(width: 116, alignment: .trailing)
            Text(costText)
                .font(.callout.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 116, alignment: .trailing)
        }
        .foregroundStyle(Color.tokenInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(isCurrentUser ? Color.tokenMint.opacity(0.24) : Color.clear)
        .background(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.05)).frame(height: 1)
        }
    }

    private var costText: String {
        guard let cost = entry.totals.estimatedCost else { return L("未完整计价") }
        return TokenStepFormat.money(cost)
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return .orange
        case 2: return .gray
        case 3: return .brown
        default: return .tokenInk
        }
    }
}

private struct CommunityDimensionValue: View {
    var name: String?
    var count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name ?? "--").font(.callout.weight(.bold)).lineLimit(1)
            if count > 1 {
                Text(LFormat("另有 %d 项", count - 1)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
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
