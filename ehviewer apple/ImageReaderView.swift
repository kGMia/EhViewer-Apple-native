//
//  ImageReaderView.swift
//  ehviewer apple
//
//  Reader 2.0 — 沉浸式阅读体验
//  支持: 翻页/滚动模式、双页排版 (iPad/Mac)、模糊氛围背景、沉浸式工具栏
//  手势: 边缘侧滑返回、点击翻页、双击缩放、键盘/滚轮导航
//

import SwiftUI
import EhModels
import EhSpider
import EhSettings
import EhDatabase
import EhDownload
import Translation
import Vision
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 跨平台图片 → Image 辅助

#if os(iOS)
private func nativeImage(_ img: UIImage) -> Image { Image(uiImage: img) }
#else
import AppKit
import UniformTypeIdentifiers
private func nativeImage(_ img: NSImage) -> Image { Image(nsImage: img) }
#endif

/// Cross-platform navigation payload. macOS uses it as a WindowGroup value,
/// while iOS uses the same Codable route for App Intents and full-screen presentation.
struct ReaderWindowRoute: Codable, Hashable, Identifiable {
    let id: UUID
    let gid: Int64
    let token: String
    let pages: Int
    let previewSet: PreviewSet?
    let initialPage: Int?

    init(
        gid: Int64,
        token: String,
        pages: Int,
        previewSet: PreviewSet?,
        initialPage: Int?
    ) {
        id = UUID()
        self.gid = gid
        self.token = token
        self.pages = pages
        self.previewSet = previewSet
        self.initialPage = initialPage
    }
}

/// iOS/iPadOS 的阅读器统一由主导航根节点呈现。详情页会在横竖屏切换时
/// 由单栏/双栏容器重建；若 fullScreenCover 挂在详情页上，宿主销毁会
/// 连带关闭阅读器。根级动作让呈现状态不再依赖某个临时页面。
struct ReaderPresentationAction {
    let present: @MainActor (ReaderWindowRoute) -> Void
}

private struct ReaderPresentationActionKey: EnvironmentKey {
    static let defaultValue: ReaderPresentationAction? = nil
}

extension EnvironmentValues {
    var readerPresentationAction: ReaderPresentationAction? {
        get { self[ReaderPresentationActionKey.self] }
        set { self[ReaderPresentationActionKey.self] = newValue }
    }
}

#if os(macOS)
struct ReaderCommandActions {
    let leftArrow: () -> Void
    let rightArrow: () -> Void
    let previousPage: () -> Void
    let nextPage: () -> Void
    let exit: () -> Void
    let toggleFullscreen: () -> Void
}

private struct ReaderCommandActionsKey: FocusedValueKey {
    typealias Value = ReaderCommandActions
}

extension FocusedValues {
    var readerCommandActions: ReaderCommandActions? {
        get { self[ReaderCommandActionsKey.self] }
        set { self[ReaderCommandActionsKey.self] = newValue }
    }
}
#endif

// MARK: - ImageReaderView

/// 设置窗口与已打开阅读器之间的轻量同步快照。只包含会影响当前界面的值，
/// 避免把 UserDefaults 查询放进翻页和滚动热路径。
private struct ReaderRuntimeSettings: Equatable {
    let readingDirection: Int
    let pageScaling: Int
    let startPosition: Int
    let keepScreenOn: Bool
    let fullscreen: Bool
    let showClock: Bool
    let showProgress: Bool
    let showBattery: Bool
    let showPageInterval: Bool
    let backgroundMode: Int
}

enum ReaderBackgroundMode: Int, CaseIterable {
    case ambient = 0
    case pureBlack = 1

    var label: String {
        switch self {
        case .ambient: AppLocalization.localized("页面氛围色")
        case .pureBlack: AppLocalization.localized("纯黑")
        }
    }

    var icon: String {
        switch self {
        case .ambient: "circle.lefthalf.filled"
        case .pureBlack: "circle.fill"
        }
    }
}

struct ImageReaderView: View {
    let gid: Int64
    let token: String
    let pages: Int
    let previewSet: PreviewSet?
    /// 初始页面 (0-based, 对齐 Android GalleryActivityEvent.page)
    let initialPage: Int?

    @State private var vm: ReaderViewModel
    @State private var showOverlay = true
    @State private var showSettings = false
    @State private var hasAppliedInitialPage = false
    @State private var isZoomed = false
    @State private var showTutorial = false
    #if os(macOS)
    @State private var readerWindow: NSWindow?
    @State private var isFullScreen = false
    #endif
    @State private var recognizedImageText = ""
    @State private var showImageTranslation = false
    @State private var isRecognizingImageText = false
    @State private var imageTranslationError = ""
    @State private var showImageTranslationError = false

    // 从设置读取
    @State private var readingDirection: ReadingDirection = .rightToLeft
    @State private var scaleMode: ScaleMode = .fit
    @State private var startPosition: StartPosition = .topRight
    @State private var pageDisplayMode: ReaderPageDisplayMode = .double
    @State private var firstPageStandalone: Bool = true
    @State private var pageAnimationEnabled: Bool = true
    @State private var backgroundMode: ReaderBackgroundMode = .ambient
    @State private var pageNavigationDelta: Int = 1
    @State private var readerViewportSize: CGSize = .zero
    @State private var lastHapticProgressPage: Int?

    // 自动翻页
    @State private var autoPageEnabled = false
    @State private var autoPageTask: Task<Void, Never>?

    // 时间显示
    @State private var currentTime = Date()
    @State private var timeTimer: Timer?

    // 垂直滚动模式
    @State private var isUpdatingFromScroll = false
    @State private var hasAppliedInitialScroll = false
    @State private var lastScrollChangeTime: Date = .distantPast
    @State private var verticalZoomScale: CGFloat = 1.0
    @State private var verticalBaseScale: CGFloat = 1.0
    /// Perf P0-2: 一次性缓存 showPageInterval 设置，避免滚动路径上读 UserDefaults
    @State private var verticalPageInterval: Bool = false
    @State private var showClock: Bool = true
    @State private var showProgress: Bool = true
    @State private var showBattery: Bool = true

    // Perf: 翻页去抖 — 快速滑动时取消上一次预加载，仅处理最终落地页
    @State private var pageChangeTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss

    // 点击区域比例
    private let tapZoneRatio: CGFloat = 0.25
    /// 纵向边缘死区比例 (上下各 15%)
    private let tapZoneVerticalDeadZone: CGFloat = 0.15
    /// 双页在更窄的阅读区域内收益很低，也会挤压底部进度控件。
    private let minimumPageLayoutControlWidth: CGFloat = 720

    private var supportsPageLayoutSelection: Bool {
        readerViewportSize.width >= minimumPageLayoutControlWidth
    }

