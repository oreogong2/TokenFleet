import Foundation
import LocalAuthentication
import Security

enum TeamSyncCredentialBackend: String, Codable, Equatable {
    case fileLoginV1 = "file-login-v1"
}

protocol TeamSyncKeychainOperating {
    var isSupported: Bool { get }
    var isUnlocked: Bool { get }
    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?)
    func addData(_ data: Data, service: String, account: String) -> OSStatus
    func updateData(_ data: Data, service: String, account: String) -> OSStatus
    func deleteData(service: String, account: String) -> OSStatus
}

extension TeamSyncKeychainOperating {
    var isSupported: Bool { true }
    var isUnlocked: Bool { true }
}

struct TeamSyncSourceBuildSignatureAssessment {
    static let backendInfoKey = "TokenFleetCredentialBackend"

    static func accepts(
        backend: String?,
        signingIdentifier: String?,
        bundleIdentifier: String?,
        signatureFlags: UInt32,
        certificateCount: Int,
        hasDesignatedRequirement: Bool
    ) -> Bool {
        guard backend == TeamSyncCredentialBackend.fileLoginV1.rawValue,
              let bundleIdentifier,
              !bundleIdentifier.isEmpty,
              signingIdentifier == bundleIdentifier,
              certificateCount > 0,
              hasDesignatedRequirement
        else {
            return false
        }
        // CSCommon.h constants are not imported into Swift by every SDK.
        let disallowed: UInt32 = 0x0002 | 0x0002_0000
        return signatureFlags & disallowed == 0
    }
}

private struct TeamSyncSourceBuildSignatureValidator {
    func isEligible(bundle: Bundle = .main) -> Bool {
        guard let configuredBackend = bundle.object(
            forInfoDictionaryKey: TeamSyncSourceBuildSignatureAssessment.backendInfoKey
        ) as? String,
              let bundleIdentifier = bundle.bundleIdentifier
        else {
            return false
        }

        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess
        else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return false
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let information = signingInformation as? [String: Any]
        else {
            return false
        }

        let signingIdentifier = information[kSecCodeInfoIdentifier as String] as? String
        let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = information[kSecCodeInfoCertificates as String] as? [Any] ?? []
        var designatedRequirement: SecRequirement?
        let hasDesignatedRequirement = SecCodeCopyDesignatedRequirement(
            staticCode,
            [],
            &designatedRequirement
        ) == errSecSuccess && designatedRequirement != nil

        return TeamSyncSourceBuildSignatureAssessment.accepts(
            backend: configuredBackend,
            signingIdentifier: signingIdentifier,
            bundleIdentifier: bundleIdentifier,
            signatureFlags: flags,
            certificateCount: certificates.count,
            hasDesignatedRequirement: hasDesignatedRequirement
        )
    }
}

final class SystemTeamSyncKeychainOperator: TeamSyncKeychainOperating {
    private let keychain: SecKeychain?
    private let signatureIsEligible: Bool

    init() {
        var defaultKeychain: SecKeychain?
        let status = SecKeychainCopyDefault(&defaultKeychain)
        keychain = status == errSecSuccess ? defaultKeychain : nil
        signatureIsEligible = TeamSyncSourceBuildSignatureValidator().isEligible()
    }

    var isSupported: Bool {
        signatureIsEligible && keychain != nil
    }

