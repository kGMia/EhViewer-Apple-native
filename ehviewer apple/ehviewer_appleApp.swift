//
//  ehviewer_appleApp.swift
//  ehviewer apple
//
//  EhViewer for Apple platforms — E-Hentai/ExHentai gallery browser
//

import SwiftUI
import AppIntents
import UserNotifications
import EhDownload
import EhSpider
import EhSettings
import EhDatabase
import EhAPI
import EhCookie
#if os(iOS)
import UIKit
#endif

@main
struct EhViewerApp: App {
    // ⚠️ 不在 App 层创建 AppState — 由 RootView 独占管理
    // 避免多个 @Observable 实例触发 App 重渲染

    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    @State private var settings = AppSettings.shared

    init() {
        // Authentication cookies are session-only when Keychain is available;
        // restore them before RootView evaluates the initial login state.
        EhCookieManager.shared.ensureCredentialsRestored()
        // 配置全局 URLCache (对标 Android Conaco 320MB 磁盘缓存)
        // AsyncImage 和所有使用 URLSession.shared 的代码都会受益
        URLCache.shared = URLCache(
            memoryCapacity: 20 * 1024 * 1024,     // 20MB 内存
            diskCapacity: 320 * 1024 * 1024,       // 320MB 磁盘
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("url_cache")
        )
        // 注意: 后台任务注册由 AppDelegate.didFinishLaunchingWithOptions 负责
        // 不要在此处重复调用, BGTaskScheduler 对同一 identifier 注册两次会崩溃
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .modifier(AppAccentTintModifier(accent: settings.accentColor))
        }
        .environment(\.locale, settings.appLanguage.locale)
        #if os(macOS)
        // A real relaunch starts with one clean main window. Restoring every
        // previous window eagerly rebuilt multiple feeds before the first
        // interactive frame.
        .restorationBehavior(.disabled)
        .defaultSize(width: 1100, height: 750)
        #endif
        .commands {
            SidebarCommands()
            BrowserCommands()
            GalleryCommands()
            #if os(macOS)
            NewWindowCommands()
            ReaderCommands()
            #endif
        }

        #if os(macOS)
        WindowGroup("阅读器", for: ReaderWindowRoute.self) { $route in
            if let route {
                ImageReaderView(
                    gid: route.gid,
                    token: route.token,
                    pages: route.pages,
                    previewSet: route.previewSet,
                    initialPage: route.initialPage
                )
                .modifier(AppAccentTintModifier(accent: settings.accentColor))
            } else {
                ContentUnavailableView("无法打开阅读器", systemImage: "book.closed")
            }
        }
        .environment(\.locale, settings.appLanguage.locale)
        .defaultSize(width: 1200, height: 820)
        .windowResizability(.contentMinSize)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .frame(width: 720, height: 650)
                .modifier(AppAccentTintModifier(accent: settings.accentColor))
        }
        .environment(\.locale, settings.appLanguage.locale)
        #endif
    }
}

#if os(macOS)
/// 使用 SwiftUI 的场景系统创建窗口，避免将未注册 URL Scheme 交给 AppKit。
private struct NewWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建窗口") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}
#endif

/// 导航菜单只操作当前聚焦窗口，多窗口之间不再通过全局通知联动。
private struct BrowserCommands: Commands {
    @FocusedValue(\.selectedMainTab) private var selectedTab
    @FocusedValue(\.browserCommandActions) private var actions
    @FocusedValue(\.mainNavigationActions) private var navigationActions
    @State private var recentHistory = RecentHistoryMenuModel.shared

