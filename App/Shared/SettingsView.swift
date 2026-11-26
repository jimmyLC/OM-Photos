import OMKit
import SwiftUI

struct SettingsView: View {
    @Environment(ConnectionManager.self) private var connection
    @AppStorage(SettingKey.autoDisconnect) private var autoDisconnect = false
    @AppStorage(SettingKey.powerOffWhenDone) private var powerOffWhenDone = true
    @State private var confirmForget: PairedCamera?
    @State private var error: String?

    var body: some View {
        Form {
            CameraInfoSection()

            Section {
                if connection.cameras.isEmpty {
                    Text("還沒有配對的相機").foregroundStyle(.secondary)
                }
                ForEach(connection.cameras) { camera in
                    CameraRow(camera: camera) { name in
                        do { try connection.rename(camera, to: name) } catch { self.error = error.localizedDescription }
                    } forget: {
                        confirmForget = camera
                    }
                }
            } header: {
                Text("已配對的相機")
            } footer: {
                Text("相機的 Wi-Fi 密碼存在鑰匙圈，並透過 iCloud 鑰匙圈同步到你的其他裝置。")
            }

            ImportSettingsSection()

            Section {
                Toggle("匯入完成後自動中斷並切回原本的 Wi-Fi", isOn: $autoDisconnect)
                if !connection.switchesWiFiAutomatically {
                    Toggle("中斷連線時關閉相機", isOn: $powerOffWhenDone)
                        .onChange(of: powerOffWhenDone) { _, on in connection.powerOffWhenDone = on }
                }
            } header: {
                Text("連線")
            } footer: {
                if !connection.switchesWiFiAutomatically {
                    Text("相機關機後 Wi-Fi 消失，iPhone 會自動回到原本的網路。")
                }
            }

            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("設定")
        .confirmationDialog("移除「\(confirmForget?.name ?? "")」？", isPresented: .init(
            get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } }
        ), titleVisibility: .visible, presenting: confirmForget) { camera in
            Button("移除", role: .destructive) {
                Task {
                    do { try await connection.forget(camera) } catch { self.error = error.localizedDescription }
                }
            }
        } message: { _ in
            Text("所有裝置上都會移除這台相機的配對資料，之後要重新掃描 QR code。相機裡的照片不受影響。")
        }
    }
}

/// The camera or card in use, plus the connection actions on iPhone and iPad.
private struct CameraInfoSection: View {
    @Environment(AppModel.self) private var model
    @Environment(ConnectionManager.self) private var connection
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var details: CameraDetails?

    private var key: String {
        let source = model.library.phase == .loaded ? model.library.source?.cacheKey ?? "" : ""
        return source + "|\(model.library.items.count)"
    }

    var body: some View {
        Section("相機資訊") {
            if model.library.phase != .loaded || model.library.source == nil {
                Text("連上相機或插入記憶卡後顯示").foregroundStyle(.secondary)
            } else if let d = details {
                row("型號", d.model)
                row("序號", d.serial)
                row("韌體版本", d.firmware)
                row("鏡頭", d.lens)
                row("連線方式", model.library.source?.kind == .usb ? "USB 記憶卡" : "Wi-Fi")
                row("記憶卡剩餘", d.freeSpace.map { (d.freeSpaceIsCapped ? "超過 " : "") + bytes($0) })
                row("記憶卡容量", d.capacity.map(bytes))
                row("檔案數", d.fileCount.map { "\($0)" })
            } else {
                ProgressView()
            }
        }
        .task(id: key) {
            guard model.library.phase == .loaded, let source = model.library.source, !model.importer.isRunning else { return }
            details = await source.details(files: model.library.items.flatMap(\.files))
        }

        #if os(iOS)
        Section {
            if model.selectedSource == .wifi, connection.isConnected {
                Button("中斷連線", systemImage: "wifi.slash") {
                    Task { await connection.disconnect() }
                    dismiss()
                }
                .disabled(model.importer.isRunning)
            }
            Button("配對新相機", systemImage: "qrcode.viewfinder") {
                model.requestPairing = true
                dismiss()
            }
        }
        #endif
    }

    private func bytes(_ n: Int64) -> String { n.formatted(.byteCount(style: .file)) }

    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        if let value {
            LabeledContent(title) {
                Text(value).textSelection(.enabled)
            }
        }
    }
}

private struct ImportSettingsSection: View {
    @AppStorage(SettingKey.autoImport) private var autoImport = false
    @State private var kind = ImportSettings.kind
    @State private var folderName = ImportSettings.folder?.path
    @State private var picking = false

    var body: some View {
        Section {
            Picker("匯入到", selection: $kind) {
                ForEach(ImportSettings.Kind.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: kind) { _, k in ImportSettings.kind = k }
            if kind == .folder {
                HStack {
                    Text(folderName.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "尚未選擇（匯入時會詢問）")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("選擇…") { choose() }
                }
            }
            Toggle("連上相機就自動匯入新項目", isOn: $autoImport)
        } header: {
            Text("匯入")
        } footer: {
            #if os(macOS)
            Text(kind == .folder ? "每次匯入前都會詢問資料夾，預設是上次選的。檔案直接放進資料夾，不另建子資料夾。" : "RAW+JPG 會存成同一張照片。")
            #else
            Text(kind == .folder ? "檔案直接放進選擇的資料夾。" : "RAW+JPG 會存成同一張照片。")
            #endif
        }
        #if os(iOS)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                ImportSettings.setFolder(url)
                folderName = url.path
            }
        }
        #endif
    }

    private func choose() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "選擇"
        panel.directoryURL = ImportSettings.folder
        if panel.runModal() == .OK, let url = panel.url {
            ImportSettings.setFolder(url)
            folderName = url.path
        }
        #else
        picking = true
        #endif
    }
}

private struct CameraRow: View {
    let camera: PairedCamera
    let rename: (String) -> Void
    let forget: () -> Void
    @State private var name = ""

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                TextField("名稱", text: $name)
                    .onSubmit { rename(name) }
                    .font(.body.weight(.medium))
                Text(camera.credentials.ssid)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("移除", role: .destructive, action: forget)
                .buttonStyle(.borderless)
        }
        .onAppear { name = camera.name }
        .onChange(of: camera.name) { _, new in name = new }
    }
}
