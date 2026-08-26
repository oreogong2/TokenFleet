#if TOKENSTEP_TESTING
import Foundation

/// One deterministic public-rank fixture shared by image gates and the
/// isolated native preview. It is compiled out of every production build.
enum Beta8CommunityRenderFixture {
    static let serverOrigin = "https://community.example.com"
    static let ownPublicID = "10000000-0000-4000-8000-000000000018"

    static func rank() -> TeamSyncCommunityRank {
        TeamSyncCommunityRank(
            publicID: ownPublicID,
            nickname: "奥利奥",
            publicProfileEnabled: true,
            period: "today",
            metric: "tokens",
            rank: 18,
            totalEntries: 128,
            metricValue: "1088000000",
            primaryTool: "Codex",
            primaryModel: "gpt-5.6-sol",
            totals: TeamSyncPublicUsageTotals(
                inputTokens: "820000000",
                outputTokens: "70000000",
                cacheReadTokens: "198000000",
                cacheWriteTokens: "0",
                normTokens: "890000000",
                totalTokens: "1088000000",
                estimatedCostMicrounits: "1392640000",
                costCurrency: "USD",
                unpriced: false,
                mixedCurrency: false
            )
        )
    }

    static func leaderboard() -> TeamSyncPublicLeaderboard {
        let nicknames = [
            "Ray", "Momo", "Aster", "Nora", "Kai",
            "小宇", "Ada", "Lin", "Juno", "Max"
        ]
        let tokens = [
            1_462_000_000, 1_241_000_000, 1_088_000_000, 986_000_000, 864_000_000,
            742_000_000, 668_000_000, 591_000_000, 524_000_000, 476_000_000
        ]
        let tools = ["Codex", "Claude Code", "Codex", "Cursor", "Codex"]
        let models = [
            "gpt-5.6-sol", "claude-opus-4.1", "gpt-5.6-sol",
            "gpt-5.6-terra", "claude-sonnet-4"
        ]
        let entries = nicknames.indices.map { index -> TeamSyncPublicLeaderboardEntry in
            let tokenValue = tokens[index]
            let input = Int(Double(tokenValue) * 0.82)
            let output = Int(Double(tokenValue) * 0.07)
            let cacheRead = tokenValue - input - output
            return TeamSyncPublicLeaderboardEntry(
                rank: index + 1,
                publicID: String(
                    format: "10000000-0000-4000-8000-%012d",
                    index + 1
                ),
                nickname: nicknames[index],
                metricValue: String(tokenValue),
                primaryTool: tools[index % tools.count],
                primaryToolTokens: String(Int(Double(tokenValue) * 0.83)),
                toolCount: 2 + (index % 3),
                primaryModel: models[index % models.count],
                primaryModelTokens: String(Int(Double(tokenValue) * 0.66)),
                modelCount: 3 + (index % 4),
                totals: TeamSyncPublicUsageTotals(
                    inputTokens: String(input),
                    outputTokens: String(output),
                    cacheReadTokens: String(cacheRead),
                    cacheWriteTokens: "0",
                    normTokens: String(tokenValue),
                    totalTokens: String(tokenValue),
                    estimatedCostMicrounits: String(Int(Double(tokenValue) * 1.28)),
                    costCurrency: "USD",
                    unpriced: false,
                    mixedCurrency: false
                )
            )
        }
        return TeamSyncPublicLeaderboard(
            period: "today",
            metric: "tokens",
            timezone: "Asia/Shanghai",
            mixedTimezones: false,
            totalEntries: 128,
            availableTools: ["Claude Code", "Codex", "Cursor"],
            availableModels: [
                "claude-opus-4.1", "claude-sonnet-4", "gpt-5.6-sol", "gpt-5.6-terra"
            ],
            entries: entries
        )
    }
}
#endif
