import Foundation
import Testing
@testable import OMKit

/// Fake camera behind URLProtocol. `reachable` simulates being on the camera Wi-Fi.
final class FakeCamera: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reachable = false
    nonisolated(unsafe) static var requests: [String] = []
    nonisolated(unsafe) static var unusedResponse = "<unused>4294967295</unused>"
    static let lock = NSLock()

    static func reset(reachable: Bool) {
        lock.withLock {
            self.reachable = reachable
            requests = []
            unusedResponse = "<unused>4294967295</unused>"
        }
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeCamera.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        let (up, unused) = Self.lock.withLock { () -> (Bool, String) in
            Self.requests.append(path + " UA=" + (request.value(forHTTPHeaderField: "User-Agent") ?? ""))
            return (Self.reachable, Self.unusedResponse)
        }
        guard up else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        var status = 200
        let body: String
        switch url.path {
        case "/get_connectmode.cgi": body = "<connectmode>private</connectmode>"
        case "/get_caminfo.cgi": body = "<?xml version=\"1.0\"?><caminfo><model>OM-3</model></caminfo>"
        case "/get_unusedcapacity.cgi": body = unused
        case "/switch_cammode.cgi", "/exec_pwoff.cgi": body = ""
        default: status = 520; body = "<errorcode>1001</errorcode>"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

actor FakeJoiner: WiFiJoining {
    var joins = 0
    var leaves = 0
    var joinError: Error?
    var makesCameraReachable = true
    var leaveResult: LeaveResult = .restored("Home")

    func configure(error: Error? = nil, reachable: Bool = true, leave: LeaveResult = .restored("Home")) {
        joinError = error
        makesCameraReachable = reachable
        leaveResult = leave
    }

    func join(_ credentials: CameraCredentials) async throws {
        joins += 1
        if let joinError { throw joinError }
        if makesCameraReachable { FakeCamera.lock.withLock { FakeCamera.reachable = true } }
    }

    func leave(_ credentials: CameraCredentials) async -> LeaveResult {
        leaves += 1
        FakeCamera.lock.withLock { FakeCamera.reachable = false }
        return leaveResult
    }
}

struct JoinDenied: LocalizedError {
    var errorDescription: String? { "你取消了加入相機 Wi-Fi" }
}

@MainActor @Suite(.serialized)
struct ConnectionTests {
    let camera = PairedCamera(name: "OM-3", credentials: .init(ssid: "OM-3-P-X", password: "pw"))

    func make(_ joiner: FakeJoiner, timeout: Duration = .seconds(3)) -> ConnectionManager {
        ConnectionManager(store: MemoryCameraStore([camera]), joiner: joiner,
                          client: CameraClient(session: FakeCamera.session()),
                          joinTimeout: timeout, pollInterval: .milliseconds(50))
    }

    @Test func alreadyOnCameraWiFiDoesNotSwitch() async {
        FakeCamera.reset(reachable: true)
        let joiner = FakeJoiner()
        let m = make(joiner)
        await m.connect()
        #expect(m.state == .connected(CameraInfo(model: "OM-3", freeSpace: 4_294_967_295)))
        #expect(m.joinedByApp == false)
        await m.disconnect()
        #expect(await joiner.joins == 0)
        #expect(await joiner.leaves == 0)  // we did not switch, so we do not switch back
        #expect(m.state == .idle)
        #expect(FakeCamera.requests.allSatisfy { $0.hasSuffix("UA=OI.Share v2") })
    }

    @Test func joinsThenSwitchesBack() async {
        FakeCamera.reset(reachable: false)
        let joiner = FakeJoiner()
        let m = make(joiner)
        await m.connect()
        #expect(m.isConnected)
        #expect(m.joinedByApp)
        #expect(FakeCamera.requests.contains { $0.hasPrefix("/switch_cammode.cgi?mode=play") })
        await m.disconnect()
        #expect(await joiner.leaves == 1)
        #expect(m.notice == "已切回「Home」")
        #expect(m.state == .idle)
    }

    @Test func joinRefused() async {
        FakeCamera.reset(reachable: false)
        let joiner = FakeJoiner()
        await joiner.configure(error: JoinDenied())
        let m = make(joiner)
        await m.connect()
        #expect(m.state == .failed("你取消了加入相機 Wi-Fi"))
        #expect(await joiner.leaves == 0)
    }

    @Test func cameraNeverAnswersAfterJoin() async {
        FakeCamera.reset(reachable: false)
        let joiner = FakeJoiner()
        await joiner.configure(reachable: false, leave: .disconnected)
        let m = make(joiner, timeout: .milliseconds(400))
        await m.connect()
        guard case .failed(let why) = m.state else { Issue.record("expected failure, got \(m.state)"); return }
        #expect(why.contains("沒有回應"))
        #expect(why.contains("沒有連上任何 Wi-Fi"))
        #expect(await joiner.leaves == 1)  // went back instead of leaving the user stranded
        #expect(m.joinedByApp == false)
    }

    @Test func manualJoinWaitsForUser() async {
        FakeCamera.reset(reachable: false)
        let joiner = FakeJoiner()
        await joiner.configure(error: ManualJoinRequired())
        let m = make(joiner)
        let task = Task { await m.connect() }
        try? await Task.sleep(for: .milliseconds(200))
        guard case .waitingForUser(let c) = m.state else { Issue.record("state \(m.state)"); return }
        #expect(c.ssid == "OM-3-P-X")
        FakeCamera.lock.withLock { FakeCamera.reachable = true }  // user switched in Settings
        await task.value
        #expect(m.isConnected)
        #expect(m.joinedByUser)
        await m.disconnect()
        #expect(await joiner.leaves == 0)
        #expect(FakeCamera.requests.contains { $0.hasPrefix("/exec_pwoff.cgi") })
        #expect(m.notice == "已關閉相機，iPhone 會自動切回原本的 Wi-Fi。")
    }

    @Test func manualJoinWithoutPowerOff() async {
        FakeCamera.reset(reachable: true)
        let joiner = FakeJoiner()
        await joiner.configure(error: ManualJoinRequired())
        let m = make(joiner)
        m.powerOffWhenDone = false
        await m.connect()
        await m.disconnect()
        #expect(!FakeCamera.requests.contains { $0.hasPrefix("/exec_pwoff.cgi") })
    }

    @Test func automaticJoinNeverPowersOff() async {
        FakeCamera.reset(reachable: false)
        let joiner = FakeJoiner()
        let m = make(joiner)
        await m.connect()
        await m.disconnect()
        #expect(!FakeCamera.requests.contains { $0.hasPrefix("/exec_pwoff.cgi") })
        #expect(await joiner.leaves == 1)
    }

    @Test func cancelWhileWaiting() async {
        FakeCamera.reset(reachable: false)
        let joiner = FakeJoiner()
        await joiner.configure(error: ManualJoinRequired())
        let m = make(joiner)
        let task = Task { await m.connect() }
        try? await Task.sleep(for: .milliseconds(200))
        await m.cancel()
        await task.value
        #expect(m.state == .idle)
        #expect(await joiner.leaves == 0)
    }

    @Test func lostConnectionIsReported() async {
        FakeCamera.reset(reachable: true)
        let m = make(FakeJoiner())
        await m.connect()
        FakeCamera.lock.withLock { FakeCamera.reachable = false }
        await m.refresh()
        #expect(m.state == .failed("和相機的連線中斷了。"))
    }

    @Test func pairRenameForget() async throws {
        FakeCamera.reset(reachable: false)
        let m = ConnectionManager(store: MemoryCameraStore(), joiner: FakeJoiner(),
                                  client: CameraClient(session: FakeCamera.session()))
        let c = try m.pair(.init(ssid: "OM-3-P-ABC", password: "x"))
        #expect(c.name == "OM-3")
        try m.rename(c, to: "我的 OM-3")
        try m.pair(.init(ssid: "OM-3-P-ABC", password: "y"))  // re-scan keeps the name
        #expect(m.cameras.map(\.name) == ["我的 OM-3"])
        #expect(m.cameras.first?.credentials.password == "y")
        try await m.forget(m.cameras[0])
        #expect(m.cameras.isEmpty)
    }

    @Test func queryKeepsSlashes() {
        let r = CameraClient().makeRequest("get_imglist.cgi", query: ["DIR": "/DCIM/100OMSYS"], timeout: 1)
        #expect(r.url?.absoluteString == "http://192.168.0.10/get_imglist.cgi?DIR=/DCIM/100OMSYS")
    }
}

extension ConnectionTests {
    @Test func connectsWithoutPairingWhenAlreadyOnCameraWiFi() async {
        FakeCamera.reset(reachable: true)
        let m = ConnectionManager(store: MemoryCameraStore(), joiner: FakeJoiner(),
                                  client: CameraClient(session: FakeCamera.session()))
        await m.connectIfReachable()
        #expect(m.isConnected)
        #expect(m.current == nil)
        #expect(m.displayName == "OM-3")
        await m.disconnect()
        #expect(m.state == .idle)
    }
}
