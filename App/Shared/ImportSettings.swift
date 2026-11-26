import Foundation
import OMKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where imports go. Mac: a folder by default; iPhone/iPad: the Photos library by default.
enum ImportSettings {
    enum Kind: String, CaseIterable, Identifiable {
        case folder, photos
        var id: String { rawValue }
        var title: String { self == .folder ? "資料夾" : "照片圖庫" }
    }

    static var kind: Kind {
        get {
            if let raw = UserDefaults.standard.string(forKey: SettingKey.destinationKind), let k = Kind(rawValue: raw) { return k }
            #if os(macOS)
            return .folder
            #else
            return .photos
            #endif
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingKey.destinationKind) }
    }

    // MARK: Folder

    /// The chosen folder, or nil on iOS when none was picked yet.
    static var folder: URL? {
        #if os(macOS)
        // The folder chosen last time (the app never creates one on its own).
        guard let path = UserDefaults.standard.string(forKey: SettingKey.destinationFolderPath) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        guard let data = UserDefaults.standard.data(forKey: SettingKey.destinationFolderBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()  // held for the app's lifetime
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: SettingKey.destinationFolderBookmark)
        }
        return url
        #endif
    }

    static func setFolder(_ url: URL) {
        #if os(macOS)
        UserDefaults.standard.set(url.path, forKey: SettingKey.destinationFolderPath)
        #else
        _ = url.startAccessingSecurityScopedResource()
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: SettingKey.destinationFolderBookmark)
        }
        #endif
    }

    #if os(macOS)
    /// Ask where to import, starting at the folder used last time.
    /// The panel doubles as the confirmation: it shows what will be imported.
    @MainActor
    static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "選擇匯入的資料夾"
        panel.message = message
        panel.prompt = "匯入到這裡"
        panel.directoryURL = folder ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        setFolder(url)
        return url
    }
    #endif

    static var destinationTitle: String {
        switch kind {
        case .photos: "照片圖庫"
        case .folder: folder.map { "「\($0.lastPathComponent)」資料夾" } ?? "（尚未選擇資料夾）"
        }
    }

    static func destination() throws -> any ImportDestination {
        switch kind {
        case .photos:
            return PhotoLibraryDestination()
        case .folder:
            guard let folder else { throw ImportError("請先到設定選擇匯入的資料夾。") }
            return FolderDestination(root: folder)
        }
    }

    /// Show the imported files: the folder in Finder, or the Photos app.
    static func reveal(_ location: String?) {
        #if os(macOS)
        if kind == .photos {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        } else if let path = location ?? folder?.path {
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        }
        #else
        let url = kind == .photos ? URL(string: "photos-redirect://")
            : location.flatMap { URL(string: "shareddocuments://" + $0) }
        if let url { UIApplication.shared.open(url) }
        #endif
    }
}

/// Keep the device awake while importing.
@MainActor
enum KeepAwake {
    #if os(macOS)
    private static var activity: NSObjectProtocol?
    #else
    private static var background: UIBackgroundTaskIdentifier = .invalid
    #endif

    static func set(_ on: Bool) {
        #if os(macOS)
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "正在從相機匯入照片")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        #else
        UIApplication.shared.isIdleTimerDisabled = on
        if on, background == .invalid {
            // A little extra time if the user leaves the app; long imports still need it open.
            background = UIApplication.shared.beginBackgroundTask(withName: "import") {
                UIApplication.shared.endBackgroundTask(background)
                background = .invalid
            }
        } else if !on, background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        #endif
    }
}
