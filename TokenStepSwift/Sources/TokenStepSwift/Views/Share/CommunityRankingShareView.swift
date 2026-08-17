import AppKit
import SwiftUI

/// A 600 × 800 point canvas. ScreenshotExporter uses a deterministic 2× export
/// scale, so the PNG is exactly 1200 × 1600 on every supported Mac and in CI.
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
            Color(red: 0.965, green: 0.945, blue: 0.902)
            ShareGridBackground()
                .stroke(Color.tokenGreen.opacity(0.055), lineWidth: 1)

            VStack(alignment: .leading, spacing: 10) {
                header
                hero
                topTen
                footer
            }
            // One 564 pt editorial column: 18 pt margins on both sides of the
            // 600 pt export canvas. Hero, table and footer share both edges.
            .frame(width: 564, alignment: .leading)
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 600, height: 800)
        .fixedSize()
        .id(appearanceID)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("TOKENFLEET")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.tokenGreenDark, in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Token 消耗排行榜"))
                    .font(.system(size: 25, weight: .black, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                Text(L("今天 · 含缓存 Token · API 公开标准价估算"))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(rank.nickname ?? L("匿名用户"))
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(Color.tokenInk)
                    .lineLimit(1)
                    .frame(height: 19, alignment: .bottom)
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text(TokenStepFormat.tokens(Int(rank.metricValue ?? "") ?? 0))
                        .font(.system(size: 23, weight: .black, design: .rounded))
                        .foregroundStyle(Color.tokenGreenDark)
                        .monospacedDigit()
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                    Text("TOKEN")
                        .font(.system(size: 7, weight: .black, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 35, alignment: .bottom)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.tokenGreen.opacity(0.22))
                .frame(width: 1, height: 46)
                .padding(.horizontal, 16)

            VStack(alignment: .trailing, spacing: 0) {
                Text(L("排名"))
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: 19, alignment: .bottom)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(rank.rank.map { "#\($0)" } ?? "--")
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .foregroundStyle(Color.tokenGreenDark)
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    if rank.totalEntries > 0 {
                        Text("/\(rank.totalEntries)")
                            .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 35, alignment: .bottom)
            }
            .frame(width: 132, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.tokenSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.tokenGreen.opacity(0.18)))
    }

    private var topTen: some View {
        VStack(alignment: .leading, spacing: 5) {
            ShareLeaderboardHeader()
            VStack(spacing: 0) {
                ForEach(Array(leaderboard.entries.prefix(10))) { entry in
                    HStack(spacing: 5) {
                        Text(entry.rank.map { String(format: "%02d", $0) } ?? "--")
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(entry.publicID == rank.publicID ? Color.tokenGreenDark : Color.tokenInk)
                            .frame(width: 25, alignment: .leading)
                        Text(entry.nickname)
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(Color.tokenInk)
                            .lineLimit(1)
                            .frame(width: 86, alignment: .leading)
                        ShareDimensionCell(name: entry.primaryTool, tokens: entry.primaryToolTokens)
                            .frame(width: 112, alignment: .leading)
                        ShareDimensionCell(name: entry.primaryModel, tokens: entry.primaryModelTokens)
                            .frame(width: 142, alignment: .leading)
                        Text(TokenStepFormat.tokens(entry.tokenValue, compact: true))
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(Color.tokenInk)
                            .monospacedDigit()
                            .frame(width: 74, alignment: .trailing)
                        Text(entryCost(entry))
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 86, alignment: .trailing)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 44)
                    .background(entry.publicID == rank.publicID ? Color.tokenMint.opacity(0.32) : Color.clear)
                    .background(alignment: .bottom) {
                        Rectangle().fill(Color.black.opacity(0.045)).frame(height: 1)
                    }
                }
            }
            .background(Color.tokenSurface.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 14) {
            if let qrCGImage {
                Image(decorative: qrCGImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 82, height: 82)
                    .padding(7)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(L("扫码查看完整榜单"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("让自己 AI Native 化，Learn in Public."))
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(Color.tokenGreenDark)
                Text(L("扫码查看同一口径的完整排行榜"))
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(Color.tokenInk)
                Text(L("Top 10 之外还有更多排名；想加入可在排行榜网页点击“安装与加入”。"))
                    .font(.system(size: 6, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.tokenSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func entryCost(_ entry: TeamSyncPublicLeaderboardEntry) -> String {
        guard let cost = entry.totals.estimatedCost else { return L("未定价") }
        return TokenStepFormat.money(cost)
    }

    private static func makeQRCodeImage(for url: URL?) -> CGImage? {
        guard let url else { return nil }
        return LocalQRCodeGenerator.makeCGImage(text: url.absoluteString)
    }
}

private struct ShareLeaderboardHeader: View {
    var body: some View {
        HStack(spacing: 5) {
            Text(L("名次")).frame(width: 25, alignment: .leading)
            Text(L("成员")).frame(width: 86, alignment: .leading)
            Text(L("主力工具")).frame(width: 112, alignment: .leading)
            Text(L("主力模型")).frame(width: 142, alignment: .leading)
            Text(L("Token")).frame(width: 74, alignment: .trailing)
            Text(L("估算")).frame(width: 86, alignment: .trailing)
        }
        .font(.system(size: 6, weight: .heavy))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
    }
}

private struct ShareDimensionCell: View {
    var name: String?
    var tokens: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name ?? "--")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.tokenInk.opacity(0.84))
                .lineLimit(1)
            Text(tokenText)
                .font(.system(size: 6, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var tokenText: String {
        guard let tokens, let value = Int(tokens) else { return L("暂无") }
        return TokenStepFormat.tokens(value, compact: true)
    }
}

private struct ShareGridBackground: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += 20
        }
        var y = rect.minY
        while y <= rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += 20
        }
        return path
    }
}
