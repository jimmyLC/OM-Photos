import OMKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var showPairing = false
    @State private var showSettings = false
    @State private var volumeError: String?

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if connection.cameras.isEmpty && model.volumes.isEmpty {
                NavigationStack {
                    WelcomeView(pair: { showPairing = true })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("OM Transfer")
                        .toolbar { moreMenu }
                }
            } else if isCompact {
                NavigationStack {
                    DetailView()
                        .navigationTitle(model.sourceTitle)
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar { compactToolbar }
                }
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
                } detail: {
                    DetailView()
                        .navigationTitle(model.sourceTitle)
                        .toolbar { regularToolbar }
                }
            }
        }
        .overlay {
            if model.viewing != nil {
                ViewerView()
            }
        }
        .sheet(isPresented: $showPairing) {
            PairingView { camera in
                showPairing = false
                Task {
                    await model.select(.wifi)
                    await connection.connect(camera)
                }
            }
            .environment(connection)
        }
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar { Button("完成") { showSettings = false } }
            }
            .environment(connection)
        }
        .fileImporter(isPresented: $model.pickingVolume, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task {
                if !(await model.addPickedVolume(url)) {
                    volumeError = "這個資料夾裡沒有 DCIM。請選擇相機記憶卡的最上層（例如「OM SYSTEM」）。"
                }
            }
        }
        #endif
        .alert("不是相機記憶卡", isPresented: .init(get: { volumeError != nil }, set: { if !$0 { volumeError = nil } })) {
            Button("好") {}
        } message: {
            Text(volumeError ?? "")
        }
        .confirmationDialog(model.pendingImport?.title ?? "", isPresented: .init(
            get: { model.pendingImport != nil }, set: { if !$0 { model.pendingImport = nil } }
        ), titleVisibility: .visible, presenting: model.pendingImport) { pending in
            Button("開始匯入") { model.confirmImport(pending) }
            Button("取消", role: .cancel) {}
        } message: { pending in
            Text(importMessage(pending))
        }
        .alert("無法匯入", isPresented: .init(get: { model.importError != nil }, set: { if !$0 { model.importError = nil } })) {
            Button("好") {}
        } message: {
            Text(model.importError ?? "")
        }
        .onChange(of: model.importer.phase) { _, phase in
            if case .finished(let summary) = phase { Task { await model.afterImport(summary) } }
        }
        .onChange(of: model.library.phase) { _, phase in
            if phase == .loaded { model.autoImportIfWanted() }
        }
        .onAppear {
            // First launch: go straight to the scanner.
            if connection.cameras.isEmpty && model.volumes.isEmpty { showPairing = true }
        }
        .task { await connection.connectIfReachable() }
        .onChange(of: connection.isConnected) { _, _ in
            Task { await model.syncSource() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                if connection.isConnected {
                    await connection.refresh()
                } else {
                    // Back from Settings after joining the camera Wi-Fi: connect by itself.
                    await connection.connectIfReachable()
                }
            }
        }
    }

    private func importMessage(_ p: AppModel.PendingImport) -> String {
        let time = Duration.seconds(max(p.seconds, 1))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
        var text = "\(p.items.count) 項，共 \(p.bytes.formatted(.byteCount(style: .file)))，預估約 \(time)。\n存到\(p.destination)。"
        if model.selectedSource == .wifi, p.seconds > 120 {
            text += "\n\nWi-Fi 較慢，大量檔案或影片建議用 USB 線（快 10 倍以上）。"
        }
        return text
    }

    // MARK: Toolbars

    @ToolbarContentBuilder private var regularToolbar: some ToolbarContent {
        if model.selectedSource == .wifi {
            ToolbarItem(placement: .principal) { StatusPill() }
        }
        if model.library.phase == .loaded {
            ToolbarItem(placement: .primaryAction) { StatusPicker() }
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) { ZoomSlider() }
            #else
            ToolbarItem(placement: .primaryAction) { SelectButton() }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button("重新整理", systemImage: "arrow.clockwise") { Task { await model.library.reload() } }
                    .keyboardShortcut("r")
            }
        }
        moreMenu
    }

    @ToolbarContentBuilder private var compactToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { CompactFilterMenu() }
        if model.library.phase == .loaded {
            ToolbarItem(placement: .primaryAction) { SelectButton() }
        }
        moreMenu
    }

    @ToolbarContentBuilder private var moreMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if model.selectedSource == .wifi, connection.isConnected {
                    Button("中斷連線", systemImage: "wifi.slash") { Task { await connection.disconnect() } }
                        .disabled(model.importer.isRunning)
                }
                Button("配對新相機", systemImage: "qrcode.viewfinder") { showPairing = true }
                #if os(iOS)
                Button("設定", systemImage: "gearshape") { showSettings = true }
                #else
                SettingsLink { Label("設定…", systemImage: "gearshape") }
                #endif
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
        }
    }
}