    /// 显式初始化器 (Fix D-2: 移除 isDownloaded 参数，由 ReaderViewModel 自行检查)
    init(
        gid: Int64,
        token: String,
        pages: Int,
        previewSet: PreviewSet? = nil,
        initialPage: Int? = nil
    ) {
        self.gid = gid
        self.token = token
        self.pages = pages
        self.previewSet = previewSet
        self.initialPage = initialPage

        let viewModel = ReaderViewModel()
        viewModel.gid = gid
        viewModel.token = token
        // Fix Race: 不在 init 中设置 totalPages — 延迟到 initializeReader()
        // 中 setupLocalGallery() 完成后再设置，防止页面 .task 在 isDownloaded
        // 确定前就触发 loadPage → 已下载画廊首页无意义走网络

        self._vm = State(initialValue: viewModel)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 模糊氛围背景 (双页/宽屏模式下，画面未覆盖区域显示主色调渐变)
                ambientBackground

                // 主内容
                if vm.totalPages == 0 {
                    ProgressView()
                        .tint(.white)
                } else if readingDirection == .topToBottom {
                    verticalScrollReader(geometry: geometry)
                } else {
                    #if os(macOS)
                    macOSPageReader(geometry: geometry)
                    #else
                    horizontalPageReader(geometry: geometry)
                    #endif
                }

                // 沉浸式覆盖层 (顶部/底部滑入动画)
                immersiveOverlay(geometry: geometry)

                // HUD 显示 (时钟/电量/进度)
                if shouldShowReaderHUD {
                    hudOverlay(geometry: geometry)
                }

                // 浮动导航按钮 (工具栏隐藏时显示，提供翻页+工具栏切换)
                floatingNavigationOverlay(geometry: geometry)

                // 新手教程
                if showTutorial {
                    readerTutorialOverlay(geometry: geometry)
                }
            }
            .onAppear {
                readerViewportSize = geometry.size
                applyPageLayout(in: geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                readerViewportSize = newSize
                applyPageLayout(in: newSize)
            }
        }
        #if os(iOS)
        .statusBarHidden(shouldHideSystemStatusBar)
        .persistentSystemOverlays(shouldHideSystemStatusBar ? .hidden : .automatic)
        #endif
        .ignoresSafeArea()
        #if os(macOS)
        .background {
            ReaderWindowAccessor { window in
                guard readerWindow !== window else { return }
                readerWindow = window
                isFullScreen = window?.styleMask.contains(.fullScreen) == true
                if AppSettings.shared.readingFullscreen,
                   let window,
                   window.sheetParent == nil,
                   !window.styleMask.contains(.fullScreen) {
                    DispatchQueue.main.async {
                        window.toggleFullScreen(nil)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if note.object as? NSWindow === readerWindow {
                isFullScreen = true
                AppSettings.shared.readingFullscreen = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if note.object as? NSWindow === readerWindow {
                isFullScreen = false
                AppSettings.shared.readingFullscreen = false
            }
        }
        #endif
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .toolbar(.hidden)
        #endif
        .onAppear(perform: setupReader)
        .onChange(of: persistedReaderSettings) { _, newSettings in
            applyRuntimeSettings(newSettings)
        }
        .onChange(of: readingDirection) { _, _ in
            applyPageLayout()
        }
        .onChange(of: pageDisplayMode) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: "reader_page_display_mode")
            applyPageLayout()
        }
        .onChange(of: firstPageStandalone) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "reader_first_page_standalone")
            applyPageLayout()
        }
        .onChange(of: pageAnimationEnabled) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "reader_page_animation")
        }
        .onDisappear(perform: cleanupReader)
        .task {
            await initializeReader()
            // Fix F2-2: 只有真正打开阅读器才记录历史 (从详情页 loadDetail 迁移到这里)
            await recordReadingHistory()
        }
        .sheet(isPresented: $showSettings) {
            #if os(macOS)
            ReaderSettingsSheet(
                readingDirection: $readingDirection,
                scaleMode: $scaleMode,
                startPosition: $startPosition,
                autoPageEnabled: $autoPageEnabled,
                showClock: $showClock,
                showProgress: $showProgress,
                showBattery: $showBattery,
                showPageInterval: $verticalPageInterval,
                pageDisplayMode: $pageDisplayMode,
                pageAnimationEnabled: $pageAnimationEnabled,
                backgroundMode: $backgroundMode,
                showsPageLayoutSettings: supportsPageLayoutSelection,
                isFullScreen: $isFullScreen,
                onToggleFullscreen: toggleReaderFullscreen
            )
            #else
            ReaderSettingsSheet(
                readingDirection: $readingDirection,
                scaleMode: $scaleMode,
                startPosition: $startPosition,
                autoPageEnabled: $autoPageEnabled,
                showClock: $showClock,
                showProgress: $showProgress,
                showBattery: $showBattery,
                showPageInterval: $verticalPageInterval,
                pageDisplayMode: $pageDisplayMode,
                pageAnimationEnabled: $pageAnimationEnabled,
                backgroundMode: $backgroundMode,
                showsPageLayoutSettings: supportsPageLayoutSelection
            )
            #endif
        }
        .translationPresentation(
            isPresented: $showImageTranslation,
            text: recognizedImageText
        )
        .alert("无法翻译图片文字", isPresented: $showImageTranslationError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(imageTranslationError)
        }
        // 键盘事件 (macOS / iPad 键盘)
        .onKeyPress(.leftArrow) {
            handleLeftArrow()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            handleRightArrow()
            return .handled
        }
        .onKeyPress(.space) {
            goToNextPage()
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.upArrow) {
            if readingDirection == .topToBottom { return .ignored }
            goToPreviousPage()
            return .handled
        }
        .onKeyPress(.downArrow) {
            if readingDirection == .topToBottom { return .ignored }
            goToNextPage()
            return .handled
        }
        #if os(macOS)
        .focusedSceneValue(\.readerCommandActions, ReaderCommandActions(
            leftArrow: handleLeftArrow,
            rightArrow: handleRightArrow,
            previousPage: goToPreviousPage,
            nextPage: goToNextPage,
            exit: { dismiss() },
            toggleFullscreen: toggleReaderFullscreen
        ))
        .onKeyPress(.pageUp) {
            goToPreviousPage()
            return .handled
        }
        .onKeyPress(.pageDown) {
            goToNextPage()
            return .handled
        }
        .onKeyPress(.home) {
            goToPage(0)
            return .handled
        }
        .onKeyPress(.end) {
            goToPage(vm.totalPages - 1)
            return .handled
        }
        #endif
        #if os(iOS)
        // 边缘侧滑返回 (fullScreenCover 无 UINavigationController，需自行添加手势)
        .overlay {
            EdgeSwipeDismissView { dismiss() }
                .allowsHitTesting(true)
        }
        #endif
    }

    #if os(macOS)
    private func toggleReaderFullscreen() {
        guard let window = readerWindow, window.sheetParent == nil else { return }
        window.toggleFullScreen(nil)
    }
    #endif

    /// Apply the user's single/double-page choice on every platform. The old
    /// iOS path only looked at orientation, so changing the Picker never
    /// affected `isDoublePageEnabled` on iPad.
    private func applyPageLayout(in viewportSize: CGSize? = nil) {
        let anchoredPage = vm.currentPage
        let size = viewportSize ?? readerViewportSize
        #if os(macOS)
        let hasRoomForSpread = size.width >= minimumPageLayoutControlWidth
        #else
        let hasRoomForSpread = size.width >= minimumPageLayoutControlWidth
            && size.width > size.height
        #endif
        vm.isDoublePageEnabled = hasRoomForSpread
            && readingDirection != .topToBottom
            && pageDisplayMode == .double
        vm.firstPageStandalone = firstPageStandalone
        vm.computeSpreads()
        vm.synchronizePagePosition(anchoredPage)
    }

    // MARK: - Ambient Background (模糊氛围背景)

    /// 主色调氛围背景 — 使用当前页的 CIAreaAverage 提取色填充未覆盖区域
    /// 修复: 翻页时如果新页颜色未就绪，保持上一页颜色而非闪黑
    @ViewBuilder
    private var ambientBackground: some View {
        readerAmbientColor
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.4), value: vm.dominantColors[vm.currentPage] != nil)
            .animation(.easeInOut(duration: 0.25), value: backgroundMode)
    }

    private var readerAmbientColor: Color {
        if backgroundMode == .pureBlack {
            return .black
        }
        return vm.dominantColors[vm.currentPage]
            ?? vm.dominantColors.values.first
            ?? Color.black
    }

    /// 控件不再假定阅读背景永远为深色。按当前页面的主色亮度选择黑/白
    /// 前景，并同步改变玻璃染色，保证浅色页面上的文字仍然清晰。
    private var readerBackgroundIsLight: Bool {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        #if os(macOS)
        guard let nativeColor = NSColor(readerAmbientColor).usingColorSpace(.deviceRGB) else {
            return false
        }
        red = nativeColor.redComponent
        green = nativeColor.greenComponent
        blue = nativeColor.blueComponent
        #else
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard UIColor(readerAmbientColor).getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return false
        }
        red = r
        green = g
        blue = b
        #endif

        func linearize(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        let luminance = 0.2126 * linearize(red)
            + 0.7152 * linearize(green)
            + 0.0722 * linearize(blue)
        return luminance > 0.48
    }

    private var readerForegroundColor: Color {
        readerBackgroundIsLight ? .black : .white
    }

    private var readerSecondaryForegroundColor: Color {
        readerForegroundColor.opacity(0.72)
    }

    private var readerPanelTint: Color {
        readerBackgroundIsLight ? .white.opacity(0.42) : .black.opacity(0.30)
    }

    /// macOS 的系统强调色可以由用户在系统设置中修改。直接读取
    /// controlAccentColor，避免 Slider 回退为固定的默认蓝色。
    private var readerThemeColor: Color {
        if let selected = AppSettings.shared.accentColor.swiftUIColor {
            return selected
        }
        #if os(macOS)
        return Color(nsColor: .controlAccentColor)
        #else
        return Color.accentColor
        #endif
    }

    // MARK: - Setup

    private var persistedReaderSettings: ReaderRuntimeSettings {
        let settings = AppSettings.shared
        return ReaderRuntimeSettings(
            readingDirection: settings.readingDirection,
            pageScaling: settings.pageScaling,
            startPosition: settings.startPosition,
            keepScreenOn: settings.keepScreenOn,
            fullscreen: settings.readingFullscreen,
            showClock: settings.showClock,
            showProgress: settings.showProgress,
            showBattery: settings.showBattery,
            showPageInterval: settings.showPageInterval,
            backgroundMode: settings.readerBackgroundMode
        )
    }

    private func setupReader() {
        applyRuntimeSettings(persistedReaderSettings, updateWindowMode: false)
        pageDisplayMode = ReaderPageDisplayMode(
            rawValue: UserDefaults.standard.object(forKey: "reader_page_display_mode") as? Int ?? ReaderPageDisplayMode.double.rawValue
        ) ?? .double
        pageAnimationEnabled = UserDefaults.standard.object(forKey: "reader_page_animation") as? Bool ?? true
        firstPageStandalone = UserDefaults.standard.object(forKey: "reader_first_page_standalone") as? Bool ?? true

        #if os(iOS)
        if AppSettings.shared.keepScreenOn {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        if AppSettings.shared.customScreenLightness {
            setScreenBrightness(CGFloat(AppSettings.shared.screenLightness) / 100.0)
        }
        #else
        timeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            currentTime = Date()
        }
        #endif

        let tutorialKey = "reader_tutorial_shown"
        if !UserDefaults.standard.bool(forKey: tutorialKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showTutorial = true
                }
            }
        }
    }

    private func applyRuntimeSettings(
        _ settings: ReaderRuntimeSettings,
        updateWindowMode: Bool = true
    ) {
        readingDirection = ReadingDirection(rawValue: settings.readingDirection) ?? .rightToLeft
        scaleMode = ScaleMode(rawValue: settings.pageScaling) ?? .fit
        startPosition = StartPosition(rawValue: settings.startPosition) ?? .topRight
        verticalPageInterval = settings.showPageInterval
        showClock = settings.showClock
        showProgress = settings.showProgress
        showBattery = settings.showBattery
        backgroundMode = ReaderBackgroundMode(rawValue: settings.backgroundMode) ?? .ambient

        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        #elseif os(macOS)
        if updateWindowMode,
           let window = readerWindow,
           window.sheetParent == nil,
           settings.fullscreen != window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        #endif
    }

    private func cleanupReader() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        timeTimer?.invalidate()
        autoPageTask?.cancel()
        pageChangeTask?.cancel()
        vm.cancelBackgroundWork()
        saveReadingProgress()
    }

    /// Fix F2-2: 只有真正打开阅读器才计入历史 (从 GalleryDetailViewModel.loadDetail 迁移至此)
    private func recordReadingHistory() async {
        let record: HistoryRecord
        // 详情缓存优先；从下载页直接打开时通常没有详情缓存，此时必须
        // 回退到下载任务持久化的 GalleryInfo，不能写入空标题历史记录。
        if let detail = GalleryCache.shared.getDetail(gid: gid),
           !detail.info.bestTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record = detail.info.historyRecord()
        } else if let downloadedGallery = await DownloadManager.shared.getAllTasks()
            .first(where: { $0.gallery.gid == gid })?
            .gallery {
            record = downloadedGallery.historyRecord()
        } else {
            // 非下载入口且缓存不可用时仍保留阅读位置；后续再次从带元数据
            // 的入口打开会通过 INSERT OR REPLACE 自动补全。
            record = HistoryRecord(
                gid: gid, token: token,
                title: "", category: 0,
                pages: pages, mode: 0, date: Date()
            )
        }

        let historyLimit = AppSettings.shared.historyInfoSize
        do {
            try await Task.detached(priority: .utility) {
                try EhDatabase.shared.insertHistory(record)
                try EhDatabase.shared.trimHistory(maxCount: historyLimit)
            }.value
            NotificationCenter.default.post(name: .ehHistoryDidChange, object: nil)
        } catch {
            debugLog("Failed to record reading history: \(error)")
        }

        // 记录最后阅读的画廊 GID (给"继续阅读"功能使用)
        UserDefaults.standard.set(gid, forKey: "eh_last_reading_gid")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "eh_last_reading_time")
    }

    private func initializeReader() async {
        // 🛡️ 身份守卫: 将 View 持有的 gid 显式传给 ViewModel
        // Context Switch → resetState() → UI 立即转 Loading
        // Hit Cache → 跳过整个初始化流程
        let needsLoad = vm.prepareForGallery(targetGid: gid, targetToken: token)
        guard needsLoad else { return }

        // Fix D-1, B-1: 从 DownloadManager 查询真实下载状态，替代硬编码 isDownloaded
        await vm.setupLocalGallery()

        // Fix Race: setupLocalGallery 完成后再设置 totalPages
        // 这样页面视图的 .task 不会在 isDownloaded 确定前触发 loadPage
        if pages > 0 {
            vm.totalPages = pages
        }

        if let ps = previewSet {
            vm.extractPTokens(from: ps)
        }

        if vm.totalPages == 0 {
            await vm.fetchGalleryInfo()
        }

        // Fix Race: 阅读进度恢复移到这里 (从 init 迁移)
        let targetPage: Int
        if let initial = initialPage, initial >= 0, initial < vm.totalPages {
            targetPage = initial
        } else if initialPage == nil {
            let key = "reading_progress_\(gid)"
            if let saved = UserDefaults.standard.object(forKey: key) as? Int, vm.totalPages > 0 {
                targetPage = min(saved, max(0, vm.totalPages - 1))
            } else {
                targetPage = 0
            }
        } else {
            targetPage = 0
        }

        // Build spreads first, then seed every native scrolling position with
        // the same target before the first reader frame becomes interactive.
        vm.computeSpreads()
        vm.synchronizePagePosition(targetPage)

        // 详情页的预览图通常已在内存或 URLCache 中，先用它估算
        // 首帧背景，完整阅读图到达后 ReaderViewModel 会自动校准。
        if let previewSet {
            vm.seedDominantColor(from: previewSet, for: targetPage)
        }

        await vm.loadCurrentPage()
    }

    // MARK: - Progress Persistence

    private func saveReadingProgress() {
        let key = "reading_progress_\(gid)"
        UserDefaults.standard.set(vm.currentPage, forKey: key)
    }

    // MARK: - Navigation

    private func handleLeftArrow() {
        readingDirection == .rightToLeft ? goToNextPage() : goToPreviousPage()
    }

    private func handleRightArrow() {
        readingDirection == .rightToLeft ? goToPreviousPage() : goToNextPage()
    }

    private func goToNextPage() {
        goToNextPage(feedback: true)
    }

    private func goToNextPage(feedback: Bool) {
        pageNavigationDelta = 1
        if vm.isDoublePageEnabled {
            // 双页模式: 按 spread 翻页
            guard let currentIdx = vm.currentSpreadIndex else { return }
            let nextSpread = currentIdx + 1
            guard nextSpread < vm.spreads.count else { return }
            let nextPage = vm.pageForSpread(nextSpread)
            if feedback { Haptics.tap() }
            updateHorizontalPagePosition(page: nextPage, spread: nextSpread)
        } else {
            guard vm.currentPage < vm.totalPages - 1 else { return }
            let nextPage = vm.currentPage + 1
            if feedback { Haptics.tap() }
            updateHorizontalPagePosition(page: nextPage)
        }
    }

    private func goToPreviousPage() {
        pageNavigationDelta = -1
        if vm.isDoublePageEnabled {
            guard let currentIdx = vm.currentSpreadIndex else { return }
            let prevSpread = currentIdx - 1
            guard prevSpread >= 0 else { return }
            let prevPage = vm.pageForSpread(prevSpread)
            Haptics.tap()
            updateHorizontalPagePosition(page: prevPage, spread: prevSpread)
        } else {
            guard vm.currentPage > 0 else { return }
            let previousPage = vm.currentPage - 1
            Haptics.tap()
            updateHorizontalPagePosition(page: previousPage)
        }
    }

    private func goToPage(_ page: Int) {
        let target = max(0, min(vm.totalPages - 1, page))
        pageNavigationDelta = target >= vm.currentPage ? 1 : -1
        let spread = vm.isDoublePageEnabled ? vm.spreadIndex(for: target) : nil
        updateHorizontalPagePosition(page: target, spread: spread)
    }

    /// Programmatic turns update SwiftUI's native paging position in one
    /// transaction on every platform. Updating the logical page and the
    /// scroll target together avoids a second correction frame on iPad.
    private func updateHorizontalPagePosition(page: Int, spread: Int? = nil) {
        let updatePosition = {
            vm.synchronizePagePosition(page)
            if let spread { vm.currentSpreadIndex = spread }
        }

        if pageAnimationEnabled {
            withAnimation(.smooth(duration: 0.28), updatePosition)
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction, updatePosition)
        }
    }

    // MARK: - Auto Page

    private func toggleAutoPage() {
        autoPageEnabled.toggle()
        if autoPageEnabled {
            startAutoPage()
        } else {
            autoPageTask?.cancel()
        }
    }

    private func startAutoPage() {
        autoPageTask?.cancel()
        autoPageTask = Task {
            while !Task.isCancelled && autoPageEnabled {
                try? await Task.sleep(nanoseconds: UInt64(AppSettings.shared.autoPageInterval) * 1_000_000_000)
                if !Task.isCancelled && autoPageEnabled {
                    await MainActor.run {
                        goToNextPage(feedback: false)
                    }
                }
            }
        }
    }

    // MARK: - Horizontal Page Reader
    // Perf P0-1: 使用 ScrollView + LazyHStack + 原生 view-aligned paging 替代 TabView
    // TabView(.page) 是非懒加载的 — 会一次性实例化所有子 View
    // LazyHStack 只创建可见区域内的 View，40 页画廊 → 仅 ~3 个 View

    private func horizontalPageReader(geometry: GeometryProxy) -> some View {
        Group {
            if vm.isDoublePageEnabled {
                // 双页模式: 按 spread 遍历，每个 spread 显示合成图
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(vm.spreads) { spread in
                            spreadPageView(spread: spread)
                                .containerRelativeFrame(.horizontal)
                                .id(spread.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                // Limit a fast iPad flick to one spread while retaining the
                // native, finger-tracking horizontal transition.
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .scrollPosition(id: $vm.currentSpreadIndex)
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                .onChange(of: vm.currentSpreadIndex) { _, newIdx in
                    guard hasAppliedInitialPage else { return }
                    guard let idx = newIdx else { return }
                    let page = vm.pageForSpread(idx)
                    if vm.currentPage != page {
                        vm.synchronizePagePosition(page)
                    }
                    saveReadingProgress()
                    // Perf: 去抖 — 快速翻页时只处理最终落地页
                    pageChangeTask?.cancel()
                    pageChangeTask = Task {
                        try? await Task.sleep(nanoseconds: 80_000_000) // 80ms debounce
                        guard !Task.isCancelled else { return }
                        await vm.onPageChange(page)
                    }
                }
            } else {
                // 单页模式
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<vm.totalPages, id: \.self) { idx in
                            pageImage(index: idx)
                                .containerRelativeFrame(.horizontal)
                                .id(idx)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .scrollPosition(id: $vm.lazyCurrentPage)
                .environment(\.layoutDirection, readingDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                .onChange(of: vm.lazyCurrentPage) { _, newPage in
                    guard hasAppliedInitialPage else { return }
                    guard let page = newPage,
                          page >= 0,
                          page < vm.totalPages else { return }
                    if page != vm.currentPage {
                        vm.synchronizePagePosition(page)
                    }
                    saveReadingProgress()
                    // Perf: 去抖 — 快速滑动时取消上一次预加载，仅处理结束页
                    pageChangeTask?.cancel()
                    pageChangeTask = Task {
                        try? await Task.sleep(nanoseconds: 80_000_000) // 80ms debounce
                        guard !Task.isCancelled else { return }
                        await vm.onPageChange(page)
                    }
                }
                .onChange(of: vm.currentPage) { _, newPage in
                    // 外部翻页 (键盘/浮动按钮/slider) → 同步 scrollPosition
                    if vm.lazyCurrentPage != newPage {
                        vm.lazyCurrentPage = newPage
                    }
                }
            }
        }
        .task(id: vm.totalPages) {
            guard vm.totalPages > 0, !hasAppliedInitialPage else { return }
            let targetPage = vm.currentPage

            // Let LazyHStack register its IDs, then reassert the target without
            // animation. ScrollView may publish its default ID (0) during these
            // first layout passes; the guards above prevent that transient value
            // from overwriting the requested preview page.
            await Task.yield()
            await Task.yield()
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                vm.synchronizePagePosition(targetPage)
            }
            hasAppliedInitialPage = true
        }
    }

    // MARK: - macOS Page Reader

    #if os(macOS)
    private func macOSPageReader(geometry: GeometryProxy) -> some View {
        ZStack {
            // Native paging keeps the outgoing and incoming pages in one
            // scroll container, avoiding the overlap/flicker produced by an
            // asymmetric transition between two full-size image views.
            horizontalPageReader(geometry: geometry)

            ScrollWheelPageNavigator(
                onNext: { goToNextPage() },
                onPrevious: { goToPreviousPage() },
                onSwipeLeft: {
                    readingDirection == .rightToLeft ? goToPreviousPage() : goToNextPage()
                },
                onSwipeRight: {
                    readingDirection == .rightToLeft ? goToNextPage() : goToPreviousPage()
                },
                onSingleTap: { location, viewSize in
                    handleTapZone(location: location, viewSize: viewSize)
                },
                isZoomed: isZoomed
            )
        }
        .contextMenu {
            Button {
                copyCurrentReaderImage()
            } label: {
                Label("拷贝图片", systemImage: "doc.on.doc")
            }
            .disabled(vm.cachedImages[vm.currentPage] == nil)

            Button {
                saveCurrentReaderImage()
            } label: {
                Label("下载图片…", systemImage: "arrow.down.to.line")
            }
            .disabled(vm.imageURLs[vm.currentPage] == nil)

            Divider()

            Button {
                recognizeAndTranslateCurrentImage()
            } label: {
                Label(
                    AppLocalization.localized(isRecognizingImageText ? "正在识别文字…" : "翻译图片文字…"),
                    systemImage: "translate"
                )
            }
            .disabled(vm.cachedImages[vm.currentPage] == nil || isRecognizingImageText)

            Divider()

            Button {
                Task { await vm.loadOriginalImage(vm.currentPage) }
            } label: {
                Label(
                    AppLocalization.localized(vm.pagesUsingOriginalImage.contains(vm.currentPage) ? "已加载原图" : "加载原图"),
                    systemImage: "photo.badge.arrow.down"
                )
            }
            .disabled(vm.pagesUsingOriginalImage.contains(vm.currentPage))
        }
    }

    private func copyCurrentReaderImage() {
        guard let image = vm.cachedImages[vm.currentPage] else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func recognizeAndTranslateCurrentImage() {
        recognizeAndTranslateImage(at: vm.currentPage)
    }

    private func saveCurrentReaderImage() {
        let page = vm.currentPage
        let sourceExtension = vm.imageURLs[page]
            .flatMap(URL.init(string:))?
            .pathExtension
            .lowercased()
        let fileExtension = (sourceExtension?.isEmpty == false ? sourceExtension : nil) ?? "jpg"

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(gid)-\(page + 1).\(fileExtension)"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .image]

        let save: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                do {
                    let data = try await vm.sourceImageData(for: page)
                    try data.write(to: destination, options: .atomic)
                } catch {
                    debugLog("[Reader] Saving image failed: \(error.localizedDescription)")
                }
            }
        }

        if let readerWindow {
            panel.beginSheetModal(for: readerWindow, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }
    #endif

    private func recognizeAndTranslateImage(at index: Int) {
        guard !isRecognizingImageText, let image = vm.cachedImages[index] else { return }
        #if os(iOS)
        guard let cgImage = image.cgImage else { return }
        #else
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        #endif

        isRecognizingImageText = true
        Task {
            do {
                var request = RecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.automaticallyDetectsLanguage = true
                request.usesLanguageCorrection = true

                let observations = try await request.perform(on: cgImage)
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                isRecognizingImageText = false
                if text.isEmpty {
                    imageTranslationError = AppLocalization.localized("当前页面没有识别到可翻译的文字。")
                    showImageTranslationError = true
                } else {
                    recognizedImageText = text
                    showImageTranslation = true
                }
            } catch is CancellationError {
                isRecognizingImageText = false
            } catch {
                isRecognizingImageText = false
                imageTranslationError = error.localizedDescription
                showImageTranslationError = true
            }
        }
    }

    // MARK: - Spread Page View (双页合成视图)

    /// 显示一个 spread (单页或双页合成) — 使用 ViewModel 合成图
    @ViewBuilder
    private func spreadPageView(spread: PageSpread) -> some View {
        if let composited = vm.spreadImage(at: spread.id, direction: readingDirection) {
            readerImageContextMenu(for: spread.pages) {
                ZoomableImageView(
                    image: composited,
                    scaleMode: scaleMode,
                    startPosition: startPosition,
                    allowsHorizontalScrollAtMinZoom: false,
                    onSingleTap: { location, viewSize in
                        handleTapZone(location: location, viewSize: viewSize)
                    },
                    onZoomChanged: { zoomed in
                        isZoomed = zoomed
                    },
                    pageSwipeAnimationEnabled: pageAnimationEnabled,
                    onSwipeLeft: handleReaderSwipeLeft,
                    onSwipeRight: handleReaderSwipeRight
                )
            }
        } else {
            // 至少一页尚未加载 — 显示加载状态
            VStack(spacing: 12) {
                // 主页状态
                pageLoadingIndicator(index: spread.primaryPage)

                // 副页状态 (如果有)
                if let sec = spread.secondaryPage {
                    Divider().frame(width: 60).overlay(Color.white.opacity(0.3))
                    pageLoadingIndicator(index: sec)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: spreadPreparationID(spread)) {
                // 同时加载两页
                await withTaskGroup(of: Void.self) { group in
                    for p in spread.pages {
                        group.addTask {
                            await vm.loadPageWithRetry(p)
                            await vm.downloadImageData(p)
                        }
                    }
                }
                await vm.prepareSpreadImage(at: spread.id, direction: readingDirection)
            }
        }
    }

    private func spreadPreparationID(_ spread: PageSpread) -> String {
        let retryState = spread.pages.map { page in
            "\(page):\(vm.retryGeneration[page, default: 0])"
        }.joined(separator: ",")
        return "\(spread.id):\(readingDirection.rawValue):\(retryState)"
    }

    /// 单页加载指示器 (复用于 spread 和单页模式)
    @ViewBuilder
    private func pageLoadingIndicator(index: Int) -> some View {
        if vm.errorPages.contains(index) {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.white)
                Text(vm.errorMessages[index] ?? "加载失败")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button("重新加载") {
                    Task { await vm.retryLoadPage(index) }
                }
                .buttonStyle(.glassProminent)
            }
        } else if let progress = vm.downloadProgress[index], progress > 0 {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 3)
                    .frame(width: 48, height: 48)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
        } else if let retryCount = vm.retryingPages[index], retryCount > 0 {
            VStack(spacing: 4) {
                ProgressView().tint(.white)
                Text("重试 \(retryCount)/5")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        } else {
            ProgressView().tint(.white)
        }
    }

    // MARK: - Vertical Scroll Reader
    // Perf P0-2: 使用 .scrollPosition(id:) 替代 GeometryReader + PreferenceKey
    // 原实现每个 page item 绑定 GeometryReader，滚动每帧触发 preference 级联
    // .scrollPosition 是 SwiftUI 原生 API，内部由 runtime 高效追踪

    private func verticalScrollReader(geometry: GeometryProxy) -> some View {
        let contentWidth = geometry.size.width * verticalZoomScale
        let showInterval = verticalPageInterval

        return ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal], showsIndicators: false) {
                LazyVStack(spacing: showInterval ? 8 : 0) {
                    ForEach(0..<vm.totalPages, id: \.self) { idx in
                        verticalPageImage(index: idx)
                            .frame(width: contentWidth)
                            .id(idx)
                    }
                }
            }
            .scrollTargetLayout()
            .scrollPosition(id: $vm.verticalScrollPage, anchor: .top)
            .scrollBounceBehavior(.basedOnSize)
            .contentShape(Rectangle())
            // 移除了 TapGesture: 防止滚动时疯狂误触工具栏
            // 工具栏切换改由底部浮动导航栏的中央按钮触发
            #if os(iOS)
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        verticalZoomScale = max(1.0, min(3.0, verticalBaseScale * value.magnification))
                    }
                    .onEnded { value in
                        verticalBaseScale = verticalZoomScale
                        if verticalZoomScale < 1.1 {
                            withAnimation(.spring()) {
                                verticalZoomScale = 1.0
                                verticalBaseScale = 1.0
                            }
                        }
                    }
            )
            #endif
            .onAppear {
                if vm.currentPage > 0 && !hasAppliedInitialScroll {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo(vm.currentPage, anchor: .top)
                        }
                        vm.verticalScrollPage = vm.currentPage
                        hasAppliedInitialScroll = true
                    }
                }
            }
            .onChange(of: vm.verticalScrollPage) { _, newPage in
                // 滚动引起的页码变化 → 同步 currentPage
                guard let page = newPage, page != vm.currentPage else { return }
                isUpdatingFromScroll = true
                vm.synchronizePagePosition(page)
                lastScrollChangeTime = Date()
                saveReadingProgress()
                DispatchQueue.main.async {
                    self.isUpdatingFromScroll = false
                }
            }
            .onChange(of: vm.currentPage) { _, newPage in
                // 外部翻页 (键盘/slider/浮动按钮) → 滚动到目标页
                if !isUpdatingFromScroll {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(newPage, anchor: .top)
                    }
                    vm.verticalScrollPage = newPage
                    saveReadingProgress()
                }
            }
        }
    }

    /// 垂直滚动模式的页面图片 — 宽度撑满、高度按比例
    @ViewBuilder
    private func verticalPageImage(index: Int) -> some View {
        if vm.errorPages.contains(index) {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.white)
                Text(vm.errorMessages[index] ?? "加载失败")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button("重新加载") {
                    Task { await vm.retryLoadPage(index) }
                }
                .buttonStyle(.glassProminent)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
        } else if let cachedImage = vm.image(at: index) {
            let imgSize = cachedImage.size
            let ratio = imgSize.width > 0 ? imgSize.height / imgSize.width : 1.0
            readerImageContextMenu(for: [index]) {
                if cachedImage.isAnimatedPlatformImage {
                    PlatformAnimatedImageView(image: cachedImage, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1.0 / ratio, contentMode: .fit)
                } else {
                    nativeImage(cachedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1.0 / ratio, contentMode: .fit)
                }
            }
        } else if vm.imageURLs[index] != nil {
            VStack(spacing: 8) {
                if let progress = vm.downloadProgress[index], progress > 0 {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 3)
                            .frame(width: 48, height: 48)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 48, height: 48)
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text("下载图片中...")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .task(id: "\(vm.imageURLs[index] ?? "")_\(vm.retryGeneration[index, default: 0])") {
                await vm.downloadImageData(index)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                if let retryCount = vm.retryingPages[index], retryCount > 0 {
                    Text("重试 \(retryCount)/5")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .task {
                await vm.loadPageWithRetry(index)
            }
        }
    }

    // MARK: - Single Page Image (翻页模式单页)

    private func pageImage(index: Int) -> some View {
        Group {
            if vm.errorPages.contains(index) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.white)
                    Text(vm.errorMessages[index] ?? "加载失败")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                    Button("重新加载") {
                        Task { await vm.retryLoadPage(index) }
                    }
                    .buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let cachedImage = vm.image(at: index) {
                readerImageContextMenu(for: [index]) {
                    ZoomableImageView(
                        image: cachedImage,
                        scaleMode: scaleMode,
                        startPosition: startPosition,
                        allowsHorizontalScrollAtMinZoom: readingDirection == .topToBottom,
                        onSingleTap: { location, viewSize in
                            handleTapZone(location: location, viewSize: viewSize)
                        },
                        onZoomChanged: { zoomed in
                            isZoomed = zoomed
                        },
                        pageSwipeAnimationEnabled: pageAnimationEnabled,
                        onSwipeLeft: handleReaderSwipeLeft,
                        onSwipeRight: handleReaderSwipeRight
                    )
                }
            } else if vm.imageURLs[index] != nil {
                VStack(spacing: 8) {
                    if let progress = vm.downloadProgress[index], progress > 0 {
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.3), lineWidth: 3)
                                .frame(width: 48, height: 48)
                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: 48, height: 48)
                                .rotationEffect(.degrees(-90))
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                        Text("下载图片中...")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: "\(vm.imageURLs[index] ?? "")_\(vm.retryGeneration[index, default: 0])") {
                    await vm.downloadImageData(index)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    if let retryCount = vm.retryingPages[index], retryCount > 0 {
                        Text("重试 \(retryCount)/5")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    await vm.loadPageWithRetry(index)
                }
            }
        }
    }

    /// iOS/iPadOS 使用系统 context menu 提供长按操作。macOS 已在阅读器
    /// 外层提供右键菜单，因此保持原有实现，避免出现重复菜单。
    @ViewBuilder
    private func readerImageContextMenu<Content: View>(
        for pageIndices: [Int],
        @ViewBuilder content: () -> Content
    ) -> some View {
        #if os(iOS)
        content()
            .contextMenu {
                Button {
                    Task {
                        for index in pageIndices where !vm.pagesUsingOriginalImage.contains(index) {
                            await vm.loadOriginalImage(index)
                        }
                    }
                } label: {
                    Label("加载原图", systemImage: "photo.badge.arrow.down")
                }
                .disabled(pageIndices.allSatisfy(vm.pagesUsingOriginalImage.contains))

                Button {
                    if let page = pageIndices.first {
                        recognizeAndTranslateImage(at: page)
                    }
                } label: {
                    Label(
                        AppLocalization.localized(isRecognizingImageText ? "正在识别文字…" : "翻译图片文字…"),
                        systemImage: "translate"
                    )
                }
                .disabled(
                    isRecognizingImageText
                        || pageIndices.first.flatMap { vm.cachedImages[$0] } == nil
                )

                Button {
                    if let page = pageIndices.first {
                        saveReaderImage(page)
                    }
                } label: {
                    Label("保存图片", systemImage: "square.and.arrow.down")
                }
                .disabled(pageIndices.first.flatMap { vm.cachedImages[$0] } == nil)

                Button {
                    if let page = pageIndices.first {
                        copyReaderImage(page)
                    }
                } label: {
                    Label("拷贝图片", systemImage: "doc.on.doc")
                }
                .disabled(pageIndices.first.flatMap { vm.cachedImages[$0] } == nil)
            }
        #else
        content()
        #endif
    }

    #if os(iOS)
    private func saveReaderImage(_ index: Int) {
        guard let image = vm.cachedImages[index] else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }

    private func copyReaderImage(_ index: Int) {
        guard let image = vm.cachedImages[index] else { return }
        UIPasteboard.general.image = image
    }
    #endif

    // MARK: - Tap Zone Detection

    private func handleReaderSwipeLeft() {
        readingDirection == .rightToLeft ? goToPreviousPage() : goToNextPage()
    }

    private func handleReaderSwipeRight() {
        readingDirection == .rightToLeft ? goToNextPage() : goToPreviousPage()
    }

    private func handleTapZone(location: CGPoint, viewSize: CGSize) {
        guard viewSize.width > 0 && viewSize.height > 0 else { return }

        #if os(macOS)
        if isFullScreen && showOverlay {
            withAnimation(.easeInOut(duration: 0.2)) { showOverlay = false }
            return
        }
        #endif

        let relX = location.x / viewSize.width
        let relY = location.y / viewSize.height

        guard relY > tapZoneVerticalDeadZone && relY < (1 - tapZoneVerticalDeadZone) else {
            return
        }

        if relX < tapZoneRatio {
            if readingDirection == .rightToLeft {
                goToNextPage()
            } else if readingDirection == .leftToRight {
                goToPreviousPage()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
            }
        } else if relX > (1 - tapZoneRatio) {
            if readingDirection == .rightToLeft {
                goToPreviousPage()
            } else if readingDirection == .leftToRight {
                goToNextPage()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
        }
    }

    // MARK: - Reader Tutorial Overlay

    private func readerTutorialOverlay(geometry: GeometryProxy) -> some View {
        let w = geometry.size.width
        let h = geometry.size.height
        let sideW = w * tapZoneRatio
        let deadH = h * tapZoneVerticalDeadZone

        return ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()

            // 左侧区域标注
            VStack(spacing: 4) {
                Image(systemName: readingDirection == .rightToLeft ? "arrow.right" : "arrow.left")
                    .font(.title2)
                Text(AppLocalization.localized(readingDirection == .rightToLeft ? "下一页" : "上一页"))
                    .font(.caption.bold())
            }
            .foregroundStyle(.white)
            .position(x: sideW / 2, y: h / 2)

            // 中央区域标注
            VStack(spacing: 8) {
                Image(systemName: "hand.tap")
                    .font(.title)
                Text("单击: 显示/隐藏工具栏")
                    .font(.caption.bold())
                Divider()
                    .frame(width: 80)
                    .overlay(Color.white.opacity(0.5))
                Image(systemName: "hand.tap")
                    .font(.title)
                    .overlay(
                        Image(systemName: "hand.tap")
                            .font(.title)
                            .offset(x: 2, y: 2)
                            .opacity(0.5)
                    )
                Text("双击: 放大/复原")
                    .font(.caption.bold())
            }
            .foregroundStyle(.white)
            .position(x: w / 2, y: h / 2)

            // 右侧区域标注
            VStack(spacing: 4) {
                Image(systemName: readingDirection == .rightToLeft ? "arrow.left" : "arrow.right")
                    .font(.title2)
                Text(AppLocalization.localized(readingDirection == .rightToLeft ? "上一页" : "下一页"))
                    .font(.caption.bold())
            }
            .foregroundStyle(.white)
            .position(x: w - sideW / 2, y: h / 2)

            // 上方死区标注
            Text("死区 (不响应)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .position(x: w / 2, y: deadH / 2)

            // 下方死区标注
            Text("死区 (不响应)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .position(x: w / 2, y: h - deadH / 2)

            // 左右滑动翻页提示
            VStack(spacing: 4) {
                Image(systemName: "hand.draw")
                    .font(.title3)
                Text("左右滑动也可以翻页")
                    .font(.caption)
            }
            .foregroundStyle(.white.opacity(0.8))
            .position(x: w / 2, y: h - deadH - 40)

            // 关闭按钮
            VStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showTutorial = false
                    }
                    UserDefaults.standard.set(true, forKey: "reader_tutorial_shown")
                } label: {
                    Text("我知道了")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.glassProminent)
                .padding(.bottom, max(40, geometry.safeAreaInsets.bottom + 20))
            }

            // 区域分界线
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: h - deadH * 2)
                .position(x: sideW, y: h / 2)
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: h - deadH * 2)
                .position(x: w - sideW, y: h / 2)
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: w, height: 1)
                .position(x: w / 2, y: deadH)
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: w, height: 1)
                .position(x: w / 2, y: h - deadH)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                showTutorial = false
            }
            UserDefaults.standard.set(true, forKey: "reader_tutorial_shown")
        }
    }

    // MARK: - Immersive Overlay (沉浸式工具栏)

    /// 顶部/底部工具栏以滑入动画出现，对齐 Apple HIG 沉浸式媒体体验
    private func immersiveOverlay(geometry: GeometryProxy) -> some View {
        VStack {
            // 顶部工具栏 — 从顶部滑入
            if showOverlay {
                topBar(geometry: geometry)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            // 底部工具栏 — 从底部滑入
            if showOverlay {
                bottomBar(geometry: geometry)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showOverlay)
    }

    private func topBar(geometry: GeometryProxy) -> some View {
        let controlHeight: CGFloat = {
            #if os(iOS)
            44
            #else
            40
            #endif
        }()

        return GlassEffectContainer(spacing: 12) {
            ZStack {
                // 页码显示 (双页模式标注 spread)
                Group {
                    if vm.isDoublePageEnabled, let currentIdx = vm.currentSpreadIndex, currentIdx < vm.spreads.count {
                        let spread = vm.spreads[currentIdx]
                        if let sec = spread.secondaryPage {
                            Text("\(spread.primaryPage + 1)–\(sec + 1) / \(vm.totalPages)")
                        } else {
                            Text("\(spread.primaryPage + 1) / \(vm.totalPages)")
                        }
                    } else {
                        Text("\(vm.currentPage + 1) / \(vm.totalPages)")
                    }
                }
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(readerForegroundColor)
                .padding(.horizontal, 16)
                .frame(height: controlHeight)
                .glassEffect(.regular.tint(readerPanelTint), in: .capsule)

                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .frame(width: controlHeight, height: controlHeight)
                    .help("关闭阅读器")

                    Spacer(minLength: 120)

                    #if os(macOS)
                    Button(action: toggleReaderFullscreen) {
                        Image(systemName: isFullScreen
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .frame(width: controlHeight, height: controlHeight)
                    .help(AppLocalization.localized(isFullScreen ? "退出全屏" : "进入全屏"))
                    .accessibilityLabel(AppLocalization.localized(isFullScreen ? "退出全屏" : "进入全屏"))
                    #endif

                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .frame(width: controlHeight, height: controlHeight)
                    .help("阅读设置")
                    .accessibilityLabel("阅读设置")
                }
                .buttonStyle(.glass)
            }
        }
        .foregroundStyle(readerForegroundColor)
        .padding(.horizontal, readerHorizontalInset(geometry))
        .padding(.top, max(readerTopPadding, geometry.safeAreaInsets.top + 18))
    }

    private func bottomBar(geometry: GeometryProxy) -> some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(ReadingDirection.allCases, id: \.rawValue) { direction in
                            Button {
                                readingDirection = direction
                                AppSettings.shared.readingDirection = direction.rawValue
                            } label: {
                                Label(direction.label, systemImage: direction.icon)
                            }
                        }
                    } label: {
                        Label(readingDirection.label, systemImage: readingDirection.icon)
                    }
                    .help("阅读顺序")
                    .accessibilityLabel("阅读顺序：\(readingDirection.label)")

                    if supportsPageLayoutSelection {
                        Menu {
                            ForEach(ReaderPageDisplayMode.allCases, id: \.rawValue) { mode in
                                Button {
                                    pageDisplayMode = mode
                                } label: {
                                    if pageDisplayMode == mode {
                                        Label(mode.label, systemImage: "checkmark")
                                    } else {
                                        Text(mode.label)
                                    }
                                }
                            }
                            Divider()
                            Toggle("第一页单独显示", isOn: $firstPageStandalone)
                                .disabled(pageDisplayMode == .single || readingDirection == .topToBottom)
                        } label: {
                            Label(pageDisplayMode.label, systemImage: pageDisplayMode == .double ? "rectangle.split.2x1" : "rectangle")
                        }
                        .help("页面布局")
                        .accessibilityLabel("页面布局：\(pageDisplayMode.label)")
                    }

                    Spacer()
                    Text("第 \(vm.currentPage + 1) 页，共 \(vm.totalPages) 页")
                        .monospacedDigit()

                    Button(action: toggleAutoPage) {
                        Label(
                            AppLocalization.localized(autoPageEnabled ? "暂停" : "自动翻页"),
                            systemImage: autoPageEnabled ? "pause.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.glass(
                        .regular.tint(autoPageEnabled ? .accentColor : nil)
                    ))
                    .accessibilityLabel(AppLocalization.localized(autoPageEnabled ? "暂停自动翻页" : "开始自动翻页"))
                }
                .font(.caption2)
                .foregroundStyle(readerForegroundColor)

                HStack(spacing: 14) {
                    Button(action: readingDirection == .rightToLeft ? goToNextPage : goToPreviousPage) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 18, height: 18)
                    }
                    .disabled(readingDirection == .rightToLeft
                              ? vm.currentPage == vm.totalPages - 1
                              : vm.currentPage == 0)
                    .help(AppLocalization.localized(readingDirection == .rightToLeft ? "下一页" : "上一页"))
                    .accessibilityLabel(AppLocalization.localized(readingDirection == .rightToLeft ? "下一页" : "上一页"))

                    Slider(
                        value: readerProgressBinding,
                        in: 0...Double(max(vm.totalPages - 1, 1)),
                        step: 1
                    ) { isEditing in
                        if isEditing {
                            lastHapticProgressPage = vm.currentPage
                        } else {
                            lastHapticProgressPage = nil
                            if vm.isDoublePageEnabled { vm.syncSpreadIndex() }
                            Task { await vm.onPageChange(vm.currentPage) }
                        }
                    }
                    .tint(readerThemeColor)
                    .accentColor(readerThemeColor)
                    .accessibilityLabel("阅读进度")
                    .accessibilityValue("第 \(vm.currentPage + 1) 页，共 \(vm.totalPages) 页")

                    Button(action: readingDirection == .rightToLeft ? goToPreviousPage : goToNextPage) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 18, height: 18)
                    }
                    .disabled(readingDirection == .rightToLeft
                              ? vm.currentPage == 0
                              : vm.currentPage == vm.totalPages - 1)
                    .help(AppLocalization.localized(readingDirection == .rightToLeft ? "上一页" : "下一页"))
                    .accessibilityLabel(AppLocalization.localized(readingDirection == .rightToLeft ? "上一页" : "下一页"))
                }

            }
            .foregroundStyle(readerForegroundColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(
                .regular.tint(readerPanelTint),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 24,
                    bottomLeadingRadius: readerPanelOuterCornerRadius(geometry),
                    bottomTrailingRadius: readerPanelOuterCornerRadius(geometry),
                    topTrailingRadius: 24,
                    style: .continuous
                )
            )
            .buttonStyle(.glass)
            .frame(maxWidth: 760)
        }
        .padding(.horizontal, readerHorizontalInset(geometry))
        .padding(.bottom, max(18, geometry.safeAreaInsets.bottom + 10))
    }

    /// 保持控制面板远离圆角屏幕、刘海和 Stage Manager 窗口边缘。
    private func readerHorizontalInset(_ geometry: GeometryProxy) -> CGFloat {
        max(20, max(geometry.safeAreaInsets.leading, geometry.safeAreaInsets.trailing) + 10)
    }

    private func readerPanelOuterCornerRadius(_ geometry: GeometryProxy) -> CGFloat {
        // Home Indicator 安全区能可靠区分圆角 iPhone 与方角窗口；面板向内
        // 缩进后使用相应的连续曲率，使底部轮廓与屏幕边框近似同心。
        if geometry.safeAreaInsets.bottom >= 20 {
            return min(42, max(32, geometry.safeAreaInsets.bottom + 3))
        }
        return 26
    }

    private var readerProgressBinding: Binding<Double> {
        Binding(
            get: {
                let maxPage = max(vm.totalPages - 1, 0)
                return Double(readingDirection == .rightToLeft ? maxPage - vm.currentPage : vm.currentPage)
            },
            set: { value in
                let maxPage = max(vm.totalPages - 1, 0)
                let visualPage = max(0, min(maxPage, Int(value.rounded())))
                let target = readingDirection == .rightToLeft ? maxPage - visualPage : visualPage
                if target != vm.currentPage, lastHapticProgressPage != target {
                    Haptics.select()
                    lastHapticProgressPage = target
                }
                pageNavigationDelta = target >= vm.currentPage ? 1 : -1
                vm.currentPage = target
            }
        )
    }

    // MARK: - HUD Overlay

    private func hudOverlay(geometry: GeometryProxy) -> some View {
        VStack {
            Spacer()
            HStack {
                #if os(macOS)
                if showClock {
                    Text(currentTime, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(readerForegroundColor)
                }

                Spacer()
                #endif
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, max(20, geometry.safeAreaInsets.leading + 12))
            .padding(.bottom, max(12, geometry.safeAreaInsets.bottom + 4))
            .foregroundStyle(readerForegroundColor)
        }
    }

    // MARK: - Floating Navigation Overlay (浮动导航)

    /// 浮动导航栏 — 工具栏隐藏时始终可见，提供翻页和工具栏切换
    /// 修复: 上下滚动模式无法翻页 + 没有上/下一页按钮
    @ViewBuilder
    private func floatingNavigationOverlay(geometry: GeometryProxy) -> some View {
        if shouldShowFloatingNavigation {
            let isRTL = readingDirection == .rightToLeft
            let isVertical = readingDirection == .topToBottom
            let isFirstPage = vm.currentPage <= 0
            let isLastPage = vm.currentPage >= vm.totalPages - 1

            VStack {
                Spacer()

                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                    // 左侧 / 上一页按钮
                    Button {
                        if isRTL { goToNextPage() } else { goToPreviousPage() }
                    } label: {
                        Image(systemName: isVertical ? "chevron.up" : "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(readerForegroundColor)
                            .frame(width: 28, height: 22)
                    }
                    .disabled(isRTL ? isLastPage : isFirstPage)
                    .opacity((isRTL ? isLastPage : isFirstPage) ? 0.25 : 0.8)

                    // 中央: 页码 + 点击切换工具栏
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
                    } label: {
                        Group {
                            if showProgress {
                                Text("\(vm.currentPage + 1) / \(vm.totalPages)")
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                            } else {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                        .foregroundStyle(readerSecondaryForegroundColor)
                        .frame(minWidth: showProgress ? 72 : 38, minHeight: 22)
                    }

                    // 右侧 / 下一页按钮
                    Button {
                        if isRTL { goToPreviousPage() } else { goToNextPage() }
                    } label: {
                        Image(systemName: isVertical ? "chevron.down" : "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(readerForegroundColor)
                            .frame(width: 28, height: 22)
                    }
                    .disabled(isRTL ? isFirstPage : isLastPage)
                    .opacity((isRTL ? isFirstPage : isLastPage) ? 0.25 : 0.8)
                    }
                }
                .buttonStyle(.glass)
                .padding(.bottom, max(16, geometry.safeAreaInsets.bottom + 4))
            }
        }
    }

    private var shouldShowFloatingNavigation: Bool {
        #if os(macOS)
        !showOverlay && vm.totalPages > 0 && !isFullScreen
        #else
        !showOverlay && vm.totalPages > 0
        #endif
    }

    private var shouldShowReaderHUD: Bool {
        #if os(macOS)
        !showOverlay && !isFullScreen && showClock
        #else
        false
        #endif
    }

    #if os(iOS)
    /// iOS 的时钟和电量属于同一个系统状态栏，不能由应用分别重绘而仍保持
    /// 系统样式。任一状态项开启时显示系统栏；全屏时遵循沉浸式设置隐藏。
    private var shouldHideSystemStatusBar: Bool {
        AppSettings.shared.readingFullscreen || (!showClock && !showBattery)
    }
    #endif

    private var readerTopPadding: CGFloat {
        #if os(macOS)
        18
        #else
        60
        #endif
    }

}

#if os(macOS)
/// Resolves the NSWindow hosting the reader so full-screen commands target the
/// correct window even when several application windows are open.
private struct ReaderWindowAccessor: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}
#endif

