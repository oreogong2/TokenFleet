import CryptoKit
import Foundation

enum TeamSyncProtocolConfiguration {
    static let schemaVersion = 1
    static let collectorVersion = "0.2.0"
    static let enrollmentPath = "/api/v1/devices/enroll"
    static let dailyUsagePath = "/api/v1/usage/daily"
    static let publicLeaderboardPath = "/rank"
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
