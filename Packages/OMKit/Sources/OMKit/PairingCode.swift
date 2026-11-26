import Foundation

/// Wi-Fi and Bluetooth details shown by the camera ("Device Connection" screen).
public struct CameraCredentials: Codable, Hashable, Sendable {
    public var ssid: String
    public var password: String
    public var bluetoothName: String
    public var bluetoothPasscode: String

    public init(ssid: String, password: String, bluetoothName: String = "", bluetoothPasscode: String = "") {
        self.ssid = ssid
        self.password = password
        self.bluetoothName = bluetoothName
        self.bluetoothPasscode = bluetoothPasscode
    }
}

/// Decoder for the QR code on the camera screen.
///
/// Formats (verified on an OM-3 on 2026-11-26 for OIS3):
///   OIS3,<ver>,<ver>,<ssid>,<password>,<bluetooth name>,<bluetooth passcode>
///   OIS1,<ssid>,<password>
/// Each field is obfuscated by mirroring its position in a 44-character table;
/// characters outside the table are kept as they are.
public enum PairingCode {
    static let table = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ$%*+-/.:")
    static let key = 41

    public static func parse(_ raw: String) -> CameraCredentials? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let credentials: CameraCredentials
        if text.hasPrefix("OIS3,"), parts.count >= 7 {
            credentials = CameraCredentials(ssid: decode(parts[3]), password: decode(parts[4]),
                                            bluetoothName: decode(parts[5]), bluetoothPasscode: decode(parts[6]))
        } else if text.hasPrefix("OIS1,"), parts.count >= 3 {
            credentials = CameraCredentials(ssid: decode(parts[1]), password: decode(parts[2]))
        } else {
            return nil
        }
        return credentials.ssid.isEmpty ? nil : credentials
    }

    static func decode(_ field: String) -> String {
        String(field.map(flip))
    }

    /// The mapping is its own inverse, so encoding uses the same function (tests only).
    static func encode(_ field: String) -> String {
        String(field.map(flip))
    }

    private static func flip(_ c: Character) -> Character {
        guard let i = table.firstIndex(of: c) else { return c }
        let n = table.count
        return table[((key - i) % n + n) % n]
    }
}
