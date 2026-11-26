import OMKit
import SwiftUI

/// Right-hand side: the connection screen or the photo grid of the selected source.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(ConnectionManager.self) private var connection

    var body: some View {
        Group {
            if model.selectedSource == .wifi && connection.cameras.isEmpty && !connection.isConnected {
                // Wi-Fi chosen but no camera paired yet (e.g. used only over USB so far).
                WelcomeView(pair: { model.requestPairing = true })
            } else if model.selectedSource == .wifi && !connection.isConnected {
                ConnectionPanel()
            } else {
                LibraryContent()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LibraryContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        switch library.phase {
        case .noSource:
            ConnectionPanel()
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                Text(model.selectedSource == .wifi ? "正在讀取相機裡的檔案…" : "正在讀取記憶卡…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("讀不到檔案", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("再試一次") { Task { await library.reload() } }
                    .brandProminent()
            }
        case .loaded:
            if library.items.isEmpty {
                ContentUnavailableView("記憶卡裡沒有照片或影片", systemImage: "photo.on.rectangle.angled")
            } else if library.filtered.isEmpty {
                ContentUnavailableView("沒有符合篩選的項目", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("試試看「全部」。"))
            } else {
                PhotoGrid()
            }
        }
    }
}

// MARK: - Grid

struct PhotoGrid: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingKey.thumbnailSize) private var cellSize: Double = PhotoGrid.defaultSize
    @State private var pinchBase: Double?
    @FocusState private var focused: Bool
    #if os(iOS)
    @State private var frames = CellFrames()
    @State private var drag: (anchor: MediaItem.ID, base: Set<MediaItem.ID>, deselect: Bool)?
    #endif

    #if os(macOS)
    static let defaultSize = 150.0
    #else
    /// Like Photos: about five across on iPhone, larger on iPad.
    @MainActor static let defaultSize = UIDevice.current.userInterfaceIdiom == .pad ? 128.0 : 74.0
    #endif
    static let sizeRange = 70.0...320.0

    var body: some View {
        let library = model.library
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.6), spacing: 2)],
                          spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(library.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                PhotoCell(item: item, selected: library.selection.contains(item.id))
                                    .id(item.id)
                                    #if os(iOS)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames.map[item.id] = $0 }
                                    .onDisappear { frames.map[item.id] = nil }
                                    #endif
                            }
                        } header: {
                            DayHeader(section: section).id(section.day)
                        }
                    }
                }
                #if os(iOS)
                .coordinateSpace(.named(Self.space))
                // Hold and drag, or swipe sideways, to select many photos.
                .gesture(SelectionDragGesture(onBegan: dragBegan, onMoved: dragMoved, onEnded: { drag = nil }))
                #endif
                .padding(.bottom, 60)
            }
            .onChange(of: model.scrollTarget) { _, day in
                guard let day else { return }
                withAnimation(.smooth) { proxy.scrollTo(day, anchor: .top) }
                model.scrollTarget = nil
            }
        }
        #if os(iOS)
        .refreshable { await model.library.reload(quietly: true) }
        #endif
        .safeAreaInset(edge: .bottom) {
            // While selecting on iPhone/iPad, the bottom toolbar takes over.
            if !(model.selecting && !model.importer.isRunning && !library.isDeleting && model.deleteMessage == nil) {
                SummaryBar()
            }
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: library.selection.count)
        #endif
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = pinchBase ?? cellSize
                    pinchBase = base
                    cellSize = min(max(base * value.magnification, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
                }
                .onEnded { _ in pinchBase = nil }
        )
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.space) {
            guard let id = library.selection.first else { return .ignored }
            model.viewing = id
            return .handled
        }
        .onKeyPress(.escape) {
            library.clearSelection()
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward, KeyEquivalent("\u{7F}")]) { _ in
            guard !library.selection.isEmpty else { return .ignored }
            model.askDeleteSelected()
            return .handled
        }
        .onKeyPress(characters: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            library.selectAll()
            return .handled
        }
    }

    #if os(iOS)
    static let space = "photo-grid"

    private func dragBegan(at point: CGPoint) {
        guard let id = frames.item(at: point) else { return }
        let library = model.library
        if !model.selecting {
            model.selecting = true
            library.clearSelection()
        }
        let start = (anchor: id, base: library.selection, deselect: library.selection.contains(id))
        drag = start
        library.dragSelect(from: id, to: id, base: start.base, deselect: start.deselect)
    }

    private func dragMoved(to point: CGPoint) {
        guard let drag, let id = frames.item(at: point) else { return }
        model.library.dragSelect(from: drag.anchor, to: id, base: drag.base, deselect: drag.deselect)
    }
    #endif
}

