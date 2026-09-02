import CryptoKit
import Foundation
import SQLite3

struct UsageCollectionFileState: Codable, Equatable {
    var path: String
    var size: UInt64
    var modificationTime: TimeInterval
}

struct UsageCollectionState: Codable, Equatable {
    var schemaVersion = 2
    var historyDays: Int
    var includesExperimentalAgentSources: Bool
    var windowDay: String
    var files: [UsageCollectionFileState]
}

struct CodexIncrementalCacheStats: Equatable {
    var generation: Int
    var sessions: Int
    var records: Int
    var lastLogicalWriteBytes: Int
}

struct CodexAccountingComparisonDiagnostics {
    var incrementalSnapshot: UsageSnapshot
    var referenceSnapshot: UsageSnapshot
    var mismatchedPathHashes: [String]
    var incrementalRecordCount: Int
    var referenceRecordCount: Int
}

struct CollectorSourcePerformance: Codable, Equatable {
    var source: String
    var elapsedMilliseconds: Int
    var files: Int
    var bytes: UInt64
    var status: String
    var skipped: Bool

    enum CodingKeys: String, CodingKey {
        case source
        case elapsedMilliseconds = "elapsed_ms"
        case files
        case bytes
        case status
        case skipped
    }
}

final class CollectorPerformanceRecorder {
    private(set) var sources = [CollectorSourcePerformance]()

    fileprivate func measure(
        source: String,
        operation: () -> CollectorResult
    ) -> CollectorResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = operation()
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        sources.append(
            CollectorSourcePerformance(
                source: source,
                elapsedMilliseconds: max(0, Int((elapsed * 1_000).rounded())),
                files: max(0, result.source.files ?? 0),
                bytes: result.inputBytes,
                status: result.source.status ?? "unknown",
                skipped: false
            )
        )
        return result
    }

    func recordSkippedSources(_ sourceInfo: [String: SourceInfo]) {
        sources = sourceInfo.keys.sorted().map { source in
            let info = sourceInfo[source]!
            return CollectorSourcePerformance(
                source: source,
                elapsedMilliseconds: 0,
                files: max(0, info.files ?? 0),
                bytes: 0,
                status: info.status ?? "unknown",
                skipped: true
            )
        }
    }

    #if TOKENSTEP_TESTING
    func measureForTests(
        source: String,
        inputURLs: [URL],
        status: String = "ok"
    ) {
        _ = measure(source: source) {
            CollectorResult(
                records: [],
                source: SourceInfo(status: status, files: inputURLs.count, records: 0),
                inputURLs: inputURLs
            )
        }
    }
    #endif
}

struct CollectorRunPerformanceLog: Codable, Equatable {
    var event = "collector_run"
    var finishedAt: String
    var outcome: String
    var totalElapsedMilliseconds: Int
    var peakRSSBytes: UInt64
    var sources: [CollectorSourcePerformance]

    enum CodingKeys: String, CodingKey {
        case event
        case finishedAt = "finished_at"
        case outcome
        case totalElapsedMilliseconds = "total_elapsed_ms"
        case peakRSSBytes = "peak_rss_bytes"
        case sources
    }
}

enum CollectorPerformanceLogger {
    static let filename = "collector-performance.jsonl"
    private static let maximumLogBytes: UInt64 = 2 * 1_024 * 1_024
    private static let retainedLineCount = 500

    static func append(
        outcome: String,
        totalElapsedMilliseconds: Int,
        peakRSSBytes: UInt64,
        sources: [CollectorSourcePerformance],
        finishedAt: Date = Date(),
        logURL: URL = AppPaths.logs.appendingPathComponent(filename)
    ) throws {
        let line = try encodedLine(
            outcome: outcome,
            totalElapsedMilliseconds: totalElapsedMilliseconds,
            peakRSSBytes: peakRSSBytes,
            sources: sources,
            finishedAt: finishedAt
        )
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
        try trimIfNeeded(logURL: logURL)
    }

    static func encodedLine(
        outcome: String,
        totalElapsedMilliseconds: Int,
        peakRSSBytes: UInt64,
        sources: [CollectorSourcePerformance],
        finishedAt: Date
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let report = CollectorRunPerformanceLog(
            finishedAt: formatter.string(from: finishedAt),
            outcome: outcome,
            totalElapsedMilliseconds: max(0, totalElapsedMilliseconds),
            peakRSSBytes: peakRSSBytes,
            sources: sources
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(report)
        data.append(0x0A)
        return data
    }

    private static func trimIfNeeded(logURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        guard let size = attributes[.size] as? NSNumber,
              size.uint64Value > maximumLogBytes
        else {
            return
        }

        let lines = try Data(contentsOf: logURL).split(separator: 0x0A)
        var retained = Data()
        for line in lines.suffix(retainedLineCount) {
            retained.append(contentsOf: line)
            retained.append(0x0A)
        }
        try retained.write(to: logURL, options: .atomic)
    }
}

enum UsageCollector {
    static let codexAccountingRevision = 8

    private static let timezone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    private static let maxRelevantLineBytes = 1_048_576
    private static let ccSwitchSourceName = "CC Switch Proxy"

