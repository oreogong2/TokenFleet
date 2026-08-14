import AppKit
import SwiftUI

/// A 600 × 800 point canvas. ScreenshotExporter renders at Retina scale, so
/// the exported PNG is exactly 1200 × 1600 on a standard 2× Mac display.
struct CommunityRankingShareView: View {
    var rank: TeamSyncCommunityRank
    var leaderboard: TeamSyncPublicLeaderboard
    var appearanceID: String
    var leaderboardURL: URL?
    private let qrCGImage: CGImage?

    init(
        rank: TeamSyncCommunityRank,
        leaderboard: TeamSyncPublicLeaderboard,
        appearanceID: String,
        leaderboardURL: URL?
    ) {
        self.rank = rank
        self.leaderboard = leaderboard
        self.appearanceID = appearanceID
        self.leaderboardURL = leaderboardURL
        qrCGImage = Self.makeQRCodeImage(for: leaderboardURL)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.tokenSurface, Color.tokenMint.opacity(0.58), Color.tokenTrack.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 14) {
                header
                hero
                topTen
                footer
            }
            .padding(28)
        }
        .frame(width: 600, height: 800)
        .fixedSize()
        .id(appearanceID)
    }

    private var header: some View {
        HStack(spacing: 11) {
            TokenFleetSignalMark(size: 43)
            VStack(alignment: .leading, spacing: 2) {
                Text("TokenFleet")
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                Text(L("今日社群排名"))
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(L("每天一个亿"))
                .font(.callout.weight(.heavy))
                .foregroundStyle(Color.tokenGreenDark)
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(rank.nickname ?? L("匿名用户"))
                    .font(.system(size: 31, weight: .black, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .lineLimit(1)
                Text(TokenStepFormat.tokens(Int(rank.metricValue ?? "") ?? 0))
                    .font(.system(size: 43, weight: .black, design: .rounded))
                    .foregroundStyle(Color.tokenGreenDark)
                    .monospacedDigit()
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Text(primaryDescription)
                    .font(.callout.weight(.heavy))
                    .foregroundStyle(Color.tokenInk.opacity(0.68))
                    .lineLimit(2)
                Text(costDescription)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                Text(rank.rank.map { "#\($0)" } ?? "--")
                    .font(.system(size: 92, weight: .black, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(LFormat("全榜 %d 人", rank.totalEntries))
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
        .background(Color.tokenSurface.opacity(0.9), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(Color.black.opacity(0.06)))
    }

    private var topTen: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("今日 Top 10"))
                    .font(.headline.weight(.black))
                    .foregroundStyle(Color.tokenInk)
                Spacer()
                Text(L("Token · 主力工具 · 主力模型"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(leaderboard.entries.prefix(10))) { entry in
                    HStack(spacing: 9) {
                        Text(entry.rank.map { "#\($0)" } ?? "--")
                            .font(.caption.weight(.black))
                            .foregroundStyle(entry.publicID == rank.publicID ? Color.tokenGreenDark : Color.tokenInk)
                            .frame(width: 32, alignment: .leading)
                        Text(entry.nickname)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                            .lineLimit(1)
                            .frame(width: 92, alignment: .leading)
                        Text(entry.primaryTool ?? "--")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.tokenInk.opacity(0.68))
                            .lineLimit(1)
                            .frame(width: 90, alignment: .leading)
                        Text(entry.primaryModel ?? "--")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.tokenInk.opacity(0.68))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(TokenStepFormat.tokens(entry.tokenValue, compact: true))
                            .font(.caption.weight(.black))
                            .foregroundStyle(Color.tokenInk)
                            .monospacedDigit()
                            .frame(width: 78, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(entry.publicID == rank.publicID ? Color.tokenMint.opacity(0.32) : Color.clear)
                    .background(alignment: .bottom) {
                        Rectangle().fill(Color.black.opacity(0.045)).frame(height: 1)
                    }
                }
            }
            .background(Color.tokenSurface.opacity(0.8), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .padding(16)
        .background(Color.tokenSurface.opacity(0.58), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("让自己 AI Native 化，Learn in Public."))
                    .font(.headline.weight(.black))
                    .foregroundStyle(Color.tokenInk)
                Text(L("公开 API 标准价等价估算，不是实际账单。"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(L("不公开提示词、回复、代码、文件或设备信息"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let qrCGImage {
                Image(decorative: qrCGImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 74, height: 74)
                    .padding(7)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(L("扫码查看完整榜单"))
            }
        }
    }

    private var ownEntry: TeamSyncPublicLeaderboardEntry? {
        leaderboard.entries.first { $0.publicID == rank.publicID }
    }

    private var primaryDescription: String {
        let tool = rank.primaryTool ?? ownEntry?.primaryTool ?? "--"
        let model = rank.primaryModel ?? ownEntry?.primaryModel ?? "--"
        return LFormat("主力工具 %@ · 主力模型 %@", tool, model)
    }

    private var costDescription: String {
        guard let cost = rank.totals?.estimatedCost ?? ownEntry?.totals.estimatedCost else {
            return L("API 估算：未完整计价")
        }
        return LFormat("API 标准价估算 %@", TokenStepFormat.money(cost))
    }

    private static func makeQRCodeImage(for url: URL?) -> CGImage? {
        guard let url else { return nil }
        return LocalQRCodeGenerator.makeCGImage(text: url.absoluteString)
    }
}
