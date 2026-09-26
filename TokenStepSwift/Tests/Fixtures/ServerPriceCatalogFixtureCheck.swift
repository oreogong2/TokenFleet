import Foundation

@main
struct ServerPriceCatalogFixtureCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("expected golden fixture and isolated root") }
        let payload = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let origin = URL(string: "https://community.example.com")!
        let catalog = try ServerTokenPriceCatalog.decode(payload)
        let context = TokenPriceCatalogCache.Context(origin: origin.absoluteString, catalog: catalog)
        let file = root.appendingPathComponent("price-cache.json")
        try expect(TokenPriceCatalogCache.save(payload, origin: origin, at: file), "initial catalog save")
        try expect(!TokenPriceCatalogCache.save(payload, origin: origin, at: file), "retry must be idempotent")
        let before = try Data(contentsOf: file)
        for changes: [String: Any] in [["revision": 1], ["prices": []], ["schema_version": 2]] {
            do { _ = try TokenPriceCatalogCache.save(replacing(payload, changes), origin: origin, at: file)
                throw failure("invalid or older catalog accepted")
            } catch is TokenPriceCatalogError { }
            try expect(Data(contentsOf: file) == before, "rejected response changed offline cache")
        }
        try expect(TokenPriceCatalogCache.load(at: file, origin: origin)?.catalog.version == catalog.version, "offline catalog lost")
        try expect(TokenPriceCatalogCache.load(at: file, origin: URL(string: "https://other.example.com")!) == nil, "cross-origin cache accepted")
        try expect(ServerTokenPriceCatalog.normalizeModel("openai/gpt_6_sol-20260102") == "gpt-6-sol", "model alias mismatch")
        try expect(ServerTokenPriceCatalog.normalizeModel("gpt-6-sol-20260230") == "gpt-6-sol-20260230", "invalid date stripped")
        for (tokens, expected) in [(1, 0.000002), (2, 0.000003), (3, 0.000005)] {
            let usage = TokenPricingUsage(inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0,
                cacheWriteTokens: 0, totalTokens: tokens, breakdownComplete: true)
            let estimate = catalog.estimate(tool: "Codex", model: "gpt-6-sol", usage: usage, date: "2026-09-26", pricingVersion: context.pricingVersion)
            try expect(abs((estimate?.costUSD ?? -1) - expected) < 0.00000001, "HALF_UP micro-unit mismatch")
            try expect(catalog.estimate(tool: "Codex", model: "router/gpt-6-sol", usage: usage, date: "2026-09-26", pricingVersion: context.pricingVersion) == nil, "arbitrary router guessed")
        }
        // Actual SQLite collection proves source invoice costs are not used.
        let db = root.appendingPathComponent("proxy.sqlite3")
        let sql = """
        CREATE TABLE proxy_request_logs (request_id TEXT, app_type TEXT, provider_id TEXT, model TEXT,
          request_model TEXT, pricing_model TEXT, input_tokens INTEGER, output_tokens INTEGER,
          cache_read_tokens INTEGER, cache_creation_tokens INTEGER, total_cost_usd TEXT,
          status_code INTEGER, created_at INTEGER, data_source TEXT, input_token_semantics INTEGER);
        INSERT INTO proxy_request_logs VALUES ('request-1','codex','fixture','gpt-6-sol','','',
          1000000,0,0,0,'99',200,1788177600,'proxy',1);
        """
        _ = try sqlite(db, sql)
        let snapshot = UsageCollector.collectCCSwitchProxyUsageSnapshot(databaseURL: db, pricing: context)
        try expect(snapshot.totals.tokens == 1_000_000, "Token counters changed")
        try expect(snapshot.totals.cost == 1.25, "source invoice overrides server estimate")
        try expect(snapshot.daily.first?.atomicUsage?.first?.model == "gpt-6-sol", "model key changed")
        try expect(sqlite(db, "SELECT total_cost_usd FROM proxy_request_logs;").trimmingCharacters(in: .whitespacesAndNewlines) == "99", "source invoice mutated")
        // Two records are rounded once after grouping, just like server ingestion.
        let project = root.appendingPathComponent("claude/project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var lines = [String]()
        for index in 1...2 {
            let row: [String: Any] = ["type": "assistant", "uuid": "round-\(index)", "timestamp": "2026-09-26T08:00:0\(index)Z",
                "message": ["id": "msg_round_\(index)", "model": "gpt-6-sol", "stop_reason": "end_turn",
                    "usage": ["input_tokens": 1, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0]]]
            lines.append(String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
        }
        try lines.joined(separator: "\n").write(to: project.appendingPathComponent("round.jsonl"), atomically: true, encoding: .utf8)
        let combined = UsageCollector.collectClaudeCodeUsageSnapshot(rootURL: root.appendingPathComponent("claude"), pricing: context)
        try expect(combined.totals.tokens == 2 && combined.totals.pricedTokens == 2, "bucket coverage mismatch")
        try expect(abs((combined.daily.first?.cost ?? -1) - 0.000003) < 0.00000001, "individual records were rounded before grouping")
        print("PASS: server catalog hash, dates, aliases, offline cache, HALF_UP buckets and retained source invoice")
    }

    static func replacing(_ payload: Data, _ changes: [String: Any]) throws -> Data {
        var body = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        body.removeValue(forKey: "version")
        body.merge(changes, uniquingKeysWith: { _, new in new })
        body["version"] = ServerTokenPriceCatalog.digest(try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]))
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func sqlite(_ db: URL, _ query: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path, query]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("fixture SQLite failed") }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "PriceCatalogFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw failure(message) }
    }
}
