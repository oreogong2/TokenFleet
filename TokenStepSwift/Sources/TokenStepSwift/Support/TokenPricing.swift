import CryptoKit
import Foundation

struct TokenPricingUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var totalTokens: Int
    var breakdownComplete: Bool

    var componentsMatchTotal: Bool {
        let values = [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens]
        guard values.allSatisfy({ $0 >= 0 }) else { return false }
        let (a, overflow1) = inputTokens.addingReportingOverflow(outputTokens)
        let (b, overflow2) = a.addingReportingOverflow(cacheReadTokens)
        let (c, overflow3) = b.addingReportingOverflow(cacheWriteTokens)
        return !overflow1 && !overflow2 && !overflow3 && c == totalTokens
    }
}

struct TokenCostEstimate: Equatable {
    var costUSD: Double
    var pricingVersion: String
    var provider: String
    var priceModel: String
    var pricedTokens: Int
    var unpricedTokens: Int
}

enum TokenPriceCatalogError: Error {
    case invalidCatalog, unsupportedSchema, staleCatalog, invalidOrigin, invalidResponse
}

/// The server is the only source of rates; this module contains no price table.
struct ServerTokenPriceCatalog: Decodable {
    struct Price: Decodable {
        let id: String
        let tool: String
        let model: String
        let currency: String
        let inputPerMillion: String
        let outputPerMillion: String
        let cacheReadPerMillion: String
        let cacheWritePerMillion: String
        let effectiveFrom: String
        let sourceUrl: String
        let sourceCheckedAt: String
        let effectiveBasis: String

        var rates: [Decimal]? {
            let strings = [inputPerMillion, outputPerMillion, cacheReadPerMillion, cacheWritePerMillion]
            let values = strings.compactMap { value -> Decimal? in
                guard value.range(of: "^[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
                      value.count <= 40,
                      let result = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
                      !result.isNaN, result >= 0 else { return nil }
                return result
            }
            return values.count == 4 ? values : nil
        }
    }

    let schemaVersion: Int
    let normalizationVersion: Int
    let revision: Int
    let version: String
    let basis: String
    let prices: [Price]

