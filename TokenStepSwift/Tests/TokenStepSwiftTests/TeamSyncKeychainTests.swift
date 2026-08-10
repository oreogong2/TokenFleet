import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import TokenStepSwift

final class TeamSyncKeychainTests: XCTestCase {
    private let origin = "https://community.example.com"
    private let deviceID = "server-device-42"
    private let deviceSecret = "fixture-device-secret-0123456789"

    func testProductionSelectorAndBaseQueryStayAppScopedAndLocalOnly() {
        XCTAssertEqual(
            TeamSyncKeychainCredentialStore.productionServiceName(
                bundleIdentifier: "com.example.TokenFleet"
            ),
            "com.example.TokenFleet.team-sync.file-login.v1"
        )
        XCTAssertEqual(
            TeamSyncKeychainCredentialStore.productionServiceName(
                bundleIdentifier: "bad identifier/with spaces"
            ),
            "com.lingdong.TokenFleet.team-sync.file-login.v1"
        )
        XCTAssertEqual(TeamSyncKeychainCredentialStore.account, "active-credential")

        let query = SystemTeamSyncKeychainOperator.baseQuery(
            service: "com.example.TokenFleet.team-sync.file-login.v1",
            account: "active-credential"
        )
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(
            query[kSecAttrService as String] as? String,
            "com.example.TokenFleet.team-sync.file-login.v1"
        )
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "active-credential")
        XCTAssertNil(query[kSecAttrSynchronizable as String])
        XCTAssertNil(query[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(query[kSecAttrAccessGroup as String])

        let sentinelKeychain = NSObject()
        let add = SystemTeamSyncKeychainOperator.addQuery(
            data: Data("sentinel".utf8),
            service: "com.example.TokenFleet.team-sync.file-login.v1",
            account: "active-credential",
            keychain: sentinelKeychain
        )
        XCTAssertTrue(add[kSecUseKeychain as String] as AnyObject === sentinelKeychain)
        XCTAssertNil(add[kSecMatchSearchList as String])
        XCTAssertNotNil(add[kSecUseAuthenticationContext as String] as? LAContext)

        let match = SystemTeamSyncKeychainOperator.matchQuery(
            service: "com.example.TokenFleet.team-sync.file-login.v1",
            account: "active-credential",
            keychain: sentinelKeychain
        )
        XCTAssertNil(match[kSecUseKeychain as String])
        XCTAssertEqual((match[kSecMatchSearchList as String] as? [NSObject])?.count, 1)
        XCTAssertEqual(match[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertNotNil(match[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertNil(match[kSecAttrAccessible as String])
    }

    func testFirstSaveAddsOneEnvelopeAndExactBindingLoadsIt() throws {
        let keychain = FakeTeamSyncKeychainOperator()
        let store = makeStore(keychain)

        try store.saveDeviceSecret(deviceSecret, serverURL: origin, deviceID: deviceID)

        XCTAssertEqual(keychain.updateCallCount, 1)
        XCTAssertEqual(keychain.addCallCount, 1)
        XCTAssertEqual(keychain.itemCount, 1)
        XCTAssertEqual(
            try store.loadDeviceSecret(serverURL: origin, deviceID: deviceID),
            deviceSecret
        )
        XCTAssertEqual(keychain.lastService, "com.example.TokenFleet.team-sync.file-login.v1")
        XCTAssertEqual(keychain.lastAccount, "active-credential")
    }

    func testRotationUpdatesSingleItemAndDuplicateAddRaceRetriesOnce() throws {
        let keychain = FakeTeamSyncKeychainOperator()
        let store = makeStore(keychain)
        try store.saveDeviceSecret(deviceSecret, serverURL: origin, deviceID: deviceID)

        let rotated = "rotated-device-secret-0123456789"
        try store.saveDeviceSecret(rotated, serverURL: origin, deviceID: deviceID)
        XCTAssertEqual(keychain.itemCount, 1)
        XCTAssertEqual(try store.loadDeviceSecret(serverURL: origin, deviceID: deviceID), rotated)

        let raceKeychain = FakeTeamSyncKeychainOperator()
        raceKeychain.updateStatuses = [errSecItemNotFound, errSecSuccess]
        raceKeychain.addStatuses = [errSecDuplicateItem]
        let raceStore = makeStore(raceKeychain)
        try raceStore.saveDeviceSecret(deviceSecret, serverURL: origin, deviceID: deviceID)
        XCTAssertEqual(raceKeychain.updateCallCount, 2)
        XCTAssertEqual(raceKeychain.addCallCount, 1)
        XCTAssertEqual(raceKeychain.itemCount, 1)
    }

    func testWrongBindingAndCorruptEnvelopeFailClosed() throws {
        let keychain = FakeTeamSyncKeychainOperator()
        let store = makeStore(keychain)
        try store.saveDeviceSecret(deviceSecret, serverURL: origin, deviceID: deviceID)

        XCTAssertThrowsError(
            try store.loadDeviceSecret(
                serverURL: "https://other.example.com",
                deviceID: deviceID
            )
        ) { error in
            XCTAssertEqual(error as? TeamSyncProtocolError, .credentialsUnavailable)
        }
        XCTAssertThrowsError(
            try store.loadDeviceSecret(serverURL: origin, deviceID: "other-device")
        ) { error in
            XCTAssertEqual(error as? TeamSyncProtocolError, .credentialsUnavailable)
        }

        keychain.item = Data(#"{"schema_version":99,"device_secret":"sentinel"}"#.utf8)
        XCTAssertThrowsError(
            try store.loadDeviceSecret(serverURL: origin, deviceID: deviceID)
        ) { error in
            XCTAssertEqual(error as? TeamSyncProtocolError, .credentialsUnavailable)
        }
    }

    func testStatusMappingAndIdempotentClear() throws {
        let lockedKeychain = FakeTeamSyncKeychainOperator()
        lockedKeychain.copyStatus = errSecInteractionNotAllowed
        let lockedStore = makeStore(lockedKeychain)
        XCTAssertThrowsError(
            try lockedStore.loadDeviceSecret(serverURL: origin, deviceID: deviceID)
        ) { error in
            XCTAssertEqual(error as? TeamSyncProtocolError, .credentialStoreTemporarilyUnavailable)
        }

        let unavailableKeychain = FakeTeamSyncKeychainOperator()
        unavailableKeychain.updateStatuses = [errSecMissingEntitlement]
        let unavailableStore = makeStore(unavailableKeychain)
        XCTAssertThrowsError(
            try unavailableStore.saveDeviceSecret(
                deviceSecret,
                serverURL: origin,
                deviceID: deviceID
            )
        ) { error in
            XCTAssertEqual(error as? TeamSyncProtocolError, .secureCredentialStorageUnavailable)
        }

        let emptyKeychain = FakeTeamSyncKeychainOperator()
        let emptyStore = makeStore(emptyKeychain)
        XCTAssertNoThrow(try emptyStore.clearDeviceSecret(deviceID: nil))
        XCTAssertNoThrow(try emptyStore.clearDeviceSecret(deviceID: deviceID))
        XCTAssertEqual(emptyKeychain.itemCount, 0)
    }

    func testUnsupportedIsPermanentButLockedIsRetryableWithoutKeychainIO() {
        let unsupportedKeychain = FakeTeamSyncKeychainOperator()
        unsupportedKeychain.isSupported = false
        let unsupportedStore = makeStore(unsupportedKeychain)
        XCTAssertFalse(unsupportedStore.isAvailable)
        XCTAssertThrowsError(
            try unsupportedStore.saveDeviceSecret(
                deviceSecret,
                serverURL: origin,
                deviceID: deviceID
            )
        ) { error in
            XCTAssertEqual(
                error as? TeamSyncProtocolError,
                .secureCredentialStorageUnavailable
            )
        }
        XCTAssertEqual(unsupportedKeychain.operationCallCount, 0)

        let lockedKeychain = FakeTeamSyncKeychainOperator()
        lockedKeychain.isUnlocked = false
        let lockedStore = makeStore(lockedKeychain)
        XCTAssertTrue(lockedStore.isAvailable)
        XCTAssertThrowsError(
            try lockedStore.loadDeviceSecret(serverURL: origin, deviceID: deviceID)
        ) { error in
            XCTAssertEqual(
                error as? TeamSyncProtocolError,
                .credentialStoreTemporarilyUnavailable
            )
        }
        XCTAssertEqual(lockedKeychain.operationCallCount, 0)
    }

    func testHostileValuesAndLegacySelectorsAreRejectedBeforeKeychainWrite() {
        let keychain = FakeTeamSyncKeychainOperator()
        let store = makeStore(keychain)
        let invalidValues: [(String, String, String)] = [
            ("http://community.example.com", deviceID, deviceSecret),
            (origin, "bad/device", deviceSecret),
            (origin, deviceID, "short"),
            (origin, deviceID, "secret-with-newline\n0123456789"),
        ]
        for value in invalidValues {
            XCTAssertThrowsError(
                try store.saveDeviceSecret(value.2, serverURL: value.0, deviceID: value.1)
            ) { error in
                XCTAssertEqual(error as? TeamSyncProtocolError, .invalidEnrollmentResponse)
            }
        }
        XCTAssertEqual(keychain.updateCallCount, 0)
        XCTAssertEqual(keychain.addCallCount, 0)

        XCTAssertThrowsError(try store.saveDeviceSecret(deviceSecret, deviceID: deviceID))
        XCTAssertThrowsError(try store.loadDeviceSecret(deviceID: deviceID))
    }

    private func makeStore(
        _ keychain: FakeTeamSyncKeychainOperator
    ) -> TeamSyncKeychainCredentialStore {
        TeamSyncKeychainCredentialStore(
            service: "com.example.TokenFleet.team-sync.file-login.v1",
            account: "active-credential",
            keychain: keychain
        )
    }

    func testSourceBuildSignatureAssessmentRejectsAdHocAndWrongBackend() {
        let valid = TeamSyncSourceBuildSignatureAssessment.accepts(
            backend: "file-login-v1",
            signingIdentifier: "com.example.TokenFleet",
            bundleIdentifier: "com.example.TokenFleet",
            signatureFlags: 0,
            certificateCount: 1,
            hasDesignatedRequirement: true
        )
        XCTAssertTrue(valid)
        XCTAssertFalse(TeamSyncSourceBuildSignatureAssessment.accepts(
            backend: "disabled",
            signingIdentifier: "com.example.TokenFleet",
            bundleIdentifier: "com.example.TokenFleet",
            signatureFlags: 0,
            certificateCount: 1,
            hasDesignatedRequirement: true
        ))
        XCTAssertFalse(TeamSyncSourceBuildSignatureAssessment.accepts(
            backend: "file-login-v1",
            signingIdentifier: "com.example.TokenFleet",
            bundleIdentifier: "com.example.TokenFleet",
            signatureFlags: 0x0002,
            certificateCount: 1,
            hasDesignatedRequirement: true
        ))
        XCTAssertFalse(TeamSyncSourceBuildSignatureAssessment.accepts(
            backend: "file-login-v1",
            signingIdentifier: "com.example.TokenFleet",
            bundleIdentifier: "com.example.TokenFleet",
            signatureFlags: 0x0002_0000,
            certificateCount: 1,
            hasDesignatedRequirement: true
        ))
    }
}

private final class FakeTeamSyncKeychainOperator: TeamSyncKeychainOperating {
    var isSupported = true
    var isUnlocked = true
    var item: Data?
    var copyStatus: OSStatus?
    var updateStatuses: [OSStatus] = []
    var addStatuses: [OSStatus] = []
    var deleteStatuses: [OSStatus] = []
    private(set) var updateCallCount = 0
    private(set) var addCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var copyCallCount = 0
    private(set) var lastService: String?
    private(set) var lastAccount: String?

    var itemCount: Int { item == nil ? 0 : 1 }
    var operationCallCount: Int {
        copyCallCount + updateCallCount + addCallCount + deleteCallCount
    }

    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?) {
        copyCallCount += 1
        record(service: service, account: account)
        if let copyStatus { return (copyStatus, copyStatus == errSecSuccess ? item : nil) }
        guard let item else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, item)
    }

    func addData(_ data: Data, service: String, account: String) -> OSStatus {
        addCallCount += 1
        record(service: service, account: account)
        let status = pop(&addStatuses) ?? (item == nil ? errSecSuccess : errSecDuplicateItem)
        if status == errSecSuccess { item = data }
        return status
    }

    func updateData(_ data: Data, service: String, account: String) -> OSStatus {
        updateCallCount += 1
        record(service: service, account: account)
        let status = pop(&updateStatuses) ?? (item == nil ? errSecItemNotFound : errSecSuccess)
        if status == errSecSuccess { item = data }
        return status
    }

    func deleteData(service: String, account: String) -> OSStatus {
        deleteCallCount += 1
        record(service: service, account: account)
        let status = pop(&deleteStatuses) ?? (item == nil ? errSecItemNotFound : errSecSuccess)
        if status == errSecSuccess { item = nil }
        return status
    }

    private func record(service: String, account: String) {
        lastService = service
        lastAccount = account
    }

    private func pop(_ values: inout [OSStatus]) -> OSStatus? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}
