import OMKit
import SwiftUI

/// Full-screen viewer: large preview, swipe or arrow keys to move, info panel.
struct ViewerView: View {
    @Environment(AppModel.self) private var model
    @State private var image: CGImage?
    @State private var showInfo = false
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat?
    @State private var drag: CGSize = .zero
    @FocusState private var focused: Bool

    private var items: [MediaItem] { model.library.filtered }
    private var index: Int? { items.firstIndex { $0.id == model.viewing } }
    private var item: MediaItem? { index.map { items[$0] } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item {
                content(item)
                    .offset(x: zoom == 1 ? drag.width : 0, y: zoom == 1 ? max(drag.height, 0) : 0)
                    .gesture(swipe)
                    .simultaneousGesture(pinch)
                    .onTapGesture(count: 2) { withAnimation(.smooth) { zoom = zoom > 1 ? 1 : 2.5 } }
                chrome(item)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.space) { close(); return .handled }
        .onKeyPress(characters: ["i"]) { _ in showInfo.toggle(); return .handled }
        .onKeyPress(keys: [.delete, .deleteForward, KeyEquivalent("\u{7F}")]) { _ in
            guard let item, !item.isProtected else { return .ignored }
            model.askDelete([item])
            return .handled
        }
        .task(id: model.viewing) { await load() }
        .environment(\.colorScheme, .dark)  // the viewer is always on black
        .transition(.opacity)
    }

    @ViewBuilder private func content(_ item: MediaItem) -> some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
            } else {
                ProgressView().tint(.white)
            }
            if item.isVideo {
                VStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 64))
                        .symbolRenderingMode(.hierarchical)
                    Text("匯入後可以播放").font(.callout)
                }
                .foregroundStyle(.white)
                .shadow(radius: 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func chrome(_ item: MediaItem) -> some View {
        VStack {
            HStack(spacing: 12) {
                Button { close() } label: { Image(systemName: "xmark").frame(width: 30, height: 30) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                VStack(spacing: 2) {
                    Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                    if let index { Text("\(index + 1) / \(items.count)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { withAnimation(.smooth) { showInfo.toggle() } } label: {
                    Image(systemName: showInfo ? "info.circle.fill" : "info.circle").frame(width: 30, height: 30)
                }
            }
            .buttonStyle(.glass)
            .padding()
            .foregroundStyle(.white)

            Spacer()

            if showInfo {
                InfoPanel(item: item, info: model.library.movieInfo[item.id])
                    .padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ViewerActions(item: item)
                .padding(.horizontal)
                .padding(.bottom, 12)
        }
        .overlay {
            HStack {
                arrow("chevron.left", enabled: (index ?? 0) > 0) { step(-1) }
                Spacer()
                arrow("chevron.right", enabled: (index ?? 0) < items.count - 1) { step(1) }
            }
            .padding(.horizontal)
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title2).frame(width: 44, height: 44) }
            .buttonStyle(.glass)
            .foregroundStyle(.white)
            .opacity(enabled ? 1 : 0)
            .disabled(!enabled)
            #if os(iOS)
            .hidden()  // iPhone/iPad: swipe instead
            #endif
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { if zoom == 1 { drag = $0.translation } }
            .onEnded { value in
                defer { withAnimation(.smooth) { drag = .zero } }
                guard zoom == 1 else { return }
                if value.translation.height > 140, abs(value.translation.width) < 100 { close() }
                else if value.translation.width < -70 { step(1) }
                else if value.translation.width > 70 { step(-1) }
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? zoom
                pinchBase = base
                zoom = min(max(base * value.magnification, 1), 6)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func step(_ delta: Int) {
        guard let index else { return }
        let next = index + delta
        guard items.indices.contains(next) else { return }
        model.viewing = items[next].id
    }

    private func close() {
        withAnimation(.smooth(duration: 0.2)) { model.viewing = nil }
    }

    private func load() async {
        guard let item else { return }
        zoom = 1
        let library = model.library
        if let cached = await library.images.cached(item.primary, size: .preview, source: library.source?.cacheKey ?? "") {
            image = cached
        } else {
            image = await library.thumbnail(for: item)  // blurry placeholder while the big one loads
            if let big = await library.preview(for: item), model.viewing == item.id { image = big }
        }
        await library.loadMovieInfo(for: item)
        // Get the neighbours ready for a quick swipe.
        if let index {
            for i in [index + 1, index - 1] where items.indices.contains(i) {
                guard !Task.isCancelled else { return }
                _ = await library.preview(for: items[i])
            }
        }
    }
}

/// Import or delete the photo that is open, with progress and results.
private struct ViewerActions: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem

    var body: some View {
        let importer = model.importer
        let imported = model.library.importedIDs.contains(item.id)
        VStack(spacing: 10) {
            if case .finished(let summary) = importer.phase {
                ImportResultView(summary: summary)
                    .glassEffect(in: Capsule())
            }
            if let message = model.deleteMessage {
                Label(message, systemImage: "trash")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(in: Capsule())
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(4))
                        model.deleteMessage = nil
                    }
            }
            if importer.isRunning {
                ImportProgressView()
                    .glassEffect(in: Capsule())
            } else if model.library.isDeleting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在從相機刪除…")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(in: Capsule())
            } else {
                HStack(spacing: 14) {
                    Button(role: .destructive) {
                        model.askDelete([item])
                    } label: {
                        Label(item.isProtected ? "受保護" : "刪除", systemImage: item.isProtected ? "lock.fill" : "trash")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .disabled(item.isProtected)

                    Button {
                        model.importFromViewer(item)
                    } label: {
                        Label(imported ? "再次匯入" : "匯入", systemImage: imported ? "checkmark.circle" : "square.and.arrow.down")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                    }
                    .brandProminent()
                }
                .controlSize(.large)
            }
        }
        .foregroundStyle(.white)
    }
}

private struct InfoPanel: View {
    let item: MediaItem
    let info: MovieInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.date.formatted(date: .complete, time: .standard)).font(.headline)
            ForEach(item.files) { file in
                HStack {
                    Text(file.name).font(.body.monospaced())
                    Spacer()
                    Text(file.size.formatted(.byteCount(style: .file))).foregroundStyle(.secondary)
                    if file.isProtected { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                }
            }
            if let info {
                HStack(spacing: 16) {
                    if let d = info.durationText { Label(d, systemImage: "clock") }
                    if let r = info.resolution { Label(r, systemImage: "aspectratio") }
                }
                .foregroundStyle(.secondary)
            }
            Text(item.primary.folder).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
