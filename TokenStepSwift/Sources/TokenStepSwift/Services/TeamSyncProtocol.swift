import CryptoKit
import Foundation

enum TeamSyncProtocolConfiguration {
    static let schemaVersion = 1
    static let collectorVersion = "0.2.0"
    static let enrollmentPath = "/api/v1/devices/enroll"
    static let dailyUsagePath = "/api/v1/usage/daily"
    static let communityRankPath = "/api/v1/devices/me/community-rank"
    static let communityShareGrantPath = "/api/v1/devices/me/community-share-grants"
    static let publicLeaderboardPath = "/rank"
    static let publicLeaderboardAPIPath = "/api/v1/public/leaderboard"
    static let maxBucketsPerRequest = 2_000
    static let maximumHTTPResponseBytes = 1 * 1_024 * 1_024
    static let maximumTokenValue = 9_000_000_000_000_000
    static let defaultSource = "local"
    static let exactCompleteness = "exact"
    static let signingKeyContext = "TokenFleet-HMAC-v1:\n"
    static let signingKeyDerivation = "sha256-tokenfleet-hmac-v1"
    static let naturalKeySeparator = "\u{1F}"
    /// Backward-compatible local state value from pre-release builds that
    /// experimented with client-generated deletions. v1 no longer creates or
    /// retransmits it; an exact key that reappears overwrites it normally.
    static let deletedLedgerMarker = "__deleted__"
}

enum TeamSyncCommunityServerConfiguration {
    static let infoDictionaryKey = "TokenFleetCommunityServerURL"

    /// Production has exactly one configuration source: the signed app
    /// bundle. Environment variables, UserDefaults, persisted settings, and
    /// command-line arguments are deliberately not consulted.
    static var productionOrigin: URL? {
        validatedProductionOrigin(
            infoDictionaryValue: Bundle.main.object(
                forInfoDictionaryKey: infoDictionaryKey
            )
        )
    }

    static func validatedProductionOrigin(infoDictionaryValue: Any?) -> URL? {
        guard let rawValue = infoDictionaryValue as? String else { return nil }
        return strictlyCanonicalProductionOrigin(rawValue)
    }

    static func persistedOrigin(_ rawValue: String, matches fixedOrigin: URL?) -> Bool {
        guard let fixedOrigin,
              let persistedOrigin = try? TeamSyncProtocol.normalizedServerURL(rawValue)
        else {
            return false
        }
        return persistedOrigin.absoluteString == fixedOrigin.absoluteString
    }

    #if TOKENSTEP_TESTING
    /// Test/dev harnesses may use the production DNS contract or exact HTTP
    /// loopback at 127.0.0.1 / ::1 with an explicit non-default port. This
    /// entire escape hatch is compiled out of production builds.
    static func validatedTestingOrigin(_ rawValue: String) -> URL? {
        strictlyCanonicalProductionOrigin(rawValue)
            ?? strictlyCanonicalTestingLoopbackOrigin(rawValue)
    }

    static func explicitTestingOrigin(_ rawValue: String) -> URL? {
        validatedTestingOrigin(rawValue)
    }
    #endif

    private static func strictlyCanonicalProductionOrigin(_ rawValue: String) -> URL? {
        let prefix = "https://"
        guard !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.unicodeScalars.allSatisfy({ $0.value < 128 }),
              !rawValue.contains("%"),
              rawValue.hasPrefix(prefix),
              let authority = rawValue.dropFirst(prefix.count).nonEmptyString,
              let authorityParts = productionAuthorityParts(authority),
              let components = URLComponents(string: rawValue),
              components.scheme == "https",
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.percentEncodedPath.isEmpty,
              components.query == nil,
              components.fragment == nil,
              components.port == authorityParts.port,
              let url = components.url,
              url.absoluteString == rawValue
        else {
            return nil
        }

        let host = authorityParts.host
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253,
              host == host.lowercased(),
              labels.count >= 2,
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !looksLikeLegacyNumericIPAddress(labels),
              labels.allSatisfy(isValidDNSLabel)
        else {
            return nil
        }
        return url
    }

    private static func productionAuthorityParts(
        _ authority: String
    ) -> (host: String, port: Int?)? {
        guard !authority.contains("@"),
              !authority.contains("["),
              !authority.contains("]"),
              authority.filter({ $0 == ":" }).count <= 1
        else {
            return nil
        }
        guard let colon = authority.lastIndex(of: ":") else {
            return (authority, nil)
        }
        let host = String(authority[..<colon])
        let rawPort = String(authority[authority.index(after: colon)...])
        guard let port = canonicalPort(rawPort), port != 443 else { return nil }
        return (host, port)
    }

