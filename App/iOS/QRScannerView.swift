import SwiftUI
import VisionKit

/// Live QR scanner (VisionKit). Calls `onCode` for each QR payload it sees.
struct QRScannerView: View {
    let onCode: (String) -> Void

    var body: some View {
        if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
            Scanner(onCode: onCode)
        } else {
            ContentUnavailableView("無法使用相機",
                                   systemImage: "camera.badge.ellipsis",
                                   description: Text("請到 設定 › OM Photos 允許使用相機，或改用「從照片讀取」與手動輸入。"))
                .background(.quaternary)
        }
    }

    private struct Scanner: UIViewControllerRepresentable {
        let onCode: (String) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                               qualityLevel: .balanced,
                                               recognizesMultipleItems: false,
                                               isHighFrameRateTrackingEnabled: false,
                                               isHighlightingEnabled: true)
            vc.delegate = context.coordinator
            try? vc.startScanning()
            return vc
        }

        func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

        static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
            vc.stopScanning()
        }

        func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let onCode: (String) -> Void
            init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

            func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                             allItems: [RecognizedItem]) {
                for case .barcode(let code) in items {
                    if let text = code.payloadStringValue { onCode(text) }
                }
            }
        }
    }
}
