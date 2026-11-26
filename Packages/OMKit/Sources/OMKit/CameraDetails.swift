import Foundation
import ImageIO

/// What can be learned about the camera. The Wi-Fi protocol has no battery or
/// firmware command, so firmware and lens come from the newest photo's EXIF.
public struct CameraDetails: Equatable, Sendable {
    public var model: String?
    public var serial: String?
    public var firmware: String?
    public var lens: String?
    public var fileCount: Int?
    public var freeSpace: Int64?
    /// The camera reports at most 4 GiB - 1 of free space over Wi-Fi.
    public var freeSpaceIsCapped = false
    public var capacity: Int64?
    /// Percent; only reported to a Mac over a USB cable.
    public var battery: Int?

    public init() {}

    /// Fill model, firmware and lens from image data that carries EXIF.
    mutating func readEXIF(_ source: CGImageSource?) {
        guard let source,
              let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
        let tiff = all[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = all[kCGImagePropertyExifDictionary] as? [CFString: Any]
        func text(_ value: Any?) -> String? {
            let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return s?.isEmpty == false ? s : nil
        }
        model = model ?? text(tiff?[kCGImagePropertyTIFFModel])
        lens = lens ?? text(exif?[kCGImagePropertyExifLensModel])
        // The camera writes "Version 1.1"; an edited file would name the editor instead.
        if firmware == nil, let software = text(tiff?[kCGImagePropertyTIFFSoftware]), software.hasPrefix("Version") {
            firmware = String(software.dropFirst("Version".count)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// The newest still photo (JPG preferred) to read EXIF from.
    static func exifCandidate(_ files: [MediaFile]) -> MediaFile? {
        let newest = files.sorted { $0.date > $1.date }
        return newest.first { $0.kind == .jpg } ?? newest.first { $0.kind == .raw }
    }
}