    var isUnlocked: Bool {
        guard isSupported, let keychain else { return false }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
        let required = SecKeychainStatus(
            kSecUnlockStateStatus | kSecReadPermStatus | kSecWritePermStatus
        )
        return status & required == required
    }

    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?) {
        guard isSupported, let keychain else { return (errSecMissingEntitlement, nil) }
        guard isUnlocked else { return (errSecInteractionNotAllowed, nil) }
        var query = Self.matchQuery(service: service, account: account, keychain: keychain)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func addData(_ data: Data, service: String, account: String) -> OSStatus {
        guard isSupported, let keychain else { return errSecMissingEntitlement }
        guard isUnlocked else { return errSecInteractionNotAllowed }
        let attributes = Self.addQuery(
            data: data,
            service: service,
            account: account,
            keychain: keychain
        )
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func updateData(_ data: Data, service: String, account: String) -> OSStatus {
        guard isSupported, let keychain else { return errSecMissingEntitlement }
        guard isUnlocked else { return errSecInteractionNotAllowed }
        let query = Self.matchQuery(service: service, account: account, keychain: keychain)
        return SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
    }

    func deleteData(service: String, account: String) -> OSStatus {
        guard isSupported, let keychain else { return errSecMissingEntitlement }
        guard isUnlocked else { return errSecInteractionNotAllowed }
        let query = Self.matchQuery(service: service, account: account, keychain: keychain)
        return SecItemDelete(query as CFDictionary)
    }

    static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func addQuery(
        data: Data,
        service: String,
        account: String,
        keychain: Any
    ) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecUseKeychain as String] = keychain
        addNoInteraction(to: &query)
        return query
    }

    static func matchQuery(
        service: String,
        account: String,
        keychain: Any
    ) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecMatchSearchList as String] = [keychain]
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        addNoInteraction(to: &query)
        return query
    }

    private static func addNoInteraction(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        // File-based Keychain has legacy ACL prompts. Keep the explicit fail
        // flag as a second guard so a background sync can never show a dialog.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }
}

enum TeamSyncCredentialValidation {
    static func canonicalServerOrigin(_ rawValue: String) -> String? {
        guard let url = try? TeamSyncProtocol.normalizedServerURL(rawValue),
              url.absoluteString == rawValue
        else {
            return nil
        }
        return rawValue
    }

    static func boundedDeviceID(_ rawValue: String) -> String? {
        guard (1...128).contains(rawValue.utf8.count),
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "-"
                          || scalar == "_"
                  )
              })
        else {
            return nil
        }
        return rawValue
    }

    static func canonicalDevicePublicID(_ rawValue: String) -> String? {
        guard let uuid = UUID(uuidString: rawValue),
              uuid.uuidString.lowercased() == rawValue
        else {
            return nil
        }
        return rawValue
    }

    static func boundedDeviceSecret(_ rawValue: String) -> String? {
        guard (16...256).contains(rawValue.utf8.count),
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "-"
                          || scalar == "_"
                  )
              })
        else {
            return nil
        }
        return rawValue
    }
}