struct StatusPicker: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var library = model.library
        Picker("狀態", selection: $library.statusFilter) {
            ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

struct SelectButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button(model.selecting ? "完成" : "選取") {
            model.selecting.toggle()
            if !model.selecting { model.library.clearSelection() }
        }
    }
}

#if os(macOS)
struct ZoomSlider: View {
    @AppStorage(SettingKey.thumbnailSize) private var cellSize: Double = PhotoGrid.defaultSize
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3").imageScale(.small).foregroundStyle(.secondary)
            Slider(value: $cellSize, in: PhotoGrid.sizeRange)
                .frame(width: 110)
                .accessibilityLabel("縮圖大小")
            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
        }
    }
}
#endif

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

enum WiFiSettings {
    /// Opens the Wi-Fi page of Settings. `App-Prefs:` is not public API (fine for a
    /// personal build); if iOS refuses it, fall back to the app's own Settings page.
    static func open() {
        #if os(iOS)
        let candidates = ["App-Prefs:WIFI", "App-Prefs:root=WIFI", UIApplication.openSettingsURLString]
        func attempt(_ i: Int) {
            guard i < candidates.count, let url = URL(string: candidates[i]) else { return }
            UIApplication.shared.open(url) { ok in if !ok { attempt(i + 1) } }
        }
        attempt(0)
        #endif
    }
}

// MARK: - First launch

struct WelcomeView: View {
    let pair: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("把 OM 相機的照片快速帶過來")
                    .font(.title2.weight(.semibold))
                Text("先配對一次，之後一鍵連線。")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, text: "相機：選單 › 裝置連線，螢幕會出現 QR code。")
                Step(number: 2, text: "用 OM Transfer 掃描 QR code。")
                #if os(iOS) && !HOTSPOT
                Step(number: 3, text: "之後按「連線」，依提示到設定切換到相機 Wi-Fi，密碼可一鍵複製。")
                #else
                Step(number: 3, text: "之後只要按「連線」，結束時自動切回原本的 Wi-Fi。")
                #endif
            }
            .frame(maxWidth: 420, alignment: .leading)
            Button(action: pair) {
                Label("配對相機", systemImage: "qrcode.viewfinder")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(32)
    }

    struct Step: View {
        let number: Int
        let text: String
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .frame(width: 26, height: 26)
                    .background(.tint.opacity(0.15), in: Circle())
                Text(text)
            }
        }
    }
}

// MARK: - Connection

struct ConnectionPanel: View {
    @Environment(ConnectionManager.self) private var connection

    var body: some View {
        VStack(spacing: 22) {
            icon
            VStack(spacing: 6) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 460)
            actions
            if let notice = connection.notice {
                Label(notice, systemImage: "wifi")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(in: Capsule())
                    .onTapGesture { connection.dismissNotice() }
            }
            if let error = connection.storeError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(32)
        .animation(.smooth, value: connection.state)
    }

