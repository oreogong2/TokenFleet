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
    private var operationEpoch: UInt64 = 0
    private var activeOperationID: UUID?

    init(
        httpClient: TeamSyncHTTPClient,
        credentialStore: TeamSyncCredentialStoring,
        stateStore: TeamSyncStateStoring
    ) {
        self.httpClient = httpClient
        self.credentialStore = credentialStore
        self.stateStore = stateStore
    }

    func loadState() -> TeamSyncPersistentState? {
        stateStore.load()
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
        let previousState = stateStore.load()
        let devicePublicID = previousState.flatMap {
            TeamSyncCredentialValidation.canonicalDevicePublicID($0.devicePublicID)
        } ?? UUID().uuidString.lowercased()
        let request = try TeamSyncProtocol.enrollmentURLRequest(
            serverURL: normalizedServerURL,
            enrollmentToken: enrollmentToken,
            devicePublicID: devicePublicID,
            appVersion: appVersion
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
        guard let state = stateStore.load(),
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
            nonce: UUID().uuidString.lowercased()
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

    func synchronize(
        snapshot: UsageSnapshot,
        serverURL rawServerURL: String,
        force: Bool = false,
        now: Date = Date()
    ) async throws -> TeamSyncPersistentState {
        let operation = try beginOperation()
        defer { finishOperation(operation) }
        guard var state = stateStore.load(),
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
                let chunk = Array(pending[chunkStart..<chunkEnd])
                let payload = TeamSyncDailyPayload(
                    schemaVersion: TeamSyncProtocolConfiguration.schemaVersion,
                    collectorVersion: TeamSyncProtocolConfiguration.collectorVersion,
                    generatedAt: generatedAt,
                    buckets: chunk.map(\.bucket)
                )
                let request = try TeamSyncProtocol.dailyUsageURLRequest(
                    serverURL: normalizedServerURL,
                    deviceID: deviceID,
                    deviceSecret: deviceSecret,
                    payload: payload,
                    timestamp: Int(now.timeIntervalSince1970),
                    nonce: UUID().uuidString.lowercased()
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
                guard (200...299).contains(response.statusCode) else {
                    throw TeamSyncProtocolError.httpStatus(response.statusCode)
                }
                guard let ingestResponse = try? JSONDecoder().decode(
                    DailyUsageIngestResponse.self,
                    from: response.data
                ), ingestResponse.isValid(expectedBucketCount: chunk.count) else {
                    throw TeamSyncProtocolError.invalidIngestResponse
                }
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
                        devicePublicID: devicePublicID
                    )
                )
            } else {
                try stateStore.delete()
            }
        } catch {
            throw TeamSyncProtocolError.stateUnavailable
        }
    }

    private func safeProtocolError(_ error: Error) -> TeamSyncProtocolError {
        if let error = error as? TeamSyncProtocolError {
            return error
        }
        return .networkUnavailable
    }

    private func shouldRetry(_ error: TeamSyncProtocolError) -> Bool {
        switch error {
        case .networkUnavailable, .credentialStoreTemporarilyUnavailable:
            return true
        case let .httpStatus(status):
            return status == 408
                || status == 409
                || status == 425
                || status == 429
                || (500...599).contains(status)
        default:
            return false
        }
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