    private static func canonicalPort(_ rawValue: String) -> Int? {
        guard !rawValue.isEmpty,
              rawValue.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let port = Int(rawValue),
              (1...65_535).contains(port),
              String(port) == rawValue
        else {
            return nil
        }
        return port
    }

    private static func isValidDNSLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 63,
              label.first != "-", label.last != "-"
        else {
            return false
        }
        return label.unicodeScalars.allSatisfy { scalar in
            (97...122).contains(scalar.value)
                || (48...57).contains(scalar.value)
                || scalar.value == 45
        }
    }

    private static func looksLikeLegacyNumericIPAddress(
        _ labels: [Substring]
    ) -> Bool {
        guard labels.count <= 4 else { return false }
        return labels.allSatisfy { label in
            let value = String(label)
            if value.hasPrefix("0x") {
                let digits = value.dropFirst(2)
                return !digits.isEmpty && digits.unicodeScalars.allSatisfy { scalar in
                    (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
                }
            }
            return value.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
        }
    }

    #if TOKENSTEP_TESTING
    private static func strictlyCanonicalTestingLoopbackOrigin(_ rawValue: String) -> URL? {
        let prefix = "http://"
        guard !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.unicodeScalars.allSatisfy({ $0.value < 128 }),
              !rawValue.contains("%"),
              rawValue.hasPrefix(prefix),
              let components = URLComponents(string: rawValue),
              components.scheme == "http",
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.percentEncodedPath.isEmpty,
              components.query == nil,
              components.fragment == nil,
              let port = components.port,
              port != 80,
              let url = components.url,
              url.absoluteString == rawValue
        else {
            return nil
        }

        let expected: String
        switch components.host {
        case "127.0.0.1":
            expected = "http://127.0.0.1:\(port)"
        case "[::1]":
            expected = "http://[::1]:\(port)"
        default:
            return nil
        }
        return rawValue == expected ? url : nil
    }
    #endif
}

private extension Substring {
    var nonEmptyString: String? {
        isEmpty ? nil : String(self)
    }
}

struct TeamSyncEnrollmentRequest: Codable, Equatable {
    var enrollmentToken: String
    var devicePublicID: String
    var platform: String
    var appVersion: String
    var collectorVersion: String

    enum CodingKeys: String, CodingKey {
        case enrollmentToken = "enrollment_token"
        case devicePublicID = "device_public_id"
        case platform
        case appVersion = "app_version"
        case collectorVersion = "collector_version"
    }
}

struct TeamSyncEnrollmentResponse: Decodable, Equatable {
    var deviceID: String
    var devicePublicID: String?
    var deviceSecret: String
    var signingKeyDerivation: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case devicePublicID = "device_public_id"
        case deviceSecret = "device_secret"
        case signingKeyDerivation = "signing_key_derivation"
    }
}

struct TeamSyncCommunityRank: Decodable, Equatable {
    var publicID: String
    var nickname: String?
    var publicProfileEnabled: Bool
    var period: String
    var metric: String
    var rank: Int?
    var totalEntries: Int
    var metricValue: String?
    var primaryTool: String?
    var primaryModel: String?
    var totals: TeamSyncPublicUsageTotals?

    enum CodingKeys: String, CodingKey {
        case publicID = "public_id"
        case nickname
        case publicProfileEnabled = "public_profile_enabled"
        case period
        case metric
        case rank
        case totalEntries = "total_entries"
        case metricValue = "metric_value"
        case primaryTool = "primary_tool"
        case primaryModel = "primary_model"
        case totals
    }

    var isValid: Bool {
        guard UUID(uuidString: publicID) != nil,
              period == "today",
              metric == "tokens",
              totalEntries >= 0,
              nickname.map({ !$0.isEmpty && $0.count <= 128 }) ?? true,
              metricValue.map(Self.isCanonicalNonNegativeInteger) ?? true
        else {
            return false
        }
        if publicProfileEnabled {
            guard nickname != nil else { return false }
        } else if nickname != nil || rank != nil || metricValue != nil
                    || primaryTool != nil || primaryModel != nil || totals != nil {
            return false
        }
        if let rank {
            guard rank > 0 && rank <= totalEntries, let metricValue else { return false }
            let hasSummary = primaryTool != nil || primaryModel != nil || totals != nil
            guard !hasSummary || summaryIsValid(metricValue: metricValue) else { return false }
            return true
        }
        return metricValue == nil && primaryTool == nil && primaryModel == nil && totals == nil
    }

