//
//  FavoritesView.swift
//  ehviewer apple
//
//  收藏视图 — 全部 + 10个收藏夹 + 本地收藏 (对齐 Android FavoritesActivity)
//

import SwiftUI
import EhModels
import EhSettings
import EhDatabase
import EhDownload
import EhAPI

private extension FavoriteMetadataSort {
    var title: String {
        switch self {
        case .serverOrder: AppLocalization.localized("网站顺序")
        case .uploadedAt: AppLocalization.localized("上传时间")
        case .addedAt: AppLocalization.localized("加入顺序")
        case .rating: AppLocalization.localized("评分")
        }
    }

    var systemImage: String {
        switch self {
        case .serverOrder: "list.number"
        case .uploadedAt: "clock"
        case .addedAt: "heart.text.clipboard"
        case .rating: "star"
        }
    }
}

struct FavoritesView: View {
    /// selectedSlot: -2 = 本地收藏, -1 = 全部, 0-9 = 云收藏夹
    /// 收藏分类按窗口恢复，避免返回收藏页时总是跳回“全部”。
    @SceneStorage("favorites.selectedSlot") private var selectedSlot = -1
    @State private var searchText = ""
    @State private var localFavorites: [LocalFavoriteRecord] = []
    @State private var isLoadingLocal = false
    @State private var localFavoritesTask: Task<Void, Never>?
    @State private var onlineFavoritesViewModel = GalleryListViewModel()
    @State private var showPageNumberDialog = false
    @State private var pageNumberInput = ""
    @State private var favoriteIndex = FavoriteMetadataIndexService.shared
    @State private var indexedFavorites: [FavoriteMetadataRecord] = []
    @State private var indexedFavoritesTask: Task<Void, Never>?
    @AppStorage("favorites.metadataSort") private var metadataSortRaw = FavoriteMetadataSort.serverOrder.rawValue

    // MARK: - 批量操作状态 (对齐 Android FavoritesScene 选择模式)
    @State private var isSelectMode = false
    @State private var selectedGids: Set<Int64> = []
    @State private var showMoveSheet = false
    @State private var showDeleteConfirm = false
    @State private var isBatchProcessing = false

    /// 外部选择绑定（嵌入模式）
    private var externalSelection: Binding<GalleryInfo?>?
    @State private var waterfallLayoutGeneration = 0
    private var isEmbedded: Bool { externalSelection != nil }
    private var isPushed = false

    init() {
        self.externalSelection = nil
    }

    init(isPushed: Bool) {
        self.externalSelection = nil
        self.isPushed = isPushed
    }

    init(selection: Binding<GalleryInfo?>) {
        self.externalSelection = selection
    }

    private var favoriteNames: [String] {
        (0..<10).map { AppSettings.shared.favCatName($0) }
    }

    var body: some View {
        Group {
            if isEmbedded {
                ZStack(alignment: .top) {
                    if selectedSlot == -2 {
                        localFavoritesContent
                    } else if selectedSlot == -1 {
                        // "全部": 合并本地收藏 + 在线收藏 (对齐 Android: 全部包含所有来源)
                        allFavoritesContent(embedded: true)
                    } else if usesMetadataIndex {
                        indexedFavoritesContent(topInset: floatingHeaderInset)
                    } else {
                        GalleryListView(
                            mode: .favorites(slot: selectedSlot),
                            selection: externalSelection!,
                            searchKeyword: searchText.isEmpty ? nil : searchText,
                            showsSearchControls: false,
                            contentTopInset: floatingHeaderInset,
                            persistentViewModel: onlineFavoritesViewModel
                        )
                            .id(selectedSlot)
                    }

                    favoritesFloatingHeader
                        .zIndex(10)
                }
                .navigationTitle("收藏")
                .onChange(of: searchText) { _, _ in
                    if selectedSlot == -2 || selectedSlot == -1 { loadLocalFavorites() }
                    if selectedSlot != -2 { loadIndexedFavorites() }
                }
            } else if isPushed {
                standaloneFavoritesContent
            } else if usesMetadataIndex {
                indexedFavoritesContent(topInset: floatingHeaderInset)
            } else {
                NavigationStack {
                    standaloneFavoritesContent
                }
            }
        }
        .alert("跳转到收藏页", isPresented: $showPageNumberDialog) {
            TextField("页码", text: $pageNumberInput)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("取消", role: .cancel) { pageNumberInput = "" }
            Button("跳转") { jumpToEnteredPage() }
        } message: {
            if maximumOnlinePage > 0 {
                Text("输入页码（已知范围 1–\(maximumOnlinePage)）")
            } else {
                Text("输入要跳转到的页码")
            }
        }
        .onChange(of: selectedSlot) { _, slot in
            selectedGids.removeAll()
            selectedGalleryForNewSlot(slot)
            loadIndexedFavorites()
        }
        .onChange(of: metadataSortRaw) { _, _ in loadIndexedFavorites() }
        .onChange(of: favoriteIndex.revision) { _, _ in loadIndexedFavorites() }
        .task {
            loadIndexedFavorites()
            await favoriteIndex.syncIfNeeded()
        }
    }

