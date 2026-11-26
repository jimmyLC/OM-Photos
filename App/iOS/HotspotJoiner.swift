import Foundation
import NetworkExtension
import OMKit

/// The joiner this build uses. Automatic joining needs the Hotspot Configuration
/// entitlement, which a free (Personal Team) developer account cannot sign.
/// Build with the HOTSPOT compilation condition once a paid account is used.
enum PlatformJoiner {
    static func make() -> WiFiJoining {
        #if HOTSPOT
        HotspotJoiner()
        #else
        ManualJoiner()
        #endif
    }
}

/// The user joins the camera Wi-Fi in Settings; the app waits for the camera.
struct ManualJoiner: WiFiJoining {
    func join(_ credentials: CameraCredentials) async throws {
        throw ManualJoinRequired()
    }

    func leave(_ credentials: CameraCredentials) async -> LeaveResult {
        .disconnected
    }
}

/// iOS/iPadOS: join the camera network with NEHotspotConfiguration.
/// Removing the configuration afterwards makes the system go back to the
/// network it used before (or cellular).
struct HotspotJoiner: WiFiJoining {
    func join(_ credentials: CameraCredentials) async throws {
        let config = NEHotspotConfiguration(ssid: credentials.ssid, passphrase: credentials.password, isWEP: false)
        // Not joinOnce: a joinOnce network is dropped soon after the app goes to the
        // background, which would cut a long video download.
        config.joinOnce = false
        do {
            try await NEHotspotConfigurationManager.shared.apply(config)
        } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain {
            switch NEHotspotConfigurationError(rawValue: error.code) {
            case .alreadyAssociated:
                return
            case .userDenied:
                throw JoinError("你取消了加入相機 Wi-Fi。")
            case .invalidWPAPassphrase, .invalidSSID:
                throw JoinError("相機 Wi-Fi 名稱或密碼格式不正確，請重新掃描 QR code。")
            case .pending, .systemConfiguration:
                throw JoinError("系統正在套用其他 Wi-Fi 設定，請稍後再試。")
            default:
                throw JoinError("無法加入相機 Wi-Fi（代碼 \(error.code)）。")
            }
        }
    }

    func leave(_ credentials: CameraCredentials) async -> LeaveResult {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: credentials.ssid)
        // iOS does not let us read the new network name without extra entitlements;
        // it rejoins the previous known network by itself.
        return .restored(nil)
    }
}

struct JoinError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
