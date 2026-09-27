import Foundation

struct TeamSyncHTTPResponse {
    var data: Data
    var statusCode: Int
}

protocol TeamSyncHTTPClient {
    func send(_ request: URLRequest) async throws -> TeamSyncHTTPResponse
}

struct URLSessionTeamSyncHTTPClient: TeamSyncHTTPClient {
    private let configuration: URLSessionConfiguration

    init(
        configuration: URLSessionConfiguration = BoundedNetworkPolicy.ephemeralConfiguration(
            requestTimeout: 30,
            resourceTimeout: 45
        )
    ) {
        self.configuration = configuration
    }

    func send(_ request: URLRequest) async throws -> TeamSyncHTTPResponse {
        let loader = BoundedDataLoader(
            maximumBytes: TeamSyncProtocolConfiguration.maximumHTTPResponseBytes,
            configuration: configuration
        )
        let (data, response) = try await loader.load(request)
        return TeamSyncHTTPResponse(data: data, statusCode: response.statusCode)
    }
}

enum TeamSyncManualRetryPolicy {
    static func allowsForceRetry(
        automaticRetryStopped: Bool,
        terminalReason: TeamSyncTerminalReason?
    ) -> Bool {
        if terminalReason == .credentials { return false }
        if !automaticRetryStopped { return true }
        return terminalReason == .requestRejected
    }
}

