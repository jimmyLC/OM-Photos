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
public struct KeychainCameraStore: CameraStoring {
    public static let defaultService = "com.jimmylc.OMDrop.camera"
    let service: String

    public init(service: String = KeychainCameraStore.defaultService) {
        self.service = service
    }

    private func base() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func all() throws -> [PairedCamera] {
        var q = base()
        q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let items = out as? [Data] ?? []
        return items.compactMap { try? JSONDecoder().decode(PairedCamera.self, from: $0) }
            .sorted { $0.pairedAt < $1.pairedAt }
    }

    public func save(_ camera: PairedCamera) throws {
        try delete(ssid: camera.credentials.ssid)
        var q = base()
        q[kSecAttrAccount as String] = camera.credentials.ssid
        q[kSecAttrLabel as String] = "OM Drop：\(camera.name)"
        q[kSecAttrSynchronizable as String] = true
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        q[kSecValueData as String] = try JSONEncoder().encode(camera)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(ssid: String) throws {
        var q = base()
        q[kSecAttrAccount as String] = ssid
        q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
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
