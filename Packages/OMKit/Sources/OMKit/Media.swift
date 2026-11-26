import Foundation

public enum FileKind: String, Sendable, Codable {
    case jpg, raw, movie, other

    static func of(_ name: String) -> FileKind {
        switch (name as NSString).pathExtension.uppercased() {
        case "JPG", "JPEG": .jpg
        case "ORF", "ORI", "DNG": .raw
        case "MOV", "MP4", "AVI": .movie
        default: .other
        }
    }
}

/// One file on the card, as reported by a source.
public struct MediaFile: Hashable, Sendable, Identifiable, Codable {
    /// Path on the card, e.g. "/DCIM/100OMSYS/PB260003.JPG".
    public var path: String
    public var size: Int64
    public var date: Date
    public var isProtected: Bool

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
    public var stem: String { (name as NSString).deletingPathExtension }
    public var fileExtension: String { (name as NSString).pathExtension.uppercased() }
    public var kind: FileKind { FileKind.of(name) }

    public init(path: String, size: Int64, date: Date, isProtected: Bool = false) {
        self.path = path
        self.size = size
        self.date = date
        self.isProtected = isProtected
    }
}

/// What the grid shows: one photo (JPG and/or RAW of the same shot) or one video.
public struct MediaItem: Hashable, Sendable, Identifiable {
    public var files: [MediaFile]

    public var id: String { files[0].folder + "/" + files[0].stem }
    public var date: Date { files.map(\.date).min() ?? .distantPast }
    public var size: Int64 { files.reduce(0) { $0 + $1.size } }
    public var isProtected: Bool { files.contains(where: \.isProtected) }
    public var isVideo: Bool { files.contains { $0.kind == .movie } }
    public var hasRaw: Bool { files.contains { $0.kind == .raw } }
    public var hasJpg: Bool { files.contains { $0.kind == .jpg } }

    /// The file used for thumbnails and previews: JPG, else RAW, else the video.
    public var primary: MediaFile {
        files.first { $0.kind == .jpg } ?? files.first { $0.kind == .raw } ?? files[0]
    }

    /// Label shown on the cell: "RAW+JPG", "RAW", "JPG", "MOV", "MP4".
    public var badge: String {
        if hasRaw && hasJpg { return "RAW+JPG" }
        if hasRaw { return "RAW" }
        return primary.fileExtension == "JPEG" ? "JPG" : primary.fileExtension
    }

    /// Group a flat file list: files with the same name stem in the same folder
    /// (PB260005.JPG + PB260005.ORF) become one item; videos stay on their own.
    public static func group(_ files: [MediaFile]) -> [MediaItem] {
        var buckets: [String: [MediaFile]] = [:]
        var order: [String] = []
        for f in files where f.kind != .other {
            let key = f.kind == .movie ? f.path : f.folder + "/" + f.stem
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(f)
        }
        return order.map { key in
            MediaItem(files: buckets[key]!.sorted { rank($0.kind) < rank($1.kind) })
        }
        .sorted { ($0.date, $0.id) > ($1.date, $1.id) }  // newest first
    }

    private static func rank(_ k: FileKind) -> Int {
        switch k {
        case .jpg: 0
        case .raw: 1
        case .movie: 2
        case .other: 3
        }
    }
}

public enum TypeFilter: String, CaseIterable, Identifiable, Sendable {
    case all, photos, raw, videos
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "全部"
        case .photos: "照片"
        case .raw: "RAW"
        case .videos: "影片"
        }
    }

    public func matches(_ item: MediaItem) -> Bool {
        switch self {
        case .all: true
        case .photos: !item.isVideo
        case .raw: item.hasRaw
        case .videos: item.isVideo
        }
    }
}

public enum StatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all, notImported, imported
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "全部"
        case .notImported: "未匯入"
        case .imported: "已匯入"
        }
    }
}

public struct DaySection: Identifiable, Hashable, Sendable {
    public var day: Date
    public var items: [MediaItem]
    public var id: Date { day }
}

public enum Days {
    /// Items (already newest first) split by calendar day.
    public static func sections(_ items: [MediaItem], calendar: Calendar = .current) -> [DaySection] {
        var out: [DaySection] = []
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if out.last?.day == day {
                out[out.count - 1].items.append(item)
            } else {
                out.append(DaySection(day: day, items: [item]))
            }
        }
        return out
    }

    /// "今天", "昨天", or "2026年11月26日 星期四".
    public static func title(_ day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "昨天" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return day.formatted(sameYear ? .dateTime.month().day().weekday(.wide) : .dateTime.year().month().day().weekday(.wide))
    }
}

public struct MovieInfo: Hashable, Sendable {
    public var duration: TimeInterval?
    public var resolution: String?

    public init(duration: TimeInterval?, resolution: String?) {
        self.duration = duration
        self.resolution = resolution
    }

    public var durationText: String? {
        guard let d = duration, d.isFinite else { return nil }
        let s = Int(d.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