    var exceededPercentage: Int? {
        guard let rank, totalEntries > 0 else { return nil }
        return max(0, min(100, Int(
            (Double(totalEntries - rank) / Double(totalEntries) * 100).rounded()
        )))
    }

    private static func isCanonicalNonNegativeInteger(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) })
        else {
            return false
        }
        return value == "0" || value.first != "0"
    }

    private func summaryIsValid(metricValue: String) -> Bool {
        guard let primaryTool, let primaryModel, let totals,
              validDimension(primaryTool), validDimension(primaryModel),
              totals.isValid,
              totals.totalTokens == metricValue
        else { return false }
        return true
    }

    private func validDimension(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 128
            && value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
    }
}

/// A short-lived bridge authorizes exactly one browser page to render this
/// already-public member's personal poster.  It is not an account session and
/// must never be logged or persisted by the client.
struct TeamSyncCommunityShareGrant: Decodable, Equatable {
    var grant: String
    var publicID: String

    enum CodingKeys: String, CodingKey {
        case grant
        case publicID = "public_id"
    }

    var isValid: Bool {
        UUID(uuidString: publicID) != nil
            && Self.isValidGrant(grant)
    }

    static func isValidGrant(_ grant: String) -> Bool {
        grant.count >= 43
            && grant.count <= 128
            && grant.unicodeScalars.allSatisfy { scalar in
                (65...90).contains(scalar.value)
                    || (97...122).contains(scalar.value)
                    || (48...57).contains(scalar.value)
                    || scalar.value == 45 || scalar.value == 95
            }
    }
}

struct TeamSyncPublicUsageTotals: Decodable, Equatable {
    var inputTokens: String
    var outputTokens: String
    var cacheReadTokens: String
    var cacheWriteTokens: String
    var normTokens: String
    var totalTokens: String
    var estimatedCostMicrounits: String?
    var costCurrency: String?
    var unpriced: Bool
    var mixedCurrency: Bool

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case normTokens = "norm_tokens"
        case totalTokens = "total_tokens"
        case estimatedCostMicrounits = "estimated_cost_microunits"
        case costCurrency = "cost_currency"
        case unpriced
        case mixedCurrency = "mixed_currency"
    }

    var estimatedCost: Double? {
        guard !unpriced, !mixedCurrency,
              costCurrency == "USD",
              let estimatedCostMicrounits,
              let value = Double(estimatedCostMicrounits)
        else { return nil }
        return value / 1_000_000
    }

    var isValid: Bool {
        let required = [
            inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens,
            normTokens, totalTokens
        ]
        guard required.allSatisfy(TeamSyncPublicLeaderboard.isCanonicalInteger) else {
            return false
        }
        if let estimatedCostMicrounits,
           !TeamSyncPublicLeaderboard.isCanonicalInteger(estimatedCostMicrounits) {
            return false
        }
        if unpriced || mixedCurrency {
            return estimatedCostMicrounits == nil && costCurrency == nil
        }
        return estimatedCostMicrounits != nil && costCurrency == "USD"
    }
}

struct TeamSyncPublicLeaderboardEntry: Decodable, Equatable, Identifiable {
    var id: String { publicID }
    var rank: Int?
    var publicID: String
    var nickname: String
    var metricValue: String?
    var primaryTool: String?
    var primaryToolTokens: String?
    var toolCount: Int
    var primaryModel: String?
    var primaryModelTokens: String?
    var modelCount: Int
    var totals: TeamSyncPublicUsageTotals

    enum CodingKeys: String, CodingKey {
        case rank
        case publicID = "public_id"
        case nickname
        case metricValue = "metric_value"
        case primaryTool = "primary_tool"
        case primaryToolTokens = "primary_tool_tokens"
        case toolCount = "tool_count"
        case primaryModel = "primary_model"
        case primaryModelTokens = "primary_model_tokens"
        case modelCount = "model_count"
        case totals
    }

    var tokenValue: Int { Int(metricValue ?? "") ?? 0 }

    func isValid(totalEntries: Int) -> Bool {
        guard UUID(uuidString: publicID) != nil,
              !nickname.isEmpty,
              nickname.count <= 128,
              nickname.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
              toolCount >= 0,
              modelCount >= 0,
              totals.isValid,
              metricValue.map(TeamSyncPublicLeaderboard.isCanonicalInteger) ?? false
        else { return false }
        if let rank, !(1...max(totalEntries, 1)).contains(rank) { return false }
        guard dimensionIsValid(
            count: toolCount,
            name: primaryTool,
            tokenValue: primaryToolTokens
        ), dimensionIsValid(
            count: modelCount,
            name: primaryModel,
            tokenValue: primaryModelTokens
        ) else { return false }
        return true
    }

