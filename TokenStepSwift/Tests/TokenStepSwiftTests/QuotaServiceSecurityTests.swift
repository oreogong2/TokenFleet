import Foundation
import XCTest
@testable import TokenStepSwift

final class QuotaServiceSecurityTests: XCTestCase {
    func testCodexQuotaExecutableSelectionDoesNotSearchInheritedPATH() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenfleet-quota-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        XCTAssertEqual(
            CodexQuotaService.firstExecutableURL(
                paths: ["relative/codex", "/tmp/../tmp/codex", executable.path]
            ),
            executable.standardizedFileURL
        )
        XCTAssertNil(
            CodexQuotaService.firstExecutableURL(paths: ["codex", "./codex"])
        )
    }
}
