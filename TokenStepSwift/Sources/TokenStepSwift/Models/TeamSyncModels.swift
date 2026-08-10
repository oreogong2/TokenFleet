import Foundation

enum TeamSyncTerminalReason: String, Codable, Equatable {
    case credentials
    case requestRejected = "request_rejected"
}

struct TeamSyncPersistentState: Codable, Equatable {
    var serverURL: String
    var devicePublicID: String
    var deviceID: String?
    var enrolledAt: Date?
    var lastSyncAt: Date?
    var lastError: String?
    var failureCount: Int
    var nextAttemptAt: Date?
    var automaticRetryStopped: Bool
    var terminalReason: TeamSyncTerminalReason?
    var lastOmittedIncompleteBucketCount: Int
    var lastLedgerVersion: Int?
    var syncedBucketHashes: [String: String]

    enum CodingKeys: String, CodingKey {
        case serverURL = "server_url"
        case devicePublicID = "device_public_id"
        case deviceID = "device_id"
        case enrolledAt = "enrolled_at"
        case lastSyncAt = "last_sync_at"
        case lastError = "last_error"
        case failureCount = "failure_count"
        case nextAttemptAt = "next_attempt_at"
        case automaticRetryStopped = "automatic_retry_stopped"
        case terminalReason = "terminal_reason"
        case lastOmittedIncompleteBucketCount = "last_omitted_incomplete_bucket_count"
        case lastLedgerVersion = "last_ledger_version"
        case syncedBucketHashes = "synced_bucket_hashes"
    }

    init(
        serverURL: String,
        devicePublicID: String = UUID().uuidString.lowercased(),
        deviceID: String? = nil,
        enrolledAt: Date? = nil,
        lastSyncAt: Date? = nil,
        lastError: String? = nil,
        failureCount: Int = 0,
        nextAttemptAt: Date? = nil,
        automaticRetryStopped: Bool = false,
        terminalReason: TeamSyncTerminalReason? = nil,
        lastOmittedIncompleteBucketCount: Int = 0,
        lastLedgerVersion: Int? = nil,
        syncedBucketHashes: [String: String] = [:]
    ) {
        self.serverURL = serverURL
        self.devicePublicID = devicePublicID
        self.deviceID = deviceID
        self.enrolledAt = enrolledAt
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
        self.failureCount = failureCount
        self.nextAttemptAt = nextAttemptAt
        self.automaticRetryStopped = automaticRetryStopped
        self.terminalReason = terminalReason
        self.lastOmittedIncompleteBucketCount = lastOmittedIncompleteBucketCount
        self.lastLedgerVersion = lastLedgerVersion
        self.syncedBucketHashes = syncedBucketHashes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        devicePublicID = try container.decodeIfPresent(String.self, forKey: .devicePublicID)
            ?? UUID().uuidString.lowercased()
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        enrolledAt = try container.decodeIfPresent(Date.self, forKey: .enrolledAt)
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        failureCount = try container.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0
        nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
        automaticRetryStopped = try container.decodeIfPresent(Bool.self, forKey: .automaticRetryStopped) ?? false
        terminalReason = try container.decodeIfPresent(TeamSyncTerminalReason.self, forKey: .terminalReason)
        lastOmittedIncompleteBucketCount = try container.decodeIfPresent(
            Int.self,
            forKey: .lastOmittedIncompleteBucketCount
        ) ?? 0
        lastLedgerVersion = try container.decodeIfPresent(Int.self, forKey: .lastLedgerVersion)
        syncedBucketHashes = try container.decodeIfPresent([String: String].self, forKey: .syncedBucketHashes) ?? [:]
    }

    var isEnrolled: Bool {
        deviceID?.isEmpty == false
    }
}

protocol TeamSyncStateStoring {
    func load() -> TeamSyncPersistentState?
    func save(_ state: TeamSyncPersistentState) throws
    func delete() throws
}

protocol TeamSyncCredentialStoring {
    var isAvailable: Bool { get }
    func saveDeviceSecret(_ secret: String, deviceID: String) throws
    func loadDeviceSecret(deviceID: String) throws -> String?
    func deleteDeviceSecret(deviceID: String) throws
    func saveDeviceSecret(_ secret: String, serverURL: String, deviceID: String) throws
    func loadDeviceSecret(serverURL: String, deviceID: String) throws -> String?
    func clearDeviceSecret(deviceID: String?) throws
}

extension TeamSyncCredentialStoring {
    func saveDeviceSecret(_ secret: String, serverURL: String, deviceID: String) throws {
        try saveDeviceSecret(secret, deviceID: deviceID)
    }

    func loadDeviceSecret(serverURL: String, deviceID: String) throws -> String? {
        try loadDeviceSecret(deviceID: deviceID)
    }

    func clearDeviceSecret(deviceID: String?) throws {
        guard let deviceID else { return }
        try deleteDeviceSecret(deviceID: deviceID)
    }
}

enum TeamSyncCredentialStorageAvailability {
    /// Tests inject an in-memory operator. A real app only enables community
    /// sync when its signed source-build identity and login Keychain are ready.
    #if TOKENSTEP_TESTING
    static let isAvailable = true
    #else
    static var isAvailable: Bool {
        TeamSyncKeychainCredentialStore().isAvailable
    }
    #endif
}

struct DisabledTeamSyncCredentialStore: TeamSyncCredentialStoring {
    var isAvailable: Bool { false }

    func saveDeviceSecret(_ secret: String, deviceID: String) throws {
        throw TeamSyncProtocolError.secureCredentialStorageUnavailable
    }

    func loadDeviceSecret(deviceID: String) throws -> String? {
        throw TeamSyncProtocolError.secureCredentialStorageUnavailable
    }

    func deleteDeviceSecret(deviceID: String) throws {
        throw TeamSyncProtocolError.secureCredentialStorageUnavailable
    }
}

struct FileTeamSyncStateStore: TeamSyncStateStoring {
    var url: URL = AppPaths.teamSyncStateJSON

    func load() -> TeamSyncPersistentState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TeamSyncPersistentState.self, from: data)
    }

    func save(_ state: TeamSyncPersistentState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
