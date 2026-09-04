//
//  GalleryListView.swift
//  ehviewer apple
//
//  画廊列表视图 — 首页/热门/搜索结果
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings
import EhDatabase
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Routes full-site searches into MainTabView's persistent Search section.
/// Favorites keeps its own server-side filtering and intentionally does not use this action.
struct GallerySearchNavigationAction {
    /// Move focus into the persistent Search tab without briefly activating
    /// an expendable source-page text field.
    let focusSearch: @MainActor () -> Void
    let search: @MainActor (_ query: String, _ advancedSearch: AdvancedSearchState?) -> Void
    /// Search initiated from gallery metadata (tag/uploader). Keeping this
    /// separate from typed searches lets the Search page offer a route back
    /// to the originating gallery.
    let searchFromGallery: @MainActor (_ query: String, _ gallery: GalleryInfo) -> Void
    let quickSearch: @MainActor (_ record: QuickSearchRecord) -> Void
    var imageSearch: (@MainActor (URL) -> Void)? = nil
}

private struct GallerySearchNavigationActionKey: EnvironmentKey {
    static let defaultValue: GallerySearchNavigationAction? = nil
}

extension EnvironmentValues {
    var gallerySearchNavigationAction: GallerySearchNavigationAction? {
        get { self[GallerySearchNavigationActionKey.self] }
        set { self[GallerySearchNavigationActionKey.self] = newValue }
    }
}

struct GalleryListView: View {
    let mode: ListMode

    private enum PrimaryFeed: String {
        case home
        case popular

        var listMode: ListMode {
            switch self {
            case .home: return .home
            case .popular: return .popular
            }
        }
    }

    enum ListMode {
        case home
        case subscription
        case popular
        case search(keyword: String)
        case tag(keyword: String)
        case favorites(slot: Int)
    }

    @State private var viewModel = GalleryListViewModel()
    @State private var showAdvancedSearch = false
    @State private var imageSearchRoute: NativeImageSearchRoute?
    @State private var advancedSearch = AdvancedSearchState()
    @State private var selectedQuickSearch: QuickSearchRecord?
    @State private var favoritePickerGallery: GalleryInfo?
    @State private var searchPanelKeyboardCommand: SearchPanelKeyboardCommand?
    @State private var selectedGallery: GalleryInfo?
    @State private var primaryFeed: PrimaryFeed
    @FocusState private var isSearchFocused: Bool
    @Environment(\.contentRouteBackAction) private var contentRouteBackAction
    @Environment(\.gallerySearchNavigationAction) private var gallerySearchNavigationAction
    /// 跳页模式切换 (对齐 Android JumpDateSelector: DATE_PICKER_TYPE / DATE_NODE_TYPE)
    @State private var jumpUseQuickNode = true

    /// 标签导航路径 — iPad 双栏布局中支持标签推入左侧
    @State private var sidebarPath = NavigationPath()

    /// 外部选择绑定（嵌入三栏布局时使用）
    private var externalSelection: Binding<GalleryInfo?>?
    private var isEmbedded: Bool { externalSelection != nil }

    /// 是否作为 push 目标（避免嵌套 NavigationStack）
    private var isPushed: Bool = false

    /// 收藏夹搜索关键字 (对齐 Android FavoritesScene 搜索)
    private var favSearchKeyword: String?
    /// 父容器（例如收藏页）已经提供搜索框时，隐藏列表自己的搜索控件。
    private var showsSearchControls = true
    /// The dedicated Search tab executes queries locally instead of routing back to itself.
    private var isDedicatedSearchPage = false
    /// Monotonic request supplied by MainTabView after the Search tab becomes active.
    private var searchFocusRequest = 0
    /// A new metadata search must also dismiss any GalleryDetailView currently
    /// pushed inside the compact Search tab's private NavigationStack.
    private var searchNavigationResetRequest = 0
    /// 父容器悬浮控件所需的初始滚动避让空间。
    private var externalTopInset: CGFloat = 0
    private var selectionBinding: Binding<GalleryInfo?> {
        externalSelection ?? $selectedGallery
    }