    static func collect(
        historyDays: Int = TokenStepSettings.defaults.historyDays,
        includeCCSwitchProxyUsage: Bool = true,
        ccSwitchDatabaseURL: URL? = nil,
        includeExperimentalAgentSources: Bool = false,
        zCodeDatabaseURL: URL? = nil,
        hermesDatabaseURL: URL? = nil,
        workBuddyRootURLs: [URL]? = nil,
        codeBuddyRootURLs: [URL]? = nil,
        qoderRootURL: URL? = nil,
        kimiCodeRootURL: URL? = nil,
        openCodeRootURL: URL? = nil,
        grokBuildRootURL: URL? = nil,
        qwenCodeRootURL: URL? = nil,
        cursorUsageImportURL: URL? = nil,
        clineRootURLs: [URL]? = nil,
        copilotDatabaseURL: URL? = nil,
        copilotOTelURLs: [URL]? = nil,
        antigravityRootURLs: [URL]? = nil,
        droidRootURL: URL? = nil,
        dshRootURL: URL? = nil,
        piSessionsRootURL: URL? = nil,
        openClawRootURLs: [URL]? = nil,
        forceFullValidation: Bool = false,
        performanceRecorder: CollectorPerformanceRecorder? = nil
    ) -> UsageSnapshot {
        func measured(_ source: String, _ operation: () -> CollectorResult) -> CollectorResult {
            guard let performanceRecorder else { return operation() }
            return performanceRecorder.measure(source: source, operation: operation)
        }

        let cacheLoad = loadCache()
        var cache = cacheLoad.cache
        var livePaths = Set<String>()
        let sourceCutoff = sourceFileCutoffDate(historyDays: historyDays)
        var ccSwitch = measured(ccSwitchSourceName) {
            includeCCSwitchProxyUsage
                ? collectCCSwitchProxyUsage(databaseURL: ccSwitchDatabaseURL)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        var usedIncrementalStore = false
        let collectedCodex = measured("Codex") {
            let outcome = collectCodex(
                cache: &cache,
                livePaths: &livePaths,
                modifiedSince: sourceCutoff,
                databaseURL: AppPaths.codexIncrementalCacheSQLite,
                forceFullValidation: forceFullValidation,
                requiresDetailedRecords: !ccSwitch.records.isEmpty
            )
            usedIncrementalStore = outcome.usedIncrementalStore
            return outcome.result
        }
        var codex = collectedCodex
        codex.source.recalibratedFromRevision = cacheLoad.recalibratedFromRevision
        let claude = measured("Claude Code") {
            collectClaudeCode(cache: &cache, livePaths: &livePaths, modifiedSince: sourceCutoff)
        }
        let zCode = measured("ZCode") {
            includeExperimentalAgentSources
                ? collectZCodeUsage(databaseURL: zCodeDatabaseURL)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let hermes = measured("Hermes Agent") {
            includeExperimentalAgentSources
                ? collectHermesUsage(databaseURL: hermesDatabaseURL, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let workBuddy = measured("WorkBuddy") {
            includeExperimentalAgentSources
                ? collectWorkBuddyUsage(rootURLs: workBuddyRootURLs, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let codeBuddy = measured("CodeBuddy") {
            includeExperimentalAgentSources
                ? collectCodeBuddyUsage(rootURLs: codeBuddyRootURLs, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let qoder = measured("Qoder") {
            includeExperimentalAgentSources
                ? collectQoderUsage(rootURL: qoderRootURL, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let kimi = measured("Kimi") {
            includeExperimentalAgentSources
                ? collectKimiCodeUsage(rootURL: kimiCodeRootURL, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let openCode = measured("OpenCode") {
            includeExperimentalAgentSources
                ? collectOpenCodeUsage(rootURL: openCodeRootURL)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let grok = measured("Grok") {
            includeExperimentalAgentSources
                ? collectGrokBuildUsage(rootURL: grokBuildRootURL, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let qwen = measured("Qwen Code") {
            includeExperimentalAgentSources
                ? collectQwenCodeUsage(rootURL: qwenCodeRootURL, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let cursor = measured("Cursor") {
            includeExperimentalAgentSources
                ? collectCursorUsage(importURL: cursorUsageImportURL)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let cline = measured("Cline") {
            includeExperimentalAgentSources
                ? collectClineUsage(rootURLs: clineRootURLs, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let copilot = measured("Copilot CLI") {
            includeExperimentalAgentSources
                ? collectCopilotCLIUsage(databaseURL: copilotDatabaseURL)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        var copilotOTel = measured("Copilot OTel") {
            includeExperimentalAgentSources
                ? collectCopilotOTelUsage(urls: copilotOTelURLs, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        preferCopilotSessionStore(sessionStore: copilot, otel: &copilotOTel)
        let antigravity = measured("Antigravity") {
            includeExperimentalAgentSources
                ? collectAntigravityUsage(rootURLs: antigravityRootURLs, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let droid = measured("Droid") {
            includeExperimentalAgentSources
                ? collectDroidUsage(rootURL: droidRootURL, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let dsh = measured("dsh") {
            includeExperimentalAgentSources
                ? collectDSHUsage(rootURL: dshRootURL, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let pi = measured("Pi") {
            includeExperimentalAgentSources
                ? collectPiUsage(sessionsRootURL: piSessionsRootURL, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        let openClaw = measured("OpenClaw") {
            includeExperimentalAgentSources
                ? collectOpenClawUsage(rootURLs: openClawRootURLs, modifiedSince: sourceCutoff)
                : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        }
        if usedIncrementalStore {
            cache.files = cache.files.filter { $0.value.tool != "Codex" && livePaths.contains($0.key) }
        } else {
            cache.files = cache.files.filter { livePaths.contains($0.key) }
        }
        saveCache(cache)

        let nativeRecords = codex.records + claude.records
        let deduped = deduplicateCrossSource(
            nativeRecords: nativeRecords,
            proxyRecords: ccSwitch.records
        )
        if includeCCSwitchProxyUsage {
            ccSwitch.source = sourceInfo(ccSwitch.source, annotatedWith: deduped)
        }
        let records = recordsInHistoryWindow(
            deduped.records + zCode.records + hermes.records + workBuddy.records + codeBuddy.records + qoder.records + kimi.records + openCode.records + grok.records + qwen.records + cursor.records + cline.records + copilot.records + copilotOTel.records + antigravity.records + droid.records + dsh.records + pi.records + openClaw.records,
            historyDays: historyDays,
            now: Date()
        )
        return aggregate(
            records: records,
            sources: [
                "Codex": codex.source,
                "Claude Code": claude.source,
                ccSwitchSourceName: ccSwitch.source,
                "ZCode": zCode.source,
                "Hermes Agent": hermes.source,
                "WorkBuddy": workBuddy.source,
                "CodeBuddy": codeBuddy.source,
                "Qoder": qoder.source,
                "Kimi": kimi.source,
                "OpenCode": openCode.source,
                "Grok": grok.source,
                "Qwen Code": qwen.source,
                "Cursor": cursor.source,
                "Cline": cline.source,
                "Copilot CLI": copilot.source,
                "Copilot OTel": copilotOTel.source,
                "Antigravity": antigravity.source,
                "Droid": droid.source,
                "dsh": dsh.source,
                "Pi": pi.source,
                "OpenClaw": openClaw.source
            ]
        )
    }

    static func collectionState(
        historyDays: Int,
        includeExperimentalAgentSources: Bool,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) -> UsageCollectionState {
        let cutoff = sourceFileCutoffDate(historyDays: historyDays)
        var urls = defaultCodexSessionRoots(homeURL: homeURL)
            .flatMap { jsonlFiles(under: $0, modifiedSince: cutoff) }
        urls.append(contentsOf: jsonlFiles(
            under: homeURL.appendingPathComponent(".claude/projects", isDirectory: true),
            modifiedSince: cutoff
        ))

        let databases = [
            homeURL.appendingPathComponent(".codex/state_5.sqlite"),
            homeURL.appendingPathComponent(".codex/sqlite/state_5.sqlite"),
            homeURL.appendingPathComponent(".cc-switch/cc-switch.db")
        ]
        urls.append(contentsOf: existingDatabaseFiles(databases))

        if includeExperimentalAgentSources {
            let dshRoot = dshDefaultSessionsRoot(homeURL: homeURL)
            urls.append(contentsOf: existingDatabaseFiles([
                homeURL.appendingPathComponent(".zcode/cli/db/db.sqlite"),
                homeURL.appendingPathComponent(".hermes/state.db"),
                copilotCLIDefaultDatabase(homeURL: homeURL)
            ]))
            urls.append(contentsOf: openCodeDatabaseURLs(
                rootURL: homeURL.appendingPathComponent(".local/share/opencode", isDirectory: true)
            ).flatMap { existingDatabaseFiles([$0]) })
            urls.append(contentsOf: [
                homeURL.appendingPathComponent(".workbuddy/projects", isDirectory: true),
                homeURL.appendingPathComponent("Library/Application Support/WorkBuddyExtension", isDirectory: true),
                homeURL.appendingPathComponent(".codebuddy/projects", isDirectory: true),
                homeURL.appendingPathComponent(".codebuddy/sessions", isDirectory: true),
                homeURL.appendingPathComponent(".qoder/projects", isDirectory: true),
                homeURL.appendingPathComponent(".kimi-code/sessions", isDirectory: true),
                grokBuildDefaultRoot(homeURL: homeURL).appendingPathComponent("sessions", isDirectory: true),
                qwenCodeDefaultRoot(homeURL: homeURL).appendingPathComponent("usage", isDirectory: true)
            ].flatMap { jsonlFiles(under: $0, modifiedSince: cutoff) })
            urls.append(contentsOf: [
                homeURL.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true),
                homeURL.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true),
                homeURL.appendingPathComponent(".gemini/antigravity-ide/brain", isDirectory: true),
                homeURL.appendingPathComponent(".factory/projects", isDirectory: true),
                dshRoot
            ].flatMap { usageLogFiles(at: $0, modifiedSince: cutoff) })
            urls.append(contentsOf: copilotOTelDefaultURLs(homeURL: homeURL)
                .flatMap { usageLogFiles(at: $0, modifiedSince: cutoff) })
            urls.append(contentsOf: compressedDSHFiles(
                under: dshRoot,
                modifiedSince: cutoff
            ))
            if FileManager.default.fileExists(atPath: AppPaths.cursorUsageImportJSON.path) {
                urls.append(AppPaths.cursorUsageImportJSON)
            }
            urls.append(contentsOf: clineUsageFiles(
                roots: clineDefaultRoots(homeURL: homeURL),
                modifiedSince: cutoff
            ))
            urls.append(contentsOf: jsonlFiles(
                under: piDefaultSessionsRoot(homeURL: homeURL),
                modifiedSince: cutoff
            ))
            let openClawRoots = openClawDefaultRoots(homeURL: homeURL)
            urls.append(contentsOf: openClawDatabaseFiles(roots: openClawRoots))
            urls.append(contentsOf: openClawTranscriptFiles(
                roots: openClawRoots,
                modifiedSince: cutoff
            ))
        }

        let files = Dictionary(grouping: urls, by: \.path)
            .compactMap { _, duplicates in duplicates.first.flatMap(collectionFileState) }
            .sorted { $0.path < $1.path }
        return UsageCollectionState(
            historyDays: historyDays,
            includesExperimentalAgentSources: includeExperimentalAgentSources,
            windowDay: dayFormatter.string(from: now),
            files: files
        )
    }

    static func codexIncrementalCacheStatsForTests(databaseURL: URL) -> CodexIncrementalCacheStats? {
        try? CodexIncrementalStore(url: databaseURL).stats()
    }

    static func codexCollectionStateForTests(
        homeURL: URL
    ) -> [UsageCollectionFileState] {
        defaultCodexSessionRoots(homeURL: homeURL)
            .flatMap { jsonlFiles(under: $0, modifiedSince: nil) }
            .compactMap(collectionFileState)
            .sorted { $0.path < $1.path }
    }

    static func compareIncrementalCodexAccountingForTests(
        homeURL: URL,
        databaseURL: URL
    ) throws -> CodexAccountingComparisonDiagnostics {
        let incremental = try collectCodexIncrementally(
            modifiedSince: nil,
            databaseURL: databaseURL,
            forceFullValidation: false,
            homeURL: homeURL,
            requiresDetailedRecords: true
        )
        var cache = CollectorCache()
        var livePaths = Set<String>()
        let reference = collectCodexFromJSONL(
            cache: &cache,
            livePaths: &livePaths,
            modifiedSince: nil,
            homeURL: homeURL
        )

        return try accountingComparisonDiagnostics(
            incremental: incremental,
            reference: reference
        )
    }

    static func compareLegacyMigrationCodexAccountingForTests(
        homeURL: URL,
        databaseURL: URL
    ) throws -> CodexAccountingComparisonDiagnostics {
        var legacyCache = CollectorCache()
        var livePaths = Set<String>()
        let reference = collectCodexFromJSONL(
            cache: &legacyCache,
            livePaths: &livePaths,
            modifiedSince: nil,
            homeURL: homeURL
        )
        let incremental = try collectCodexIncrementally(
            modifiedSince: nil,
            databaseURL: databaseURL,
            forceFullValidation: false,
            homeURL: homeURL,
            requiresDetailedRecords: true,
            legacyCache: legacyCache
        )
        return try accountingComparisonDiagnostics(
            incremental: incremental,
            reference: reference
        )
    }

    private static func accountingComparisonDiagnostics(
        incremental: CollectorResult,
        reference: CollectorResult
    ) throws -> CodexAccountingComparisonDiagnostics {
        let incrementalByPath = Dictionary(grouping: incremental.records) {
            $0.sourcePath ?? "<missing>"
        }
        let referenceByPath = Dictionary(grouping: reference.records) {
            $0.sourcePath ?? "<missing>"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let paths = Set(incrementalByPath.keys).union(referenceByPath.keys)
        let mismatches = try paths.compactMap { path -> String? in
            let incrementalData = try encoder.encode(incrementalByPath[path] ?? [])
            let referenceData = try encoder.encode(referenceByPath[path] ?? [])
            return incrementalData == referenceData ? nil : anonymousPathHash(path)
        }.sorted()

        return CodexAccountingComparisonDiagnostics(
            incrementalSnapshot: aggregate(
                records: incremental.records,
                sources: ["Codex": incremental.source]
            ),
            referenceSnapshot: aggregate(
                records: reference.records,
                sources: ["Codex": reference.source]
            ),
            mismatchedPathHashes: mismatches,
            incrementalRecordCount: incremental.records.count,
            referenceRecordCount: reference.records.count
        )
    }

    private static func anonymousPathHash(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func existingDatabaseFiles(_ databases: [URL]) -> [URL] {
        databases.flatMap { database in
            [
                database,
                URL(fileURLWithPath: database.path + "-wal")
            ].filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private static func collectionFileState(_ url: URL) -> UsageCollectionFileState? {
        guard let metadata = fileMetadata(for: url) else { return nil }
        return UsageCollectionFileState(
            path: url.standardizedFileURL.path,
            size: metadata.size,
            modificationTime: metadata.modificationTime
        )
    }

    static func collectCCSwitchProxyUsageSnapshot(databaseURL: URL) -> UsageSnapshot {
        let result = collectCCSwitchProxyUsage(databaseURL: databaseURL)
        return aggregate(
            records: result.records,
            sources: [ccSwitchSourceName: result.source]
        )
    }

    static func collectClaudeCodeUsageSnapshot(rootURL: URL) -> UsageSnapshot {
        var cache = CollectorCache()
        var livePaths = Set<String>()
        let result = collectClaudeCode(cache: &cache, livePaths: &livePaths, rootURL: rootURL, modifiedSince: nil)
        return aggregate(records: result.records, sources: ["Claude Code": result.source])
    }

    static func collectCodexUsageSnapshotForTests(
        homeURL: URL,
        cacheURL: URL? = nil,
        forceFullValidation: Bool = false,
        requiresDetailedRecords: Bool = false
    ) -> UsageSnapshot {
        if let cacheURL {
            do {
                let result = try collectCodexIncrementally(
                modifiedSince: nil,
                databaseURL: cacheURL,
                forceFullValidation: forceFullValidation,
                homeURL: homeURL,
                requiresDetailedRecords: requiresDetailedRecords
                )
                return aggregate(records: result.records, sources: ["Codex": result.source])
            } catch {
                return aggregate(
                    records: [],
                    sources: ["Codex": SourceInfo(status: "incremental_cache_error", files: 0, records: 0)]
                )
            }
        }
        var cache = CollectorCache()
        var livePaths = Set<String>()
        let result = collectCodexFromJSONL(
            cache: &cache,
            livePaths: &livePaths,
            modifiedSince: nil,
            homeURL: homeURL
        )
        return aggregate(records: result.records, sources: ["Codex": result.source])
    }

    static func collectIncrementalCodexAndProxySnapshotForTests(
        codexRoots: [URL],
        cacheURL: URL,
        ccSwitchDatabaseURL: URL
    ) -> UsageSnapshot {
        let codex: CollectorResult
        do {
            codex = try collectCodexIncrementally(
                modifiedSince: nil,
                databaseURL: cacheURL,
                forceFullValidation: false,
                requiresDetailedRecords: true,
                roots: codexRoots
            )
        } catch {
            codex = CollectorResult(
                records: [],
                source: SourceInfo(status: "incremental_cache_error", files: 0, records: 0)
            )
        }
        var proxy = collectCCSwitchProxyUsage(databaseURL: ccSwitchDatabaseURL)
        let deduped = deduplicateCrossSource(
            nativeRecords: codex.records,
            proxyRecords: proxy.records
        )
        proxy.source = sourceInfo(proxy.source, annotatedWith: deduped)
        return aggregate(
            records: deduped.records,
            sources: [
                "Codex": codex.source,
                ccSwitchSourceName: proxy.source
            ]
        )
    }

    static func collectCodexWithIncrementalFallbackForTests(
        homeURL: URL,
        cacheURL: URL
    ) -> UsageSnapshot {
        var cache = CollectorCache()
        var livePaths = Set<String>()
        let outcome = collectCodex(
            cache: &cache,
            livePaths: &livePaths,
            modifiedSince: nil,
            databaseURL: cacheURL,
            forceFullValidation: false,
            requiresDetailedRecords: false,
            homeURL: homeURL
        )
        return aggregate(
            records: outcome.result.records,
            sources: ["Codex": outcome.result.source]
        )
    }

    static func collectorCacheRecalibrationRevisionForTests(cacheURL: URL) -> Int? {
        loadCache(at: cacheURL).recalibratedFromRevision
    }

    static func collectUsageSnapshotForTests(
        codexRoots: [URL] = [],
        claudeRootURL: URL? = nil,
        ccSwitchDatabaseURL: URL? = nil,
        zCodeDatabaseURL: URL? = nil,
        hermesDatabaseURL: URL? = nil,
        workBuddyRootURLs: [URL]? = nil,
        codeBuddyRootURLs: [URL]? = nil,
        qoderRootURL: URL? = nil,
        kimiCodeRootURL: URL? = nil,
        openCodeRootURL: URL? = nil,
        grokBuildRootURL: URL? = nil,
        qwenCodeRootURL: URL? = nil,
        cursorUsageImportURL: URL? = nil,
        clineRootURLs: [URL]? = nil,
        copilotDatabaseURL: URL? = nil,
        copilotOTelURLs: [URL]? = nil,
        antigravityRootURLs: [URL]? = nil,
        droidRootURL: URL? = nil,
        dshRootURL: URL? = nil,
        dshZstdExecutableURL: URL? = nil,
        dshDiscoverZstdDecoder: Bool = true,
        piSessionsRootURL: URL? = nil,
        openClawRootURLs: [URL]? = nil,
        includeExperimentalAgentSources: Bool = false,
        historyDays: Int? = nil,
        now: Date = Date()
    ) -> UsageSnapshot {
        let sourceCutoff = historyDays.flatMap {
            sourceFileCutoffDate(historyDays: $0, now: now)
        }
        var cache = CollectorCache()
        var livePaths = Set<String>()
        let codex = codexRoots.isEmpty
            ? CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
            : collectCodexFromJSONL(
                cache: &cache,
                livePaths: &livePaths,
                modifiedSince: nil,
                roots: codexRoots
            )
        let claude = claudeRootURL.map {
            collectClaudeCode(cache: &cache, livePaths: &livePaths, rootURL: $0, modifiedSince: nil)
        } ?? CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        var ccSwitch = ccSwitchDatabaseURL.map {
            collectCCSwitchProxyUsage(databaseURL: $0)
        } ?? CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let zCode = includeExperimentalAgentSources
            ? zCodeDatabaseURL.map { collectZCodeUsage(databaseURL: $0) } ?? CollectorResult(records: [], source: SourceInfo(status: "missing_db", files: 0, records: 0))
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let hermes = includeExperimentalAgentSources
            ? hermesDatabaseURL.map {
                collectHermesUsage(databaseURL: $0, modifiedSince: sourceCutoff)
            } ?? CollectorResult(records: [], source: SourceInfo(status: "missing_db", files: 0, records: 0))
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let workBuddy = includeExperimentalAgentSources
            ? collectWorkBuddyUsage(rootURLs: workBuddyRootURLs ?? [], modifiedSince: nil)
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let codeBuddy = includeExperimentalAgentSources
            ? collectCodeBuddyUsage(rootURLs: codeBuddyRootURLs ?? [], modifiedSince: nil)
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let qoder = includeExperimentalAgentSources
            ? qoderRootURL.map { collectQoderUsage(rootURL: $0, modifiedSince: nil) }
                ?? CollectorResult(records: [], source: SourceInfo(status: "missing", files: 0, records: 0))
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let kimi = includeExperimentalAgentSources
            ? kimiCodeRootURL.map { collectKimiCodeUsage(rootURL: $0, modifiedSince: nil) }
                ?? CollectorResult(records: [], source: SourceInfo(status: "missing", files: 0, records: 0))
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let openCode = includeExperimentalAgentSources
            ? openCodeRootURL.map { collectOpenCodeUsage(rootURL: $0) }
                ?? CollectorResult(records: [], source: SourceInfo(status: "missing", files: 0, records: 0))
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let grok = includeExperimentalAgentSources
            ? grokBuildRootURL.map { collectGrokBuildUsage(rootURL: $0, modifiedSince: nil) }
                ?? CollectorResult(records: [], source: SourceInfo(status: "missing", files: 0, records: 0))
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let qwen = includeExperimentalAgentSources
            ? qwenCodeRootURL.map { collectQwenCodeUsage(rootURL: $0, modifiedSince: nil) }
                ?? CollectorResult(records: [], source: SourceInfo(status: "missing", files: 0, records: 0))
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let cursor = includeExperimentalAgentSources
            ? collectCursorUsage(importURL: cursorUsageImportURL)
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let cline = includeExperimentalAgentSources
            ? collectClineUsage(rootURLs: clineRootURLs ?? [], modifiedSince: nil)
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let copilot = includeExperimentalAgentSources
            ? copilotDatabaseURL.map { collectCopilotCLIUsage(databaseURL: $0) }
                ?? CollectorResult(records: [], source: SourceInfo(status: "missing_db", files: 0, records: 0))
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        var copilotOTel = includeExperimentalAgentSources
            ? collectCopilotOTelUsage(urls: copilotOTelURLs ?? [], modifiedSince: nil)
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        preferCopilotSessionStore(sessionStore: copilot, otel: &copilotOTel)
        let antigravity = includeExperimentalAgentSources
            ? collectAntigravityUsage(rootURLs: antigravityRootURLs ?? [], modifiedSince: nil)
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let droid = includeExperimentalAgentSources
            ? droidRootURL.map { collectDroidUsage(rootURL: $0, modifiedSince: nil) }
                ?? CollectorResult(records: [], source: SourceInfo(status: "missing", files: 0, records: 0))
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let dsh = includeExperimentalAgentSources
            ? dshRootURL.map {
                collectDSHUsage(
                    rootURL: $0,
                    modifiedSince: nil,
                    zstdExecutableURLOverride: dshZstdExecutableURL,
                    discoverZstdDecoder: dshDiscoverZstdDecoder
                )
            }
                ?? CollectorResult(records: [], source: SourceInfo(status: "missing", files: 0, records: 0))
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let pi = includeExperimentalAgentSources
            ? piSessionsRootURL.map { collectPiUsage(sessionsRootURL: $0, modifiedSince: nil) }
                ?? CollectorResult(records: [], source: SourceInfo(status: "missing", files: 0, records: 0))
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let openClaw = includeExperimentalAgentSources
            ? collectOpenClawUsage(rootURLs: openClawRootURLs ?? [], modifiedSince: nil)
            : CollectorResult(records: [], source: SourceInfo(status: "disabled", files: nil, records: 0))
        let deduped = deduplicateCrossSource(
            nativeRecords: codex.records + claude.records,
            proxyRecords: ccSwitch.records
        )
        ccSwitch.source = sourceInfo(ccSwitch.source, annotatedWith: deduped)
        let allRecords = deduped.records + zCode.records + hermes.records + workBuddy.records + codeBuddy.records + qoder.records + kimi.records + openCode.records + grok.records + qwen.records + cursor.records + cline.records + copilot.records + copilotOTel.records + antigravity.records + droid.records + dsh.records + pi.records + openClaw.records
        let records = historyDays.map {
            recordsInHistoryWindow(allRecords, historyDays: $0, now: now)
        } ?? allRecords
        return aggregate(
            records: records,
            sources: [
                "Codex": codex.source,
                "Claude Code": claude.source,
                ccSwitchSourceName: ccSwitch.source,
                "ZCode": zCode.source,
                "Hermes Agent": hermes.source,
                "WorkBuddy": workBuddy.source,
                "CodeBuddy": codeBuddy.source,
                "Qoder": qoder.source,
                "Kimi": kimi.source,
                "OpenCode": openCode.source,
                "Grok": grok.source,
                "Qwen Code": qwen.source,
                "Cursor": cursor.source,
                "Cline": cline.source,
                "Copilot CLI": copilot.source,
                "Copilot OTel": copilotOTel.source,
                "Antigravity": antigravity.source,
                "Droid": droid.source,
                "dsh": dsh.source,
                "Pi": pi.source,
                "OpenClaw": openClaw.source
            ]
        )
    }

    private static func collectCodex(
        cache: inout CollectorCache,
        livePaths: inout Set<String>,
        modifiedSince cutoffDate: Date?,
        databaseURL: URL,
        forceFullValidation: Bool,
        requiresDetailedRecords: Bool,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexCollectionOutcome {
        func runIncremental() throws -> CollectorResult {
            try collectCodexIncrementally(
                modifiedSince: cutoffDate,
                databaseURL: databaseURL,
                forceFullValidation: forceFullValidation,
                homeURL: homeURL,
                requiresDetailedRecords: requiresDetailedRecords,
                legacyCache: cache
            )
        }

        do {
            let incremental = try runIncremental()
            if incremental.source.status == "ok" {
                return CodexCollectionOutcome(result: incremental, usedIncrementalStore: true)
            }
        } catch {
            if let cacheError = error as? CodexIncrementalStoreError,
               cacheError.shouldRebuildCache {
                CodexIncrementalStore.discardDatabase(at: databaseURL)
                if let rebuilt = try? runIncremental(), rebuilt.source.status == "ok" {
                    return CodexCollectionOutcome(result: rebuilt, usedIncrementalStore: true)
                }
            }
        }

        let jsonlResult = collectCodexFromJSONL(
            cache: &cache,
            livePaths: &livePaths,
            modifiedSince: cutoffDate,
            homeURL: homeURL
        )
        if jsonlResult.source.status == "ok" {
            return CodexCollectionOutcome(result: jsonlResult, usedIncrementalStore: false)
        }
        return CodexCollectionOutcome(
            result: collectCodexFromSQLite() ?? jsonlResult,
            usedIncrementalStore: false
        )
    }

    private static func collectCodexIncrementally(
        modifiedSince cutoffDate: Date?,
        databaseURL: URL,
        forceFullValidation: Bool,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        requiresDetailedRecords: Bool = false,
        legacyCache: CollectorCache? = nil,
        roots: [URL]? = nil
    ) throws -> CollectorResult {
        let paths = (roots ?? defaultCodexSessionRoots(homeURL: homeURL))
            .flatMap { jsonlFiles(under: $0, modifiedSince: cutoffDate) }
            .sorted { $0.path < $1.path }
        guard !paths.isEmpty else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "missing", files: 0, records: 0)
            )
        }

        let store = try CodexIncrementalStore(url: databaseURL)
        let storedMetadata = try store.metadataByPath()
        let currentPaths = Set(paths.map(\.path))
        let deletedPaths = Set(storedMetadata.keys).subtracting(currentPaths)
        var fullyAffectedParentIDs = Set(
            deletedPaths.compactMap { storedMetadata[$0]?.sessionID }
        )
        var appendedParentAnchorThresholds = [String: TimeInterval]()
        var stagedPaths = Set<String>()
        try store.beginStaging()
        var committed = false
        defer {
            if !committed {
                store.abortStaging()
            }
        }

        func validatedScan(
            at path: URL,
            metadata: (size: UInt64, modificationTime: TimeInterval)
        ) throws -> PendingCodexSession {
            if !forceFullValidation,
               let legacyCache,
               let scan = cachedCodexScan(for: path, cache: legacyCache),
               let fingerprint = contentFingerprint(for: path, size: metadata.size) {
                return PendingCodexSession(
                    path: path,
                    metadata: metadata,
                    fingerprint: fingerprint,
                    scan: scan
                )
            }

            guard var stable = stableCodexScan(at: path) else {
                throw CodexIncrementalStoreError.unstableSource(path.path)
            }
            if !stable.isStable, let retry = stableCodexScan(at: path) {
                stable = retry
            }
            guard stable.isStable,
                  let fingerprint = contentFingerprint(for: path, size: stable.metadata.size)
            else {
                throw CodexIncrementalStoreError.unstableSource(path.path)
            }
            return PendingCodexSession(
                path: path,
                metadata: stable.metadata,
                fingerprint: fingerprint,
                scan: stable.scan
            )
        }

        for path in paths {
            guard let metadata = fileMetadata(for: path) else { continue }
            let stored = storedMetadata[path.path]
            var validatedFullFingerprint: String?
            let metadataMatches = stored?.size == metadata.size
                && abs((stored?.modificationTime ?? -1) - metadata.modificationTime) < 0.001
            if metadataMatches {
                if !forceFullValidation {
                    continue
                }
                let fingerprint = contentFingerprint(for: path, size: metadata.size)
                if fingerprint == stored?.fingerprint {
                    guard let fullFingerprint = fullContentFingerprint(
                        for: path,
                        size: metadata.size
                    ),
                    let afterValidation = fileMetadata(for: path),
                    UsageCollector.metadata(metadata, matches: afterValidation)
                    else {
                        throw CodexIncrementalStoreError.unstableSource(path.path)
                    }
                    if fullFingerprint == stored?.validationFingerprint {
                        continue
                    }
                    validatedFullFingerprint = fullFingerprint
                }
            }

            if !forceFullValidation,
               let stored,
               metadata.size > stored.size,
               contentFingerprint(for: path, size: stored.size) == stored.fingerprint,
               let cachedSession = try store.session(path: path.path),
               let appended = incrementalCodexAppend(at: path, cached: cachedSession) {
                try store.stage(session: appended)
                if let earliestNewAnchor = appended.anchors
                    .dropFirst(cachedSession.anchors.count)
                    .first?.timestamp {
                    appendedParentAnchorThresholds[appended.sessionID] = min(
                        appendedParentAnchorThresholds[appended.sessionID] ?? earliestNewAnchor,
                        earliestNewAnchor
                    )
                }
                continue
            }

            var pending = try validatedScan(at: path, metadata: metadata)
            if validatedFullFingerprint != nil {
                pending.validationFingerprint = validatedFullFingerprint
            } else if forceFullValidation, stored != nil, metadataMatches {
                guard let fullFingerprint = fullContentFingerprint(
                    for: path,
                    size: pending.metadata.size
                ),
                let afterValidation = fileMetadata(for: path),
                UsageCollector.metadata(pending.metadata, matches: afterValidation)
                else {
                    throw CodexIncrementalStoreError.unstableSource(path.path)
                }
                pending.validationFingerprint = fullFingerprint
            }
            try store.stage(
                scan: pending,
                anchors: codexAnchors(for: pending.scan),
                createdAtEpoch: pending.scan.createdAt.flatMap(parseISO)?.timeIntervalSince1970
            )
            stagedPaths.insert(path.path)
            fullyAffectedParentIDs.insert(pending.scan.canonicalSessionID)
            if let previousID = stored?.sessionID {
                fullyAffectedParentIDs.insert(previousID)
            }
        }

        func stageChild(at childPath: String) throws {
            guard currentPaths.contains(childPath), !stagedPaths.contains(childPath) else { return }
            let url = URL(fileURLWithPath: childPath)
            guard let metadata = fileMetadata(for: url) else {
                throw CodexIncrementalStoreError.unstableSource(childPath)
            }
            var pending = try validatedScan(at: url, metadata: metadata)
            if let stored = storedMetadata[childPath],
               stored.size == metadata.size,
               abs(stored.modificationTime - metadata.modificationTime) < 0.001,
               contentFingerprint(for: url, size: metadata.size) == stored.fingerprint {
                pending.validationFingerprint = stored.validationFingerprint
            }
            try store.stage(
                scan: pending,
                anchors: codexAnchors(for: pending.scan),
                createdAtEpoch: pending.scan.createdAt.flatMap(parseISO)?.timeIntervalSince1970
            )
            stagedPaths.insert(childPath)
        }

        for parentID in fullyAffectedParentIDs {
            for childPath in try store.childPaths(parentSessionID: parentID) {
                try stageChild(at: childPath)
            }
        }
        for (parentID, earliestNewAnchor) in appendedParentAnchorThresholds
        where !fullyAffectedParentIDs.contains(parentID) {
            for childPath in try store.childPaths(
                parentSessionID: parentID,
                createdAtOnOrAfter: earliestNewAnchor
            ) {
                try stageChild(at: childPath)
            }
        }

        for stagedPath in try store.stagedScanPaths() {
            guard let item = try store.stagedScan(path: stagedPath) else {
                throw CodexIncrementalStoreError.sqlite("missing staged scan for \(stagedPath)")
            }
            let parentAnchors: [CodexAnchor]?
            if let parentID = item.scan.parentSessionID {
                if let pendingParent = try store.stagedAnchors(sessionID: parentID) {
                    parentAnchors = pendingParent
                } else {
                    parentAnchors = try store.anchors(sessionID: parentID)
                }
            } else {
                parentAnchors = nil
            }
            let childCreatedAt = item.scan.createdAt.flatMap(parseISO)?.timeIntervalSince1970
            let parentAnchor = childCreatedAt.flatMap { timestamp in
                parentAnchors.flatMap { codexAnchor(atOrBefore: timestamp, anchors: $0) }
            }
            var seenRequestIDs = Set<String>()
            let result = codexDeltaRecords(
                from: item.scan,
                parentAnchor: parentAnchor,
                seenRequestIDs: &seenRequestIDs
            )
            let candidate = CodexCachedSession(
                    path: item.path.path,
                    size: item.metadata.size,
                    modificationTime: item.metadata.modificationTime,
                    fingerprint: item.fingerprint,
                    validationFingerprint: item.validationFingerprint,
                    sessionID: item.scan.canonicalSessionID,
                    createdAtEpoch: childCreatedAt,
                    parentSessionID: item.scan.parentSessionID,
                    anchors: try store.stagedAnchors(
                        sessionID: item.scan.canonicalSessionID
                    ) ?? [],
                    records: result.records,
                    summaryRecords: summarizeCodexRecords(result.records),
                    cursor: CodexSessionCursor(
                        currentModel: item.scan.finalModel ?? item.scan.events.last?.model ?? "unknown",
                        relevantLineNumber: item.scan.relevantLineCount ?? item.scan.events.count,
                        hasCumulativeSchema: result.cursor.hasCumulativeSchema,
                        previousCumulative: result.cursor.previousCumulative,
                        epoch: result.cursor.epoch
                    ),
                    diagnostics: result.diagnostics
                )
            if let existing = try store.session(path: item.path.path),
               candidate.hasSameStoredAccounting(as: existing) {
                if let validationFingerprint = candidate.validationFingerprint,
                   validationFingerprint != existing.validationFingerprint {
                    try store.updateValidationFingerprint(
                        validationFingerprint,
                        path: item.path.path
                    )
                }
            } else {
                try store.stage(session: candidate)
            }
        }

        try store.commitStaged(deletedPaths: deletedPaths)
        committed = true
        let cachedSessionCount = try store.sessionCount()
        guard cachedSessionCount == paths.count else {
            throw CodexIncrementalStoreError.incompleteCache(
                expected: paths.count,
                actual: cachedSessionCount
            )
        }

        var seenRequestIDs = Set<String>()
        var records = [UsageRecord]()
        var summaries = [CodexSummaryKey: CodexSummaryAccumulator]()
        var diagnostics = CodexCollectionDiagnostics()
        var sourceRecordCount = 0
        try store.forEachContribution(detailed: requiresDetailedRecords) { contribution in
            sourceRecordCount += contribution.recordCount
            diagnostics.add(contribution.diagnostics)
            for record in contribution.records {
                if let requestID = record.requestID,
                   !seenRequestIDs.insert(requestID).inserted {
                    diagnostics.duplicateRecords += 1
                    continue
                }
                if requiresDetailedRecords {
                    records.append(record)
                } else {
                    addCodexSummary(record, to: &summaries)
                }
            }
        }
        if !requiresDetailedRecords {
            records = codexSummaryRecords(summaries)
        }
        return codexCollectorResult(
            records: records,
            diagnostics: diagnostics,
            fileCount: paths.count,
            sourceRecordCount: sourceRecordCount,
            inputURLs: paths
        )
    }

    private static func collectCodexFromSQLite() -> CollectorResult? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".codex/state_5.sqlite"),
            home.appendingPathComponent(".codex/sqlite/state_5.sqlite")
        ]
        guard let database = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }

        let query = "select created_at, model, tokens_used from threads where tokens_used > 0"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", database.path, query]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        let records = rows.compactMap { row -> UsageRecord? in
            let tokens = integerValue(row["tokens_used"] as Any)
            guard tokens > 0,
                  let day = dayString(fromEpoch: row["created_at"] as Any)
            else {
                return nil
            }
            var usage = TokenUsageCounts()
            usage.totalTokens = tokens
            return UsageRecord(
                date: day,
                timestamp: nil,
                tool: "Codex",
                model: modelKey(row["model"] as? String),
                usage: usage,
                source: .nativeCodexSQLite
            )
        }

        guard !records.isEmpty else { return nil }
        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: "ok_sqlite",
                files: 1,
                records: records.count
            ),
            inputURLs: [database]
        )
    }

    private static func collectCodexFromJSONL(
        cache: inout CollectorCache,
        livePaths: inout Set<String>,
        modifiedSince cutoffDate: Date?,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        roots: [URL]? = nil
    ) -> CollectorResult {
        let roots = roots ?? defaultCodexSessionRoots(homeURL: homeURL)
        let paths = roots
            .flatMap { jsonlFiles(under: $0, modifiedSince: cutoffDate) }
            .sorted { $0.path < $1.path }
        var scans: [CodexSessionScan] = []

        for path in paths {
            livePaths.insert(path.path)
            if let cached = cachedCodexScan(for: path, cache: cache) {
                scans.append(cached)
                continue
            }

            guard var result = stableCodexScan(at: path) else { continue }
            if !result.isStable, let retry = stableCodexScan(at: path) {
                result = retry
            }
            scans.append(result.scan)
            if result.isStable {
                updateCodexCache(path: path, scan: result.scan, metadata: result.metadata, cache: &cache)
            }
        }

        let scansBySessionID = Dictionary(
            scans.map { ($0.canonicalSessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let anchorsBySessionID = scansBySessionID.mapValues(codexAnchors)
        var records: [UsageRecord] = []
        var diagnostics = CodexCollectionDiagnostics()
        var seenRequestIDs = Set<String>()
        for scan in scans.sorted(by: { $0.sourcePath < $1.sourcePath }) {
            let parentAnchor = codexForkAnchor(for: scan, anchorsBySessionID: anchorsBySessionID)
            let result = codexDeltaRecords(
                from: scan,
                parentAnchor: parentAnchor,
                seenRequestIDs: &seenRequestIDs
            )
            records.append(contentsOf: result.records)
            diagnostics.add(result.diagnostics)
        }

        return codexCollectorResult(
            records: records,
            diagnostics: diagnostics,
            fileCount: paths.count,
            inputURLs: paths
        )
    }

    private static func codexCollectorResult(
        records: [UsageRecord],
        diagnostics: CodexCollectionDiagnostics,
        fileCount: Int,
        sourceRecordCount: Int? = nil,
        inputURLs: [URL] = []
    ) -> CollectorResult {
        let breakdown = records.reduce(into: TokenUsageCounts()) { partial, record in
            partial.add(record.usage)
        }
        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: records.isEmpty ? "missing" : "ok",
                files: fileCount,
                records: sourceRecordCount ?? records.count,
                rawRecords: diagnostics.rawRecords,
                dedupedRecords: diagnostics.duplicateRecords + diagnostics.inheritedRecords,
                skippedRecords: diagnostics.skippedRecords,
                strategy: "total_token_usage_delta_v6_with_incremental_cache",
                exactRecords: diagnostics.exactRecords,
                legacyRecords: diagnostics.legacyRecords,
                duplicateRecords: diagnostics.duplicateRecords,
                counterResets: diagnostics.counterResets,
                inheritedRecords: diagnostics.inheritedRecords,
                inheritedTokens: diagnostics.inheritedTokens,
                unknownBreakdownRecords: diagnostics.unknownBreakdownRecords,
                accountingRevision: codexAccountingRevision,
                tokenBreakdown: SourceTokenBreakdown(
                    processedTokens: breakdown.totalTokens,
                    inputTokens: breakdown.inputTokens,
                    cachedInputTokens: breakdown.cacheReadInputTokens,
                    uncachedInputTokens: max(
                        0,
                        breakdown.inputTokens
                            - breakdown.cacheReadInputTokens
                            - breakdown.cacheCreationInputTokens
                    ),
                    outputTokens: breakdown.outputTokens,
                    reasoningTokens: breakdown.reasoningOutputTokens
                )
            ),
            inputURLs: inputURLs
        )
    }

    private static func summarizeCodexRecords(_ records: [UsageRecord]) -> [UsageRecord] {
        var summaries = [CodexSummaryKey: CodexSummaryAccumulator]()
        for record in records {
            addCodexSummary(record, to: &summaries)
        }
        return codexSummaryRecords(summaries)
    }

    private static func addCodexSummary(
        _ record: UsageRecord,
        to summaries: inout [CodexSummaryKey: CodexSummaryAccumulator]
    ) {
        let hour = record.timestampEpoch.map(hour(fromEpoch:))
            ?? hour(fromISO: record.timestamp)
        let key = CodexSummaryKey(date: record.date, model: record.model, hour: hour)
        summaries[key, default: CodexSummaryAccumulator()].add(record)
    }

    private static func codexSummaryRecords(
        _ summaries: [CodexSummaryKey: CodexSummaryAccumulator]
    ) -> [UsageRecord] {
        summaries.map { key, value in
            UsageRecord(
                date: key.date,
                timestamp: value.timestamp,
                timestampEpoch: value.timestampEpoch,
                tool: "Codex",
                model: key.model,
                usage: value.usage,
                source: .nativeCodex,
                dataSource: "codex_incremental_summary",
                modelRequestCount: value.modelRequestCount,
                toolCallCount: value.toolCallCount
            )
        }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.model != $1.model { return $0.model < $1.model }
            return ($0.timestampEpoch ?? -1) < ($1.timestampEpoch ?? -1)
        }
    }

    private static func stableCodexScan(
        at path: URL
    ) -> (scan: CodexSessionScan, isStable: Bool, metadata: (size: UInt64, modificationTime: TimeInterval))? {
        guard let before = fileMetadata(for: path),
              let scan = scanCodexSessionFile(at: path),
              let after = fileMetadata(for: path)
        else {
            return nil
        }
        return (scan, metadata(before, matches: after), after)
    }

    private static func incrementalCodexAppend(
        at path: URL,
        cached: CodexCachedSession
    ) -> CodexCachedSession? {
        guard let tail = scanCodexSessionTail(
            at: path,
            fromOffset: cached.size,
            cursor: cached.cursor
        ) else {
            return nil
        }

        var records = cached.records
        var diagnostics = cached.diagnostics
        var cursor = cached.cursor
        diagnostics.rawRecords += tail.events.count
        var seenRequestIDs = Set(records.compactMap(\.requestID))
        let scan = CodexSessionScan(
            canonicalSessionID: cached.sessionID,
            createdAt: cached.createdAtEpoch.map { isoFormatter.string(from: Date(timeIntervalSince1970: $0)) },
            parentSessionID: cached.parentSessionID,
            sourcePath: cached.path,
            events: tail.events,
            finalModel: tail.currentModel,
            relevantLineCount: tail.relevantLineNumber
        )

        if cursor.hasCumulativeSchema {
            var previous = cursor.previousCumulative
            var epoch = cursor.epoch
            for index in tail.events.indices {
                let event = tail.events[index]
                guard event.cumulativePresent else {
                    diagnostics.skippedRecords += 1
                    continue
                }
                guard let current = event.cumulative,
                      current.totalTokens > 0,
                      let day = dayString(for: event)
                else {
                    diagnostics.skippedRecords += 1
                    continue
                }

                let deltaTotal: Int
                let isReset: Bool
                if let previous {
                    if current.totalTokens == previous.totalTokens {
                        diagnostics.duplicateRecords += 1
                        continue
                    }
                    if current.totalTokens > previous.totalTokens {
                        deltaTotal = current.totalTokens - previous.totalTokens
                        isReset = false
                    } else if isCodexContextWindowSentinel(event) {
                        diagnostics.skippedRecords += 1
                        continue
                    } else if isCredibleCodexReset(
                        at: index,
                        events: tail.events,
                        current: current,
                        previous: previous
                    ) {
                        epoch += 1
                        diagnostics.counterResets += 1
                        deltaTotal = current.totalTokens
                        isReset = true
                    } else {
                        // Re-read the complete session so an ambiguous reset can be
                        // reconsidered when a following cumulative event arrives.
                        return nil
                    }
                } else {
                    deltaTotal = current.totalTokens
                    isReset = false
                }

                guard deltaTotal > 0 else { continue }
                let componentResult = codexIncrementUsage(
                    current: current,
                    previous: isReset ? nil : previous,
                    last: event.last,
                    total: deltaTotal
                )
                let requestID = "codex:cumulative:\(cached.sessionID):\(epoch):\(current.totalTokens)"
                guard seenRequestIDs.insert(requestID).inserted else {
                    diagnostics.duplicateRecords += 1
                    previous = current
                    continue
                }
                records.append(
                    codexUsageRecord(
                        scan: scan,
                        event: event,
                        day: day,
                        usage: componentResult.usage,
                        requestID: requestID,
                        dataSource: componentResult.hasKnownBreakdown
                            ? "codex_total_usage_delta"
                            : "codex_total_usage_delta_unknown_breakdown"
                    )
                )
                diagnostics.exactRecords += 1
                if !componentResult.hasKnownBreakdown {
                    diagnostics.unknownBreakdownRecords += 1
                }
                previous = current
            }
            cursor.previousCumulative = previous
            cursor.epoch = epoch
        } else {
            guard !tail.events.contains(where: \.cumulativePresent) else {
                return nil
            }
            for event in tail.events {
                guard let usage = event.last,
                      usage.totalTokens > 0,
                      let timestamp = event.timestamp,
                      let day = dayString(for: event)
                else {
                    diagnostics.skippedRecords += 1
                    continue
                }
                let requestID = "codex:legacy:\(cached.sessionID):\(timestamp):\(usage.fingerprint)"
                guard seenRequestIDs.insert(requestID).inserted else {
                    diagnostics.duplicateRecords += 1
                    continue
                }
                records.append(
                    codexUsageRecord(
                        scan: scan,
                        event: event,
                        day: day,
                        usage: usage,
                        requestID: requestID,
                        dataSource: "codex_last_usage_legacy_estimate"
                    )
                )
                diagnostics.legacyRecords += 1
                if !isCodexBreakdownConsistent(usage, total: usage.totalTokens) {
                    diagnostics.unknownBreakdownRecords += 1
                }
            }
        }

        cursor.currentModel = tail.currentModel
        cursor.relevantLineNumber = tail.relevantLineNumber
        return CodexCachedSession(
            path: cached.path,
            size: tail.processedSize,
            modificationTime: tail.modificationTime,
            fingerprint: tail.fingerprint,
            validationFingerprint: nil,
            sessionID: cached.sessionID,
            createdAtEpoch: cached.createdAtEpoch,
            parentSessionID: cached.parentSessionID,
            anchors: (cached.anchors + codexAnchors(for: scan))
                .sorted { $0.timestamp < $1.timestamp },
            records: records,
            summaryRecords: summarizeCodexRecords(records),
            cursor: cursor,
            diagnostics: diagnostics
        )
    }

    private static func scanCodexSessionTail(
        at path: URL,
        fromOffset offset: UInt64,
        cursor: CodexSessionCursor
    ) -> CodexSessionTail? {
        guard let metadata = fileMetadata(for: path), metadata.size > offset else { return nil }

        do {
            if offset > 0 {
                let handle = try FileHandle(forReadingFrom: path)
                defer { try? handle.close() }
                try handle.seek(toOffset: offset - 1)
                guard try handle.read(upToCount: 1)?.first == 0x0A else { return nil }
            }

            var currentModel = cursor.currentModel
            var relevantLineNumber = cursor.relevantLineNumber
            var events = [CodexTokenEvent]()
            var encounteredSessionMetadata = false
            let processedSize = try forEachCompleteLine(
                in: path,
                fromOffset: offset,
                matchingAny: ["session_meta", "turn_context", "token_count"]
            ) { line in
                autoreleasepool {
                    relevantLineNumber += 1
                    guard line.utf8.count <= maxRelevantLineBytes,
                          let obj = jsonObject(line)
                    else { return }
                    let type = obj["type"] as? String
                    let payload = obj["payload"] as? [String: Any]
                    if type == "session_meta" {
                        encounteredSessionMetadata = true
                        return
                    }
                    if type == "turn_context" {
                        currentModel = modelKey(payload?["model"] as? String ?? currentModel)
                    }
                    guard type == "event_msg",
                          payload?["type"] as? String == "token_count",
                          let info = payload?["info"] as? [String: Any]
                    else { return }
                    let timestamp = nonEmptyString(obj["timestamp"] as? String)
                    events.append(
                        CodexTokenEvent(
                            timestamp: timestamp,
                            timestampEpoch: timestamp.flatMap(parseISO)?.timeIntervalSince1970,
                            model: currentModel,
                            cumulativePresent: info.keys.contains("total_token_usage"),
                            cumulative: (info["total_token_usage"] as? [String: Any]).map(normalizeCodexUsage),
                            last: (info["last_token_usage"] as? [String: Any]).map(normalizeCodexUsage),
                            modelContextWindow: integerValue(info["model_context_window"] as Any),
                            lineNumber: relevantLineNumber
                        )
                    )
                }
            }

            guard processedSize > offset, !encounteredSessionMetadata else { return nil }
            guard let finalMetadata = fileMetadata(for: path),
                  let fingerprint = contentFingerprint(for: path, size: processedSize)
            else { return nil }
            return CodexSessionTail(
                events: events,
                currentModel: currentModel,
                relevantLineNumber: relevantLineNumber,
                processedSize: processedSize,
                modificationTime: finalMetadata.modificationTime,
                fingerprint: fingerprint
            )
        } catch {
            return nil
        }
    }

    private static func scanCodexSessionFile(at path: URL) -> CodexSessionScan? {
        guard FileManager.default.isReadableFile(atPath: path.path) else { return nil }
        var canonicalSessionID: String?
        var createdAt: String?
        var parentSessionID: String?
        var currentModel = "unknown"
        var events: [CodexTokenEvent] = []
        var relevantLineNumber = 0

        do {
            try forEachLine(in: path, matchingAny: ["session_meta", "turn_context", "token_count"]) { line in
                autoreleasepool {
                    relevantLineNumber += 1
                    guard let obj = jsonObject(line) else { return }
                    let type = obj["type"] as? String
                    let payload = obj["payload"] as? [String: Any]

                    if type == "session_meta", canonicalSessionID == nil,
                       let id = nonEmptyString(payload?["id"] as? String) {
                        canonicalSessionID = id
                        createdAt = nonEmptyString(obj["timestamp"] as? String)
                            ?? nonEmptyString(payload?["timestamp"] as? String)
                        parentSessionID = codexParentSessionID(from: payload)
                    }
                    if type == "turn_context" {
                        currentModel = modelKey(payload?["model"] as? String ?? currentModel)
                    }
                    guard type == "event_msg",
                          payload?["type"] as? String == "token_count",
                          let info = payload?["info"] as? [String: Any]
                    else {
                        return
                    }

                    let timestamp = nonEmptyString(obj["timestamp"] as? String)
                    let cumulativePresent = info.keys.contains("total_token_usage")
                    let cumulative = (info["total_token_usage"] as? [String: Any]).map(normalizeCodexUsage)
                    let last = (info["last_token_usage"] as? [String: Any]).map(normalizeCodexUsage)
                    events.append(
                        CodexTokenEvent(
                            timestamp: timestamp,
                            timestampEpoch: timestamp.flatMap(parseISO)?.timeIntervalSince1970,
                            model: currentModel,
                            cumulativePresent: cumulativePresent,
                            cumulative: cumulative,
                            last: last,
                            modelContextWindow: integerValue(info["model_context_window"] as Any),
                            lineNumber: relevantLineNumber
                        )
                    )
                }
            }
        } catch {
            return nil
        }

        return CodexSessionScan(
            canonicalSessionID: canonicalSessionID ?? path.deletingPathExtension().lastPathComponent,
            createdAt: createdAt,
            parentSessionID: parentSessionID,
            sourcePath: path.path,
            events: events,
            finalModel: currentModel,
            relevantLineCount: relevantLineNumber
        )
    }

    private static func codexParentSessionID(from payload: [String: Any]?) -> String? {
        if let source = payload?["source"] as? [String: Any],
           let subagent = source["subagent"] as? [String: Any],
           let threadSpawn = subagent["thread_spawn"] as? [String: Any],
           let parent = nonEmptyString(threadSpawn["parent_thread_id"] as? String) {
            return parent
        }
        return [
            payload?["parent_thread_id"] as? String,
            payload?["forked_from_id"] as? String
        ].compactMap(nonEmptyString).first
    }

    private static func codexForkAnchor(
        for scan: CodexSessionScan,
        anchorsBySessionID: [String: [CodexAnchor]]
    ) -> TokenUsageCounts? {
        guard let parentID = scan.parentSessionID,
              let anchors = anchorsBySessionID[parentID],
              let childCreatedAt = scan.createdAt.flatMap(parseISO)?.timeIntervalSince1970
        else {
            return nil
        }
        return codexAnchor(atOrBefore: childCreatedAt, anchors: anchors)
    }

    private static func codexAnchors(for scan: CodexSessionScan) -> [CodexAnchor] {
        scan.events.compactMap { event in
            guard event.cumulativePresent,
                  let usage = event.cumulative,
                  usage.totalTokens > 0,
                  let timestamp = event.timestampEpoch
                    ?? event.timestamp.flatMap(parseISO)?.timeIntervalSince1970
            else {
                return nil
            }
            return CodexAnchor(timestamp: timestamp, usage: usage)
        }.sorted { $0.timestamp < $1.timestamp }
    }

    private static func codexAnchor(
        atOrBefore timestamp: TimeInterval,
        anchors: [CodexAnchor]
    ) -> TokenUsageCounts? {
        var lower = 0
        var upper = anchors.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if anchors[middle].timestamp <= timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        return anchors[lower - 1].usage
    }

    private static func codexDeltaRecords(
        from scan: CodexSessionScan,
        parentAnchor: TokenUsageCounts?,
        seenRequestIDs: inout Set<String>
    ) -> (
        records: [UsageRecord],
        diagnostics: CodexCollectionDiagnostics,
        cursor: CodexDeltaCursor
    ) {
        var diagnostics = CodexCollectionDiagnostics(rawRecords: scan.events.count)
        var records: [UsageRecord] = []
        let hasCumulativeSchema = scan.events.contains { $0.cumulativePresent }

        if !hasCumulativeSchema {
            for event in scan.events {
                guard let usage = event.last,
                      usage.totalTokens > 0,
                      let timestamp = event.timestamp,
                      let day = dayString(for: event)
                else {
                    diagnostics.skippedRecords += 1
                    continue
                }
                let requestID = "codex:legacy:\(scan.canonicalSessionID):\(timestamp):\(usage.fingerprint)"
                guard seenRequestIDs.insert(requestID).inserted else {
                    diagnostics.duplicateRecords += 1
                    continue
                }
                records.append(
                    codexUsageRecord(
                        scan: scan,
                        event: event,
                        day: day,
                        usage: usage,
                        requestID: requestID,
                        dataSource: "codex_last_usage_legacy_estimate"
                    )
                )
                diagnostics.legacyRecords += 1
                if !isCodexBreakdownConsistent(usage, total: usage.totalTokens) {
                    diagnostics.unknownBreakdownRecords += 1
                }
            }
            return (
                records,
                diagnostics,
                CodexDeltaCursor(
                    hasCumulativeSchema: false,
                    previousCumulative: nil,
                    epoch: 0
                )
            )
        }

        var startIndex = 0
        var previous: TokenUsageCounts?
        if let parentAnchor,
           parentAnchor.totalTokens > 0,
           let anchorIndex = scan.events.firstIndex(where: {
               $0.cumulativePresent && $0.cumulative == parentAnchor
           }) {
            previous = parentAnchor
            startIndex = anchorIndex + 1
            diagnostics.inheritedRecords = scan.events[...anchorIndex].filter(\.cumulativePresent).count
            diagnostics.inheritedTokens = parentAnchor.totalTokens
        }

        var epoch = 0
        for index in startIndex..<scan.events.count {
            let event = scan.events[index]
            guard event.cumulativePresent else {
                diagnostics.skippedRecords += 1
                continue
            }
            guard let current = event.cumulative,
                  current.totalTokens > 0,
                  let day = dayString(for: event)
            else {
                diagnostics.skippedRecords += 1
                continue
            }

            let deltaTotal: Int
            let isReset: Bool
            if let previous {
                if current.totalTokens == previous.totalTokens {
                    diagnostics.duplicateRecords += 1
                    continue
                }
                if current.totalTokens > previous.totalTokens {
                    deltaTotal = current.totalTokens - previous.totalTokens
                    isReset = false
                } else if isCodexContextWindowSentinel(event) {
                    diagnostics.skippedRecords += 1
                    continue
                } else if isCredibleCodexReset(
                    at: index,
                    events: scan.events,
                    current: current,
                    previous: previous
                ) {
                    epoch += 1
                    diagnostics.counterResets += 1
                    deltaTotal = current.totalTokens
                    isReset = true
                } else {
                    diagnostics.skippedRecords += 1
                    continue
                }
            } else {
                deltaTotal = current.totalTokens
                isReset = false
            }

            guard deltaTotal > 0 else { continue }
            let componentResult = codexIncrementUsage(
                current: current,
                previous: isReset ? nil : previous,
                last: event.last,
                total: deltaTotal
            )
            let requestID = "codex:cumulative:\(scan.canonicalSessionID):\(epoch):\(current.totalTokens)"
            guard seenRequestIDs.insert(requestID).inserted else {
                diagnostics.duplicateRecords += 1
                previous = current
                continue
            }
            records.append(
                codexUsageRecord(
                    scan: scan,
                    event: event,
                    day: day,
                    usage: componentResult.usage,
                    requestID: requestID,
                    dataSource: componentResult.hasKnownBreakdown
                        ? "codex_total_usage_delta"
                        : "codex_total_usage_delta_unknown_breakdown"
                )
            )
            diagnostics.exactRecords += 1
            if !componentResult.hasKnownBreakdown {
                diagnostics.unknownBreakdownRecords += 1
            }
            previous = current
        }
        return (
            records,
            diagnostics,
            CodexDeltaCursor(
                hasCumulativeSchema: true,
                previousCumulative: previous,
                epoch: epoch
            )
        )
    }

    private static func codexUsageRecord(
        scan: CodexSessionScan,
        event: CodexTokenEvent,
        day: String,
        usage: TokenUsageCounts,
        requestID: String,
        dataSource: String
    ) -> UsageRecord {
        UsageRecord(
            date: day,
            timestamp: event.timestamp,
            timestampEpoch: event.timestampEpoch,
            tool: "Codex",
            model: event.model,
            usage: usage,
            source: .nativeCodex,
            requestID: requestID,
            sessionID: scan.canonicalSessionID,
            sourcePath: scan.sourcePath,
            lineNumber: event.lineNumber,
            dataSource: dataSource
        )
    }

    private static func codexIncrementUsage(
        current: TokenUsageCounts,
        previous: TokenUsageCounts?,
        last: TokenUsageCounts?,
        total: Int
    ) -> (usage: TokenUsageCounts, hasKnownBreakdown: Bool) {
        if let last,
           last.totalTokens == total,
           isCodexBreakdownConsistent(last, total: total) {
            var result = last
            result.totalTokens = total
            return (result, true)
        }

        let previous = previous ?? TokenUsageCounts()
        guard current.inputTokens >= previous.inputTokens,
              current.outputTokens >= previous.outputTokens,
              current.cacheCreationInputTokens >= previous.cacheCreationInputTokens,
              current.cacheReadInputTokens >= previous.cacheReadInputTokens,
              current.reasoningOutputTokens >= previous.reasoningOutputTokens
        else {
            return (TokenUsageCounts(totalTokens: total), false)
        }
        var result = TokenUsageCounts(
            inputTokens: current.inputTokens - previous.inputTokens,
            outputTokens: current.outputTokens - previous.outputTokens,
            cacheCreationInputTokens: current.cacheCreationInputTokens - previous.cacheCreationInputTokens,
            cacheReadInputTokens: current.cacheReadInputTokens - previous.cacheReadInputTokens,
            reasoningOutputTokens: current.reasoningOutputTokens - previous.reasoningOutputTokens,
            totalTokens: total
        )
        guard isCodexBreakdownConsistent(result, total: total) else {
            result = TokenUsageCounts(totalTokens: total)
            return (result, false)
        }
        return (result, true)
    }

    private static func isCodexBreakdownConsistent(_ usage: TokenUsageCounts, total: Int) -> Bool {
        usage.inputTokens >= 0
            && usage.outputTokens >= 0
            && usage.cacheCreationInputTokens >= 0
            && usage.cacheReadInputTokens >= 0
            && usage.reasoningOutputTokens >= 0
            && usage.inputTokens + usage.outputTokens == total
            && usage.cacheCreationInputTokens + usage.cacheReadInputTokens <= usage.inputTokens
            && usage.reasoningOutputTokens <= usage.outputTokens
    }

    private static func isCodexContextWindowSentinel(_ event: CodexTokenEvent) -> Bool {
        guard let current = event.cumulative else { return false }
        return current.inputTokens == 0
            && current.outputTokens == 0
            && current.cacheCreationInputTokens == 0
            && current.cacheReadInputTokens == 0
            && current.reasoningOutputTokens == 0
            && (event.last?.totalTokens ?? 0) == 0
            && event.modelContextWindow > 0
            && current.totalTokens == event.modelContextWindow
    }

    private static func isCredibleCodexReset(
        at index: Int,
        events: [CodexTokenEvent],
        current: TokenUsageCounts,
        previous: TokenUsageCounts
    ) -> Bool {
        if let last = events[index].last,
           last.totalTokens == current.totalTokens,
           isCodexBreakdownConsistent(last, total: current.totalTokens) {
            return true
        }
        for candidate in events.dropFirst(index + 1) where candidate.cumulativePresent {
            guard let next = candidate.cumulative, next.totalTokens > 0 else { continue }
            if next.totalTokens == current.totalTokens { continue }
            return next.totalTokens > current.totalTokens && next.totalTokens < previous.totalTokens
        }
        return false
    }

    private static func defaultCodexSessionRoots(homeURL: URL) -> [URL] {
        // archived_sessions may contain restored historical logs with rewritten timestamps.
        // Only live Codex sessions should count as current usage.
        [
            homeURL.appendingPathComponent(".codex/sessions", isDirectory: true)
        ]
    }

    private static func collectClaudeCode(
        cache: inout CollectorCache,
        livePaths: inout Set<String>,
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let root = rootURL
        let paths = jsonlFiles(under: root, modifiedSince: cutoffDate)
        var records: [UsageRecord] = []

        for path in paths.sorted(by: { $0.path < $1.path }) {
            livePaths.insert(path.path)
            if let cached = cachedRecords(for: path, tool: "Claude Code", cache: cache) {
                records.append(contentsOf: cached)
                continue
            }

            var fileRecords: [UsageRecord] = []
            var responses = [String: ClaudeUsageCandidate]()
            guard FileManager.default.isReadableFile(atPath: path.path) else { continue }

            var lineNumber = 0

            try? forEachLine(in: path, matchingAny: ["usage"]) { line in
                autoreleasepool {
                    lineNumber += 1
                    guard let obj = jsonObject(line),
                          obj["type"] as? String == "assistant",
                          let message = obj["message"] as? [String: Any]
                    else {
                        return
                    }

                    let usage = normalizeUsage(message["usage"] as? [String: Any])
                    guard usage.totalTokens > 0,
                          let timestamp = obj["timestamp"] as? String,
                          let day = dayString(fromISO: timestamp)
                    else {
                        return
                    }

                    let identity = claudeIdentity(obj: obj, message: message, path: path, lineNumber: lineNumber)
                    let candidate = ClaudeUsageCandidate(
                        date: day,
                        timestamp: timestamp,
                        model: modelKey(message["model"] as? String),
                        usage: usage,
                        hasStopReason: hasStopReason(message["stop_reason"]),
                        lineNumber: lineNumber,
                        requestID: identity.requestID,
                        responseID: identity.responseID,
                        sessionID: identity.sessionID,
                        sourcePath: path.path
                    )
                    if let existing = responses[identity.deduplicationKey],
                       !candidate.isPreferred(over: existing) {
                        return
                    }
                    responses[identity.deduplicationKey] = candidate
                }
            }
            fileRecords = responses.values.map(\.record)
            records.append(contentsOf: fileRecords)
            updateCache(path: path, tool: "Claude Code", records: fileRecords, cache: &cache)
        }

        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: records.isEmpty ? "missing" : "ok",
                files: paths.count,
                records: records.count
            ),
            inputURLs: paths
        )
    }

    private static func collectCCSwitchProxyUsage(databaseURL: URL? = nil) -> CollectorResult {
        let database = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/cc-switch.db")

        guard FileManager.default.fileExists(atPath: database.path) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "missing_db", files: 0, records: 0)
            )
        }

        guard FileManager.default.isReadableFile(atPath: database.path) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "unreadable_db", files: 1, records: 0)
            )
        }

        guard let columns = sqliteJSONRows(
            database: database,
            query: "pragma table_info(proxy_request_logs)"
        ) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "schema_unreadable", files: 1, records: 0)
            )
        }

        guard !columns.isEmpty else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "missing_table", files: 1, records: 0)
            )
        }

        let availableColumns = Set(columns.compactMap { $0["name"] as? String })
        let requiredColumns: Set<String> = [
            "request_id",
            "app_type",
            "provider_id",
            "model",
            "request_model",
            "pricing_model",
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_creation_tokens",
            "total_cost_usd",
            "status_code",
            "created_at"
        ]
        guard requiredColumns.isSubset(of: availableColumns) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "schema_mismatch", files: 1, records: 0)
            )
        }
        guard availableColumns.contains("data_source") else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "schema_missing_data_source", files: 1, records: 0)
            )
        }

        let sessionColumn = availableColumns.contains("session_id") ? "session_id" : "null"
        let inputSemanticsColumn = availableColumns.contains("input_token_semantics")
            ? "coalesce(input_token_semantics, 0)"
            : "0"
        let query = """
        select
            request_id,
            \(sessionColumn) as session_id,
            data_source,
            created_at,
            app_type,
            coalesce(nullif(pricing_model, ''), nullif(model, ''), nullif(request_model, ''), 'unknown') as display_model,
            coalesce(input_tokens, 0) as input_tokens,
            coalesce(output_tokens, 0) as output_tokens,
            coalesce(cache_read_tokens, 0) as cache_read_tokens,
            coalesce(cache_creation_tokens, 0) as cache_creation_tokens,
            \(inputSemanticsColumn) as input_token_semantics,
            cast(coalesce(nullif(total_cost_usd, ''), '0') as real) as total_cost_usd
        from proxy_request_logs
        where status_code >= 200
            and status_code < 300
            and lower(data_source) = 'proxy'
            and (
                coalesce(input_tokens, 0)
                + coalesce(output_tokens, 0)
                + coalesce(cache_read_tokens, 0)
                + coalesce(cache_creation_tokens, 0)
            ) > 0
        order by created_at, request_id
        """

        guard let rows = sqliteJSONRows(database: database, query: query) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "query_failed", files: 1, records: 0)
            )
        }

        let records = rows.compactMap { row -> UsageRecord? in
            guard let day = dayString(fromEpoch: row["created_at"] as Any) else {
                return nil
            }

            let appType = row["app_type"] as? String
            let rawInputTokens = integerValue(row["input_tokens"] as Any)
            let cacheReadTokens = integerValue(row["cache_read_tokens"] as Any)
            let cacheCreationTokens = integerValue(row["cache_creation_tokens"] as Any)
            let freshInputTokens = ccSwitchFreshInputTokens(
                rawInputTokens: rawInputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                appType: appType,
                inputTokenSemantics: integerValue(row["input_token_semantics"] as Any)
            )
            let usage = canonicalUsageCounts(
                rawInputTokens: freshInputTokens,
                outputTokens: integerValue(row["output_tokens"] as Any),
                cacheCreationInputTokens: cacheCreationTokens,
                cacheReadInputTokens: cacheReadTokens,
                inputIncludesCachedTokens: false
            )
            guard usage.totalTokens > 0 else { return nil }

            return UsageRecord(
                date: day,
                timestamp: isoString(fromEpoch: row["created_at"] as Any),
                tool: ccSwitchToolName(appType: appType),
                model: modelKey(row["display_model"] as? String),
                usage: usage,
                costUSD: positiveDoubleValue(row["total_cost_usd"] as Any),
                source: .ccSwitchProxy,
                requestID: nonEmptyString(row["request_id"] as? String),
                sessionID: nonEmptyString(row["session_id"] as? String),
                dataSource: nonEmptyString(row["data_source"] as? String)
            )
        }

        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: records.isEmpty ? "missing_valid_rows" : "ok",
                files: 1,
                records: records.count
            ),
            inputURLs: [database]
        )
    }

