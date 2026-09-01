import Foundation
import XCTest
@testable import TokenStepSwift

final class CursorUsageCSVParserTests: XCTestCase {
    func testParsesCurrentExportByHeaderNameAndPreservesExactParts() throws {
        let csv = """
        Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        "2026-04-16T03:32:33.284Z","","","On-Demand","composer-2-fast","No","0","3189","194368","1815","199372","0.11"
        "2026-04-15T03:39:53.013Z","","","Included","claude-4.6-sonnet-medium-thinking","Yes","50000","40000","10000","3000","103000","$0.32"
        """

        let records = CursorUsageCSVParser.parse(csv)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].model, "composer-2-fast")
        XCTAssertEqual(records[0].inputTokens, 3189)
        XCTAssertEqual(records[0].cacheWriteTokens, 0)
        XCTAssertEqual(records[0].cacheReadTokens, 194_368)
        XCTAssertEqual(records[0].outputTokens, 1_815)
        XCTAssertEqual(records[0].exactTotalTokens, 199_372)
        XCTAssertEqual(records[1].cacheWriteTokens, 10_000)
        XCTAssertEqual(records[1].exactTotalTokens, 63_000)
        XCTAssertEqual(records[1].reportedTotalTokens, 103_000)
        XCTAssertTrue(records[1].maxMode)
        XCTAssertEqual(records[1].costUSD, 0.32)
    }

    func testParsesLegacyExportAndQuotedComma() throws {
        let csv = """
        \u{FEFF}Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost,Cost to you
        2025-02-01,"gpt-4o, legacy",1000,500,200,300,2000,"$0.10","$0.10"
        """

        let record = try XCTUnwrap(CursorUsageCSVParser.parse(csv).first)
        XCTAssertEqual(record.kind, "unknown")
        XCTAssertEqual(record.model, "gpt-4o, legacy")
        XCTAssertEqual(record.cacheWriteTokens, 500)
        XCTAssertEqual(record.exactTotalTokens, 1_500)
        XCTAssertEqual(record.reportedTotalTokens, 2_000)
    }

    func testLegacyDateWithBOMImportsIntoCollector() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorLegacyImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let csvURL = root.appendingPathComponent("legacy.csv")
        let archiveURL = root.appendingPathComponent("cursor-usage.json")
        let csv = """
        \u{FEFF}Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        2025-02-01,gpt-4o,1000,500,200,300,2000,$0.10
        """
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)

        let summary = try CursorUsageImportStore.importCSV(from: csvURL, archiveURL: archiveURL)
        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            cursorUsageImportURL: archiveURL,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(summary.addedRecords, 1)
        XCTAssertEqual(snapshot.sources["Cursor"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 1_500)
        XCTAssertEqual(snapshot.daily.first?.date, "2025-02-01")
    }

    func testRejectsUnknownSchemaAndZeroRows() {
        XCTAssertTrue(CursorUsageCSVParser.parse("Date,Model\n2026-01-01,gpt-5").isEmpty)
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        2026-01-01,gpt-5,0,0,0,0,0,0
        """
        XCTAssertTrue(CursorUsageCSVParser.parse(csv).isEmpty)
    }

    func testImportDeduplicatesAndFeedsExactCursorCollector() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorUsageImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let csvURL = root.appendingPathComponent("cursor-usage.csv")
        let archiveURL = root.appendingPathComponent("cursor-usage.json")
        let csv = """
        Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        "2026-04-16T03:32:33.284Z","","","On-Demand","composer-2-fast","No","0","3189","194368","1815","199372","0.11"
        "2026-04-15T03:39:53.013Z","","","Included","claude-4.6-sonnet-medium-thinking","Yes","50000","40000","10000","3000","103000","$0.32"
        """
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)

        let first = try CursorUsageImportStore.importCSV(from: csvURL, archiveURL: archiveURL)
        let second = try CursorUsageImportStore.importCSV(from: csvURL, archiveURL: archiveURL)
        XCTAssertEqual(first.addedRecords, 2)
        XCTAssertEqual(first.totalRecords, 2)
        XCTAssertEqual(second.addedRecords, 0)
        XCTAssertEqual(second.totalRecords, 2)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            cursorUsageImportURL: archiveURL,
            includeExperimentalAgentSources: true
        )
        XCTAssertEqual(snapshot.sources["Cursor"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Cursor"]?.records, 2)
        XCTAssertEqual(snapshot.totals.tokens, 262_372)
        XCTAssertEqual(snapshot.tools.first(where: { $0.tool == "Cursor" })?.tokens, 262_372)
        XCTAssertEqual(snapshot.totals.cost, 0.43, accuracy: 0.0001)
    }
}