actor TeamSyncService {
    static let live = TeamSyncService(
        httpClient: URLSessionTeamSyncHTTPClient(),
        credentialStore: TeamSyncKeychainCredentialStore(),
        stateStore: FileTeamSyncStateStore()
    )

    private struct OperationToken: Equatable {
        var id: UUID
        var epoch: UInt64
    }

    private let httpClient: TeamSyncHTTPClient
    private let credentialStore: TeamSyncCredentialStoring
    private let stateStore: TeamSyncStateStoring
    private let machineFingerprint: @Sendable () throws -> String
    private let requestClock: @Sendable () -> Date
    private var operationEpoch: UInt64 = 0
    private var activeOperationID: UUID?

    init(
        httpClient: TeamSyncHTTPClient,
        credentialStore: TeamSyncCredentialStoring,
        stateStore: TeamSyncStateStoring,
        requestClock: @escaping @Sendable () -> Date = { Date() },
        machineFingerprint: @escaping @Sendable () throws -> String = { try TeamSyncMachineIdentity.current() }
    ) {
        self.httpClient = httpClient
        self.credentialStore = credentialStore
        self.stateStore = stateStore
        self.requestClock = requestClock
        self.machineFingerprint = machineFingerprint
    }

    func loadState() -> TeamSyncPersistentState? {
        guard var state = stateStore.load() else { return nil }
        do { state = try machineState() ?? state }
        catch {
            var stopped = stateStore.load() ?? state
            let reason = safeProtocolError(error)
            stopped.lastError = reason.localizedDescription
            if reason == .machineIdentityUnavailable {
                // An unavailable hardware read is not a revoked credential.
                // Keep the retry timer reachable; machineState still blocks
                // every authenticated operation before any network request.
                stopped.automaticRetryStopped = false
                stopped.terminalReason = nil
                stopped.nextAttemptAt = requestClock().addingTimeInterval(60)
            } else {
                stopped.automaticRetryStopped = true
                stopped.terminalReason = .credentials
            }
            return stopped
        }
        if state.retryPolicyVersion < 1 {
            // Old clients classified clock skew and HTML as terminal. Permit
            // ONE upgrade recovery attempt; a confirmed revocation stays stopped.
            state.retryPolicyVersion = 1
            state.automaticRetryStopped = false
            state.terminalReason = nil
            state.nextAttemptAt = nil
            state.failureCount = 0
            do {
                try stateStore.save(state)
            } catch {
                // Do not repeat the recovery on every launch if persistence
                // failed. Keep the previous stopped state until it can be saved.
                return stateStore.load()
            }
        }
        return state
    }

    func enroll(
        serverURL rawServerURL: String,
        enrollmentToken: String,
        appVersion: String = UpdateService.currentVersion,
        now: Date = Date()
    ) async throws -> TeamSyncPersistentState {
        guard credentialStore.isAvailable else {
            throw TeamSyncProtocolError.secureCredentialStorageUnavailable
        }
        let operation = try beginOperation()
        defer { finishOperation(operation) }
        let normalizedServerURL = try TeamSyncProtocol.normalizedServerURL(rawServerURL).absoluteString
        let previousState = try machineState()
        let devicePublicID = previousState.flatMap {
            TeamSyncCredentialValidation.canonicalDevicePublicID($0.devicePublicID)
        } ?? UUID().uuidString.lowercased()
        let request = try TeamSyncProtocol.enrollmentURLRequest(
            serverURL: normalizedServerURL,
            enrollmentToken: enrollmentToken,
            devicePublicID: devicePublicID,
            appVersion: appVersion,
            machineFingerprint: try currentMachineFingerprint()
        )
        let response: TeamSyncHTTPResponse
        do {
            response = try await httpClient.send(request)
        } catch let error as TeamSyncProtocolError {
            throw error
        } catch {
            throw TeamSyncProtocolError.networkUnavailable
        }
        try ensureOperation(operation)
        try handleMachineResponse(response)
        guard (200...299).contains(response.statusCode) else {
            throw TeamSyncProtocolError.httpStatus(response.statusCode)
        }
        guard let enrollment = try? JSONDecoder().decode(TeamSyncEnrollmentResponse.self, from: response.data),
              let serverDeviceID = TeamSyncCredentialValidation.boundedDeviceID(enrollment.deviceID),
              let deviceSecret = TeamSyncCredentialValidation.boundedDeviceSecret(enrollment.deviceSecret),
              let returnedPublicID = enrollment.devicePublicID,
              TeamSyncCredentialValidation.canonicalDevicePublicID(returnedPublicID) == devicePublicID,
              enrollment.signingKeyDerivation == TeamSyncProtocolConfiguration.signingKeyDerivation
        else {
            throw TeamSyncProtocolError.invalidEnrollmentResponse
        }

        var previousBinding: (serverURL: String, deviceID: String, secret: String)?
        if let previousState,
           let previousDeviceID = previousState.deviceID,
           TeamSyncCredentialValidation.canonicalServerOrigin(previousState.serverURL) != nil,
           let previousSecret = try? credentialStore.loadDeviceSecret(
               serverURL: previousState.serverURL,
               deviceID: previousDeviceID
           ) {
            previousBinding = (previousState.serverURL, previousDeviceID, previousSecret)
        }

        do {
            try ensureOperation(operation)
            try credentialStore.saveDeviceSecret(
                deviceSecret,
                serverURL: normalizedServerURL,
                deviceID: serverDeviceID
            )
            let state = TeamSyncPersistentState(
                serverURL: normalizedServerURL,
                devicePublicID: devicePublicID,
                machineFingerprint: try currentMachineFingerprint(),
                uploadNotBeforeDate: previousState?.uploadNotBeforeDate,
                deviceID: serverDeviceID,
                enrolledAt: now
            )
            do {
                try ensureOperation(operation)
                try stateStore.save(state)
            } catch {
                let previousStateAlreadyMatchesRotatedBinding = previousState?.serverURL == normalizedServerURL
                    && previousState?.deviceID == serverDeviceID
                if previousStateAlreadyMatchesRotatedBinding {
                    // Re-enrollment rotates the server secret before this
                    // response arrives. The existing state already points to
                    // the same origin/device binding, so retaining the new
                    // Keychain value is the only recoverable state. Restoring
                    // the old secret would guarantee a 401 on the next sync.
                } else if let previousBinding {
                    try? credentialStore.saveDeviceSecret(
                        previousBinding.secret,
                        serverURL: previousBinding.serverURL,
                        deviceID: previousBinding.deviceID
                    )
                } else {
                    try? credentialStore.clearDeviceSecret(deviceID: serverDeviceID)
                }
                throw TeamSyncProtocolError.stateUnavailable
            }
            return state
        } catch let error as TeamSyncProtocolError {
            throw error
        } catch {
            throw TeamSyncProtocolError.credentialsUnavailable
        }
    }

    func fetchCommunityRank(
        serverURL rawServerURL: String,
        now: Date = Date()
    ) async throws -> TeamSyncCommunityRank {
        guard credentialStore.isAvailable else {
            throw TeamSyncProtocolError.secureCredentialStorageUnavailable
        }
        guard let state = try machineState(),
              state.isEnrolled,
              let deviceID = state.deviceID
        else {
            throw TeamSyncProtocolError.notEnrolled
        }
        let normalizedServerURL = try TeamSyncProtocol.normalizedServerURL(
            rawServerURL
        ).absoluteString
        guard state.serverURL == normalizedServerURL else {
            throw TeamSyncProtocolError.reconnectRequired
        }
        let deviceSecret: String
        do {
            guard let storedSecret = try credentialStore.loadDeviceSecret(
                serverURL: normalizedServerURL,
                deviceID: deviceID
            ) else {
                throw TeamSyncProtocolError.credentialsUnavailable
            }
            deviceSecret = storedSecret
        } catch let error as TeamSyncProtocolError {
            throw error
        } catch {
            throw TeamSyncProtocolError.credentialStoreTemporarilyUnavailable
        }
        let request = try TeamSyncProtocol.communityRankURLRequest(
            serverURL: normalizedServerURL,
            deviceID: deviceID,
            deviceSecret: deviceSecret,
            timestamp: Int(now.timeIntervalSince1970),
            nonce: UUID().uuidString.lowercased(),
            machineFingerprint: state.machineFingerprint
        )
        let response: TeamSyncHTTPResponse
        do {
            response = try await httpClient.send(request)
        } catch let error as TeamSyncProtocolError {
            throw error
        } catch {
            throw TeamSyncProtocolError.networkUnavailable
        }
        guard let currentState = stateStore.load(),
              currentState.serverURL == normalizedServerURL,
              currentState.deviceID == deviceID,
              currentState.isEnrolled
        else {
            throw TeamSyncProtocolError.operationCancelled
        }
        try handleMachineResponse(response)
        guard (200...299).contains(response.statusCode) else {
            throw TeamSyncProtocolError.httpStatus(response.statusCode)
        }
        guard let rank = try? JSONDecoder().decode(
            TeamSyncCommunityRank.self,
            from: response.data
        ), rank.isValid else {
            throw TeamSyncProtocolError.invalidCommunityRankResponse
        }
        return rank
    }

    func additionalDeviceCode(
        serverURL rawServerURL: String,
        now: Date = Date()
    ) async throws -> TeamSyncAdditionalDeviceCode {
        guard credentialStore.isAvailable else {
            throw TeamSyncProtocolError.secureCredentialStorageUnavailable
        }
        guard let state = try machineState(),
              state.isEnrolled,
              let deviceID = state.deviceID
        else {
            throw TeamSyncProtocolError.notEnrolled
        }
        let normalizedServerURL = try TeamSyncProtocol.normalizedServerURL(
            rawServerURL
        ).absoluteString
        guard state.serverURL == normalizedServerURL else {
            throw TeamSyncProtocolError.reconnectRequired
        }
        let deviceSecret: String
        do {
            guard let storedSecret = try credentialStore.loadDeviceSecret(
                serverURL: normalizedServerURL,
                deviceID: deviceID
            ) else {
                throw TeamSyncProtocolError.credentialsUnavailable
            }
            deviceSecret = storedSecret
        } catch let error as TeamSyncProtocolError {
            throw error
        } catch {
            throw TeamSyncProtocolError.credentialStoreTemporarilyUnavailable
        }
        let request = try TeamSyncProtocol.additionalDeviceURLRequest(
            serverURL: normalizedServerURL,
            deviceID: deviceID,
            deviceSecret: deviceSecret,
            timestamp: Int(now.timeIntervalSince1970),
            nonce: UUID().uuidString.lowercased(),
            machineFingerprint: state.machineFingerprint
        )
        let response: TeamSyncHTTPResponse
        do {
            response = try await httpClient.send(request)
        } catch let error as TeamSyncProtocolError {
            throw error
        } catch {
            throw TeamSyncProtocolError.networkUnavailable
        }
        guard let currentState = stateStore.load(),
              currentState.serverURL == normalizedServerURL,
              currentState.deviceID == deviceID,
              currentState.isEnrolled
        else {
            throw TeamSyncProtocolError.operationCancelled
        }
        try handleMachineResponse(response)
        guard (200...299).contains(response.statusCode) else {
            throw TeamSyncProtocolError.httpStatus(response.statusCode)
        }
        return try TeamSyncAdditionalDeviceCode.decode(response.data, now: now)
    }

    func fetchPublicLeaderboard(
        serverURL rawServerURL: String
    ) async throws -> TeamSyncPublicLeaderboard {
        let normalizedServerURL = try TeamSyncProtocol.normalizedServerURL(
            rawServerURL
        ).absoluteString
        var request = try TeamSyncProtocol.publicLeaderboardAPIURLRequest(
            serverURL: normalizedServerURL, enriched: true
        )
        var response: TeamSyncHTTPResponse
        do {
            response = try await httpClient.send(request)
            if response.statusCode == 404 {
                request = try TeamSyncProtocol.publicLeaderboardAPIURLRequest(serverURL: normalizedServerURL)
                response = try await httpClient.send(request)
            }
        } catch let error as TeamSyncProtocolError {
            throw error
        } catch {
            throw TeamSyncProtocolError.networkUnavailable
        }
        guard (200...299).contains(response.statusCode) else {
            throw TeamSyncProtocolError.httpStatus(response.statusCode)
        }
        guard let leaderboard = try? JSONDecoder().decode(
            TeamSyncPublicLeaderboard.self,
            from: response.data
        ), leaderboard.isValid else {
            throw TeamSyncProtocolError.invalidCommunityRankResponse
        }
        return leaderboard
    }

    /// Requests a one-time browser bridge for the existing device binding.
    /// The returned opaque value deliberately stays only in the caller's
    /// short-lived stack frame; this service does not log or persist it.
    func issueCommunityShareGrant(
        serverURL rawServerURL: String,
        now: Date = Date()
    ) async throws -> TeamSyncCommunityShareGrant {
        guard credentialStore.isAvailable else {
            throw TeamSyncProtocolError.secureCredentialStorageUnavailable
        }
        guard let state = try machineState(),
              state.isEnrolled,
              let deviceID = state.deviceID
        else {
            throw TeamSyncProtocolError.notEnrolled
        }
        let normalizedServerURL = try TeamSyncProtocol.normalizedServerURL(
            rawServerURL
        ).absoluteString
        guard state.serverURL == normalizedServerURL else {
            throw TeamSyncProtocolError.reconnectRequired
        }
        let deviceSecret: String
        do {
            guard let storedSecret = try credentialStore.loadDeviceSecret(
                serverURL: normalizedServerURL,
                deviceID: deviceID
            ) else {
                throw TeamSyncProtocolError.credentialsUnavailable
            }
            deviceSecret = storedSecret
        } catch let error as TeamSyncProtocolError {
            throw error
        } catch {
            throw TeamSyncProtocolError.credentialStoreTemporarilyUnavailable
        }
        let request = try TeamSyncProtocol.communityShareGrantURLRequest(
            serverURL: normalizedServerURL,
            deviceID: deviceID,
            deviceSecret: deviceSecret,
            timestamp: Int(now.timeIntervalSince1970),
            nonce: UUID().uuidString.lowercased(),
            machineFingerprint: state.machineFingerprint
        )
        let response: TeamSyncHTTPResponse
        do {
            response = try await httpClient.send(request)
        } catch let error as TeamSyncProtocolError {
            throw error
        } catch {
            throw TeamSyncProtocolError.networkUnavailable
        }
        guard let currentState = stateStore.load(),
              currentState.serverURL == normalizedServerURL,
              currentState.deviceID == deviceID,
              currentState.isEnrolled
        else {
            throw TeamSyncProtocolError.operationCancelled
        }
        try handleMachineResponse(response)
        guard (200...299).contains(response.statusCode) else {
            throw TeamSyncProtocolError.httpStatus(response.statusCode)
        }
        guard let grant = try? JSONDecoder().decode(
            TeamSyncCommunityShareGrant.self,
            from: response.data
        ), grant.isValid else {
            throw TeamSyncProtocolError.invalidCommunityShareGrantResponse
        }
        return grant
    }

    func synchronize(
        snapshot: UsageSnapshot,
        serverURL rawServerURL: String,
        force: Bool = false,
        now: Date = Date()
    ) async throws -> TeamSyncPersistentState {
        let operation = try beginOperation()
        defer { finishOperation(operation) }
        _ = loadState()
        guard var state = try machineState(),
              state.isEnrolled,
              let deviceID = state.deviceID
        else {
            throw TeamSyncProtocolError.notEnrolled
        }
        let normalizedServerURL = try TeamSyncProtocol.normalizedServerURL(rawServerURL).absoluteString
        guard normalizedServerURL == state.serverURL else {
            throw TeamSyncProtocolError.reconnectRequired
        }
        if state.terminalReason == .credentials {
            throw TeamSyncProtocolError.reconnectRequired
        }
        if state.automaticRetryStopped {
            // A rejected aggregate/configuration remains terminal for
            // automatic work, but an explicit force action may retry after the
            // user fixes local data or upgrades the client. Credential
            // failures above are never bypassable.
            guard force,
                  TeamSyncManualRetryPolicy.allowsForceRetry(
                    automaticRetryStopped: state.automaticRetryStopped,
                    terminalReason: state.terminalReason
                  )
            else {
                throw TeamSyncProtocolError.automaticRetryStopped
            }
            state.automaticRetryStopped = false
            state.terminalReason = nil
            state.failureCount = 0
            state.nextAttemptAt = nil
            state.lastError = nil
        }
        if !force, let nextAttemptAt = state.nextAttemptAt, nextAttemptAt > now {
            return state
        }

        do {
            guard let deviceSecret = try credentialStore.loadDeviceSecret(
                serverURL: normalizedServerURL,
                deviceID: deviceID
            ) else {
                throw TeamSyncProtocolError.credentialsUnavailable
            }
            let bucketBuild = try TeamSyncProtocol.dailyBucketBuild(snapshot: snapshot)
            var pending: [(bucket: TeamSyncDailyBucket, hash: String)] = []
            for bucket in bucketBuild.buckets {
                if let earliest = state.uploadNotBeforeDate, bucket.date < earliest { continue }
                let hash = try TeamSyncProtocol.contentHash(for: bucket)
                if force || state.syncedBucketHashes[bucket.naturalKey] != hash {
                    pending.append((bucket, hash))
                }
            }
            // v1 has no reliable proof that a missing tool/model/source means
            // deletion rather than a temporarily unavailable collector. Keep
            // all absent natural keys in the local ledger and never synthesize
            // a tombstone, including during force sync.
            state.lastOmittedIncompleteBucketCount = bucketBuild.omittedIncompleteBucketCount

            let generatedAt = TeamSyncProtocol.generatedAt(now)
            for chunkStart in stride(
                from: 0,
                to: pending.count,
                by: TeamSyncProtocolConfiguration.maxBucketsPerRequest
            ) {
                let chunkEnd = min(chunkStart + TeamSyncProtocolConfiguration.maxBucketsPerRequest, pending.count)
                var chunk = Array(pending[chunkStart..<chunkEnd])
                var clockOffset: TimeInterval = 0
                var authenticationRetries = 0
                var validationRetries = 0
                var acknowledged: DailyUsageIngestResponse?
                while !chunk.isEmpty {
                    let payload = TeamSyncDailyPayload(
                        schemaVersion: TeamSyncProtocolConfiguration.schemaVersion,
                        collectorVersion: TeamSyncProtocolConfiguration.collectorVersion,
                        generatedAt: generatedAt,
                        buckets: chunk.map(\.bucket)
                    )
                    // Payload time describes the snapshot; signing time must be
                    // fresh for EVERY request, including retries and later chunks.
                    let signedAt = requestClock().addingTimeInterval(clockOffset)
                    let request = try TeamSyncProtocol.dailyUsageURLRequest(
                        serverURL: normalizedServerURL,
                        deviceID: deviceID,
                        deviceSecret: deviceSecret,
                        payload: payload,
                        timestamp: Int(signedAt.timeIntervalSince1970),
                        nonce: UUID().uuidString.lowercased(),
                        machineFingerprint: state.machineFingerprint
                    )
                    let response: TeamSyncHTTPResponse
                    do {
                        response = try await httpClient.send(request)
                    } catch let error as TeamSyncProtocolError {
                        throw error
                    } catch {
                        throw TeamSyncProtocolError.networkUnavailable
                    }
                    try ensureOperation(operation)
                    if response.statusCode == 401 {
                        let serverTime = Self.clockSkewTime(response.data)
                        if authenticationRetries == 0 {
                            authenticationRetries += 1
                            if let serverTime {
                                clockOffset = serverTime - requestClock().timeIntervalSince1970
                            }
                            continue
                        }
                        if serverTime != nil { throw TeamSyncProtocolError.clockSkew }
                    }
                    if response.statusCode == 422, validationRetries < 2 {
                        let rejected = Self.rejectedBucketIndices(response.data, count: chunk.count)
                        if !rejected.isEmpty {
                            validationRetries += 1
                            state.lastOmittedIncompleteBucketCount += rejected.count
                            chunk = chunk.enumerated().filter { !rejected.contains($0.offset) }.map(\.element)
                            continue
                        }
                    }
                    try handleMachineResponse(response)
                    guard (200...299).contains(response.statusCode) else {
                        throw TeamSyncProtocolError.httpStatus(response.statusCode)
                    }
                    guard let ingestResponse = try? JSONDecoder().decode(
                        DailyUsageIngestResponse.self,
                        from: response.data
                    ), ingestResponse.isValid(expectedBucketCount: chunk.count) else {
                        throw TeamSyncProtocolError.invalidIngestResponse
                    }
                    acknowledged = ingestResponse
                    break
                }
                // Quarantined rows are not acknowledged or added to the hash
                // ledger. Healthy rows are committed only after a valid receipt.
                guard let ingestResponse = acknowledged else { continue }
                var committedState = state
                committedState.lastLedgerVersion = ingestResponse.ledgerVersion
                for item in chunk {
                    committedState.syncedBucketHashes[item.bucket.naturalKey] = item.hash
                }
                try ensureOperation(operation)
                try stateStore.save(committedState)
                state = committedState
            }

            state.lastSyncAt = now
            state.lastError = nil
            state.failureCount = 0
            state.nextAttemptAt = nil
            state.automaticRetryStopped = false
            state.terminalReason = nil
            try ensureOperation(operation)
            try stateStore.save(state)
            return state
        } catch {
            let protocolError = safeProtocolError(error)
            if protocolError == .machineChanged { throw protocolError }
            if protocolError == .operationCancelled {
                throw protocolError
            }
            state.lastError = protocolError.localizedDescription
            state.failureCount += 1
            if shouldRetry(protocolError) {
                state.automaticRetryStopped = false
                state.terminalReason = nil
                state.nextAttemptAt = now.addingTimeInterval(
                    TeamSyncBackoffPolicy.delay(failureCount: state.failureCount)
                )
            } else {
                state.automaticRetryStopped = true
                state.nextAttemptAt = nil
                if protocolError == .credentialsUnavailable
                    || protocolError == .reconnectRequired {
                    state.terminalReason = .credentials
                } else if case let .httpStatus(status) = protocolError,
                          status == 401 || status == 403 {
                    state.terminalReason = .credentials
                } else {
                    state.terminalReason = .requestRejected
                }
            }
            try? stateStore.save(state)
            throw protocolError
        }
    }

    func clear() throws {
        operationEpoch &+= 1
        activeOperationID = nil
        let previousState = stateStore.load()
        do {
            try credentialStore.clearDeviceSecret(deviceID: previousState?.deviceID)
        } catch let error as TeamSyncProtocolError {
            throw error
        } catch {
            throw TeamSyncProtocolError.credentialsUnavailable
        }
        do {
            if let devicePublicID = previousState?.devicePublicID,
               !devicePublicID.isEmpty {
                // The anonymous installation ID is not a credential. Retain it
                // across disconnects so a later enrollment identifies the same
                // installation, while dropping every server and sync binding.
                try stateStore.save(
                    TeamSyncPersistentState(
                        serverURL: "",
                        devicePublicID: devicePublicID,
                        machineFingerprint: previousState?.machineFingerprint,
                        uploadNotBeforeDate: previousState?.uploadNotBeforeDate
                    )
                )
            } else {
                try stateStore.delete()
            }
        } catch {
            throw TeamSyncProtocolError.stateUnavailable
        }
    }

    private func currentMachineFingerprint() throws -> String {
        let fingerprint: String
        do { fingerprint = try machineFingerprint() }
        catch { throw TeamSyncProtocolError.machineIdentityUnavailable }
        guard fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw TeamSyncProtocolError.machineIdentityUnavailable
        }
        return fingerprint
    }

    private func machineState() throws -> TeamSyncPersistentState? {
        let fingerprint = try currentMachineFingerprint()
        guard var state = stateStore.load() else { return nil }
        if let previous = state.machineFingerprint, previous != fingerprint {
            try resetMachineBinding(fingerprint: fingerprint)
            throw TeamSyncProtocolError.machineChanged
        }
        if state.machineFingerprint == nil {
            state.machineFingerprint = fingerprint
            do { try stateStore.save(state) }
            catch { throw TeamSyncProtocolError.stateUnavailable }
        }
        return state
    }

    private func resetMachineBinding(fingerprint: String) throws {
        let previous = stateStore.load()
        try credentialStore.clearDeviceSecret(deviceID: previous?.deviceID)
        var replacement = TeamSyncPersistentState(
            serverURL: previous?.serverURL ?? "", machineFingerprint: fingerprint,
            uploadNotBeforeDate: DateFormatter.tokenStepDay.string(from: requestClock())
        )
        replacement.lastError = TeamSyncProtocolError.machineChanged.localizedDescription
        replacement.automaticRetryStopped = true
        replacement.terminalReason = .credentials
        try stateStore.save(replacement)
    }

    private func handleMachineResponse(_ response: TeamSyncHTTPResponse) throws {
        guard response.statusCode == 409,
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let detail = object["detail"] as? [String: Any],
              detail["code"] as? String == "machine_mismatch" else { return }
        try resetMachineBinding(fingerprint: currentMachineFingerprint())
        throw TeamSyncProtocolError.machineChanged
    }

    private func safeProtocolError(_ error: Error) -> TeamSyncProtocolError {
        if let error = error as? TeamSyncProtocolError {
            return error
        }
        return .networkUnavailable
    }

    private func shouldRetry(_ error: TeamSyncProtocolError) -> Bool {
        switch error {
        case .networkUnavailable, .credentialStoreTemporarilyUnavailable, .invalidIngestResponse, .clockSkew:
            return true
        case let .httpStatus(status):
            return status != 401 && status != 403
        default:
            return false
        }
    }

    private static func clockSkewTime(_ data: Data) -> TimeInterval? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? [String: Any],
              detail["code"] as? String == "clock_skew",
              let timestamp = detail["server_time"] as? Int,
              (1...4_102_444_800).contains(timestamp)
        else { return nil }
        return TimeInterval(timestamp)
    }

    private static func rejectedBucketIndices(_ data: Data, count: Int) -> Set<Int> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = object["detail"] as? [[String: Any]] else { return [] }
        return Set(details.compactMap { detail in
            guard let location = detail["loc"] as? [Any], location.count >= 3,
                  location[0] as? String == "body", location[1] as? String == "buckets",
                  let index = location[2] as? Int, (0..<count).contains(index)
            else { return nil }
            return index
        })
    }

    private func beginOperation() throws -> OperationToken {
        guard activeOperationID == nil else {
            throw TeamSyncProtocolError.operationInProgress
        }
        let token = OperationToken(id: UUID(), epoch: operationEpoch)
        activeOperationID = token.id
        return token
    }

    private func ensureOperation(_ token: OperationToken) throws {
        guard token.epoch == operationEpoch, activeOperationID == token.id else {
            throw TeamSyncProtocolError.operationCancelled
        }
    }

    private func finishOperation(_ token: OperationToken) {
        if activeOperationID == token.id {
            activeOperationID = nil
        }
    }
}
