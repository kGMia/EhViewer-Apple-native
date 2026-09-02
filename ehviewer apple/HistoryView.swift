//
//  HistoryView.swift
//  ehviewer apple
//
//  浏览历史视图 (对齐 Android HistoryScene)
//

import SwiftUI
import EhModels
import EhDatabase
import EhSettings

struct HistoryView: View {
    @State private var vm = HistoryViewModel()
    @State private var searchText = ""
    @State private var favoritePickerGallery: GalleryInfo?

    /// 被推入父导航栈时，不创建自己的 NavigationStack，避免嵌套
    private var isPushed: Bool = false
    /// 宽屏分栏中由父视图持有详情选择。
    private var externalSelection: Binding<GalleryInfo?>?

    init(isPushed: Bool = false) {
        self.isPushed = isPushed
    }

    init(selection: Binding<GalleryInfo?>) {
        self.isPushed = true
        self.externalSelection = selection
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
                historyInnerContent
            } else {
                NavigationStack {
                    historyInnerContent
                }
            }
        }
        .task {
            await vm.loadHistory()
        }
        .sheet(item: $favoritePickerGallery) { gallery in
            FavoriteSlotPicker(
                onSelect: { slot in
                    favoritePickerGallery = nil
                    addFavorite(gallery, to: slot)
                },
                onCancel: { favoritePickerGallery = nil }
            )
            #if os(iOS)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            #endif
        }
    }

    private var historyInnerContent: some View {
        ZStack(alignment: .top) {
            Group {
                if filteredRecords.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView("暂无历史记录",
                            systemImage: "clock",
                            description: Text("浏览过的画廊会显示在这里"))
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else {
                    historyList
                }
            }
            .padding(.top, filteredRecords.isEmpty ? floatingHeaderInset : 0)

            Group {
                if isPushed {
                    ContentColumnSearchBar(text: $searchText, prompt: "搜索历史", isFloating: true) {
                        if !vm.records.isEmpty {
                            Button(role: .destructive) {
                                vm.showClearConfirm = true
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 40, height: 40)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .help("清空历史")
                            .accessibilityLabel("清空历史")
                        }
                    }
                } else {
                    #if os(macOS)
                    ContentColumnSearchBar(text: $searchText, prompt: "搜索历史", isFloating: true) {
                        if !vm.records.isEmpty {
                            Button(role: .destructive) {
                                vm.showClearConfirm = true
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 40, height: 40)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .help("清空历史")
                            .accessibilityLabel("清空历史")
                        }
                    }
                    #endif
                }
            }
            .zIndex(10)
        }
            .navigationTitle("历史")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .searchableWhen(!isPushed, text: $searchText, prompt: "搜索历史")
            .toolbar {
                if !isPushed && !vm.records.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Button("清空", role: .destructive) {
                            vm.showClearConfirm = true
                        }
                    }
                }
            }
            #endif
            .confirmationDialog("确认清空所有历史记录？", isPresented: $vm.showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    vm.clearAll()
                }
            }
    }

    private var filteredRecords: [HistoryRecord] {
        if searchText.isEmpty {
            return vm.records
        }
        let q = searchText.lowercased()
        return vm.records.filter {
            $0.title.lowercased().contains(q) ||
            ($0.titleJpn?.lowercased().contains(q) ?? false) ||
            ($0.uploader?.lowercased().contains(q) ?? false)
        }
    }

    private var historyList: some View {
        List {
            Color.clear
                .frame(height: floatingHeaderInset)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ForEach(filteredRecords, id: \.gid) { record in
                Group {
                    if let externalSelection {
                        Button {
                            externalSelection.wrappedValue = record.galleryInfo
                        } label: {
                            historyRow(record)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: record.galleryInfo) {
                            historyRow(record)
                        }
                    }
                }
                .contextMenu {
                    // 对齐 Android HistoryScene 长按菜单
                    Button {
                        Task { await GalleryActionService.shared.startDownload(gallery: record.galleryInfo) }
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }

                    Button {
                        performFavoriteToggle(record.galleryInfo)
                    } label: {
                        Label("收藏", systemImage: "heart")
                    }

                    Divider()

                    Button(role: .destructive) {
                        vm.deleteByGid(record.gid)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            .onDelete { indexSet in
                let gids = indexSet.map { filteredRecords[$0].gid }
                vm.delete(gids: gids)
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: GalleryInfo.self) { gallery in
            GalleryDetailView(gallery: gallery)
        }
    }

    private func performFavoriteToggle(_ gallery: GalleryInfo) {
        let service = GalleryActionService.shared
        if !service.isFavorited(gallery), AppSettings.shared.defaultFavSlot == -2 {
            favoritePickerGallery = gallery
        } else {
            Task { await service.toggleFavorite(gallery) }
        }
    }

    private func addFavorite(_ gallery: GalleryInfo, to slot: Int) {
        Task {
            do {
                if slot == -1 {
                    try await GalleryActionService.shared.addLocalFavorite(gallery: gallery)
                } else {
                    try await GalleryActionService.shared.addFavorite(
                        gid: gallery.gid,
                        token: gallery.token,
                        slot: slot
                    )
                }
                Haptics.success()
            } catch {
                ErrorHandler.shared.handle(error, context: "HistoryFavorite")
            }
        }
    }

    private func historyRow(_ record: HistoryRecord) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: ThumbnailURLResolver.url(
                for: record.thumb,
                fixLegacy: AppSettings.shared.fixThumbUrl,
                site: AppSettings.shared.gallerySite
            )) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(.tertiarySystemFill)
            }
            .frame(width: 52, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
                Text(record.titleJpn ?? record.title)
                    .font(.subheadline)
                    .lineLimit(2)

                Text(formattedTime(record.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocalization.locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - ViewModel

@MainActor
@Observable
class HistoryViewModel {
    var records: [HistoryRecord] = []
    var showClearConfirm = false

    func loadHistory() async {
        let limit = AppSettings.shared.historyInfoSize
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try EhDatabase.shared.getAllHistory(limit: limit)
            }.value
            guard !Task.isCancelled else { return }
            records = loaded
        } catch {
            debugLog("Failed to load history: \(error)")
        }
    }

    func delete(gids: [Int64]) {
        records.removeAll { gids.contains($0.gid) }
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    for gid in gids {
                        try EhDatabase.shared.deleteHistory(gid: gid)
                    }
                }.value
                NotificationCenter.default.post(name: .ehHistoryDidChange, object: nil)
            } catch {
                debugLog("Failed to delete history: \(error)")
                await loadHistory()
            }
        }
    }

    func deleteByGid(_ gid: Int64) {
        records.removeAll { $0.gid == gid }
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try EhDatabase.shared.deleteHistory(gid: gid)
                }.value
                NotificationCenter.default.post(name: .ehHistoryDidChange, object: nil)
            } catch {
                debugLog("Failed to delete history: \(error)")
                await loadHistory()
            }
        }
    }

    func clearAll() {
        let previousRecords = records
        records.removeAll()
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try EhDatabase.shared.clearHistory()
                }.value
                NotificationCenter.default.post(name: .ehHistoryDidChange, object: nil)
            } catch {
                debugLog("Failed to clear history: \(error)")
                records = previousRecords
            }
        }
    }

    func addRecord(_ gallery: GalleryInfo) {
        let record = gallery.historyRecord()
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try EhDatabase.shared.insertHistory(record)
                }.value
                NotificationCenter.default.post(name: .ehHistoryDidChange, object: nil)
                await loadHistory()
            } catch {
                debugLog("Failed to add history: \(error)")
            }
        }
    }
}

#Preview {
    HistoryView()
}