    private var standaloneFavoritesContent: some View {
        ZStack(alignment: .top) {
            if selectedSlot == -2 {
                localFavoritesContent
            } else if selectedSlot == -1 {
                // "全部": 合并本地收藏 + 在线收藏
                allFavoritesContent(embedded: false)
            } else {
                GalleryListView(
                    mode: .favorites(slot: selectedSlot),
                    searchKeyword: searchText.isEmpty ? nil : searchText,
                    showsSearchControls: false,
                    contentTopInset: floatingHeaderInset,
                    persistentViewModel: onlineFavoritesViewModel
                )
                .id(selectedSlot)
            }

            favoritesFloatingHeader
                .zIndex(10)
        }
        .navigationTitle("收藏")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .searchableWhen(
            !isPushed,
            text: $searchText,
            prompt: AppLocalization.localized(selectedSlot == -2 ? "搜索本地收藏" : "搜索收藏")
        )
        #endif
        .onChange(of: searchText) { _, _ in
            if selectedSlot == -2 || selectedSlot == -1 { loadLocalFavorites() }
            if selectedSlot != -2 { loadIndexedFavorites() }
        }
        #if os(iOS)
        .toolbar {
            // 本地收藏批量操作工具栏 (对齐 Android FavoritesScene FAB)
            if !isPushed,
               (selectedSlot == -2 || selectedSlot == -1),
               !localFavorites.isEmpty {
                ToolbarItem(placement: .automatic) {
                    localBatchToolbar
                }
            }
        }
        #endif
    }

