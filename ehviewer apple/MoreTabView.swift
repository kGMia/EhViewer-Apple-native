//
//  MoreTabView.swift
//  ehviewer apple
//
//  “我的”标签页 — 入口页、个人内容与设置的统一导航层级
//

import SwiftUI
import EhModels

struct MoreTabView: View {
    @State private var path: [Destination] = []
    @Binding private var selectedSection: MainTabView.Tab?
    @Binding private var selectedGallery: GalleryInfo?

    private let prefersSplitNavigation: Bool

    private enum Destination: Hashable {
        case section(MainTabView.Tab)
        case gallery(GalleryInfo)
    }

    init(
        prefersSplitNavigation: Bool = false,
        selectedSection: Binding<MainTabView.Tab?> = .constant(nil),
        selectedGallery: Binding<GalleryInfo?> = .constant(nil)
    ) {
        self.prefersSplitNavigation = prefersSplitNavigation
        _selectedSection = selectedSection
        _selectedGallery = selectedGallery
    }

    var body: some View {
        Group {
            if prefersSplitNavigation {
                splitBody
            } else {
                compactBody
            }
        }
        .onChange(of: selectedSection) { oldSection, section in
            if prefersSplitNavigation, oldSection != section {
                selectedGallery = nil
            } else {
                synchronizeCompactPath(to: section)
            }
        }
        .animation(.smooth(duration: 0.28), value: selectedSection)
    }

    /// iPhone、竖屏 iPad 与窄窗口使用标准的入口页 → 子页面 push。
    /// 子页面因此自动获得系统返回按钮和原生侧滑返回手势。
    private var compactBody: some View {
        NavigationStack(path: $path) {
            landingPage(useNavigationLinks: true)
                .navigationDestination(for: Destination.self) { destination in
                    switch destination {
                    case .section(let tab):
                        morePageContent(tab, gallerySelection: compactGallerySelection)
                            .navigationTitle(tab.localizedTitle)
                            #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                            #endif
                            .toolbar { sectionMenuToolbar(current: tab) }
                    case .gallery(let gallery):
                        GalleryDetailView(gallery: gallery)
                    }
                }
        }
        .onChange(of: path) { _, newPath in
            synchronizeSharedState(from: newPath)
        }
        .task {
            restoreCompactPathIfNeeded()
        }
    }

