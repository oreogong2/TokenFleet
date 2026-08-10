import Foundation
import Security
@testable import TokenStepSwift

private enum FixtureFailure: Error {
    case assertion(String)
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw FixtureFailure.assertion(message) }
}

private final class FixtureKeychainOperator: TeamSyncKeychainOperating {
    var isSupported = true
    var isUnlocked = true
    var item: Data?
    var updateStatuses: [OSStatus] = []
    var addStatuses: [OSStatus] = []
    private(set) var selectors: [(service: String, account: String)] = []

    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?) {
        selectors.append((service, account))
        guard let item else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, item)
    }

    func addData(_ data: Data, service: String, account: String) -> OSStatus {
        selectors.append((service, account))
        let status = pop(&addStatuses) ?? (item == nil ? errSecSuccess : errSecDuplicateItem)
        if status == errSecSuccess { item = data }
        return status
    }

    func updateData(_ data: Data, service: String, account: String) -> OSStatus {
        selectors.append((service, account))
        let status = pop(&updateStatuses) ?? (item == nil ? errSecItemNotFound : errSecSuccess)
        if status == errSecSuccess { item = data }
        return status
    }

    func deleteData(service: String, account: String) -> OSStatus {
        selectors.append((service, account))
        guard item != nil else { return errSecItemNotFound }
        item = nil
        return errSecSuccess
    }

    private func pop(_ values: inout [OSStatus]) -> OSStatus? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

@main
private struct TeamSyncKeychainFixtureCheck {
    static func main() throws {
        try require(
            TeamSyncCredentialStorageAvailability.isAvailable,
            "production Keychain availability gate is disabled"
        )
        let service = "com.example.TokenFleet.team-sync.file-login.v1"
        let account = "active-credential"
        let origin = "https://community.example.com"
        let deviceID = "server-device-42"
        let initialSecret = "fixture-device-secret-0123456789"
        let rotatedSecret = "rotated-device-secret-0123456789"

        let unsupportedKeychain = FixtureKeychainOperator()
        unsupportedKeychain.isSupported = false
        let unsupportedStore = TeamSyncKeychainCredentialStore(
            service: service,
            account: account,
            keychain: unsupportedKeychain
        )
        do {
            try unsupportedStore.saveDeviceSecret(
                initialSecret,
                serverURL: origin,
                deviceID: deviceID
            )
            throw FixtureFailure.assertion("unsupported credential store accepted a write")
        } catch let error as TeamSyncProtocolError {
            try require(
                error == .secureCredentialStorageUnavailable,
                "unsupported credential store error was not permanent"
            )
        }
        try require(
            unsupportedKeychain.selectors.isEmpty,
            "unsupported credential store performed Keychain IO"
        )

        let lockedKeychain = FixtureKeychainOperator()
        lockedKeychain.isUnlocked = false
        let lockedStore = TeamSyncKeychainCredentialStore(
            service: service,
            account: account,
            keychain: lockedKeychain
        )
        do {
            _ = try lockedStore.loadDeviceSecret(serverURL: origin, deviceID: deviceID)
            throw FixtureFailure.assertion("locked credential store accepted a read")
        } catch let error as TeamSyncProtocolError {
            try require(
                error == .credentialStoreTemporarilyUnavailable,
                "locked credential store error was not retryable"
            )
        }
        try require(
            lockedKeychain.selectors.isEmpty,
            "locked credential store performed Keychain IO"
        )

        let keychain = FixtureKeychainOperator()
        let store = TeamSyncKeychainCredentialStore(
            service: service,
            account: account,
            keychain: keychain
        )

        try store.saveDeviceSecret(initialSecret, serverURL: origin, deviceID: deviceID)
        try require(keychain.item != nil, "first save did not add one Keychain envelope")
        try require(
            try store.loadDeviceSecret(serverURL: origin, deviceID: deviceID) == initialSecret,
            "saved Keychain envelope did not round-trip"
        )

        try store.saveDeviceSecret(rotatedSecret, serverURL: origin, deviceID: deviceID)
        try require(
            try store.loadDeviceSecret(serverURL: origin, deviceID: deviceID) == rotatedSecret,
            "rotation did not replace the active Keychain value"
        )
        do {
            _ = try store.loadDeviceSecret(
                serverURL: "https://other.example.com",
                deviceID: deviceID
            )
            throw FixtureFailure.assertion("wrong-origin binding was accepted")
        } catch let error as TeamSyncProtocolError {
            try require(error == .credentialsUnavailable, "wrong-origin error was not fail-closed")
        }

        try store.clearDeviceSecret(deviceID: deviceID)
        try store.clearDeviceSecret(deviceID: nil)
        try require(keychain.item == nil, "clear retained the active Keychain item")
        try require(
            keychain.selectors.allSatisfy { $0.service == service && $0.account == account },
            "a Keychain operation escaped the fixed service/account selector"
        )

        let raceOperator = FixtureKeychainOperator()
        raceOperator.updateStatuses = [errSecItemNotFound, errSecSuccess]
        raceOperator.addStatuses = [errSecDuplicateItem]
        let raceStore = TeamSyncKeychainCredentialStore(
            service: service,
            account: account,
            keychain: raceOperator
        )
        try raceStore.saveDeviceSecret(initialSecret, serverURL: origin, deviceID: deviceID)
        try require(raceOperator.item != nil, "duplicate add race did not converge to one value")

        print("TokenFleet Keychain fixture passed")
    }
}