    private func dimensionIsValid(count: Int, name: String?, tokenValue: String?) -> Bool {
        if count == 0 { return name == nil && tokenValue == nil }
        guard let name, !name.isEmpty, name.count <= 128,
              let tokenValue,
              TeamSyncPublicLeaderboard.isCanonicalInteger(tokenValue)
        else { return false }
        return true
    }
}

extension TeamSyncPublicLeaderboardEntry {
    /// beta.7 public leaderboard responses predate the optional primary
    /// tool/model summary. Keep those rows readable during a client-first
    /// beta.8 rollout; any partially supplied beta.8 dimension still fails
    /// `isValid` instead of being silently accepted.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rank = try container.decodeIfPresent(Int.self, forKey: .rank)
        publicID = try container.decode(String.self, forKey: .publicID)
        nickname = try container.decode(String.self, forKey: .nickname)
        metricValue = try container.decodeIfPresent(String.self, forKey: .metricValue)
        primaryTool = try container.decodeIfPresent(String.self, forKey: .primaryTool)
        primaryToolTokens = try container.decodeIfPresent(String.self, forKey: .primaryToolTokens)
        toolCount = try container.decodeIfPresent(Int.self, forKey: .toolCount) ?? 0
        primaryModel = try container.decodeIfPresent(String.self, forKey: .primaryModel)
        primaryModelTokens = try container.decodeIfPresent(String.self, forKey: .primaryModelTokens)
        modelCount = try container.decodeIfPresent(Int.self, forKey: .modelCount) ?? 0
        totals = try container.decode(TeamSyncPublicUsageTotals.self, forKey: .totals)
    }
}

struct TeamSyncPublicLeaderboard: Decodable, Equatable {
    var period: String
    var metric: String
    var timezone: String
    var mixedTimezones: Bool
    var totalEntries: Int
    var availableTools: [String]
    var availableModels: [String]
    var entries: [TeamSyncPublicLeaderboardEntry]

    enum CodingKeys: String, CodingKey {
        case period
        case metric
        case timezone
        case mixedTimezones = "mixed_timezones"
        case totalEntries = "total_entries"
        case availableTools = "available_tools"
        case availableModels = "available_models"
        case entries
    }

    var isValid: Bool {
        guard period == "today",
              metric == "tokens",
              !timezone.isEmpty,
              timezone.count <= 128,
              totalEntries >= 0,
              entries.count <= 10,
              entries.count <= totalEntries,
              Set(entries.map(\.publicID)).count == entries.count,
              availableTools.count <= 512,
              availableModels.count <= 2_048,
              (availableTools + availableModels).allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
              entries.allSatisfy({ $0.isValid(totalEntries: totalEntries) })
        else { return false }
        let ranks = entries.compactMap(\.rank)
        return ranks == ranks.sorted() && Set(ranks).count == ranks.count
    }

    static func isCanonicalInteger(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) })
        else { return false }
        return value == "0" || value.first != "0"
    }
}

struct TeamSyncDailyBucket: Codable, Equatable {
    var date: String
    var timezone: String
    var tool: String
    var model: String
    var source: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var completeness: String
    /// Optional on the wire. Its absence decodes as `false`, preserving the v1
    /// upsert payload. A `true` value is a zero-valued deletion tombstone.
    var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case date
        case timezone
        case tool
        case model
        case source
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case completeness
        case deleted
    }

    init(
        date: String,
        timezone: String,
        tool: String,
        model: String,
        source: String = TeamSyncProtocolConfiguration.defaultSource,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        completeness: String = TeamSyncProtocolConfiguration.exactCompleteness,
        deleted: Bool = false
    ) {
        self.date = date
        self.timezone = timezone
        self.tool = tool
        self.model = model
        self.source = source
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.completeness = completeness
        self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        timezone = try container.decode(String.self, forKey: .timezone)
        tool = try container.decode(String.self, forKey: .tool)
        model = try container.decode(String.self, forKey: .model)
        source = try container.decodeIfPresent(String.self, forKey: .source)
            ?? TeamSyncProtocolConfiguration.defaultSource
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
        cacheWriteTokens = try container.decode(Int.self, forKey: .cacheWriteTokens)
        completeness = try container.decodeIfPresent(String.self, forKey: .completeness)
            ?? TeamSyncProtocolConfiguration.exactCompleteness
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(timezone, forKey: .timezone)
        try container.encode(tool, forKey: .tool)
        try container.encode(model, forKey: .model)
        try container.encode(source, forKey: .source)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try container.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try container.encode(completeness, forKey: .completeness)
        if deleted {
            try container.encode(true, forKey: .deleted)
        }
    }

    var naturalKey: String {
        // Completeness is an overwriteable value, not identity. An estimated
        // bucket must be replaced when exact data becomes available.
        [date, timezone, tool, model, source]
            .joined(separator: TeamSyncProtocolConfiguration.naturalKeySeparator)
    }

}