    /// 对服务器返回了 simpleTags 的列表执行本地屏蔽；没有标签摘要的
    /// 列表样式保持原样，避免在信息不足时误删画廊。
    private var displayedGalleries: [GalleryInfo] {
        let blocked = Set(AppSettings.shared.blockedTags)
        let visible = viewModel.galleries.filter { gallery in
            guard !blocked.isEmpty,
                  let tags = gallery.simpleTags,
                  !tags.isEmpty
            else { return true }
            return tags.allSatisfy { !blocked.contains($0.lowercased()) }
        }
        return visible
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// iPad 侧边栏由 MainTabView 统一管理，GalleryListView 不再创建自己的 SplitView
    private var isRegularWidth: Bool { false }
    #else
    /// macOS 也支持全宽单列表模式
    private var isRegularWidth: Bool { AppSettings.shared.wideScreenListMode == 0 }
    #endif

    init(mode: ListMode) {
        self.mode = mode
        self.externalSelection = nil
        _primaryFeed = State(initialValue: Self.initialPrimaryFeed(for: mode))
    }

    /// 作为导航目标推入时使用，不创建自己的 NavigationStack/SplitView
    init(mode: ListMode, isPushed: Bool) {
        self.mode = mode
        self.isPushed = isPushed
        self.externalSelection = nil
        _primaryFeed = State(initialValue: Self.initialPrimaryFeed(for: mode))
    }

    init(mode: ListMode, selection: Binding<GalleryInfo?>) {
        self.mode = mode
        self.externalSelection = selection
        _primaryFeed = State(initialValue: Self.initialPrimaryFeed(for: mode))
    }

    /// 主栏目由 MainTabView 持有 ViewModel。布局在单栏/双栏间切换或用户
    /// 离开后返回时，不重新解析缓存、发起网络请求或丢失滚动位置。
    init(mode: ListMode, persistentViewModel: GalleryListViewModel) {
        self.mode = mode
        self.externalSelection = nil
        _viewModel = State(initialValue: persistentViewModel)
        _primaryFeed = State(initialValue: Self.initialPrimaryFeed(for: mode))
    }

    init(
        mode: ListMode,
        selection: Binding<GalleryInfo?>,
        persistentViewModel: GalleryListViewModel
    ) {
        self.mode = mode
        self.externalSelection = selection
        _viewModel = State(initialValue: persistentViewModel)
        _primaryFeed = State(initialValue: Self.initialPrimaryFeed(for: mode))
    }

    /// Search tab initializer. The owner keeps both reference-type states alive while the
    /// user switches sections, so results, pagination, filters and scroll position survive.
    init(
        mode: ListMode,
        selection: Binding<GalleryInfo?>,
        persistentViewModel: GalleryListViewModel,
        persistentAdvancedSearch: AdvancedSearchState,
        searchFocusRequest: Int = 0,
        searchNavigationResetRequest: Int = 0
    ) {
        self.mode = mode
        self.externalSelection = selection
        self.isDedicatedSearchPage = true
        self.searchFocusRequest = searchFocusRequest
        self.searchNavigationResetRequest = searchNavigationResetRequest
        _viewModel = State(initialValue: persistentViewModel)
        _advancedSearch = State(initialValue: persistentAdvancedSearch)
        _primaryFeed = State(initialValue: Self.initialPrimaryFeed(for: mode))
    }

    /// Compact Search tab initializer. It preserves the shared search model,
    /// but owns its selection so it uses the same NavigationStack/list style
    /// as Home instead of the wide embedded-column presentation.
    init(
        mode: ListMode,
        persistentViewModel: GalleryListViewModel,
        persistentAdvancedSearch: AdvancedSearchState,
        searchFocusRequest: Int = 0,
        searchNavigationResetRequest: Int = 0
    ) {
        self.mode = mode
        self.externalSelection = nil
        self.isDedicatedSearchPage = true
        self.searchFocusRequest = searchFocusRequest
        self.searchNavigationResetRequest = searchNavigationResetRequest
        _viewModel = State(initialValue: persistentViewModel)
        _advancedSearch = State(initialValue: persistentAdvancedSearch)
        _primaryFeed = State(initialValue: Self.initialPrimaryFeed(for: mode))
    }

    /// 收藏搜索模式
    init(
        mode: ListMode,
        searchKeyword: String?,
        showsSearchControls: Bool = true,
        contentTopInset: CGFloat = 0,
        persistentViewModel: GalleryListViewModel? = nil
    ) {
        self.mode = mode
        self.favSearchKeyword = searchKeyword
        self.showsSearchControls = showsSearchControls
        self.externalTopInset = contentTopInset
        self.externalSelection = nil
        if let persistentViewModel {
            _viewModel = State(initialValue: persistentViewModel)
        }
        _primaryFeed = State(initialValue: Self.initialPrimaryFeed(for: mode))
    }

    /// 收藏搜索模式 (嵌入)
    init(
        mode: ListMode,
        selection: Binding<GalleryInfo?>,
        searchKeyword: String?,
        showsSearchControls: Bool = true,
        contentTopInset: CGFloat = 0,
        persistentViewModel: GalleryListViewModel? = nil
    ) {
        self.mode = mode
        self.externalSelection = selection
        self.favSearchKeyword = searchKeyword
        self.showsSearchControls = showsSearchControls
        self.externalTopInset = contentTopInset
        if let persistentViewModel {
            _viewModel = State(initialValue: persistentViewModel)
        }
        _primaryFeed = State(initialValue: Self.initialPrimaryFeed(for: mode))
    }

    private static func initialPrimaryFeed(for mode: ListMode) -> PrimaryFeed {
        if case .popular = mode { return .popular }
        return .home
    }

    private var supportsPrimaryFeedSwitching: Bool {
        switch mode {
        case .home, .popular: return true
        default: return false
        }
    }

    private var selectedBaseMode: ListMode {
        supportsPrimaryFeedSwitching ? primaryFeed.listMode : mode
    }

    /// 当前实际运行模式 — 如果搜索框有内容，则为搜索模式
    /// 但收藏夹模式下搜索应保持在收藏夹内 (对齐 Android: 收藏夹搜索只搜收藏内容)
    private var effectiveMode: ListMode {
        if !viewModel.searchText.isEmpty {
            if case .favorites = selectedBaseMode {
                // 收藏夹下搜索保持在收藏夹模式，搜索关键词通过 searchText 传递给 API
                return selectedBaseMode
            }
            return .search(keyword: viewModel.searchText)
        }
        return selectedBaseMode
    }

    /// EH 的收藏响应有时不提供 pages，但设置中有登录后同步的各收藏夹计数。
    /// 使用该计数作为只读后备，让页码/最后一页在 pages=0 时仍能执行。
    private var maximumJumpPage: Int {
        var pageCount = viewModel.totalPages
        guard case .favorites(let slot) = effectiveMode else { return pageCount }

        let favoriteCount: Int
        if slot >= 0 {
            favoriteCount = AppSettings.shared.favCount(slot)
        } else {
            favoriteCount = (0..<10).reduce(into: 0) { result, index in
                result += AppSettings.shared.favCount(index)
            }
        }
        pageCount = max(pageCount, (favoriteCount + 49) / 50)
        if !viewModel.galleries.isEmpty { pageCount = max(pageCount, 1) }
        return pageCount
    }

    private var isEmptyDedicatedSearch: Bool {
        isDedicatedSearchPage
            && viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel.galleries.isEmpty
    }

    private var keepsSearchInCurrentPage: Bool {
        if isDedicatedSearchPage { return true }
        if case .favorites = mode { return true }
        return gallerySearchNavigationAction == nil
    }

    private func submitSearch() {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearchFocused = false
        if keepsSearchInCurrentPage {
            viewModel.searchWithAdvanced(advancedSearch)
        } else {
            gallerySearchNavigationAction?.search(query, advancedSearch)
        }
    }

    private func clearSearchText() {
        if isDedicatedSearchPage {
            viewModel.clearDedicatedSearch()
        } else {
            viewModel.searchText = ""
            viewModel.updateSuggestions()
        }
    }

    private func activateQuickSearch(_ record: QuickSearchRecord) {
        if keepsSearchInCurrentPage {
            viewModel.applyQuickSearch(record)
        } else {
            gallerySearchNavigationAction?.quickSearch(record)
        }
    }



    var body: some View {
        Group {
            if isEmbedded {
                // 嵌入模式: 仅展示列表，由父视图管理导航
                embeddedContent
            } else if isPushed {
                // 被推入导航栈时: 不创建自己的 NavigationStack，避免嵌套
                pushedContent
        } else if isRegularWidth {
            // iPadOS / macOS 独立模式: 双栏布局
            NavigationSplitView {
                NavigationStack(path: $sidebarPath) {
                    sidebarContent
                        .navigationTitle(navigationTitle)
                        .navigationDestination(for: TagSearchDestination.self) { dest in
                            // 标签点击推入的画廊列表 (对齐 Android: onTagClick → 叠加新列表)
                            GalleryListView(mode: .tag(keyword: dest.tag), selection: $selectedGallery)
                        }
                        .navigationDestination(for: UploaderSearchDestination.self) { dest in
                            GalleryListView(mode: .search(keyword: dest.keyword), selection: $selectedGallery)
                        }
                }
                .navigationSplitViewColumnWidth(min: 350, ideal: 400, max: 500)
            } detail: {
                // Detail 部分需要 NavigationStack 才能支持 navigationDestination
                NavigationStack {
                    if let gallery = selectedGallery {
                        GalleryDetailView(gallery: gallery)
                    } else {
                        ContentUnavailableView("选择画廊", systemImage: "photo.stack", description: Text("从左侧列表选择一个画廊"))
                    }
                }
                .environment(\.tagNavigationAction, TagNavigationAction { tag in
                    sidebarPath.append(TagSearchDestination(tag: tag))
                })
                .environment(\.uploaderSearchNavigationAction, UploaderSearchNavigationAction { keyword in
                    sidebarPath.append(UploaderSearchDestination(keyword: keyword))
                })
            }
        } else {
            // iPhone: 单栏布局
            compactContent
        }
        }
        .environment(\.imageSearchPresentationAction, ImageSearchPresentationAction { data in
            isSearchFocused = false
            imageSearchRoute = NativeImageSearchRoute(initialData: data)
        })
        .sheet(item: $imageSearchRoute) { route in
            NativeImageSearchView(initialData: route.initialData) { url in
                imageSearchRoute = nil
                if let action = gallerySearchNavigationAction?.imageSearch {
                    action(url)
                } else {
                    viewModel.loadImageSearch(url)
                }
            }
        }
        .task {
            // 异步执行 ViewModel 初始化 — 避免 .onAppear 同步变更 @Observable 导致 NavigationStack 多次更新
            viewModel.favSearchKeyword = favSearchKeyword
            viewModel.loadSearchHistory()
            if isDedicatedSearchPage {
                await viewModel.restoreDedicatedSearchSession(into: advancedSearch)
            }
            if case .tag(let keyword) = mode, viewModel.searchText.isEmpty {
                viewModel.searchText = keyword
            }
            // 安全兜底: 确保数据加载在任何分支下都能触发
            if viewModel.galleries.isEmpty && !viewModel.isLoading && !isEmptyDedicatedSearch {
                viewModel.loadGalleries(mode: selectedBaseMode)
            }
        }
        .task(id: favSearchKeyword) {
            guard case .favorites = mode,
                  viewModel.favSearchKeyword != favSearchKeyword
            else { return }

            // 收藏搜索由父级唯一搜索框驱动；短暂防抖并让 SwiftUI 在
            // 关键字继续变化时自动取消旧任务。
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            viewModel.favSearchKeyword = favSearchKeyword
            await viewModel.refreshAsync(mode: mode)
        }
        .onChange(of: AppSettings.shared.gallerySite) { _, _ in
            if viewModel.imageSearchURL != nil {
                // Image-result URLs belong to the site that accepted the upload.
                // Do not silently reuse one under a different EH/EX selection.
                viewModel.clearDedicatedSearch()
            } else {
                viewModel.refresh(mode: selectedBaseMode)
            }
        }
        .onChange(of: primaryFeed) { _, newFeed in
            guard supportsPrimaryFeedSwitching else { return }
            isSearchFocused = false
            viewModel.scrollPosition = nil
            viewModel.refresh(mode: newFeed.listMode)
        }
        .onChange(of: showAdvancedSearch) { _, isShowing in
            if !isShowing {
                // 高级搜索面板关闭时，静默保存参数到 ViewModel (不自动触发搜索)
                // 用户提交搜索或点击搜索按钮时才会使用这些参数
                viewModel.syncAdvancedSettings(advancedSearch)
            }
        }
        .onChange(of: isSearchFocused) { _, focused in
            if focused {
                viewModel.updateSuggestions()
            }
        }
        .onChange(of: viewModel.scrollPosition) { _, _ in
            if isDedicatedSearchPage {
                viewModel.scheduleDedicatedSearchPersistence()
            }
        }
        .task(id: searchFocusRequest) {
            guard isDedicatedSearchPage, searchFocusRequest != 0 else { return }
            guard searchFocusRequest > 0 else {
                isSearchFocused = false
                return
            }
            // Wait until TabView has committed the destination hierarchy;
            // otherwise UIKit immediately resigns the new text field.
            await Task.yield()
            await Task.yield()
            isSearchFocused = true
        }
        .onChange(of: searchFocusRequest, initial: true) { _, request in
            guard isDedicatedSearchPage, request < 0 else { return }
            // Resigning focus must not wait for a `.task` hidden underneath a
            // pushed GalleryDetailView. Otherwise the history/suggestion layer
            // can remain above the newly loaded deep-search results.
            isSearchFocused = false
            searchPanelKeyboardCommand = nil
        }
        .onChange(of: searchNavigationResetRequest, initial: true) { _, request in
            guard isDedicatedSearchPage, request != 0 else { return }
            // `task(id:)` may be deferred while NavigationStack is presenting
            // a detail destination. An observation callback is delivered to
            // the mounted root immediately, so the new result set can never
            // remain hidden behind the gallery that initiated it.
            withAnimation(.smooth(duration: 0.24)) {
                // In an embedded wide layout the visible detail is owned by
                // MainTabView, not this view's private state. Reset through the
                // effective binding so both compact and split layouts pop it.
                selectionBinding.wrappedValue = nil
                sidebarPath = NavigationPath()
            }
        }
        .focusedSceneValue(\.browserCommandActions, BrowserCommandActions(
            refresh: { viewModel.refresh(mode: effectiveMode) },
            focusSearch: focusSearchFromCommand,
            toggleDisplayMode: toggleGalleryDisplayMode
        ))
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

    // iPhone 布局
    private var compactContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if viewModel.galleries.isEmpty && viewModel.errorMessage != nil && !viewModel.isLoading {
                        errorView
                    } else {
                        // 离线可用: 始终显示列表结构，加载指示器为内联行，不阻塞界面
                        galleryList
                    }
                }
            }
            .navigationTitle(navigationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    searchDismissBackdrop(topInset: 54)
                    floatingSearchControls
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .zIndex(3)
                    searchAuxiliaryOverlay
                        .padding(.top, 58)
                        .zIndex(4)
                }
            }
            .sheet(isPresented: $showAdvancedSearch) {
                AdvancedSearchView(state: advancedSearch)
            }
            .onChange(of: selectedQuickSearch) { _, newValue in
                if let search = newValue {
                    activateQuickSearch(search)
                    selectedQuickSearch = nil
                }
            }
        }
        // ★ 已移除 compactContent 级 .task — 避免与 body .task 重复加载，由 body .task 统一管理
        .sheet(isPresented: $viewModel.showJumpDialog) {
            jumpSheet
        }
        .alert("跳页", isPresented: $viewModel.showGoToDialog) {
            TextField("页码", text: $viewModel.goToPageInput)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("取消", role: .cancel) { viewModel.goToPageInput = "" }
            Button("确定") {
                if let page = Int(viewModel.goToPageInput), page >= 1,
                   page <= maximumJumpPage {
                    viewModel.goToPage(
                        page - 1,
                        mode: effectiveMode,
                        knownTotalPages: maximumJumpPage
                    )
                }
                viewModel.goToPageInput = ""
            }
        } message: {
            Text("输入页码 (1-\(maximumJumpPage))")
        }
    }

    /// 被推入导航栈时的内容 — 不包装 NavigationStack，避免嵌套
    private var pushedContent: some View {
        VStack(spacing: 0) {
            Group {
                if viewModel.galleries.isEmpty && viewModel.errorMessage != nil && !viewModel.isLoading {
                    errorView
                } else {
                    galleryList
                }
            }
        }
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                searchDismissBackdrop(topInset: 54)
                floatingSearchControls
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .zIndex(3)
                searchAuxiliaryOverlay
                    .padding(.top, 58)
                    .zIndex(4)
            }
        }
        .sheet(isPresented: $showAdvancedSearch) {
            AdvancedSearchView(state: advancedSearch)
        }
        .onChange(of: selectedQuickSearch) { _, newValue in
            if let search = newValue {
                activateQuickSearch(search)
                selectedQuickSearch = nil
            }
        }
        .task {
            if viewModel.galleries.isEmpty && !isEmptyDedicatedSearch {
                viewModel.loadGalleries(mode: selectedBaseMode)
            }
        }
        .sheet(isPresented: $viewModel.showJumpDialog) {
            jumpSheet
        }
        .alert("跳页", isPresented: $viewModel.showGoToDialog) {
            TextField("页码", text: $viewModel.goToPageInput)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("取消", role: .cancel) { viewModel.goToPageInput = "" }
            Button("确定") {
                if let page = Int(viewModel.goToPageInput), page >= 1,
                   page <= maximumJumpPage {
                    viewModel.goToPage(
                        page - 1,
                        mode: effectiveMode,
                        knownTotalPages: maximumJumpPage
                    )
                }
                viewModel.goToPageInput = ""
            }
        } message: {
            Text("输入页码 (1-\(maximumJumpPage))")
        }
    }

    private var navigationTitle: String {
        switch selectedBaseMode {
        case .home: return AppSettings.shared.gallerySite == .exHentai ? "ExHentai" : "E-Hentai"
        case .subscription: return AppLocalization.localized("订阅")
        case .popular: return AppLocalization.localized("热门")
        case .search(let kw): return kw.isEmpty
            ? AppLocalization.localized("搜索")
            : AppLocalization.format("搜索: %@", kw)
        case .tag: return AppLocalization.localized("标签搜索")  // 对齐 Android: 标签关键字显示在搜索框而非标题
        case .favorites: return AppLocalization.localized("收藏")
        }
    }

    private var galleryList: some View {
        Group {
            if isEmptyDedicatedSearch {
                dedicatedSearchLanding
            } else if galleryDisplayMode == .grid {
                navigationWaterfall
            } else {
                standardGalleryList
            }
        }
        .navigationDestination(for: GalleryInfo.self) { gallery in
            GalleryDetailView(gallery: gallery)
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedGallery != nil },
            set: { if !$0 { selectedGallery = nil } }
        )) {
            if let selectedGallery {
                GalleryDetailView(gallery: selectedGallery)
                    .id(selectedGallery.gid)
            }
        }
    }

    private var navigationWaterfall: some View {
        let showJpn = AppSettings.shared.showJpnTitle
        let fixThumb = AppSettings.shared.fixThumbUrl
        let showRating = AppSettings.shared.showGalleryRating
        let showPages = AppSettings.shared.showGalleryPages
        return GalleryWaterfallView(
            galleries: displayedGalleries,
            topInset: (showsSearchControls ? 72 : 0) + externalTopInset,
            scrollPosition: $viewModel.scrollPosition,
            showsContinueReading: {
                if case .home = selectedBaseMode { return true }
                return false
            }(),
            isLoading: viewModel.isLoading,
            hasMore: viewModel.hasMore,
            onRefresh: { await viewModel.refreshOrLoadPrevious(mode: effectiveMode) },
            onLoadMore: { await viewModel.loadMore(mode: effectiveMode) }
        ) { gallery in
            NavigationLink(value: gallery) {
                GalleryWaterfallCard(
                    gallery: gallery,
                    showJpnTitle: showJpn,
                    fixThumbUrl: fixThumb,
                    showRating: showRating,
                    showPages: showPages,
                    isSelected: false
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var standardGalleryList: some View {
        // Perf P0-3: 一次性读取配置，避免每个 Row 重复读 UserDefaults
        let showJpn = AppSettings.shared.showJpnTitle
        let fixThumb = AppSettings.shared.fixThumbUrl
        let showRating = AppSettings.shared.showGalleryRating
        let showPages = AppSettings.shared.showGalleryPages
        return List {
            if showsSearchControls || externalTopInset > 0 {
                Color.clear
                    .frame(height: (showsSearchControls ? 72 : 0) + externalTopInset)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            // Fix F2-1: \u9996\u9875\u9876\u90e8\u663e\u793a\u201c\u7ee7\u7eed\u9605\u8bfb\u201d\u5361\u7247
            if case .home = selectedBaseMode {
                ContinueReadingCard()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            // 内联加载指示器 (不阻塞界面，用户可正常操作其他 Tab 和功能)
            if viewModel.isLoading && viewModel.galleries.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在加载…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowSeparator(.hidden)
            }

            ForEach(displayedGalleries, id: \.gid) { gallery in
                let isWatchLater = GalleryActionService.shared.isInWatchLater(gid: gallery.gid)
                let isFavorited = GalleryActionService.shared.isFavorited(gallery)
                Button {
                    selectedGallery = gallery
                } label: {
                    GalleryRow(
                        gallery: gallery,
                        showJpnTitle: showJpn,
                        fixThumbUrl: fixThumb,
                        showRating: showRating,
                        showPages: showPages,
                        isSelected: false
                    )
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        performFavoriteToggle(gallery)
                    } label: {
                        Label(AppLocalization.localized(isFavorited ? "取消收藏" : "收藏"), systemImage: isFavorited ? "heart.slash" : "heart")
                    }
                    .tint(isFavorited ? .gray : .red)

                    if !isWatchLater {
                        Button {
                            Task { await GalleryActionService.shared.addToWatchLater(gallery) }
                        } label: {
                            Label("稍后再看", systemImage: "bookmark")
                        }
                        .tint(.orange)
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if isWatchLater {
                        Button {
                            Task { await GalleryActionService.shared.removeFromWatchLater(gid: gallery.gid) }
                        } label: {
                            Label("移除稍后再看", systemImage: "bookmark.slash")
                        }
                        .tint(.orange)
                    }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                .listRowSeparator(.hidden)
            }

            // 加载更多
            if viewModel.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .task {
                        await viewModel.loadMore(mode: effectiveMode)
                    }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollPosition(id: $viewModel.scrollPosition)
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        #endif
        .refreshable {
            await viewModel.refreshOrLoadPrevious(mode: effectiveMode)
        }
    }

    // 嵌入模式内容（无导航包装器，用于三栏布局的 content 列）
    private var embeddedContent: some View {
        sidebarContent
            .navigationTitle(navigationTitle)
            .task {
                if viewModel.galleries.isEmpty && !isEmptyDedicatedSearch {
                    viewModel.loadGalleries(mode: selectedBaseMode)
                }
            }
    }

    // iPad/Mac 侧边栏内容
    private var sidebarContent: some View {
        // Perf P0-3: 一次性读取配置
        let showJpn = AppSettings.shared.showJpnTitle
        let fixThumb = AppSettings.shared.fixThumbUrl
        let showRating = AppSettings.shared.showGalleryRating
        let showPages = AppSettings.shared.showGalleryPages
        let waterfallTopInset: CGFloat = (showsSearchControls ? 72 : 0) + externalTopInset
        return VStack(spacing: 0) {
            Group {
                if isEmptyDedicatedSearch {
                    dedicatedSearchLanding
                } else if viewModel.galleries.isEmpty && viewModel.errorMessage != nil && !viewModel.isLoading {
                    errorView
                } else if galleryDisplayMode == .grid {
                    GalleryWaterfallView(
                        galleries: displayedGalleries,
                        topInset: waterfallTopInset,
                        scrollPosition: $viewModel.scrollPosition,
                        showsContinueReading: false,
                        isLoading: viewModel.isLoading,
                        hasMore: viewModel.hasMore,
                        onRefresh: { await viewModel.refreshOrLoadPrevious(mode: effectiveMode) },
                        onLoadMore: { await viewModel.loadMore(mode: effectiveMode) }
                    ) { gallery in
                        Button {
                            selectionBinding.wrappedValue = gallery
                        } label: {
                            GalleryWaterfallCard(
                                gallery: gallery,
                                showJpnTitle: showJpn,
                                fixThumbUrl: fixThumb,
                                showRating: showRating,
                                showPages: showPages,
                                isSelected: selectionBinding.wrappedValue?.gid == gallery.gid
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    List(selection: selectionBinding) {
                        // A real row is used instead of contentMargins because
                        // List may ignore scroll-content top margins. It
                        // keeps the first gallery clear of the floating search
                        // controls and naturally scrolls away with the feed.
                        if showsSearchControls || externalTopInset > 0 {
                            Color.clear
                                .frame(height: (showsSearchControls ? 72 : 0) + externalTopInset)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }

                        // 内联加载指示器 (不阻塞界面)
                        if viewModel.isLoading && viewModel.galleries.isEmpty {
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("正在加载…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(displayedGalleries, id: \.gid) { gallery in
                            let isWatchLater = GalleryActionService.shared.isInWatchLater(gid: gallery.gid)
                            let isFavorited = GalleryActionService.shared.isFavorited(gallery)
                            #if os(macOS)
                            Button {
                                selectionBinding.wrappedValue = gallery
                            } label: {
                                GalleryRow(
                                    gallery: gallery,
                                    showJpnTitle: showJpn,
                                    fixThumbUrl: fixThumb,
                                    showRating: showRating,
                                    showPages: showPages,
                                    isSelected: selectionBinding.wrappedValue?.gid == gallery.gid
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                            .listRowSeparator(.hidden)
                            #else
                            GalleryRow(
                                gallery: gallery,
                                showJpnTitle: showJpn,
                                fixThumbUrl: fixThumb,
                                showRating: showRating,
                                showPages: showPages,
                                isSelected: selectionBinding.wrappedValue?.gid == gallery.gid
                            )
                                .tag(gallery)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        performFavoriteToggle(gallery)
                                    } label: {
                                        Label(AppLocalization.localized(isFavorited ? "取消收藏" : "收藏"), systemImage: isFavorited ? "heart.slash" : "heart")
                                    }
                                    .tint(isFavorited ? .gray : .red)

                                    if !isWatchLater {
                                        Button {
                                            Task { await GalleryActionService.shared.addToWatchLater(gallery) }
                                        } label: {
                                            Label("稍后再看", systemImage: "bookmark")
                                        }
                                        .tint(.orange)
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    if isWatchLater {
                                        Button {
                                            Task { await GalleryActionService.shared.removeFromWatchLater(gid: gallery.gid) }
                                        } label: {
                                            Label("移除稍后再看", systemImage: "bookmark.slash")
                                        }
                                        .tint(.orange)
                                    }
                                }
                                .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                                .listRowSeparator(.hidden)
                            #endif
                        }

                        if viewModel.hasMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                                .task {
                                    await viewModel.loadMore(mode: effectiveMode)
                                }
                        }
                    }
                    .scrollPosition(id: $viewModel.scrollPosition)
                    #if os(macOS)
                    // This is the content/feed column, not the app sidebar.
                    // Keep materials on navigation and controls; gallery
                    // content uses an opaque surface for legibility.
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    #else
                    // 与首页使用相同的内容列表样式。`.sidebar` 会在 iOS
                    // 收藏页额外注入圆角分组背景与 disclosure 外观。
                    .listStyle(.plain)
                    #endif
                    .refreshable {
                        await viewModel.refreshOrLoadPrevious(mode: effectiveMode)
                    }
                }
            }
        }
        #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
        .overlay(alignment: .top) {
            if showsSearchControls {
                ZStack(alignment: .top) {
                    searchDismissBackdrop(topInset: 54)
                        .zIndex(1)

                    floatingSearchControls
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .zIndex(3)

                    searchAuxiliaryOverlay
                        .padding(.top, 58)
                        .zIndex(4)
                }
            }
        }
        .sheet(isPresented: $showAdvancedSearch) {
            AdvancedSearchView(state: advancedSearch)
        }
        .onChange(of: selectedQuickSearch) { _, newValue in
            if let search = newValue {
                activateQuickSearch(search)
                selectedQuickSearch = nil
            }
        }
        .sheet(isPresented: $viewModel.showJumpDialog) {
            jumpSheet
        }
        .alert("跳页", isPresented: $viewModel.showGoToDialog) {
            TextField("页码", text: $viewModel.goToPageInput)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("取消", role: .cancel) { viewModel.goToPageInput = "" }
            Button("确定") {
                if let page = Int(viewModel.goToPageInput), page >= 1,
                   page <= maximumJumpPage {
                    viewModel.goToPage(
                        page - 1,
                        mode: effectiveMode,
                        knownTotalPages: maximumJumpPage
                    )
                }
                viewModel.goToPageInput = ""
            }
        } message: {
            Text("输入页码 (1-\(maximumJumpPage))")
        }
    }

    /// Search and feed navigation float over the scrolling content on every
    /// platform. Liquid Glass keeps the field visually separate without
    /// introducing a fixed header band.
    private var floatingSearchControls: some View {
        HStack(spacing: 8) {
            if let contentRouteBackAction {
                Button(action: contentRouteBackAction.perform) {
                    Image(systemName: "chevron.left")
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("返回")
                .accessibilityIdentifier("gallery.search.back")
            }

            if supportsPrimaryFeedSwitching {
                Menu {
                    Button {
                        primaryFeed = .home
                    } label: {
                        Label("首页", systemImage: primaryFeed == .home ? "checkmark" : "house")
                    }

                    Button {
                        primaryFeed = .popular
                    } label: {
                        Label("热门", systemImage: primaryFeed == .popular ? "checkmark" : "flame")
                    }
                } label: {
                    Image(systemName: primaryFeed == .home ? "house" : "flame")
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(AppLocalization.localized(primaryFeed == .home ? "切换到热门" : "切换到首页"))
                .accessibilityLabel("切换首页与热门")
            }

            HStack(spacing: 7) {
                searchFieldControl

                Button {
                    isSearchFocused = false
                    imageSearchRoute = NativeImageSearchRoute(initialData: nil)
                } label: {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("以图搜图")
                .accessibilityLabel("以图搜图")

                Button {
                    if viewModel.searchText.isEmpty {
                        isSearchFocused = false
                        showAdvancedSearch = true
                    } else {
                        clearSearchText()
                    }
                } label: {
                    Image(systemName: viewModel.searchText.isEmpty
                          ? (advancedSearch.isEnabled ? "plus.circle.fill" : "plus.circle")
                          : "xmark.circle.fill")
                        .foregroundStyle(viewModel.searchText.isEmpty ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            // The text field is the interactive control. Applying an
            // interactive glass container here can take first-responder taps
            // away from UIKit's text input bridge on iOS/Simulator.
            .glassEffect(.regular, in: .capsule)

            if isSearchFocused {
                Button {
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("结束搜索输入")
                .accessibilityLabel("结束搜索输入")
                .accessibilityIdentifier("gallery.search.dismiss")
                .transition(.scale.combined(with: .opacity))
            } else {
                Button { toggleGalleryDisplayMode() } label: {
                    Image(systemName: galleryDisplayMode == .list ? "rectangle.grid.2x2" : "list.bullet")
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(AppLocalization.localized(galleryDisplayMode == .list ? "切换到瀑布流" : "切换到列表"))
                .accessibilityIdentifier("gallery.display.toggle")

                Button {
                    if maximumJumpPage > 0 {
                        viewModel.showGoToDialog = true
                    } else {
                        viewModel.showJumpDialog = true
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .disabled(viewModel.galleries.isEmpty || viewModel.imageSearchURL != nil)
                .help("跳页")
                .accessibilityIdentifier("gallery.search.jump")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: isSearchFocused)
    }

    private var searchRecordsPanel: some View {
        SearchRecordsPanelContent(
            selectedSearch: $selectedQuickSearch,
            searchHistory: viewModel.searchHistory,
            currentSearch: viewModel.currentQuickSearchRecord(),
            searchText: viewModel.searchText,
            suggestions: viewModel.suggestions,
            onSelectHistory: { term in
                viewModel.searchText = term
                submitSearch()
            },
            onDeleteHistory: viewModel.removeSearchHistory,
            onSelectSuggestion: { suggestion in
                viewModel.applySuggestion(suggestion)
            },
            onSubmitCurrentSearch: {
                submitSearch()
            },
            onDismiss: { isSearchFocused = false },
            keyboardCommand: searchPanelKeyboardCommand,
            canSaveCurrentSearch: viewModel.imageSearchURL == nil
        )
    }

    @ViewBuilder
    private var searchFieldControl: some View {
        #if os(iOS)
        if keepsSearchInCurrentPage {
            interactiveSearchField
        } else {
            Button(action: focusSearchFromCommand) {
                Text(viewModel.searchText.isEmpty ? "搜索" : viewModel.searchText)
                    .foregroundStyle(viewModel.searchText.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开搜索")
            .accessibilityIdentifier("gallery.search.field")
        }
        #else
        interactiveSearchField
        #endif
    }

    private var interactiveSearchField: some View {
        TextField("搜索", text: $viewModel.searchText)
            .textFieldStyle(.plain)
            .focused($isSearchFocused)
            .onSubmit { submitSearch() }
            .onChange(of: viewModel.searchText) { _, _ in
                viewModel.updateSuggestions()
            }
            #if os(macOS)
            .onKeyPress(.downArrow) {
                sendSearchPanelCommand(.next)
                return .handled
            }
            .onKeyPress(.upArrow) {
                sendSearchPanelCommand(.previous)
                return .handled
            }
            .onKeyPress(.return) {
                sendSearchPanelCommand(.confirm)
                return .handled
            }
            .onKeyPress(.escape) {
                isSearchFocused = false
                return .handled
            }
            #else
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            #endif
            .accessibilityIdentifier("gallery.search.field")
    }

    private func focusSearchFromCommand() {
        if keepsSearchInCurrentPage {
            isSearchFocused = true
        } else {
            isSearchFocused = false
            gallerySearchNavigationAction?.focusSearch()
        }
    }

    /// 空搜索页承载排行榜；聚焦搜索框时，统一的历史与候选面板覆盖在其上。
    private var dedicatedSearchLanding: some View {
        TopListView(selection: selectionBinding)
            .padding(.top, showsSearchControls ? 64 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var searchAuxiliaryOverlay: some View {
        ZStack(alignment: .top) {
            if isSearchFocused {
                // 聚焦时右侧只有一个 38pt 关闭按钮。46pt 同时包含按钮与
                // 间距；面板自身 10pt 外边距与搜索栏的外边距完全一致。
                searchRecordsPanel
                    .padding(
                        .leading,
                        (contentRouteBackAction == nil ? 0 : 46)
                            + (supportsPrimaryFeedSwitching ? 46 : 0)
                    )
                    .padding(.trailing, 46)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.975, anchor: .top)),
                            removal: .opacity
                                .combined(with: .scale(scale: 0.985, anchor: .top))
                        )
                    )
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isSearchFocused)
    }

    private var galleryDisplayMode: EhSettings.ListMode {
        AppSettings.shared.listMode
    }

    private func toggleGalleryDisplayMode() {
        isSearchFocused = false
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            AppSettings.shared.listMode = galleryDisplayMode == .list ? .grid : .list
        }
    }

    @ViewBuilder
    private func searchDismissBackdrop(topInset: CGFloat) -> some View {
        if isSearchFocused {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: topInset)
                    .contentShape(Rectangle())
                    .onTapGesture { isSearchFocused = false }

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isSearchFocused = false }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sendSearchPanelCommand(_ action: SearchPanelKeyboardAction) {
        searchPanelKeyboardCommand = SearchPanelKeyboardCommand(action: action)
    }

    /// 列表收藏与详情页保持相同语义：“每次询问”会先展示收藏夹，
    /// 已设置默认收藏夹时才直接执行。这样滑动操作不会静默失败。
    private func performFavoriteToggle(_ gallery: GalleryInfo) {
        let service = GalleryActionService.shared
        if !service.isFavorited(gallery), AppSettings.shared.defaultFavSlot == -2 {
            favoritePickerGallery = gallery
            return
        }
        Task { await service.toggleFavorite(gallery) }
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
                ErrorHandler.shared.handle(error, context: "ListFavorite")
            }
        }
    }

    // MARK: - 跳页 Sheet (对齐 Android JumpDateSelector: 日期 / 快捷节点 双模式)

    /// 快捷跳转节点 (对齐 Android JumpDateSelector DATE_NODE_TYPE)
    private static let jumpNodes: [(label: String, value: String)] = [
        ("1 天", "1d"), ("3 天", "3d"),
        ("1 周", "1w"), ("2 周", "2w"),
        ("1 月", "1m"), ("6 月", "6m"),
        ("1 年", "1y"), ("2 年", "2y"),
    ]
    @State private var selectedJumpNode: String = "1d"

    private var jumpSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 模式切换 (对齐 Android JumpDateSelector 的 toggle 按钮)
                    Picker("跳页模式", selection: $jumpUseQuickNode) {
                        Text("快捷跳转").tag(true)
                        Text("日期选择").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    if jumpUseQuickNode {
                        // 快捷节点 (对齐 Android JumpDateSelector RadioGroup)
                        VStack(spacing: 12) {
                            Text("选择时间范围快速跳转")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                            ], spacing: 10) {
                                ForEach(Self.jumpNodes, id: \.value) { node in
                                    Button {
                                        selectedJumpNode = node.value
                                    } label: {
                                        Text(node.label)
                                            .font(.body)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(
                                                selectedJumpNode == node.value
                                                    ? Color.accentColor.opacity(0.15)
                                                    : Color.secondary.opacity(0.08)
                                            )
                                            .foregroundStyle(
                                                selectedJumpNode == node.value
                                                    ? Color.accentColor
                                                    : .primary
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(
                                                        selectedJumpNode == node.value
                                                            ? Color.accentColor
                                                            : Color.clear,
                                                        lineWidth: 1.5
                                                    )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    } else {
                        // 日期选择器 (对齐 Android JumpDateSelector DATE_PICKER_TYPE)
                        Text("选择日期跳转到对应时间的画廊")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        DatePicker(
                            "跳转日期",
                            selection: $viewModel.jumpDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .padding(.horizontal)
                    }

                    // 前/后页快捷按钮 (仅收藏模式)
                    if viewModel.isFavoritesMode {
                        HStack(spacing: 16) {
                            if let prevHref = viewModel.prevHref {
                                Button {
                                    viewModel.showJumpDialog = false
                                    viewModel.goToFavoritesHref(prevHref, mode: effectiveMode)
                                } label: {
                                    Label("上一页", systemImage: "chevron.left")
                                }
                                .buttonStyle(.bordered)
                            }
                            if let nextHref = viewModel.nextHref {
                                Button {
                                    viewModel.showJumpDialog = false
                                    viewModel.goToFavoritesHref(nextHref, mode: effectiveMode)
                                } label: {
                                    Label("下一页", systemImage: "chevron.right")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .navigationTitle("跳页")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { viewModel.showJumpDialog = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("跳转") {
                        viewModel.showJumpDialog = false
                        if jumpUseQuickNode {
                            viewModel.goToJump("jump=\(selectedJumpNode)", mode: effectiveMode)
                        } else {
                            viewModel.goToDate(viewModel.jumpDate, mode: effectiveMode)
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(viewModel.errorMessage ?? "加载失败")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // 网络提示
            if let msg = viewModel.errorMessage,
               msg.contains("超时") || msg.contains("timed out") || msg.contains("连接") || msg.contains("域名") || msg.contains("DNS") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("请确认 VPN / 代理已开启", systemImage: "lock.shield")
                    Label("可在设置中尝试开启域名前置", systemImage: "server.rack")
                    Label("检查 DNS 是否被污染", systemImage: "globe")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            }

            Button("重试") {
                viewModel.loadGalleries(mode: effectiveMode)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - 星级评分视图 (对齐 Android SimpleRatingView)

struct SimpleRatingView: View {
    let rating: Float

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                starImage(for: index)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func starImage(for index: Int) -> Image {
        let threshold = Float(index) + 1
        if rating >= threshold {
            return Image(systemName: "star.fill")
        } else if rating >= threshold - 0.5 {
            return Image(systemName: "star.leadinghalf.filled")
        } else {
            return Image(systemName: "star")
        }
    }
}

// MARK: - Gallery Row (对齐 Android item_gallery_list.xml 布局)
// Perf P0-3: showJpnTitle 从外部传入，禁止在 body 中读 AppSettings.shared

struct GalleryRow: View {
    let gallery: GalleryInfo
    let showJpnTitle: Bool
    let fixThumbUrl: Bool
    let showRating: Bool
    let showPages: Bool
    let isSelected: Bool

    @Environment(\.responsiveLayout) private var layout
    @State private var isCoverHovered = false
    @State private var favoritePickerGallery: GalleryInfo?

    private var usesTabletContentMargins: Bool {
        layout.horizontalSizeClass == .regular
            && (layout.height > layout.width || AppSettings.shared.wideScreenListMode == 1)
    }

    private var drawsCustomSelectionHighlight: Bool {
        #if os(macOS)
        true
        #else
        // Regular-width iPad List already supplies the native selection
        // material. Drawing another blue rounded rectangle causes a double
        // highlight, while compact iPhone lists still benefit from this cue.
        layout.horizontalSizeClass != .regular
        #endif
    }

    /// 对齐 Android EhUrl.getFixedThumbUrl: 修复缩略图 CDN 域名不可达问题
    private var thumbURL: URL? {
        ThumbnailURLResolver.url(
            for: gallery.thumb,
            fixLegacy: fixThumbUrl,
            site: AppSettings.shared.gallerySite
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 缩略图 (对齐 Android @id/thumb) - 使用响应式尺寸
            #if os(macOS)
            galleryCover
                .scaleEffect(isCoverHovered ? 1.065 : 1)
                .shadow(
                    color: .black.opacity(isCoverHovered ? 0.28 : 0.08),
                    radius: isCoverHovered ? 10 : 2,
                    y: isCoverHovered ? 6 : 1
                )
                .zIndex(isCoverHovered ? 2 : 0)
                .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isCoverHovered)
                .onHover { isCoverHovered = $0 }
            #else
            galleryCover
            #endif

            // 信息区 (对齐 Android RelativeLayout 右侧元素)
            VStack(alignment: .leading, spacing: 0) {
                // 标题 (对齐 Android @id/title: alignParentTop, toRightOf thumb)
                Text(gallery.suitableTitle(preferJpn: showJpnTitle))
                    .font(.subheadline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 2) {
                    if let uploader = gallery.uploader, !uploader.isEmpty {
                        Label(uploader, systemImage: "person")
                            .lineLimit(1)
                    }
                    if !gallery.authorNames.isEmpty {
                        Label(gallery.authorNames.joined(separator: "、"), systemImage: "paintbrush")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

                Spacer(minLength: 4)

                // 底部区域 — 评分 + 图标行 (对齐 Android rating + LinearLayout)
                HStack {
                    // 评分星星 (对齐 Android SimpleRatingView: above category)
                    if showRating {
                        SimpleRatingView(rating: gallery.rating)
                    }

                    Spacer(minLength: 4)

                    // 右侧图标 (对齐 Android LinearLayout: downloaded, favourited, simple_language, pages)
                    HStack(spacing: 6) {
                        if GalleryActionService.shared.isInWatchLater(gid: gallery.gid) {
                            Image(systemName: "bookmark.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("已加入稍后再看")
                        }
                        if GalleryActionService.shared.isFavorited(gallery) {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        if let lang = gallery.simpleLanguage, !lang.isEmpty {
                            Label(localizedLanguageName(lang), systemImage: "globe")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if showPages {
                            Text("\(gallery.pages)P")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 分类 + 发布时间 (对齐 Android category + posted)
                HStack {
                    // 分类标签 (对齐 Android @id/category: alignBottom thumb)
                    Text(gallery.category.name)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(gallery.category.color)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Spacer(minLength: 4)

                    // 发布时间 (对齐 Android @id/posted: alignBottom thumb, alignParentRight)
                    if let posted = gallery.posted, !posted.isEmpty {
                        Text(GalleryTimestamp.localizedString(fromServerText: posted))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, usesTabletContentMargins ? 28 : 16)
        #if os(macOS)
        // Reserve enough row canvas for the scaled cover and its lower shadow.
        // List rows clip drawing outside their layout bounds even when their
        // separators are hidden.
        .padding(.vertical, 14)
        #else
        .padding(.vertical, 8)
        #endif
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    isSelected && drawsCustomSelectionHighlight
                        ? Color.accentColor.opacity(0.16)
                        : Color.clear
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
        .contentShape(Rectangle())
        #if os(iOS)
        .contentShape(
            .contextMenuPreview,
            RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        #endif
        .contextMenu {
            Button {
                if GalleryActionService.shared.isInWatchLater(gid: gallery.gid) {
                    Task { await GalleryActionService.shared.removeFromWatchLater(gid: gallery.gid) }
                } else {
                    Task { await GalleryActionService.shared.addToWatchLater(gallery) }
                }
            } label: {
                let isWatchLater = GalleryActionService.shared.isInWatchLater(gid: gallery.gid)
                Label(
                    AppLocalization.localized(isWatchLater ? "从稍后再看移除" : "稍后再看"),
                    systemImage: isWatchLater ? "bookmark.slash" : "bookmark"
                )
            }

            // 下载
            Button {
                Task { await GalleryActionService.shared.startDownload(gallery: gallery) }
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }

            // 收藏
            Button {
                performFavoriteToggle(gallery)
            } label: {
                let isFavorited = GalleryActionService.shared.isFavorited(gallery)
                Label(AppLocalization.localized(isFavorited ? "取消收藏" : "收藏"), systemImage: isFavorited ? "heart.slash" : "heart")
            }

            Divider()

            // 复制链接
            Button {
                GalleryActionService.shared.copyLink(gid: gallery.gid, token: gallery.token)
            } label: {
                Label("复制链接", systemImage: "doc.on.doc")
            }

            // 分享 (仅 iOS)
            #if os(iOS)
            ShareLink(item: URL(string: GalleryActionService.shared.galleryURL(gid: gallery.gid, token: gallery.token))!) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            #endif
        }
        .sheet(item: $favoritePickerGallery) { selectedGallery in
            listFavoritePicker(for: selectedGallery)
        }
    }

    private func performFavoriteToggle(_ selectedGallery: GalleryInfo) {
        let service = GalleryActionService.shared
        if !service.isFavorited(selectedGallery), AppSettings.shared.defaultFavSlot == -2 {
            favoritePickerGallery = selectedGallery
        } else {
            Task { await service.toggleFavorite(selectedGallery) }
        }
    }

    private func listFavoritePicker(for selectedGallery: GalleryInfo) -> some View {
        FavoriteSlotPicker(
            onSelect: { slot in
                favoritePickerGallery = nil
                addFavorite(selectedGallery, to: slot)
            },
            onCancel: { favoritePickerGallery = nil }
        )
        #if os(iOS)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func addFavorite(_ selectedGallery: GalleryInfo, to slot: Int) {
        Task {
            do {
                if slot == -1 {
                    try await GalleryActionService.shared.addLocalFavorite(gallery: selectedGallery)
                } else {
                    try await GalleryActionService.shared.addFavorite(
                        gid: selectedGallery.gid,
                        token: selectedGallery.token,
                        slot: slot
                    )
                }
                Haptics.success()
            } catch {
                ErrorHandler.shared.handle(error, context: "RowFavorite")
            }
        }
    }

    private var galleryCover: some View {
        CachedAsyncImage(url: thumbURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Color(.secondarySystemBackground)
        }
        .frame(width: layout.galleryThumbnailSize.width, height: layout.galleryThumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func localizedLanguageName(_ code: String) -> String {
        switch code.uppercased() {
        case "ZH": return AppLocalization.localized("中文")
        case "EN": return AppLocalization.localized("英语")
        case "JA": return AppLocalization.localized("日语")
        case "KO": return AppLocalization.localized("韩语")
        case "FR": return AppLocalization.localized("法语")
        case "DE": return AppLocalization.localized("德语")
        case "ES": return AppLocalization.localized("西班牙语")
        case "IT": return AppLocalization.localized("意大利语")
        case "RU": return AppLocalization.localized("俄语")
        default: return code.uppercased()
        }
    }
}

// MARK: - Adaptive Waterfall Feed

private struct GalleryWaterfallLayoutKey: Hashable, Sendable {
    let columnCount: Int
    let itemCount: Int
    let revision: Int
    let firstGID: Int64?
    let middleGID: Int64?
    let lastGID: Int64?
}

private enum GalleryWaterfallLayoutBuilder {
    nonisolated static func columns(
        for galleries: [GalleryInfo],
        columnCount: Int
    ) -> [[GalleryInfo]] {
        guard columnCount > 0 else { return [] }
        var result = Array(repeating: [GalleryInfo](), count: columnCount)
        var estimatedHeights = Array(repeating: CGFloat.zero, count: columnCount)

        for gallery in galleries {
            let targetColumn = estimatedHeights.indices.min {
                estimatedHeights[$0] < estimatedHeights[$1]
            } ?? 0
            result[targetColumn].append(gallery)
            // All columns have the same width. The metadata row contributes a
            // small fixed normalized height below the image.
            estimatedHeights[targetColumn] += (1 / gallery.waterfallAspectRatio) + 0.18
        }
        return result
    }
}

/// 使用 SwiftUI 原生 ScrollView + LazyVStack 构成的自适应瀑布流。
/// 项目按照缩略图宽高比依次放入当前最短列。
struct GalleryWaterfallView<ItemContent: View>: View {
    let galleries: [GalleryInfo]
    let topInset: CGFloat
    @Binding var scrollPosition: Int64?
    let showsContinueReading: Bool
    let isLoading: Bool
    let hasMore: Bool
    var layoutRevision: Int = 0
    let onRefresh: () async -> Void
    let onLoadMore: () async -> Void
    @ViewBuilder let itemContent: (GalleryInfo) -> ItemContent

    @Environment(\.responsiveLayout) private var layout
    @State private var preparedLayoutKey: GalleryWaterfallLayoutKey?
    @State private var preparedColumns: [[GalleryInfo]] = []

    private let spacing: CGFloat = 12
    private let minimumColumnWidth: CGFloat = 164
    private let synchronousLayoutLimit = 128

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset: CGFloat = layout.horizontalSizeClass == .regular
                && (layout.height > layout.width || AppSettings.shared.wideScreenListMode == 1)
                ? 28 : 10
            // Never inflate the content width to the preferred card width.
            // Doing so made a one-column waterfall wider than a narrow window.
            let availableWidth = max(proxy.size.width - horizontalInset * 2, 1)
            let columnCount = max(
                1,
                Int((availableWidth + spacing) / (minimumColumnWidth + spacing))
            )
            let columnWidth = max(
                1,
                (availableWidth - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount)
            )
            let layoutKey = GalleryWaterfallLayoutKey(
                columnCount: columnCount,
                itemCount: galleries.count,
                revision: layoutRevision,
                firstGID: galleries.first?.gid,
                middleGID: galleries.isEmpty ? nil : galleries[galleries.count / 2].gid,
                lastGID: galleries.last?.gid
            )
            let columns = galleries.count <= synchronousLayoutLimit
                ? GalleryWaterfallLayoutBuilder.columns(
                    for: galleries,
                    columnCount: columnCount
                )
                // While a new page is being distributed, keep the preceding
                // complete layout visible instead of flashing an empty feed.
                : (preparedLayoutKey?.columnCount == columnCount ? preparedColumns : [])

            ScrollView {
                LazyVStack(spacing: 14) {
                    if topInset > 0 {
                        Color.clear
                            .frame(height: topInset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    if showsContinueReading {
                        ContinueReadingCard()
                    }

                    if isLoading && galleries.isEmpty {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("正在加载…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }

                    if galleries.count > synchronousLayoutLimit && columns.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }

                    if !columns.isEmpty {
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(columns.indices, id: \.self) { columnIndex in
                                VStack(spacing: spacing) {
                                    ForEach(columns[columnIndex], id: \.gid) { gallery in
                                        itemContent(gallery)
                                            .frame(width: columnWidth)
                                            .id(gallery.gid)
                                    }
                                }
                                .scrollTargetLayout()
                                .frame(width: columnWidth, alignment: .top)
                            }
                        }
                        .frame(width: availableWidth, alignment: .leading)
                        .transaction { transaction in
                            if layoutRevision != 0 {
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                            }
                        }
                    }

                    if hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .task { await onLoadMore() }
                    }
                }
                .padding(.horizontal, horizontalInset)
                .padding(.bottom, 16)
            }
            .scrollPosition(id: $scrollPosition)
            #if os(macOS)
            .scrollEdgeEffectStyle(.soft, for: .top)
            #else
            .scrollDismissesKeyboard(.immediately)
            #endif
            .refreshable { await onRefresh() }
            .task(id: layoutKey) {
                guard galleries.count > synchronousLayoutLimit else {
                    preparedLayoutKey = nil
                    preparedColumns = []
                    return
                }

                let source = galleries
                let computed = await Task.detached(priority: .userInitiated) {
                    GalleryWaterfallLayoutBuilder.columns(
                        for: source,
                        columnCount: columnCount
                    )
                }.value
                guard !Task.isCancelled else { return }

                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    preparedColumns = computed
                    preparedLayoutKey = layoutKey
                }
            }
        }
        #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
    }

}

struct GalleryWaterfallCard: View {
    let gallery: GalleryInfo
    let showJpnTitle: Bool
    let fixThumbUrl: Bool
    let showRating: Bool
    let showPages: Bool
    let isSelected: Bool

    @State private var isHovered = false
    @State private var favoritePickerGallery: GalleryInfo?

    private var thumbURL: URL? {
        ThumbnailURLResolver.url(
            for: gallery.thumb,
            fixLegacy: fixThumbUrl,
            site: AppSettings.shared.gallerySite
        )
    }

    var body: some View {
        VStack(spacing: 6) {
            CachedAsyncImage(url: thumbURL, showProgress: false) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(.secondarySystemBackground)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
            .aspectRatio(gallery.waterfallAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack(spacing: 5) {
                Circle()
                    .fill(gallery.category.color)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("类型：\(gallery.category.name)")
                    .help(gallery.category.name)

                if let languageEmoji {
                    Text(languageEmoji)
                        .font(.caption2)
                        .accessibilityLabel("语言：\(gallery.simpleLanguage ?? "")")
                }

                if GalleryActionService.shared.isInWatchLater(gid: gallery.gid) {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("已加入稍后再看")
                }

                HoverMarqueeTitle(
                    title: gallery.suitableTitle(preferJpn: showJpnTitle),
                    isHovering: isHovered
                )
                .frame(maxWidth: .infinity)

                if showPages {
                    Text("\(gallery.pages)P")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if showRating {
                    Text(gallery.rating.formatted(.number.precision(.fractionLength(1))))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("评分 \(gallery.rating.formatted(.number.precision(.fractionLength(1))))")
                }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 2)
        }
        .padding(5)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
            }
        }
        #if os(macOS)
        .scaleEffect(isHovered ? 1.018 : 1)
        .offset(y: isHovered ? -3 : 0)
        .shadow(
            color: .black.opacity(isHovered ? 0.2 : 0.05),
            radius: isHovered ? 10 : 2,
            y: isHovered ? 6 : 1
        )
        .animation(.snappy(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
        #else
        // iPad 指针悬浮时使用与 macOS 相同的标题跑马灯；触控长按仍交给
        // 系统 context menu，避免自定义长按手势抢走列表点击/滚动。
        .hoverEffect(.lift)
        .onHover { isHovered = $0 }
        #endif
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .help(gallery.suitableTitle(preferJpn: showJpnTitle))
        #if os(iOS)
        .contentShape(
            .contextMenuPreview,
            RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        #endif
        .contextMenu {
            Button {
                if GalleryActionService.shared.isInWatchLater(gid: gallery.gid) {
                    Task { await GalleryActionService.shared.removeFromWatchLater(gid: gallery.gid) }
                } else {
                    Task { await GalleryActionService.shared.addToWatchLater(gallery) }
                }
            } label: {
                let isWatchLater = GalleryActionService.shared.isInWatchLater(gid: gallery.gid)
                Label(
                    AppLocalization.localized(isWatchLater ? "从稍后再看移除" : "稍后再看"),
                    systemImage: isWatchLater ? "bookmark.slash" : "bookmark"
                )
            }

            Button {
                Task { await GalleryActionService.shared.startDownload(gallery: gallery) }
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }

            Button {
                performFavoriteToggle(gallery)
            } label: {
                let isFavorited = GalleryActionService.shared.isFavorited(gallery)
                Label(AppLocalization.localized(isFavorited ? "取消收藏" : "收藏"), systemImage: isFavorited ? "heart.slash" : "heart")
            }

            Divider()

            Button {
                GalleryActionService.shared.copyLink(gid: gallery.gid, token: gallery.token)
            } label: {
                Label("复制链接", systemImage: "doc.on.doc")
            }
        }
        .sheet(item: $favoritePickerGallery) { selectedGallery in
            listFavoritePicker(for: selectedGallery)
        }
    }

    private func performFavoriteToggle(_ selectedGallery: GalleryInfo) {
        let service = GalleryActionService.shared
        if !service.isFavorited(selectedGallery), AppSettings.shared.defaultFavSlot == -2 {
            favoritePickerGallery = selectedGallery
        } else {
            Task { await service.toggleFavorite(selectedGallery) }
        }
    }

    private func listFavoritePicker(for selectedGallery: GalleryInfo) -> some View {
        FavoriteSlotPicker(
            onSelect: { slot in
                favoritePickerGallery = nil
                addFavorite(selectedGallery, to: slot)
            },
            onCancel: { favoritePickerGallery = nil }
        )
        #if os(iOS)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func addFavorite(_ selectedGallery: GalleryInfo, to slot: Int) {
        Task {
            do {
                if slot == -1 {
                    try await GalleryActionService.shared.addLocalFavorite(gallery: selectedGallery)
                } else {
                    try await GalleryActionService.shared.addFavorite(
                        gid: selectedGallery.gid,
                        token: selectedGallery.token,
                        slot: slot
                    )
                }
                Haptics.success()
            } catch {
                ErrorHandler.shared.handle(error, context: "WaterfallFavorite")
            }
        }
    }

    private var languageEmoji: String? {
        switch gallery.simpleLanguage?.uppercased() {
        case "ZH": return "🇨🇳"
        case "EN": return "🇬🇧"
        case "JA": return "🇯🇵"
        case "KO": return "🇰🇷"
        case "FR": return "🇫🇷"
        case "DE": return "🇩🇪"
        case "ES": return "🇪🇸"
        case "IT": return "🇮🇹"
        case "RU": return "🇷🇺"
        case "PT": return "🇵🇹"
        case "PL": return "🇵🇱"
        case "NL": return "🇳🇱"
        case "HU": return "🇭🇺"
        case "VI": return "🇻🇳"
        case "CS": return "🇨🇿"
        case "ID": return "🇮🇩"
        case "TH": return "🇹🇭"
        case "AR": return "🇸🇦"
        case "TR": return "🇹🇷"
        default: return nil
        }
    }
}

private struct HoverMarqueeTitle: View {
    let title: String
    let isHovering: Bool

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .onGeometryChange(for: CGFloat.self) { textProxy in
                    textProxy.size.width
                } action: { width in
                    textWidth = width
                    updateAnimation(containerWidth: proxy.size.width)
                }
                .offset(x: offset)
                .frame(height: proxy.size.height, alignment: .leading)
                .mask(alignment: .leading) {
                    titleMask(isOverflowing: textWidth > proxy.size.width + 1)
                        .frame(width: proxy.size.width)
                }
                .onAppear {
                    containerWidth = proxy.size.width
                    updateAnimation()
                }
                .onChange(of: proxy.size.width) { _, width in
                    containerWidth = width
                    updateAnimation()
                }
        }
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 16)
            .clipped()
            .accessibilityLabel(title)
            .onChange(of: isHovering) { _, _ in updateAnimation() }
            .onChange(of: title) { _, _ in
                offset = 0
                updateAnimation()
            }
    }

    @ViewBuilder
    private func titleMask(isOverflowing: Bool) -> some View {
        if isOverflowing && !isHovering {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.78),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Rectangle().fill(.black)
        }
    }

    private func updateAnimation(containerWidth: CGFloat) {
        self.containerWidth = containerWidth
        updateAnimation()
    }

    private func updateAnimation() {
        let distance = max(textWidth - containerWidth, 0)
        guard isHovering, distance > 1 else {
            withAnimation(.snappy(duration: 0.18)) { offset = 0 }
            return
        }
        withAnimation(.linear(duration: max(1.2, distance / 28)).delay(0.28)) {
            offset = -distance
        }
    }
}

private extension GalleryInfo {
    nonisolated var waterfallAspectRatio: CGFloat {
        guard thumbWidth > 0, thumbHeight > 0 else { return 0.72 }
        return CGFloat(thumbWidth) / CGFloat(thumbHeight)
    }
}

// MARK: - ViewModel

@MainActor
@Observable
class GalleryListViewModel {
    var galleries: [GalleryInfo] = []
    var isLoading = false
    var errorMessage: String?
    var searchText = ""
    /// Native scroll views update this anchor as the visible result changes. Keeping it in
    /// the persistent Search model restores the user's position after switching sections.
    var scrollPosition: Int64?
    private var pagination = GalleryPaginationState()
    var hasMore: Bool { pagination.hasMore }
    var totalPages: Int { pagination.totalPages }
    var showGoToDialog = false // 跳页对话框 (页码模式，仅 TopList 使用)
    var goToPageInput: String = "" // 跳页输入
    var showJumpDialog = false // 跳页对话框 (日期模式，对齐 Android GoToDialog)
    var jumpDate = Date() // 跳页日期

    /// searchnav 模式下的导航链接，由统一分页状态持有。
    var prevHref: String? { pagination.prevHref }
    var nextHref: String? { pagination.nextHref }
    var lastHref: String? { pagination.lastHref }
    var nextPage: Int? { pagination.nextPage }
    /// 是否为收藏模式 (使用 seek 跳页而非整数页码)
    var isFavoritesMode: Bool {
        if case .favorites = currentMode { return true }
        return false
    }

    /// 收藏夹搜索关键字 (由 FavoritesView 传入)
    var favSearchKeyword: String?

    // MARK: - 搜索历史 (对齐 Android SearchBar 搜索历史)
    var searchHistory: [String] = []

    private static let searchHistoryKey = "ehSearchHistory"
    /// Only five rows are shown by QuickSearchView, but retaining a larger
    /// history lets older entries move into view as the visible ones are
    /// deleted. The bounded store prevents UserDefaults from growing forever.
    private static let maxStoredHistoryCount = 50

    func loadSearchHistory() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.searchHistoryKey) ?? []
        searchHistory = Array(stored.prefix(Self.maxStoredHistoryCount))
        if stored.count > Self.maxStoredHistoryCount {
            UserDefaults.standard.set(searchHistory, forKey: Self.searchHistoryKey)
        }
    }

    func addSearchToHistory(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var history = UserDefaults.standard.stringArray(forKey: Self.searchHistoryKey) ?? []
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        if history.count > Self.maxStoredHistoryCount {
            history = Array(history.prefix(Self.maxStoredHistoryCount))
        }
        UserDefaults.standard.set(history, forKey: Self.searchHistoryKey)
        searchHistory = history
    }

    func removeSearchHistory(_ text: String) {
        var history = UserDefaults.standard.stringArray(forKey: Self.searchHistoryKey) ?? []
        history.removeAll { $0 == text }
        UserDefaults.standard.set(history, forKey: Self.searchHistoryKey)
        searchHistory = history
    }

    func clearSearchHistory() {
        UserDefaults.standard.removeObject(forKey: Self.searchHistoryKey)
        searchHistory = []
    }

    // MARK: - 搜索建议 (对齐 Android SearchBar.updateSuggestions)
    var suggestions: [(chinese: String, english: String)] = []
    private var suggestionTask: Task<Void, Never>?

    /// 更新搜索建议 (对齐 Android SearchBar.updateSuggestions)
    func updateSuggestions() {
        suggestionTask?.cancel()
        suggestionTask = Task { @MainActor in
            // 防抖 200ms
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }

            guard let extracted = EhTagDatabase.extractLastKeyword(from: searchText) else {
                suggestions = []
                return
            }
            let keyword = extracted.keyword
            // 中文/子串候选可能线性扫描整个标签库。放到 utility 任务，避免
            // 它与键盘、搜索面板或页面切换动画争用主线程。
            let results = await Task.detached(priority: .utility) {
                EhTagDatabase.shared.suggest(keyword, limit: 8)
            }.value
            guard !Task.isCancelled else { return }
            suggestions = results
        }
    }

    /// 应用搜索建议到搜索文本
    func applySuggestion(_ suggestion: String) {
        searchText = EhTagDatabase.applySuggestion(to: searchText, suggestion: suggestion)
        suggestions = []
    }

    private var currentCacheKey: String?
    private var currentMode: GalleryListView.ListMode?
    private(set) var imageSearchURL: URL?
    /// 与 EhPanda cancellable Effect 相同的语义：新的导航/搜索请求会取消旧请求，
    /// 防止较慢的旧响应覆盖用户刚选择的新页面。
    private var requestTask: Task<Void, Never>?
    /// 收藏列表使用服务器生成的游标而非稳定页码。缓存已经走过的游标，
    /// 让重复跳页不必每次都从第一页重新请求，同时不触发界面观察更新。
    @ObservationIgnored
    private var favoriteCursorURLs: [String: [Int: String]] = [:]
    /// 高级搜索参数 (对齐 Android AdvanceSearchTable 状态持久化)
    private var currentAdvanceSearch: Int = -1
    private var currentMinRating: Int = -1
    private var currentPageFrom: Int = -1
    private var currentPageTo: Int = -1
    private var currentCategory: Int = 0
    private var currentSearchMode: SearchMode = .normal
    @ObservationIgnored
    private var persistsDedicatedSearchSession = false
    @ObservationIgnored
    private var didRestoreDedicatedSearchSession = false
    @ObservationIgnored
    private var searchPersistenceTask: Task<Void, Never>?
    @ObservationIgnored
    private var searchRestorationTask: Task<Void, Never>?
    /// In-memory navigation history for searches opened from a result's tag,
    /// uploader, or another metadata link. Keeping complete snapshots (including
    /// opaque EH cursors and the visible anchor) makes Back restore the prior
    /// result set immediately instead of issuing a new request.
    private var dedicatedSearchBackStack: [DedicatedSearchSession] = []
    /// Changes only when a previous result layer is restored. Views use this
    /// generation to re-apply the saved visible anchor after lazy layout.
    var dedicatedSearchRestorationGeneration = 0
    private(set) var dedicatedSearchRestorationAnchor: Int64?

    private struct DedicatedSearchSession: Codable, Sendable {
        let site: Int
        let search: QuickSearchRecord
        let galleries: [GalleryInfo]
        let scrollPosition: Int64?
        let pagination: GalleryPaginationState.Snapshot
        let savedAt: Date
        let imageSearchURL: URL?
    }

    private static let dedicatedSearchSessionKey = "ehDedicatedSearchSession.v1"

    var canRestorePreviousDedicatedSearch: Bool {
        !dedicatedSearchBackStack.isEmpty
    }

    /// Save the currently visible Search page before following a metadata link.
    /// Consecutive requests for the same query do not create duplicate levels.
    func pushDedicatedSearchStateIfNeeded(replacingWith rawQuery: String) {
        let currentKeyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextKeyword = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentKeyword.isEmpty,
              currentKeyword.localizedCaseInsensitiveCompare(nextKeyword) != .orderedSame
        else { return }

        dedicatedSearchBackStack.append(makeDedicatedSearchSession())
        if dedicatedSearchBackStack.count > 20 {
            dedicatedSearchBackStack.removeFirst(dedicatedSearchBackStack.count - 20)
        }
    }

    func discardDedicatedSearchNavigationHistory() {
        dedicatedSearchBackStack.removeAll(keepingCapacity: true)
        dedicatedSearchRestorationAnchor = nil
    }

    @discardableResult
    func restorePreviousDedicatedSearch(into advancedState: AdvancedSearchState) -> Bool {
        guard let session = dedicatedSearchBackStack.popLast() else { return false }
        requestTask?.cancel()
        suggestionTask?.cancel()
        searchRestorationTask?.cancel()
        applyDedicatedSearchSession(session, into: advancedState)
        dedicatedSearchRestorationAnchor = session.scrollPosition
        dedicatedSearchRestorationGeneration &+= 1
        let restorationGeneration = dedicatedSearchRestorationGeneration
        let restorationAnchor = session.scrollPosition
        // Re-applying the anchor on the next layout pass is sufficient; forcing
        // a new identity on the entire list decoded all visible thumbnails and
        // was the main source of stutter during Back.
        scrollPosition = nil
        searchRestorationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.dedicatedSearchRestorationGeneration == restorationGeneration
            else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.scrollPosition = restorationAnchor
            }
        }
        isLoading = false
        errorMessage = nil
        scheduleDedicatedSearchPersistence()
        return true
    }

    /// Restore the persistent Search tab once per scene-owned model. Results and
    /// opaque EH cursors are restored together, so returning to Search does not
    /// silently restart from page one or lose bidirectional pagination.
    func restoreDedicatedSearchSession(into advancedState: AdvancedSearchState) async {
        persistsDedicatedSearchSession = true
        guard !didRestoreDedicatedSearchSession else { return }
        didRestoreDedicatedSearchSession = true
        guard searchText.isEmpty, galleries.isEmpty else { return }

        let session: DedicatedSearchSession? = await Task.detached(priority: .utility) { () -> DedicatedSearchSession? in
            guard let data = UserDefaults.standard.data(forKey: Self.dedicatedSearchSessionKey) else { return nil }
            return try? JSONDecoder().decode(DedicatedSearchSession.self, from: data)
        }.value

        // Search may have been used while the saved result was decoding.
        guard searchText.isEmpty, galleries.isEmpty,
              let session,
              session.site == AppSettings.shared.gallerySite.rawValue,
              let keyword = session.search.keyword,
              !keyword.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
        else { return }

        applyDedicatedSearchSession(session, into: advancedState)
    }

    func scheduleDedicatedSearchPersistence() {
        guard persistsDedicatedSearchSession else { return }
        searchPersistenceTask?.cancel()
        searchPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.persistDedicatedSearchSession()
        }
    }

    private func persistDedicatedSearchSession() {
        guard persistsDedicatedSearchSession else { return }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.dedicatedSearchSessionKey)
            return
        }
        let session = makeDedicatedSearchSession()
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: Self.dedicatedSearchSessionKey)
    }

    private func makeDedicatedSearchSession() -> DedicatedSearchSession {
        DedicatedSearchSession(
            site: AppSettings.shared.gallerySite.rawValue,
            search: currentQuickSearchRecord(),
            galleries: galleries,
            scrollPosition: scrollPosition,
            pagination: pagination.snapshot,
            savedAt: Date(),
            imageSearchURL: imageSearchURL
        )
    }

    private func applyDedicatedSearchSession(
        _ session: DedicatedSearchSession,
        into advancedState: AdvancedSearchState
    ) {
        guard let keyword = session.search.keyword else { return }
        searchText = keyword
        galleries = session.galleries
        scrollPosition = session.scrollPosition
        currentMode = .search(keyword: keyword)
        advancedState.copyValues(from: session.search)
        syncAdvancedSettings(advancedState)
        imageSearchURL = session.imageSearchURL
        pagination.restore(session.pagination, galleries: galleries)
        GalleryCache.shared.putMetadata(galleries)
    }

    func loadGalleries(mode: GalleryListView.ListMode) {
        guard !isLoading else {
            return
        }

        currentMode = mode
        if case .home = mode {
            currentCategory = AppSettings.shared.defaultCategories
        } else if case .subscription = mode {
            currentCategory = AppSettings.shared.defaultCategories
        }

        // 先查缓存 (空结果不视为有效缓存 — 可能是之前网络失败)
        let cacheKey = resolvedCacheKey(for: mode, page: 0)
        if let cached = GalleryCache.shared.getListResult(forKey: cacheKey),
           !cached.galleries.isEmpty,
           cached.galleries.allSatisfy({ !GalleryCache.shared.needsMetadataHydration($0) }) {
            galleries = GalleryCache.shared.mergeCachedMetadata(into: cached.galleries)
            pagination.restore(
                nextPage: cached.nextPage,
                nextHref: cached.nextHref,
                firstHref: cached.firstHref,
                lastHref: cached.lastHref,
                totalPages: cached.totalPages ?? 0,
                hasMore: cached.hasMore
            )
            _ = pagination.merge(cached.galleries, replacing: true)
            currentCacheKey = cacheKey
            return
        }

        isLoading = true
        errorMessage = nil
        pagination.reset()
        currentCacheKey = cacheKey

        startReplacingRequest {
            await self.fetchFirstPageWithTimeout(mode: mode)
        }
    }

    func refresh(mode: GalleryListView.ListMode) {
        // 刷新时清除当前 mode 的缓存
        if let key = currentCacheKey {
            GalleryCache.shared.removeListResult(forKey: key)
        }
        // 不清除 galleries — loadGalleries/fetchPage 成功后会替换
        // 避免列表被清空后触发 ProgressView，导致 .refreshable 任务被 SwiftUI 取消
        isLoading = false  // 重置状态，确保 loadGalleries 不会被 guard 拦截
        loadGalleries(mode: mode)
    }

    /// 异步刷新 — 用于 .refreshable ，等待网络请求完成后才结束下拉动画
    func refreshAsync(mode: GalleryListView.ListMode) async {
        if let key = currentCacheKey {
            GalleryCache.shared.removeListResult(forKey: key)
        }
        // 不清除 galleries、不设置 isLoading = true
        // — 保持旧数据可见，防止 SwiftUI 将 galleryList 替换为 ProgressView
        //   从而取消 .refreshable 的结构化并发任务
        currentMode = mode
        errorMessage = nil
        pagination.reset()
        let cacheKey = resolvedCacheKey(for: mode, page: 0)
        currentCacheKey = cacheKey
        await fetchPage(mode: mode, page: 0)
    }

    func search() {
        imageSearchURL = nil
        guard !searchText.isEmpty else { return }
        scrollPosition = nil
        addSearchToHistory(searchText)
        galleries = []
        isLoading = true
        errorMessage = nil
        pagination.reset()
        // 清除高级搜索参数
        currentAdvanceSearch = -1
        currentMinRating = -1
        currentPageFrom = -1
        currentPageTo = -1
        currentCategory = AppSettings.shared.defaultCategories
        currentSearchMode = .normal

        let keyword = searchText
        startReplacingRequest {
            await self.fetchPage(mode: .search(keyword: keyword), page: 0)
        }
        scheduleDedicatedSearchPersistence()
    }

    func clearDedicatedSearch() {
        imageSearchURL = nil
        suggestionTask?.cancel()
        requestTask?.cancel()
        searchRestorationTask?.cancel()
        searchText = ""
        galleries = []
        suggestions = []
        isLoading = false
        errorMessage = nil
        scrollPosition = nil
        pagination.reset()
        currentCacheKey = nil
        currentMode = .search(keyword: "")
        dedicatedSearchBackStack.removeAll(keepingCapacity: true)
        dedicatedSearchRestorationAnchor = nil
        UserDefaults.standard.removeObject(forKey: Self.dedicatedSearchSessionKey)
    }

    /// 带高级搜索参数的搜索 (对齐 Android AdvanceSearchTable → ListUrlBuilder)
    func searchWithAdvanced(_ state: AdvancedSearchState) {
        imageSearchURL = nil
        scrollPosition = nil
        if !searchText.isEmpty { addSearchToHistory(searchText) }
        currentAdvanceSearch = state.advanceSearchValue
        currentMinRating = state.minRatingValue
        currentPageFrom = state.pageFromValue
        currentPageTo = state.pageToValue
        currentCategory = state.categoryValue
        currentSearchMode = state.searchMode

        // 没有关键字时，按分类过滤首页 (对齐 Android: 无关键字也能按分类搜索)
        if searchText.isEmpty {
            galleries = []
            isLoading = true
            errorMessage = nil
            pagination.reset()
            startReplacingRequest {
                await self.fetchPage(mode: .home, page: 0)
            }
            return
        }

        galleries = []
        isLoading = true
        errorMessage = nil
        pagination.reset()
        let keyword = searchText
        startReplacingRequest {
            await self.fetchPage(mode: .search(keyword: keyword), page: 0)
        }
        scheduleDedicatedSearchPersistence()
    }

    /// 高级搜索面板关闭后自动应用设置 (对齐 Android GalleryListScene.onApplySearch)
    func applyAdvancedSettings(_ state: AdvancedSearchState, initialMode: GalleryListView.ListMode) {
        imageSearchURL = nil
        syncAdvancedSettings(state)

        // 清除缓存，强制使用新参数重新加载
        if let key = currentCacheKey {
            GalleryCache.shared.removeListResult(forKey: key)
        }

        // 有活跃搜索关键字时，重新执行搜索
        if !searchText.isEmpty {
            galleries = []
            isLoading = true
            errorMessage = nil
            pagination.reset()
            let keyword = searchText
            startReplacingRequest {
                await self.fetchPage(mode: .search(keyword: keyword), page: 0)
            }
            return
        }

        // 首页模式: 用分类重新加载
        if case .home = initialMode {
            galleries = []
            isLoading = true
            errorMessage = nil
            pagination.reset()
            startReplacingRequest {
                await self.fetchPage(mode: .home, page: 0)
            }
        }
    }

    /// 静默同步高级搜索参数到 ViewModel (不触发搜索)
    func syncAdvancedSettings(_ state: AdvancedSearchState) {
        currentCategory = state.categoryValue
        currentSearchMode = state.searchMode
        currentAdvanceSearch = state.advanceSearchValue
        currentMinRating = state.minRatingValue
        currentPageFrom = state.pageFromValue
        currentPageTo = state.pageToValue
    }

    func currentQuickSearchRecord() -> QuickSearchRecord {
        var record = QuickSearchRecord(
            name: nil,
            mode: currentSearchMode.listMode,
            category: currentCategory,
            keyword: searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        record.advanceSearch = currentAdvanceSearch
        record.minRating = currentMinRating
        record.pageFrom = currentPageFrom
        record.pageTo = currentPageTo
        return record
    }

    func applyQuickSearch(_ search: QuickSearchRecord) {
        imageSearchURL = nil
        guard let keyword = search.keyword, !keyword.isEmpty else { return }
        searchText = keyword
        galleries = []
        isLoading = true
        errorMessage = nil
        pagination.reset()
        currentMode = .search(keyword: keyword)
        currentCategory = search.category
        let hasAdvancedFilters = search.advanceSearch > 0
            || search.minRating > 0
            || search.pageFrom > 0
            || search.pageTo > 0
        currentAdvanceSearch = hasAdvancedFilters ? search.advanceSearch : -1
        currentMinRating = search.minRating > 0 ? search.minRating : -1
        currentPageFrom = search.pageFrom > 0 ? search.pageFrom : -1
        currentPageTo = search.pageTo > 0 ? search.pageTo : -1
        switch search.mode {
        case ListUrlBuilder.Mode.subscription.rawValue:
            currentSearchMode = .subscription
        case ListUrlBuilder.Mode.uploader.rawValue:
            currentSearchMode = .uploader
        case ListUrlBuilder.Mode.tag.rawValue:
            currentSearchMode = .tag
        default:
            currentSearchMode = .normal
        }

        // 快速搜索与普通搜索共用同一条分页管线，确保筛选条件在后续页面保持一致。
        startReplacingRequest {
            await self.fetchPage(mode: .search(keyword: keyword), page: 0)
        }
        scheduleDedicatedSearchPersistence()
    }

    func loadMore(mode: GalleryListView.ListMode) async {
        guard !isLoading, let request = pagination.nextRequest else { return }

        switch request {
        case .href(let nextHref):
            await fetchCursorPage(nextHref)
        case .page(let targetPage):
            isLoading = true
            await fetchPage(mode: mode, page: targetPage)
        }
    }

    private func fetchCursorPage(_ href: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let result = try await EhAPI.shared.getGalleryList(url: resolvedListHref(href))
            try Task.checkCancellation()

            let pageGalleries = try await enrichedGalleries(result.galleries)

            let appendedGalleries = pagination.merge(pageGalleries, replacing: false)
            galleries.append(contentsOf: appendedGalleries)
            let loadedPage = pagination.lastLoadedPage + 1
            pagination.consume(
                nextPage: result.nextPage,
                firstHref: result.firstHref,
                prevHref: result.prevHref,
                nextHref: result.nextHref,
                lastHref: result.lastHref,
                totalPages: result.pages,
                loadedPage: loadedPage,
                appendedCount: appendedGalleries.count,
                replacing: false
            )
            isLoading = false
            scheduleDedicatedSearchPersistence()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            errorMessage = EhError.localizedMessage(for: error)
            isLoading = false
            scheduleDedicatedSearchPersistence()
        }
    }

    /// 下拉刷新在存在服务器 `prev` 游标时切换到上一页；首屏仍执行普通刷新。
    /// 该逻辑对收藏、普通搜索和标签搜索共用，因此可以连续向前翻页。
    func refreshOrLoadPrevious(mode: GalleryListView.ListMode) async {
        if let previousHref = pagination.prevHref {
            await fetchPreviousPage(previousHref)
        } else {
            await refreshAsync(mode: mode)
        }
    }

    private func fetchPreviousPage(_ href: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let targetPage = max(pagination.firstLoadedPage - 1, 0)
        // Prefer the item that is actually pinned to the scroll viewport. The
        // first loaded item can already be well above the visible region after
        // several page loads, and restoring to it would look like a jump to the
        // top of the list.
        let retainedAnchor = scrollPosition ?? galleries.first?.gid

        do {
            let result = try await EhAPI.shared.getGalleryList(url: resolvedListHref(href))
            try Task.checkCancellation()
            let pageGalleries = try await enrichedGalleries(result.galleries)
            let prependedGalleries = pagination.merge(pageGalleries, replacing: false)
            if !prependedGalleries.isEmpty {
                galleries.insert(contentsOf: prependedGalleries, at: 0)
            }
            pagination.consumePrepending(
                firstHref: result.firstHref,
                prevHref: result.prevHref,
                totalPages: result.pages,
                loadedPage: targetPage,
                prependedCount: prependedGalleries.count
            )
            // Keep the former first row/card stationary after inserting the
            // previous page above it. The user can then continue scrolling
            // upward without a visual jump.
            if let retainedAnchor {
                await Task.yield()
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    scrollPosition = retainedAnchor
                }
            }
            isLoading = false
            scheduleDedicatedSearchPersistence()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            errorMessage = EhError.localizedMessage(for: error)
            isLoading = false
        }
    }

    private func resolvedListHref(_ href: String) -> String {
        if let url = URL(string: href), url.scheme != nil {
            return url.absoluteString
        }
        let base = URL(string: EhURL.host(for: AppSettings.shared.gallerySite))
        return URL(string: href, relativeTo: base)?.absoluteURL.absoluteString ?? href
    }
    
    /// 跳转到指定页 (对齐 Android ContentHelper.goTo(page), 仅 TopList 使用)
    func goToPage(
        _ page: Int,
        mode: GalleryListView.ListMode,
        knownTotalPages: Int? = nil
    ) {
        if case .favorites = mode {
            goToFavoritesPage(page, mode: mode, knownTotalPages: knownTotalPages)
            return
        }
        let availablePages = max(totalPages, knownTotalPages ?? 0)
        guard page >= 0 && page < availablePages else { return }
        
        galleries = []
        isLoading = true
        errorMessage = nil
        pagination.reset()
        currentMode = mode
        
        startReplacingRequest {
            await self.fetchPage(mode: mode, page: page)
        }
    }

    /// 收藏页的 `searchnav` 返回不透明 next/prev URL，`?page=N` 会被部分
    /// EH 节点忽略。沿服务器游标前进到目标页，才能保证跳转真正发生。
    func goToFavoritesPage(
        _ page: Int,
        mode: GalleryListView.ListMode,
        knownTotalPages: Int? = nil
    ) {
        guard case .favorites = mode, page >= 0 else { return }
        if let knownTotalPages, knownTotalPages > 0, page >= knownTotalPages { return }
        beginFavoritesTraversal(mode: mode, targetPage: page, seeksLastPage: false)
    }

    func goToLastFavoritesPage(
        mode: GalleryListView.ListMode,
        knownTotalPages: Int? = nil
    ) {
        guard case .favorites = mode else { return }
        beginFavoritesTraversal(
            mode: mode,
            targetPage: nil,
            seeksLastPage: true,
            knownTotalPages: knownTotalPages
        )
    }

    private func beginFavoritesTraversal(
        mode: GalleryListView.ListMode,
        targetPage: Int?,
        seeksLastPage: Bool,
        knownTotalPages: Int? = nil
    ) {
        let directLastURL = seeksLastPage ? pagination.lastHref.map(resolvedListHref) : nil
        galleries = []
        isLoading = true
        errorMessage = nil
        pagination.reset()
        currentMode = mode
        scrollPosition = nil

        startReplacingRequest {
            await self.traverseFavorites(
                mode: mode,
                targetPage: targetPage,
                seeksLastPage: seeksLastPage,
                directLastURL: directLastURL,
                knownTotalPages: knownTotalPages
            )
        }
    }

    private func traverseFavorites(
        mode: GalleryListView.ListMode,
        targetPage: Int?,
        seeksLastPage: Bool,
        directLastURL: String?,
        knownTotalPages: Int?
    ) async {
        guard case .favorites(let slot) = mode else { return }

        let site = AppSettings.shared.gallerySite
        let normalizedKeyword = favSearchKeyword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = "\(site)-\(slot)-\(normalizedKeyword ?? "")"
        let firstURL = FavListUrlBuilder(
            favCat: slot,
            keyword: normalizedKeyword,
            index: 0
        ).build(site: site)

        var cachedURLs = favoriteCursorURLs[cacheKey] ?? [0: firstURL]
        cachedURLs[0] = firstURL

        let desiredPage = targetPage ?? Int.max

        // 部分 EH 节点仍接受 `page=N`。先进行一次可验证的直达请求：
        // 目标页应当包含 prev 游标；若节点忽略 page 参数并返回首屏，则
        // 不采用该结果，继续走下方可靠的 searchnav 游标链。
        if !seeksLastPage,
           let targetPage,
           targetPage > 0,
           cachedURLs[targetPage] == nil {
            let optimisticURL = FavListUrlBuilder(
                favCat: slot,
                keyword: normalizedKeyword,
                index: targetPage
            ).build(site: site)
            do {
                var directResult = try await EhAPI.shared.getGalleryList(url: optimisticURL)
                try Task.checkCancellation()
                if directResult.prevHref != nil {
                    if let previousURL = directResult.prevHref.map(resolvedListHref) {
                        cachedURLs[targetPage - 1] = previousURL
                    }
                    if let nextURL = directResult.nextHref.map(resolvedListHref) {
                        cachedURLs[targetPage + 1] = nextURL
                    }
                    directResult.galleries = try await enrichedGalleries(directResult.galleries)
                    favoriteCursorURLs[cacheKey] = cachedURLs
                    applyReplacement(directResult, loadedPage: targetPage)
                    isLoading = false
                    return
                }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                // 节点不支持数字页或临时失败时，继续使用可靠的游标遍历。
            }
        }

        let cachedStart = cachedURLs.keys
            .filter { $0 <= desiredPage }
            .max() ?? 0
        var pageIndex = directLastURL == nil ? cachedStart : max((knownTotalPages ?? 1) - 1, 0)
        var pageURL = directLastURL ?? cachedURLs[cachedStart] ?? firstURL
        // 防止异常节点循环返回同一个游标。
        var visitedURLs: Set<String> = []

        do {
            while pageIndex < 2_000, visitedURLs.insert(pageURL).inserted {
                try Task.checkCancellation()
                var result = try await EhAPI.shared.getGalleryList(url: pageURL)
                try Task.checkCancellation()

                let nextURL = result.nextHref.map(resolvedListHref)
                if let nextURL {
                    cachedURLs[pageIndex + 1] = nextURL
                }

                if seeksLastPage,
                   nextURL != nil,
                   let lastURL = result.lastHref.map(resolvedListHref),
                   !visitedURLs.contains(lastURL) {
                    pageIndex = max((knownTotalPages ?? pageIndex + 2) - 1, pageIndex + 1)
                    pageURL = lastURL
                    continue
                }

                let reachedRequestedPage = !seeksLastPage && pageIndex >= desiredPage
                let reachedLastPage = nextURL == nil
                if reachedRequestedPage || reachedLastPage {
                    result.galleries = try await enrichedGalleries(result.galleries)
                    favoriteCursorURLs[cacheKey] = cachedURLs
                    applyReplacement(result, loadedPage: pageIndex)
                    isLoading = false
                    return
                }

                guard let nextURL else { break }
                pageIndex += 1
                pageURL = nextURL
            }

            throw URLError(.cannotParseResponse)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            isLoading = false
            errorMessage = EhError.localizedMessage(for: error)
        }
    }

    /// 通用日期跳转 (对齐 Android GoToDialog: 所有模式统一使用日期选择器)
    func goToDate(_ date: Date, mode: GalleryListView.ListMode) {
        if case .favorites = mode {
            // 收藏模式: ?seek=YYYY-MM-DD
            goToFavoritesDate(date, mode: mode)
        } else {
            // 普通模式: ?next=UNIX_TIMESTAMP (对齐 Android: 日期转时间戳跳转)
            goToNormalDate(date, mode: mode)
        }
    }

    /// 普通画廊按日期跳转 (对齐 Android GoToDialog 普通模式: ?next=TIMESTAMP)
    private func goToNormalDate(_ date: Date, mode: GalleryListView.ListMode) {
        galleries = []
        isLoading = true
        errorMessage = nil
        pagination.reset()
        currentMode = mode
        
        startReplacingRequest {
            await self.fetchNormalSeek(date: date, mode: mode)
        }
    }

    /// 收藏跳转到指定日期 (对齐 Android FavoritesScene: ?seek=YYYY-MM-DD)
    func goToFavoritesDate(_ date: Date, mode: GalleryListView.ListMode) {
        guard case .favorites(let slot) = mode else { return }
        
        galleries = []
        isLoading = true
        errorMessage = nil
        pagination.reset()
        currentMode = mode
        
        startReplacingRequest {
            await self.fetchFavoritesSeek(slot: slot, date: date)
        }
    }

    /// 收藏通过 URL 导航 (prev/next 链接)
    func goToFavoritesHref(_ href: String, mode: GalleryListView.ListMode) {
        let loadedPage: Int
        if href == pagination.prevHref {
            loadedPage = max(pagination.firstLoadedPage - 1, 0)
        } else if href == pagination.nextHref {
            loadedPage = pagination.lastLoadedPage + 1
        } else {
            loadedPage = 0
        }
        galleries = []
        isLoading = true
        errorMessage = nil
        currentMode = mode
        
        startReplacingRequest {
            do {
                let result = try await EhAPI.shared.getGalleryList(url: href)
                try Task.checkCancellation()
                self.applyReplacement(result, loadedPage: loadedPage)
                self.isLoading = false
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return
                }
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
        }
    }

    /// 快捷跳转 (对齐 Android jumpHrefBuild + onTimeSelected)
    /// appendParam 为 "jump=1d" / "seek=2024-01-15" 之类的 URL 追加参数
    func goToJump(_ appendParam: String, mode: GalleryListView.ListMode) {
        galleries = []
        isLoading = true
        errorMessage = nil
        currentMode = mode

        startReplacingRequest {
            let jumpUrl = self.buildJumpUrl(appendParam, mode: mode)
            do {
                let result = try await EhAPI.shared.getGalleryList(url: jumpUrl)
                try Task.checkCancellation()
                self.applyReplacement(result)
                self.isLoading = false
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return
                }
                self.errorMessage = EhError.localizedMessage(for: error)
                self.isLoading = false
            }
        }
    }

    /// 构建跳转 URL (对齐 Android ListUrlBuilder.jumpHrefBuild)
    /// 如果有 nextHref，修改它；否则从当前模式构建基础 URL
    private func buildJumpUrl(_ appendParam: String, mode: GalleryListView.ListMode) -> String {
        var baseUrl: String

        if let href = nextHref, !href.isEmpty {
            baseUrl = href
        } else {
            let site = AppSettings.shared.gallerySite
            switch mode {
            case .home:
                var builder = ListUrlBuilder()
                builder.mode = .normal
                builder.category = currentCategory
                baseUrl = builder.build(site: site)
            case .subscription:
                var builder = ListUrlBuilder()
                builder.mode = .subscription
                builder.category = currentCategory
                baseUrl = builder.build(site: site)
            case .search(let keyword):
                var builder = ListUrlBuilder()
                builder.mode = ListUrlBuilder.Mode(rawValue: currentSearchMode.listMode) ?? .normal
                builder.keyword = keyword
                builder.advanceSearch = currentAdvanceSearch
                builder.minRating = currentMinRating
                builder.pageFrom = currentPageFrom
                builder.pageTo = currentPageTo
                builder.category = currentCategory
                baseUrl = builder.build(site: site)
            case .tag(let keyword):
                let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
                baseUrl = "\(EhURL.host(for: site))tag/\(encoded)"
            case .favorites(let slot):
                if slot < 0 {
                    baseUrl = EhURL.favoritesUrl(for: site)
                } else {
                    baseUrl = "\(EhURL.favoritesUrl(for: site))?favcat=\(slot)"
                }
            case .popular:
                baseUrl = EhURL.popularUrl(for: site)
            }
        }

        // 移除已有的 seek/jump 参数 (对齐 Android jumpHrefBuild 正则替换逻辑)
        baseUrl = baseUrl.replacingOccurrences(
            of: "seek=\\d+-\\d+-\\d+",
            with: "",
            options: .regularExpression
        )
        baseUrl = baseUrl.replacingOccurrences(
            of: "jump=\\d[ymwd]",
            with: "",
            options: .regularExpression
        )
        // 清除残留分隔符
        baseUrl = baseUrl.replacingOccurrences(of: "&&", with: "&")
        baseUrl = baseUrl.replacingOccurrences(of: "?&", with: "?")
        while baseUrl.hasSuffix("?") || baseUrl.hasSuffix("&") {
            baseUrl.removeLast()
        }

        // 追加新参数
        let separator = baseUrl.contains("?") ? "&" : "?"
        return "\(baseUrl)\(separator)\(appendParam)"
    }

    /// 普通画廊按日期跳转 (对齐 Android: ?next=UNIX_TIMESTAMP)
    private func fetchNormalSeek(date: Date, mode: GalleryListView.ListMode) async {
        let site = AppSettings.shared.gallerySite
        let timestamp = Int(date.timeIntervalSince1970)

        // 基于当前模式构建 URL，附加 &next=TIMESTAMP
        var baseUrl: String
        switch mode {
        case .home:
            var builder = ListUrlBuilder()
            builder.mode = .normal
            builder.category = currentCategory
            baseUrl = builder.build(site: site)
        case .subscription:
            return
        case .search(let keyword):
            var builder = ListUrlBuilder()
            builder.mode = ListUrlBuilder.Mode(rawValue: currentSearchMode.listMode) ?? .normal
            builder.keyword = keyword
            builder.advanceSearch = currentAdvanceSearch
            builder.minRating = currentMinRating
            builder.pageFrom = currentPageFrom
            builder.pageTo = currentPageTo
            builder.category = currentCategory
            baseUrl = builder.build(site: site)
        case .tag(let keyword):
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
            baseUrl = "\(EhURL.host(for: site))tag/\(encoded)"
        default:
            // popular 等模式不支持日期跳转
            return
        }

        // 附加 next=TIMESTAMP 参数
        let separator = baseUrl.contains("?") ? "&" : "?"
        let seekUrl = "\(baseUrl)\(separator)next=\(timestamp)"

        do {
            let result = try await EhAPI.shared.getGalleryList(url: seekUrl)
            try Task.checkCancellation()
            self.applyReplacement(result)
            self.isLoading = false
            scheduleDedicatedSearchPersistence()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            self.errorMessage = EhError.localizedMessage(for: error)
            self.isLoading = false
        }
    }

    /// 按日期跳转收藏 (对齐 Android: ?seek=YYYY-MM-DD)
    private func fetchFavoritesSeek(slot: Int, date: Date) async {
        let site = AppSettings.shared.gallerySite
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: date)
        
        var favUrl: String
        if slot < 0 {
            favUrl = "\(EhURL.favoritesUrl(for: site))?seek=\(dateStr)"
        } else {
            favUrl = "\(EhURL.favoritesUrl(for: site))?favcat=\(slot)&seek=\(dateStr)"
        }
        
        if let keyword = favSearchKeyword, !keyword.isEmpty {
            let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
            favUrl += "&f_search=\(encoded)"
        }
        
        do {
            let result = try await EhAPI.shared.getGalleryList(url: favUrl)
            try Task.checkCancellation()
            self.applyReplacement(result)
            self.isLoading = false
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            self.errorMessage = EhError.localizedMessage(for: error)
            self.isLoading = false
        }
    }

    func loadImageSearch(_ url: URL) {
        guard EhAPI.imageSearchResultURL(url.absoluteString, relativeTo: url, site: AppSettings.shared.gallerySite) != nil else { return }
        cancelRequests()
        imageSearchURL = url
        searchText = AppLocalization.localized("以图搜图")
        galleries = []
        scrollPosition = nil
        pagination.reset()
        errorMessage = nil
        isLoading = true
        currentMode = .search(keyword: searchText)
        startReplacingRequest { await self.fetchPage(mode: .search(keyword: self.searchText), page: 0) }
    }

    private func applyReplacement(_ result: GalleryListResult, loadedPage: Int = 0) {
        let replacement = pagination.merge(result.galleries, replacing: true)
        galleries = replacement
        pagination.consume(
            nextPage: result.nextPage,
            firstHref: result.firstHref,
            prevHref: result.prevHref,
            nextHref: result.nextHref,
            lastHref: result.lastHref,
            totalPages: result.pages,
            loadedPage: loadedPage,
            appendedCount: replacement.count,
            replacing: true
        )
    }

    private func startReplacingRequest(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        requestTask?.cancel()
        requestTask = Task {
            await operation()
        }
    }

    func cancelRequests() {
        suggestionTask?.cancel()
        requestTask?.cancel()
        suggestionTask = nil
        requestTask = nil
        isLoading = false
    }

    /// 使用结构化任务竞争网络请求与超时；取消父任务时两者会一起取消，
    /// 不再遗留一个稍后回写界面状态的孤立 timeout Task。
    private func fetchFirstPageWithTimeout(mode: GalleryListView.ListMode) async {
        let didTimeout = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                await self.fetchPage(mode: mode, page: 0)
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(20))
                    return !Task.isCancelled
                } catch {
                    return false
                }
            }

            let firstResult = await group.next() ?? false
            group.cancelAll()
            return firstResult
        }

        if didTimeout, isLoading, galleries.isEmpty {
            isLoading = false
            errorMessage = AppLocalization.localized("网络请求超时，请检查网络连接或 VPN 设置后重试")
        }
    }

    private func fetchPage(mode: GalleryListView.ListMode, page: Int) async {
        let performanceInterval = PerformanceDiagnostics.begin("GalleryListFetch")
        defer { performanceInterval.end() }

        do {
            let site = AppSettings.shared.gallerySite
            let host = EhURL.host(for: site)
            let urlString: String

            switch mode {
            case .home:
                var builder = ListUrlBuilder()
                builder.mode = .normal
                builder.pageIndex = page
                builder.category = currentCategory
                urlString = builder.build(site: site)
            case .subscription:
                var builder = ListUrlBuilder()
                builder.mode = .subscription
                builder.pageIndex = page
                builder.category = currentCategory
                urlString = builder.build(site: site)
            case .popular:
                urlString = EhURL.popularUrl(for: site)
            case .search(let keyword):
                if let imageSearchURL {
                    var components = URLComponents(url: imageSearchURL, resolvingAgainstBaseURL: true)!
                    if page > 0 {
                        var items = components.queryItems ?? []
                        items.removeAll { $0.name == "page" }
                        items.append(URLQueryItem(name: "page", value: String(page)))
                        components.queryItems = items
                    }
                    urlString = components.url!.absoluteString
                    break
                }
                var builder = ListUrlBuilder()
                builder.mode = ListUrlBuilder.Mode(rawValue: currentSearchMode.listMode) ?? .normal
                builder.keyword = keyword
                builder.pageIndex = page
                builder.advanceSearch = currentAdvanceSearch
                builder.minRating = currentMinRating
                builder.pageFrom = currentPageFrom
                builder.pageTo = currentPageTo
                builder.category = currentCategory
                urlString = builder.build(site: site)
            case .tag(let keyword):
                let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
                if page > 0 {
                    urlString = "\(host)tag/\(encoded)/\(page)"
                } else {
                    urlString = "\(host)tag/\(encoded)"
                }
            case .favorites(let slot):
                // slot -1 = 全部收藏, 0-9 = 指定收藏夹 (对齐 Android FavoritesScene)
                var favUrl: String
                if slot < 0 {
                    favUrl = "\(EhURL.favoritesUrl(for: site))?page=\(page)"
                } else {
                    favUrl = "\(EhURL.favoritesUrl(for: site))?favcat=\(slot)&page=\(page)"
                }
                // 收藏搜索 (对齐 Android FavoritesScene.onGetFavoritesSuccess)
                if let keyword = favSearchKeyword, !keyword.isEmpty {
                    let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
                    favUrl += "&f_search=\(encoded)"
                }
                urlString = favUrl
            }

            // EhAPI builds several URL sessions and disk caches on first use.
            // Resolve the singleton on a utility executor so a cold first
            // request suspends the main actor instead of constructing it there.
            let api = await Task.detached(priority: .utility) { EhAPI.shared }.value
            let result = try await api.getGalleryList(url: urlString)
            try Task.checkCancellation()

            let pageGalleries = try await enrichedGalleries(result.galleries)

            let appendedGalleries = pagination.merge(pageGalleries, replacing: page == 0)

            if page == 0 {
                self.galleries = appendedGalleries
            } else {
                self.galleries.append(contentsOf: appendedGalleries)
            }
            pagination.consume(
                nextPage: result.nextPage,
                firstHref: result.firstHref,
                prevHref: result.prevHref,
                nextHref: result.nextHref,
                lastHref: result.lastHref,
                totalPages: result.pages,
                loadedPage: page,
                appendedCount: appendedGalleries.count,
                replacing: page == 0
            )
            self.isLoading = false
            scheduleDedicatedSearchPersistence()

            // 缓存第一页结果
            if page == 0 {
                let cacheKey = resolvedCacheKey(for: mode, page: 0)
                GalleryCache.shared.putListResult(
                    CachedGalleryListResult(
                        galleries: self.galleries,
                        hasMore: self.hasMore,
                        nextPage: result.nextPage,
                        nextHref: result.nextHref,
                        firstHref: result.firstHref,
                        lastHref: result.lastHref,
                        totalPages: self.totalPages
                    ),
                    forKey: cacheKey
                )
            }

        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            self.isLoading = false
            self.errorMessage = EhError.localizedMessage(for: error)
        }
    }

    /// 列表 HTML 信息不完整时，优先复用内存元数据，再按需通过 gdata
    /// 补全语言、作者和标签。补全失败不阻塞列表，取消则继续向上传递。
    private func enrichedGalleries(_ galleries: [GalleryInfo]) async throws -> [GalleryInfo] {
        var result = GalleryCache.shared.mergeCachedMetadata(into: galleries)
        var missing = result.filter { GalleryCache.shared.needsMetadataHydration($0) }

        if !missing.isEmpty {
            do {
                try await EhAPI.shared.fillGalleryListByApi(galleries: &missing)
                try Task.checkCancellation()
                GalleryCache.shared.putMetadata(missing, markHydrated: true)
                let hydratedByGID = Dictionary(
                    uniqueKeysWithValues: missing.map { ($0.gid, $0) }
                )
                result = result.map { hydratedByGID[$0.gid] ?? $0 }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                debugLog("Gallery metadata hydration failed: \(error)")
            }
        }

        GalleryCache.shared.putMetadata(result)
        return result
    }

    /// 生成缓存 key
    private func resolvedCacheKey(for mode: GalleryListView.ListMode, page: Int) -> String {
        if let imageSearchURL { return "image:\(imageSearchURL.absoluteString):\(page)" }
        return Self.cacheKey(for: mode, page: page)
    }

    private static func cacheKey(for mode: GalleryListView.ListMode, page: Int) -> String {
        let site = AppSettings.shared.gallerySite.rawValue
        switch mode {
        case .home: return "\(site):home:\(page)"
        case .subscription: return "\(site):subscription:\(page)"
        case .popular: return "\(site):popular:\(page)"
        case .search(let kw): return "\(site):search:\(kw):\(page)"
        case .tag(let kw): return "\(site):tag:\(kw):\(page)"
        case .favorites(let slot): return "\(site):fav:\(slot):\(page)"
        }
    }

}

#if os(iOS)
// iOS already has secondarySystemBackground
#else
extension NSColor {
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
}
#endif

#Preview {
    GalleryListView(mode: .home)
}
