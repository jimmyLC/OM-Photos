import AVFoundation
import CoreImage
import SwiftUI

/// Live QR scanner using the Mac's camera. Calls `onCode` for each QR payload it sees.
struct QRScannerView: View {
    let onCode: (String) -> Void
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            switch status {
            case .authorized:
                Preview(onCode: onCode)
            case .notDetermined:
                ProgressView().task {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                    status = AVCaptureDevice.authorizationStatus(for: .video)
                }
            default:
                ContentUnavailableView("無法使用鏡頭",
                                       systemImage: "camera.badge.ellipsis",
                                       description: Text("請到 系統設定 › 隱私權與安全性 › 相機 允許 OM Transfer，或改用「從照片讀取」與手動輸入。"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary)
    }

    private struct Preview: NSViewRepresentable {
        let onCode: (String) -> Void

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.wantsLayer = true
            let scanner = context.coordinator
            if let layer = scanner.start() {
                layer.frame = view.bounds
                layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                view.layer?.addSublayer(layer)
            }
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {}

        static func dismantleNSView(_ view: NSView, coordinator: Scanner) {
            coordinator.stop()
        }

        func makeCoordinator() -> Scanner { Scanner(onCode: onCode) }
    }

    final class Scanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        let onCode: (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "qr-scanner")
        private let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                          options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        private var lastFrame = Date.distantPast

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func start() -> CALayer? {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            // Mirror like a mirror; the QR detector reads the unmirrored frames.
            layer.connection?.automaticallyAdjustsVideoMirroring = false
            layer.connection?.isVideoMirrored = true
            let session = session
            queue.async { session.startRunning() }
            return layer
        }

        func stop() {
            let session = session
            queue.async { session.stopRunning() }
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard Date().timeIntervalSince(lastFrame) > 0.25, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
            lastFrame = Date()
            let image = CIImage(cvPixelBuffer: pixels)
            for case let feature as CIQRCodeFeature in detector?.features(in: image) ?? [] {
                if let text = feature.messageString {
                    DispatchQueue.main.async { self.onCode(text) }
                }
            }
        }
    }
}
