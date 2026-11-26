import Foundation
import Observation

/// Joins and leaves the camera's Wi-Fi. One implementation per platform
/// (NetworkExtension on iOS/iPadOS, CoreWLAN on macOS).
public protocol WiFiJoining: Sendable {
    /// Join the camera network. Returns when the system accepted the request;
    /// the caller still checks that the camera answers.
    func join(_ credentials: CameraCredentials) async throws
    /// Leave the camera network and go back to the network used before.
    func leave(_ credentials: CameraCredentials) async -> LeaveResult
    /// True when the user has to switch networks in Settings.
    var isManual: Bool { get }
}

public extension WiFiJoining {
    var isManual: Bool { false }
}

/// Thrown by a joiner that cannot switch networks itself (iOS without the Hotspot
/// entitlement): the user joins in Settings while the app keeps looking for the camera.
public struct ManualJoinRequired: Error, Equatable {
    public init() {}
}

public enum LeaveResult: Equatable, Sendable {
    /// Back on a normal network (its name when the system lets us read it).
    case restored(String?)
    /// Left the camera, but no other network was joined yet.
    case disconnected
    case failed(String)
}

public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting(String)
    case joiningWiFi(String)
    /// Waiting for the user to join the camera Wi-Fi in Settings.
    case waitingForUser(CameraCredentials)
    case connected(CameraInfo)
    case leaving
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .connecting, .joiningWiFi, .waitingForUser, .leaving: true
        default: false
        }
    }
}

/// Pairing list plus the connect / disconnect flow. Shared by every platform.
@MainActor @Observable
public final class ConnectionManager {
    public private(set) var cameras: [PairedCamera] = []
    public private(set) var state: ConnectionState = .idle
    public private(set) var current: PairedCamera?
    /// Last message about the network after disconnecting (shown briefly).
    public private(set) var notice: String?
    /// True when this app switched the Wi-Fi, so it must also switch it back.
    public private(set) var joinedByApp = false
    /// True when the user switched to the camera Wi-Fi by hand, so they must switch back by hand.
    public private(set) var joinedByUser = false
    public private(set) var storeError: String?
    /// After a manual join (iPhone without the Hotspot entitlement), turn the camera
    /// off when disconnecting so the phone returns to its previous Wi-Fi.
    public var powerOffWhenDone = true

    public let client: CameraClient
    private let store: CameraStoring
    private let joiner: WiFiJoining
    private let joinTimeout: Duration
    private let manualTimeout: Duration
    private let pollInterval: Duration
    private var attempt = 0

    public init(store: CameraStoring, joiner: WiFiJoining, client: CameraClient = CameraClient(),
                joinTimeout: Duration = .seconds(25), manualTimeout: Duration = .seconds(180),
                pollInterval: Duration = .seconds(1)) {
        self.store = store
        self.joiner = joiner
        self.client = client
        self.joinTimeout = joinTimeout
        self.manualTimeout = manualTimeout
        self.pollInterval = pollInterval
        reload()
    }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: Pairing

    public func reload() {
        do {
            cameras = try store.all()
            storeError = nil
        } catch {
            storeError = error.localizedDescription
        }
    }

    @discardableResult
    public func pair(_ credentials: CameraCredentials, name: String? = nil) throws -> PairedCamera {
        let existing = cameras.first { $0.id == credentials.ssid }
        let camera = PairedCamera(name: name ?? existing?.name ?? PairedCamera.defaultName(for: credentials.ssid),
                                  credentials: credentials)
        try store.save(camera)
        reload()
        return camera
    }

    public func rename(_ camera: PairedCamera, to name: String) throws {
        var c = camera
        c.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? camera.name : name
        try store.save(c)
        reload()
        if current?.id == c.id { current = c }
    }

    public func forget(_ camera: PairedCamera) async throws {
        if current?.id == camera.id { await disconnect() }
        try store.delete(ssid: camera.id)
        reload()
    }

    // MARK: Connection