// MARK: - Reader Settings Sheet

struct ReaderSettingsSheet: View {
    @Binding var readingDirection: ReadingDirection
    @Binding var scaleMode: ScaleMode
    @Binding var startPosition: StartPosition
    @Binding var autoPageEnabled: Bool
    @Binding var showClock: Bool
    @Binding var showProgress: Bool
    @Binding var showBattery: Bool
    @Binding var showPageInterval: Bool
    @Binding var pageDisplayMode: ReaderPageDisplayMode
    @Binding var pageAnimationEnabled: Bool
    @Binding var backgroundMode: ReaderBackgroundMode
    let showsPageLayoutSettings: Bool
    #if os(macOS)
    @Binding var isFullScreen: Bool
    let onToggleFullscreen: () -> Void
    #endif
    @State private var keepScreenOn = AppSettings.shared.keepScreenOn
    @State private var autoPageInterval = AppSettings.shared.autoPageInterval
    @State private var draftShowClock = false
    @State private var draftShowProgress = false
    @State private var draftShowBattery = false
    @State private var draftShowPageInterval = false
    @State private var draftPageAnimation = true
    @State private var draftFullscreen = false
    @State private var hasLoadedDrafts = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读方向") {
                    Picker("方向", selection: $readingDirection) {
                        ForEach(ReadingDirection.allCases, id: \.rawValue) { dir in
                            Label(dir.label, systemImage: dir.icon).tag(dir)
                        }
                    }
                    .onChange(of: readingDirection) { _, newValue in
                        AppSettings.shared.readingDirection = newValue.rawValue
                    }
                }

                Section("缩放模式") {
                    Picker("缩放", selection: $scaleMode) {
                        ForEach(ScaleMode.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .onChange(of: scaleMode) { _, newValue in
                        AppSettings.shared.pageScaling = newValue.rawValue
                    }
                }

                Section("背景") {
                    Picker("阅读背景", selection: $backgroundMode) {
                        ForEach(ReaderBackgroundMode.allCases, id: \.rawValue) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: backgroundMode) { _, newValue in
                        AppSettings.shared.readerBackgroundMode = newValue.rawValue
                    }
                }

                Section("起始位置") {
                    Picker("位置", selection: $startPosition) {
                        ForEach(StartPosition.allCases, id: \.rawValue) { pos in
                            Text(pos.label).tag(pos)
                        }
                    }
                    .onChange(of: startPosition) { _, newValue in
                        AppSettings.shared.startPosition = newValue.rawValue
                    }
                }

                if showsPageLayoutSettings && readingDirection != .topToBottom {
                    Section("页面布局") {
                        Picker("显示方式", selection: $pageDisplayMode) {
                            ForEach(ReaderPageDisplayMode.allCases, id: \.rawValue) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Toggle("翻页动画", isOn: $draftPageAnimation)
                            .onChange(of: draftPageAnimation) { _, value in
                                guard hasLoadedDrafts else { return }
                                pageAnimationEnabled = value
                            }
                    }
                }

                Section("显示") {
                    #if os(iOS)
                    Toggle("显示系统状态栏", isOn: Binding(
                        get: { draftShowClock || draftShowBattery },
                        set: { value in
                            draftShowClock = value
                            draftShowBattery = value
                            guard hasLoadedDrafts else { return }
                            showClock = value
                            showBattery = value
                            AppSettings.shared.showClock = value
                            AppSettings.shared.showBattery = value
                        }
                    ))
                    #else
                    Toggle("显示时钟", isOn: $draftShowClock)
                        .onChange(of: draftShowClock) { _, value in
                            guard hasLoadedDrafts else { return }
                            showClock = value
                            AppSettings.shared.showClock = value
                        }
                    #endif
                    Toggle("显示进度", isOn: $draftShowProgress)
                        .onChange(of: draftShowProgress) { _, value in
                            guard hasLoadedDrafts else { return }
                            showProgress = value
                            AppSettings.shared.showProgress = value
                        }
                    Toggle("页面间距", isOn: $draftShowPageInterval)
                        .onChange(of: draftShowPageInterval) { _, value in
                            guard hasLoadedDrafts else { return }
                            showPageInterval = value
                            AppSettings.shared.showPageInterval = value
                        }
                }

                Section("行为") {
                    #if os(macOS)
                    Toggle("全屏模式", isOn: $draftFullscreen)
                        .onChange(of: draftFullscreen) { _, desiredState in
                            guard hasLoadedDrafts, desiredState != isFullScreen else { return }
                            isFullScreen = desiredState
                            AppSettings.shared.readingFullscreen = desiredState
                            onToggleFullscreen()
                        }
                    #else
                    Toggle("屏幕常亮", isOn: $keepScreenOn)
                        .onChange(of: keepScreenOn) { _, value in
                            AppSettings.shared.keepScreenOn = value
                            UIApplication.shared.isIdleTimerDisabled = value
                        }
                    Toggle("全屏模式", isOn: Binding(
                        get: { AppSettings.shared.readingFullscreen },
                        set: { AppSettings.shared.readingFullscreen = $0 }
                    ))
                    #endif

                    #if os(iOS)
                    Toggle("自定义亮度", isOn: Binding(
                        get: { AppSettings.shared.customScreenLightness },
                        set: { AppSettings.shared.customScreenLightness = $0 }
                    ))

                    if AppSettings.shared.customScreenLightness {
                        HStack {
                            Image(systemName: "sun.min")
                            Slider(value: Binding(
                                get: { Double(AppSettings.shared.screenLightness) },
                                set: {
                                    AppSettings.shared.screenLightness = Int($0)
                                    setScreenBrightness(CGFloat($0) / 100.0)
                                }
                            ), in: 0...100)
                            Image(systemName: "sun.max")
                        }
                    }
                    #endif
                }

                Section("自动翻页") {
                    Stepper(
                        "间隔: \(autoPageInterval) 秒",
                        value: $autoPageInterval,
                        in: 1...60
                    )
                    .onChange(of: autoPageInterval) { _, value in
                        AppSettings.shared.autoPageInterval = value
                    }
                }
            }
            #if os(macOS)
            .toggleStyle(.switch)
            .formStyle(.grouped)
            #endif
            .navigationTitle("阅读设置")
            .onAppear {
                draftShowClock = showClock
                draftShowProgress = showProgress
                draftShowBattery = showBattery
                draftShowPageInterval = showPageInterval
                draftPageAnimation = pageAnimationEnabled
                #if os(macOS)
                draftFullscreen = isFullScreen
                #else
                draftFullscreen = AppSettings.shared.readingFullscreen
                #endif
                hasLoadedDrafts = true
            }
            #if os(macOS)
            .onChange(of: isFullScreen) { _, value in
                if draftFullscreen != value { draftFullscreen = value }
            }
            #endif
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

// Perf P0-2: PageOffsetPreferenceKey 已移除 — 改用 .scrollPosition(id:) 追踪页码

// MARK: - Edge Swipe Dismiss (iOS fullScreenCover 边缘侧滑返回)

#if os(iOS)
/// UIScreenEdgePanGestureRecognizer — 在 fullScreenCover 中实现原生边缘右滑返回
/// fullScreenCover 无 UINavigationController，需要自行添加手势
struct EdgeSwipeDismissView: UIViewRepresentable {
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = EdgeSwipeGestureView()
        let edgeGesture = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleEdgePan(_:))
        )
        edgeGesture.edges = .left
        // 降低手势优先级，避免与 TabView 滑动冲突
        edgeGesture.delegate = context.coordinator
        view.addGestureRecognizer(edgeGesture)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    /// 透明视图，仅在左边缘 30pt 内响应触摸
    class EdgeSwipeGestureView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // 只拦截左边缘 30pt 的触摸
            if point.x < 30 {
                return self
            }
            return nil
        }
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        @objc func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let translation = gesture.translation(in: gesture.view)
            let velocity = gesture.velocity(in: gesture.view)
            // 滑动距离 > 80pt 或速度 > 500 则触发返回
            if translation.x > 80 || velocity.x > 500 {
                onDismiss()
            }
        }

        // 允许与其他手势同时识别
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            return false
        }
    }
}
#endif