struct TeamSyncDailyPayload: Codable, Equatable {
    var schemaVersion: Int
    var collectorVersion: String
    var generatedAt: String
    var buckets: [TeamSyncDailyBucket]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case collectorVersion = "collector_version"
        case generatedAt = "generated_at"
        case buckets
    }
}

struct DailyUsageIngestResponse: Decodable, Equatable {
    var created: Int
    var updated: Int
    var unchanged: Int
    var ledgerVersion: Int

    enum CodingKeys: String, CodingKey {
        case created
        case updated
        case unchanged
        case ledgerVersion = "ledger_version"
    }

    func isValid(expectedBucketCount: Int) -> Bool {
        guard created >= 0, updated >= 0, unchanged >= 0, ledgerVersion >= 0 else {
            return false
        }
        let (createdAndUpdated, overflow1) = created.addingReportingOverflow(updated)
        let (processed, overflow2) = createdAndUpdated.addingReportingOverflow(unchanged)
        return !overflow1 && !overflow2 && processed == expectedBucketCount
    }
}

struct TeamSyncBucketBuildResult: Equatable {
    var buckets: [TeamSyncDailyBucket]
    var omittedIncompleteBucketCount: Int
}

struct TeamSyncSignedHeaders: Equatable {
    var deviceID: String
    var timestamp: String
    var nonce: String
    var signature: String
}

enum TeamSyncProtocolError: LocalizedError, Equatable {
    case invalidServerURL
    case communityServerUnavailable
    case enrollmentTokenRequired
    case invalidEnrollmentResponse
    case invalidIngestResponse
    case invalidCommunityRankResponse
    case invalidCommunityShareGrantResponse
    case invalidBucket
    case duplicateBucket
    case notEnrolled
    case reconnectRequired
    case operationInProgress
    case operationCancelled
    case automaticRetryStopped
    case credentialsUnavailable
    case credentialStoreTemporarilyUnavailable
    case secureCredentialStorageUnavailable
    case stateUnavailable
    case networkUnavailable
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return L("社群榜服务器地址必须是有效的 HTTPS 地址。")
        case .communityServerUnavailable:
            return L("当前构建未配置有效的社群榜服务器，社群榜同步不可用。")
        case .enrollmentTokenRequired:
            return L("请输入一次性注册码。")
        case .invalidEnrollmentResponse:
            return L("社群榜服务器返回了无效的注册信息。")
        case .invalidIngestResponse:
            return L("社群榜服务器未确认完整接收本次日汇总，已停止自动重试。")
        case .invalidCommunityRankResponse:
            return L("社群榜服务器返回了无效的排名信息。")
        case .invalidCommunityShareGrantResponse:
            return L("社群榜服务器未能安全创建网页分享凭证。")
        case .invalidBucket, .duplicateBucket:
            return L("本地日汇总未通过同步校验。")
        case .notEnrolled:
            return L("请先连接社群榜服务器。")
        case .reconnectRequired:
            return L("设备凭证已失效，请清除后重新连接。")
        case .operationInProgress:
            return L("已有一项社群榜同步操作正在进行。")
        case .operationCancelled:
            return L("社群榜同步已取消。")
        case .automaticRetryStopped:
            return L("同步请求被拒绝，已停止自动重试；请检查服务器配置或更新客户端。")
        case .credentialsUnavailable:
            return L("无法从钥匙串读取设备凭证，请重新连接。")
        case .credentialStoreTemporarilyUnavailable:
            return L("钥匙串暂时不可用，尚未发送数据，稍后会自动重试。")
        case .secureCredentialStorageUnavailable:
            return L("当前构建未启用安全凭据存储，社群榜同步保持关闭。")
        case .stateUnavailable:
            return L("无法保存社群榜同步状态。")
        case .networkUnavailable:
            return L("社群榜服务器暂时无法连接。")
        case let .httpStatus(status):
            return LFormat("社群榜服务器返回错误（%d）。", status)
        }
    }
}

