import Foundation
import Observation
import OMKit

/// Where the library reads from.
enum SourceID: Hashable {
    case wifi
    case volume(URL)
}

/// Sidebar rows (one selection, like the Photos sidebar).
enum SidebarItem: Hashable {
    case source(SourceID)
    case type(TypeFilter)
    case day(Date)
}

/// App-wide state shared by every window and platform.
@MainActor @Observable
final class AppModel {
    let connection: ConnectionManager
    let library = LibraryModel()

    /// Camera cards available over USB (camera in "Storage" mode).
    private(set) var volumes: [URL] = []
    var selectedSource: SourceID = .wifi
    /// Day the grid should scroll to (set from the sidebar or the date menu).
    var scrollTarget: Date?
    /// Item open in the full-screen viewer.
    var viewing: MediaItem.ID?
    /// iPhone/iPad: taps select instead of opening the viewer.
    var selecting = false
    /// Ask the root view to show the pairing sheet.
    var requestPairing = false
    /// iPhone/iPad: show the Files picker to choose the USB card.
    var pickingVolume = false

    let importer: Importer
    /// Import waiting for the user's OK (shows count, size and time first).
    var pendingImport: PendingImport?
    /// Source cache key that was auto-imported already (once per load).
    private var autoImportedSource: String?

    struct PendingImport: Identifiable {
        let id = UUID()
        let items: [MediaItem]
        let title: String
        let bytes: Int64
        let seconds: TimeInterval
        let destination: String
    }

    init(connection: ConnectionManager) {
        self.connection = connection
        connection.powerOffWhenDone = UserDefaults.standard.object(forKey: SettingKey.powerOffWhenDone) as? Bool ?? true
        let ledger = ImportLedger()
        importer = Importer(ledger: ledger)
        library.ledger = ledger
        importer.onItemImported = { [weak self] item in self?.library.importedIDs.insert(item.id) }
        importer.onRunningChange = { running in KeepAwake.set(running) }
    }

    // MARK: Import

    var newItemCount: Int { library.items.count - library.importedIDs.count }

    func askImportNew() {
        prepare(importer.newItems(library.items), title: "匯入所有新項目")
    }

    func askImportSelected() {
        prepare(library.selectedItems, title: "匯入選取的項目")
    }

    func retryFailed() {
        let items = importer.failedItems
        importer.dismissSummary()
        prepare(items, title: "重試失敗的項目")
    }

    private func prepare(_ items: [MediaItem], title: String) {
        guard let source = library.source, !items.isEmpty, !importer.isRunning else { return }
        let estimate = Importer.estimate(items, source: source)
        #if os(macOS)
        if ImportSettings.kind == .folder {
            let time = Duration.seconds(max(estimate.seconds, 1))
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
            let message = "\(title)：\(items.count) 項，共 \(estimate.bytes.formatted(.byteCount(style: .file)))，預估約 \(time)。"
            guard let folder = ImportSettings.chooseFolder(message: message) else { return }
            importer.start(items, from: source, to: FolderDestination(root: folder))
            return
        }
        #endif
        pendingImport = PendingImport(items: items, title: title, bytes: estimate.bytes,
                                      seconds: estimate.seconds, destination: ImportSettings.destinationTitle)
    }

    func confirmImport(_ pending: PendingImport) {
        pendingImport = nil
        guard let source = library.source else { return }
        do {
            importer.start(pending.items, from: source, to: try ImportSettings.destination())
        } catch {
            importError = error.localizedDescription
        }
    }

    var importError: String?

    // MARK: Delete

    /// Items waiting for the user's OK to be deleted from the card.
    var pendingDelete: [MediaItem]?
    /// Result message after deleting (shown briefly).
    var deleteMessage: String?

    func askDeleteSelected() {
        let items = library.selectedItems
        guard !items.isEmpty, !importer.isRunning, !library.isDeleting else { return }
        pendingDelete = items
    }