    private static func collectZCodeUsage(databaseURL: URL? = nil) -> CollectorResult {
        let database = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/db/db.sqlite")

        guard FileManager.default.fileExists(atPath: database.path) else {
            return CollectorResult(records: [], source: SourceInfo(status: "missing_db", files: 0, records: 0))
        }
        guard FileManager.default.isReadableFile(atPath: database.path) else {
            return CollectorResult(records: [], source: SourceInfo(status: "unreadable_db", files: 1, records: 0))
        }
        guard let columns = sqliteJSONRows(database: database, query: "pragma table_info(model_usage)") else {
            return CollectorResult(records: [], source: SourceInfo(status: "schema_unreadable", files: 1, records: 0))
        }
        guard !columns.isEmpty else {
            return CollectorResult(records: [], source: SourceInfo(status: "missing_table", files: 1, records: 0))
        }

        let availableColumns = Set(columns.compactMap { $0["name"] as? String })
        let requiredColumns: Set<String> = [
            "id",
            "session_id",
            "status",
            "started_at",
            "model_id",
            "input_tokens",
            "output_tokens"
        ]
        guard requiredColumns.isSubset(of: availableColumns) else {
            return CollectorResult(records: [], source: SourceInfo(status: "schema_mismatch", files: 1, records: 0))
        }

        let optionalInteger: (String) -> String = { column in
            availableColumns.contains(column) ? "coalesce(\(column), 0)" : "0"
        }
        let reasoningExpression = optionalInteger("reasoning_tokens")
        let cacheCreationExpression = optionalInteger("cache_creation_input_tokens")
        let cacheReadExpression = optionalInteger("cache_read_input_tokens")
        let computedTotalExpression = optionalInteger("computed_total_tokens")
        let providerTotalExpression = optionalInteger("provider_total_tokens")
        let toolCallExpression = optionalInteger("tool_call_count")
        let query = """
        select
            id,
            session_id,
            started_at,
            coalesce(nullif(model_id, ''), 'unknown') as display_model,
            coalesce(input_tokens, 0) as input_tokens,
            coalesce(output_tokens, 0) as output_tokens,
            \(reasoningExpression) as reasoning_tokens,
            \(cacheCreationExpression) as cache_creation_input_tokens,
            \(cacheReadExpression) as cache_read_input_tokens,
            \(computedTotalExpression) as computed_total_tokens,
            \(providerTotalExpression) as provider_total_tokens,
            \(toolCallExpression) as tool_call_count
        from model_usage
        where status = 'completed'
            and (
                \(computedTotalExpression) > 0
                or \(providerTotalExpression) > 0
                or (
                    coalesce(input_tokens, 0)
                    + coalesce(output_tokens, 0)
                    + \(reasoningExpression)
                    + \(cacheCreationExpression)
                    + \(cacheReadExpression)
                ) > 0
            )
        order by started_at, id
        """

        guard let rows = sqliteJSONRows(database: database, query: query) else {
            return CollectorResult(records: [], source: SourceInfo(status: "query_failed", files: 1, records: 0))
        }

        let records = rows.compactMap { row -> UsageRecord? in
            guard let day = dayString(fromEpoch: row["started_at"] as Any) else { return nil }
            let rawInputTokens = max(0, integerValue(row["input_tokens"] as Any))
            let outputTokens = max(0, integerValue(row["output_tokens"] as Any))
            let reasoningTokens = max(0, integerValue(row["reasoning_tokens"] as Any))
            let computedTotal = integerValue(row["computed_total_tokens"] as Any)
            let providerTotal = integerValue(row["provider_total_tokens"] as Any)
            let (componentTotal, componentTotalOverflow) = rawInputTokens.addingReportingOverflow(outputTokens)
            guard !componentTotalOverflow,
                  reasoningTokens <= outputTokens,
                  [computedTotal, providerTotal].allSatisfy({ $0 <= 0 || $0 == componentTotal })
            else { return nil }
            let usage = canonicalUsageCounts(
                rawInputTokens: rawInputTokens,
                outputTokens: outputTokens,
                cacheCreationInputTokens: integerValue(row["cache_creation_input_tokens"] as Any),
                cacheReadInputTokens: integerValue(row["cache_read_input_tokens"] as Any),
                reasoningOutputTokens: reasoningTokens,
                inputIncludesCachedTokens: true,
                explicitTotalTokens: computedTotal > 0 ? computedTotal : providerTotal
            )
            guard usage.totalTokens > 0 else { return nil }

            return UsageRecord(
                date: day,
                timestamp: isoString(fromEpoch: row["started_at"] as Any),
                tool: "ZCode",
                model: modelKey(row["display_model"] as? String),
                usage: usage,
                source: .zcode,
                requestID: nonEmptyString(row["id"] as? String),
                sessionID: nonEmptyString(row["session_id"] as? String),
                modelRequestCount: 1,
                toolCallCount: integerValue(row["tool_call_count"] as Any)
            )
        }

        return CollectorResult(
            records: records,
            source: SourceInfo(status: records.isEmpty ? "missing_valid_rows" : "ok", files: 1, records: records.count),
            inputURLs: [database]
        )
    }

    private static func collectHermesUsage(
        databaseURL: URL? = nil,
        modifiedSince cutoffDate: Date? = nil
    ) -> CollectorResult {
        let database = databaseURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/state.db")

        guard FileManager.default.fileExists(atPath: database.path) else {
            return CollectorResult(records: [], source: SourceInfo(status: "missing_db", files: 0, records: 0))
        }
        guard FileManager.default.isReadableFile(atPath: database.path) else {
            return CollectorResult(records: [], source: SourceInfo(status: "unreadable_db", files: 1, records: 0))
        }
        guard let columns = sqliteJSONRows(database: database, query: "pragma table_info(sessions)") else {
            return CollectorResult(records: [], source: SourceInfo(status: "schema_unreadable", files: 1, records: 0))
        }
        guard !columns.isEmpty else {
            return CollectorResult(records: [], source: SourceInfo(status: "missing_table", files: 1, records: 0))
        }

        let availableColumns = Set(columns.compactMap { $0["name"] as? String })
        let requiredColumns: Set<String> = [
            "id",
            "started_at",
            "input_tokens",
            "output_tokens"
        ]
        guard requiredColumns.isSubset(of: availableColumns) else {
            return CollectorResult(records: [], source: SourceInfo(status: "schema_mismatch", files: 1, records: 0))
        }

        let optionalInteger: (String) -> String = { column in
            availableColumns.contains(column) ? "coalesce(\(column), 0)" : "0"
        }
        let optionalText: (String, String) -> String = { column, fallback in
            availableColumns.contains(column)
                ? "coalesce(nullif(\(column), ''), '\(fallback)')"
                : "'\(fallback)'"
        }
        let sourceExpression = optionalText("source", "unknown")
        let modelExpression = optionalText("model", "unknown")
        let cacheReadExpression = optionalInteger("cache_read_tokens")
        let cacheWriteExpression = optionalInteger("cache_write_tokens")
        let reasoningExpression = optionalInteger("reasoning_tokens")
        let toolCallExpression = optionalInteger("tool_call_count")
        let apiCallExpression = optionalInteger("api_call_count")
        let actualCostExpression = optionalInteger("actual_cost_usd")
        let estimatedCostExpression = optionalInteger("estimated_cost_usd")
        let costStatusExpression = optionalText("cost_status", "")
        let startedAtLowerBound = cutoffDate.map {
            String(format: "and cast(started_at as real) >= %.6f", $0.timeIntervalSince1970)
        } ?? ""
        let query = """
        select
            id,
            \(sourceExpression) as source,
            \(modelExpression) as model,
            started_at,
            coalesce(input_tokens, 0) as input_tokens,
            coalesce(output_tokens, 0) as output_tokens,
            \(cacheReadExpression) as cache_read_tokens,
            \(cacheWriteExpression) as cache_write_tokens,
            \(reasoningExpression) as reasoning_tokens,
            \(toolCallExpression) as tool_call_count,
            \(apiCallExpression) as api_call_count,
            \(actualCostExpression) as actual_cost_usd,
            \(estimatedCostExpression) as estimated_cost_usd,
            \(costStatusExpression) as cost_status
        from sessions
        where (
            coalesce(input_tokens, 0)
            + coalesce(output_tokens, 0)
            + \(cacheReadExpression)
            + \(cacheWriteExpression)
            + \(reasoningExpression)
        ) > 0
        \(startedAtLowerBound)
        order by started_at, id
        """

        guard let rows = sqliteJSONRows(database: database, query: query) else {
            return CollectorResult(records: [], source: SourceInfo(status: "query_failed", files: 1, records: 0))
        }

        let records = rows.compactMap { row -> UsageRecord? in
            guard let day = dayString(fromEpoch: row["started_at"] as Any) else { return nil }
            let usage = canonicalUsageCounts(
                rawInputTokens: integerValue(row["input_tokens"] as Any),
                outputTokens: integerValue(row["output_tokens"] as Any),
                cacheCreationInputTokens: integerValue(row["cache_write_tokens"] as Any),
                cacheReadInputTokens: integerValue(row["cache_read_tokens"] as Any),
                reasoningOutputTokens: integerValue(row["reasoning_tokens"] as Any),
                inputIncludesCachedTokens: false
            )
            guard usage.totalTokens > 0 else { return nil }

            let actualCost = doubleValue(row["actual_cost_usd"] as Any)
            let estimatedCost = doubleValue(row["estimated_cost_usd"] as Any)
            let cost: Double?
            if actualCost > 0 {
                cost = actualCost
            } else if estimatedCost > 0 {
                cost = estimatedCost
            } else {
                cost = nil
            }
            let requestCount = integerValue(row["api_call_count"] as Any)

            return UsageRecord(
                date: day,
                timestamp: isoString(fromEpoch: row["started_at"] as Any),
                tool: "Hermes Agent",
                model: modelKey(row["model"] as? String),
                usage: usage,
                costUSD: cost,
                source: .hermes,
                requestID: nonEmptyString(row["id"] as? String),
                sessionID: nonEmptyString(row["id"] as? String),
                dataSource: nonEmptyString(row["source"] as? String),
                    modelRequestCount: max(1, requestCount),
                toolCallCount: integerValue(row["tool_call_count"] as Any)
            )
        }

        return CollectorResult(
            records: records,
            source: SourceInfo(status: records.isEmpty ? "missing_valid_rows" : "ok", files: 1, records: records.count),
            inputURLs: [database]
        )
    }