    /// Connect to `camera` (or the first paired camera). Uses the current network
    /// when the camera already answers there; otherwise joins its Wi-Fi.
    public func connect(_ camera: PairedCamera? = nil) async {
        guard !state.isBusy, let camera = camera ?? current ?? cameras.first else { return }
        if isConnected, current?.id == camera.id { return }
        if isConnected { await disconnect() }
        attempt += 1
        let mine = attempt
        current = camera
        notice = nil
        state = .connecting(camera.name)

        joinedByApp = false
        joinedByUser = false
        if let info = await probe(timeout: 2) {
            state = .connected(info)
            return
        }

        state = .joiningWiFi(camera.credentials.ssid)
        do {
            try await joiner.join(camera.credentials)
        } catch is ManualJoinRequired {
            guard mine == attempt else { return }
            state = .waitingForUser(camera.credentials)
            if let info = await waitForCamera(attempt: mine, timeout: manualTimeout) {
                joinedByUser = true
                state = .connected(info)
            } else if mine == attempt {
                state = .failed("等不到相機。請到 設定 › Wi-Fi 選擇「\(camera.credentials.ssid)」，再回到 OM Transfer。")
            }
            return
        } catch {
            guard mine == attempt else { return }
            state = .failed(Self.describe(error))
            return
        }
        joinedByApp = true
        if let info = await waitForCamera(attempt: mine, timeout: joinTimeout) {
            state = .connected(info)
            return
        }
        guard mine == attempt else { return }
        let result = await joiner.leave(camera.credentials)
        joinedByApp = false
        state = .failed("已嘗試加入「\(camera.credentials.ssid)」，但相機沒有回應。請確認相機正顯示連線畫面。"
                        + (result == .disconnected ? "\n目前沒有連上任何 Wi-Fi。" : ""))
    }

    /// Stop using the camera and, if this app switched the Wi-Fi, switch back.
    public func disconnect() async {
        attempt += 1
        guard let camera = current else {
            state = .idle
            return
        }
        guard joinedByApp else {
            if joinedByUser, isConnected {
                if powerOffWhenDone {
                    state = .leaving
                    do {
                        try await client.powerOff()
                        notice = "已關閉相機，iPhone 會自動切回原本的 Wi-Fi。"
                    } catch {
                        notice = "無法關閉相機。請到 設定 › Wi-Fi 切回原本的網路。"
                    }
                } else {
                    notice = "請到 設定 › Wi-Fi 切回原本的網路（關掉相機也會自動切回）。"
                }
            }
            joinedByUser = false
            state = .idle
            return
        }
        state = .leaving
        let result = await joiner.leave(camera.credentials)
        joinedByApp = false
        state = .idle
        switch result {
        case .restored(let name?): notice = "已切回「\(name)」"
        case .restored(nil): notice = "已切回原本的網路"
        case .disconnected: notice = "已離開相機 Wi-Fi，但還沒連上其他網路。請從系統選單選擇 Wi-Fi。"
        case .failed(let why): notice = "切回原本網路失敗：\(why)"
        }
    }

    /// Connect silently when the device is already on the camera Wi-Fi
    /// (e.g. the user just switched in Settings and came back). Never switches networks.
    public func connectIfReachable() async {
        guard !cameras.isEmpty, !isConnected, !state.isBusy else { return }
        guard let info = await probe(timeout: 1.5), !isConnected, !state.isBusy else { return }
        attempt += 1
        current = current ?? cameras.first
        joinedByApp = false
        joinedByUser = joiner.isManual
        notice = nil
        state = .connected(info)
    }

    public var switchesWiFiAutomatically: Bool { !joiner.isManual }

    /// Stop waiting for the camera (manual join or a slow automatic join).
    public func cancel() async {
        guard state.isBusy, state != .leaving else { return }
        let mayHaveSwitched: Bool
        if case .joiningWiFi = state { mayHaveSwitched = true } else { mayHaveSwitched = joinedByApp }
        attempt += 1
        if mayHaveSwitched, let camera = current {
            state = .leaving
            _ = await joiner.leave(camera.credentials)
        }
        joinedByApp = false
        joinedByUser = false
        state = .idle
    }

    /// Re-check the camera, e.g. when the app returns to the foreground.
    public func refresh() async {
        guard isConnected else { return }
        if let info = await probe(timeout: 3) {
            state = .connected(info)
        } else {
            state = .failed("和相機的連線中斷了。")
        }
    }

    public func dismissNotice() {
        notice = nil
        if case .failed = state { state = .idle }
    }

    /// Poll until the camera answers, the attempt is superseded, or time runs out.
    private func waitForCamera(attempt mine: Int, timeout: Duration) async -> CameraInfo? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline, mine == attempt, state.isBusy {
            if let info = await probe(timeout: 2) { return info }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }

    private func probe(timeout: TimeInterval) async -> CameraInfo? {
        do {
            _ = try await client.connectMode(timeout: timeout)
            try? await client.switchMode(.play)
            return try await client.info(timeout: timeout + 2)
        } catch {
            return nil
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