    /// `items` comes from the alert itself: dismissing the alert clears `pendingDelete`
    /// before the button action runs.
    func confirmDelete(_ items: [MediaItem]) async {
        pendingDelete = nil
        let r = await library.delete(items)
        var parts: [String] = []
        if r.deleted > 0 { parts.append("已從相機刪除 \(r.deleted) 項") }
        if !r.failed.isEmpty { parts.append("\(r.failed.count) 項刪除失敗（\(r.failed.prefix(3).joined(separator: "、"))）") }
        if r.skippedProtected > 0 { parts.append("略過 \(r.skippedProtected) 項受保護的檔案") }
        deleteMessage = parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    /// Text for the delete confirmation.
    func deleteSummary(_ items: [MediaItem]) -> String {
        let protected = items.filter(\.isProtected)
        let deletable = items.filter { !$0.isProtected }
        let notImported = deletable.filter { !library.importedIDs.contains($0.id) }
        var lines: [String] = []
        let names = deletable.prefix(8).map { $0.files.map(\.name).joined(separator: " + ") }
        lines.append(names.joined(separator: "\n") + (deletable.count > 8 ? "\n…等 \(deletable.count) 項" : ""))
        if !notImported.isEmpty {
            lines.append("⚠️ 其中 \(notImported.count) 項還沒有匯入：\n" + notImported.prefix(5).map(\.primary.name).joined(separator: "、")
                         + (notImported.count > 5 ? "…" : ""))
        }
        if !protected.isEmpty { lines.append("\(protected.count) 項在相機上設為保護，會略過。") }
        lines.append("刪除後無法復原。")
        return lines.joined(separator: "\n\n")
    }

    /// After the list loads: import new items automatically if the user turned that on.
    func autoImportIfWanted() {
        guard UserDefaults.standard.bool(forKey: SettingKey.autoImport), library.phase == .loaded,
              let source = library.source, autoImportedSource != source.cacheKey, !importer.isRunning else { return }
        autoImportedSource = source.cacheKey
        let items = importer.newItems(library.items)
        guard !items.isEmpty else { return }
        do {
            importer.start(items, from: source, to: try ImportSettings.destination())
        } catch {
            importError = error.localizedDescription
        }
    }

    /// After an import over Wi-Fi: switch back to the normal network if the user wants that.
    func afterImport(_ summary: ImportSummary) async {
        let wanted = UserDefaults.standard.bool(forKey: SettingKey.autoDisconnect)  // default off
        guard wanted, connection.joinedByApp, selectedSource == .wifi, connection.isConnected, summary.imported > 0,
              summary.failed.isEmpty, !summary.cancelled, summary.error == nil else { return }
        await connection.disconnect()
    }

    var sourceTitle: String {
        switch selectedSource {
        case .wifi: connection.displayName
        case .volume(let url): VolumeSource(root: url).displayName
        }
    }

    /// Call when the connection or the selected source changes.
    func syncSource() async {
        switch selectedSource {
        case .wifi:
            if connection.isConnected, case .connected(let info) = connection.state {
                let id = connection.current?.id ?? info.model
                await library.setSource(WiFiSource(client: connection.client, cameraID: id))
            } else {
                await library.setSource(nil)
            }
        case .volume(let url):
            await library.setSource(VolumeSource(root: url))
        }
    }

    /// Launch: a card already plugged in wins over Wi-Fi (no pairing or connect screen).
    func startWithCards(_ urls: [URL]) {
        volumes = urls
        if let first = urls.first { selectedSource = .volume(first) }
    }

    /// True when a USB card is the source, so Wi-Fi pairing and connecting are not needed.
    var usingUSB: Bool {
        if case .volume = selectedSource { return true }
        return false
    }

    func select(_ source: SourceID) async {
        selectedSource = source
        library.typeFilter = .all
        await syncSource()
    }

    // MARK: USB

    /// Replace the list of mounted cards (from the Mac volume watcher).
    func setVolumes(_ urls: [URL]) async {
        let added = urls.filter { !volumes.contains($0) }
        volumes = urls
        if case .volume(let current) = selectedSource, !urls.contains(current) {
            selectedSource = .wifi
            await syncSource()
        } else if let first = added.first, !(selectedSource == .wifi && connection.isConnected) {
            // A card was plugged in: show it (faster than Wi-Fi), unless Wi-Fi is in use.
            await select(.volume(first))
        }
    }

    /// iOS/iPadOS: the user picked the card folder in the Files picker.
    func addPickedVolume(_ url: URL) async -> Bool {
        _ = url.startAccessingSecurityScopedResource()  // kept for the whole session
        guard VolumeSource.looksLikeCard(url) else {
            url.stopAccessingSecurityScopedResource()
            return false
        }
        if !volumes.contains(url) { volumes.append(url) }
        await select(.volume(url))
        return true
    }

    func removeVolume(_ url: URL) async {
        volumes.removeAll { $0 == url }
        url.stopAccessingSecurityScopedResource()
        if selectedSource == .volume(url) { await select(.wifi) }
    }
}

enum SettingKey {
    static let autoDisconnect = "autoDisconnectAfterImport"
    static let powerOffWhenDone = "powerOffWhenDone"
    static let thumbnailSize = "thumbnailSize"
    static let autoImport = "autoImportOnConnect"
    static let destinationKind = "destinationKind"
    static let destinationFolderPath = "destinationFolderPath"
    static let destinationFolderBookmark = "destinationFolderBookmark"
}