struct DayHeader: View {
    let section: DaySection

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Days.title(section.day)).font(.headline)
            Text("\(section.items.count) 項").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct PhotoCell: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    let selected: Bool

    var body: some View {
        Thumbnail(item: item)
            .overlay(alignment: .bottomLeading) { badges }
            .overlay(alignment: .topTrailing) { marks }
            .overlay(alignment: .topLeading) {
                if model.library.importedIDs.contains(item.id) {
                    Label("已匯入", systemImage: "arrow.down.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.callout)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay {
                if selected {
                    Color.white.opacity(0.28)
                    #if os(macOS)
                    Rectangle().strokeBorder(Color.blue, lineWidth: 3)
                    #endif
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .blue)
                        .background(Circle().fill(.white).padding(1))
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { tap() }
            #if os(macOS)  // on iPhone and iPad a long press starts drag selection instead
            .contextMenu {
                Button("匯入", systemImage: "square.and.arrow.down") {
                    selectForMenu()
                    model.askImportSelected()
                }
                Button("從相機刪除…", systemImage: "trash", role: .destructive) {
                    selectForMenu()
                    model.askDeleteSelected()
                }
            }
            #endif
            .accessibilityLabel("\(item.badge)，\(item.date.formatted(date: .abbreviated, time: .shortened))")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .task(id: item.id) { await model.library.loadMovieInfo(for: item) }
    }

    private var badges: some View {
        HStack(spacing: 4) {
            Text(item.badge)
            if item.isVideo, let duration = model.library.movieInfo[item.id]?.durationText {
                Image(systemName: "play.fill").imageScale(.small)
                Text(duration).monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.5), in: Capsule())
        .padding(5)
    }

    private var marks: some View {
        HStack(spacing: 4) {
            if item.isProtected {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.5), in: Circle())
            }
        }
        .padding(5)
    }

    /// Right-click acts on the selection; on an unselected item it acts on that item only.
    private func selectForMenu() {
        if !model.library.selection.contains(item.id) {
            model.library.select(item, extend: false, toggle: false)
        }
    }

    private func tap() {
        let library = model.library
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        if NSApp.currentEvent?.clickCount == 2 {
            model.viewing = item.id
            return
        }
        library.select(item, extend: flags.contains(.shift), toggle: flags.contains(.command))
        #else
        if model.selecting {
            library.select(item, extend: false, toggle: true)
        } else {
            model.viewing = item.id
        }
        #endif
    }
}

struct Thumbnail: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if failed {
                    Image(systemName: item.isVideo ? "video" : "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: item.id) {
                if let img = await model.library.thumbnail(for: item) {
                    withAnimation(.easeOut(duration: 0.15)) { image = img }
                } else if !Task.isCancelled {
                    failed = true
                }
            }
    }
}