enum TeamSyncProtocol {
    /// Returns the same HTTPS origin used for enrollment and uploads. The
    /// dashboard link never appends credentials, tokens, or automatic-login
    /// parameters.
    static func dashboardURL(serverURL rawValue: String) -> URL? {
        try? normalizedServerURL(rawValue)
    }

    /// Produces the only public destination opened from a connected community
    /// sync card. The destination is always the canonical server origin plus
    /// the fixed public leaderboard path; credentials and login parameters are
    /// never carried into the URL. Screenshot rendering is deliberately gated
    /// here as well as in the view so rendering cannot launch external apps.
    static func publicLeaderboardURL(
        serverURL rawValue: String,
        isEnrolled: Bool,
        isScreenshotRendering: Bool
    ) -> URL? {
        guard isEnrolled, !isScreenshotRendering,
              let origin = TeamSyncCommunityServerConfiguration.validatedProductionOrigin(
                  infoDictionaryValue: rawValue
              )
        else {
            return nil
        }
        return try? endpointURL(
            serverURL: origin,
            path: TeamSyncProtocolConfiguration.publicLeaderboardPath
        )
    }

    /// Builds an App-only browser bridge.  The opaque value lives only in the
    /// fragment, so it never appears in HTTP requests or referrers.  Callers
    /// must never log the returned URL.
    static func personalCommunityShareURL(
        serverURL rawValue: String,
        isEnrolled: Bool,
        isScreenshotRendering: Bool,
        grant: String
    ) -> URL? {
        guard TeamSyncCommunityShareGrant.isValidGrant(grant),
              let base = publicLeaderboardURL(
                  serverURL: rawValue,
                  isEnrolled: isEnrolled,
                  isScreenshotRendering: isScreenshotRendering
              ),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        components.percentEncodedFragment = "/rank?share_grant=\(grant)"
        return components.url
    }