private struct TeamSyncKeychainEnvelope: Codable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var credentialBackend: TeamSyncCredentialBackend
    var serverOrigin: String
    var deviceID: String
    var deviceSecret: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case credentialBackend = "credential_backend"
        case serverOrigin = "server_origin"
        case deviceID = "device_id"
        case deviceSecret = "device_secret"
    }

    static func make(serverOrigin: String, deviceID: String, deviceSecret: String) throws -> Self {
        guard let origin = TeamSyncCredentialValidation.canonicalServerOrigin(serverOrigin),
              let identifier = TeamSyncCredentialValidation.boundedDeviceID(deviceID),
              let secret = TeamSyncCredentialValidation.boundedDeviceSecret(deviceSecret)
        else {
            throw TeamSyncProtocolError.invalidEnrollmentResponse
        }
        return Self(
            schemaVersion: currentSchemaVersion,
            credentialBackend: .fileLoginV1,
            serverOrigin: origin,
            deviceID: identifier,
            deviceSecret: secret
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decodeStrictly(_ data: Data) throws -> Self {
        let expectedKeys = Set([
            "schema_version",
            "credential_backend",
            "server_origin",
            "device_id",
            "device_secret",
        ])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == expectedKeys,
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.schemaVersion == currentSchemaVersion,
              decoded.credentialBackend == .fileLoginV1,
              TeamSyncCredentialValidation.canonicalServerOrigin(decoded.serverOrigin) != nil,
              TeamSyncCredentialValidation.boundedDeviceID(decoded.deviceID) != nil,
              TeamSyncCredentialValidation.boundedDeviceSecret(decoded.deviceSecret) != nil
        else {
            throw TeamSyncProtocolError.credentialsUnavailable
        }
        return decoded
    }
}

struct TeamSyncKeychainCredentialStore: TeamSyncCredentialStoring {
    static let account = "active-credential"
    static let fallbackBundleIdentifier = "com.lingdong.TokenFleet"
    static let serviceSuffix = "team-sync.file-login.v1"

    let service: String
    let account: String
    private let keychain: any TeamSyncKeychainOperating

    init(
        service: String = TeamSyncKeychainCredentialStore.productionServiceName(),
        account: String = TeamSyncKeychainCredentialStore.account,
        keychain: any TeamSyncKeychainOperating = SystemTeamSyncKeychainOperator()
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    var isAvailable: Bool { keychain.isSupported }

    static func productionServiceName(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        let candidate = bundleIdentifier ?? fallbackBundleIdentifier
        let isSafe = !candidate.isEmpty
            && candidate.utf8.count <= 200
            && candidate.unicodeScalars.allSatisfy({ scalar in
                scalar.isASCII && (
                    CharacterSet.alphanumerics.contains(scalar)
                        || scalar == "."
                        || scalar == "-"
                )
            })
        let identifier = isSafe ? candidate : fallbackBundleIdentifier
        return "\(identifier).\(serviceSuffix)"
    }

    func saveDeviceSecret(_ secret: String, deviceID: String) throws {
        throw TeamSyncProtocolError.secureCredentialStorageUnavailable
    }

    func loadDeviceSecret(deviceID: String) throws -> String? {
        throw TeamSyncProtocolError.secureCredentialStorageUnavailable
    }

    func deleteDeviceSecret(deviceID: String) throws {
        try clearDeviceSecret(deviceID: deviceID)
    }

    func saveDeviceSecret(_ secret: String, serverURL: String, deviceID: String) throws {
        try requireAvailable()
        let envelope = try TeamSyncKeychainEnvelope.make(
            serverOrigin: serverURL,
            deviceID: deviceID,
            deviceSecret: secret
        )
        let data: Data
        do {
            data = try envelope.encoded()
        } catch {
            throw TeamSyncProtocolError.credentialsUnavailable
        }

        let updateStatus = keychain.updateData(data, service: service, account: account)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw mappedError(updateStatus)
        }

        let addStatus = keychain.addData(data, service: service, account: account)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let retryStatus = keychain.updateData(data, service: service, account: account)
            guard retryStatus == errSecSuccess else { throw mappedError(retryStatus) }
            return
        }
        throw mappedError(addStatus)
    }

    func loadDeviceSecret(serverURL: String, deviceID: String) throws -> String? {
        try requireAvailable()
        guard let origin = TeamSyncCredentialValidation.canonicalServerOrigin(serverURL),
              let identifier = TeamSyncCredentialValidation.boundedDeviceID(deviceID)
        else {
            throw TeamSyncProtocolError.credentialsUnavailable
        }
        let result = keychain.copyData(service: service, account: account)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess, let data = result.data else {
            throw mappedError(result.status)
        }
        let envelope = try TeamSyncKeychainEnvelope.decodeStrictly(data)
        guard envelope.serverOrigin == origin, envelope.deviceID == identifier else {
            throw TeamSyncProtocolError.credentialsUnavailable
        }
        return envelope.deviceSecret
    }

    func clearDeviceSecret(deviceID: String?) throws {
        try requireAvailable()
        let status = keychain.deleteData(service: service, account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mappedError(status)
        }
    }

    private func requireAvailable() throws {
        guard keychain.isSupported else {
            throw TeamSyncProtocolError.secureCredentialStorageUnavailable
        }
        guard keychain.isUnlocked else {
            throw TeamSyncProtocolError.credentialStoreTemporarilyUnavailable
        }
    }

    private func mappedError(_ status: OSStatus) -> TeamSyncProtocolError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed:
            return .credentialStoreTemporarilyUnavailable
        case errSecMissingEntitlement:
            return .secureCredentialStorageUnavailable
        default:
            return .credentialsUnavailable
        }
    }
}