    private var cameraName: String { connection.current?.name ?? connection.cameras.first?.name ?? "相機" }

    @ViewBuilder private var icon: some View {
        let symbol = switch connection.state {
        case .connected: "camera.fill"
        case .failed: "exclamationmark.triangle"
        default: "camera"
        }
        Image(systemName: symbol)
            .font(.system(size: 56, weight: .light))
            .foregroundStyle(connection.isConnected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .symbolEffect(.pulse, isActive: connection.state.isBusy)
            .contentTransition(.symbolEffect(.replace))
    }

    private var title: String {
        switch connection.state {
        case .idle: cameraName
        case .connecting: "正在尋找\(cameraName)…"
        case .joiningWiFi: "正在加入相機 Wi-Fi…"
        case .waitingForUser: "請切換到相機 Wi-Fi"
        case .connected(let info): "已連線：\(info.model)"
        case .leaving: "正在切回原本的 Wi-Fi…"
        case .failed: "沒有連上"
        }
    }

    private var subtitle: String? {
        switch connection.state {
        case .idle: "相機：選單 › 裝置連線，再按「連線」。"
        case .joiningWiFi(let ssid): ssid
        case .waitingForUser(let c): "密碼已複製。到 Wi-Fi 設定選擇「\(c.ssid)」，第一次貼上密碼（之後 iPhone 會記住）。回到 OM Transfer 就會自動連上。"
        case .connected(let info): freeSpaceText(info).map { "記憶卡剩餘 \($0)" }
        case .failed(let why): why
        default: nil
        }
    }

    @ViewBuilder private var actions: some View {
        switch connection.state {
        case .connected:
            Button("中斷連線", role: .cancel) { Task { await connection.disconnect() } }
                .buttonStyle(.glass)
                .controlSize(.large)
        case .waitingForUser(let c):
            VStack(spacing: 14) {
                ProgressView()
                HStack(spacing: 12) {
                    Button("取消") { Task { await connection.cancel() } }
                        .buttonStyle(.glass)
                    Button {
                        Clipboard.copy(c.password)
                        WiFiSettings.open()
                    } label: {
                        Label("前往 Wi-Fi 設定", systemImage: "gear")
                    }
                    .buttonStyle(.glassProminent)
                }
                Button("再複製一次密碼") { Clipboard.copy(c.password) }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
            .onAppear { Clipboard.copy(c.password) }
        case .connecting, .joiningWiFi:
            VStack(spacing: 14) {
                ProgressView()
                Button("取消") { Task { await connection.cancel() } }
                    .buttonStyle(.glass)
            }
        case .leaving:
            ProgressView()
        case .idle, .failed:
            HStack(spacing: 12) {
                if connection.cameras.count > 1 {
                    Menu("選擇相機") {
                        ForEach(connection.cameras) { camera in
                            Button(camera.name) { Task { await connection.connect(camera) } }
                        }
                    }
                    .buttonStyle(.glass)
                }
                Button {
                    Task { await connection.connect() }
                } label: {
                    Label("連線", systemImage: "wifi").padding(.horizontal, 10)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func freeSpaceText(_ info: CameraInfo) -> String? {
        guard let bytes = info.freeSpace else { return nil }
        let text = bytes.formatted(.byteCount(style: .file))
        return info.freeSpaceIsCapped ? "超過 \(text)" : text
    }
}

struct StatusPill: View {
    @Environment(ConnectionManager.self) private var connection

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .glassEffect(in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch connection.state {
        case .connected: .green
        case .failed: .red
        case .idle: .secondary
        default: .orange
        }
    }

    private var text: String {
        switch connection.state {
        case .connected(let info): info.model
        case .connecting, .joiningWiFi, .waitingForUser: "連線中"
        case .leaving: "切回網路中"
        case .failed: "未連線"
        case .idle: "未連線"
        }
    }
}