    static func normalizedServerURL(_ rawValue: String) throws -> URL {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw TeamSyncProtocolError.invalidServerURL
        }
        components.scheme = "https"
        components.path = ""
        guard let url = components.url else {
            throw TeamSyncProtocolError.invalidServerURL
        }
        return url
    }

    static func endpointURL(serverURL: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw TeamSyncProtocolError.invalidServerURL
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw TeamSyncProtocolError.invalidServerURL
        }
        return url
    }

    static func enrollmentURLRequest(
        serverURL rawServerURL: String,
        enrollmentToken: String,
        devicePublicID: String,
        appVersion: String,
        collectorVersion: String = TeamSyncProtocolConfiguration.collectorVersion
    ) throws -> URLRequest {
        let token = enrollmentToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw TeamSyncProtocolError.enrollmentTokenRequired }
        let serverURL = try normalizedServerURL(rawServerURL)
        let endpoint = try endpointURL(serverURL: serverURL, path: TeamSyncProtocolConfiguration.enrollmentPath)
        let payload = TeamSyncEnrollmentRequest(
            enrollmentToken: token,
            devicePublicID: devicePublicID,
            platform: "macos",
            appVersion: appVersion,
            collectorVersion: collectorVersion
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodedJSON(payload)
        return request
    }

    static func dailyUsageURLRequest(
        serverURL rawServerURL: String,
        deviceID: String,
        deviceSecret: String,
        payload: TeamSyncDailyPayload,
        timestamp: Int,
        nonce: String
    ) throws -> URLRequest {
        let serverURL = try normalizedServerURL(rawServerURL)
        let endpoint = try endpointURL(serverURL: serverURL, path: TeamSyncProtocolConfiguration.dailyUsagePath)
        let body = try encodedJSON(payload)
        let headers = signedHeaders(
            deviceID: deviceID,
            deviceSecret: deviceSecret,
            timestamp: timestamp,
            nonce: nonce,
            method: "POST",
            path: TeamSyncProtocolConfiguration.dailyUsagePath,
            body: body
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(headers.deviceID, forHTTPHeaderField: "X-Device-ID")
        request.setValue(headers.timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(headers.nonce, forHTTPHeaderField: "X-Nonce")
        request.setValue(headers.signature, forHTTPHeaderField: "X-Signature")
        request.httpBody = body
        return request
    }

    static func communityRankURLRequest(
        serverURL rawServerURL: String,
        deviceID: String,
        deviceSecret: String,
        timestamp: Int,
        nonce: String
    ) throws -> URLRequest {
        let serverURL = try normalizedServerURL(rawServerURL)
        let endpoint = try endpointURL(
            serverURL: serverURL,
            path: TeamSyncProtocolConfiguration.communityRankPath
        )
        let headers = signedHeaders(
            deviceID: deviceID,
            deviceSecret: deviceSecret,
            timestamp: timestamp,
            nonce: nonce,
            method: "GET",
            path: TeamSyncProtocolConfiguration.communityRankPath,
            body: Data()
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(headers.deviceID, forHTTPHeaderField: "X-Device-ID")
        request.setValue(headers.timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(headers.nonce, forHTTPHeaderField: "X-Nonce")
        request.setValue(headers.signature, forHTTPHeaderField: "X-Signature")
        return request
    }

    /// Mints a server-tracked, one-time browser bridge for the current signed
    /// device.  The only request body is `{}`; the opaque response is never
    /// stored by this layer.
    static func communityShareGrantURLRequest(
        serverURL rawServerURL: String,
        deviceID: String,
        deviceSecret: String,
        timestamp: Int,
        nonce: String
    ) throws -> URLRequest {
        let serverURL = try normalizedServerURL(rawServerURL)
        let endpoint = try endpointURL(
            serverURL: serverURL,
            path: TeamSyncProtocolConfiguration.communityShareGrantPath
        )
        let body = Data("{}".utf8)
        let headers = signedHeaders(
            deviceID: deviceID,
            deviceSecret: deviceSecret,
            timestamp: timestamp,
            nonce: nonce,
            method: "POST",
            path: TeamSyncProtocolConfiguration.communityShareGrantPath,
            body: body
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(headers.deviceID, forHTTPHeaderField: "X-Device-ID")
        request.setValue(headers.timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(headers.nonce, forHTTPHeaderField: "X-Nonce")
        request.setValue(headers.signature, forHTTPHeaderField: "X-Signature")
        request.httpBody = body
        return request
    }

    /// Reads only the anonymous public projection. It never carries device
    /// credentials, enrollment tokens, cookies, or an Authorization header.
    static func publicLeaderboardAPIURLRequest(
        serverURL rawServerURL: String
    ) throws -> URLRequest {
        let serverURL = try normalizedServerURL(rawServerURL)
        let endpoint = try endpointURL(
            serverURL: serverURL,
            path: TeamSyncProtocolConfiguration.publicLeaderboardAPIPath
        )
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw TeamSyncProtocolError.invalidServerURL
        }
        components.queryItems = [
            URLQueryItem(name: "period", value: "today"),
            URLQueryItem(name: "metric", value: "tokens"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components.url else {
            throw TeamSyncProtocolError.invalidServerURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func signedHeaders(
        deviceID: String,
        deviceSecret: String,
        timestamp: Int,
        nonce: String,
        method: String,
        path: String,
        body: Data
    ) -> TeamSyncSignedHeaders {
        let timestampText = String(timestamp)
        let canonicalValue = canonical(
            timestamp: timestampText,
            nonce: nonce,
            method: method,
            path: path,
            body: body
        )
        let derivedKey = SHA256.hash(
            data: Data((TeamSyncProtocolConfiguration.signingKeyContext + deviceSecret).utf8)
        )
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(canonicalValue.utf8),
            using: SymmetricKey(data: Data(derivedKey))
        )
        return TeamSyncSignedHeaders(
            deviceID: deviceID,
            timestamp: timestampText,
            nonce: nonce,
            signature: Data(signature).lowercaseHex
        )
    }

    static func canonical(
        timestamp: String,
        nonce: String,
        method: String,
        path: String,
        body: Data
    ) -> String {
        [timestamp, nonce, method.uppercased(), path, body.sha256Hex]
            .joined(separator: "\n")
    }

    static func dailyBuckets(
        snapshot: UsageSnapshot,
        source: String = TeamSyncProtocolConfiguration.defaultSource
    ) throws -> [TeamSyncDailyBucket] {
        try dailyBucketBuild(snapshot: snapshot, source: source).buckets
    }

    static func dailyBucketBuild(
        snapshot: UsageSnapshot,
        source: String = TeamSyncProtocolConfiguration.defaultSource
    ) throws -> TeamSyncBucketBuildResult {
        let timezone = (snapshot.timezone?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? snapshot.timezone!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Asia/Shanghai"
        var buckets: [TeamSyncDailyBucket] = []
        var omittedIncompleteBucketCount = 0
        for day in snapshot.daily {
            // Legacy rows have only independent marginals. Skipping them is the
            // only honest choice: a tool x model tuple cannot be reconstructed.
            guard let atomicUsage = day.atomicUsage else {
                let (nextCount, overflow) = omittedIncompleteBucketCount.addingReportingOverflow(1)
                guard !overflow else { throw TeamSyncProtocolError.invalidBucket }
                omittedIncompleteBucketCount = nextCount
                continue
            }
            var atomicDayTotal = 0
            for atomic in atomicUsage {
                guard atomic.totalTokens >= 0 else {
                    throw TeamSyncProtocolError.invalidBucket
                }
                let (nextDayTotal, overflow) = atomicDayTotal.addingReportingOverflow(atomic.totalTokens)
                guard !overflow else { throw TeamSyncProtocolError.invalidBucket }
                atomicDayTotal = nextDayTotal
                guard atomic.breakdownComplete else {
                    omittedIncompleteBucketCount += 1
                    continue
                }
                let bucket = TeamSyncDailyBucket(
                    date: day.date,
                    timezone: timezone,
                    tool: atomic.tool.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: atomic.model.trimmingCharacters(in: .whitespacesAndNewlines),
                    source: source,
                    inputTokens: atomic.inputTokens,
                    outputTokens: atomic.outputTokens,
                    cacheReadTokens: atomic.cacheReadTokens,
                    cacheWriteTokens: atomic.cacheWriteTokens
                )
                try validate(bucket: bucket)
                let componentTotal = bucket.inputTokens
                    + bucket.outputTokens
                    + bucket.cacheReadTokens
                    + bucket.cacheWriteTokens
                guard atomic.totalTokens == componentTotal else {
                    throw TeamSyncProtocolError.invalidBucket
                }
                buckets.append(bucket)
            }
            guard atomicDayTotal == day.totalTokens else {
                throw TeamSyncProtocolError.invalidBucket
            }
        }
        var naturalKeys = Set<String>()
        for bucket in buckets where !naturalKeys.insert(bucket.naturalKey).inserted {
            throw TeamSyncProtocolError.duplicateBucket
        }
        let sortedBuckets = buckets.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.tool != $1.tool { return $0.tool.localizedStandardCompare($1.tool) == .orderedAscending }
            return $0.model.localizedStandardCompare($1.model) == .orderedAscending
        }
        return TeamSyncBucketBuildResult(
            buckets: sortedBuckets,
            omittedIncompleteBucketCount: omittedIncompleteBucketCount
        )
    }

    static func contentHash(for bucket: TeamSyncDailyBucket) throws -> String {
        try encodedJSON(bucket).sha256Hex
    }

    static func generatedAt(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func validate(bucket: TeamSyncDailyBucket) throws {
        let separator = TeamSyncProtocolConfiguration.naturalKeySeparator
        let trimmedTool = bucket.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = bucket.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedDate = DateFormatter.tokenStepDay.date(from: bucket.date),
              DateFormatter.tokenStepDay.string(from: parsedDate) == bucket.date,
              TimeZone(identifier: bucket.timezone) != nil,
              (1...128).contains(bucket.tool.count),
              (1...128).contains(bucket.model.count),
              bucket.tool == trimmedTool,
              bucket.model == trimmedModel,
              !bucket.date.contains(separator),
              !bucket.timezone.contains(separator),
              !bucket.tool.contains(separator),
              !bucket.model.contains(separator),
              !bucket.source.contains(separator),
              bucket.source == TeamSyncProtocolConfiguration.defaultSource,
              bucket.completeness == TeamSyncProtocolConfiguration.exactCompleteness
        else {
            throw TeamSyncProtocolError.invalidBucket
        }
        let counts = [
            bucket.inputTokens,
            bucket.outputTokens,
            bucket.cacheReadTokens,
            bucket.cacheWriteTokens
        ]
        guard counts.allSatisfy({ (0...TeamSyncProtocolConfiguration.maximumTokenValue).contains($0) }) else {
            throw TeamSyncProtocolError.invalidBucket
        }
        if bucket.deleted, !counts.allSatisfy({ $0 == 0 }) {
            throw TeamSyncProtocolError.invalidBucket
        }
    }
}

enum TeamSyncBackoffPolicy {
    static let maximumDelay: TimeInterval = 6 * 60 * 60

    static func delay(failureCount: Int, jitterUnit: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponent = min(max(0, failureCount - 1), 12)
        let base = min(maximumDelay, 60 * pow(2, Double(exponent)))
        let clampedJitter = min(1, max(0, jitterUnit))
        let jitterMultiplier = 0.8 + (0.4 * clampedJitter)
        return min(maximumDelay, base * jitterMultiplier)
    }
}

private extension Data {
    var sha256Hex: String {
        Data(SHA256.hash(data: self)).lowercaseHex
    }

    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
