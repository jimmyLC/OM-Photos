import CoreLocation
@preconcurrency import CoreWLAN
import Foundation
import OMKit

/// macOS: join the camera network with CoreWLAN, then go back to the previous network.
/// macOS hides Wi-Fi names unless the app has Location Services permission, so
/// that permission is requested the first time.
final class CoreWLANJoiner: WiFiJoining, @unchecked Sendable {
    private let lock = NSLock()
    private var previousSSID: String?
    private let location = LocationPermission()

    private var interface: CWInterface? { CWWiFiClient.shared().interface() }

    func join(_ credentials: CameraCredentials) async throws {
        guard await location.ensureAuthorized() else {
            throw JoinError("macOS 需要「定位服務」權限才能切換 Wi-Fi。請到 系統設定 › 隱私權與安全性 › 定位服務，允許 OM Drop。")
        }
        guard let wifi = interface else { throw JoinError("這台 Mac 沒有 Wi-Fi。") }
        guard wifi.powerOn() else { throw JoinError("Wi-Fi 已關閉，請先開啟。") }
        let current = wifi.ssid()
        if current == credentials.ssid { return }
        lock.withLock { previousSSID = current }

        try await Task.detached {
            // The camera may take a moment to start broadcasting.
            var network: CWNetwork?
            for attempt in 0..<3 where network == nil {
                network = try? wifi.scanForNetworks(withName: credentials.ssid).first
                if network == nil, attempt < 2 { try await Task.sleep(for: .seconds(2)) }
            }
            guard let network else {
                throw JoinError("找不到相機 Wi-Fi「\(credentials.ssid)」。請確認相機正顯示連線畫面。")
            }
            do {
                try wifi.associate(to: network, password: credentials.password)
            } catch {
                throw JoinError("無法加入相機 Wi-Fi：\(error.localizedDescription)")
            }
        }.value
    }

    func leave(_ credentials: CameraCredentials) async -> LeaveResult {
        guard let wifi = interface else { return .failed("找不到 Wi-Fi") }
        let previous = lock.withLock { previousSSID }
        if wifi.ssid() == credentials.ssid { wifi.disassociate() }

        // Give macOS a chance to rejoin a preferred network by itself.
        if let joined = await waitForNetwork(on: wifi, notNamed: credentials.ssid, seconds: 10) {
            return .restored(joined)
        }
        if let previous {
            let ok = await Task.detached { () -> Bool in
                guard let n = try? wifi.scanForNetworks(withName: previous).first else { return false }
                // Known networks: macOS supplies the saved password from the system keychain.
                return (try? wifi.associate(to: n, password: nil)) != nil
            }.value
            if ok, let joined = await waitForNetwork(on: wifi, notNamed: credentials.ssid, seconds: 8) {
                return .restored(joined)
            }
        }
        return .disconnected
    }

    private func waitForNetwork(on wifi: CWInterface, notNamed camera: String, seconds: Int) async -> String? {
        for _ in 0..<(seconds * 2) {
            if let name = wifi.ssid(), name != camera { return name }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }
}

/// Asks for Location Services once (needed to read Wi-Fi names on macOS).
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private var created: CLLocationManager?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    nonisolated override init() {
        super.init()
    }

    func ensureAuthorized() async -> Bool {
        let manager = created ?? CLLocationManager()
        created = manager
        manager.delegate = self
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized: return true
        case .denied, .restricted: return false
        default: break
        }
        return await withCheckedContinuation { c in
            waiters.append(c)
            if waiters.count == 1 { manager.requestWhenInUseAuthorization() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined else { return }
            let ok = status == .authorizedAlways || status == .authorized
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume(returning: ok) }
        }
    }
}

struct JoinError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