    private var favoritesSearchBar: some View {
        ContentColumnSearchBar(
            text: $searchText,
            prompt: AppLocalization.localized(selectedSlot == -2 ? "搜索本地收藏" : "搜索收藏"),
            isFloating: true
        ) {
            Button { toggleDisplayMode() } label: {
                Image(systemName: AppSettings.shared.listMode == .list ? "rectangle.grid.2x2" : "list.bullet")
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(AppLocalization.localized(AppSettings.shared.listMode == .list ? "切换到瀑布流" : "切换到列表"))
            .accessibilityLabel(AppLocalization.localized(AppSettings.shared.listMode == .list ? "切换到瀑布流" : "切换到列表"))

            if selectedSlot != -2 {
                Menu {
                    ForEach(FavoriteMetadataSort.allCases, id: \.self) { sort in
                        Button {
                            metadataSortRaw = sort.rawValue
                        } label: {
                            Label(sort.title, systemImage: metadataSort == sort ? "checkmark" : sort.systemImage)
                        }
                    }
                    Divider()
                    Button {
                        favoriteIndex.forceSync()
                    } label: {
                        Label("更新离线索引", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(favoriteIndex.isSyncing)
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("全局排序：\(metadataSort.title)")
            }

            if selectedSlot != -2 {
                Menu {
                    Button {
                        pageNumberInput = ""
                        showPageNumberDialog = true
                    } label: {
                        Label("跳转到页码", systemImage: "number")
                    }
                    Button {
                        jumpToLastPage()
                    } label: {
                        Label("最后一页", systemImage: "arrow.right.to.line")
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("跳页")
            }

            if (selectedSlot == -2 || selectedSlot == -1) && !localFavorites.isEmpty {
                localBatchToolbar
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
    }

    private func toggleDisplayMode() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            AppSettings.shared.listMode = AppSettings.shared.listMode == .list ? .grid : .list
        }
    }

    private var metadataSort: FavoriteMetadataSort {
        FavoriteMetadataSort(rawValue: metadataSortRaw) ?? .serverOrder
    }

    private var usesMetadataIndex: Bool {
        selectedSlot != -2 && metadataSort != .serverOrder
    }

    private var maximumOnlinePage: Int {
        guard selectedSlot >= -1 else { return 0 }
        let count: Int
        if selectedSlot >= 0 {
            count = AppSettings.shared.favCount(selectedSlot)
        } else {
            count = (0..<10).reduce(into: 0) { result, slot in
                result += AppSettings.shared.favCount(slot)
            }
        }
        let estimatedPages = (count + 49) / 50
        return max(
            max(onlineFavoritesViewModel.totalPages, estimatedPages),
            onlineFavoritesViewModel.galleries.isEmpty ? 0 : 1
        )
    }

    private func jumpToEnteredPage() {
        defer { pageNumberInput = "" }
        guard selectedSlot >= -1,
              let page = Int(pageNumberInput),
              page >= 1
        else { return }

        onlineFavoritesViewModel.favSearchKeyword = searchText.isEmpty ? nil : searchText
        onlineFavoritesViewModel.goToFavoritesPage(
            page - 1,
            mode: .favorites(slot: selectedSlot),
            knownTotalPages: max(maximumOnlinePage, page)
        )
    }

    private func jumpToLastPage() {
        guard selectedSlot >= -1 else { return }
        onlineFavoritesViewModel.favSearchKeyword = searchText.isEmpty ? nil : searchText
        onlineFavoritesViewModel.goToLastFavoritesPage(
            mode: .favorites(slot: selectedSlot),
            knownTotalPages: maximumOnlinePage
        )
    }

    private func selectedGalleryForNewSlot(_ slot: Int) {
        externalSelection?.wrappedValue = nil
        guard slot >= -1 else { return }
        guard metadataSort == .serverOrder else { return }
        onlineFavoritesViewModel.favSearchKeyword = searchText.isEmpty ? nil : searchText
        onlineFavoritesViewModel.refresh(mode: .favorites(slot: slot))
    }

    private var favoritesFloatingHeader: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            favoritesSearchBar
            #else
            if isEmbedded || isPushed { favoritesSearchBar }
            #endif
            slotPicker
        }
    }

    private var floatingHeaderInset: CGFloat {
        #if os(macOS)
        104
        #else
        (isEmbedded || isPushed) ? 104 : 44
        #endif
    }

    // MARK: - 本地收藏批量操作工具栏 (对齐 Android FavoritesScene FAB)

    private var localBatchToolbar: some View {
        Menu {
            if isSelectMode {
                Button {
                    if selectedGids.count == localFavorites.count {
                        selectedGids.removeAll()
                    } else {
                        selectedGids = Set(localFavorites.map { $0.gid })
                    }
                } label: {
                    Label(AppLocalization.localized(selectedGids.count == localFavorites.count ? "取消全选" : "全选"),
                          systemImage: selectedGids.count == localFavorites.count ? "square" : "checkmark.square")
                }

                Divider()

                Button {
                    batchDownloadSelected()
                } label: {
                    Label("批量下载 (\(selectedGids.count))", systemImage: "arrow.down.circle")
                }
                .disabled(selectedGids.isEmpty)

                Button {
                    showMoveSheet = true
                } label: {
                    Label("移动到云收藏 (\(selectedGids.count))", systemImage: "arrow.right.circle")
                }
                .disabled(selectedGids.isEmpty)

                Divider()

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除 (\(selectedGids.count))", systemImage: "trash")
                }
                .disabled(selectedGids.isEmpty)

                Divider()

                Button {
                    isSelectMode = false
                    selectedGids.removeAll()
                } label: {
                    Label("退出选择", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    isSelectMode = true
                    selectedGids.removeAll()
                } label: {
                    Label("批量操作", systemImage: "checkmark.circle")
                }
            }
        } label: {
            Image(systemName: isSelectMode ? "checkmark.circle.fill" : "ellipsis.circle")
        }
        .sheet(isPresented: $showMoveSheet) {
            FavoriteSlotPicker(
                onSelect: { slot in
                    showMoveSheet = false
                    guard slot >= 0 else { return }
                    batchMoveToCloud(slot: slot)
                },
                onCancel: { showMoveSheet = false },
                showLocalOption: false
            )
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
        }
        .confirmationDialog("确认删除 \(selectedGids.count) 个收藏？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                batchDeleteSelected()
            }
        }
    }

    // MARK: - 本地收藏内容 (对齐 Android FAV_CAT_LOCAL)

    private var localFavoritesContent: some View {
        Group {
            if isLoadingLocal {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if localFavorites.isEmpty {
                ContentUnavailableView("暂无本地收藏", systemImage: "heart.slash", description: Text("在画廊详情页点击 ♡ 添加本地收藏"))
                    .padding(.top, floatingHeaderInset)
            } else {
                if AppSettings.shared.listMode == .grid {
                    localFavoritesWaterfall
                } else {
                    List {
                    Color.clear
                        .frame(height: floatingHeaderInset)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    ForEach(localFavorites, id: \.gid) { record in
                        if isSelectMode {
                            Button {
                                if selectedGids.contains(record.gid) {
                                    selectedGids.remove(record.gid)
                                } else {
                                    selectedGids.insert(record.gid)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedGids.contains(record.gid) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selectedGids.contains(record.gid) ? Color.accentColor : .secondary)
                                    localFavoriteRow(record)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            if let externalSelection {
                                Button {
                                    externalSelection.wrappedValue = record.galleryInfo
                                } label: {
                                    localFavoriteRow(record)
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    GalleryDetailView(gallery: record.galleryInfo)
                                } label: {
                                    localFavoriteRow(record)
                                }
                            }
                        }
                    }
                    .onDelete { indexSet in
                        if !isSelectMode {
                            deleteLocalFavorites(at: indexSet)
                        }
                    }
                }
                .listStyle(.plain)
                }
            }
        }
        .onAppear { loadLocalFavorites() }
        .onChange(of: selectedSlot) { _, newSlot in
            if newSlot == -2 || newSlot == -1 { loadLocalFavorites() }
            isSelectMode = false
            selectedGids.removeAll()
        }
        .overlay {
            if isBatchProcessing {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .overlay {
                        ProgressView("处理中...")
                            .padding()
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
            }
        }
    }

    private var localFavoritesWaterfall: some View {
        let recordsByGID = Dictionary(
            localFavorites.map { ($0.gid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return GalleryWaterfallView(
            galleries: localFavorites.map(\.galleryInfo),
            topInset: floatingHeaderInset,
            scrollPosition: .constant(nil),
            showsContinueReading: false,
            isLoading: isLoadingLocal,
            hasMore: false,
            onRefresh: { loadLocalFavorites() },
            onLoadMore: {}
        ) { gallery in
            if let record = recordsByGID[gallery.gid] {
                localFavoriteWaterfallItem(record)
            }
        }
    }

    @ViewBuilder
    private func localFavoriteWaterfallItem(_ record: LocalFavoriteRecord) -> some View {
        let card = GalleryWaterfallCard(
            gallery: record.galleryInfo,
            showJpnTitle: AppSettings.shared.showJpnTitle,
            fixThumbUrl: AppSettings.shared.fixThumbUrl,
            showRating: AppSettings.shared.showGalleryRating,
            showPages: AppSettings.shared.showGalleryPages,
            isSelected: selectedGids.contains(record.gid)
        )

        if isSelectMode {
            Button {
                if selectedGids.contains(record.gid) {
                    selectedGids.remove(record.gid)
                } else {
                    selectedGids.insert(record.gid)
                }
            } label: {
                card
            }
            .buttonStyle(.plain)
        } else if let externalSelection {
            Button {
                externalSelection.wrappedValue = record.galleryInfo
            } label: {
                card
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                GalleryDetailView(gallery: record.galleryInfo)
            } label: {
                card
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 全部收藏 (本地 + 在线合并)

    @ViewBuilder
    private func allFavoritesContent(embedded: Bool) -> some View {
        VStack(spacing: 0) {
            // 本地收藏区块 (折叠式, 对齐 Android: 全部分类下显示所有来源)
            if !localFavorites.isEmpty {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: floatingHeaderInset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    HStack {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                        Text("本地收藏 (\(localFavorites.count))")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))

                    ForEach(localFavorites.prefix(5), id: \.gid) { record in
                        if let externalSelection {
                            Button {
                                externalSelection.wrappedValue = record.galleryInfo
                            } label: {
                                localFavoriteRow(record)
                                    .padding(.horizontal, 16)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                GalleryDetailView(gallery: record.galleryInfo)
                            } label: {
                                localFavoriteRow(record)
                                    .padding(.horizontal, 16)
                            }
                            .buttonStyle(.plain)
                        }
                        Divider().padding(.leading, 104)
                    }

                    if localFavorites.count > 5 {
                        Button {
                            selectedSlot = -2  // 切换到本地收藏查看全部
                        } label: {
                            Text("查看全部 \(localFavorites.count) 个本地收藏")
                                .font(.subheadline)
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                }
            }

            // 在线收藏
            if usesMetadataIndex {
                indexedFavoritesContent(topInset: localFavorites.isEmpty ? floatingHeaderInset : 0)
            } else if embedded, let sel = externalSelection {
                GalleryListView(
                    mode: .favorites(slot: -1),
                    selection: sel,
                    searchKeyword: searchText.isEmpty ? nil : searchText,
                    showsSearchControls: false,
                    contentTopInset: localFavorites.isEmpty ? floatingHeaderInset : 0,
                    persistentViewModel: onlineFavoritesViewModel
                )
            } else {
                GalleryListView(
                    mode: .favorites(slot: -1),
                    searchKeyword: searchText.isEmpty ? nil : searchText,
                    showsSearchControls: false,
                    contentTopInset: localFavorites.isEmpty ? floatingHeaderInset : 0,
                    persistentViewModel: onlineFavoritesViewModel
                )
            }
        }
        .onAppear { loadLocalFavorites() }
    }

    @ViewBuilder
    private func indexedFavoritesContent(topInset: CGFloat) -> some View {
        if indexedFavorites.isEmpty {
            ContentUnavailableView {
                Label(
                    AppLocalization.localized(favoriteIndex.isSyncing ? "正在建立收藏索引" : "暂无离线收藏索引"),
                    systemImage: favoriteIndex.isSyncing ? "arrow.triangle.2.circlepath" : "externaldrive"
                )
            } description: {
                Text(
                    favoriteIndex.isSyncing
                        ? AppLocalization.format("已同步 %lld 页", Int64(favoriteIndex.completedPages))
                        : AppLocalization.localized("请联网后更新离线索引")
                )
            } actions: {
                if !favoriteIndex.isSyncing {
                    Button("立即同步") { favoriteIndex.forceSync() }
                }
            }
            .padding(.top, topInset)
        } else if AppSettings.shared.listMode == .grid {
            GalleryWaterfallView(
                galleries: indexedFavorites.map(\.galleryInfo),
                topInset: topInset,
                scrollPosition: .constant(nil),
                showsContinueReading: false,
                isLoading: favoriteIndex.isSyncing,
                hasMore: false,
                layoutRevision: waterfallLayoutGeneration,
                onRefresh: {
                    await favoriteIndex.syncIfNeeded(force: true)
                    loadIndexedFavorites()
                },
                onLoadMore: {}
            ) { gallery in
                indexedFavoriteDestination(gallery)
            }
        } else {
            List {
                if topInset > 0 {
                    Color.clear
                        .frame(height: topInset)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .allowsHitTesting(false)
                }
                ForEach(indexedFavorites, id: \.gid) { record in
                    indexedFavoriteDestination(record.galleryInfo)
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .refreshable {
                await favoriteIndex.syncIfNeeded(force: true)
                loadIndexedFavorites()
            }
        }
    }

    @ViewBuilder
    private func indexedFavoriteDestination(_ gallery: GalleryInfo) -> some View {
        let card = Group {
            if AppSettings.shared.listMode == .grid {
                GalleryWaterfallCard(
                    gallery: gallery,
                    showJpnTitle: AppSettings.shared.showJpnTitle,
                    fixThumbUrl: AppSettings.shared.fixThumbUrl,
                    showRating: AppSettings.shared.showGalleryRating,
                    showPages: AppSettings.shared.showGalleryPages,
                    isSelected: externalSelection?.wrappedValue?.gid == gallery.gid
                )
            } else {
                GalleryRow(
                    gallery: gallery,
                    showJpnTitle: AppSettings.shared.showJpnTitle,
                    fixThumbUrl: AppSettings.shared.fixThumbUrl,
                    showRating: AppSettings.shared.showGalleryRating,
                    showPages: AppSettings.shared.showGalleryPages,
                    isSelected: externalSelection?.wrappedValue?.gid == gallery.gid
                )
            }
        }

        if let externalSelection {
            Button { externalSelection.wrappedValue = gallery } label: { card }
                .buttonStyle(.plain)
        } else {
            NavigationLink { GalleryDetailView(gallery: gallery) } label: { card }
                .buttonStyle(.plain)
        }
    }

    private func loadIndexedFavorites() {
        guard selectedSlot != -2 else { return }
        indexedFavoritesTask?.cancel()
        let site = AppSettings.shared.gallerySite.rawValue
        let slot: Int? = selectedSlot >= 0 ? selectedSlot : nil
        let query = searchText
        let sort = metadataSort
        indexedFavoritesTask = Task {
            let records = (try? await Task.detached(priority: .userInitiated) {
                try EhDatabase.shared.fetchFavoriteMetadata(
                    site: site,
                    slot: slot,
                    query: query,
                    sort: sort
                )
            }.value) ?? []
            guard !Task.isCancelled,
                  site == AppSettings.shared.gallerySite.rawValue,
                  query == searchText,
                  sort == metadataSort
            else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                indexedFavorites = records
                waterfallLayoutGeneration &+= 1
            }
        }
    }

    private func localFavoriteRow(_ record: LocalFavoriteRecord) -> some View {
        GalleryRow(
            gallery: record.galleryInfo,
            showJpnTitle: AppSettings.shared.showJpnTitle,
            fixThumbUrl: AppSettings.shared.fixThumbUrl,
            showRating: AppSettings.shared.showGalleryRating,
            showPages: AppSettings.shared.showGalleryPages,
            isSelected: selectedGids.contains(record.gid)
        )
    }

    private func loadLocalFavorites() {
        localFavoritesTask?.cancel()
        isLoadingLocal = true
        let query = searchText
        localFavoritesTask = Task {
            do {
                let records = try await Task.detached(priority: .userInitiated) {
                    if query.isEmpty {
                        return try EhDatabase.shared.getAllLocalFavorites()
                    }
                    return try EhDatabase.shared.searchLocalFavorites(query: query)
                }.value
                guard !Task.isCancelled, query == searchText else { return }
                localFavorites = records
                isLoadingLocal = false
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingLocal = false
            }
        }
    }

    // MARK: - 批量操作 (对齐 Android FavoritesScene)

    private func batchDownloadSelected() {
        let selected = localFavorites.filter { selectedGids.contains($0.gid) }
        Task {
            for record in selected {
                await GalleryActionService.shared.startDownload(gallery: record.galleryInfo)
            }
        }
        isSelectMode = false
        selectedGids.removeAll()
    }

    private func batchMoveToCloud(slot: Int) {
        let selected = localFavorites.filter { selectedGids.contains($0.gid) }
        isBatchProcessing = true
        Task {
            for record in selected {
                try? await GalleryActionService.shared.addFavorite(gid: record.gid, token: record.token, slot: slot)
                try? EhDatabase.shared.deleteLocalFavorite(gid: record.gid)
            }
            await MainActor.run {
                isBatchProcessing = false
                isSelectMode = false
                selectedGids.removeAll()
                loadLocalFavorites()
            }
        }
    }

    private func batchDeleteSelected() {
        for gid in selectedGids {
            try? EhDatabase.shared.deleteLocalFavorite(gid: gid)
        }
        localFavorites.removeAll { selectedGids.contains($0.gid) }
        isSelectMode = false
        selectedGids.removeAll()
    }

    private func deleteLocalFavorites(at offsets: IndexSet) {
        let visibleRecords = localFavorites
        for index in offsets {
            guard visibleRecords.indices.contains(index) else { continue }
            let record = visibleRecords[index]
            try? EhDatabase.shared.deleteLocalFavorite(gid: record.gid)
            localFavorites.removeAll { $0.gid == record.gid }
        }
    }

    // MARK: - Slot Picker

    private var slotPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                // "全部" 标签 (对齐 Android FavoritesActivity: favCatArray[0] = "All Favorites")
                LiquidGlassFilterChip(isSelected: selectedSlot == -1, action: { selectedSlot = -1 }) {
                    Text("全部")
                }

                // "本地收藏" 标签 (对齐 Android FAV_CAT_LOCAL)
                LiquidGlassFilterChip(isSelected: selectedSlot == -2, action: { selectedSlot = -2 }) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                        Text("本地收藏")
                            .font(.subheadline)
                    }
                }

                ForEach(0..<10) { slot in
                    LiquidGlassFilterChip(isSelected: selectedSlot == slot, action: { selectedSlot = slot }) {
                        HStack(spacing: 4) {
                            Text(favoriteNames[slot])
                                .font(.subheadline)
                            let count = AppSettings.shared.favCount(slot)
                            if count > 0 {
                                Text("(\(count))")
                                    .font(.caption2)
                                    .foregroundStyle(selectedSlot == slot ? .white.opacity(0.8) : .secondary)
                            }
                        }
                    }
                }
                }
            }
            .padding(.horizontal, 12)
            // Glass 的环境投影需要位于 ScrollView 内容边界内；同时关闭
            // 默认裁剪，避免投影在标签栏底边形成一条生硬的切线。
            .padding(.vertical, 8)
        }
        .scrollClipDisabled()
    }
}

#Preview {
    FavoritesView()
}
