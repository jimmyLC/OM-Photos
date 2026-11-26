import CoreImage
import Foundation

/// Finds QR codes in a still image (a photo or screenshot of the camera screen).
public enum QRImageReader {
    public static func messages(in image: CIImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: image) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    public static func credentials(in image: CIImage) -> CameraCredentials? {
        messages(in: image).lazy.compactMap(PairingCode.parse).first
    }

    public static func credentials(inFile url: URL) -> CameraCredentials? {
        CIImage(contentsOf: url).flatMap(credentials(in:))
    }
}