// MARK: - macOS Scroll Wheel Page Navigator

#if os(macOS)
/// macOS 滚轮翻页 — 累积 deltaY 超过阈值翻页
struct ScrollWheelPageNavigator: NSViewRepresentable {
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void
    let onSingleTap: (CGPoint, CGSize) -> Void
    let isZoomed: Bool

    func makeNSView(context: Context) -> ScrollWheelCaptureView {
        let view = ScrollWheelCaptureView()
        view.onNext = onNext
        view.onPrevious = onPrevious
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        view.onSingleTap = onSingleTap
        view.isZoomed = isZoomed
        return view
    }

    func updateNSView(_ nsView: ScrollWheelCaptureView, context: Context) {
        nsView.onNext = onNext
        nsView.onPrevious = onPrevious
        nsView.onSwipeLeft = onSwipeLeft
        nsView.onSwipeRight = onSwipeRight
        nsView.onSingleTap = onSingleTap
        nsView.isZoomed = isZoomed
    }

    class ScrollWheelCaptureView: NSView {
        var onNext: (() -> Void)?
        var onPrevious: (() -> Void)?
        var onSwipeLeft: (() -> Void)?
        var onSwipeRight: (() -> Void)?
        var onSingleTap: ((CGPoint, CGSize) -> Void)?
        var isZoomed: Bool = false
        private var accumulatedVerticalDelta: CGFloat = 0
        private var accumulatedHorizontalDelta: CGFloat = 0
        private let threshold: CGFloat = 70
        private var lastScrollTime: Date = .distantPast
        private var hasTurnedPageInCurrentGesture = false

