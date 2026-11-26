import Foundation

public enum CameraError: Error, LocalizedError, Equatable {
    case unreachable(String)
    case http(status: Int, code: String?)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let why): "連不到相機（\(why)）"
        case .http(let status, let code): "相機回應錯誤 HTTP \(status)" + (code.map { "，代碼 \($0)" } ?? "")
        case .badResponse(let what): "相機回應無法解讀：\(what)"
        }
    }
}

public struct CameraInfo: Equatable, Sendable {
    public var model: String
    /// Free space in bytes. The camera caps this at 4 GiB - 1, so `freeSpaceIsCapped` means "at least".
    public var freeSpace: Int64?
    public var freeSpaceIsCapped: Bool { freeSpace == 4_294_967_295 }
}

public enum CameraMode: String, Sendable {
    case play, rec
}

/// HTTP client for the camera's own Wi-Fi (OI.Share protocol).
/// Commands are sent one at a time: the camera handles a single request at once.
public actor CameraClient {
    public static let defaultHost = "192.168.0.10"
    nonisolated public let host: String
    private let session: URLSession
    private var tail: Task<Void, Never>?

    public init(host: String = CameraClient.defaultHost, session: URLSession? = nil) {
        self.host = host
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpMaximumConnectionsPerHost = 1
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Commands

    public func connectMode(timeout: TimeInterval = 3) async throws -> String {
        let body = try await text("get_connectmode.cgi", timeout: timeout)
        return XML.value("connectmode", in: body) ?? body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func info(timeout: TimeInterval = 5) async throws -> CameraInfo {
        let body = try await text("get_caminfo.cgi", timeout: timeout)
        guard let model = XML.value("model", in: body) else { throw CameraError.badResponse("沒有 model") }
        let unused = try? await text("get_unusedcapacity.cgi", timeout: timeout)
        return CameraInfo(model: model, freeSpace: unused.flatMap { XML.value("unused", in: $0) }.flatMap { Int64($0) })
    }

    public func switchMode(_ mode: CameraMode, settle: Duration = .zero) async throws {
        _ = try await data("switch_cammode.cgi", query: ["mode": mode.rawValue])
        if settle > .zero { try await Task.sleep(for: settle) }
    }

    // MARK: Transport

    public func text(_ cgi: String, query: [String: String] = [:], timeout: TimeInterval = 10) async throws -> String {
        String(decoding: try await data(cgi, query: query, timeout: timeout), as: UTF8.self)
    }

    public func data(_ path: String, query: [String: String] = [:], timeout: TimeInterval = 10) async throws -> Data {
        let request = makeRequest(path, query: query, timeout: timeout)
        let previous = tail
        let session = session
        let job = Task { () throws -> Data in
            await previous?.value
            return try await Self.perform(request, session: session)
        }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }

    nonisolated func makeRequest(_ path: String, query: [String: String], timeout: TimeInterval) -> URLRequest {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            // The camera expects unescaped slashes in DIR=/DCIM/...
            c.percentEncodedQuery = query.sorted { $0.key < $1.key }.map { key, value in
                let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?"))
                return "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }.joined(separator: "&")
        }
        var r = URLRequest(url: c.url!, timeoutInterval: timeout)
        r.setValue("OI.Share v2", forHTTPHeaderField: "User-Agent")
        return r
    }

    static func perform(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await session.data(for: request)
        } catch let e as URLError {
            throw CameraError.unreachable(e.code == .timedOut ? "逾時" : e.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CameraError.badResponse("不是 HTTP") }
        guard http.statusCode == 200 else {
            throw CameraError.http(status: http.statusCode, code: XML.value("errorcode", in: String(decoding: body, as: UTF8.self)))
        }
        return body
    }
}

enum XML {
    /// First `<tag>value</tag>` in a small camera response.
    static func value(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
