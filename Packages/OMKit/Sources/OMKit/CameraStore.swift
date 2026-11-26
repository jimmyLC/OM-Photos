import Foundation
import Security

/// A camera that was paired once by scanning its QR code (or typing its Wi-Fi details).
public struct PairedCamera: Codable, Hashable, Identifiable, Sendable {
    public var id: String { credentials.ssid }
    public var name: String
    public var credentials: CameraCredentials
    public var pairedAt: Date

    public init(name: String, credentials: CameraCredentials, pairedAt: Date = .now) {
        self.name = name
        self.credentials = credentials
        self.pairedAt = pairedAt
    }

    /// "OM-3-P-XXXXXXXX" -> "OM-3"
    public static func defaultName(for ssid: String) -> String {
        if let r = ssid.range(of: "-P-") { return String(ssid[..<r.lowerBound]) }
        return ssid
    }
}

public protocol CameraStoring: Sendable {
    func all() throws -> [PairedCamera]
    func save(_ camera: PairedCamera) throws
    func delete(ssid: String) throws
}

public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public var errorDescription: String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "未知錯誤"
        return "鑰匙圈錯誤 \(status)：\(text)"
    }
}

/// Stores paired cameras in the keychain, synced through iCloud Keychain so a
/// camera paired on the iPhone also works on the Mac and iPad.
/// One generic-password item per camera; the item data is the JSON of `PairedCamera`.
///
/// iCloud sync needs a signed build with the keychain-access-groups entitlement.
/// The free public Mac build is ad-hoc signed and has none, so it falls back to the
/// login keychain on this Mac only (`errSecMissingEntitlement`).
public struct KeychainCameraStore: CameraStoring {
    public static let defaultService = "com.jimmylc.OMDrop.camera"
    let service: String

    public init(service: String = KeychainCameraStore.defaultService) {
        self.service = service
    }

    /// True when this build can use the synced keychain (checked once).
    public static let syncsWithICloud: Bool = {
        // Reads succeed even without the entitlement, so probe with a write.
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: defaultService + ".probe",
            kSecAttrAccount as String: "probe",
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: Data([1]),
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            SecItemDelete(q.filter { $0.key != kSecValueData as String } as CFDictionary)
        }
        return status != errSecMissingEntitlement
    }()

    private var synced: Bool { Self.syncsWithICloud }

    private func base() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if synced { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    public func all() throws -> [PairedCamera] {
        // The login keychain cannot return data for several items at once
        // (errSecParam), so list the accounts first and read each one.
        var q = base()
        if synced { q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let accounts = (out as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        return try accounts.compactMap(read).sorted { $0.pairedAt < $1.pairedAt }
    }

    private func read(_ account: String) throws -> PairedCamera? {
        var q = base()
        if synced { q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
        q[kSecAttrAccount as String] = account
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return try? JSONDecoder().decode(PairedCamera.self, from: data)
    }

    public func save(_ camera: PairedCamera) throws {
        try delete(ssid: camera.credentials.ssid)
        var q = base()
        q[kSecAttrAccount as String] = camera.credentials.ssid
        q[kSecAttrLabel as String] = "OM Photos：\(camera.name)"
        if synced {
            q[kSecAttrSynchronizable as String] = true
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        q[kSecValueData as String] = try JSONEncoder().encode(camera)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(ssid: String) throws {
        var q = base()
        q[kSecAttrAccount as String] = ssid
        if synced { q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For tests and previews.
public final class MemoryCameraStore: CameraStoring, @unchecked Sendable {
    private var items: [String: PairedCamera]
    private let lock = NSLock()

    public init(_ cameras: [PairedCamera] = []) {
        items = Dictionary(uniqueKeysWithValues: cameras.map { ($0.id, $0) })
    }

    public func all() throws -> [PairedCamera] {
        lock.withLock { items.values.sorted { $0.pairedAt < $1.pairedAt } }
    }

    public func save(_ camera: PairedCamera) throws {
        lock.withLock { items[camera.id] = camera }
    }

    public func delete(ssid: String) throws {
        _ = lock.withLock { items.removeValue(forKey: ssid) }
    }
}
