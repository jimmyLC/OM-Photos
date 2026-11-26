import CoreGraphics
import Foundation
import Observation

/// The list of items from the current source, with filters and selection.
@MainActor @Observable
public final class LibraryModel {
    public enum Phase: Equatable {
        case noSource, loading, loaded, failed(String)
    }

    public private(set) var phase: Phase = .noSource
    public private(set) var source: (any CameraSource)?
    public private(set) var items: [MediaItem] = []
    public private(set) var movieInfo: [String: MovieInfo] = [:]

    public var typeFilter: TypeFilter = .all
    public var statusFilter: StatusFilter = .all
    public var selection: Set<MediaItem.ID> = []
    /// IDs of items already imported on this device.
    public var importedIDs: Set<MediaItem.ID> = []
    public var ledger: ImportLedger?

    public let images: ImageStore
    private var loadID = 0

    public init(images: ImageStore = ImageStore()) {
        self.images = images
    }

    // MARK: Derived

    public var filtered: [MediaItem] {
        items.filter { item in
            guard typeFilter.matches(item) else { return false }
            switch statusFilter {
            case .all: return true
            case .imported: return importedIDs.contains(item.id)
            case .notImported: return !importedIDs.contains(item.id)
            }
        }
    }

    public var sections: [DaySection] { Days.sections(filtered) }

    public func count(_ filter: TypeFilter) -> Int { items.filter(filter.matches).count }

    public var selectedItems: [MediaItem] { filtered.filter { selection.contains($0.id) } }
    public var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    // MARK: Loading

    public func setSource(_ source: (any CameraSource)?) async {
        if source?.cacheKey == self.source?.cacheKey, phase == .loaded || phase == .loading { return }
        self.source = source
        items = []
        selection = []
        movieInfo = [:]
        phase = source == nil ? .noSource : .loading
        await reload()
    }

    public func reload() async {
        guard let source else {
            phase = .noSource
            return
        }
        loadID += 1
        let mine = loadID
        phase = .loading
        do {
            let files = try await source.listFiles()
            guard mine == loadID, source.cacheKey == self.source?.cacheKey else { return }
            items = MediaItem.group(files)
            importedIDs = ledger?.importedIDs(in: items) ?? []
            selection.formIntersection(Set(items.map(\.id)))
            phase = .loaded
        } catch {
            guard mine == loadID else { return }
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: Images

    public func thumbnail(for item: MediaItem) async -> CGImage? {
        guard let source else { return nil }
        return await images.image(for: item.primary, size: .thumbnail, from: source)
    }

    public func preview(for item: MediaItem) async -> CGImage? {
        guard let source else { return nil }
        return await images.image(for: item.primary, size: .preview, from: source)
    }

    public func loadMovieInfo(for item: MediaItem) async {
        guard item.isVideo, movieInfo[item.id] == nil, let source else { return }
        if let info = try? await source.movieInfo(for: item.primary) {
            movieInfo[item.id] = info
        }
    }

    // MARK: Delete

    public struct DeleteResult: Equatable, Sendable {
        public var deleted = 0
        public var failed: [String] = []
        public var skippedProtected = 0
    }

    public private(set) var isDeleting = false

    /// Delete whole items (RAW and JPG together) from the card, then reload the list.
    /// Protected items are skipped. Files are deleted one at a time.
    public func delete(_ targets: [MediaItem]) async -> DeleteResult {
        var result = DeleteResult()
        guard let source, !isDeleting else { return result }
        isDeleting = true
        defer { isDeleting = false }
        for item in targets {
            if item.isProtected {
                result.skippedProtected += 1
                continue
            }
            var ok = true
            for file in item.files {
                do {
                    try await source.delete(file)
                } catch {
                    ok = false
                }
            }
            if ok {
                result.deleted += 1
            } else {
                result.failed.append(item.primary.name)
            }
        }
        selection.subtract(targets.map(\.id))
        await reload()
        return result
    }

    // MARK: Selection

    public func select(_ item: MediaItem, extend: Bool, toggle: Bool) {
        let list = filtered
        if extend, let anchor = anchorID, let a = list.firstIndex(where: { $0.id == anchor }),
           let b = list.firstIndex(where: { $0.id == item.id }) {
            selection.formUnion(list[min(a, b)...max(a, b)].map(\.id))
        } else if toggle {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchorID = item.id
        } else {
            selection = [item.id]
            anchorID = item.id
        }
    }

    public func selectAll() { selection = Set(filtered.map(\.id)) }
    public func clearSelection() { selection = [] }
    private var anchorID: MediaItem.ID?
}
