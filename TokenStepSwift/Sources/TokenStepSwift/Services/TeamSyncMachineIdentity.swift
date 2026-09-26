import CryptoKit
import Foundation
import IOKit

enum TeamSyncMachineIdentity {
    static func fingerprint(uuidText: String) throws -> String {
        guard let uuid = UUID(uuidString: uuidText),
              uuid.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw TeamSyncProtocolError.machineIdentityUnavailable
        }
        let value = "TokenFleet machine identity v1:\nmacos\n" + uuid.uuidString.lowercased()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func current() throws -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { throw TeamSyncProtocolError.machineIdentityUnavailable }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0),
              let text = property.takeRetainedValue() as? String else {
            throw TeamSyncProtocolError.machineIdentityUnavailable
        }
        return try fingerprint(uuidText: text)
    }
}
