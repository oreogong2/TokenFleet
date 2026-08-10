import Foundation
@testable import TokenStepSwift

private enum FixtureFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message):
            return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw FixtureFailure.assertion(message)
    }
}

private func requireValue<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw FixtureFailure.assertion(message)
    }
    return value
}

private struct CommunityOriginFixtureCase {
    var mode: String
    var expectedValid: Bool
    var rawValue: String
    var lineNumber: Int
}

private func loadCommunityOriginFixture() throws -> [CommunityOriginFixtureCase] {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("script/fixtures/community-origin-cases.tsv")
    let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
    return try contents.components(separatedBy: .newlines).enumerated().compactMap {
        index, line in
        if line.isEmpty || line.hasPrefix("#") { return nil }
        let fields = line.split(
            separator: "\t",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard fields.count == 3,
              fields[0] == "production" || fields[0] == "testing",
              fields[1] == "valid" || fields[1] == "invalid"
        else {
            throw FixtureFailure.assertion(
                "malformed community origin fixture line \(index + 1)"
            )
        }
        return CommunityOriginFixtureCase(
            mode: String(fields[0]),
            expectedValid: fields[1] == "valid",
            rawValue: fields[2] == "<EMPTY>" ? "" : String(fields[2]),
            lineNumber: index + 1
        )
    }
}

private func requireError<E: Error & Equatable>(
    _ expected: E,
    _ operation: () throws -> Void,
    _ message: String
) throws {
    do {
        try operation()
        throw FixtureFailure.assertion("\(message): expected failure")
    } catch let error as E {
        try require(error == expected, "\(message): got \(error)")
    }
}

private final class FixtureURLProtocol: URLProtocol {
    static var handler: ((FixtureURLProtocol) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: FixtureFailure.assertion("missing URLProtocol handler")
            )
            return
        }
        handler(self)
    }

    override func stopLoading() {}

    func sendResponse(
        headers: [String: String]?,
        body: Data,
        finish: Bool = true
    ) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        if finish {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

private actor FailClosedRecordingTeamSyncHTTPClient: TeamSyncHTTPClient {
    private var requestCount = 0

    func send(_ request: URLRequest) async throws -> TeamSyncHTTPResponse {
        requestCount += 1
        return TeamSyncHTTPResponse(data: Data(), statusCode: 200)
    }

    func recordedRequestCount() -> Int {
        requestCount
    }
}

private final class EmptyTeamSyncStateStore: TeamSyncStateStoring {
    func load() -> TeamSyncPersistentState? { nil }
    func save(_ state: TeamSyncPersistentState) throws {}
    func delete() throws {}
}

private actor SuccessfulEnrollmentHTTPClient: TeamSyncHTTPClient {
    private var requestBody: Data?

    func send(_ request: URLRequest) async throws -> TeamSyncHTTPResponse {
        requestBody = request.httpBody
        guard let requestBody,
              let object = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              let publicID = object["device_public_id"] as? String
        else {
            throw TeamSyncProtocolError.invalidEnrollmentResponse
        }
        let responseObject: [String: Any] = [
            "device_id": "123e4567-e89b-12d3-a456-426614174000",
            "device_public_id": publicID,
            "device_secret": "fixture-device-secret-0123456789",
            "signing_key_derivation": "sha256-tokenfleet-hmac-v1",
        ]
        return TeamSyncHTTPResponse(
            data: try JSONSerialization.data(withJSONObject: responseObject, options: [.sortedKeys]),
            statusCode: 201
        )
    }

    func recordedRequestBody() -> Data? {
        requestBody
    }
}

private final class FixtureMemoryCredentialStore: TeamSyncCredentialStoring {
    var isAvailable: Bool { true }
    private(set) var values: [String: String] = [:]

    func saveDeviceSecret(_ secret: String, deviceID: String) throws {
        values[deviceID] = secret
    }

    func loadDeviceSecret(deviceID: String) throws -> String? {
        values[deviceID]
    }

    func deleteDeviceSecret(deviceID: String) throws {
        values.removeValue(forKey: deviceID)
    }
}

private final class CapturingTeamSyncStateStore: TeamSyncStateStoring {
    private(set) var state: TeamSyncPersistentState?

    func load() -> TeamSyncPersistentState? { state }
    func save(_ state: TeamSyncPersistentState) throws { self.state = state }
    func delete() throws { state = nil }
}

@main
private struct NetworkSupplyChainFixtureCheck {
    static func main() async throws {
        let secureURL = URL(string: "https://updates.example/asset")!

        let oversizedManifest = HTTPURLResponse(
            url: secureURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Length": "\(UpdateNetworkPolicy.maximumManifestBytes + 1)"
            ]
        )!
        try requireError(BoundedNetworkError.responseTooLarge, {
            _ = try BoundedNetworkPolicy.validateResponse(
                oversizedManifest,
                maximumBytes: Int64(UpdateNetworkPolicy.maximumManifestBytes)
            )
        }, "oversized manifest Content-Length")

        var chunkedBody = BoundedBodyAccumulator(maximumBytes: 4)
        try chunkedBody.append(Data([0, 1, 2, 3]))
        try requireError(BoundedNetworkError.bodyTooLarge, {
            try chunkedBody.append(Data([4]))
        }, "chunked body hard limit")

        try requireError(BoundedNetworkError.redirectRejected, {
            try BoundedNetworkPolicy.rejectRedirect()
        }, "strict manifest/leaderboard redirect policy")

        let github = URL(string: "https://github.com/org/repo/releases/download/v1/app.dmg")!
        let objects = URL(string: "https://objects.githubusercontent.com/release-assets/app.dmg")!
        var redirectCount = 0
        redirectCount = try UpdateNetworkPolicy.validatedRedirectCount(
            from: github,
            to: objects,
            currentCount: redirectCount
        )
        redirectCount = try UpdateNetworkPolicy.validatedRedirectCount(
            from: objects,
            to: github,
            currentCount: redirectCount
        )
        redirectCount = try UpdateNetworkPolicy.validatedRedirectCount(
            from: github,
            to: objects,
            currentCount: redirectCount
        )
        try require(redirectCount == 3, "three HTTPS cross-host redirects must remain compatible")
        try requireError(UpdateDownloadPolicyError.tooManyRedirects, {
            _ = try UpdateNetworkPolicy.validatedRedirectCount(
                from: objects,
                to: github,
                currentCount: redirectCount
            )
        }, "fourth DMG redirect")
        try requireError(UpdateDownloadPolicyError.insecureURL, {
            _ = try UpdateNetworkPolicy.validatedRedirectCount(
                from: github,
                to: URL(string: "http://objects.githubusercontent.com/app.dmg")!,
                currentCount: 0
            )
        }, "insecure DMG redirect")

        let mismatchedDMG = HTTPURLResponse(
            url: objects,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "3"]
        )!
        try requireError(UpdateDownloadPolicyError.contentLengthMismatch, {
            _ = try UpdateNetworkPolicy.validateDownloadResponse(
                mismatchedDMG,
                declaredAssetSize: 4
            )
        }, "DMG Content-Length mismatch")

        let chunkedDMG = HTTPURLResponse(
            url: objects,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let contentLength = try UpdateNetworkPolicy.validateDownloadResponse(
            chunkedDMG,
            declaredAssetSize: 4
        )
        try require(contentLength == nil, "missing Content-Length must be accepted for streaming")
        try requireError(UpdateDownloadPolicyError.bodyTooLarge, {
            _ = try UpdateNetworkPolicy.validatedCumulativeBytes(
                currentBytes: 3,
                nextChunkBytes: 2,
                declaredAssetSize: 4
            )
        }, "chunked DMG actual byte overflow")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenfleet-network-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let mismatchedFile = directory.appendingPathComponent("mismatch.dmg")
        try Data([0, 1, 2]).write(to: mismatchedFile)
        try requireError(UpdateDownloadPolicyError.finalSizeMismatch, {
            try UpdateDownloadedFileValidator.validateOrRemove(
                mismatchedFile,
                declaredAssetSize: 4
            )
        }, "final DMG size mismatch")
        try require(
            !FileManager.default.fileExists(atPath: mismatchedFile.path),
            "invalid temporary DMG must be deleted"
        )

        let exactFile = directory.appendingPathComponent("exact.dmg")
        try Data([0, 1, 2, 3]).write(to: exactFile)
        try UpdateDownloadedFileValidator.validateOrRemove(
            exactFile,
            declaredAssetSize: 4
        )
        try require(
            FileManager.default.fileExists(atPath: exactFile.path),
            "exact temporary DMG must remain available to preflight"
        )

        try await exerciseDownloaderCleanup(
            name: "oversized-content-length",
            declaredSize: 4,
            handler: { protocolInstance in
                protocolInstance.sendResponse(
                    headers: ["Content-Length": "5"],
                    body: Data(repeating: 1, count: 5)
                )
            }
        )
        try await exerciseDownloaderCleanup(
            name: "chunked-overflow",
            declaredSize: 4,
            handler: { protocolInstance in
                protocolInstance.sendResponse(
                    headers: nil,
                    body: Data(repeating: 2, count: 5)
                )
            }
        )
        try await exerciseDownloaderCleanup(
            name: "short-final-file",
            declaredSize: 4,
            handler: { protocolInstance in
                protocolInstance.sendResponse(
                    headers: nil,
                    body: Data(repeating: 3, count: 3)
                )
            }
        )
        try await exerciseDownloaderCleanup(
            name: "network-failure",
            declaredSize: 4,
            handler: { protocolInstance in
                protocolInstance.client?.urlProtocol(
                    protocolInstance,
                    didFailWithError: URLError(.notConnectedToInternet)
                )
            }
        )

        let successDirectory = directory.appendingPathComponent("successful-download")
        try FileManager.default.createDirectory(
            at: successDirectory,
            withIntermediateDirectories: true
        )
        FixtureURLProtocol.handler = { protocolInstance in
            protocolInstance.sendResponse(
                headers: ["Content-Length": "4"],
                body: Data([0, 1, 2, 3])
            )
        }
        let successConfiguration = UpdateNetworkPolicy.downloadConfiguration()
        successConfiguration.protocolClasses = [FixtureURLProtocol.self]
        let successDownloader = UpdateDownloader(
            declaredAssetSize: 4,
            configuration: successConfiguration,
            stagingDirectory: successDirectory,
            progress: { _ in }
        )
        let successfulFile = try await successDownloader.download(from: secureURL)
        let successfulAttributes = try FileManager.default.attributesOfItem(
            atPath: successfulFile.path
        )
        try require(
            (successfulAttributes[.size] as? NSNumber)?.intValue == 4,
            "successful streamed DMG must keep the exact declared size"
        )

        try require(
            TeamSyncProtocolConfiguration.maximumHTTPResponseBytes == 1_048_576,
            "team sync response limit must remain exactly one MiB"
        )
        try await exerciseTeamSyncResponseLimit(
            name: "team-content-length-overflow",
            headers: [
                "Content-Length": "\(TeamSyncProtocolConfiguration.maximumHTTPResponseBytes + 1)"
            ],
            body: Data(),
            expectedError: .responseTooLarge
        )
        try await exerciseTeamSyncResponseLimit(
            name: "team-chunked-overflow",
            headers: nil,
            body: Data(
                repeating: 4,
                count: TeamSyncProtocolConfiguration.maximumHTTPResponseBytes + 1
            ),
            expectedError: .bodyTooLarge
        )

        try validateCommunityServerBuildConfiguration()
        try validateCommunityLeaderboardLinkPolicy()
        try await validateMissingCredentialStoreFailsClosed()
        try await validateEnrollmentCodeIsRequestOnly()

        print("TokenFleet network supply-chain fixture passed")
    }

    private static func validateCommunityServerBuildConfiguration() throws {
        try require(
            TeamSyncCommunityServerConfiguration.infoDictionaryKey
                == "TokenFleetCommunityServerURL",
            "signed bundle community origin key changed unexpectedly"
        )
        try require(
            TeamSyncCommunityServerConfiguration.validatedProductionOrigin(
                infoDictionaryValue: "https://community.example.invalid:8443"
            )?.absoluteString == "https://community.example.invalid:8443",
            "strict canonical production HTTPS origin was rejected"
        )
        let cases = try loadCommunityOriginFixture()
        try require(cases.count > 40, "community origin fixture lost required coverage")
        for fixture in cases {
            let actual: Bool
            switch fixture.mode {
            case "production":
                actual = TeamSyncCommunityServerConfiguration.validatedProductionOrigin(
                    infoDictionaryValue: fixture.rawValue
                ) != nil
            case "testing":
                actual = TeamSyncCommunityServerConfiguration.validatedTestingOrigin(
                    fixture.rawValue
                ) != nil
            default:
                throw FixtureFailure.assertion("unexpected community origin fixture mode")
            }
            try require(
                actual == fixture.expectedValid,
                "community origin fixture mismatch at line \(fixture.lineNumber): \(fixture.rawValue)"
            )
        }
    }

    private static func validateCommunityLeaderboardLinkPolicy() throws {
        let url = TeamSyncProtocol.publicLeaderboardURL(
            serverURL: "https://community.example:8443",
            isEnrolled: true,
            isScreenshotRendering: false
        )
        try require(
            TeamSyncProtocolConfiguration.publicLeaderboardPath == "/rank",
            "community leaderboard path must remain fixed"
        )
        try require(url?.scheme == "https", "community leaderboard must use HTTPS")
        try require(url?.host == "community.example", "community leaderboard must stay on server origin")
        try require(url?.port == 8443, "community leaderboard must preserve the canonical origin port")
        try require(url?.path == "/rank", "community leaderboard must open the fixed /rank path")
        try require(url?.query == nil, "community leaderboard must not include query credentials")
        try require(url?.fragment == nil, "community leaderboard must not include fragments")
        try require(url?.user == nil, "community leaderboard must not include userinfo")
        try require(url?.password == nil, "community leaderboard must not include passwords")

        let maliciousInputs = [
            "http://community.example",
            "https://user:secret@community.example",
            "https://community.example/private",
            "https://community.example/?token=must-not-leak",
            "https://community.example/#access-token"
        ]
        for value in maliciousInputs {
            try require(
                TeamSyncProtocol.publicLeaderboardURL(
                    serverURL: value,
                    isEnrolled: true,
                    isScreenshotRendering: false
                ) == nil,
                "malicious server URL must not produce a leaderboard destination"
            )
        }
        try require(
            TeamSyncProtocol.publicLeaderboardURL(
                serverURL: "https://community.example",
                isEnrolled: false,
                isScreenshotRendering: false
            ) == nil,
            "leaderboard must stay unavailable before enrollment"
        )
        try require(
            TeamSyncProtocol.publicLeaderboardURL(
                serverURL: "https://community.example",
                isEnrolled: true,
                isScreenshotRendering: true
            ) == nil,
            "screenshot rendering must not produce an external-open destination"
        )
    }

    private static func validateMissingCredentialStoreFailsClosed() async throws {
        try require(
            TeamSyncCredentialStorageAvailability.isAvailable,
            "production builds must expose the audited Keychain credential store"
        )
        let http = FailClosedRecordingTeamSyncHTTPClient()
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: DisabledTeamSyncCredentialStore(),
            stateStore: EmptyTeamSyncStateStore()
        )
        do {
            _ = try await service.enroll(
                serverURL: "https://community.example",
                enrollmentToken: "must-not-be-consumed"
            )
            throw FixtureFailure.assertion("disabled credential storage unexpectedly enrolled")
        } catch let error as TeamSyncProtocolError {
            try require(
                error == .secureCredentialStorageUnavailable,
                "disabled credential storage must fail with the secure-store gate"
            )
        }
        let requestCount = await http.recordedRequestCount()
        try require(
            requestCount == 0,
            "disabled credential storage must reject before any network request"
        )
    }

    private static func validateEnrollmentCodeIsRequestOnly() async throws {
        let oneTimeCode = "fixture-one-time-code-must-not-persist"
        let http = SuccessfulEnrollmentHTTPClient()
        let stateStore = CapturingTeamSyncStateStore()
        let credentialStore = FixtureMemoryCredentialStore()
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: credentialStore,
            stateStore: stateStore
        )
        let state = try await service.enroll(
            serverURL: "https://community.example",
            enrollmentToken: oneTimeCode,
            appVersion: "fixture"
        )
        let encodedState = try JSONEncoder().encode(state)
        let encodedText = String(data: encodedState, encoding: .utf8) ?? ""
        try require(
            !encodedText.contains(oneTimeCode),
            "one-time enrollment code must not enter returned persistent state"
        )
        let persistedState = try requireValue(
            stateStore.state,
            "successful enrollment did not save state"
        )
        let persistedData = try JSONEncoder().encode(persistedState)
        let persistedText = String(data: persistedData, encoding: .utf8) ?? ""
        try require(
            !persistedText.contains(oneTimeCode),
            "one-time enrollment code must not enter saved state"
        )
        let requestBody = try requireValue(
            await http.recordedRequestBody(),
            "enrollment request body was not recorded"
        )
        let object = try requireValue(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
            "enrollment request body was not a JSON object"
        )
        try require(
            object["enrollment_token"] as? String == oneTimeCode,
            "one-time enrollment code must be sent only in the enrollment body"
        )
    }

    private static func exerciseDownloaderCleanup(
        name: String,
        declaredSize: Int64,
        handler: @escaping (FixtureURLProtocol) -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenfleet-downloader-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        FixtureURLProtocol.handler = handler
        let configuration = UpdateNetworkPolicy.downloadConfiguration()
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let downloader = UpdateDownloader(
            declaredAssetSize: declaredSize,
            configuration: configuration,
            stagingDirectory: directory,
            progress: { _ in }
        )
        do {
            _ = try await downloader.download(
                from: URL(string: "https://updates.example/\(name).dmg")!
            )
            throw FixtureFailure.assertion("\(name): expected download failure")
        } catch is FixtureFailure {
            throw FixtureFailure.assertion("\(name): downloader unexpectedly succeeded")
        } catch {
            let remaining = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            try require(
                remaining.isEmpty,
                "\(name): failed download must remove its controlled temporary file"
            )
        }
    }

    private static func exerciseTeamSyncResponseLimit(
        name: String,
        headers: [String: String]?,
        body: Data,
        expectedError: BoundedNetworkError
    ) async throws {
        FixtureURLProtocol.handler = { protocolInstance in
            protocolInstance.sendResponse(headers: headers, body: body)
        }
        let configuration = BoundedNetworkPolicy.ephemeralConfiguration(
            requestTimeout: 2,
            resourceTimeout: 2
        )
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let client = URLSessionTeamSyncHTTPClient(configuration: configuration)
        var request = URLRequest(
            url: URL(string: "https://team.example/\(name)")!
        )
        request.httpMethod = "POST"
        do {
            _ = try await client.send(request)
            throw FixtureFailure.assertion("\(name): expected bounded response failure")
        } catch is FixtureFailure {
            throw FixtureFailure.assertion("\(name): client unexpectedly accepted response")
        } catch let error as BoundedNetworkError {
            try require(
                error == expectedError,
                "\(name): expected \(expectedError), got \(error)"
            )
        }
    }
}