    static let maximumBytes = 2 * 1024 * 1024

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let claimed = object.removeValue(forKey: "version") as? String,
              claimed.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw TokenPriceCatalogError.invalidCatalog
        }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard digest(canonical) == claimed else { throw TokenPriceCatalogError.invalidCatalog }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(Self.self, from: data)
        guard result.schemaVersion == 1, result.normalizationVersion == 1 else {
            throw TokenPriceCatalogError.unsupportedSchema
        }
        let officialHosts = Set(["developers.openai.com", "platform.openai.com", "openai.com",
                                 "platform.claude.com", "docs.anthropic.com", "docs.z.ai", "api-docs.deepseek.com"])
        guard result.revision >= 0, result.basis == "standard_api_equivalent", result.prices.count <= 10_000,
              Set(result.prices.map(\.id)).count == result.prices.count,
              result.prices.allSatisfy({ row in
                  guard let source = URLComponents(string: row.sourceUrl) else { return false }
                  return UUID(uuidString: row.id) != nil && row.tool.count <= 128 && !row.tool.isEmpty
                      && row.model.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression) != nil
                      && Self.normalizeModel(row.model) == row.model
                      && row.currency == "USD" && row.rates != nil
                      && validDay(row.effectiveFrom) && validDay(row.sourceCheckedAt)
                      && ["official_date", "ledger_first_seen"].contains(row.effectiveBasis)
                      && source.scheme == "https" && officialHosts.contains(source.host ?? "")
                      && source.user == nil && source.password == nil && source.port == nil
                      && source.query == nil && source.fragment == nil
              }) else { throw TokenPriceCatalogError.invalidCatalog }
        return result
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validDay(_ value: String) -> Bool {
        guard value.range(of: "^20[0-9]{2}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let day = formatter.date(from: value) else { return false }
        return formatter.string(from: day) == value
    }

    /// Mirrors normalization v1 on the server; the ledger's model/tool keys stay unchanged.
    static func normalizeModel(_ value: String) -> String {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        for prefix in ["anthropic/", "openai/", "public/", "cursor-", "cb-"] where name.hasPrefix(prefix) {
            let candidate = String(name.dropFirst(prefix.count))
            if candidate.range(of: "^(?:gpt-[0-9]|claude-(?:opus|sonnet|haiku|fable|mythos)-[0-9])", options: .regularExpression) != nil {
                name = candidate
                break
            }
        }
        if let range = name.range(of: "-(20[0-9]{2}-[0-9]{2}-[0-9]{2}|20[0-9]{6})$", options: .regularExpression) {
            let stamp = String(name[range].dropFirst())
            let day: String
            if stamp.count == 8 {
                day = String(stamp.prefix(4)) + "-" + String(stamp.dropFirst(4).prefix(2)) + "-" + String(stamp.suffix(2))
            } else { day = stamp }
            if validDay(day) { name.removeSubrange(range) }
        }
        name = name.replacingOccurrences(of: "^(gpt)-([0-9]+)-([0-9]+)(?=-|$)", with: "$1-$2.$3", options: .regularExpression)
        return name.replacingOccurrences(of: "^(claude-(?:opus|sonnet|haiku|fable|mythos))-([0-9]+)[.-]([0-9]+)$", with: "$1-$2.$3", options: .regularExpression)
    }

    func estimate(tool: String, model: String, usage: TokenPricingUsage, date: String, pricingVersion: String) -> TokenCostEstimate? {
        guard usage.breakdownComplete, usage.componentsMatchTotal, Self.validDay(date) else { return nil }
        let normalizedModel = Self.normalizeModel(model)
        let matches = prices.filter { $0.effectiveFrom <= date && $0.model == normalizedModel }
        for target in [tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "*"] {
            let candidates = matches.filter { $0.tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target }
            guard let latest = candidates.map(\.effectiveFrom).max() else { continue }
            let newest = candidates.filter { $0.effectiveFrom == latest }
            guard let row = newest.first, let rates = row.rates,
                  newest.allSatisfy({ $0.currency == row.currency && $0.rates == rates }) else { return nil }
            // Same unit and HALF_UP rounding as the server, once per daily ledger bucket.
            let tokens = [usage.inputTokens, usage.outputTokens, usage.cacheReadTokens, usage.cacheWriteTokens]
            var total = Decimal.zero
            for (count, rate) in zip(tokens, rates) {
                var lhs = Decimal(count), rhs = rate, product = Decimal.zero, next = Decimal.zero
                guard NSDecimalMultiply(&product, &lhs, &rhs, .plain) == .noError,
                      NSDecimalAdd(&next, &total, &product, .plain) == .noError else { return nil }
                total = next
            }
            var rounded = Decimal.zero
            NSDecimalRound(&rounded, &total, 0, .plain)
            guard !rounded.isNaN, rounded <= Decimal(Int64.max) else { return nil }
            return TokenCostEstimate(costUSD: NSDecimalNumber(decimal: rounded).doubleValue / 1_000_000,
                pricingVersion: pricingVersion, provider: URL(string: row.sourceUrl)?.host ?? "",
                priceModel: row.model, pricedTokens: usage.totalTokens, unpricedTokens: 0)
        }
        return nil
    }
}

enum TokenPriceCatalogCache {
    private struct Envelope: Codable {
        let origin: String
        let payload: Data
    }
    struct Context {
        let origin: String
        let catalog: ServerTokenPriceCatalog
        var pricingVersion: String {
            "server-usd-v1:\(ServerTokenPriceCatalog.digest(Data(origin.utf8)).prefix(16)):\(catalog.revision):\(catalog.version)"
        }
    }

    static func canonicalOrigin(_ url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.port == nil || parts.port == 443,
              parts.path.isEmpty || parts.path == "/" else { throw TokenPriceCatalogError.invalidOrigin }
        return "https://" + parts.host!.lowercased()
    }

