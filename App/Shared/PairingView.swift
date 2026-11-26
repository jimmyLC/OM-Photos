import OMKit
import SwiftUI
import UniformTypeIdentifiers

/// Pair a camera: scan its QR code, read it from a photo, or type the Wi-Fi details.
struct PairingView: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.dismiss) private var dismiss
    let onPaired: (PairedCamera) -> Void

    enum Mode: Hashable { case scan, manual }
    @State private var mode: Mode = .scan
    @State private var ssid = ""
    @State private var password = ""
    @State private var error: String?
    @State private var importing = false
    @State private var found: CameraCredentials?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Picker("方式", selection: $mode) {
                    Text("掃描 QR code").tag(Mode.scan)
                    Text("手動輸入").tag(Mode.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)

                switch mode {
                case .scan: scanner
                case .manual: manualForm
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
            .navigationTitle("配對相機")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                readImage(result)
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 560)
        #endif
    }

    private var scanner: some View {
        VStack(spacing: 14) {
            QRScannerView { text in accept(text) }
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: 480)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(alignment: .bottom) {
                    if found != nil {
                        Label("已讀到相機資料", systemImage: "checkmark.circle.fill")
                            .padding(10)
                            .glassEffect(in: Capsule())
                            .padding(12)
                    }
                }
            Text("相機：選單 › 裝置連線，把螢幕上的 QR code 對準鏡頭。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("從照片讀取 QR code…", systemImage: "photo") { importing = true }
                .buttonStyle(.glass)
        }
    }

    private var manualForm: some View {
        Form {
            Section {
                TextField("Wi-Fi SSID", text: $ssid, prompt: Text("例如 OM-3-P-XXXXXXXX"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                SecureField("Wi-Fi Password", text: $password)
            } footer: {
                Text("在相機的「裝置連線」畫面上可以看到這兩項。")
            }
            Button("配對") { save(CameraCredentials(ssid: ssid.trimmingCharacters(in: .whitespaces), password: password)) }
                .disabled(ssid.trimmingCharacters(in: .whitespaces).isEmpty || password.count < 8)
                .keyboardShortcut(.defaultAction)
        }
        .formStyle(.grouped)
        .frame(maxWidth: 480)
    }

    private func accept(_ text: String) {
        guard found == nil else { return }
        guard let credentials = PairingCode.parse(text) else {
            error = "這不是 OM 相機的連線 QR code。"
            return
        }
        found = credentials
        save(credentials)
    }

    private func readImage(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let credentials = QRImageReader.credentials(inFile: url) {
            save(credentials)
        } else {
            error = "這張圖片裡找不到 OM 相機的 QR code。"
        }
    }

    private func save(_ credentials: CameraCredentials) {
        do {
            let camera = try connection.pair(credentials)
            onPaired(camera)
        } catch {
            found = nil
            self.error = "無法儲存相機資料：\(error.localizedDescription)"
        }
    }
}