        override func scrollWheel(with event: NSEvent) {
            guard !isZoomed else {
                super.scrollWheel(with: event)
                return
            }

            let delta = event.scrollingDeltaY
            let horizontalDelta = event.scrollingDeltaX
            let now = Date()
            if event.phase.contains(.began) || now.timeIntervalSince(lastScrollTime) > 0.45 {
                accumulatedVerticalDelta = 0
                accumulatedHorizontalDelta = 0
                hasTurnedPageInCurrentGesture = false
            }
            lastScrollTime = now

            // Trackpad momentum emits many scroll events after the finger has
            // left the surface. One physical gesture must never turn more than
            // one page.
            guard !hasTurnedPageInCurrentGesture else { return }

            // Trackpad horizontal swipes follow the physical movement of the
            // content; semantic next/previous mapping is supplied by the view.
            if abs(horizontalDelta) > abs(delta) {
                accumulatedHorizontalDelta += horizontalDelta
                if accumulatedHorizontalDelta > threshold {
                    hasTurnedPageInCurrentGesture = true
                    onSwipeRight?()
                } else if accumulatedHorizontalDelta < -threshold {
                    hasTurnedPageInCurrentGesture = true
                    onSwipeLeft?()
                }
                return
            }

            accumulatedVerticalDelta += delta

            if accumulatedVerticalDelta > threshold {
                hasTurnedPageInCurrentGesture = true
                onPrevious?()
            } else if accumulatedVerticalDelta < -threshold {
                hasTurnedPageInCurrentGesture = true
                onNext?()
            }
        }

        override func swipe(with event: NSEvent) {
            let now = Date()
            if event.phase.contains(.began) || now.timeIntervalSince(lastScrollTime) > 0.45 {
                hasTurnedPageInCurrentGesture = false
            }
            lastScrollTime = now
            guard !hasTurnedPageInCurrentGesture else { return }
            hasTurnedPageInCurrentGesture = true
            if event.deltaX > 0 {
                onSwipeRight?()
            } else if event.deltaX < 0 {
                onSwipeLeft?()
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 1 else {
                super.mouseDown(with: event)
                return
            }
            let location = convert(event.locationInWindow, from: nil)
            onSingleTap?(
                CGPoint(x: location.x, y: bounds.height - location.y),
                bounds.size
            )
        }

        override var acceptsFirstResponder: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            if isZoomed { return nil }
            return frame.contains(point) ? self : nil
        }
    }
}
#endif

// MARK: - Helper Functions

#if os(iOS)
/// 设置屏幕亮度
private func setScreenBrightness(_ brightness: CGFloat) {
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let screen = windowScene.windows.first?.screen {
        screen.brightness = brightness
    }
}
#endif
