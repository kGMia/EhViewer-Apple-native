//
//  MainTabView.swift
//  ehviewer apple
//
//  主导航: TabView (iOS) / 三栏 NavigationSplitView (macOS)
//

import SwiftUI
import EhModels
import EhDatabase
import EhSettings
#if os(iOS)
import UIKit
#else
import AppKit
#endif

private struct SelectedMainTabKey: FocusedValueKey {
    typealias Value = Binding<MainTabView.Tab>
}

struct BrowserCommandActions {
    let refresh: () -> Void
    let focusSearch: () -> Void
    let toggleDisplayMode: () -> Void
}

struct MainNavigationActions {
    let openGallery: (GalleryInfo) -> Void
}

private struct BrowserCommandActionsKey: FocusedValueKey {
    typealias Value = BrowserCommandActions
}

private struct MainNavigationActionsKey: FocusedValueKey {
    typealias Value = MainNavigationActions
}

extension FocusedValues {
    var selectedMainTab: Binding<MainTabView.Tab>? {
        get { self[SelectedMainTabKey.self] }
        set { self[SelectedMainTabKey.self] = newValue }
    }

    var browserCommandActions: BrowserCommandActions? {
        get { self[BrowserCommandActionsKey.self] }
        set { self[BrowserCommandActionsKey.self] = newValue }
    }

    var mainNavigationActions: MainNavigationActions? {
        get { self[MainNavigationActionsKey.self] }
        set { self[MainNavigationActionsKey.self] = newValue }
    }
}

struct MainTabView: View {
    #if os(macOS)
    @AppStorage("showsMainWindowToolbar") private var showsMainWindowToolbar = false
    #endif

    @Environment(AppState.self) private var appState
    /// 每个窗口独立恢复上次所在页面；App Intent 的显式导航请求仍具有更高优先级。
    @SceneStorage("main.selectedTab") private var restoredSelectedTabRawValue = ""
    @SceneStorage("main.selectedGallery") private var restoredSelectedGalleryPayload = ""
    @State private var selectedTab: Tab = {
        let launchTab = Tab.fromLaunchPage(AppSettings.shared.launchPage)
        #if os(macOS)
        return launchTab
        #else
        return Tab.bottomTabSafe(launchTab)
        #endif
    }()
    /// “我的”子页由主导航持有，不再随横竖屏分支重建而回到收藏。
    @State private var selectedMoreSection: Tab?
    /// 剪贴板打开画廊 (iOS sheet 展示)
    @State private var clipboardGallery: GalleryInfo?
    @State private var selectedGallery: GalleryInfo? = Self.uiTestGallery
    @State private var searchViewModel = GalleryListViewModel()
    @State private var searchAdvancedState = AdvancedSearchState()
    @State private var homeViewModel = GalleryListViewModel()
    @State private var subscriptionViewModel = GalleryListViewModel()
    @State private var popularViewModel = GalleryListViewModel()
    @State private var contentRoutes: [ContentRoute] = []
    @State private var compactPath: [CompactDestination] = []
    @State private var intentReaderRoute: ReaderWindowRoute?
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @AppStorage("main.preferredSidebarWidth") private var sidebarColumnWidth = 180.0
    @AppStorage("main.preferredFeedWidth") private var feedColumnWidth = 520.0
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .content
    @State private var preservesSelectionDuringTabChange = false
    @State private var searchReturnContext: SearchReturnContext?
    @State private var dedicatedSearchFocusRequest = 0
    @State private var dedicatedSearchNavigationResetRequest = 0
    @State private var dedicatedSearchPresentationTask: Task<Void, Never>?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #else
    @Environment(\.openWindow) private var openWindow
    #endif

    private enum ContentRoute: Hashable {
        case tag(String)
        case uploader(String)
        case search(String)

        var listMode: GalleryListView.ListMode {
            switch self {
            case .tag(let tag): return .tag(keyword: tag)
            case .uploader(let keyword): return .search(keyword: keyword)
            case .search(let keyword): return .search(keyword: keyword)
            }
        }
    }

    /// Root feeds and in-place search routes must not share SwiftUI state.
    /// Otherwise a popped tag route can leave its GalleryListView view model
    /// on screen, making the back button appear to do nothing.
    private enum ContentColumnIdentity: Hashable {
        case root(Tab)
        case route(ContentRoute)
    }

    /// macOS does not automatically collapse NavigationSplitView when its
    /// window becomes narrow. A real NavigationStack supplies the native
    /// single-column push/pop behavior in that size class.
    private enum CompactDestination: Hashable {
        case gallery(GalleryInfo)
        case content(ContentRoute)
    }

    private static var uiTestGallery: GalleryInfo? {
        #if os(macOS)
        guard let gidText = ProcessInfo.processInfo.environment["EH_UI_TEST_GALLERY_GID"],
              let gid = Int64(gidText) else { return nil }
        return GalleryInfo(
            gid: gid,
            token: "uitesttoken",
            title: "UI Test Gallery",
            category: .manga,
            pages: 3
        )
        #else
        return nil
        #endif
    }