    var body: some Commands {
        CommandMenu("浏览") {
            Button("首页") { selectedTab?.wrappedValue = .home }
                .keyboardShortcut("1", modifiers: .command)
            Button("订阅") { selectedTab?.wrappedValue = .subscription }
                .keyboardShortcut("2", modifiers: .command)
            #if os(macOS)
            Button("热门") { selectedTab?.wrappedValue = .popular }
                .keyboardShortcut("3", modifiers: .command)
            #endif
            Button("收藏") { selectedTab?.wrappedValue = .favorites }
                .keyboardShortcut("4", modifiers: .command)
            Button("下载") { selectedTab?.wrappedValue = .downloads }
                .keyboardShortcut("5", modifiers: .command)
            Menu("历史") {
                Button("显示全部历史") { selectedTab?.wrappedValue = .history }
                    .keyboardShortcut("6", modifiers: .command)

                Divider()

                if recentHistory.records.isEmpty {
                    Text("暂无历史记录")
                } else {
                    ForEach(recentHistory.records, id: \.gid) { record in
                        Button(record.titleJpn ?? record.title) {
                            navigationActions?.openGallery(record.galleryInfo)
                        }
                        .disabled(navigationActions == nil)
                    }
                }
            }
            Button("搜索页面") { selectedTab?.wrappedValue = .search }
                .keyboardShortcut("7", modifiers: .command)

            Divider()

            Button("刷新") { actions?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions == nil)

            Button("搜索") { actions?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)

            Button("切换列表/瀑布流") { actions?.toggleDisplayMode() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}

private struct GalleryCommands: Commands {
    @FocusedValue(\.galleryCommandActions) private var actions

    var body: some Commands {
        CommandMenu("画廊") {
            Button("阅读") { actions?.read() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(actions == nil)

            Divider()

            Button("下载") { actions?.download() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(actions == nil)

            Button("收藏") { actions?.toggleFavorite() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(actions == nil)
        }
    }
}

#if os(macOS)
private struct ReaderCommands: Commands {
    @FocusedValue(\.readerCommandActions) private var actions

    var body: some Commands {
        CommandMenu("阅读") {
            Button("向左翻页") { actions?.leftArrow() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(actions == nil)
            Button("向右翻页") { actions?.rightArrow() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(actions == nil)
            Button("下一页 (空格)") { actions?.nextPage() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(actions == nil)

            Divider()

            Button("退出阅读") { actions?.exit() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(actions == nil)

            Divider()

            Button("全屏") { actions?.toggleFullscreen() }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(actions == nil)
        }
    }
}
#endif

/// 将非 UI 启动工作从 `App.init` 移出，确保 SwiftUI 先提交首帧。
/// 实例是幂等的，场景重建不会重复注册监听器或发起更新。
@MainActor
final class ApplicationBootstrap {
    static let shared = ApplicationBootstrap()

    private var hasStarted = false
    private var hasScheduledMaintenance = false
    private var deferredServicesTask: Task<Void, Never>?

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        // Expensive singleton construction must not share the first-frame main
        // actor. Both caches are safe to initialize on a utility executor.
        Task.detached(priority: .utility) {
            SpiderDen.initialize()
            _ = EhAPI.shared
        }

        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(2))
            do {
                try await EhTagDatabase.shared.updateDatabase(forceUpdate: false)
                await MainActor.run { debugLog("[EhTagDatabase] Auto-update check completed") }
            } catch {
                await MainActor.run { debugLog("[EhTagDatabase] Auto-update failed: \(error)") }
            }
        }

        deferredServicesTask = Task { @MainActor in
            // Preserve the launch and initial scrolling window for interactive
            // work before restoring secondary services and Spotlight state.
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }

            Haptics.prepareForInteraction()
            EhViewerAppShortcuts.updateAppShortcutParameters()
            UNUserNotificationCenter.current().delegate = DownloadNotificationService.shared

            let downloadManager = await Task.detached(priority: .utility) {
                DownloadManager.shared
            }.value
            await downloadManager.setListener(DownloadNotificationBridge.shared)
            await GalleryActionService.shared.reloadWatchLaterState()

            #if os(macOS)
            await RecentHistoryMenuModel.shared.refresh()
            #endif

            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await SystemGalleryIntegration.indexRecentHistory()
        }
    }

    func scheduleDatabaseMaintenance() {
        guard !hasScheduledMaintenance else { return }
        hasScheduledMaintenance = true

        Task.detached(priority: .background) {
            EhDatabase.shared.performMaintenanceIfNeeded()
        }
    }
}

// MARK: - Navigation Notifications

extension Notification.Name {
    static let openGalleryFromClipboard = Notification.Name("openGalleryFromClipboard")
    /// 标签搜索 (对齐 Android: onTagClick → mUrlBuilder.set(tag) → mHelper.refresh())
    static let tagSearchRequested = Notification.Name("tagSearchRequested")
    /// 磁盘空间不足，所有下载已暂停
    static let ehDiskFull = Notification.Name("ehDiskFull")
    /// 全局错误展示 (GlobalErrorBoundary 监听)
    static let ehGlobalError = Notification.Name("ehGlobalError")
}
