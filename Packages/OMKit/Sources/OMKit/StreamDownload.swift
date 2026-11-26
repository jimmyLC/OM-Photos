import Foundation

/// Writes an HTTP response body straight to a file, with progress and cancellation.
/// (The camera does not support Range requests, so there is no resuming.)
final class StreamDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var status = 0
    private var errorBody = Data()
    private var continuation: CheckedContinuation<Int64, Error>?
    private let lock = NSLock()

    init(request: URLRequest, configuration: URLSessionConfiguration, destination: URL,
         progress: @escaping @Sendable (Int64) -> Void) {
        self.request = request
        self.configuration = configuration
        self.destination = destination
        self.progress = progress
    }

    func run() async throws -> Int64 {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        handle = try FileHandle(forWritingTo: destination)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.withLock { continuation = c }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard status == 200 else {
            errorBody.append(data)
            return
        }
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            progress(received)
        } catch {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let c = lock.withLock { () -> CheckedContinuation<Int64, Error>? in
            defer { continuation = nil }
            return continuation
        }
        if let error = error as? URLError {
            c?.resume(throwing: error.code == .cancelled ? CancellationError()
                      : CameraError.unreachable(error.code == .timedOut ? "逾時" : error.localizedDescription))
        } else if let error {
            c?.resume(throwing: error)
        } else if status != 200 {
            c?.resume(throwing: CameraError.http(status: status, code: XML.value("errorcode", in: String(decoding: errorBody, as: UTF8.self))))
        } else {
            c?.resume(returning: received)
        }
    }
}
