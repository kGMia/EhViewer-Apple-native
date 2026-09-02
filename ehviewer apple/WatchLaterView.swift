import SwiftUI
import EhModels
import EhDatabase
import EhSettings

/// 本地“稍后再看”队列。它使用与首页相同的 GalleryRow，并由数据库按
/// 加入时间排序；不依赖登录或网络收藏状态。
struct WatchLaterView: View {
    @State private var records: [WatchLaterRecord] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var showsClearConfirmation = false
    @State private var errorMessage: String?

    private var externalSelection: Binding<GalleryInfo?>?
    private var isPushed = false

    init() {}

    init(selection: Binding<GalleryInfo?>) {
        externalSelection = selection
        isPushed = true
    }

    private var filteredRecords: [WatchLaterRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.title.lowercased().contains(query)
                || ($0.titleJpn?.lowercased().contains(query) ?? false)
                || ($0.uploader?.lowercased().contains(query) ?? false)
        }
    }

    private var floatingHeaderInset: CGFloat {
        #if os(macOS)
        60
        #else
        isPushed ? 60 : 0
        #endif
    }

    var body: some View {
        Group {
            if isPushed {
                content
            } else {
                NavigationStack { content }
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .watchLaterChanged)) { _ in
            Task { await load() }
        }
    }

    private var content: some View {
        ZStack(alignment: .top) {
            Group {
                if isLoading {
                    ProgressView("加载中…")
                } else if records.isEmpty {
                    ContentUnavailableView(
                        "暂无稍后再看",
                        systemImage: "bookmark",
                        description: Text("在信息流中长按、左滑或右键点击画廊即可加入")
                    )
                } else if filteredRecords.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    recordList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, filteredRecords.isEmpty ? floatingHeaderInset : 0)

            if isPushed {
                floatingSearchBar
                    .zIndex(10)
            } else {
                #if os(macOS)
                floatingSearchBar
                    .zIndex(10)
                #endif
            }
        }
        .navigationTitle("稍后再看")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .searchableWhen(!isPushed, text: $searchText, prompt: "搜索稍后再看")
        #endif
        .confirmationDialog(
            "确认清空稍后再看？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { clearAll() }
        }
        .alert("稍后再看", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var floatingSearchBar: some View {
        ContentColumnSearchBar(text: $searchText, prompt: "搜索稍后再看", isFloating: true) {
            if !records.isEmpty {
                Button(role: .destructive) {
                    showsClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("清空稍后再看")
            }
        }
    }

    private var recordList: some View {
        List {
            Color.clear
                .frame(height: floatingHeaderInset)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .allowsHitTesting(false)

            ForEach(filteredRecords, id: \.gid) { record in
                Group {
                    if let externalSelection {
                        Button {
                            externalSelection.wrappedValue = record.galleryInfo
                        } label: {
                            row(for: record)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: record.galleryInfo) {
                            row(for: record)
                        }
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { remove(record.gid) } label: {
                        Label("从稍后再看移除", systemImage: "bookmark.slash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { remove(record.gid) } label: {
                        Label("移除", systemImage: "bookmark.slash")
                    }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: GalleryInfo.self) { gallery in
            GalleryDetailView(gallery: gallery)
        }
    }

    private func row(for record: WatchLaterRecord) -> some View {
        GalleryRow(
            gallery: record.galleryInfo,
            showJpnTitle: AppSettings.shared.showJpnTitle,
            fixThumbUrl: AppSettings.shared.fixThumbUrl,
            showRating: AppSettings.shared.showGalleryRating,
            showPages: AppSettings.shared.showGalleryPages,
            isSelected: externalSelection?.wrappedValue?.gid == record.gid
        )
    }

    private func load() async {
        isLoading = true
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try EhDatabase.shared.getAllWatchLater()
            }.value
            records = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func remove(_ gid: Int64) {
        records.removeAll { $0.gid == gid }
        Task { await GalleryActionService.shared.removeFromWatchLater(gid: gid) }
    }

    private func clearAll() {
        let oldRecords = records
        records.removeAll()
        Task {
            do {
                try await GalleryActionService.shared.clearWatchLater()
            } catch {
                records = oldRecords
                errorMessage = error.localizedDescription
            }
        }
    }
}