    enum Tab: String, CaseIterable {
        case home = "首页"
        case search = "搜索"
        case subscription = "订阅"
        case popular = "热门"
        case toplist = "排行榜"
        case favorites = "收藏"
        case watchLater = "稍后再看"
        case downloads = "下载"
        case history = "历史"
        case settings = "设置"
        case more = "我的"

        var localizedTitle: String {
            AppLocalization.localized(rawValue)
        }

        var icon: String {
            switch self {
            case .home: return "house"
            case .search: return "magnifyingglass"
            case .subscription: return "star.bubble"
            case .popular: return "flame"
            case .toplist: return "chart.bar"
            case .favorites: return "heart"
            case .watchLater: return "bookmark"
            case .downloads: return "arrow.down.circle"
            case .history: return "clock"
            case .settings: return "gear"
            case .more: return "person.crop.circle"
            }
        }

        /// iOS 的四个一级入口。收藏、下载、历史和设置统一收纳在“我的”。
        static var defaultBottomTabs: [Tab] { [.home, .subscription, .more, .search] }

        /// “我的”中的个人内容与设置入口。
        static var accountTabs: [Tab] { [.favorites, .watchLater, .downloads, .history, .settings] }

        /// macOS 仍采用原生侧边栏；排行榜并入搜索页，不再重复占用入口。
        static var sidebarTabs: [Tab] {
            [.home, .search, .subscription, .favorites, .watchLater, .downloads, .history, .settings]
        }

        /// 启动页面设置映射
        static func fromLaunchPage(_ page: Int) -> Tab {
            switch page {
            case 1: return .popular
            case 2: return .toplist
            case 3: return .favorites
            case 4: return .downloads
            case 5: return .history
            case 6: return .subscription
            default: return .home
            }
        }

        /// 将旧启动页/深层链接映射到新的四入口导航。
        static func bottomTabSafe(_ tab: Tab) -> Tab {
            switch tab {
            case .favorites, .watchLater, .downloads, .history, .settings, .more:
                return .more
            case .search, .toplist:
                return .search
            case .subscription:
                return .subscription
            case .home, .popular:
                return .home
            }
        }
    }

    /// A metadata search temporarily leaves a gallery for the persistent
    /// Search section. Store the gallery and its section independently from
    /// the active selection so normal tab changes cannot lose the return path.
    private struct SearchReturnContext {
        let gallery: GalleryInfo
        let tab: Tab
    }

