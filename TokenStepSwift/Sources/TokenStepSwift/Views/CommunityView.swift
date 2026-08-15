import Foundation
import SwiftUI

struct CommunityView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isScreenshotRendering) private var isScreenshotRendering

    var body: some View {
        VStack(spacing: 10) {
            hero
            leaderboardCard
        }
        .onAppear {
            if !isScreenshotRendering {
                appState.refreshCommunityRank()
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("COMMUNITY · TODAY")
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(Color.tokenGreen.opacity(0.78))
            Text(rankHeadline)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white)
                .monospacedDigit()
            Text(rankDetail)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.62))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tokenInk, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var leaderboardCard: some View {
        VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("今日 Top 10"))
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(L("主力工具优先于主力模型；费用是公开 API 标准价等价估算"))
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(leaderboardStatus)
                        .font(.system(size: 8, weight: .heavy))
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
                leaderboardFooter
        }
        .padding(14)
        .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.black.opacity(0.08)))
    }

    private var leaderboardFooter: some View {
        HStack(spacing: 12) {
            Text(L("只公开昵称、排名、工具/模型和聚合用量；不上传提示词、回复、代码或路径。"))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isScreenshotRendering {
                Text(L("分享排名"))
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.tokenGreenDark)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Color.tokenSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.tokenGreen.opacity(0.3)))
            } else {
                Menu {
                    Button(L("复制排名海报"), action: copyRankingPoster)
                    Button(L("保存排名海报 PNG"), action: saveRankingPoster)
                } label: {
                    Text(L("分享排名"))
                        .font(.system(size: 9, weight: .heavy))
                        .frame(width: 80, height: 30)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.bordered)
                .tint(Color.tokenGreenDark)
                .disabled(!canShareRanking)
            }

            if isScreenshotRendering {
                Text(L("查看排行榜详情 ↗"))
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Color.tokenGreen, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Button {
                    appState.openCommunityLeaderboard(isScreenshotRendering: isScreenshotRendering)
                } label: {
                    Text(L("查看排行榜详情 ↗"))
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(Color.tokenGreen, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(appState.communityLeaderboardURL(isScreenshotRendering: isScreenshotRendering) == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.tokenTrack.opacity(0.4), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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

    private var rankHeadline: String {
        if appState.communityRankError != nil,
           appState.communityLeaderboard != nil,
           appState.communityLeaderboardError == nil {
            return L("已进入社群 · 个人排名暂不可用")
        }
        guard let rank = appState.communityRank?.rank,
              let total = appState.communityRank?.totalEntries,
              appState.communityRank?.publicProfileEnabled == true
        else { return L("今天暂无公开排名") }
        return LFormat("今天第 %d / %d 名", rank, total)
    }

    private var rankDetail: String {
        if appState.communityRankError != nil,
           appState.communityLeaderboard != nil,
           appState.communityLeaderboardError == nil {
            return L("公开榜可正常查看；个人排名暂时无法读取，请稍后重试")
        }
        let exceeded = appState.communityRank?.exceededPercentage.map { LFormat("超过 %d%% 参榜用户", $0) }
        let tool = currentUserEntry?.primaryTool ?? appState.communityRank?.primaryTool
        var parts = [String]()
        if let exceeded { parts.append(exceeded) }
        if let tool { parts.append(LFormat("主力工具 %@", tool)) }
        parts.append(localizedStreakDescription(days: appState.activeStreak.days, isLowerBound: appState.activeStreak.isLowerBound))
        return parts.joined(separator: " · ")
    }

    private var currentUserEntry: TeamSyncPublicLeaderboardEntry? {
        guard let publicID = appState.communityRank?.publicID else { return nil }
        return leaderboardEntries.first(where: { $0.publicID == publicID })
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
            Text(L("名次")).frame(width: 42, alignment: .leading)
            Text(L("昵称")).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            Text(L("主力工具")).frame(width: 118, alignment: .leading)
            Text(L("主力模型")).frame(width: 138, alignment: .leading)
            Text(L("总 Token")).frame(width: 104, alignment: .trailing)
            Text(L("估算费用")).frame(width: 104, alignment: .trailing)
        }
        .font(.system(size: 7, weight: .heavy))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.tokenTrack.opacity(0.58), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct CommunityLeaderboardRow: View {
    var entry: TeamSyncPublicLeaderboardEntry
    var isCurrentUser: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.rank.map { "\($0)" } ?? "--")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(entry.rank.map(rankColor) ?? .secondary)
                .frame(width: 42, alignment: .leading)
            HStack(spacing: 7) {
                Text(entry.nickname).font(.system(size: 9, weight: .heavy)).lineLimit(1)
                if isCurrentUser {
                    Text(L("我"))
                        .font(.system(size: 6, weight: .black))
                        .foregroundStyle(Color.tokenSurface)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.tokenGreenDark, in: Capsule())
                }
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            CommunityDimensionValue(name: entry.primaryTool, tokenValue: entry.primaryToolTokens, count: entry.toolCount)
                .frame(width: 118, alignment: .leading)
            CommunityDimensionValue(name: entry.primaryModel, tokenValue: entry.primaryModelTokens, count: entry.modelCount)
                .frame(width: 138, alignment: .leading)
            Text(TokenStepFormat.tokens(entry.tokenValue, compact: true))
                .font(.system(size: 9, weight: .heavy))
                .monospacedDigit()
                .frame(width: 104, alignment: .trailing)
            Text(costText)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
        }
        .foregroundStyle(Color.tokenInk)
        .padding(.horizontal, 14)
        // Keep all ten rows plus the real share/open actions in the standard
        // 760 pt main-window viewport. A taller row silently pushed the
        // footer below the capture and made the actions look removed.
        .frame(height: 34)
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
    var tokenValue: String?
    var count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name ?? "--").font(.system(size: 8, weight: .bold)).lineLimit(1)
            Text(dimensionDetail)
                .font(.system(size: 6, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var dimensionDetail: String {
        if let tokenValue, let tokens = Int(tokenValue) {
            return count > 1
                ? "\(TokenStepFormat.tokens(tokens, compact: true)) · \(LFormat("共 %d 项", count))"
                : TokenStepFormat.tokens(tokens, compact: true)
        }
        return count > 0 ? LFormat("共 %d 项", count) : L("暂无")
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