    /// 宽屏先显示与窄窗口相同的“我的”入口页。进入可浏览画廊的栏目后，
    /// 左栏直接替换为该栏目的信息流，右栏固定显示画廊；不会常驻一层
    /// “我的”侧栏，也不会在收藏/历史内部继续嵌套 SplitView。
    @ViewBuilder
    private var splitBody: some View {
        if let section = selectedSection {
            if sectionSupportsGalleryDetail(section) {
                GeometryReader { proxy in
                    let contentWidth = min(max(proxy.size.width * 0.42, 390), 580)
                    HStack(spacing: 0) {
                    NavigationStack {
                        morePageContent(section, gallerySelection: splitGallerySelection)
                            .navigationTitle(section.localizedTitle)
                            .toolbar { splitSectionToolbar(current: section) }
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
                                    GalleryDetailBackAction { selectedGallery = nil }
                                )
                                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                        } else {
                            ContentUnavailableView(
                                section.localizedTitle,
                                systemImage: section.icon,
                                description: Text("从左侧信息流选择一个画廊")
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.smooth(duration: 0.24), value: selectedGallery?.gid)
                    }
                }
                .toolbar(removing: .sidebarToggle)
                .transition(.opacity)
            } else {
                NavigationStack {
                    morePageContent(section, gallerySelection: splitGallerySelection)
                        .navigationTitle(section.localizedTitle)
                        .toolbar { splitSectionToolbar(current: section) }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        } else {
            NavigationStack {
                landingPage(useNavigationLinks: false)
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder
    private func splitSectionToolbar(current: MainTabView.Tab) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: exitSection) {
                Label("返回我的", systemImage: "chevron.left")
            }
        }
        sectionMenuToolbar(current: current)
    }

    @ViewBuilder
    private func landingPage(useNavigationLinks: Bool) -> some View {
        List {
            Section {
                ForEach(MainTabView.Tab.accountTabs, id: \.self) { tab in
                    if useNavigationLinks {
                        NavigationLink(value: Destination.section(tab)) {
                            accountRow(tab)
                        }
                    } else {
                        Button {
                            withAnimation(.smooth(duration: 0.28)) {
                                selectedSection = tab
                            }
                        } label: {
                            HStack {
                                accountRow(tab)
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("我的")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func accountRow(_ tab: MainTabView.Tab) -> some View {
        Label(tab.localizedTitle, systemImage: tab.icon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    @ToolbarContentBuilder
    private func sectionMenuToolbar(current: MainTabView.Tab) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(MainTabView.Tab.accountTabs, id: \.self) { tab in
                    Button {
                        selectedSection = tab
                    } label: {
                        Label(
                            tab.localizedTitle,
                            systemImage: current == tab ? "checkmark" : tab.icon
                        )
                    }
                }
            } label: {
                Label(current.localizedTitle, systemImage: current.icon)
            }
            .help("切换“我的”页面")
            .accessibilityLabel("切换“我的”页面")
        }
    }

    private func exitSection() {
        withAnimation(.smooth(duration: 0.28)) {
            selectedGallery = nil
            selectedSection = nil
            if !path.isEmpty { path.removeAll(keepingCapacity: true) }
        }
    }

    private func sectionSupportsGalleryDetail(_ section: MainTabView.Tab) -> Bool {
        switch section {
        case .favorites, .watchLater, .history: true
        default: false
        }
    }

    private func synchronizeCompactPath(to section: MainTabView.Tab?) {
        guard !prefersSplitNavigation else { return }
        guard let section else {
            if !path.isEmpty { path.removeAll(keepingCapacity: true) }
            selectedGallery = nil
            return
        }

        let expectedRoot = Destination.section(section)
        if path.first != expectedRoot {
            path = [expectedRoot]
            selectedGallery = nil
        }
    }

    private func synchronizeSharedState(from newPath: [Destination]) {
        guard !prefersSplitNavigation else { return }
        guard case .section(let section) = newPath.first else {
            selectedSection = nil
            selectedGallery = nil
            return
        }
        if selectedSection != section { selectedSection = section }
        if !newPath.contains(where: {
            if case .gallery = $0 { return true }
            return false
        }) {
            selectedGallery = nil
        }
    }

    private func restoreCompactPathIfNeeded() {
        guard !prefersSplitNavigation, let section = selectedSection else { return }
        if path.isEmpty { path.append(.section(section)) }
        if let gallery = selectedGallery,
           !path.contains(where: {
               if case .gallery(let current) = $0 { return current.gid == gallery.gid }
               return false
           }) {
            path.append(.gallery(gallery))
        }
    }

    private var compactGallerySelection: Binding<GalleryInfo?> {
        Binding(
            get: { selectedGallery },
            set: { gallery in
                guard let gallery else {
                    selectedGallery = nil
                    if case .gallery = path.last { path.removeLast() }
                    return
                }
                guard selectedGallery?.gid != gallery.gid else { return }
                selectedGallery = gallery
                path.append(.gallery(gallery))
            }
        )
    }

    private var splitGallerySelection: Binding<GalleryInfo?> {
        Binding(
            get: { selectedGallery },
            set: { gallery in
                guard selectedGallery?.gid != gallery?.gid else { return }
                selectedGallery = gallery
            }
        )
    }

    @ViewBuilder
    private func morePageContent(
        _ tab: MainTabView.Tab,
        gallerySelection: Binding<GalleryInfo?>
    ) -> some View {
        switch tab {
        case .favorites:
            FavoritesView(selection: gallerySelection)
        case .watchLater:
            WatchLaterView(selection: gallerySelection)
        case .downloads:
            DownloadsView(isPushed: true)
        case .history:
            HistoryView(selection: gallerySelection)
        case .settings:
            SettingsView(isPushed: true)
        default:
            EmptyView()
        }
    }
}