    static func load(at file: URL, origin: URL? = nil) -> Context? {
        guard !((try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= ServerTokenPriceCatalog.maximumBytes * 2,
              let data = try? Data(contentsOf: file),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let storedOrigin = URL(string: envelope.origin),
              (try? canonicalOrigin(storedOrigin)) == envelope.origin,
              origin == nil || (try? canonicalOrigin(origin!)) == envelope.origin,
              let catalog = try? ServerTokenPriceCatalog.decode(envelope.payload) else { return nil }
        return Context(origin: envelope.origin, catalog: catalog)
    }

    @discardableResult
    static func save(_ payload: Data, origin: URL, at file: URL) throws -> Bool {
        let normalized = try canonicalOrigin(origin)
        let catalog = try ServerTokenPriceCatalog.decode(payload)
        if let old = load(at: file, origin: origin) {
            guard catalog.revision >= old.catalog.revision else { throw TokenPriceCatalogError.staleCatalog }
            if catalog.revision == old.catalog.revision {
                guard catalog.version == old.catalog.version else { throw TokenPriceCatalogError.staleCatalog }
                return false
            }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Envelope(origin: normalized, payload: payload))
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }
}

enum TokenPricingCatalog {
    static var context: TokenPriceCatalogCache.Context? {
        let origin = (Bundle.main.object(forInfoDictionaryKey: "TokenFleetCommunityServerURL") as? String).flatMap(URL.init(string:))
        return TokenPriceCatalogCache.load(at: AppPaths.priceCatalogJSON, origin: origin)
    }
    static var version: String { context?.pricingVersion ?? "server-usd-v1:unavailable" }

    static func estimate(tool: String, model: String, usage: TokenPricingUsage, date: String) -> TokenCostEstimate? {
        guard let context else { return nil }
        return context.catalog.estimate(tool: tool, model: model, usage: usage, date: date, pricingVersion: context.pricingVersion)
    }

    private static func revision(_ value: String) -> (String, Int)? {
        let parts = value.split(separator: ":")
        guard parts.count == 4, parts[0] == "server-usd-v1", let revision = Int(parts[2]), revision >= 0,
              parts[1].count == 16, parts[3].count == 64 else { return nil }
        return (String(parts[1]), revision)
    }

    static func shouldReestimate(storedVersion: String?) -> Bool {
        guard storedVersion != version else { return false }
        guard let storedVersion, !storedVersion.isEmpty else { return true }
        if storedVersion.hasPrefix("public-usd-") || storedVersion == "server-usd-v1:unavailable" { return true }
        guard let old = revision(storedVersion), let current = revision(version) else { return false }
        return old.0 == current.0 && old.1 < current.1
    }

    static func shouldPreserveSnapshot(storedVersion: String?) -> Bool {
        guard let storedVersion, !storedVersion.isEmpty, storedVersion != version else { return false }
        if storedVersion.hasPrefix("public-usd-") || storedVersion == "server-usd-v1:unavailable" { return false }
        guard let old = revision(storedVersion), let current = revision(version) else { return true }
        return old.0 != current.0 || old.1 >= current.1
    }
}

private final class PriceCatalogRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor TokenPriceCatalogRefresh {
    static let shared = TokenPriceCatalogRefresh()
    private var lastAttempt: [String: Date] = [:]

    @discardableResult
    func refresh(origin: URL, file: URL = AppPaths.priceCatalogJSON, now: Date = Date()) async -> Bool {
        guard let key = try? TokenPriceCatalogCache.canonicalOrigin(origin) else { return false }
        if let last = lastAttempt[key], now.timeIntervalSince(last) < 15 * 60 { return false }
        lastAttempt[key] = now
        let endpoint = origin.appendingPathComponent("api/v1/public/price-catalog")
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8
        if let cache = TokenPriceCatalogCache.load(at: file, origin: origin) {
            request.setValue("\"" + cache.catalog.version + "\"", forHTTPHeaderField: "If-None-Match")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration, delegate: PriceCatalogRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == endpoint else { return false }
            if http.statusCode == 304 { return false }
            guard http.statusCode == 200,
                  response.expectedContentLength <= Int64(ServerTokenPriceCatalog.maximumBytes) else { return false }
            var data = Data()
            for try await byte in stream {
                guard data.count < ServerTokenPriceCatalog.maximumBytes else { return false }
                data.append(byte)
            }
            return try TokenPriceCatalogCache.save(data, origin: origin, at: file)
        } catch {
            // Offline, stale and invalid responses keep the last valid catalog.
            return false
        }
    }
}