/// Bottom bar: counts and import buttons, the import progress, or the result.
struct SummaryBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        let importer = model.importer
        Group {
            switch importer.phase {
            case .running:
                ImportProgressView()
            case .finished(let summary) where library.selection.isEmpty && !library.isDeleting && model.deleteMessage == nil:
                ImportResultView(summary: summary)
            case _ where library.isDeleting:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在從相機刪除…")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            case _ where model.deleteMessage != nil:
                HStack(spacing: 10) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                    Text(model.deleteMessage ?? "")
                    Button { model.deleteMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("關閉")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .task {
                    try? await Task.sleep(for: .seconds(6))
                    model.deleteMessage = nil
                }
            default:
                HStack(spacing: 12) {
                    if library.selection.isEmpty {
                        Text("\(library.filtered.count) 個項目")
                            .foregroundStyle(.secondary)
                        if model.newItemCount > 0 {
                            Button {
                                model.askImportNew()
                            } label: {
                                Label("匯入所有新項目（\(model.newItemCount)）", systemImage: "square.and.arrow.down")
                            }
                            .brandProminent()
                        } else if !library.items.isEmpty {
                            Label("全部已匯入", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    } else {
                        Text("已選 \(library.selectedItems.count) 項 · \(library.selectedSize.formatted(.byteCount(style: .file)))")
                        Button("取消選取") { library.clearSelection() }
                            .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            model.askDeleteSelected()
                        } label: {
                            Label("刪除", systemImage: "trash")
                        }
                        .buttonStyle(.glass)
                        .disabled(library.isDeleting)
                        Button {
                            model.askImportSelected()
                        } label: {
                            Label("匯入", systemImage: "square.and.arrow.down")
                        }
                        .brandProminent()
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
            }
        }
        .font(.callout)
        .glassEffect(in: Capsule())
        .padding(.horizontal)
        .padding(.bottom, 10)
        .animation(.smooth, value: library.selection.count)
        .animation(.smooth, value: importer.phase)
    }
}

struct ImportProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let importer = model.importer
        HStack(spacing: 12) {
            ProgressView(value: importer.fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在匯入 \(min(importer.doneItems + 1, importer.totalItems)) / \(importer.totalItems)")
                    .font(.callout.weight(.medium))
                Text(detail(importer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(minWidth: 200, alignment: .leading)
            Button("取消", role: .cancel) { importer.cancel() }
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func detail(_ importer: Importer) -> String {
        var parts = [importer.currentName]
        parts.append("\(Int(importer.fraction * 100))%")
        if let remaining = importer.remaining {
            parts.append("剩約 " + Duration.seconds(max(remaining, 1)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ImportResultView: View {
    @Environment(AppModel.self) private var model
    let summary: ImportSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if summary.imported > 0 {
                Button("顯示") { ImportSettings.reveal(summary.location) }
                    .buttonStyle(.glass)
            }
            if !model.importer.failedItems.isEmpty {
                Button("重試") { model.retryFailed() }
                    .brandProminent()
            }
            Button {
                model.importer.dismissSummary()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("關閉")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var icon: String {
        if summary.error != nil || !summary.failed.isEmpty { return "exclamationmark.triangle.fill" }
        return summary.cancelled ? "stop.circle" : "checkmark.circle.fill"
    }

    private var color: Color {
        if summary.error != nil || !summary.failed.isEmpty { return .orange }
        return summary.cancelled ? .secondary : .green
    }

    private var title: String {
        if summary.cancelled { return "已取消，匯入了 \(summary.imported) 項" }
        if summary.imported == 0, let error = summary.error { return error }
        if summary.failed.isEmpty { return "已匯入 \(summary.imported) 項" }
        return "已匯入 \(summary.imported) 項，\(summary.failed.count) 項失敗"
    }

    private var detail: String? {
        if !summary.failed.isEmpty {
            return "失敗：" + summary.failed.prefix(4).joined(separator: "、") + (summary.failed.count > 4 ? "…" : "")
        }
        guard summary.imported > 0 else { return nil }
        let speed = summary.seconds > 0 ? Double(summary.bytes) / summary.seconds : 0
        return "\(summary.bytes.formatted(.byteCount(style: .file))) · 平均 \(Int64(speed).formatted(.byteCount(style: .file)))/秒"
    }
}