    var body: some View {
        Group {
            #if os(macOS)
            GeometryReader { geometry in
                let usesCompactNavigation = !Self.forcesWideUITestNavigation
                    && (geometry.size.width < 900 || Self.forcesCompactUITestNavigation)
                Group {
                    if usesCompactNavigation {
                        compactMacView
                    } else {
                        adaptiveSplitView(isCompactWindow: false)
                    }
                }
                .onChange(of: usesCompactNavigation, initial: true) { _, isCompact in
                    synchronizeNavigation(forCompactWindow: isCompact)
                }
            }
            #else
            GeometryReader { geometry in
                let layout = ResponsiveLayout(
                    size: geometry.size,
                    horizontalSizeClass: horizontalSizeClass
                )
                let usesWideColumns = AppSettings.shared.wideScreenListMode == 0
                    && horizontalSizeClass == .regular
                    && geometry.size.width >= 820
                    && geometry.size.width > geometry.size.height
                Group {
                    if usesWideColumns {
                        iPadWideTabView
                    } else {
                        compactAdaptiveView
                    }
                }
                .environment(\.responsiveLayout, layout)
                .onChange(of: usesWideColumns, initial: true) { _, isWide in
                    if !isWide {
                        if Tab.accountTabs.contains(selectedTab) {
                            // 这是同一页面在窄导航中的映射，不是用户切换栏目。
                            // 保留正在显示的画廊详情，避免旋转时被清空。
                            preservesSelectionDuringTabChange = true
                            selectedMoreSection = selectedTab
                        }
                        selectedTab = Tab.bottomTabSafe(selectedTab)
                    }
                }
            }
            // Keep the root layout's proposal independent from software-keyboard
            // avoidance. Otherwise focusing Search shortens GeometryReader and
            // can make a portrait iPad look wider than it is tall.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            #endif
        }
        .accessibilityIdentifier("main.browser")
        .environment(
            \.gallerySearchNavigationAction,
            GallerySearchNavigationAction(
                focusSearch: openDedicatedSearchField,
                search: { query, advancedState in
                    openDedicatedSearch(query, advancedState: advancedState)
                },
                searchFromGallery: { query, gallery in
                    openDedicatedSearch(
                        query,
                        advancedState: nil,
                        returnContext: SearchReturnContext(gallery: gallery, tab: selectedTab)
                    )
                },
                quickSearch: openDedicatedQuickSearch,
                imageSearch: openDedicatedImageSearch
            )
        )
        .environment(
            \.readerPresentationAction,
            ReaderPresentationAction { route in
                intentReaderRoute = route
            }
        )
        .onChange(of: selectedTab) { _, newTab in
            restoredSelectedTabRawValue = newTab.rawValue
            if Tab.accountTabs.contains(newTab) {
                selectedMoreSection = newTab
            }
            if newTab != .search {
                searchReturnContext = nil
            }
            if preservesSelectionDuringTabChange {
                preservesSelectionDuringTabChange = false
                return
            }
            clearTransientNavigation()
        }
        .onChange(of: selectedGallery) { _, gallery in
            if gallery != nil {
                preferredCompactColumn = .detail
            }
            restoredSelectedGalleryPayload = Self.encodeRestoredGallery(gallery)
        }
        .task {
            await searchViewModel.restoreDedicatedSearchSession(into: searchAdvancedState)
            if let gallery = appState.pendingIncomingGallery {
                appState.pendingIncomingGallery = nil
                openIncomingGallery(gallery)
            } else if let route = AppNavigationRequest.consumePendingReader() {
                openIntentReader(route)
            } else if let query = AppNavigationRequest.consumePendingSearch() {
                openIntentSearch(query)
            } else if let section = AppNavigationRequest.consumePending() {
                openIntentSection(section)
            } else if let restoredTab = Tab(rawValue: restoredSelectedTabRawValue) {
                #if os(macOS)
                selectedTab = restoredTab
                #else
                if Tab.accountTabs.contains(restoredTab) {
                    selectedMoreSection = restoredTab
                }
                selectedTab = Tab.bottomTabSafe(restoredTab)
                #endif
            } else {
                restoredSelectedTabRawValue = selectedTab.rawValue
            }
            // Allow a restored tab change to commit before presenting its
            // gallery. Otherwise the tab's onChange cleanup can erase the
            // detail selection a frame later.
            await Task.yield()
            if selectedGallery == nil,
               let restoredGallery = Self.decodeRestoredGallery(restoredSelectedGalleryPayload) {
                selectedGallery = restoredGallery
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppNavigationRequest.notification)) { notification in
            guard let rawValue = notification.object as? String,
                  let section = EhViewerIntentSection(rawValue: rawValue)
            else { return }
            // 已运行时通知会先到；同时清掉用于冷启动兜底的待处理值。
            _ = AppNavigationRequest.consumePending()
            openIntentSection(section)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppNavigationRequest.searchNotification)) { notification in
            guard let query = notification.object as? String else { return }
            _ = AppNavigationRequest.consumePendingSearch()
            openIntentSearch(query)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppNavigationRequest.readerNotification)) { notification in
            guard let route = notification.object as? ReaderWindowRoute else { return }
            _ = AppNavigationRequest.consumePendingReader()
            openIntentReader(route)
        }
        .onChange(of: appState.pendingIncomingGallery) { _, gallery in
            guard let gallery else { return }
            appState.pendingIncomingGallery = nil
            openIncomingGallery(gallery)
        }
        // Focused commands drive the native macOS and iPadOS 26 menu bars.
        .focusedSceneValue(\.selectedMainTab, $selectedTab)
        .focusedSceneValue(
            \.mainNavigationActions,
            MainNavigationActions(openGallery: openNavigationGallery)
        )
        .onReceive(NotificationCenter.default.publisher(for: .openGalleryFromClipboard)) { notification in
            guard let userInfo = notification.userInfo,
                  let gid = userInfo["gid"] as? Int64,
                  let token = userInfo["token"] as? String else { return }
            let gallery = GalleryInfo(gid: gid, token: token)
            openIncomingGallery(gallery)
        }
        #if os(iOS)
        .fullScreenCover(item: $intentReaderRoute) { route in
            ImageReaderView(
                gid: route.gid,
                token: route.token,
                pages: route.pages,
                previewSet: route.previewSet,
                initialPage: route.initialPage
            )
        }
        .sheet(item: $clipboardGallery) { gallery in
            NavigationStack {
                GalleryDetailView(gallery: gallery)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { clipboardGallery = nil }
                        }
                    }
            }
        }
        #endif
    }

    private static func encodeRestoredGallery(_ gallery: GalleryInfo?) -> String {
        guard let gallery,
              let data = try? JSONEncoder().encode(gallery)
        else { return "" }
        return data.base64EncodedString()
    }

    private static func decodeRestoredGallery(_ payload: String) -> GalleryInfo? {
        guard !payload.isEmpty,
              let data = Data(base64Encoded: payload)
        else { return nil }
        return try? JSONDecoder().decode(GalleryInfo.self, from: data)
    }

    private func adaptiveSplitView(isCompactWindow: Bool) -> some View {
        NavigationSplitView(
            columnVisibility: $splitVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            List(selection: Binding<Tab?>(
                get: { selectedTab },
                set: { if let tab = $0 { selectedTab = tab } }
            )) {
                ForEach(Tab.sidebarTabs, id: \.self) { tab in
                    Label(tab.localizedTitle, systemImage: tab.icon)
                        .tag(tab)
                        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                        .accessibilityIdentifier("sidebar.tab.\(tab.rawValue)")
                }
            }
            .accessibilityIdentifier("main.sidebar")
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("EhViewer")
            .frame(minWidth: 160)
            .navigationSplitViewColumnWidth(min: 160, ideal: sidebarColumnWidth, max: 320)
            .onGeometryChange(for: Double.self) { Double($0.size.width.rounded()) } action: { width in
                if isAdjustingSplitDivider, width >= 160, width <= 320, sidebarColumnWidth != width {
                    sidebarColumnWidth = width
                }
            }
        } content: {
            adaptiveContentView
                .frame(minWidth: 460)
                .navigationSplitViewColumnWidth(min: 460, ideal: max(460, feedColumnWidth), max: 900)
                .onGeometryChange(for: Double.self) { Double($0.size.width.rounded()) } action: { width in
                    if isAdjustingSplitDivider, width >= 460, width <= 900, feedColumnWidth != width {
                        feedColumnWidth = width
                    }
                }
        } detail: {
            NavigationStack {
                Group {
                    if let gallery = selectedGallery {
                        GalleryDetailView(gallery: gallery)
                            .id(gallery.gid)
                            .environment(
                                \.galleryDetailBackAction,
                                isCompactWindow
                                    ? GalleryDetailBackAction {
                                        selectedGallery = nil
                                        preferredCompactColumn = .content
                                    }
                                    : nil
                            )
                            .navigationBarBackButtonHidden(isCompactWindow)
                    } else {
                        ContentUnavailableView("选择画廊", systemImage: "photo.stack", description: Text("从列表选择一个画廊"))
                    }
                }
            }
            .environment(\.tagNavigationAction, TagNavigationAction { tag in
                openDedicatedSearch(tag, advancedState: nil)
            })
            .environment(\.uploaderSearchNavigationAction, UploaderSearchNavigationAction { keyword in
                openDedicatedSearch(keyword, advancedState: nil)
            })
        }
        .navigationSplitViewStyle(.balanced)
        #if os(macOS)
        // Hiding windowToolbar also removes the system traffic lights.
        // Hide only its background so window controls remain available.
        .toolbarBackgroundVisibility(showsMainWindowToolbar ? .automatic : .hidden, for: .windowToolbar)
        #endif
    }

    /// Save user divider adjustments, never provisional launch geometry or a
    /// column compressed by resizing the window. Defaults survive a fresh scene.
    private var isAdjustingSplitDivider: Bool {
        #if os(macOS)
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDragged,
              let window = event.window else { return false }
        return !window.inLiveResize
        #else
        return false
        #endif
    }

    #if os(macOS)
    private static var forcesCompactUITestNavigation: Bool {
        ProcessInfo.processInfo.environment["EH_UI_TEST_COMPACT"] == "1"
    }

    private static var forcesWideUITestNavigation: Bool {
        ProcessInfo.processInfo.environment["EH_UI_TEST_WIDE"] == "1"
    }

    private var compactMacView: some View {
        NavigationStack(path: $compactPath) {
            compactMacRootContent(for: selectedTab)
                .navigationDestination(for: CompactDestination.self) { destination in
                    compactDestinationView(destination)
                }
        }
        .overlay(alignment: .bottomLeading) {
            if compactPath.isEmpty {
                compactSectionMenu
                    .padding(12)
            }
        }
        .toolbarBackgroundVisibility(
            showsMainWindowToolbar || !compactPath.isEmpty ? .automatic : .hidden,
            for: .windowToolbar
        )

    }

    @ViewBuilder
    private func compactMacRootContent(for tab: Tab) -> some View {
        switch tab {
        case .home:
            GalleryListView(
                mode: .home,
                selection: compactGallerySelection,
                persistentViewModel: homeViewModel
            )
        case .search:
            persistentSearchView(selection: compactGallerySelection)
        case .subscription:
            GalleryListView(
                mode: .subscription,
                selection: compactGallerySelection,
                persistentViewModel: subscriptionViewModel
            )
        case .popular:
            GalleryListView(
                mode: .popular,
                selection: compactGallerySelection,
                persistentViewModel: popularViewModel
            )
        case .toplist:
            TopListView(selection: compactGallerySelection)
        case .favorites:
            FavoritesView(selection: compactGallerySelection)
        case .watchLater:
            WatchLaterView(selection: compactGallerySelection)
        case .downloads:
            DownloadsView(isPushed: true)
        case .history:
            HistoryView(selection: compactGallerySelection)
        case .settings:
            SettingsView(isPushed: true)
        case .more:
            EmptyView()
        }
    }

    @ViewBuilder
    private func compactDestinationView(_ destination: CompactDestination) -> some View {
        switch destination {
        case .gallery(let gallery):
            GalleryDetailView(gallery: gallery)
                .id(gallery.gid)
                .environment(
                    \.galleryDetailBackAction,
                    GalleryDetailBackAction(perform: popCompactDestination)
                )
                .environment(\.tagNavigationAction, TagNavigationAction { tag in
                    openDedicatedSearch(tag, advancedState: nil)
                })
                .environment(\.uploaderSearchNavigationAction, UploaderSearchNavigationAction { keyword in
                    openDedicatedSearch(keyword, advancedState: nil)
                })
                .navigationBarBackButtonHidden(true)
                // NavigationStack destinations are transparent on macOS by
                // default; give the single-column detail an opaque surface so
                // the feed beneath cannot show through during/after the push.
                .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
                .accessibilityIdentifier("gallery.detail.compact")

        case .content(let route):
            Group {
                if case .search = route {
                    persistentSearchView(selection: compactGallerySelection)
                } else {
                    GalleryListView(mode: route.listMode, selection: compactGallerySelection)
                        .id(ContentColumnIdentity.route(route))
                }
            }
                .environment(
                    \.contentRouteBackAction,
                    ContentRouteBackAction { popCompactContentRoute(route) }
                )
                .navigationBarBackButtonHidden(true)
        }
    }

    private var compactSectionMenu: some View {
        Menu {
            ForEach(Tab.sidebarTabs, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(tab.localizedTitle, systemImage: tab.icon)
                }
            }
        } label: {
            Label(selectedTab.localizedTitle, systemImage: selectedTab.icon)
                .padding(.horizontal, 10)
                .frame(height: 34)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("切换栏目")
    }

    private var compactGallerySelection: Binding<GalleryInfo?> {
        Binding(
            get: { selectedGallery },
            set: { gallery in
                guard let gallery else {
                    selectedGallery = nil
                    return
                }
                selectedGallery = gallery
                withAnimation(.smooth(duration: 0.28)) {
                    compactPath.append(.gallery(gallery))
                }
            }
        )
    }

    private func pushCompactContentRoute(_ route: ContentRoute) {
        pushContentRoute(route)
        selectedGallery = nil
        withAnimation(.smooth(duration: 0.28)) {
            compactPath.append(.content(route))
        }
    }

    private func popCompactContentRoute(_ route: ContentRoute) {
        guard compactPath.last == .content(route) else { return }
        withAnimation(.smooth(duration: 0.28)) {
            compactPath.removeLast()
            if contentRoutes.last == route {
                contentRoutes.removeLast()
            }
            synchronizeSelection(with: compactPath)
        }
    }

    private func popCompactDestination() {
        guard !compactPath.isEmpty else { return }
        withAnimation(.smooth(duration: 0.28)) {
            compactPath.removeLast()
            synchronizeSelection(with: compactPath)
        }
    }

    private func synchronizeSelection(with path: [CompactDestination]) {
        if case .gallery(let gallery) = path.last {
            selectedGallery = gallery
        } else {
            selectedGallery = nil
        }
    }

    private func synchronizeNavigation(forCompactWindow isCompact: Bool) {
        guard isCompact else {
            compactPath.removeAll()
            return
        }
        guard compactPath.isEmpty else { return }
        // Preserve both levels when narrowing a window with an open detail
        // inside tag/uploader search. Back should return to that same feed.
        var destinations: [CompactDestination] = []
        if let route = contentRoutes.last {
            destinations.append(.content(route))
        }
        if let gallery = selectedGallery {
            destinations.append(.gallery(gallery))
        }
        compactPath = destinations
    }
    #endif

    private var compactTabView: some View {
        // Compact navigation exposes exactly four primary destinations.
        // Adding sidebarOnly account tabs here makes compact TabView overflow
        // them into an automatic “More” item next to our explicit “我的”.
        // Wide iPad and macOS sidebars keep the direct account shortcuts.
        TabView(selection: nativeTabSelection) {
            ForEach(Tab.defaultBottomTabs, id: \.self) { tab in
                SwiftUI.Tab(
                    tab.localizedTitle,
                    systemImage: tab.icon,
                    value: tab,
                    role: tab == .search ? .search : nil
                ) {
                    tabContent(tab)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSearchActivation(.searchTabSelection)
        #if os(iOS)
        .toolbarBackground(.hidden, for: .tabBar)
        #endif
    }

    /// TabView 的 binding setter 在用户再次点按已选中的搜索 Tab 时仍会
    /// 收到赋值。借此触发自定义搜索框，而无需拦截平台控制器或替换系统
    /// Tab 行为。
    private var nativeTabSelection: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == .search && selectedTab == .search {
                    requestDedicatedSearchFocus(true)
                }
                if newTab == .more && (selectedTab != .more || selectedMoreSection != nil) {
                    // 用户主动进入或再次点按“我的”时回到清晰的入口页。
                    // 旋转和 App Intent 不经过这个 setter，因此仍会保留/直达子页。
                    selectedMoreSection = nil
                    selectedGallery = nil
                }
                selectedTab = newTab
            }
        )
    }

    #if os(iOS)
    /// iPad landscape keeps the system top tab bar while each destination
    /// owns a native list/detail split. The previous three-column branch
    /// bypassed TabView entirely, so iPadOS could not present its top tabs.
    private var iPadWideTabView: some View {
        TabView(selection: nativeTabSelection) {
            ForEach(Tab.defaultBottomTabs, id: \.self) { tab in
                SwiftUI.Tab(
                    tab.localizedTitle,
                    systemImage: tab.icon,
                    value: tab,
                    role: tab == .search ? .search : nil
                ) {
                    iPadWideContent(for: tab)
                        // Tab bar appearance is a per-destination preference.
                        // Applying it only to TabView is lost when iPadOS
                        // lazily swaps a destination, causing the white strip
                        // to reappear after some tab/rotation transitions.
                        .toolbarBackground(.hidden, for: .tabBar)
                }
            }

            ForEach(Tab.accountTabs, id: \.self) { tab in
                SwiftUI.Tab(tab.localizedTitle, systemImage: tab.icon, value: tab) {
                    iPadWideContent(for: tab)
                        .toolbarBackground(.hidden, for: .tabBar)
                }
                .tabPlacement(.sidebarOnly)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Let iPadOS choose its native floating/sidebar presentation. Forcing
        // `.tabBar` creates an opaque full-width strip in iPadOS 26 instead of
        // the system's adaptive glass appearance.
        .toolbarBackground(.hidden, for: .tabBar)
        .toolbar(removing: .sidebarToggle)
        // iPadOS 的顶部 Tab 会占用安全区，但内容背景默认只从安全区下方
        // 开始，旋转/切页时便会露出一条不透明白带。只让背景延伸到顶部，
        // 不移动实际控件，保留状态栏与系统 Tab 的安全布局。
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    @ViewBuilder
    private func iPadWideContent(for tab: Tab) -> some View {
        if tab == .more {
            MoreTabView(
                prefersSplitNavigation: true,
                selectedSection: $selectedMoreSection,
                selectedGallery: $selectedGallery
            )
        } else {
            // A two-column NavigationSplitView styles its leading column as a
            // sidebar on iPadOS. The browser is a feed/detail workspace, so a
            // fixed content split gives it the same visual hierarchy as macOS
            // without introducing another sidebar or collapse button.
            GeometryReader { proxy in
                let contentWidth = min(max(proxy.size.width * 0.42, 400), 580)
                HStack(spacing: 0) {
                    NavigationStack {
                        adaptiveRootContent(for: tab)
                            .toolbar(.hidden, for: .navigationBar)
                    }
                    .frame(width: contentWidth)
                    .background { Rectangle().fill(.background) }

                    Divider()

                    NavigationStack {
                        if let gallery = selectedGallery {
                            GalleryDetailView(gallery: gallery)
                                .id(gallery.gid)
                                .environment(
                                    \.galleryDetailBackAction,
                                    GalleryDetailBackAction {
                                        withAnimation(.smooth(duration: 0.22)) {
                                            selectedGallery = nil
                                        }
                                    }
                                )
                        } else {
                            ContentUnavailableView(
                                "选择画廊",
                                systemImage: "photo.stack",
                                description: Text("从左侧信息流选择一个画廊")
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .toolbar(.hidden, for: .navigationBar)
                    .environment(\.tagNavigationAction, TagNavigationAction { tag in
                        openDedicatedSearch(tag, advancedState: nil)
                    })
                    .environment(\.uploaderSearchNavigationAction, UploaderSearchNavigationAction { keyword in
                        openDedicatedSearch(keyword, advancedState: nil)
                    })
                }
            }
            .toolbar(removing: .sidebarToggle)
        }
    }

    #endif

    @ViewBuilder
    private var compactAdaptiveView: some View {
        // “我的”的紧凑导航由 MoreTabView 自己的 NavigationStack 管理。
        // 若在这里抢先替换整个 TabView，会失去系统 push 动画和侧滑返回。
        if let gallery = selectedGallery, selectedTab != .more {
            NavigationStack {
                GalleryDetailView(gallery: gallery)
                    .environment(
                        \.galleryDetailBackAction,
                        GalleryDetailBackAction {
                            selectedGallery = nil
                            preferredCompactColumn = .content
                        }
                    )
                    .navigationBarBackButtonHidden(true)
                    #if os(iOS)
                    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                    #endif
            }
        } else if let route = contentRoutes.last {
            if case .search = route {
                persistentCompactSearchView()
                    .environment(
                        \.contentRouteBackAction,
                        ContentRouteBackAction { popContentRoute(route) }
                    )
            } else {
                GalleryListView(mode: route.listMode, selection: $selectedGallery)
                    .id(ContentColumnIdentity.route(route))
                    .environment(
                        \.contentRouteBackAction,
                        ContentRouteBackAction { popContentRoute(route) }
                    )
            }
        } else {
            compactTabView
        }
    }

    @ViewBuilder
    private var adaptiveContentView: some View {
        ZStack {
            if let route = contentRoutes.last {
                Group {
                    if case .search = route {
                        persistentSearchView(selection: $selectedGallery)
                    } else {
                        GalleryListView(mode: route.listMode, selection: $selectedGallery)
                            .id(ContentColumnIdentity.route(route))
                    }
                }
                .environment(
                    \.contentRouteBackAction,
                    ContentRouteBackAction { popContentRoute(route) }
                )
            } else {
                adaptiveRootContent(for: selectedTab)
            }
        }
    }

    @ViewBuilder
    private func adaptiveRootContent(for tab: Tab) -> some View {
        switch tab {
        case .home:
            GalleryListView(
                mode: .home,
                selection: $selectedGallery,
                persistentViewModel: homeViewModel
            )
        case .search:
            persistentSearchView(selection: $selectedGallery)
        case .subscription:
            GalleryListView(
                mode: .subscription,
                selection: $selectedGallery,
                persistentViewModel: subscriptionViewModel
            )
        case .popular:
            GalleryListView(
                mode: .popular,
                selection: $selectedGallery,
                persistentViewModel: popularViewModel
            )
        case .toplist:
            TopListView(selection: $selectedGallery)
        case .favorites:
            FavoritesView(selection: $selectedGallery)
        case .watchLater:
            WatchLaterView(selection: $selectedGallery)
        case .downloads:
            DownloadsView(isPushed: true)
        case .history:
            HistoryView(selection: $selectedGallery)
        case .settings:
            SettingsView(isPushed: true)
        case .more:
            // macOS 不使用 "更多" 标签，不应出现
            EmptyView()
        }
    }

    private func pushContentRoute(_ route: ContentRoute) {
        guard contentRoutes.last != route else { return }
        withAnimation(.smooth(duration: 0.22)) {
            contentRoutes.append(route)
        }
    }

    private func openIntentSection(_ section: EhViewerIntentSection) {
        let destination: Tab
        switch section {
        case .home: destination = .home
        case .favorites: destination = .favorites
        case .downloads: destination = .downloads
        case .history: destination = .history
        case .subscription: destination = .subscription
        case .settings: destination = .settings
        case .toplist:
            #if os(macOS)
            destination = .toplist
            #else
            destination = .search
            #endif
        #if os(macOS)
        case .popular: destination = .popular
        #endif
        }

        withAnimation(.smooth(duration: 0.22)) {
            #if os(iOS)
            if Tab.accountTabs.contains(destination) {
                selectedMoreSection = destination
                selectedTab = .more
            } else {
                selectedTab = destination
            }
            #else
            selectedTab = destination
            #endif
            clearTransientNavigation()
        }
    }

    private func openIntentSearch(_ query: String) {
        openDedicatedSearch(query, advancedState: nil)
    }

    @ViewBuilder
    private func persistentSearchView(selection: Binding<GalleryInfo?>) -> some View {
        let searchView = GalleryListView(
            mode: .search(keyword: ""),
            selection: selection,
            persistentViewModel: searchViewModel,
            persistentAdvancedSearch: searchAdvancedState,
            searchFocusRequest: dedicatedSearchFocusRequest,
            searchNavigationResetRequest: dedicatedSearchNavigationResetRequest
        )
            .accessibilityIdentifier("main.search")

        if searchReturnContext != nil || searchViewModel.canRestorePreviousDedicatedSearch {
            searchView.environment(
                \.contentRouteBackAction,
                ContentRouteBackAction(perform: returnFromDedicatedSearch)
            )
        } else {
            searchView
        }
    }

    @ViewBuilder
    private func persistentCompactSearchView() -> some View {
        let searchView = GalleryListView(
            mode: .search(keyword: ""),
            persistentViewModel: searchViewModel,
            persistentAdvancedSearch: searchAdvancedState,
            searchFocusRequest: dedicatedSearchFocusRequest,
            searchNavigationResetRequest: dedicatedSearchNavigationResetRequest
        )
            .accessibilityIdentifier("main.search")

        if searchReturnContext != nil || searchViewModel.canRestorePreviousDedicatedSearch {
            searchView.environment(
                \.contentRouteBackAction,
                ContentRouteBackAction(perform: returnFromDedicatedSearch)
            )
        } else {
            searchView
        }
    }

    private func openDedicatedSearch(
        _ rawQuery: String,
        advancedState: AdvancedSearchState?,
        returnContext: SearchReturnContext? = nil
    ) {
        requestDedicatedSearchFocus(false)
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || advancedState?.isEnabled == true else {
            withAnimation(.smooth(duration: 0.22)) {
                selectedTab = .search
                clearTransientNavigation()
            }
            return
        }

        if selectedTab == .search {
            searchViewModel.pushDedicatedSearchStateIfNeeded(replacingWith: query)
        } else {
            // A search started from another primary section begins a new
            // navigation chain; do not expose stale Back levels from an older
            // visit to the Search tab.
            searchViewModel.discardDedicatedSearchNavigationHistory()
        }
        // Preserve the oldest origin. Deeper tag searches restore their prior
        // Search snapshots first, then the final Back returns to the gallery
        // from which the search chain originally began.
        if searchReturnContext == nil {
            searchReturnContext = returnContext
        }

        if let advancedState {
            searchAdvancedState.copyValues(from: advancedState)
        }

        // First expose the persistent Search root and pop any gallery owned by
        // its private NavigationStack. Starting the request only afterwards
        // prevents its results from being painted behind that destination.
        withAnimation(.smooth(duration: 0.22)) {
            selectedTab = .search
            clearTransientNavigation()
            dedicatedSearchNavigationResetRequest &+= 1
        }
        dedicatedSearchPresentationTask?.cancel()
        dedicatedSearchPresentationTask = Task { @MainActor in
            // Allow the tab switch and both the outer and Search-owned detail
            // stacks to commit their pop before publishing a new result set.
            // Without this boundary SwiftUI can render the response behind the
            // gallery that initiated a deep tag/uploader search.
            await Task.yield()
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchViewModel.searchText = query
            searchViewModel.scrollPosition = nil
            searchViewModel.searchWithAdvanced(searchAdvancedState)
        }
    }

    private func openDedicatedImageSearch(_ url: URL) {
        requestDedicatedSearchFocus(false)
        if selectedTab == .search {
            searchViewModel.pushDedicatedSearchStateIfNeeded(replacingWith: url.absoluteString)
        } else {
            searchViewModel.discardDedicatedSearchNavigationHistory()
            searchReturnContext = nil
        }
        withAnimation(.smooth(duration: 0.22)) {
            selectedTab = .search
            clearTransientNavigation()
            dedicatedSearchNavigationResetRequest &+= 1
        }
        dedicatedSearchPresentationTask?.cancel()
        dedicatedSearchPresentationTask = Task { @MainActor in
            await Task.yield()
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchViewModel.loadImageSearch(url)
        }
    }

    private func openDedicatedSearchField() {
        searchReturnContext = nil
        // Do not focus the Search tab while it is still hidden. UIKit would
        // grant and immediately revoke first responder during the TabView
        // transition, which appeared as a flash/refresh on portrait iPad.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedTab = .search
            clearTransientNavigation()
        }
        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            requestDedicatedSearchFocus(true)
        }
    }

    private func openDedicatedQuickSearch(_ record: QuickSearchRecord) {
        guard let keyword = record.keyword?.trimmingCharacters(in: .whitespacesAndNewlines),
              !keyword.isEmpty
        else { return }
        requestDedicatedSearchFocus(false)
        searchReturnContext = nil
        searchViewModel.discardDedicatedSearchNavigationHistory()
        searchAdvancedState.copyValues(from: record)
        withAnimation(.smooth(duration: 0.22)) {
            selectedTab = .search
            clearTransientNavigation()
            dedicatedSearchNavigationResetRequest &+= 1
        }
        dedicatedSearchPresentationTask?.cancel()
        dedicatedSearchPresentationTask = Task { @MainActor in
            await Task.yield()
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchViewModel.scrollPosition = nil
            searchViewModel.applyQuickSearch(record)
        }
    }

    private func requestDedicatedSearchFocus(_ shouldFocus: Bool) {
        let generation = abs(dedicatedSearchFocusRequest) + 1
        dedicatedSearchFocusRequest = shouldFocus ? generation : -generation
    }

    private func returnToSearchOriginGallery() {
        guard let context = searchReturnContext else { return }
        let changesTab = selectedTab != context.tab
        searchReturnContext = nil
        preservesSelectionDuringTabChange = changesTab

        withAnimation(.smooth(duration: 0.24)) {
            selectedTab = context.tab
            selectedGallery = context.gallery
            contentRoutes.removeAll()
            compactPath = [.gallery(context.gallery)]
            preferredCompactColumn = .detail
        }
    }

    private func returnFromDedicatedSearch() {
        dedicatedSearchPresentationTask?.cancel()
        let restored = searchViewModel.restorePreviousDedicatedSearch(into: searchAdvancedState)
        if restored {
            requestDedicatedSearchFocus(false)
            return
        }
        returnToSearchOriginGallery()
    }

    private func openIntentReader(_ route: ReaderWindowRoute) {
        #if os(macOS)
        openWindow(value: route)
        #else
        intentReaderRoute = route
        #endif
    }

    private func openIncomingGallery(_ gallery: GalleryInfo) {
        #if os(macOS)
        selectedGallery = gallery
        #else
        if horizontalSizeClass == .regular {
            selectedGallery = gallery
        } else {
            clipboardGallery = gallery
        }
        #endif
    }

    private func openNavigationGallery(_ gallery: GalleryInfo) {
        withAnimation(.smooth(duration: 0.22)) {
            if selectedTab != .history {
                preservesSelectionDuringTabChange = true
                selectedTab = .history
            }
            selectedGallery = gallery
            contentRoutes.removeAll()
            #if os(macOS)
            compactPath = [.gallery(gallery)]
            #endif
            preferredCompactColumn = .detail
        }
    }

    /// Clear every transient destination as one operation. Keeping this in a
    /// single place prevents a tab/search transition from leaving a stale
    /// detail selection in one layout mode but not another.
    private func clearTransientNavigation() {
        // TabView 会保留各栏目本身；只在确有临时导航状态时发布变更，避免
        // 每次点 Tab 都无意义地重算 NavigationStack / SplitView。
        if selectedGallery != nil { selectedGallery = nil }
        if !contentRoutes.isEmpty { contentRoutes.removeAll(keepingCapacity: true) }
        if !compactPath.isEmpty { compactPath.removeAll(keepingCapacity: true) }
        if preferredCompactColumn != .content { preferredCompactColumn = .content }
    }

    private func popContentRoute(_ route: ContentRoute) {
        guard let routeIndex = contentRoutes.lastIndex(of: route) else { return }
        withAnimation(.smooth(duration: 0.22)) {
            // Remove this route and any accidental duplicate/stale routes
            // above it, so a single back action always changes the page.
            contentRoutes.removeSubrange(routeIndex...)
            preferredCompactColumn = .content
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: Tab) -> some View {
        switch tab {
        case .home:
            GalleryListView(
                mode: AppSettings.shared.launchPage == 1 ? .popular : .home,
                persistentViewModel: homeViewModel
            )
        case .search:
            persistentCompactSearchView()
        case .subscription:
            GalleryListView(mode: .subscription, persistentViewModel: subscriptionViewModel)
        case .popular:
            GalleryListView(mode: .popular, persistentViewModel: popularViewModel)
        case .toplist:
            TopListView()
        case .favorites:
            FavoritesView()
        case .watchLater:
            WatchLaterView()
        case .downloads:
            DownloadsView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        case .more:
            MoreTabView(
                selectedSection: $selectedMoreSection,
                selectedGallery: $selectedGallery
            )
        }
    }
}

#Preview {
    MainTabView()
        .environment(AppState())
}