    private static func collectWorkBuddyUsage(
        rootURLs: [URL]? = nil,
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = rootURLs ?? [
            home.appendingPathComponent(".workbuddy/projects", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/WorkBuddyExtension", isDirectory: true)
        ]
        let discoveredRoots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        let files = discoveredRoots.flatMap { jsonlFiles(under: $0, modifiedSince: cutoffDate) }
        var records: [UsageRecord] = []
        var seenRequests = Set<String>()

        for file in files {
            var lineNumber = 0
            try? forEachLine(in: file, matchingAny: ["\"usage\"", "\"rawUsage\""]) { line in
                lineNumber += 1
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestamp = object["timestamp"],
                      let day = dayString(fromEpoch: timestamp),
                      let usage = workBuddyUsage(from: object),
                      usage.totalTokens > 0
                else {
                    return
                }

                let providerData = object["providerData"] as? [String: Any]
                let recordType = object["type"] as? String
                let sessionID = nonEmptyString(object["sessionId"] as? String)
                    ?? nonEmptyString(file.deletingPathExtension().lastPathComponent)
                let requestID = [
                    providerData?["messageId"] as? String,
                    providerData?["conversationRequestId"] as? String,
                    object["uuid"] as? String,
                    object["id"] as? String
                ].compactMap(nonEmptyString).first
                let fallbackIdentity = "\(file.path):\(lineNumber)"
                let identity = requestID.map { "\(sessionID ?? "unknown")|\($0)" }
                    ?? fallbackIdentity
                guard seenRequests.insert(identity).inserted else { return }
                records.append(UsageRecord(
                    date: day,
                    timestamp: isoString(fromEpoch: timestamp),
                    tool: "WorkBuddy",
                    model: modelKey(
                        providerData?["requestModelId"] as? String
                            ?? providerData?["requestModelName"] as? String
                            ?? providerData?["model"] as? String
                            ?? object["model"] as? String
                    ),
                    usage: usage,
                    source: .workbuddy,
                    requestID: requestID,
                    sessionID: sessionID,
                    sourcePath: file.path,
                    lineNumber: lineNumber,
                    modelRequestCount: 1,
                    toolCallCount: recordType == "function_call" ? 1 : 0
                ))
            }
        }

        let status: String
        if discoveredRoots.isEmpty {
            status = "missing"
        } else if files.isEmpty {
            status = "discovered_no_usage"
        } else if records.isEmpty {
            status = "missing_valid_rows"
        } else {
            status = "ok"
        }
        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: status,
                files: files.count,
                records: records.count
            ),
            inputURLs: files
        )
    }

    private static func workBuddyUsage(
        from object: [String: Any],
        inputIncludesCachedTokens: Bool = true
    ) -> TokenUsageCounts? {
        let message = object["message"] as? [String: Any]
        let providerData = object["providerData"] as? [String: Any]
        let usage = object["usage"] as? [String: Any]
            ?? message?["usage"] as? [String: Any]
            ?? providerData?["rawUsage"] as? [String: Any]
            ?? providerData?["usage"] as? [String: Any]
        guard let usage else { return nil }

        let rawInput = firstIntegerValue(
            in: usage,
            keys: ["input_tokens", "inputTokens", "prompt_tokens"]
        )
        let output = firstIntegerValue(
            in: usage,
            keys: ["output_tokens", "outputTokens", "completion_tokens"]
        )
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        let completionDetails = usage["completion_tokens_details"] as? [String: Any]
        let cacheRead = [
            integerValue(usage["cache_read_input_tokens"] as Any),
            integerValue(usage["cached_tokens"] as Any),
            integerValue(usage["prompt_cache_hit_tokens"] as Any),
            integerValue(promptDetails?["cached_tokens"] as Any)
        ].map { max(0, $0) }.max() ?? 0
        let cacheCreation = firstIntegerValue(
            in: usage,
            keys: ["cache_creation_input_tokens", "cacheCreationInputTokens", "prompt_cache_write_tokens"]
        )
        let reasoning = [
            integerValue(usage["reasoning_tokens"] as Any),
            integerValue(usage["completion_thinking_tokens"] as Any),
            integerValue(completionDetails?["reasoning_tokens"] as Any)
        ].map { max(0, $0) }.max() ?? 0
        let explicitTotal = firstIntegerValue(
            in: usage,
            keys: ["total_tokens", "totalTokens"]
        )
        let resolvedInputIncludesCachedTokens: Bool
        if explicitTotal > 0, explicitTotal == rawInput + output {
            resolvedInputIncludesCachedTokens = true
        } else if explicitTotal > 0,
                  explicitTotal == rawInput + cacheCreation + cacheRead + output {
            resolvedInputIncludesCachedTokens = false
        } else {
            resolvedInputIncludesCachedTokens = inputIncludesCachedTokens
        }
        return canonicalUsageCounts(
            rawInputTokens: rawInput,
            outputTokens: output,
            cacheCreationInputTokens: cacheCreation,
            cacheReadInputTokens: cacheRead,
            reasoningOutputTokens: reasoning,
            inputIncludesCachedTokens: resolvedInputIncludesCachedTokens,
            explicitTotalTokens: explicitTotal,
            explicitTotalIsAuthoritative: true
        )
    }

    private static func collectCodeBuddyUsage(
        rootURLs: [URL]? = nil,
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return collectClaudeShapedAgentUsage(
            tool: "CodeBuddy",
            source: .codebuddy,
            roots: rootURLs ?? [
                home.appendingPathComponent(".codebuddy/projects", isDirectory: true),
                home.appendingPathComponent(".codebuddy/sessions", isDirectory: true)
            ],
            modifiedSince: cutoffDate,
            assistantOnly: true,
            inputIncludesCachedTokens: false
        )
    }

    private static func collectQoderUsage(
        rootURL: URL? = nil,
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let root = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qoder/projects", isDirectory: true)
        return collectClaudeShapedAgentUsage(
            tool: "Qoder",
            source: .qoder,
            roots: [root],
            modifiedSince: cutoffDate,
            assistantOnly: true,
            inputIncludesCachedTokens: false
        )
    }

    private static func collectClaudeShapedAgentUsage(
        tool: String,
        source: UsageRecordSource,
        roots: [URL],
        modifiedSince cutoffDate: Date?,
        assistantOnly: Bool,
        inputIncludesCachedTokens: Bool
    ) -> CollectorResult {
        let discoveredRoots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        let files = discoveredRoots.flatMap { jsonlFiles(under: $0, modifiedSince: cutoffDate) }
        var records: [UsageRecord] = []
        var seen = Set<String>()

        for file in files {
            var lineNumber = 0
            try? forEachLine(in: file, matchingAny: ["\"usage\"", "\"rawUsage\""]) { line in
                lineNumber += 1
                guard let object = jsonObject(line) else { return }
                let message = object["message"] as? [String: Any]
                let role = nonEmptyString(message?["role"] as? String)
                    ?? nonEmptyString(object["role"] as? String)
                let type = nonEmptyString(object["type"] as? String)
                if assistantOnly,
                   role != "assistant",
                   type != "assistant",
                   type != "assistant_message" {
                    return
                }
                guard let temporal = usageTemporalInfo(from: object),
                      let usage = workBuddyUsage(
                        from: object,
                        inputIncludesCachedTokens: inputIncludesCachedTokens
                      ),
                      usage.totalTokens > 0
                else { return }

                let providerData = object["providerData"] as? [String: Any]
                let sessionID = firstNonEmptyString([
                    object["sessionId"], object["session_id"], message?["sessionId"]
                ]) ?? file.deletingPathExtension().lastPathComponent
                let requestID = firstNonEmptyString([
                    object["requestId"], object["request_id"], object["uuid"], object["id"],
                    message?["id"], providerData?["messageId"], providerData?["conversationRequestId"]
                ])
                let identity = requestID.map { "\(sessionID)|\($0)" }
                    ?? "\(file.path):\(lineNumber)"
                guard seen.insert(identity).inserted else { return }

                records.append(UsageRecord(
                    date: temporal.day,
                    timestamp: temporal.iso,
                    timestampEpoch: temporal.epoch,
                    tool: tool,
                    model: modelKey(firstNonEmptyString([
                        message?["model"], object["model"], object["modelId"],
                        providerData?["model"], providerData?["requestModelId"],
                        providerData?["requestModelName"]
                    ])),
                    usage: usage,
                    source: source,
                    requestID: requestID,
                    sessionID: sessionID,
                    responseID: nonEmptyString(message?["id"] as? String),
                    sourcePath: file.path,
                    lineNumber: lineNumber,
                    dataSource: "local_transcript",
                    modelRequestCount: 1,
                    toolCallCount: type == "function_call" ? 1 : 0
                ))
            }
        }

        let status: String
        if discoveredRoots.isEmpty { status = "missing" }
        else if files.isEmpty { status = "discovered_no_usage" }
        else if records.isEmpty { status = "missing_valid_rows" }
        else { status = "ok" }
        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: status,
                files: files.count,
                records: records.count,
                strategy: "transcript_assistant_usage"
            ),
            inputURLs: files
        )
    }

    private static func collectKimiCodeUsage(
        rootURL: URL? = nil,
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let root = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "missing", files: 0, records: 0)
            )
        }

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let files = jsonlFiles(under: sessions, modifiedSince: cutoffDate)
            .filter { $0.lastPathComponent == "wire.jsonl" }
        let fallbackModel = kimiCodeDefaultModel(rootURL: root)
        var records: [UsageRecord] = []
        var seenEvents = Set<String>()

        for file in files {
            var fileModel = fallbackModel
            var matchedLineNumber = 0
            try? forEachLine(
                in: file,
                matchingAny: ["\"config.update\"", "\"step.end\""]
            ) { line in
                matchedLineNumber += 1
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return
                }

                if object["type"] as? String == "config.update" {
                    if let alias = kimiCodeModelAlias(object["modelAlias"] as? String) {
                        fileModel = alias
                    }
                    return
                }

                let event: [String: Any]
                if object["type"] as? String == "context.append_loop_event",
                   let nested = object["event"] as? [String: Any] {
                    event = nested
                } else {
                    event = object
                }
                guard event["type"] as? String == "step.end",
                      let usageObject = event["usage"] as? [String: Any],
                      let usage = kimiCodeUsage(from: usageObject),
                      usage.totalTokens > 0,
                      let timestampValue = object["time"] ?? event["time"],
                      let day = dayString(fromEpoch: timestampValue)
                else {
                    return
                }

                let eventID = nonEmptyString(event["uuid"] as? String)
                let identity = eventID.map { "id:\($0)" }
                    ?? "line:\(file.path):\(matchedLineNumber)"
                guard seenEvents.insert(identity).inserted else { return }

                let model = kimiCodeModelAlias(
                    event["model"] as? String ?? object["model"] as? String
                ) ?? fileModel
                let sessionID = file
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .lastPathComponent
                records.append(UsageRecord(
                    date: day,
                    timestamp: isoString(fromEpoch: timestampValue),
                    timestampEpoch: epochSeconds(timestampValue),
                    tool: "Kimi",
                    model: modelKey(model),
                    usage: usage,
                    source: .kimi,
                    requestID: eventID,
                    sessionID: nonEmptyString(sessionID),
                    sourcePath: file.path,
                    lineNumber: matchedLineNumber,
                    modelRequestCount: 1
                ))
            }
        }

        let status: String
        if files.isEmpty {
            status = "discovered_no_usage"
        } else if records.isEmpty {
            status = "missing_valid_rows"
        } else {
            status = "ok"
        }
        return CollectorResult(
            records: records,
            source: SourceInfo(status: status, files: files.count, records: records.count),
            inputURLs: files
        )
    }

    private static func kimiCodeDefaultModel(rootURL: URL) -> String {
        let fallback = "kimi-for-coding"
        let configURL = rootURL.appendingPathComponent("config.toml")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            return fallback
        }
        for line in contents.split(whereSeparator: \Character.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, parts[0] == "default_model" else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return kimiCodeModelAlias(value) ?? fallback
        }
        return fallback
    }

    private static func kimiCodeModelAlias(_ value: String?) -> String? {
        guard let value = nonEmptyString(value) else { return nil }
        return nonEmptyString(value.split(separator: "/").last.map(String.init))
    }

    private static func kimiCodeUsage(from usage: [String: Any]) -> TokenUsageCounts? {
        if usage.keys.contains("inputOther") {
            return canonicalUsageCounts(
                rawInputTokens: integerValue(usage["inputOther"] as Any),
                outputTokens: integerValue(usage["output"] as Any),
                cacheCreationInputTokens: integerValue(usage["inputCacheCreation"] as Any),
                cacheReadInputTokens: integerValue(usage["inputCacheRead"] as Any),
                inputIncludesCachedTokens: false
            )
        }

        let rawInput = max(0, integerValue(usage["input_tokens"] as Any))
        let directCacheRead = usage.keys.contains("cache_read_input_tokens")
        let details = usage["input_tokens_details"] as? [String: Any]
        let cacheRead = directCacheRead
            ? max(0, integerValue(usage["cache_read_input_tokens"] as Any))
            : max(0, integerValue(details?["cached_tokens"] as Any))
        let freshInput = directCacheRead ? rawInput : max(0, rawInput - cacheRead)
        return canonicalUsageCounts(
            rawInputTokens: freshInput,
            outputTokens: integerValue(usage["output_tokens"] as Any),
            cacheCreationInputTokens: integerValue(usage["cache_creation_input_tokens"] as Any),
            cacheReadInputTokens: cacheRead,
            inputIncludesCachedTokens: false
        )
    }

    private static func collectCursorUsage(importURL: URL? = nil) -> CollectorResult {
        let url = importURL ?? AppPaths.cursorUsageImportJSON
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "missing_import", files: 0, records: 0)
            )
        }
        guard let data = try? Data(contentsOf: url) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "unreadable_import", files: 1, records: 0)
            )
        }
        guard let archive = try? JSONDecoder().decode(CollectedCursorUsageArchive.self, from: data),
              archive.schemaVersion == 1
        else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "schema_mismatch", files: 1, records: 0)
            )
        }

        var seen = Set<String>()
        let records = archive.records.compactMap { item -> UsageRecord? in
            guard seen.insert(item.deduplicationKey).inserted,
                  let parsedDate = CursorUsageTimestamp.date(from: item.timestamp)
            else {
                return nil
            }
            let usage = canonicalUsageCounts(
                rawInputTokens: item.inputTokens,
                outputTokens: item.outputTokens,
                cacheCreationInputTokens: item.cacheWriteTokens,
                cacheReadInputTokens: item.cacheReadTokens,
                inputIncludesCachedTokens: false
            )
            guard usage.totalTokens > 0 else { return nil }

            let digest = SHA256.hash(data: Data(item.deduplicationKey.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return UsageRecord(
                date: dayFormatter.string(from: parsedDate),
                timestamp: item.timestamp,
                timestampEpoch: parsedDate.timeIntervalSince1970,
                tool: "Cursor",
                model: modelKey(item.model),
                usage: usage,
                costUSD: max(0, item.costUSD),
                source: .cursor,
                requestID: "cursor-csv:\(digest)",
                sourcePath: url.path,
                dataSource: "cursor_usage_csv",
                modelRequestCount: 1
            )
        }

        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: records.isEmpty ? "missing_valid_rows" : "ok",
                files: 1,
                records: records.count,
                rawRecords: archive.records.count,
                dedupedRecords: records.count,
                strategy: "cursor_usage_csv_v1"
            ),
            inputURLs: [url]
        )
    }

    private static func collectClineUsage(
        rootURLs: [URL]? = nil,
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let roots = rootURLs ?? clineDefaultRoots()
        let files = clineUsageFiles(roots: roots, modifiedSince: cutoffDate)
        guard !files.isEmpty else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "missing", files: 0, records: 0)
            )
        }

        var records: [UsageRecord] = []
        var seen = Set<String>()
        var currentSessionIDs = Set<String>()
        var currentArchives: [(URL, ClineMessagesArchive)] = []
        var rawRecords = 0

        for file in files where file.lastPathComponent.hasSuffix(".messages.json") {
            guard let data = try? Data(contentsOf: file),
                  let archive = try? JSONDecoder().decode(ClineMessagesArchive.self, from: data),
                  archive.version == 1,
                  !archive.sessionID.isEmpty
            else {
                continue
            }
            currentSessionIDs.insert(archive.sessionID)
            currentArchives.append((file, archive))
        }

        for (file, archive) in currentArchives {
            for message in archive.messages {
                guard message.role == "assistant",
                      let metrics = message.metrics,
                      let input = metrics.inputTokens,
                      let output = metrics.outputTokens,
                      let cacheRead = metrics.cacheReadTokens,
                      let cacheWrite = metrics.cacheWriteTokens,
                      let timestampMilliseconds = message.timestampMilliseconds,
                      let model = nonEmptyString(message.modelInfo?.id)
                else {
                    continue
                }
                rawRecords += 1
                let dedupKey = "current:\(archive.sessionID):\(message.id)"
                guard seen.insert(dedupKey).inserted else { continue }

                let timestamp = timestampMilliseconds > 10_000_000_000
                    ? timestampMilliseconds / 1_000
                    : timestampMilliseconds
                let date = Date(timeIntervalSince1970: timestamp)
                let usage = canonicalUsageCounts(
                    rawInputTokens: input,
                    outputTokens: output,
                    cacheCreationInputTokens: cacheWrite,
                    cacheReadInputTokens: cacheRead,
                    inputIncludesCachedTokens: true
                )
                guard usage.totalTokens > 0 else { continue }
                records.append(UsageRecord(
                    date: dayFormatter.string(from: date),
                    timestamp: isoFormatterWithFractional.string(from: date),
                    timestampEpoch: timestamp,
                    tool: "Cline",
                    model: modelKey(model),
                    usage: usage,
                    costUSD: metrics.cost.map { max(0, $0) },
                    source: .cline,
                    requestID: dedupKey,
                    sessionID: archive.sessionID,
                    sourcePath: file.path,
                    dataSource: "cline_messages_v1",
                    modelRequestCount: 1
                ))
            }
        }

        for file in files where file.lastPathComponent == "ui_messages.json" {
            let taskID = file.deletingLastPathComponent().lastPathComponent
            guard !currentSessionIDs.contains(taskID),
                  let data = try? Data(contentsOf: file),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                continue
            }

            func appendLegacyUsage(
                payload: [String: Any],
                message: [String: Any],
                say: String
            ) {
                let timestampValue = message["ts"]
                guard let timestampValue,
                      let day = dayString(fromEpoch: timestampValue)
                else {
                    return
                }
                let input = integerValue(payload["tokensIn"] as Any)
                let output = integerValue(payload["tokensOut"] as Any)
                let cacheRead = integerValue(payload["cacheReads"] as Any)
                let cacheWrite = integerValue(payload["cacheWrites"] as Any)
                let usage = canonicalUsageCounts(
                    rawInputTokens: input,
                    outputTokens: output,
                    cacheCreationInputTokens: cacheWrite,
                    cacheReadInputTokens: cacheRead,
                    inputIncludesCachedTokens: false
                )
                guard usage.totalTokens > 0 else { return }
                rawRecords += 1
                let timestampText = String(describing: timestampValue)
                let dedupKey = "legacy:\(taskID):\(timestampText):\(say)"
                guard seen.insert(dedupKey).inserted else { return }

                let costValue = payload["cost"] ?? payload["totalCost"]
                let cost = costValue.map { max(0, doubleValue($0)) }
                let model = [
                    payload["model"] as? String,
                    payload["modelId"] as? String
                ].compactMap(nonEmptyString).first ?? "unknown"
                records.append(UsageRecord(
                    date: day,
                    timestamp: isoString(fromEpoch: timestampValue),
                    timestampEpoch: epochSeconds(timestampValue),
                    tool: "Cline",
                    model: modelKey(model),
                    usage: usage,
                    costUSD: cost,
                    source: .cline,
                    requestID: dedupKey,
                    sessionID: taskID,
                    sourcePath: file.path,
                    dataSource: "cline_ui_messages",
                    modelRequestCount: 1
                ))
            }

            for (index, message) in messages.enumerated() {
                guard message["type"] as? String == "say",
                      let say = nonEmptyString(message["say"] as? String),
                      ["api_req_started", "deleted_api_reqs", "subagent_usage", "api_req_deleted"].contains(say),
                      let text = message["text"] as? String,
                      let payloadData = text.data(using: .utf8),
                      var payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
                else {
                    continue
                }

                if say == "api_req_started" {
                    var cursor = index + 1
                    while cursor < messages.count {
                        let candidate = messages[cursor]
                        if candidate["type"] as? String == "say",
                           candidate["say"] as? String == "api_req_started" {
                            break
                        }
                        if candidate["type"] as? String == "say",
                           candidate["say"] as? String == "api_req_finished",
                           let finishText = candidate["text"] as? String,
                           let finishData = finishText.data(using: .utf8),
                           let finish = try? JSONSerialization.jsonObject(with: finishData) as? [String: Any] {
                            payload.merge(finish) { _, latest in latest }
                            break
                        }
                        cursor += 1
                    }
                }
                appendLegacyUsage(payload: payload, message: message, say: say)
            }
        }

        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: records.isEmpty ? "missing_valid_rows" : "ok",
                files: files.count,
                records: records.count,
                rawRecords: rawRecords,
                dedupedRecords: records.count,
                strategy: "cline_exact_usage_v1_and_legacy"
            ),
            inputURLs: files
        )
    }

    private static func clineDefaultRoots(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        let dataRoot: URL
        if let raw = nonEmptyString(environment["CLINE_DATA_DIR"]) {
            dataRoot = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        } else if let raw = nonEmptyString(environment["CLINE_DIR"]) {
            dataRoot = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("data", isDirectory: true)
        } else {
            dataRoot = homeURL.appendingPathComponent(".cline/data", isDirectory: true)
        }

        let applicationSupport = homeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
        let ideNames = ["Code", "Code - Insiders", "Cursor", "CodeBuddy", "Windsurf", "VSCodium", "Trae", "Trae CN"]
        let extensionIDs = ["saoudrizwan.claude-dev", "cline.cline"]
        var roots = [dataRoot]
        for ideName in ideNames {
            for extensionID in extensionIDs {
                roots.append(
                    applicationSupport
                        .appendingPathComponent(ideName, isDirectory: true)
                        .appendingPathComponent("User/globalStorage", isDirectory: true)
                        .appendingPathComponent(extensionID, isDirectory: true)
                )
            }
        }
        return roots
    }

    private static func clineUsageFiles(
        roots: [URL],
        modifiedSince cutoffDate: Date?
    ) -> [URL] {
        var files: [URL] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if root.lastPathComponent == "ui_messages.json" || root.lastPathComponent.hasSuffix(".messages.json") {
                    files.append(root)
                }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                guard name == "ui_messages.json" || name.hasSuffix(".messages.json"),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true
                else {
                    continue
                }
                if let cutoffDate,
                   let modifiedAt = values.contentModificationDate,
                   modifiedAt < cutoffDate {
                    continue
                }
                files.append(url)
            }
        }
        return Dictionary(grouping: files, by: \.path)
            .compactMap { _, duplicates in duplicates.first }
            .sorted { $0.path < $1.path }
    }

    private static func copilotCLIDefaultDatabase(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let raw = nonEmptyString(ProcessInfo.processInfo.environment["COPILOT_HOME"]) {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("session-store.db")
        }
        return homeURL.appendingPathComponent(".copilot/session-store.db")
    }

    private static func collectCopilotCLIUsage(databaseURL: URL? = nil) -> CollectorResult {
        let database = databaseURL ?? copilotCLIDefaultDatabase()
        guard FileManager.default.fileExists(atPath: database.path) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "missing_db", files: 0, records: 0)
            )
        }
        guard FileManager.default.isReadableFile(atPath: database.path) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "unreadable_db", files: 1, records: 0)
            )
        }
        guard let columns = sqliteJSONRows(
            database: database,
            query: "pragma table_info(assistant_usage_events)"
        ) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "schema_unreadable", files: 1, records: 0)
            )
        }
        guard !columns.isEmpty else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "missing_table", files: 1, records: 0)
            )
        }

        let availableColumns = Set(columns.compactMap { $0["name"] as? String })
        let requiredColumns: Set<String> = [
            "id",
            "session_id",
            "model",
            "input_tokens",
            "output_tokens",
            "created_at"
        ]
        guard requiredColumns.isSubset(of: availableColumns) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "schema_mismatch", files: 1, records: 0)
            )
        }

        let optionalInteger: (String) -> String = { column in
            availableColumns.contains(column) ? "coalesce(\(column), 0)" : "0"
        }
        let tokenDetailsExpression = availableColumns.contains("token_details_json")
            ? "token_details_json"
            : "null"
        let query = """
        select
            id,
            session_id,
            coalesce(nullif(model, ''), 'unknown') as model,
            coalesce(input_tokens, 0) as input_tokens,
            coalesce(output_tokens, 0) as output_tokens,
            \(optionalInteger("cache_read_tokens")) as cache_read_tokens,
            \(optionalInteger("cache_write_tokens")) as cache_write_tokens,
            \(optionalInteger("reasoning_tokens")) as reasoning_tokens,
            \(tokenDetailsExpression) as token_details_json,
            created_at
        from assistant_usage_events
        where coalesce(input_tokens, 0) + coalesce(output_tokens, 0) > 0
        order by id
        """
        guard let rows = sqliteJSONRows(database: database, query: query) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "query_failed", files: 1, records: 0)
            )
        }

        var seen = Set<String>()
        let records = rows.compactMap { row -> UsageRecord? in
            guard let rowID = nonEmptyString(String(describing: row["id"] ?? "")),
                  seen.insert(rowID).inserted,
                  let createdAt = nonEmptyString(row["created_at"] as? String),
                  let date = parseISO(createdAt)
            else {
                return nil
            }

            let rawInput = max(0, integerValue(row["input_tokens"] as Any))
            let rawOutput = max(0, integerValue(row["output_tokens"] as Any))
            let declaredCacheRead = max(0, integerValue(row["cache_read_tokens"] as Any))
            let declaredCacheWrite = max(0, integerValue(row["cache_write_tokens"] as Any))
            let details = copilotStoreTokenDetails(row["token_details_json"] as? String)
            let detailsAreConsistent = details.map {
                $0.input + $0.cacheRead + $0.cacheWrite == rawInput
                    && $0.output == rawOutput
            } ?? false
            let cacheRead = detailsAreConsistent ? details?.cacheRead ?? 0 : min(declaredCacheRead, rawInput)
            let cacheWrite = detailsAreConsistent
                ? details?.cacheWrite ?? 0
                : min(declaredCacheWrite, max(0, rawInput - cacheRead))
            let usage = canonicalUsageCounts(
                rawInputTokens: rawInput,
                outputTokens: rawOutput,
                cacheCreationInputTokens: cacheWrite,
                cacheReadInputTokens: cacheRead,
                reasoningOutputTokens: min(
                    max(0, integerValue(row["reasoning_tokens"] as Any)),
                    rawOutput
                ),
                inputIncludesCachedTokens: true
            )
            guard usage.totalTokens > 0 else { return nil }

            return UsageRecord(
                date: dayFormatter.string(from: date),
                timestamp: isoFormatterWithFractional.string(from: date),
                timestampEpoch: date.timeIntervalSince1970,
                tool: "Copilot CLI",
                model: modelKey(row["model"] as? String),
                usage: usage,
                source: .copilot,
                requestID: "copilot-store:\(rowID)",
                sessionID: nonEmptyString(row["session_id"] as? String),
                sourcePath: database.path,
                dataSource: "copilot_session_store",
                modelRequestCount: 1
            )
        }

        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: records.isEmpty ? "missing_valid_rows" : "ok",
                files: 1,
                records: records.count,
                rawRecords: rows.count,
                dedupedRecords: records.count,
                strategy: "copilot_session_store_per_request"
            ),
            inputURLs: [database]
        )
    }

    private static func copilotStoreTokenDetails(
        _ raw: String?
    ) -> (input: Int, cacheRead: Int, cacheWrite: Int, output: Int)? {
        guard let raw = nonEmptyString(raw),
              let data = raw.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }
        var result = (input: 0, cacheRead: 0, cacheWrite: 0, output: 0)
        var recognized = 0
        for row in rows {
            let count = max(0, integerValue(row["tokenCount"] as Any))
            switch row["tokenType"] as? String {
            case "input":
                result.input += count
                recognized += 1
            case "cache_read":
                result.cacheRead += count
                recognized += 1
            case "cache_write":
                result.cacheWrite += count
                recognized += 1
            case "output":
                result.output += count
                recognized += 1
            default:
                break
            }
        }
        return recognized > 0 ? result : nil
    }

    private static func copilotOTelDefaultURLs(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var urls: [URL] = []
        if let configured = nonEmptyString(
            ProcessInfo.processInfo.environment["COPILOT_OTEL_FILE_EXPORTER_PATH"]
        ) {
            urls.append(URL(fileURLWithPath: (configured as NSString).expandingTildeInPath))
        }
        urls.append(homeURL.appendingPathComponent(".copilot/otel", isDirectory: true))
        urls.append(homeURL.appendingPathComponent(
            "Library/Application Support/GitHub Copilot/otel",
            isDirectory: true
        ))
        return Dictionary(grouping: urls, by: \.standardizedFileURL.path)
            .compactMap { _, duplicates in duplicates.first }
    }

    private static func preferCopilotSessionStore(
        sessionStore: CollectorResult,
        otel: inout CollectorResult
    ) {
        guard !sessionStore.records.isEmpty else { return }

        let recordsBySession = Dictionary(grouping: sessionStore.records.compactMap { record -> UsageRecord? in
            guard nonEmptyString(record.sessionID) != nil,
                  record.timestampEpoch != nil
            else { return nil }
            return record
        }) { $0.sessionID ?? "" }
        let coveredWindows = recordsBySession.reduce(into: [String: ClosedRange<TimeInterval>]()) {
            result, entry in
            let epochs = entry.value.compactMap(\.timestampEpoch)
            guard let first = epochs.min(), let last = epochs.max() else { return }
            result[entry.key] = first ... last
        }
        let coveredDates = Set(sessionStore.records.map(\.date))

        let rawCount = otel.records.count
        otel.records.removeAll { record in
            guard record.tool == "Copilot CLI" else { return false }
            if let sessionID = nonEmptyString(record.sessionID),
               let eventTime = record.timestampEpoch,
               let coveredWindow = coveredWindows[sessionID],
               coveredWindow.contains(eventTime) {
                return true
            }
            // Some Copilot OTel versions omit conversation/session IDs and
            // leave only the trace ID. On dates covered by the authoritative
            // session store, suppress that unmatchable CLI fallback to avoid
            // counting the same local request twice. Older dates remain intact.
            return record.dataSource == "copilot_otel_chat_span_trace_session_fallback"
                && coveredDates.contains(record.date)
        }
        let removed = rawCount - otel.records.count
        guard removed > 0 else { return }
        otel.source.rawRecords = max(otel.source.rawRecords ?? rawCount, rawCount)
        otel.source.records = otel.records.count
        otel.source.dedupedRecords = otel.records.count
        otel.source.skippedRecords = (otel.source.skippedRecords ?? 0) + removed
        otel.source.strategy = "otel_chat_spans_cli_session_window_or_trace_fallback_day_overlap"
        if otel.records.isEmpty {
            otel.source.status = "deduped_by_session_store"
        }
    }

    private static func collectCopilotOTelUsage(
        urls: [URL]? = nil,
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let roots = urls ?? copilotOTelDefaultURLs()
        let discovered = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        let files = discovered.flatMap { usageLogFiles(at: $0, modifiedSince: cutoffDate) }
        var records: [UsageRecord] = []
        var seen = Set<String>()

        for file in files {
            var lineNumber = 0
            try? forEachLine(in: file, matchingAny: ["gen_ai.usage", "gen_ai\\\"", "attributes"]) { line in
                lineNumber += 1
                guard let object = jsonObject(line) else { return }
                for envelope in otelSpanEnvelopes(in: object) {
                    let span = envelope.span
                    let attributes = envelope.attributes
                    let operation = firstNonEmptyString([
                        attributes["gen_ai.operation.name"], span["name"], span["spanName"]
                    ])?.lowercased()
                    guard operation == "chat" || operation?.hasSuffix(" chat") == true else { continue }

                    let input = firstIntegerValue(in: attributes, keys: ["gen_ai.usage.input_tokens"])
                    let output = firstIntegerValue(in: attributes, keys: ["gen_ai.usage.output_tokens"])
                    let cacheRead = firstIntegerValue(in: attributes, keys: [
                        "gen_ai.usage.cache_read.input_tokens",
                        "gen_ai.usage.cache_read_input_tokens"
                    ])
                    let cacheCreation = firstIntegerValue(in: attributes, keys: [
                        "gen_ai.usage.cache_creation.input_tokens",
                        "gen_ai.usage.cache_creation_input_tokens"
                    ])
                    let reasoning = firstIntegerValue(in: attributes, keys: [
                        "gen_ai.usage.reasoning.output_tokens",
                        "gen_ai.usage.reasoning_tokens"
                    ])
                    let usage = canonicalUsageCounts(
                        rawInputTokens: input,
                        outputTokens: output,
                        cacheCreationInputTokens: cacheCreation,
                        cacheReadInputTokens: cacheRead,
                        reasoningOutputTokens: reasoning,
                        inputIncludesCachedTokens: true
                    )
                    guard usage.totalTokens > 0,
                          let temporal = otelTemporalInfo(from: span) ?? usageTemporalInfo(from: object)
                    else { continue }

                    let traceID = firstNonEmptyString([span["traceId"], span["trace_id"]])
                    let spanID = firstNonEmptyString([span["spanId"], span["span_id"]])
                    let identity = [traceID, spanID].compactMap { $0 }.joined(separator: "|")
                    let dedupeKey = identity.isEmpty ? "\(file.path):\(lineNumber):\(records.count)" : identity
                    guard seen.insert(dedupeKey).inserted else { continue }

                    let service = firstNonEmptyString([
                        attributes["service.name"], attributes["gen_ai.system"], attributes["gen_ai.provider.name"]
                    ])?.lowercased() ?? ""
                    let tool = service.contains("chat") || service.contains("vscode")
                        ? "Copilot Chat"
                        : "Copilot CLI"
                    let explicitSessionID = firstNonEmptyString([
                        attributes["gen_ai.conversation.id"], attributes["session.id"]
                    ])
                    records.append(UsageRecord(
                        date: temporal.day,
                        timestamp: temporal.iso,
                        timestampEpoch: temporal.epoch,
                        tool: tool,
                        model: modelKey(firstNonEmptyString([
                            attributes["gen_ai.response.model"], attributes["gen_ai.request.model"]
                        ])),
                        usage: usage,
                        costUSD: doubleValue(attributes["github.copilot.cost"] as Any) > 0
                            ? doubleValue(attributes["github.copilot.cost"] as Any)
                            : nil,
                        source: .copilotOTel,
                        requestID: firstNonEmptyString([
                            attributes["gen_ai.request.id"], attributes["gen_ai.response.id"], spanID
                        ]),
                        sessionID: explicitSessionID ?? traceID,
                        responseID: firstNonEmptyString([attributes["gen_ai.response.id"]]),
                        sourcePath: file.path,
                        lineNumber: lineNumber,
                        dataSource: explicitSessionID == nil
                            ? "copilot_otel_chat_span_trace_session_fallback"
                            : "copilot_otel_chat_span"
                    ))
                }
            }
        }

        let status: String
        if discovered.isEmpty { status = "missing" }
        else if files.isEmpty { status = "discovered_no_usage" }
        else if records.isEmpty { status = "missing_valid_rows" }
        else { status = "ok" }
        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: status,
                files: files.count,
                records: records.count,
                strategy: "otel_chat_spans_only"
            ),
            inputURLs: files
        )
    }

    private static func collectAntigravityUsage(
        rootURLs: [URL]? = nil,
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = rootURLs ?? [
            home.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true),
            home.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true),
            home.appendingPathComponent(".gemini/antigravity-ide/brain", isDirectory: true)
        ]
        return collectResultUsageJSONL(
            tool: "Antigravity",
            source: .antigravity,
            roots: roots,
            modifiedSince: cutoffDate,
            acceptedNames: ["transcript.jsonl"],
            usageKeys: ["usage", "usageMetadata"],
            requireResultLikeRecord: true,
            inputIncludesCachedTokens: true
        )
    }

    private static func collectDroidUsage(
        rootURL: URL? = nil,
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let root = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".factory/projects", isDirectory: true)
        return collectResultUsageJSONL(
            tool: "Droid",
            source: .droid,
            roots: [root],
            modifiedSince: cutoffDate,
            acceptedNames: ["session.jsonl"],
            usageKeys: ["tokenUsage"],
            requireResultLikeRecord: true,
            inputIncludesCachedTokens: false
        )
    }

    private static func collectResultUsageJSONL(
        tool: String,
        source: UsageRecordSource,
        roots: [URL],
        modifiedSince cutoffDate: Date?,
        acceptedNames: Set<String>,
        usageKeys: [String],
        requireResultLikeRecord: Bool,
        inputIncludesCachedTokens: Bool
    ) -> CollectorResult {
        let discovered = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        let files = discovered.flatMap { usageLogFiles(at: $0, modifiedSince: cutoffDate) }
            .filter { acceptedNames.isEmpty || acceptedNames.contains($0.lastPathComponent) }
        var records: [UsageRecord] = []
        var seen = Set<String>()

        for file in files {
            var lineNumber = 0
            try? forEachLine(in: file, matchingAny: usageKeys.map { "\"\($0)\"" }) { line in
                lineNumber += 1
                guard let object = jsonObject(line) else { return }
                let type = firstNonEmptyString([object["type"], object["event"]])?.lowercased() ?? ""
                if requireResultLikeRecord,
                   !type.contains("result"),
                   !type.contains("complete"),
                   !type.contains("assistant_message"),
                   !type.contains("response"),
                   type != "assistant" {
                    return
                }
                guard let usageObject = firstNestedDictionary(in: object, keys: usageKeys),
                      let usage = portableUsage(
                        from: usageObject,
                        inputIncludesCachedTokens: inputIncludesCachedTokens
                      ),
                      usage.totalTokens > 0,
                      let temporal = usageTemporalInfo(from: object)
                else { return }

                let result = object["result"] as? [String: Any]
                let requestID = firstNonEmptyString([
                    object["requestId"], object["request_id"], object["id"], object["uuid"],
                    result?["id"]
                ])
                let sessionID = firstNonEmptyString([
                    object["sessionId"], object["session_id"], result?["sessionId"]
                ]) ?? file.deletingPathExtension().lastPathComponent
                let identity = requestID.map { "\(sessionID)|\($0)" }
                    ?? "\(file.path):\(lineNumber)"
                guard seen.insert(identity).inserted else { return }
                records.append(UsageRecord(
                    date: temporal.day,
                    timestamp: temporal.iso,
                    timestampEpoch: temporal.epoch,
                    tool: tool,
                    model: modelKey(firstNonEmptyString([
                        object["model"], object["modelId"], result?["model"], usageObject["model"]
                    ])),
                    usage: usage,
                    source: source,
                    requestID: requestID,
                    sessionID: sessionID,
                    sourcePath: file.path,
                    lineNumber: lineNumber,
                    dataSource: "local_transcript_result"
                ))
            }
        }

        let status: String
        if discovered.isEmpty { status = "missing" }
        else if files.isEmpty { status = "discovered_no_usage" }
        else if records.isEmpty { status = "missing_valid_rows" }
        else { status = "ok" }
        return CollectorResult(
            records: records,
            source: SourceInfo(status: status, files: files.count, records: records.count, strategy: "exact_result_usage"),
            inputURLs: files
        )
    }

    private static func collectDSHUsage(
        rootURL: URL? = nil,
        modifiedSince cutoffDate: Date?,
        zstdExecutableURLOverride: URL? = nil,
        discoverZstdDecoder: Bool = true
    ) -> CollectorResult {
        let root = rootURL ?? dshDefaultSessionsRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            return CollectorResult(records: [], source: SourceInfo(status: "missing", files: 0, records: 0))
        }
        let decoder = zstdExecutableURLOverride ?? (discoverZstdDecoder ? zstdExecutableURL() : nil)
        let compressedFiles = compressedDSHFiles(under: root, modifiedSince: cutoffDate)
        let allPlaintextFiles = usageLogFiles(at: root, modifiedSince: cutoffDate)
        let plaintextPaths = Set(allPlaintextFiles.map { $0.standardizedFileURL.path })
        let compressedPlaintextPaths = Set(compressedFiles.map {
            $0.deletingPathExtension().standardizedFileURL.path
        })
        let plaintextFiles = allPlaintextFiles.filter { file in
            decoder == nil || !compressedPlaintextPaths.contains(file.standardizedFileURL.path)
        }
        // A decodable .jsonl.zstd is authoritative over its same-name .jsonl.
        // When no decoder exists, retain the plaintext copy as a safe fallback.
        let files = compressedFiles + plaintextFiles
        var records: [UsageRecord] = []
        var seenEvents = Set<String>()
        var skippedCompressedFiles = 0
        var uncoveredCompressedFilesWithoutDecoder = 0

        func appendRecord(_ record: UsageRecord) {
            let fallback = "\(record.sourcePath ?? "unknown"):\(record.lineNumber ?? 0)"
            let identity = "\(record.sessionID ?? "unknown")|\(record.requestID ?? fallback)"
            guard seenEvents.insert(identity).inserted else { return }
            records.append(record)
        }

        for file in files {
            let data: Data?
            if file.pathExtension == "zstd" {
                guard let decoder else {
                    skippedCompressedFiles += 1
                    if !plaintextPaths.contains(file.deletingPathExtension().standardizedFileURL.path) {
                        uncoveredCompressedFilesWithoutDecoder += 1
                    }
                    continue
                }
                data = decodeZstdFile(file, executableURL: decoder)
                if data == nil {
                    skippedCompressedFiles += 1
                }
            } else {
                data = try? Data(contentsOf: file, options: .mappedIfSafe)
            }
            guard let data, let text = String(data: data, encoding: .utf8) else { continue }
            var provider = ""
            var model = "unknown"
            var currentStep = ""
            var stepHasUsageChunk = false
            var pendingMessageRecord: UsageRecord?
            var pendingChunkRecord: UsageRecord?
            for (offset, line) in text.split(whereSeparator: \.isNewline).enumerated() {
                guard let object = jsonObject(String(line)) else { continue }
                let type = nonEmptyString(object["type"] as? String) ?? ""
                let payload = object["data"] as? [String: Any] ?? object
                if type == "request/header" {
                    let header = payload["header"] as? [String: Any] ?? payload
                    let config = header["config"] as? [String: Any] ?? header
                    provider = nonEmptyString(config["provider"] as? String) ?? provider
                    model = modelKey(nonEmptyString(config["model"] as? String) ?? model)
                    continue
                }
                if type == "step/start" {
                    if let completed = pendingChunkRecord ?? pendingMessageRecord { appendRecord(completed) }
                    pendingMessageRecord = nil
                    pendingChunkRecord = nil
                    currentStep = firstNonEmptyString([payload["id"], payload["stepId"], object["seq"]])
                        ?? "step-\(offset + 1)"
                    stepHasUsageChunk = false
                    continue
                }
                if type == "step/end" {
                    if let completed = pendingChunkRecord ?? pendingMessageRecord { appendRecord(completed) }
                    pendingMessageRecord = nil
                    pendingChunkRecord = nil
                    stepHasUsageChunk = false
                    continue
                }

                var usageObject: [String: Any]?
                var isChunk = false
                if type == "assistant/chunk" {
                    let chunk = payload["chunk"] as? [String: Any] ?? payload
                    if (chunk["type"] as? String) == "usage" {
                        usageObject = chunk["usage"] as? [String: Any] ?? chunk
                        isChunk = true
                    }
                } else if type == "assistant/message", !stepHasUsageChunk {
                    usageObject = payload["usage"] as? [String: Any]
                }
                guard let usageObject,
                      let usage = portableUsage(from: usageObject, inputIncludesCachedTokens: false),
                      usage.totalTokens > 0,
                      let temporal = usageTemporalInfo(from: object)
                else { continue }
                let eventID = firstNonEmptyString([object["seq"], payload["id"]])
                    ?? "\(currentStep):\(offset + 1)"
                let record = UsageRecord(
                    date: temporal.day,
                    timestamp: temporal.iso,
                    timestampEpoch: temporal.epoch,
                    tool: "dsh",
                    model: model,
                    usage: usage,
                    source: .dsh,
                    requestID: eventID,
                    sessionID: file.deletingLastPathComponent().lastPathComponent,
                    sourcePath: file.path,
                    lineNumber: offset + 1,
                    dataSource: provider.isEmpty ? "dsh_session" : "dsh_session:\(provider)"
                )
                if isChunk {
                    stepHasUsageChunk = true
                    pendingMessageRecord = nil
                    pendingChunkRecord = record
                } else {
                    pendingMessageRecord = record
                }
            }
            if let completed = pendingChunkRecord ?? pendingMessageRecord { appendRecord(completed) }
        }

        let status: String
        if uncoveredCompressedFilesWithoutDecoder > 0, records.isEmpty { status = "missing_decoder" }
        else if uncoveredCompressedFilesWithoutDecoder > 0 { status = "partial_missing_decoder" }
        else if files.isEmpty { status = "discovered_no_usage" }
        else if records.isEmpty { status = "missing_valid_rows" }
        else { status = "ok" }
        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: status,
                files: files.count,
                records: records.count,
                skippedRecords: skippedCompressedFiles,
                strategy: "dsh_exact_usage_events_compressed_preferred_session_seq_dedupe"
            ),
            inputURLs: files
        )
    }

    private static func dshDefaultSessionsRoot(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = nonEmptyString(ProcessInfo.processInfo.environment["DSH_HOME"]) {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return homeURL.appendingPathComponent(".dsh/sessions", isDirectory: true)
    }

    private static func piDefaultSessionsRoot(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let raw = nonEmptyString(environment["PI_CODING_AGENT_SESSION_DIR"]) {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let raw = nonEmptyString(environment["PI_CODING_AGENT_DIR"]) {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return homeURL.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    }

    private static func collectPiUsage(
        sessionsRootURL: URL? = nil,
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let root = sessionsRootURL ?? piDefaultSessionsRoot()
        let rootExists = FileManager.default.fileExists(atPath: root.path)
        let files = jsonlFiles(under: root, modifiedSince: cutoffDate)
        var seen = Set<String>()
        var rawRecords = 0
        let records = collectPiLikeJSONLUsage(
            files: files,
            tool: "Pi",
            source: .pi,
            dataSource: "pi_session_jsonl",
            seen: &seen,
            rawRecords: &rawRecords
        )
        let status: String
        if !rootExists {
            status = "missing"
        } else if files.isEmpty {
            status = "discovered_no_usage"
        } else if records.isEmpty {
            status = "missing_valid_rows"
        } else {
            status = "ok"
        }
        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: status,
                files: files.count,
                records: records.count,
                rawRecords: rawRecords,
                dedupedRecords: records.count,
                strategy: "pi_session_usage"
            ),
            inputURLs: files
        )
    }

    private static func openClawDefaultRoots(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        if let raw = nonEmptyString(environment["OPENCLAW_HOME"]) {
            return [URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)]
        }
        if let raw = nonEmptyString(environment["OPENCLAW_STATE_DIR"]) {
            return [URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)]
        }
        return [homeURL.appendingPathComponent(".openclaw", isDirectory: true)]
    }

    private static func openClawDatabaseFiles(roots: [URL]) -> [URL] {
        collectNamedFiles(roots: roots) { url in
            url.lastPathComponent == "openclaw-agent.sqlite"
        }
    }

    private static func openClawTranscriptFiles(
        roots: [URL],
        modifiedSince cutoffDate: Date?
    ) -> [URL] {
        collectNamedFiles(roots: roots, modifiedSince: cutoffDate) { url in
            let name = url.lastPathComponent
            let isTranscript = name.hasSuffix(".jsonl")
                || name.contains(".jsonl.reset.")
                || name.contains(".jsonl.deleted.")
            guard isTranscript else { return false }
            return url.path.contains("/sessions/")
                || url.path.contains("/session-sqlite-import-archive/")
        }
    }

    private static func collectNamedFiles(
        roots: [URL],
        modifiedSince cutoffDate: Date? = nil,
        matching predicate: (URL) -> Bool
    ) -> [URL] {
        var files: [URL] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if predicate(root) { files.append(root) }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                guard predicate(url),
                      let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .contentModificationDateKey]
                      ),
                      values.isRegularFile == true
                else {
                    continue
                }
                if let cutoffDate,
                   let modifiedAt = values.contentModificationDate,
                   modifiedAt < cutoffDate {
                    continue
                }
                files.append(url)
            }
        }
        return Dictionary(grouping: files, by: \.path)
            .compactMap { _, duplicates in duplicates.first }
            .sorted { $0.path < $1.path }
    }

    private static func collectOpenClawUsage(
        rootURLs: [URL]? = nil,
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let roots = rootURLs ?? openClawDefaultRoots()
        let discoveredRoots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        let databases = openClawDatabaseFiles(roots: roots)
        let transcriptFiles = openClawTranscriptFiles(roots: roots, modifiedSince: cutoffDate)
        var records: [UsageRecord] = []
        var seen = Set<String>()
        var rawRecords = 0
        var readableDatabases = 0

        for database in databases {
            guard let columns = sqliteJSONRows(
                database: database,
                query: "pragma table_info(transcript_events)"
            ),
            Set(columns.compactMap { $0["name"] as? String })
                .isSuperset(of: ["session_id", "seq", "event_json", "created_at"])
            else {
                continue
            }
            let cutoffClause = cutoffDate.map {
                " where created_at >= \(Int($0.timeIntervalSince1970 * 1_000))"
            } ?? ""
            guard let rows = sqliteJSONRows(
                database: database,
                query: "select session_id, seq, event_json, created_at from transcript_events\(cutoffClause) order by session_id, seq"
            ) else {
                continue
            }
            readableDatabases += 1
            for row in rows {
                guard let raw = row["event_json"] as? String,
                      let data = raw.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continue
                }
                let sessionID = nonEmptyString(row["session_id"] as? String) ?? "unknown"
                let sequence = integerValue(row["seq"] as Any)
                if let result = piLikeUsageRecord(
                    object: object,
                    tool: "OpenClaw",
                    source: .openclaw,
                    dataSource: "openclaw_transcript_sqlite",
                    sourcePath: database.path,
                    lineNumber: sequence,
                    sessionID: sessionID,
                    fallbackEntryID: "sqlite:\(sessionID):\(sequence)"
                ) {
                    rawRecords += 1
                    guard seen.insert(result.identity).inserted else { continue }
                    records.append(result.record)
                }
            }
        }

        records.append(contentsOf: collectPiLikeJSONLUsage(
            files: transcriptFiles,
            tool: "OpenClaw",
            source: .openclaw,
            dataSource: "openclaw_transcript_jsonl",
            seen: &seen,
            rawRecords: &rawRecords
        ))

        let status: String
        if discoveredRoots.isEmpty {
            status = "missing"
        } else if databases.isEmpty && transcriptFiles.isEmpty {
            status = "discovered_no_usage"
        } else if !databases.isEmpty && readableDatabases == 0 && transcriptFiles.isEmpty {
            status = "schema_mismatch"
        } else if records.isEmpty {
            status = "missing_valid_rows"
        } else {
            status = "ok"
        }
        return CollectorResult(
            records: records,
            source: SourceInfo(
                status: status,
                files: databases.count + transcriptFiles.count,
                records: records.count,
                rawRecords: rawRecords,
                dedupedRecords: records.count,
                strategy: "openclaw_sqlite_and_legacy_transcripts"
            ),
            inputURLs: databases + transcriptFiles
        )
    }

    private static func collectPiLikeJSONLUsage(
        files: [URL],
        tool: String,
        source: UsageRecordSource,
        dataSource: String,
        seen: inout Set<String>,
        rawRecords: inout Int
    ) -> [UsageRecord] {
        var records: [UsageRecord] = []
        for file in files {
            var sessionID = file.lastPathComponent.components(separatedBy: ".jsonl").first
                ?? file.deletingPathExtension().lastPathComponent
            var matchedLineNumber = 0
            try? forEachLine(
                in: file,
                matchingAny: ["\"type\":\"session\"", "\"type\": \"session\"", "\"usage\""]
            ) { line in
                matchedLineNumber += 1
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return
                }
                if object["type"] as? String == "session",
                   let headerID = nonEmptyString(object["id"] as? String) {
                    sessionID = headerID
                    return
                }
                guard let result = piLikeUsageRecord(
                    object: object,
                    tool: tool,
                    source: source,
                    dataSource: dataSource,
                    sourcePath: file.path,
                    lineNumber: matchedLineNumber,
                    sessionID: sessionID,
                    fallbackEntryID: "file:\(file.path):\(matchedLineNumber)"
                ) else {
                    return
                }
                rawRecords += 1
                guard seen.insert(result.identity).inserted else { return }
                records.append(result.record)
            }
        }
        return records
    }

    private static func piLikeUsageRecord(
        object: [String: Any],
        tool: String,
        source: UsageRecordSource,
        dataSource: String,
        sourcePath: String,
        lineNumber: Int,
        sessionID: String,
        fallbackEntryID: String
    ) -> (identity: String, record: UsageRecord)? {
        guard object["type"] as? String == "message",
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let rawUsage = message["usage"] as? [String: Any]
        else {
            return nil
        }
        let input = max(0, integerValue(rawUsage["input"] as Any))
        let output = max(0, integerValue(rawUsage["output"] as Any))
        let cacheRead = max(0, integerValue(rawUsage["cacheRead"] as Any))
        let cacheWrite = max(0, integerValue(rawUsage["cacheWrite"] as Any))
        let reasoning = max(0, integerValue(rawUsage["reasoningTokens"] as Any))
        let explicitTotal = max(0, integerValue(rawUsage["totalTokens"] as Any))
        let baseTotal = input + output + cacheRead + cacheWrite
        let reasoningIsAdditional = reasoning > 0 && (explicitTotal == 0 || explicitTotal >= baseTotal + reasoning)
        let normalizedOutput = output + (reasoningIsAdditional ? reasoning : 0)
        let usage = canonicalUsageCounts(
            rawInputTokens: input,
            outputTokens: normalizedOutput,
            cacheCreationInputTokens: cacheWrite,
            cacheReadInputTokens: cacheRead,
            reasoningOutputTokens: min(reasoning, normalizedOutput),
            inputIncludesCachedTokens: false,
            explicitTotalTokens: explicitTotal,
            explicitTotalIsAuthoritative: explicitTotal > 0
        )
        guard usage.totalTokens > 0 else { return nil }

        let timestampEpoch: Double?
        if let direct = epochSeconds(message["timestamp"]) {
            timestampEpoch = direct
        } else if let raw = object["timestamp"] as? String,
                  let date = parseISO(raw) {
            timestampEpoch = date.timeIntervalSince1970
        } else {
            timestampEpoch = epochSeconds(object["timestamp"])
        }
        guard let timestampEpoch else { return nil }
        let date = Date(timeIntervalSince1970: timestampEpoch)
        let entryID = nonEmptyString(object["id"] as? String) ?? fallbackEntryID
        let identity = "\(sessionID):\(entryID)"
        let costObject = rawUsage["cost"] as? [String: Any]
        let cost = costObject?.keys.contains("total") == true
            ? max(0, doubleValue(costObject?["total"] as Any))
            : nil
        let content = message["content"] as? [[String: Any]] ?? []
        let toolCalls = content.filter { $0["type"] as? String == "toolCall" }.count
        return (
            identity,
            UsageRecord(
                date: dayFormatter.string(from: date),
                timestamp: isoFormatterWithFractional.string(from: date),
                timestampEpoch: timestampEpoch,
                tool: tool,
                model: modelKey(message["model"] as? String),
                usage: usage,
                costUSD: cost,
                source: source,
                requestID: entryID,
                sessionID: nonEmptyString(sessionID),
                sourcePath: sourcePath,
                lineNumber: lineNumber,
                dataSource: dataSource,
                modelRequestCount: 1,
                toolCallCount: toolCalls
            )
        )
    }

    private static func collectQwenCodeUsage(
        rootURL: URL? = nil,
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let root = rootURL ?? qwenCodeDefaultRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "missing", files: 0, records: 0)
            )
        }

        let files = jsonlFiles(
            under: root.appendingPathComponent("usage", isDirectory: true),
            modifiedSince: cutoffDate
        ).filter {
            $0.lastPathComponent.hasPrefix("token-usage-")
        }
        var records: [UsageRecord] = []
        var seenIDs = Set<String>()

        for file in files {
            var matchedLineNumber = 0
            try? forEachLine(in: file, matchingAny: ["\"schemaVersion\"", "\"inputTokens\""]) { line in
                matchedLineNumber += 1
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      integerValue(object["schemaVersion"] as Any) == 1,
                      let id = nonEmptyString(object["id"] as? String),
                      seenIDs.insert(id).inserted,
                      let timestamp = nonEmptyString(object["timestamp"] as? String)
                else {
                    return
                }

                let parsedDate = parseISO(timestamp)
                let day = parsedDate.map(dayFormatter.string(from:))
                    ?? nonEmptyString(object["localDate"] as? String)
                guard let day else { return }

                let input = integerValue(object["inputTokens"] as Any)
                let output = integerValue(object["outputTokens"] as Any)
                let cached = integerValue(object["cachedTokens"] as Any)
                let thoughts = integerValue(object["thoughtsTokens"] as Any)
                let total = integerValue(object["totalTokens"] as Any)
                let usage = canonicalUsageCounts(
                    rawInputTokens: input,
                    outputTokens: output + thoughts,
                    cacheReadInputTokens: cached,
                    reasoningOutputTokens: thoughts,
                    inputIncludesCachedTokens: true,
                    explicitTotalTokens: total,
                    explicitTotalIsAuthoritative: true
                )
                guard usage.totalTokens > 0 else { return }

                records.append(UsageRecord(
                    date: day,
                    timestamp: timestamp,
                    timestampEpoch: parsedDate?.timeIntervalSince1970,
                    tool: "Qwen Code",
                    model: modelKey(object["model"] as? String),
                    usage: usage,
                    source: .qwen,
                    requestID: id,
                    sessionID: nonEmptyString(object["sessionId"] as? String),
                    sourcePath: file.path,
                    lineNumber: matchedLineNumber,
                    dataSource: nonEmptyString(object["source"] as? String),
                    modelRequestCount: 1
                ))
            }
        }

        let status: String
        if files.isEmpty {
            status = "discovered_no_usage"
        } else if records.isEmpty {
            status = "missing_valid_rows"
        } else {
            status = "ok"
        }
        return CollectorResult(
            records: records,
            source: SourceInfo(status: status, files: files.count, records: records.count),
            inputURLs: files
        )
    }

    private static func qwenCodeDefaultRoot(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let environment = ProcessInfo.processInfo.environment
        for key in ["QWEN_RUNTIME_DIR", "QWEN_HOME"] {
            guard let raw = nonEmptyString(environment[key]) else { continue }
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return homeURL.appendingPathComponent(".qwen", isDirectory: true)
    }

    private static func collectGrokBuildUsage(
        rootURL: URL? = nil,
        modifiedSince cutoffDate: Date?
    ) -> CollectorResult {
        let root = rootURL ?? grokBuildDefaultRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "missing", files: 0, records: 0)
            )
        }

        let files = jsonlFiles(
            under: root.appendingPathComponent("sessions", isDirectory: true),
            modifiedSince: cutoffDate
        ).filter { $0.lastPathComponent == "updates.jsonl" }
        var records: [UsageRecord] = []
        var seenEvents = Set<String>()

        for file in files {
            let sessionID = nonEmptyString(file.deletingLastPathComponent().lastPathComponent)
            let fallbackModel = grokBuildFallbackModel(for: file)
            var matchedLineNumber = 0
            try? forEachLine(in: file, matchingAny: ["\"turn_completed\"", "\"usage\""]) { line in
                matchedLineNumber += 1
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let params = object["params"] as? [String: Any],
                      let update = params["update"] as? [String: Any],
                      update["sessionUpdate"] as? String == "turn_completed",
                      let topLevelUsage = update["usage"] as? [String: Any]
                else {
                    return
                }

                let metadata = params["_meta"] as? [String: Any]
                    ?? object["_meta"] as? [String: Any]
                let timestampValue = metadata?["agentTimestampMs"]
                    ?? metadata?["timestampMs"]
                    ?? object["timestamp_ms"]
                    ?? object["timestamp"]
                    ?? object["time"]
                guard let timestampValue,
                      let day = dayString(fromEpoch: timestampValue)
                else {
                    return
                }

                let baseEventID = nonEmptyString(metadata?["eventId"] as? String)
                    ?? nonEmptyString(object["eventId"] as? String)
                    ?? nonEmptyString(object["id"] as? String)
                    ?? nonEmptyString(update["prompt_id"] as? String)
                    ?? "line-\(matchedLineNumber)"
                let modelUsage = topLevelUsage["modelUsage"] as? [String: Any]
                let candidates: [(String, [String: Any])]
                if let modelUsage, !modelUsage.isEmpty {
                    candidates = modelUsage.compactMap { model, value in
                        (value as? [String: Any]).map { (model, $0) }
                    }.sorted { $0.0 < $1.0 }
                } else {
                    candidates = [(fallbackModel, topLevelUsage)]
                }

                for (rawModel, usageObject) in candidates {
                    guard let usage = grokBuildUsage(from: usageObject),
                          usage.counts.totalTokens > 0
                    else {
                        continue
                    }
                    let model = grokBuildModel(rawModel)
                    let identity = "\(sessionID ?? "unknown")|\(baseEventID)|\(model)"
                    guard seenEvents.insert(identity).inserted else { continue }
                    records.append(UsageRecord(
                        date: day,
                        timestamp: isoString(fromEpoch: timestampValue),
                        timestampEpoch: epochSeconds(timestampValue),
                        tool: "Grok",
                        model: model,
                        usage: usage.counts,
                        costUSD: usage.costUSD,
                        source: .grok,
                        requestID: baseEventID,
                        sessionID: sessionID,
                        sourcePath: file.path,
                        lineNumber: matchedLineNumber,
                        modelRequestCount: max(1, usage.modelCalls)
                    ))
                }
            }
        }

        let status: String
        if files.isEmpty {
            status = "discovered_no_usage"
        } else if records.isEmpty {
            status = "missing_valid_rows"
        } else {
            status = "ok"
        }
        return CollectorResult(
            records: records,
            source: SourceInfo(status: status, files: files.count, records: records.count),
            inputURLs: files
        )
    }

    private static func grokBuildFallbackModel(for updatesURL: URL) -> String {
        let signalsURL = updatesURL.deletingLastPathComponent().appendingPathComponent("signals.json")
        guard let data = try? Data(contentsOf: signalsURL),
              let signals = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "grok-build"
        }
        if let primary = nonEmptyString(signals["primaryModelId"] as? String) {
            return primary
        }
        if let models = signals["modelsUsed"] as? [String],
           let first = models.compactMap(nonEmptyString).first {
            return first
        }
        return nonEmptyString(signals["model"] as? String) ?? "grok-build"
    }

    private static func grokBuildDefaultRoot(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let environment = ProcessInfo.processInfo.environment
        for key in ["TOKENTRACKER_GROK_HOME", "GROK_HOME"] {
            guard let raw = nonEmptyString(environment[key]) else { continue }
            return URL(
                fileURLWithPath: (raw as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return homeURL.appendingPathComponent(".grok", isDirectory: true)
    }

    private static func grokBuildModel(_ value: String) -> String {
        let model = modelKey(value)
        let lower = model.lowercased()
        if lower.contains("build-free") || lower.hasSuffix("-free") || lower.contains("free-tier") {
            return "grok-build-free"
        }
        if lower == "grok-4.5-build" || lower == "grok-4-5-build" {
            return "grok-4.5-build"
        }
        return model
    }

    private static func grokBuildUsage(
        from usage: [String: Any]
    ) -> (counts: TokenUsageCounts, costUSD: Double?, modelCalls: Int)? {
        let camelCaseInput = usage.keys.contains("inputTokens")
        let rawInput = firstIntegerValue(in: usage, keys: ["inputTokens", "input_tokens"])
        let cacheRead = firstIntegerValue(
            in: usage,
            keys: ["cachedReadTokens", "cacheReadInputTokens", "cache_read_input_tokens", "cached_input_tokens"]
        )
        let cacheCreation = firstIntegerValue(
            in: usage,
            keys: ["cacheCreationTokens", "cachedWriteTokens", "cacheWriteInputTokens", "cache_creation_input_tokens"]
        )
        let rawOutput = firstIntegerValue(in: usage, keys: ["outputTokens", "output_tokens"])
        let reasoning = firstIntegerValue(
            in: usage,
            keys: ["reasoningTokens", "reasoning_output_tokens"]
        )
        let freshInput = camelCaseInput
            ? max(0, rawInput - cacheRead - cacheCreation)
            : rawInput
        let reportedTotal = firstIntegerValue(in: usage, keys: ["totalTokens", "total_tokens"])
        let counts = canonicalUsageCounts(
            rawInputTokens: freshInput,
            outputTokens: rawOutput,
            cacheCreationInputTokens: cacheCreation,
            cacheReadInputTokens: cacheRead,
            reasoningOutputTokens: min(rawOutput, reasoning),
            inputIncludesCachedTokens: false,
            explicitTotalTokens: reportedTotal,
            explicitTotalIsAuthoritative: true
        )
        guard counts.totalTokens > 0 else { return nil }

        let partial = (usage["costIsPartial"] as? Bool)
            ?? (usage["cost_is_partial"] as? Bool)
            ?? false
        let incomplete = (usage["usageIsIncomplete"] as? Bool)
            ?? (usage["usage_is_incomplete"] as? Bool)
            ?? false
        let costUSD: Double?
        if partial || incomplete {
            costUSD = nil
        } else if let ticksValue = [
            usage["costUsdTicks"],
            usage["totalCostUsdTicks"],
            usage["cost_usd_ticks"],
            usage["total_cost_usd_ticks"]
        ].compactMap({ $0 }).first {
            costUSD = max(0, doubleValue(ticksValue) / 10_000_000_000)
        } else if let usdValue = [
            usage["costUsd"],
            usage["totalCostUsd"],
            usage["cost_usd"],
            usage["total_cost_usd"]
        ].compactMap({ $0 }).first {
            costUSD = max(0, doubleValue(usdValue))
        } else {
            costUSD = nil
        }
        let modelCalls = firstIntegerValue(in: usage, keys: ["modelCalls", "model_calls"])
        return (counts, costUSD, modelCalls)
    }

    private static func collectOpenCodeUsage(rootURL: URL? = nil) -> CollectorResult {
        let root = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "missing", files: 0, records: 0)
            )
        }

        let databases = openCodeDatabaseURLs(rootURL: root)
        guard !databases.isEmpty else {
            return CollectorResult(
                records: [],
                source: SourceInfo(status: "missing_db", files: 0, records: 0)
            )
        }

        var recordsByIdentity: [String: UsageRecord] = [:]
        var validLayouts = 0
        var failedQueries = 0

        for database in databases {
            for table in ["message", "session_message"] {
                guard let columns = sqliteJSONRows(
                    database: database,
                    query: "pragma table_info('\(table)')"
                ) else {
                    failedQueries += 1
                    continue
                }
                let availableColumns = Set(columns.compactMap { $0["name"] as? String })
                guard availableColumns.contains("data"),
                      availableColumns.contains("id"),
                      availableColumns.contains("session_id")
                else {
                    continue
                }
                validLayouts += 1

                let timeUpdatedExpression = availableColumns.contains("time_updated")
                    ? "time_updated"
                    : "null"
                let assistantPredicate = table == "session_message" && availableColumns.contains("type")
                    ? "type = 'assistant'"
                    : "json_extract(data, '$.role') = 'assistant'"
                let query = openCodeUsageQuery(
                    table: table,
                    timeUpdatedExpression: timeUpdatedExpression,
                    assistantPredicate: assistantPredicate
                )
                guard let rows = sqliteJSONRows(database: database, query: query) else {
                    failedQueries += 1
                    continue
                }

                for row in rows {
                    guard let timestampValue = row["event_time"],
                          let day = dayString(fromEpoch: timestampValue)
                    else {
                        continue
                    }

                    let reasoning = max(0, integerValue(row["reasoning_tokens"] as Any))
                    let usage = canonicalUsageCounts(
                        rawInputTokens: integerValue(row["input_tokens"] as Any),
                        outputTokens: integerValue(row["output_tokens"] as Any) + reasoning,
                        cacheCreationInputTokens: integerValue(row["cache_write_tokens"] as Any),
                        cacheReadInputTokens: integerValue(row["cache_read_tokens"] as Any),
                        reasoningOutputTokens: reasoning,
                        inputIncludesCachedTokens: false
                    )
                    guard usage.totalTokens > 0 else { continue }

                    let messageID = nonEmptyString(row["message_id"] as? String)
                    let sessionID = nonEmptyString(row["session_id"] as? String)
                    let rowID = integerValue(row["row_id"] as Any)
                    let identity = [sessionID, messageID].compactMap { $0 }.joined(separator: "|")
                    let fallbackIdentity = "\(database.path)|\(table)|\(rowID)"
                    let record = UsageRecord(
                        date: day,
                        timestamp: isoString(fromEpoch: timestampValue),
                        timestampEpoch: epochSeconds(timestampValue),
                        tool: "OpenCode",
                        model: modelKey(row["display_model"] as? String),
                        usage: usage,
                        source: .opencode,
                        requestID: messageID,
                        sessionID: sessionID,
                        sourcePath: database.path,
                        dataSource: table,
                        modelRequestCount: 1
                    )
                    let key = identity.isEmpty ? fallbackIdentity : identity
                    if let existing = recordsByIdentity[key] {
                        let existingTime = existing.timestampEpoch ?? 0
                        let candidateTime = record.timestampEpoch ?? 0
                        if candidateTime > existingTime ||
                            (candidateTime == existingTime && record.usage.totalTokens > existing.usage.totalTokens) {
                            recordsByIdentity[key] = record
                        }
                    } else {
                        recordsByIdentity[key] = record
                    }
                }
            }
        }

        let records = recordsByIdentity.values.sorted { lhs, rhs in
            let lhsTimestamp = lhs.timestampEpoch ?? 0
            let rhsTimestamp = rhs.timestampEpoch ?? 0
            if lhsTimestamp != rhsTimestamp {
                return lhsTimestamp < rhsTimestamp
            }

            let lhsSessionID = lhs.sessionID ?? ""
            let rhsSessionID = rhs.sessionID ?? ""
            if lhsSessionID != rhsSessionID {
                return lhsSessionID < rhsSessionID
            }

            return (lhs.requestID ?? "") < (rhs.requestID ?? "")
        }
        let status: String
        if !records.isEmpty {
            status = "ok"
        } else if validLayouts == 0 {
            status = failedQueries > 0 ? "schema_unreadable" : "schema_mismatch"
        } else if failedQueries >= validLayouts {
            status = "query_failed"
        } else {
            status = "missing_valid_rows"
        }
        return CollectorResult(
            records: records,
            source: SourceInfo(status: status, files: databases.count, records: records.count),
            inputURLs: databases
        )
    }

    private static func openCodeDatabaseURLs(rootURL: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return [rootURL]
        }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let extensions: Set<String> = ["db", "sqlite", "sqlite3"]
        return children.filter { url in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return name.hasPrefix("opencode") && extensions.contains(url.pathExtension.lowercased())
        }.sorted { $0.path < $1.path }
    }

    private static func openCodeUsageQuery(
        table: String,
        timeUpdatedExpression: String,
        assistantPredicate: String
    ) -> String {
        """
        select
            rowid as row_id,
            id as message_id,
            session_id,
            coalesce(
                json_extract(data, '$.time.completed'),
                json_extract(data, '$.time.created'),
                \(timeUpdatedExpression)
            ) as event_time,
            coalesce(
                json_extract(data, '$.modelID'),
                case when json_type(data, '$.model') = 'text' then json_extract(data, '$.model') end,
                json_extract(data, '$.model.id'),
                json_extract(data, '$.modelId'),
                'unknown'
            ) as display_model,
            coalesce(json_extract(data, '$.tokens.input'), 0) as input_tokens,
            coalesce(json_extract(data, '$.tokens.output'), 0) as output_tokens,
            coalesce(json_extract(data, '$.tokens.reasoning'), 0) as reasoning_tokens,
            coalesce(json_extract(data, '$.tokens.cache.read'), 0) as cache_read_tokens,
            coalesce(json_extract(data, '$.tokens.cache.write'), 0) as cache_write_tokens
        from \(table)
        where json_valid(data) = 1
            and \(assistantPredicate)
            and (
                coalesce(json_extract(data, '$.tokens.input'), 0)
                + coalesce(json_extract(data, '$.tokens.output'), 0)
                + coalesce(json_extract(data, '$.tokens.reasoning'), 0)
                + coalesce(json_extract(data, '$.tokens.cache.read'), 0)
                + coalesce(json_extract(data, '$.tokens.cache.write'), 0)
            ) > 0
        order by event_time, rowid
        """
    }

    private static func firstIntegerValue(in object: [String: Any], keys: [String]) -> Int {
        for key in keys where object.keys.contains(key) {
            return max(0, integerValue(object[key] as Any))
        }
        return 0
    }

    private static func firstNonEmptyString(_ values: [Any?]) -> String? {
        for value in values {
            if let string = value as? String, let result = nonEmptyString(string) {
                return result
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func portableUsage(
        from raw: [String: Any],
        inputIncludesCachedTokens: Bool
    ) -> TokenUsageCounts? {
        let rawInput = firstIntegerValue(in: raw, keys: [
            "input_tokens", "inputTokens", "prompt_tokens", "promptTokens", "promptTokenCount", "input"
        ])
        let rawOutput = firstIntegerValue(in: raw, keys: [
            "output_tokens", "outputTokens", "completion_tokens", "completionTokens", "candidatesTokenCount", "output"
        ])
        let cacheRead = firstIntegerValue(in: raw, keys: [
            "cache_read_input_tokens", "cacheReadInputTokens", "cacheReadTokens",
            "cache_read_tokens", "cached_input_tokens", "cachedContentTokenCount", "prompt_cache_hit_tokens"
        ])
        let cacheCreation = firstIntegerValue(in: raw, keys: [
            "cache_creation_input_tokens", "cacheCreationInputTokens", "cacheCreationTokens",
            "cache_creation_tokens", "cache_write_input_tokens", "cacheWriteTokens",
            "cache_write_tokens", "prompt_cache_write_tokens"
        ])
        let reasoning = firstIntegerValue(in: raw, keys: [
            "reasoning_output_tokens", "reasoningTokens", "reasoning_tokens",
            "thinkingTokens", "thinking_tokens", "thoughtsTokenCount"
        ])
        let explicitTotal = firstIntegerValue(in: raw, keys: [
            "total_tokens", "totalTokens", "totalTokenCount", "total"
        ])
        // Gemini reports candidate tokens and thinking tokens separately while
        // totalTokenCount includes both. TokenFleet's output bucket is the
        // inclusive completion total, with reasoning retained as a subset.
        let output = raw.keys.contains("thoughtsTokenCount")
            ? rawOutput + reasoning
            : rawOutput
        let usage = canonicalUsageCounts(
            rawInputTokens: rawInput,
            outputTokens: output,
            cacheCreationInputTokens: cacheCreation,
            cacheReadInputTokens: cacheRead,
            reasoningOutputTokens: reasoning,
            inputIncludesCachedTokens: inputIncludesCachedTokens,
            explicitTotalTokens: explicitTotal,
            explicitTotalIsAuthoritative: explicitTotal > 0
        )
        return usage.totalTokens > 0 ? usage : nil
    }

    private static func firstNestedDictionary(
        in object: [String: Any],
        keys: [String]
    ) -> [String: Any]? {
        for key in keys {
            if let value = object[key] as? [String: Any] { return value }
        }
        for value in object.values {
            if let dictionary = value as? [String: Any],
               let found = firstNestedDictionary(in: dictionary, keys: keys) {
                return found
            }
        }
        return nil
    }

    private static func usageTemporalInfo(
        from object: [String: Any]
    ) -> (day: String, iso: String?, epoch: TimeInterval?)? {
        let candidates: [Any?] = [
            object["timestamp"], object["created_at"], object["createdAt"],
            object["time"], object["event_time"], object["date"]
        ]
        for candidate in candidates {
            if let string = candidate as? String,
               let date = parseISO(string) {
                return (
                    dayFormatter.string(from: date),
                    isoFormatterWithFractional.string(from: date),
                    date.timeIntervalSince1970
                )
            }
            if let epoch = epochSeconds(candidate) {
                let date = Date(timeIntervalSince1970: epoch)
                return (
                    dayFormatter.string(from: date),
                    isoFormatterWithFractional.string(from: date),
                    epoch
                )
            }
        }
        for key in ["message", "result", "data"] {
            if let nested = object[key] as? [String: Any],
               let result = usageTemporalInfo(from: nested) {
                return result
            }
        }
        return nil
    }

    private static func otelTemporalInfo(
        from span: [String: Any]
    ) -> (day: String, iso: String?, epoch: TimeInterval?)? {
        for key in ["startTimeUnixNano", "start_time_unix_nano"] {
            if let raw = firstNonEmptyString([span[key]]), let nanos = Double(raw) {
                let epoch = nanos / 1_000_000_000
                let date = Date(timeIntervalSince1970: epoch)
                return (dayFormatter.string(from: date), isoFormatterWithFractional.string(from: date), epoch)
            }
        }
        for key in ["startTime", "start_time", "timestamp", "time"] {
            if let pair = span[key] as? [Any], let seconds = pair.first {
                let epoch = doubleValue(seconds)
                    + (pair.count > 1 ? doubleValue(pair[1]) / 1_000_000_000 : 0)
                if epoch > 0 {
                    let date = Date(timeIntervalSince1970: epoch)
                    return (dayFormatter.string(from: date), isoFormatterWithFractional.string(from: date), epoch)
                }
            }
        }
        return usageTemporalInfo(from: span)
    }

    private static func otelSpanEnvelopes(
        in object: [String: Any],
        inheritedAttributes: [String: Any] = [:]
    ) -> [(span: [String: Any], attributes: [String: Any])] {
        var inherited = inheritedAttributes
        if let resource = object["resource"] as? [String: Any] {
            inherited.merge(otelAttributes(resource["attributes"]), uniquingKeysWith: { _, child in child })
        }
        var results: [(span: [String: Any], attributes: [String: Any])] = []
        if object["name"] != nil || object["spanName"] != nil {
            var attributes = inherited
            attributes.merge(otelAttributes(object["attributes"]), uniquingKeysWith: { _, child in child })
            results.append((object, attributes))
        }
        for (key, value) in object where key != "attributes" && key != "resource" {
            if let nested = value as? [String: Any] {
                results.append(contentsOf: otelSpanEnvelopes(in: nested, inheritedAttributes: inherited))
            } else if let array = value as? [Any] {
                for case let nested as [String: Any] in array {
                    results.append(contentsOf: otelSpanEnvelopes(in: nested, inheritedAttributes: inherited))
                }
            }
        }
        return results
    }

    private static func otelAttributes(_ value: Any?) -> [String: Any] {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(otelScalar)
        }
        guard let rows = value as? [[String: Any]] else { return [:] }
        var result: [String: Any] = [:]
        for row in rows {
            guard let key = nonEmptyString(row["key"] as? String) else { continue }
            result[key] = otelScalar(row["value"])
        }
        return result
    }

    private static func otelScalar(_ value: Any?) -> Any {
        guard let dictionary = value as? [String: Any] else { return value ?? NSNull() }
        for key in ["stringValue", "intValue", "doubleValue", "boolValue", "string_value", "int_value"] {
            if let scalar = dictionary[key] { return scalar }
        }
        return value ?? NSNull()
    }

    private static func deduplicateCrossSource(
        nativeRecords: [UsageRecord],
        proxyRecords: [UsageRecord]
    ) -> CrossSourceDedupeResult {
        var enrichedNativeRecords = nativeRecords
        let deduplicableProxyIndices = proxyRecords.indices.filter {
            isDeduplicableProxyRecord(proxyRecords[$0])
        }
        var matchedProxyIndices = Set<Int>()
        var matchedNativeIndices = Set<Int>()
        let skippedProxyRecords = 0

        let exactPairs = uniqueDedupePairs(
            proxyIndices: deduplicableProxyIndices,
            nativeIndices: Array(nativeRecords.indices)
        ) { proxyIndex, nativeIndex in
            isSameDedupeDomain(
                proxyRecord: proxyRecords[proxyIndex],
                nativeRecord: nativeRecords[nativeIndex]
            ) && hasExactIdentifierMatch(
                proxyRecord: proxyRecords[proxyIndex],
                nativeRecord: nativeRecords[nativeIndex]
            )
        }
        applyDedupePairs(
            exactPairs,
            proxyRecords: proxyRecords,
            enrichedNativeRecords: &enrichedNativeRecords,
            matchedProxyIndices: &matchedProxyIndices,
            matchedNativeIndices: &matchedNativeIndices
        )

        // Similar timing/model/token vectors alone are not proof of identity:
        // concurrent requests can legitimately look the same. Keep those rows and
        // expose the possible overlap count instead of silently deleting usage.
        let possibleOverlapRecords = deduplicableProxyIndices.filter { proxyIndex in
            guard !matchedProxyIndices.contains(proxyIndex) else { return false }
            return nativeRecords.indices.contains { nativeIndex in
                guard !matchedNativeIndices.contains(nativeIndex) else { return false }
                return isSameDedupeDomain(
                    proxyRecord: proxyRecords[proxyIndex],
                    nativeRecord: nativeRecords[nativeIndex]
                ) && areTimestampsClose(
                    proxyRecords[proxyIndex].timestamp,
                    nativeRecords[nativeIndex].timestamp,
                    seconds: 10
                ) && modelsCompatible(
                    proxyRecords[proxyIndex].model,
                    nativeRecords[nativeIndex].model
                ) && usageVectorsClose(
                    proxyRecord: proxyRecords[proxyIndex],
                    nativeRecord: nativeRecords[nativeIndex]
                )
            }
        }.count

        let keptProxyRecords = proxyRecords.indices
            .filter { !matchedProxyIndices.contains($0) }
            .map { proxyRecords[$0] }
        return CrossSourceDedupeResult(
            records: enrichedNativeRecords + keptProxyRecords,
            rawProxyRecords: proxyRecords.count,
            keptProxyRecords: keptProxyRecords.count,
            dedupedProxyRecords: matchedProxyIndices.count,
            possibleOverlapRecords: possibleOverlapRecords,
            skippedProxyRecords: skippedProxyRecords
        )
    }

    private static func uniqueDedupePairs(
        proxyIndices: [Int],
        nativeIndices: [Int],
        matches: (Int, Int) -> Bool
    ) -> [(proxy: Int, native: Int)] {
        var nativeCandidatesByProxy: [Int: [Int]] = [:]
        var proxyCandidateCountByNative: [Int: Int] = [:]
        for proxyIndex in proxyIndices {
            let candidates = nativeIndices.filter { matches(proxyIndex, $0) }
            nativeCandidatesByProxy[proxyIndex] = candidates
            for nativeIndex in candidates {
                proxyCandidateCountByNative[nativeIndex, default: 0] += 1
            }
        }
        return proxyIndices.compactMap { proxyIndex in
            guard let candidates = nativeCandidatesByProxy[proxyIndex],
                  candidates.count == 1,
                  let nativeIndex = candidates.first,
                  proxyCandidateCountByNative[nativeIndex] == 1
            else {
                return nil
            }
            return (proxy: proxyIndex, native: nativeIndex)
        }
    }

    private static func applyDedupePairs(
        _ pairs: [(proxy: Int, native: Int)],
        proxyRecords: [UsageRecord],
        enrichedNativeRecords: inout [UsageRecord],
        matchedProxyIndices: inout Set<Int>,
        matchedNativeIndices: inout Set<Int>
    ) {
        for pair in pairs {
            enrichedNativeRecords[pair.native] = enrichedRecord(
                enrichedNativeRecords[pair.native],
                withProxyCostFrom: proxyRecords[pair.proxy]
            )
            matchedProxyIndices.insert(pair.proxy)
            matchedNativeIndices.insert(pair.native)
        }
    }

    private static func sourceInfo(
        _ source: SourceInfo,
        annotatedWith result: CrossSourceDedupeResult
    ) -> SourceInfo {
        var annotated = source
        annotated.rawRecords = result.rawProxyRecords
        annotated.dedupedRecords = result.dedupedProxyRecords
        annotated.possibleOverlapRecords = result.possibleOverlapRecords
        annotated.skippedRecords = result.skippedProxyRecords
        annotated.strategy = "request_level_dedupe"
        annotated.records = result.keptProxyRecords
        if source.status == "ok",
           result.rawProxyRecords > 0,
           result.keptProxyRecords == 0,
           result.dedupedProxyRecords > 0 {
            annotated.status = "all_deduped"
        }
        return annotated
    }

    private static func isDeduplicableProxyRecord(_ record: UsageRecord) -> Bool {
        guard record.source == .ccSwitchProxy else { return false }
        guard let family = toolFamily(for: record.tool) else { return false }
        return family == "claude" || family == "codex"
    }

    private static func isSameDedupeDomain(proxyRecord: UsageRecord, nativeRecord: UsageRecord) -> Bool {
        guard proxyRecord.date == nativeRecord.date,
              let proxyFamily = toolFamily(for: proxyRecord.tool),
              let nativeFamily = toolFamily(for: nativeRecord.tool),
              proxyFamily == nativeFamily,
              nativeRecord.source != .ccSwitchProxy
        else {
            return false
        }
        return true
    }

    private static func hasExactIdentifierMatch(proxyRecord: UsageRecord, nativeRecord: UsageRecord) -> Bool {
        let proxyIDs = Set([proxyRecord.requestID, proxyRecord.responseID].compactMap(nonEmptyString))
        let nativeIDs = Set([nativeRecord.requestID, nativeRecord.responseID].compactMap(nonEmptyString))
        return !proxyIDs.isDisjoint(with: nativeIDs)
    }

    private static func enrichedRecord(
        _ nativeRecord: UsageRecord,
        withProxyCostFrom proxyRecord: UsageRecord
    ) -> UsageRecord {
        var record = nativeRecord
        if record.costUSD == nil,
           let proxyCost = proxyRecord.costUSD,
           proxyCost > 0 {
            record.costUSD = proxyCost
        }
        return record
    }

    private static func toolFamily(for tool: String) -> String? {
        let value = tool.lowercased()
        if value.contains("claude") { return "claude" }
        if value.contains("codex") { return "codex" }
        if value.contains("gemini") { return "gemini" }
        return nil
    }

    private static func areTimestampsClose(_ lhs: String?, _ rhs: String?, seconds: TimeInterval) -> Bool {
        guard let lhs,
              let rhs,
              let lhsDate = parseISO(lhs),
              let rhsDate = parseISO(rhs)
        else {
            return false
        }
        return abs(lhsDate.timeIntervalSince(rhsDate)) <= seconds
    }

    private static func modelsCompatible(_ lhs: String, _ rhs: String) -> Bool {
        let left = canonicalModel(lhs)
        let right = canonicalModel(rhs)
        if left == right { return true }
        guard left != "unknown",
              right != "unknown",
              min(left.count, right.count) >= 8
        else {
            return false
        }
        return left.contains(right) || right.contains(left)
    }

    private static func canonicalModel(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func usageVectorsClose(_ lhs: TokenUsageCounts, _ rhs: TokenUsageCounts) -> Bool {
        guard tokenValuesClose(lhs.totalTokens, rhs.totalTokens) else { return false }
        let pairs = [
            (lhs.inputTokens, rhs.inputTokens),
            (lhs.outputTokens, rhs.outputTokens),
            (lhs.cacheCreationInputTokens, rhs.cacheCreationInputTokens),
            (lhs.cacheReadInputTokens, rhs.cacheReadInputTokens),
            (lhs.reasoningOutputTokens, rhs.reasoningOutputTokens)
        ]
        return pairs.allSatisfy { pair in
            let left = pair.0
            let right = pair.1
            return left == 0 && right == 0 || tokenValuesClose(left, right)
        }
    }

    private static func usageVectorsClose(proxyRecord: UsageRecord, nativeRecord: UsageRecord) -> Bool {
        guard toolFamily(for: proxyRecord.tool) == "codex",
              toolFamily(for: nativeRecord.tool) == "codex"
        else {
            return usageVectorsClose(proxyRecord.usage, nativeRecord.usage)
        }

        let proxy = proxyRecord.usage
        let native = nativeRecord.usage
        guard tokenValuesClose(proxy.outputTokens, native.outputTokens),
              tokenValuesClose(proxy.cacheReadInputTokens, native.cacheReadInputTokens),
              tokenValuesClose(proxy.cacheCreationInputTokens, native.cacheCreationInputTokens)
        else {
            return false
        }

        // Native Codex reports cached input as a subset of input. CC Switch versions
        // have emitted input both inclusive and exclusive of cached input, so compare
        // both canonical interpretations without changing either source's stored data.
        let nativeUncachedInput = max(0, native.inputTokens - native.cacheReadInputTokens)
        let inputMatches = tokenValuesClose(proxy.inputTokens, native.inputTokens)
            || tokenValuesClose(proxy.inputTokens, nativeUncachedInput)
        guard inputMatches else { return false }

        let proxyProcessedCandidates = [
            proxy.inputTokens + proxy.outputTokens,
            proxy.inputTokens + proxy.cacheReadInputTokens + proxy.cacheCreationInputTokens + proxy.outputTokens
        ]
        return proxyProcessedCandidates.contains { tokenValuesClose($0, native.totalTokens) }
    }

    private static func tokenValuesClose(_ lhs: Int, _ rhs: Int) -> Bool {
        if lhs == rhs { return true }
        let baseline = max(lhs, rhs)
        guard baseline > 0 else { return true }
        let tolerance = max(4, Int((Double(baseline) * 0.01).rounded(.up)))
        return abs(lhs - rhs) <= tolerance
    }

    private static func aggregate(records: [UsageRecord], sources: [String: SourceInfo]) -> UsageSnapshot {
        var daily = [String: DailyAccumulator]()
        var rhythms = [String: RhythmAccumulator]()
        var agentWork = [String: AgentWorkAccumulator]()
        var tools = [String: UsageAccumulator]()
        var models = [ModelKey: UsageAccumulator]()

        for originalRecord in records {
            var record = originalRecord
            // Normalize again at the aggregation boundary so records decoded
            // from an older CollectorCache cannot bypass current natural-key
            // safety rules.
            record.model = modelKey(record.model)
            let resolvedCost = resolveCost(for: record)
            daily[record.date, default: DailyAccumulator(date: record.date)]
                .add(record: record, resolvedCost: resolvedCost)
            let recordHour = record.timestampEpoch.map(hour(fromEpoch:))
                ?? hour(fromISO: record.timestamp)
            if let hour = recordHour {
                rhythms[record.date, default: RhythmAccumulator(date: record.date)]
                    .add(tokens: record.usage.totalTokens, hour: hour)
            }
            if isAgentWorkRecord(record) {
                agentWork[record.date, default: AgentWorkAccumulator(date: record.date)]
                    .add(record: record, hour: recordHour)
            }
            tools[record.tool, default: UsageAccumulator()].add(record.usage, cost: resolvedCost.costUSD)
            models[ModelKey(tool: record.tool, model: record.model), default: UsageAccumulator()]
                .add(record.usage, cost: resolvedCost.costUSD)
        }

        let totalTokens = tools.values.map(\.usage.totalTokens).reduce(0, +)
        let totalCost = tools.values.map(\.cost).reduce(0, +)
        let totalPricedTokens = daily.values.map(\.pricedTokens).reduce(0, +)
        let totalUnpricedTokens = daily.values.map(\.unpricedTokens).reduce(0, +)

        let dailyRows = daily.values
            .sorted { $0.date < $1.date }
            .map { item in
                DailyUsage(
                    date: item.date,
                    tools: item.tools,
                    models: item.models,
                    atomicUsage: item.atomicUsage,
                    totalTokens: item.totalTokens,
                    cost: rounded(item.cost, digits: 4),
                    pricedTokens: item.pricedTokens,
                    unpricedTokens: item.unpricedTokens,
                    pricingVersion: TokenPricingCatalog.version
                )
            }

        let rhythmRows = rhythms.values
            .map(\.dailyRhythm)
            .filter { $0.totalTokens > 0 }
            .sorted { $0.date < $1.date }

        let agentWorkRows = agentWork.values
            .map(\.dailyAgentWork)
            .filter { $0.totalTokens > 0 }
            .sorted { $0.date < $1.date }

        let toolRows = tools
            .sorted { $0.value.usage.totalTokens > $1.value.usage.totalTokens }
            .map { tool, item in
                ToolUsage(
                    tool: tool,
                    tokens: item.usage.totalTokens,
                    percent: percent(item.usage.totalTokens, of: totalTokens)
                )
            }

        let modelRows = models
            .sorted { $0.value.usage.totalTokens > $1.value.usage.totalTokens }
            .map { key, item in
                ModelUsage(
                    model: key.model,
                    tool: key.tool,
                    tokens: item.usage.totalTokens,
                    percent: percent(item.usage.totalTokens, of: totalTokens)
                )
            }

        return UsageSnapshot(
            generatedAt: isoFormatter.string(from: Date()),
            timezone: "Asia/Shanghai",
            totals: UsageTotals(
                tokens: totalTokens,
                cost: rounded(totalCost, digits: 2),
                activeDays: dailyRows.filter { $0.totalTokens > 0 }.count,
                pricedTokens: totalTokens > 0 ? totalPricedTokens : nil,
                unpricedTokens: totalTokens > 0 ? totalUnpricedTokens : nil,
                pricingVersion: TokenPricingCatalog.version
            ),
            daily: dailyRows,
            rhythms: rhythmRows,
            agentWork: agentWorkRows,
            tools: toolRows,
            models: modelRows,
            sources: sources
        )
    }

    private static func isAgentWorkRecord(_ record: UsageRecord) -> Bool {
        switch record.source {
        case .nativeCodex, .nativeCodexSQLite, .nativeClaudeCode, .ccSwitchProxy, .zcode, .hermes, .workbuddy, .codebuddy, .qoder, .kimi, .opencode, .grok, .qwen, .cursor, .cline, .copilot, .copilotOTel, .antigravity, .droid, .dsh, .pi, .openclaw:
            return true
        case .unknown:
            return false
        }
    }

    private static func jsonlFiles(under root: URL, modifiedSince cutoffDate: Date? = nil) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true
            else {
                return nil
            }
            if let cutoffDate,
               let modificationDate = values.contentModificationDate,
               modificationDate < cutoffDate {
                return nil
            }
            return url
        }
    }

    private static func usageLogFiles(
        at root: URL,
        modifiedSince cutoffDate: Date?
    ) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            guard let values = try? root.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true
            else { return [] }
            if let cutoffDate, let modified = values.contentModificationDate, modified < cutoffDate { return [] }
            return [root]
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: []
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true
            else { return nil }
            if let cutoffDate, let modified = values.contentModificationDate, modified < cutoffDate { return nil }
            return url
        }
    }

    private static func compressedDSHFiles(
        under root: URL,
        modifiedSince cutoffDate: Date?
    ) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: []
              )
        else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.lastPathComponent.hasSuffix(".jsonl.zstd"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true
            else { return nil }
            if let cutoffDate, let modified = values.contentModificationDate, modified < cutoffDate { return nil }
            return url
        }
    }

    private static func zstdExecutableURL() -> URL? {
        var candidates = [
            "/opt/homebrew/bin/zstd",
            "/usr/local/bin/zstd",
            "/usr/bin/zstd"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/zstd" })
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func decodeZstdFile(_ file: URL, executableURL: URL) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["-dc", "--", file.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    private static func cachedRecords(for url: URL, tool: String, cache: CollectorCache) -> [UsageRecord]? {
        guard let metadata = fileMetadata(for: url),
              let fingerprint = contentFingerprint(for: url, size: metadata.size),
              let cached = cache.files[url.path],
              cached.tool == tool,
              cached.size == metadata.size,
              abs(cached.modificationTime - metadata.modificationTime) < 0.001,
              cached.contentFingerprint == fingerprint
        else {
            return nil
        }
        return cached.records
    }

    private static func cachedCodexScan(for url: URL, cache: CollectorCache) -> CodexSessionScan? {
        guard let metadata = fileMetadata(for: url),
              let fingerprint = contentFingerprint(for: url, size: metadata.size),
              let cached = cache.files[url.path],
              cached.tool == "Codex",
              cached.size == metadata.size,
              abs(cached.modificationTime - metadata.modificationTime) < 0.001,
              cached.contentFingerprint == fingerprint
        else {
            return nil
        }
        return cached.codexScan
    }

    private static func updateCache(path: URL, tool: String, records: [UsageRecord], cache: inout CollectorCache) {
        guard let metadata = fileMetadata(for: path),
              let fingerprint = contentFingerprint(for: path, size: metadata.size)
        else {
            return
        }
        cache.files[path.path] = CachedUsageFile(
            tool: tool,
            size: metadata.size,
            modificationTime: metadata.modificationTime,
            records: records,
            contentFingerprint: fingerprint
        )
    }

    private static func updateCodexCache(
        path: URL,
        scan: CodexSessionScan,
        metadata: (size: UInt64, modificationTime: TimeInterval),
        cache: inout CollectorCache
    ) {
        guard let currentMetadata = fileMetadata(for: path),
              UsageCollector.metadata(metadata, matches: currentMetadata),
              let fingerprint = contentFingerprint(for: path, size: currentMetadata.size),
              let finalMetadata = fileMetadata(for: path),
              UsageCollector.metadata(currentMetadata, matches: finalMetadata)
        else {
            return
        }
        cache.files[path.path] = CachedUsageFile(
            tool: "Codex",
            size: finalMetadata.size,
            modificationTime: finalMetadata.modificationTime,
            records: [],
            codexScan: scan,
            contentFingerprint: fingerprint
        )
    }

    private static func fileMetadata(for url: URL) -> (size: UInt64, modificationTime: TimeInterval)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modificationDate = values.contentModificationDate
        else {
            return nil
        }
        return (UInt64(max(0, size)), modificationDate.timeIntervalSince1970)
    }

    private static func metadata(
        _ lhs: (size: UInt64, modificationTime: TimeInterval),
        matches rhs: (size: UInt64, modificationTime: TimeInterval)
    ) -> Bool {
        lhs.size == rhs.size && abs(lhs.modificationTime - rhs.modificationTime) < 0.001
    }

    private static func contentFingerprint(for url: URL, size: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let chunkSize = 4_096
        var hash: UInt64 = 14_695_981_039_346_656_037
        func include(_ data: Data) {
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }

        do {
            include(withUnsafeBytes(of: size.littleEndian) { Data($0) })
            let leadingCount = min(chunkSize, Int(clamping: size))
            include(try handle.read(upToCount: leadingCount) ?? Data())
            if size > UInt64(leadingCount) {
                let trailingCount = min(chunkSize, Int(clamping: size))
                try handle.seek(toOffset: size - UInt64(trailingCount))
                include(try handle.read(upToCount: trailingCount) ?? Data())
            }
            return String(format: "%016llx", hash)
        } catch {
            return nil
        }
    }

    private static func fullContentFingerprint(for url: URL, size: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        hasher.update(data: withUnsafeBytes(of: size.littleEndian) { Data($0) })
        var remaining = size
        do {
            while remaining > 0 {
                let requested = min(1_048_576, Int(clamping: remaining))
                guard let chunk = try autoreleasepool(invoking: {
                    try handle.read(upToCount: requested)
                }), !chunk.isEmpty else {
                    return nil
                }
                hasher.update(data: chunk)
                remaining -= UInt64(chunk.count)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    private static func loadCache() -> CollectorCacheLoad {
        loadCache(at: AppPaths.collectorCacheJSON)
    }

    private static func loadCache(at url: URL) -> CollectorCacheLoad {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CollectorCache.self, from: data)
        else {
            return CollectorCacheLoad(cache: CollectorCache(), recalibratedFromRevision: nil)
        }
        guard decoded.version == CollectorCache.currentVersion else {
            return CollectorCacheLoad(
                cache: CollectorCache(),
                recalibratedFromRevision: decoded.version < CollectorCache.currentVersion ? decoded.version : nil
            )
        }
        return CollectorCacheLoad(cache: decoded, recalibratedFromRevision: nil)
    }

    private static func saveCache(_ cache: CollectorCache) {
        saveCache(cache, to: AppPaths.collectorCacheJSON)
    }

    private static func loadCurrentCache(at url: URL) -> CollectorCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CollectorCache.self, from: data),
              cache.version == CollectorCache.currentVersion
        else {
            return CollectorCache()
        }
        return cache
    }

    private static func saveCache(_ cache: CollectorCache, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let existingSize = (attributes[.size] as? NSNumber)?.intValue,
               existingSize == data.count,
               let existing = try? Data(contentsOf: url),
               existing == data {
                return
            }
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache misses should never prevent the app from showing fresh usage.
        }
    }

    private static func sourceFileCutoffDate(historyDays: Int, now: Date = Date()) -> Date? {
        calendar.date(byAdding: .day, value: -max(7, historyDays + 1), to: now)
    }

    private static func recordsInHistoryWindow(
        _ records: [UsageRecord],
        historyDays: Int,
        now: Date
    ) -> [UsageRecord] {
        let inclusiveDays = max(1, historyDays)
        let today = calendar.startOfDay(for: now)
        guard let firstDay = calendar.date(
            byAdding: .day,
            value: -(inclusiveDays - 1),
            to: today
        ) else {
            return records
        }
        let firstDayString = dayFormatter.string(from: firstDay)
        let todayString = dayFormatter.string(from: today)
        return records.filter {
            $0.date >= firstDayString && $0.date <= todayString
        }
    }

    private static func forEachLine(in url: URL, matchingAny markers: [String] = [], _ body: (String) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let newline = Data([0x0A])
        let markerData = markers.map { Data($0.utf8) }
        var buffer = Data()
        buffer.reserveCapacity(128 * 1024)
        var discardingOversizedLine = false

        func processLine(_ lineData: Data) {
            guard lineMatches(lineData, markers: markerData),
                  let line = String(data: lineData, encoding: .utf8),
                  !line.isEmpty
            else {
                return
            }
            body(line)
        }

        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                return false
            }
            buffer.append(chunk)

            var consumedEnd = buffer.startIndex
            var lineStart = buffer.startIndex
            var searchRange = buffer.startIndex..<buffer.endIndex
            while let range = buffer.range(of: newline, options: [], in: searchRange) {
                let lineEnd = range.lowerBound
                if discardingOversizedLine {
                    discardingOversizedLine = false
                } else if lineEnd > lineStart {
                    let lineData = buffer.subdata(in: lineStart..<lineEnd)
                    processLine(lineData)
                }
                consumedEnd = range.upperBound
                lineStart = range.upperBound
                searchRange = lineStart..<buffer.endIndex
            }

            if consumedEnd > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<consumedEnd)
            }

            if buffer.count > maxRelevantLineBytes {
                discardingOversizedLine = true
                buffer.removeAll(keepingCapacity: true)
            }
            return true
        }) {}

        if !discardingOversizedLine,
           !buffer.isEmpty,
           buffer.count <= maxRelevantLineBytes {
            processLine(buffer)
        }
    }

    @discardableResult
    private static func forEachCompleteLine(
        in url: URL,
        fromOffset offset: UInt64,
        matchingAny markers: [String] = [],
        _ body: (String) -> Void
    ) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        let newline = Data([0x0A])
        let markerData = markers.map { Data($0.utf8) }
        var buffer = Data()
        buffer.reserveCapacity(128 * 1024)
        var discardingOversizedLine = false
        var discardedIncompleteBytes = 0
        var processedSize = offset

        func processLine(_ lineData: Data) {
            guard lineMatches(lineData, markers: markerData),
                  let line = String(data: lineData, encoding: .utf8),
                  !line.isEmpty
            else {
                return
            }
            body(line)
        }

        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                return false
            }
            buffer.append(chunk)

            var consumedEnd = buffer.startIndex
            var lineStart = buffer.startIndex
            var searchRange = buffer.startIndex..<buffer.endIndex
            while let range = buffer.range(of: newline, options: [], in: searchRange) {
                let lineEnd = range.lowerBound
                if discardingOversizedLine {
                    discardingOversizedLine = false
                } else if lineEnd > lineStart {
                    processLine(buffer.subdata(in: lineStart..<lineEnd))
                }
                consumedEnd = range.upperBound
                lineStart = range.upperBound
                searchRange = lineStart..<buffer.endIndex
            }

            if consumedEnd > buffer.startIndex {
                let consumedBytes = buffer.distance(from: buffer.startIndex, to: consumedEnd)
                processedSize += UInt64(discardedIncompleteBytes + consumedBytes)
                discardedIncompleteBytes = 0
                buffer.removeSubrange(buffer.startIndex..<consumedEnd)
            }

            if buffer.count > maxRelevantLineBytes {
                discardingOversizedLine = true
                discardedIncompleteBytes += buffer.count
                buffer.removeAll(keepingCapacity: true)
            }
            return true
        }) {}

        return processedSize
    }

    private static func lineMatches(_ data: Data, markers: [Data]) -> Bool {
        markers.isEmpty || markers.contains { data.range(of: $0) != nil }
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return nil
        }
        return dictionary
    }

    private static func normalizeUsage(_ raw: [String: Any]?) -> TokenUsageCounts {
        guard let raw else { return TokenUsageCounts() }
        func value(_ keys: [String]) -> Int {
            for key in keys where raw.keys.contains(key) {
                return max(0, integerValue(raw[key] as Any))
            }
            return 0
        }

        let explicitTotal = ["total_tokens", "total"].first(where: { raw.keys.contains($0) })
            .map { max(0, integerValue(raw[$0] as Any)) }
        return canonicalUsageCounts(
            rawInputTokens: value(["input_tokens", "input"]),
            outputTokens: value(["output_tokens", "output"]),
            cacheCreationInputTokens: value(["cache_creation_input_tokens"]),
            cacheReadInputTokens: value(["cache_read_input_tokens", "cached_input_tokens", "cached"]),
            reasoningOutputTokens: value(["reasoning_output_tokens", "reasoning_tokens", "thoughts"]),
            inputIncludesCachedTokens: false,
            explicitTotalTokens: explicitTotal
        )
    }

    private static func normalizeCodexUsage(_ raw: [String: Any]) -> TokenUsageCounts {
        func value(_ keys: [String]) -> Int {
            for key in keys where raw.keys.contains(key) {
                return max(0, integerValue(raw[key] as Any))
            }
            return 0
        }

        let input = value(["input_tokens", "input"])
        let output = value(["output_tokens", "output"])
        let cached = value(["cached_input_tokens", "cache_read_input_tokens", "cached"])
        let reasoning = value(["reasoning_output_tokens", "reasoning_tokens", "thoughts"])
        let explicitTotal = ["total_tokens", "total"].first(where: { raw.keys.contains($0) })
            .map { max(0, integerValue(raw[$0] as Any)) }
        return canonicalUsageCounts(
            rawInputTokens: input,
            outputTokens: output,
            cacheCreationInputTokens: value(["cache_creation_input_tokens", "cache_write_input_tokens"]),
            cacheReadInputTokens: cached,
            reasoningOutputTokens: reasoning,
            inputIncludesCachedTokens: true,
            explicitTotalTokens: explicitTotal,
            explicitTotalIsAuthoritative: true
        )
    }

    private static func canonicalUsageCounts(
        rawInputTokens: Int,
        outputTokens: Int,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        inputIncludesCachedTokens: Bool,
        explicitTotalTokens: Int? = nil,
        explicitTotalIsAuthoritative: Bool = false
    ) -> TokenUsageCounts {
        let rawInput = max(0, rawInputTokens)
        let output = max(0, outputTokens)
        let cacheCreation = max(0, cacheCreationInputTokens)
        let cacheRead = max(0, cacheReadInputTokens)
        let reasoning = max(0, reasoningOutputTokens)
        let input = rawInput + (inputIncludesCachedTokens ? 0 : cacheCreation + cacheRead)
        let derivedTotal = input + output
        let explicitTotal = max(0, explicitTotalTokens ?? 0)
        let total = explicitTotalIsAuthoritative && explicitTotal > 0
            ? explicitTotal
            : (derivedTotal > 0 ? derivedTotal : explicitTotal)
        return TokenUsageCounts(
            inputTokens: input,
            outputTokens: output,
            cacheCreationInputTokens: cacheCreation,
            cacheReadInputTokens: cacheRead,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }

    private static func integerValue(_ value: Any) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func doubleValue(_ value: Any) -> Double {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }

    private static func positiveDoubleValue(_ value: Any) -> Double? {
        let number = doubleValue(value)
        return number.isFinite && number > 0 ? number : nil
    }

    private static func nonEmptyString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dayString(fromISO value: String) -> String? {
        guard let date = parseISO(value) else { return nil }
        return dayFormatter.string(from: date)
    }

    private static func dayString(for event: CodexTokenEvent) -> String? {
        if let timestamp = event.timestampEpoch {
            return dayFormatter.string(from: Date(timeIntervalSince1970: timestamp))
        }
        return event.timestamp.flatMap(dayString(fromISO:))
    }

    private static func hour(fromEpoch value: TimeInterval) -> Int {
        calendar.component(.hour, from: Date(timeIntervalSince1970: value))
    }

    private static func hour(fromISO value: String?) -> Int? {
        guard let value, let date = parseISO(value) else { return nil }
        return calendar.component(.hour, from: date)
    }

    private static func dayString(fromEpoch value: Any?) -> String? {
        guard let seconds = epochSeconds(value) else { return nil }
        return dayFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private static func isoString(fromEpoch value: Any?) -> String? {
        guard let seconds = epochSeconds(value) else { return nil }
        return isoFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private static func epochSeconds(_ value: Any?) -> Double? {
        var seconds: Double
        if let int = value as? Int {
            seconds = Double(int)
        } else if let double = value as? Double {
            seconds = double
        } else if let string = value as? String, let parsed = Double(string) {
            seconds = parsed
        } else {
            return nil
        }
        if seconds > 10_000_000_000 {
            seconds /= 1_000
        }
        return seconds
    }

    private static func parseISO(_ value: String) -> Date? {
        if let date = isoFormatterWithFractional.date(from: value) {
            return date
        }
        return isoFormatter.date(from: value)
    }

    private static func modelKey(_ model: String?) -> String {
        let raw = (model ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
        let safeScalars = raw.unicodeScalars.map { scalar -> String in
            if scalar == "\u{1F}" || CharacterSet.controlCharacters.contains(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()
        let collapsed = safeScalars
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let value = collapsed.isEmpty ? "unknown" : collapsed
        let limited = value.unicodeScalars.prefix(128).map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? "unknown" : limited
    }

    private static func claudeIdentity(
        obj: [String: Any],
        message: [String: Any],
        path: URL,
        lineNumber: Int
    ) -> ClaudeIdentity {
        let responseID = nonEmptyString(message["id"] as? String)
        let requestID = [
            obj["requestId"] as? String,
            obj["request_id"] as? String,
            message["requestId"] as? String,
            message["request_id"] as? String
        ].compactMap(nonEmptyString).first
        let sessionID = [
            obj["sessionId"] as? String,
            obj["session_id"] as? String,
            obj["sessionID"] as? String
        ].compactMap(nonEmptyString).first
        let uuid = nonEmptyString(obj["uuid"] as? String)

        let deduplicationKey: String
        if let responseID {
            deduplicationKey = "response:\(responseID)"
        } else if let requestID {
            deduplicationKey = "request:\(requestID)"
        } else if let uuid {
            deduplicationKey = "uuid:\(uuid)"
        } else {
            deduplicationKey = "line:\(path.path):\(lineNumber)"
        }
        return ClaudeIdentity(
            deduplicationKey: deduplicationKey,
            requestID: requestID,
            responseID: responseID,
            sessionID: sessionID
        )
    }

    private static func hasStopReason(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func ccSwitchToolName(appType: String?) -> String {
        let value = (appType ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = value.lowercased()
        switch normalized {
        case "claude":
            return "Claude Code via CC Switch"
        case "codex":
            return "Codex via CC Switch"
        case "gemini":
            return "Gemini via CC Switch"
        case "kimi", "kimi-cli", "kimi-code":
            return "Kimi via CC Switch (experimental)"
        case "deepseek":
            return "DeepSeek via CC Switch (experimental)"
        case "cursor":
            return "Cursor via CC Switch (experimental)"
        default:
            return "\(value.isEmpty ? "unknown" : value) via CC Switch (experimental)"
        }
    }

    private static func ccSwitchFreshInputTokens(
        rawInputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        appType: String?,
        inputTokenSemantics: Int
    ) -> Int {
        let rawInput = max(0, rawInputTokens)
        let cacheRead = max(0, cacheReadTokens)
        let cacheCreation = max(0, cacheCreationTokens)
        let normalizedAppType = (appType ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let cacheInclusiveAppTypes: Set<String> = ["codex", "gemini", "grokbuild"]
        guard cacheInclusiveAppTypes.contains(normalizedAppType) else {
            return rawInput
        }

        switch inputTokenSemantics {
        case 2:
            // FRESH: input excludes both cache-read and cache-write buckets.
            return rawInput
        case 1 where rawInput >= cacheRead + cacheCreation:
            // TOTAL: input already includes both cache buckets.
            return rawInput - cacheRead - cacheCreation
        case 0 where rawInput >= cacheRead:
            // LEGACY: cache reads were included, cache writes were separate.
            return rawInput - cacheRead
        default:
            // Malformed or future semantics stay conservative instead of going negative.
            return rawInput
        }
    }

    private static func sqliteJSONRows(database: URL, query: String) -> [[String: Any]]? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstep-sqlite-\(UUID().uuidString).json")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            return nil
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = sqliteJSONProcess(database: database, query: query)
        process.standardOutput = outputHandle
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        guard !data.isEmpty else { return [] }
        return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }

    private static func sqliteJSONProcess(database: URL, query: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", database.path, query]
        process.qualityOfService = .utility
        return process
    }

    #if TOKENSTEP_TESTING
    static func sqliteJSONQualityOfServiceForTests() -> QualityOfService {
        sqliteJSONProcess(
            database: URL(fileURLWithPath: "/tmp/tokenfleet-qos-test.sqlite"),
            query: "select 1"
        ).qualityOfService
    }
    #endif

    private static func resolveCost(for record: UsageRecord) -> ResolvedRecordCost {
        if let sourceCost = record.costUSD,
           sourceCost.isFinite,
           sourceCost > 0 {
            return ResolvedRecordCost(
                costUSD: sourceCost,
                pricedTokens: record.usage.totalTokens,
                unpricedTokens: 0
            )
        }

        let usage = record.usage
        let normalizedUsage = TokenPricingUsage(
            inputTokens: max(
                0,
                usage.inputTokens
                    - usage.cacheCreationInputTokens
                    - usage.cacheReadInputTokens
            ),
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadInputTokens,
            cacheWriteTokens: usage.cacheCreationInputTokens,
            totalTokens: usage.totalTokens,
            breakdownComplete: usage.cacheCoverageComplete
        )
        guard let estimate = TokenPricingCatalog.estimate(
            tool: record.tool,
            model: record.model,
            usage: normalizedUsage,
            date: record.date
        ) else {
            return ResolvedRecordCost(
                costUSD: 0,
                pricedTokens: 0,
                unpricedTokens: record.usage.totalTokens
            )
        }
        return ResolvedRecordCost(
            costUSD: estimate.costUSD,
            pricedTokens: estimate.pricedTokens,
            unpricedTokens: estimate.unpricedTokens
        )
    }

    private static func percent(_ value: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return rounded(Double(value) / Double(total) * 100, digits: 2)
    }

    private static func rounded(_ value: Double, digits: Int) -> Double {
        let multiplier = pow(10.0, Double(digits))
        return (value * multiplier).rounded() / multiplier
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        return calendar
    }()

    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct CollectedCursorUsageArchive: Decodable {
    var schemaVersion: Int
    var importedAt: String
    var records: [CursorUsageCSVRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case importedAt = "imported_at"
        case records
    }
}

private struct CollectorResult {
    var records: [UsageRecord]
    var source: SourceInfo
    var inputURLs: [URL]

    init(records: [UsageRecord], source: SourceInfo, inputURLs: [URL] = []) {
        self.records = records
        self.source = source
        self.inputURLs = inputURLs
    }

    var inputBytes: UInt64 {
        let recordURLs = records.compactMap { record -> URL? in
            guard let path = record.sourcePath else { return nil }
            return URL(fileURLWithPath: path)
        }
        let uniqueURLs = Dictionary(
            grouping: inputURLs + recordURLs,
            by: { $0.standardizedFileURL.path }
        ).compactMap { $0.value.first }
        return uniqueURLs.reduce(into: UInt64(0)) { total, url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber
            else {
                return
            }
            total &+= size.uint64Value
        }
    }
}

private struct ClineMessagesArchive: Decodable {
    var version: Int
    var sessionID: String
    var messages: [ClineStoredMessage]

    enum CodingKeys: String, CodingKey {
        case version
        case sessionID = "sessionId"
        case messages
    }
}

private struct ClineStoredMessage: Decodable {
    var id: String
    var role: String
    var timestampMilliseconds: Double?
    var modelInfo: ClineStoredModelInfo?
    var metrics: ClineStoredMetrics?

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case timestampMilliseconds = "ts"
        case modelInfo
        case metrics
    }
}

private struct ClineStoredModelInfo: Decodable {
    var id: String?
}

private struct ClineStoredMetrics: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var cost: Double?
}

private struct CodexCollectionOutcome {
    var result: CollectorResult
    var usedIncrementalStore: Bool
}

private struct PendingCodexSession {
    var path: URL
    var metadata: (size: UInt64, modificationTime: TimeInterval)
    var fingerprint: String
    var validationFingerprint: String? = nil
    var scan: CodexSessionScan
}

private struct StoredCodexSessionMetadata {
    var size: UInt64
    var modificationTime: TimeInterval
    var fingerprint: String
    var validationFingerprint: String?
    var sessionID: String
}

private struct CodexCachedSession {
    var path: String
    var size: UInt64
    var modificationTime: TimeInterval
    var fingerprint: String
    var validationFingerprint: String? = nil
    var sessionID: String
    var createdAtEpoch: TimeInterval?
    var parentSessionID: String?
    var anchors: [CodexAnchor]
    var records: [UsageRecord]
    var summaryRecords: [UsageRecord]
    var cursor: CodexSessionCursor
    var diagnostics: CodexCollectionDiagnostics

    func hasSameStoredAccounting(as other: CodexCachedSession) -> Bool {
        path == other.path
            && size == other.size
            && abs(modificationTime - other.modificationTime) < 0.001
            && fingerprint == other.fingerprint
            && sessionID == other.sessionID
            && createdAtEpoch == other.createdAtEpoch
            && parentSessionID == other.parentSessionID
            && anchors == other.anchors
            && records == other.records
            && summaryRecords == other.summaryRecords
            && cursor == other.cursor
            && diagnostics == other.diagnostics
    }
}

private struct CodexCachedContribution {
    var records: [UsageRecord]
    var recordCount: Int
    var diagnostics: CodexCollectionDiagnostics
}

private struct CodexSummaryKey: Hashable {
    var date: String
    var model: String
    var hour: Int?
}

private struct CodexSummaryAccumulator {
    var timestamp: String?
    var timestampEpoch: TimeInterval?
    var usage = TokenUsageCounts()
    var modelRequestCount = 0
    var toolCallCount = 0

    mutating func add(_ record: UsageRecord) {
        timestamp = timestamp ?? record.timestamp
        timestampEpoch = timestampEpoch ?? record.timestampEpoch
        usage.add(record.usage)
        modelRequestCount += max(0, record.modelRequestCount)
        toolCallCount += max(0, record.toolCallCount)
    }
}

private enum CodexIncrementalStoreError: LocalizedError {
    case sqlite(String)
    case corruptPayload(String)
    case unstableSource(String)
    case incompleteCache(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case let .sqlite(message):
            return "Incremental cache error: \(message)"
        case let .corruptPayload(context):
            return "Incremental cache payload is corrupt: \(context)"
        case .unstableSource:
            return "A Codex session changed while it was being collected."
        case let .incompleteCache(expected, actual):
            return "Incremental cache is incomplete (expected \(expected), got \(actual))."
        }
    }

    var shouldRebuildCache: Bool {
        switch self {
        case .corruptPayload:
            return true
        case let .sqlite(message):
            let normalized = message.lowercased()
            return normalized.contains("not a database")
                || normalized.contains("database disk image is malformed")
                || normalized.contains("database malformed")
        case .incompleteCache:
            return true
        case .unstableSource:
            return false
        }
    }
}

private final class CodexIncrementalStore {
    private static let schemaVersion: Int32 = 6
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var database: OpaquePointer?
    private var stagingTransactionActive = false

    static func discardDatabase(at url: URL) {
        let fileManager = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            guard fileManager.fileExists(atPath: path) else { continue }
            try? fileManager.removeItem(atPath: path)
        }
    }

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let database { sqlite3_close(database) }
            database = nil
            throw CodexIncrementalStoreError.sqlite(message)
        }
        do {
            sqlite3_busy_timeout(database, 2_000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try migrateIfNeeded()
        } catch {
            if let database {
                sqlite3_close(database)
            }
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func metadataByPath() throws -> [String: StoredCodexSessionMetadata] {
        let statement = try prepare(
            """
            SELECT path, size, modification_time, fingerprint,
                   validation_fingerprint, session_id
            FROM codex_sessions
            """
        )
        defer { sqlite3_finalize(statement) }
        var result = [String: StoredCodexSessionMetadata]()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = columnText(statement, index: 0),
                  let fingerprint = columnText(statement, index: 3),
                  let sessionID = columnText(statement, index: 5)
            else { continue }
            result[path] = StoredCodexSessionMetadata(
                size: UInt64(max(0, sqlite3_column_int64(statement, 1))),
                modificationTime: sqlite3_column_double(statement, 2),
                fingerprint: fingerprint,
                validationFingerprint: columnText(statement, index: 4),
                sessionID: sessionID
            )
        }
        try checkFinalStep(statement)
        return result
    }

    func childPaths(parentSessionID: String) throws -> [String] {
        let statement = try prepare(
            "SELECT path FROM codex_sessions WHERE parent_session_id = ? ORDER BY path"
        )
        defer { sqlite3_finalize(statement) }
        bind(parentSessionID, to: statement, index: 1)
        var result = [String]()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = columnText(statement, index: 0) {
                result.append(path)
            }
        }
        try checkFinalStep(statement)
        return result
    }

    func childPaths(
        parentSessionID: String,
        createdAtOnOrAfter timestamp: TimeInterval
    ) throws -> [String] {
        let statement = try prepare(
            """
            SELECT path FROM codex_sessions
            WHERE parent_session_id = ?
              AND (created_at_epoch IS NULL OR created_at_epoch >= ?)
            ORDER BY path
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(parentSessionID, to: statement, index: 1)
        sqlite3_bind_double(statement, 2, timestamp)
        var result = [String]()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = columnText(statement, index: 0) {
                result.append(path)
            }
        }
        try checkFinalStep(statement)
        return result
    }

    func anchors(sessionID: String) throws -> [CodexAnchor]? {
        let statement = try prepare(
            "SELECT anchors FROM codex_sessions WHERE session_id = ? ORDER BY path LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        bind(sessionID, to: statement, index: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW,
              let data = columnData(statement, index: 0)
        else {
            throw currentError()
        }
        return try decode([CodexAnchor].self, from: data, context: "anchors")
    }

    func session(path: String) throws -> CodexCachedSession? {
        let statement = try prepare(
            """
            SELECT size, modification_time, fingerprint, validation_fingerprint,
                   session_id, created_at_epoch, parent_session_id, anchors,
                   records, COALESCE(summary_records, records), cursor, diagnostics
            FROM codex_sessions WHERE path = ? LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(path, to: statement, index: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW,
              let fingerprint = columnText(statement, index: 2),
              let sessionID = columnText(statement, index: 4),
              let anchorsData = columnData(statement, index: 7),
              let recordsData = columnData(statement, index: 8),
              let summaryData = columnData(statement, index: 9),
              let cursorData = columnData(statement, index: 10),
              let diagnosticsData = columnData(statement, index: 11)
        else { return nil }
        return CodexCachedSession(
            path: path,
            size: UInt64(max(0, sqlite3_column_int64(statement, 0))),
            modificationTime: sqlite3_column_double(statement, 1),
            fingerprint: fingerprint,
            validationFingerprint: columnText(statement, index: 3),
            sessionID: sessionID,
            createdAtEpoch: sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 5),
            parentSessionID: columnText(statement, index: 6),
            anchors: try decode([CodexAnchor].self, from: anchorsData, context: "session anchors"),
            records: try decode([UsageRecord].self, from: recordsData, context: "session records"),
            summaryRecords: try decode([UsageRecord].self, from: summaryData, context: "session summaries"),
            cursor: try decode(CodexSessionCursor.self, from: cursorData, context: "session cursor"),
            diagnostics: try decode(
                CodexCollectionDiagnostics.self,
                from: diagnosticsData,
                context: "session diagnostics"
            )
        )
    }

    func beginStaging() throws {
        guard !stagingTransactionActive else {
            throw CodexIncrementalStoreError.sqlite("staging transaction already active")
        }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM codex_staged_scans")
            try execute("DELETE FROM codex_staged_sessions")
            stagingTransactionActive = true
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func abortStaging() {
        guard stagingTransactionActive else { return }
        try? execute("ROLLBACK")
        stagingTransactionActive = false
    }

    func updateValidationFingerprint(_ fingerprint: String, path: String) throws {
        guard stagingTransactionActive else {
            throw CodexIncrementalStoreError.sqlite("staging transaction is not active")
        }
        let statement = try prepare(
            "UPDATE codex_sessions SET validation_fingerprint = ? WHERE path = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(fingerprint, to: statement, index: 1)
        bind(path, to: statement, index: 2)
        try requireDone(statement)
    }

    func stage(
        scan item: PendingCodexSession,
        anchors: [CodexAnchor],
        createdAtEpoch: TimeInterval?
    ) throws {
        guard stagingTransactionActive else {
            throw CodexIncrementalStoreError.sqlite("staging transaction is not active")
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let anchors = try encoder.encode(anchors)
        let scan = try encoder.encode(item.scan)
        let statement = try prepare(
            """
            INSERT OR REPLACE INTO codex_staged_scans (
                path, size, modification_time, fingerprint, validation_fingerprint,
                session_id, created_at_epoch, parent_session_id, anchors, scan
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(item.path.path, to: statement, index: 1)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(item.metadata.size))
        sqlite3_bind_double(statement, 3, item.metadata.modificationTime)
        bind(item.fingerprint, to: statement, index: 4)
        bind(item.validationFingerprint, to: statement, index: 5)
        bind(item.scan.canonicalSessionID, to: statement, index: 6)
        bind(createdAtEpoch, to: statement, index: 7)
        bind(item.scan.parentSessionID, to: statement, index: 8)
        bind(anchors, to: statement, index: 9)
        bind(scan, to: statement, index: 10)
        try requireDone(statement)
    }

    func stagedScanPaths() throws -> [String] {
        let statement = try prepare("SELECT path FROM codex_staged_scans ORDER BY path")
        defer { sqlite3_finalize(statement) }
        var paths = [String]()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = columnText(statement, index: 0) {
                paths.append(path)
            }
        }
        try checkFinalStep(statement)
        return paths
    }

    func stagedScan(path: String) throws -> PendingCodexSession? {
        let statement = try prepare(
            """
            SELECT size, modification_time, fingerprint, validation_fingerprint, scan
            FROM codex_staged_scans WHERE path = ? LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(path, to: statement, index: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW,
              let fingerprint = columnText(statement, index: 2),
              let scanData = columnData(statement, index: 4)
        else { throw currentError() }
        return PendingCodexSession(
            path: URL(fileURLWithPath: path),
            metadata: (
                size: UInt64(max(0, sqlite3_column_int64(statement, 0))),
                modificationTime: sqlite3_column_double(statement, 1)
            ),
            fingerprint: fingerprint,
            validationFingerprint: columnText(statement, index: 3),
            scan: try decode(CodexSessionScan.self, from: scanData, context: "staged scan")
        )
    }

    func stagedAnchors(sessionID: String) throws -> [CodexAnchor]? {
        for table in ["codex_staged_scans", "codex_staged_sessions"] {
            let statement = try prepare(
                "SELECT anchors FROM \(table) WHERE session_id = ? ORDER BY path LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            bind(sessionID, to: statement, index: 1)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { continue }
            guard status == SQLITE_ROW,
                  let data = columnData(statement, index: 0)
            else { throw currentError() }
            return try decode([CodexAnchor].self, from: data, context: "staged anchors")
        }
        return nil
    }

    func stage(session: CodexCachedSession) throws {
        guard stagingTransactionActive else {
            throw CodexIncrementalStoreError.sqlite("staging transaction is not active")
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let anchors = try encoder.encode(session.anchors)
        let records = try encoder.encode(session.records)
        let summaryRecords = try encoder.encode(session.summaryRecords)
        let cursor = try encoder.encode(session.cursor)
        let diagnostics = try encoder.encode(session.diagnostics)
        let statement = try prepare(
            """
            INSERT OR REPLACE INTO codex_staged_sessions (
                path, size, modification_time, fingerprint, validation_fingerprint,
                session_id, created_at_epoch, parent_session_id, anchors, records,
                summary_records, record_count, cursor, diagnostics
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(session.path, to: statement, index: 1)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(session.size))
        sqlite3_bind_double(statement, 3, session.modificationTime)
        bind(session.fingerprint, to: statement, index: 4)
        bind(session.validationFingerprint, to: statement, index: 5)
        bind(session.sessionID, to: statement, index: 6)
        bind(session.createdAtEpoch, to: statement, index: 7)
        bind(session.parentSessionID, to: statement, index: 8)
        bind(anchors, to: statement, index: 9)
        bind(records, to: statement, index: 10)
        bind(summaryRecords, to: statement, index: 11)
        sqlite3_bind_int64(statement, 12, sqlite3_int64(session.records.count))
        bind(cursor, to: statement, index: 13)
        bind(diagnostics, to: statement, index: 14)
        try requireDone(statement)
    }

    func commitStaged(deletedPaths: Set<String>) throws {
        guard stagingTransactionActive else {
            throw CodexIncrementalStoreError.sqlite("staging transaction is not active")
        }
        do {
            let stagedCount = try stagedSessionCount()
            let stagedPayloadBytes = try stagedSessionPayloadBytes()
            if !deletedPaths.isEmpty {
                let statement = try prepare("DELETE FROM codex_sessions WHERE path = ?")
                defer { sqlite3_finalize(statement) }
                for path in deletedPaths {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(path, to: statement, index: 1)
                    try requireDone(statement)
                }
            }
            if stagedCount > 0 {
                try execute(
                    """
                    INSERT OR REPLACE INTO codex_sessions (
                        path, size, modification_time, fingerprint, validation_fingerprint,
                        session_id, created_at_epoch, parent_session_id, anchors, records,
                        summary_records, record_count, cursor, diagnostics
                    )
                    SELECT path, size, modification_time, fingerprint,
                           validation_fingerprint, session_id, created_at_epoch,
                           parent_session_id, anchors, records, summary_records,
                           record_count, cursor, diagnostics
                    FROM codex_staged_sessions
                    """
                )
            }
            if stagedCount > 0 || !deletedPaths.isEmpty {
                try execute(
                    """
                    INSERT INTO cache_meta(key, value) VALUES ('generation', '1')
                    ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1
                    """
                )
                let logicalWriteBytes = stagedPayloadBytes * 2
                try execute(
                    """
                    INSERT INTO cache_meta(key, value)
                    VALUES ('last_logical_write_bytes', '\(logicalWriteBytes)')
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """
                )
            }
            try execute("DELETE FROM codex_staged_scans")
            try execute("DELETE FROM codex_staged_sessions")
            try execute("COMMIT")
            stagingTransactionActive = false
        } catch {
            try? execute("ROLLBACK")
            stagingTransactionActive = false
            throw error
        }
    }

    private func stagedSessionCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM codex_staged_sessions")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func stagedSessionPayloadBytes() throws -> Int {
        let statement = try prepare(
            """
            SELECT COALESCE(SUM(
                LENGTH(anchors) + LENGTH(records) + LENGTH(summary_records)
                + LENGTH(cursor) + LENGTH(diagnostics)
            ), 0)
            FROM codex_staged_sessions
            """
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func sessionCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM codex_sessions")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func forEachContribution(
        detailed: Bool,
        _ body: (CodexCachedContribution) throws -> Void
    ) throws {
        let statement = try prepare(
            detailed
                ? "SELECT records, diagnostics, record_count FROM codex_sessions ORDER BY path"
                : """
                  SELECT CASE
                      WHEN session_id IN (
                          SELECT session_id FROM codex_sessions
                          GROUP BY session_id HAVING COUNT(*) > 1
                      ) THEN records
                      ELSE COALESCE(summary_records, records)
                    END,
                    diagnostics,
                    record_count
                  FROM codex_sessions
                  ORDER BY path
                  """
        )
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let recordsData = columnData(statement, index: 0),
                  let diagnosticsData = columnData(statement, index: 1)
            else { throw currentError() }
            try body(
                CodexCachedContribution(
                    records: try decode(
                        [UsageRecord].self,
                        from: recordsData,
                        context: "contribution records"
                    ),
                    recordCount: Int(sqlite3_column_int64(statement, 2)),
                    diagnostics: try decode(
                        CodexCollectionDiagnostics.self,
                        from: diagnosticsData,
                        context: "contribution diagnostics"
                    )
                )
            )
        }
        try checkFinalStep(statement)
    }

    func stats() throws -> CodexIncrementalCacheStats {
        let statement = try prepare(
            """
            SELECT
                COALESCE((SELECT CAST(value AS INTEGER) FROM cache_meta WHERE key = 'generation'), 0),
                COUNT(*),
                COALESCE(SUM(record_count), 0),
                COALESCE((
                    SELECT CAST(value AS INTEGER) FROM cache_meta
                    WHERE key = 'last_logical_write_bytes'
                ), 0)
            FROM codex_sessions
            """
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return CodexIncrementalCacheStats(
            generation: Int(sqlite3_column_int64(statement, 0)),
            sessions: Int(sqlite3_column_int64(statement, 1)),
            records: Int(sqlite3_column_int64(statement, 2)),
            lastLogicalWriteBytes: Int(sqlite3_column_int64(statement, 3))
        )
    }

    private func migrateIfNeeded() throws {
        guard database != nil else { throw CodexIncrementalStoreError.sqlite("database closed") }
        let current = userVersion()
        guard current >= 0, current <= Self.schemaVersion else {
            throw CodexIncrementalStoreError.sqlite("unsupported schema version \(current)")
        }
        try execute(
            """
            CREATE TABLE IF NOT EXISTS cache_meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """
        )
        if current > 0, current < Self.schemaVersion {
            // v0.1.48 is the first public incremental-cache release. Recreate
            // older development schemas so interim payloads cannot survive.
            try execute("DROP TABLE IF EXISTS codex_sessions")
            try execute("DROP TABLE IF EXISTS codex_staged_scans")
            try execute("DROP TABLE IF EXISTS codex_staged_sessions")
            try execute("DELETE FROM cache_meta")
        }
        try execute(
            """
            CREATE TABLE IF NOT EXISTS codex_sessions (
                path TEXT PRIMARY KEY NOT NULL,
                size INTEGER NOT NULL,
                modification_time REAL NOT NULL,
                fingerprint TEXT NOT NULL,
                validation_fingerprint TEXT,
                session_id TEXT NOT NULL,
                created_at_epoch REAL,
                parent_session_id TEXT,
                anchors BLOB NOT NULL,
                records BLOB NOT NULL,
                summary_records BLOB,
                record_count INTEGER NOT NULL,
                cursor BLOB,
                diagnostics BLOB NOT NULL
            )
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS codex_sessions_session_id ON codex_sessions(session_id)"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS codex_sessions_parent_id ON codex_sessions(parent_session_id)"
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS codex_staged_scans (
                path TEXT PRIMARY KEY NOT NULL,
                size INTEGER NOT NULL,
                modification_time REAL NOT NULL,
                fingerprint TEXT NOT NULL,
                validation_fingerprint TEXT,
                session_id TEXT NOT NULL,
                created_at_epoch REAL,
                parent_session_id TEXT,
                anchors BLOB NOT NULL,
                scan BLOB NOT NULL
            )
            """
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS codex_staged_scans_session_id ON codex_staged_scans(session_id)"
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS codex_staged_sessions (
                path TEXT PRIMARY KEY NOT NULL,
                size INTEGER NOT NULL,
                modification_time REAL NOT NULL,
                fingerprint TEXT NOT NULL,
                validation_fingerprint TEXT,
                session_id TEXT NOT NULL,
                created_at_epoch REAL,
                parent_session_id TEXT,
                anchors BLOB NOT NULL,
                records BLOB NOT NULL,
                summary_records BLOB NOT NULL,
                record_count INTEGER NOT NULL,
                cursor BLOB NOT NULL,
                diagnostics BLOB NOT NULL
            )
            """
        )
        try execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    private func userVersion() -> Int32 {
        guard let statement = try? prepare("PRAGMA user_version") else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(statement, 0)
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw CodexIncrementalStoreError.sqlite("database closed") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw CodexIncrementalStoreError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw CodexIncrementalStoreError.sqlite("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw currentError() }
        return statement
    }

    private func bind(_ value: String?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: TimeInterval?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func bind(_ data: Data, to statement: OpaquePointer, index: Int32) {
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        context: String
    ) throws -> T {
        do {
            return try PropertyListDecoder().decode(type, from: data)
        } catch {
            throw CodexIncrementalStoreError.corruptPayload(context)
        }
    }

    private func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func columnData(_ statement: OpaquePointer, index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func requireDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
    }

    private func checkFinalStep(_ statement: OpaquePointer) throws {
        let status = sqlite3_errcode(database)
        guard status == SQLITE_OK || status == SQLITE_DONE else { throw currentError() }
    }

    private func currentError() -> CodexIncrementalStoreError {
        guard let database else { return .sqlite("database closed") }
        return .sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private struct CollectorCache: Codable {
    static let currentVersion = UsageCollector.codexAccountingRevision

    var version = currentVersion
    var files: [String: CachedUsageFile] = [:]
}

private struct CollectorCacheLoad {
    var cache: CollectorCache
    var recalibratedFromRevision: Int?
}

private struct CachedUsageFile: Codable {
    var tool: String
    var size: UInt64
    var modificationTime: TimeInterval
    var records: [UsageRecord]
    var codexScan: CodexSessionScan? = nil
    var contentFingerprint: String? = nil
}

private struct CodexSessionScan: Codable {
    var canonicalSessionID: String
    var createdAt: String?
    var parentSessionID: String?
    var sourcePath: String
    var events: [CodexTokenEvent]
    var finalModel: String? = nil
    var relevantLineCount: Int? = nil
}

private struct CodexTokenEvent: Codable {
    var timestamp: String?
    var timestampEpoch: TimeInterval? = nil
    var model: String
    var cumulativePresent: Bool
    var cumulative: TokenUsageCounts?
    var last: TokenUsageCounts?
    var modelContextWindow: Int
    var lineNumber: Int
}

private struct CodexAnchor: Codable, Equatable {
    var timestamp: TimeInterval
    var usage: TokenUsageCounts
}

private struct CodexDeltaCursor {
    var hasCumulativeSchema: Bool
    var previousCumulative: TokenUsageCounts?
    var epoch: Int
}

private struct CodexSessionCursor: Codable, Equatable {
    var currentModel: String
    var relevantLineNumber: Int
    var hasCumulativeSchema: Bool
    var previousCumulative: TokenUsageCounts?
    var epoch: Int
}

private struct CodexSessionTail {
    var events: [CodexTokenEvent]
    var currentModel: String
    var relevantLineNumber: Int
    var processedSize: UInt64
    var modificationTime: TimeInterval
    var fingerprint: String
}

private struct CodexCollectionDiagnostics: Codable, Equatable {
    var rawRecords = 0
    var exactRecords = 0
    var legacyRecords = 0
    var duplicateRecords = 0
    var counterResets = 0
    var inheritedRecords = 0
    var inheritedTokens = 0
    var skippedRecords = 0
    var unknownBreakdownRecords = 0

    mutating func add(_ other: CodexCollectionDiagnostics) {
        rawRecords += other.rawRecords
        exactRecords += other.exactRecords
        legacyRecords += other.legacyRecords
        duplicateRecords += other.duplicateRecords
        counterResets += other.counterResets
        inheritedRecords += other.inheritedRecords
        inheritedTokens += other.inheritedTokens
        skippedRecords += other.skippedRecords
        unknownBreakdownRecords += other.unknownBreakdownRecords
    }
}

private struct UsageRecord: Codable, Equatable {
    var date: String
    var timestamp: String?
    var timestampEpoch: TimeInterval? = nil
    var tool: String
    var model: String
    var usage: TokenUsageCounts
    var costUSD: Double? = nil
    var source: UsageRecordSource = .unknown
    var requestID: String? = nil
    var sessionID: String? = nil
    var responseID: String? = nil
    var sourcePath: String? = nil
    var lineNumber: Int? = nil
    var dataSource: String? = nil
    var modelRequestCount = 1
    var toolCallCount = 0

    enum CodingKeys: String, CodingKey {
        case date
        case timestamp
        case timestampEpoch
        case tool
        case model
        case usage
        case costUSD
        case source
        case requestID
        case sessionID
        case responseID
        case sourcePath
        case lineNumber
        case dataSource
        case modelRequestCount
        case toolCallCount
    }

    init(
        date: String,
        timestamp: String?,
        timestampEpoch: TimeInterval? = nil,
        tool: String,
        model: String,
        usage: TokenUsageCounts,
        costUSD: Double? = nil,
        source: UsageRecordSource = .unknown,
        requestID: String? = nil,
        sessionID: String? = nil,
        responseID: String? = nil,
        sourcePath: String? = nil,
        lineNumber: Int? = nil,
        dataSource: String? = nil,
        modelRequestCount: Int = 1,
        toolCallCount: Int = 0
    ) {
        self.date = date
        self.timestamp = timestamp
        self.timestampEpoch = timestampEpoch
        self.tool = tool
        self.model = model
        self.usage = usage
        self.costUSD = costUSD
        self.source = source
        self.requestID = requestID
        self.sessionID = sessionID
        self.responseID = responseID
        self.sourcePath = sourcePath
        self.lineNumber = lineNumber
        self.dataSource = dataSource
        self.modelRequestCount = modelRequestCount
        self.toolCallCount = toolCallCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        timestampEpoch = try container.decodeIfPresent(TimeInterval.self, forKey: .timestampEpoch)
        tool = try container.decode(String.self, forKey: .tool)
        model = try container.decode(String.self, forKey: .model)
        usage = try container.decode(TokenUsageCounts.self, forKey: .usage)
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
        source = try container.decodeIfPresent(UsageRecordSource.self, forKey: .source) ?? .unknown
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        responseID = try container.decodeIfPresent(String.self, forKey: .responseID)
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        lineNumber = try container.decodeIfPresent(Int.self, forKey: .lineNumber)
        dataSource = try container.decodeIfPresent(String.self, forKey: .dataSource)
        modelRequestCount = try container.decodeIfPresent(Int.self, forKey: .modelRequestCount) ?? 1
        toolCallCount = try container.decodeIfPresent(Int.self, forKey: .toolCallCount) ?? 0
    }
}

private enum UsageRecordSource: String, Codable, Equatable {
    case nativeCodex
    case nativeCodexSQLite
    case nativeClaudeCode
    case ccSwitchProxy
    case zcode
    case hermes
    case workbuddy
    case codebuddy
    case qoder
    case kimi
    case opencode
    case grok
    case qwen
    case cursor
    case cline
    case copilot
    case copilotOTel
    case antigravity
    case droid
    case dsh
    case pi
    case openclaw
    case unknown
}

private struct CrossSourceDedupeResult {
    var records: [UsageRecord]
    var rawProxyRecords: Int
    var keptProxyRecords: Int
    var dedupedProxyRecords: Int
    var possibleOverlapRecords: Int
    var skippedProxyRecords: Int
}

private struct ClaudeIdentity {
    var deduplicationKey: String
    var requestID: String?
    var responseID: String?
    var sessionID: String?
}

private struct ClaudeUsageCandidate {
    var date: String
    var timestamp: String
    var model: String
    var usage: TokenUsageCounts
    var hasStopReason: Bool
    var lineNumber: Int
    var requestID: String?
    var responseID: String?
    var sessionID: String?
    var sourcePath: String

    var record: UsageRecord {
        UsageRecord(
            date: date,
            timestamp: timestamp,
            tool: "Claude Code",
            model: model,
            usage: usage,
            source: .nativeClaudeCode,
            requestID: requestID,
            sessionID: sessionID,
            responseID: responseID,
            sourcePath: sourcePath,
            lineNumber: lineNumber
        )
    }

    func isPreferred(over other: ClaudeUsageCandidate) -> Bool {
        if hasStopReason != other.hasStopReason {
            return hasStopReason
        }
        if timestamp != other.timestamp {
            return timestamp > other.timestamp
        }
        return lineNumber > other.lineNumber
    }
}

private struct TokenUsageCounts: Codable, Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationInputTokens = 0
    var cacheReadInputTokens = 0
    var reasoningOutputTokens = 0
    var totalTokens = 0

    mutating func add(_ other: TokenUsageCounts) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheCreationInputTokens += other.cacheCreationInputTokens
        cacheReadInputTokens += other.cacheReadInputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        totalTokens += other.totalTokens
    }

    var fingerprint: String {
        [
            totalTokens,
            inputTokens,
            cacheReadInputTokens,
            outputTokens,
            reasoningOutputTokens,
            cacheCreationInputTokens
        ].map(String.init).joined(separator: ":")
    }

    var cacheCoverageComplete: Bool {
        inputTokens >= 0
            && outputTokens >= 0
            && cacheCreationInputTokens >= 0
            && cacheReadInputTokens >= 0
            && reasoningOutputTokens >= 0
            && totalTokens == inputTokens + outputTokens
            && cacheCreationInputTokens + cacheReadInputTokens <= inputTokens
            && reasoningOutputTokens <= outputTokens
    }
}

private struct UsageAccumulator {
    var usage = TokenUsageCounts()
    var cost = 0.0

    mutating func add(_ counts: TokenUsageCounts, cost: Double) {
        usage.inputTokens += counts.inputTokens
        usage.outputTokens += counts.outputTokens
        usage.cacheCreationInputTokens += counts.cacheCreationInputTokens
        usage.cacheReadInputTokens += counts.cacheReadInputTokens
        usage.reasoningOutputTokens += counts.reasoningOutputTokens
        usage.totalTokens += counts.totalTokens
        self.cost += cost
    }
}

private struct ResolvedRecordCost {
    var costUSD: Double
    var pricedTokens: Int
    var unpricedTokens: Int
}

private struct DailyAccumulator {
    var date: String
    var tools: [String: Int] = [:]
    var models: [String: Int] = [:]
    var atomic: [ModelKey: DailyAtomicAccumulator] = [:]
    var totalTokens = 0
    var cost = 0.0
    var pricedTokens = 0
    var unpricedTokens = 0

    mutating func add(record: UsageRecord, resolvedCost: ResolvedRecordCost) {
        tools[record.tool, default: 0] += record.usage.totalTokens
        models[record.model, default: 0] += record.usage.totalTokens
        atomic[ModelKey(tool: record.tool, model: record.model), default: DailyAtomicAccumulator()]
            .add(record.usage)
        totalTokens += record.usage.totalTokens
        cost += resolvedCost.costUSD
        pricedTokens += resolvedCost.pricedTokens
        unpricedTokens += resolvedCost.unpricedTokens
    }

    var atomicUsage: [DailyAtomicUsage] {
        atomic.map { key, accumulator in
            let counts = accumulator.usage
            return DailyAtomicUsage(
                tool: key.tool,
                model: key.model,
                inputTokens: max(
                    0,
                    counts.inputTokens
                        - counts.cacheReadInputTokens
                        - counts.cacheCreationInputTokens
                ),
                outputTokens: counts.outputTokens,
                cacheReadTokens: counts.cacheReadInputTokens,
                cacheWriteTokens: counts.cacheCreationInputTokens,
                totalTokens: counts.totalTokens,
                breakdownComplete: accumulator.breakdownComplete
            )
        }
        .sorted {
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            if $0.tool != $1.tool { return $0.tool.localizedStandardCompare($1.tool) == .orderedAscending }
            return $0.model.localizedStandardCompare($1.model) == .orderedAscending
        }
    }
}

private struct DailyAtomicAccumulator {
    var usage = TokenUsageCounts()
    var breakdownComplete = true

    mutating func add(_ counts: TokenUsageCounts) {
        usage.add(counts)
        breakdownComplete = breakdownComplete && counts.cacheCoverageComplete
    }
}

private struct AgentWorkAccumulator {
    var date: String
    var totalTokens = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var cacheCoverageComplete = true
    var unbucketedTokens = 0
    var activeHours = Set<Int>()
    var modelRequestCount = 0
    var toolCallCount = 0
    var sources: [String: AgentWorkSourceAccumulator] = [:]
    var hourlySources: [Int: [ModelKey: AgentWorkHourlySourceAccumulator]] = [:]

    mutating func add(record: UsageRecord, hour: Int?) {
        totalTokens += record.usage.totalTokens
        inputTokens += record.usage.inputTokens
        cachedInputTokens += record.usage.cacheReadInputTokens
        outputTokens += record.usage.outputTokens
        cacheCoverageComplete = cacheCoverageComplete && record.usage.cacheCoverageComplete
        if let hour {
            activeHours.insert(hour)
            var sourceRows = hourlySources[hour] ?? [:]
            let key = ModelKey(tool: record.tool, model: record.model)
            sourceRows[
                key,
                default: AgentWorkHourlySourceAccumulator(
                    source: record.tool,
                    model: record.model
                )
            ]
                .add(record: record)
            hourlySources[hour] = sourceRows
        } else {
            unbucketedTokens += record.usage.totalTokens
        }
        modelRequestCount += max(0, record.modelRequestCount)
        toolCallCount += max(0, record.toolCallCount)
        sources[record.tool, default: AgentWorkSourceAccumulator(source: record.tool)]
            .add(record: record)
    }

    var dailyAgentWork: DailyAgentWork {
        DailyAgentWork(
            date: date,
            totalTokens: totalTokens,
            activeHours: activeHours.count,
            modelRequestCount: modelRequestCount,
            toolCallCount: toolCallCount,
            sources: sources.values
                .filter { $0.tokens > 0 }
                .sorted { $0.tokens > $1.tokens }
                .map(\.agentWorkSource),
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            cacheCoverageComplete: cacheCoverageComplete,
            hourlyBuckets: (0..<24).map { hour in
                AgentWorkHourBucket(
                    hour: hour,
                    sources: (hourlySources[hour] ?? [:]).values
                        .filter { $0.tokens > 0 }
                        .sorted {
                            if $0.tokens == $1.tokens {
                                if $0.source == $1.source {
                                    return $0.model < $1.model
                                }
                                return $0.source < $1.source
                            }
                            return $0.tokens > $1.tokens
                        }
                        .map(\.hourlySource)
                )
            },
            unbucketedTokens: unbucketedTokens
        )
    }
}

private struct AgentWorkSourceAccumulator {
    var source: String
    var tokens = 0
    var modelRequestCount = 0
    var toolCallCount = 0

    mutating func add(record: UsageRecord) {
        tokens += record.usage.totalTokens
        modelRequestCount += max(0, record.modelRequestCount)
        toolCallCount += max(0, record.toolCallCount)
    }

    var agentWorkSource: AgentWorkSource {
        AgentWorkSource(
            source: source,
            tokens: tokens,
            modelRequestCount: modelRequestCount,
            toolCallCount: toolCallCount
        )
    }
}

private struct AgentWorkHourlySourceAccumulator {
    var source: String
    var model: String
    var tokens = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var cacheCoverageComplete = true

    mutating func add(record: UsageRecord) {
        tokens += record.usage.totalTokens
        inputTokens += record.usage.inputTokens
        cachedInputTokens += record.usage.cacheReadInputTokens
        outputTokens += record.usage.outputTokens
        cacheCoverageComplete = cacheCoverageComplete && record.usage.cacheCoverageComplete
    }

    var hourlySource: AgentWorkHourlySource {
        AgentWorkHourlySource(
            source: source,
            model: model,
            tokens: tokens,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            cacheCoverageComplete: cacheCoverageComplete
        )
    }
}

private struct RhythmAccumulator {
    var date: String
    var hourlyTokens = Array(repeating: 0, count: 24)

    mutating func add(tokens: Int, hour: Int) {
        guard tokens > 0, (0..<hourlyTokens.count).contains(hour) else { return }
        hourlyTokens[hour] += tokens
    }

    var dailyRhythm: DailyRhythm {
        let buckets = hourlyTokens.enumerated().map { hour, tokens in
            HourlyTokenBucket(hour: hour, tokens: tokens)
        }
        let totalTokens = hourlyTokens.reduce(0, +)
        let peak = hourlyTokens.enumerated().max { left, right in
            if left.element == right.element {
                return left.offset > right.offset
            }
            return left.element < right.element
        }
        let peakHour = (peak?.element ?? 0) > 0 ? peak?.offset : nil
        let peakTokens = peak?.element ?? 0
        let activeThreshold = Self.significantTokenThreshold(totalTokens: totalTokens, peakTokens: peakTokens)
        let significantHourlyTokens = hourlyTokens.map { $0 >= activeThreshold ? $0 : 0 }
        let activeHours = significantHourlyTokens.filter { $0 > 0 }.count
        let firstActiveHour = significantHourlyTokens.firstIndex { $0 > 0 }
        let lastActiveHour = significantHourlyTokens.lastIndex { $0 > 0 }
        let primaryTag = Self.classify(
            hourlyTokens: hourlyTokens,
            significantHourlyTokens: significantHourlyTokens,
            totalTokens: totalTokens,
            peakHour: peakHour,
            peakTokens: peakTokens,
            activeHours: activeHours,
            firstActiveHour: firstActiveHour
        )

        return DailyRhythm(
            date: date,
            buckets: buckets,
            totalTokens: totalTokens,
            peakHour: peakHour,
            peakTokens: peakTokens,
            activeHours: activeHours,
            firstActiveHour: firstActiveHour,
            lastActiveHour: lastActiveHour,
            primaryTag: primaryTag,
            companionTag: Self.companionTag(for: primaryTag)
        )
    }

    private static func classify(
        hourlyTokens: [Int],
        significantHourlyTokens: [Int],
        totalTokens: Int,
        peakHour: Int?,
        peakTokens: Int,
        activeHours: Int,
        firstActiveHour: Int?
    ) -> RhythmTag {
        guard totalTokens > 0 else { return .quietDay }
        let peakShare = share(peakTokens, of: totalTokens)
        if isDoublePeak(hourlyTokens: significantHourlyTokens, peakTokens: peakTokens) {
            return .doublePeak
        }
        if peakShare >= 0.50 {
            return .oneShot
        }

        let nightShare = share(tokens(in: [21, 22, 23, 0, 1, 2], hourlyTokens: significantHourlyTokens), of: totalTokens)
        if nightShare >= 0.35 || (peakHour.map { $0 >= 21 || $0 <= 2 } == true && nightShare >= 0.25) {
            return .nightAgent
        }

        let eveningShare = share(tokens(in: [19, 20], hourlyTokens: significantHourlyTokens), of: totalTokens)
        if peakHour.map({ (19...20).contains($0) }) == true || eveningShare >= 0.30 {
            return .eveningSprint
        }

        let afternoonShare = share(tokens(in: Array(14...18), hourlyTokens: significantHourlyTokens), of: totalTokens)
        if afternoonShare >= 0.35 || peakHour.map({ (14...18).contains($0) }) == true && afternoonShare >= 0.25 {
            return .afternoonBurst
        }

        let earlyShare = share(tokens(in: Array(5...9), hourlyTokens: significantHourlyTokens), of: totalTokens)
        if firstActiveHour.map({ $0 <= 8 }) == true && earlyShare >= 0.25 {
            return .earlyStarter
        }

        let morningShare = share(tokens(in: Array(8...12), hourlyTokens: significantHourlyTokens), of: totalTokens)
        if morningShare >= 0.35 || peakHour.map({ (8...12).contains($0) }) == true && morningShare >= 0.25 {
            return .morningPlanner
        }

        if activeHours >= 6 && peakShare < 0.35 {
            return .fragmented
        }
        if activeHours >= 4 {
            return .steadyCruise
        }
        return .quietDay
    }

    private static func companionTag(for tag: RhythmTag) -> RhythmTag {
        switch tag {
        case .earlyStarter:
            return .nightAgent
        case .morningPlanner:
            return .afternoonBurst
        case .afternoonBurst:
            return .morningPlanner
        case .eveningSprint:
            return .steadyCruise
        case .nightAgent:
            return .earlyStarter
        case .doublePeak:
            return .steadyCruise
        case .fragmented:
            return .oneShot
        case .oneShot:
            return .fragmented
        case .steadyCruise:
            return .doublePeak
        case .quietDay:
            return .morningPlanner
        }
    }

    private static func isDoublePeak(hourlyTokens: [Int], peakTokens: Int) -> Bool {
        guard peakTokens > 0 else { return false }
        let peaks = localPeakCandidates(hourlyTokens: hourlyTokens)
            .filter { Double($0.tokens) >= Double(peakTokens) * 0.45 }
            .sorted { $0.tokens > $1.tokens }
            .prefix(5)
        for left in peaks {
            for right in peaks where abs(left.hour - right.hour) >= 4 {
                return true
            }
        }
        return false
    }

    private static func localPeakCandidates(hourlyTokens: [Int]) -> [(hour: Int, tokens: Int)] {
        hourlyTokens.enumerated().compactMap { hour, tokens in
            guard tokens > 0 else { return nil }
            let previous = hour > 0 ? hourlyTokens[hour - 1] : 0
            let next = hour < hourlyTokens.count - 1 ? hourlyTokens[hour + 1] : 0
            guard tokens >= previous && tokens >= next else { return nil }
            return (hour, tokens)
        }
    }

    private static func tokens(in hours: [Int], hourlyTokens: [Int]) -> Int {
        hours.reduce(0) { total, hour in
            guard hourlyTokens.indices.contains(hour) else { return total }
            return total + hourlyTokens[hour]
        }
    }

    private static func share(_ value: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(value) / Double(total)
    }

    private static func significantTokenThreshold(totalTokens: Int, peakTokens: Int) -> Int {
        guard totalTokens > 0 else { return 1 }
        let totalBased = Double(totalTokens) * 0.03
        let peakBased = Double(peakTokens) * 0.30
        return max(1, Int(max(totalBased, peakBased).rounded()))
    }
}

private struct ModelKey: Hashable {
    var tool: String
    var model: String
}
