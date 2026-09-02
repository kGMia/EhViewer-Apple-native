//
//  AppIntentsSupport.swift
//  ehviewer apple
//
//  Siri / Shortcuts integration for opening the app's primary sections.
//

import AppIntents
import Foundation
import EhDatabase
import EhModels

enum EhViewerIntentSection: String, AppEnum {
    case home
    case favorites
    case downloads
    case history
    case subscription
    case toplist
    case settings
    #if os(macOS)
    case popular
    #endif

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "EhViewer 页面")
    #if os(macOS)
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .home: DisplayRepresentation(title: "首页", image: .init(systemName: "house")),
        .favorites: DisplayRepresentation(title: "收藏", image: .init(systemName: "heart")),
        .downloads: DisplayRepresentation(title: "下载", image: .init(systemName: "arrow.down.circle")),
        .history: DisplayRepresentation(title: "历史", image: .init(systemName: "clock")),
        .subscription: DisplayRepresentation(title: "订阅", image: .init(systemName: "star.bubble")),
        .toplist: DisplayRepresentation(title: "排行榜", image: .init(systemName: "chart.bar")),
        .settings: DisplayRepresentation(title: "设置", image: .init(systemName: "gear")),
        .popular: DisplayRepresentation(title: "热门", image: .init(systemName: "flame"))
    ]
    #else
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .home: DisplayRepresentation(title: "首页", image: .init(systemName: "house")),
        .favorites: DisplayRepresentation(title: "收藏", image: .init(systemName: "heart")),
        .downloads: DisplayRepresentation(title: "下载", image: .init(systemName: "arrow.down.circle")),
        .history: DisplayRepresentation(title: "历史", image: .init(systemName: "clock")),
        .subscription: DisplayRepresentation(title: "订阅", image: .init(systemName: "star.bubble")),
        .toplist: DisplayRepresentation(title: "排行榜", image: .init(systemName: "chart.bar")),
        .settings: DisplayRepresentation(title: "设置", image: .init(systemName: "gear"))
    ]
    #endif
}

struct OpenEhViewerSectionIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 EhViewer 页面"
    static let description = IntentDescription("打开 EhViewer，并前往指定的主要页面。")
    static let openAppWhenRun = true

    @Parameter(title: "页面", default: .home)
    var section: EhViewerIntentSection

    init() {}

    init(section: EhViewerIntentSection) {
        self.section = section
    }

    static var parameterSummary: some ParameterSummary {
        Summary("打开 \(\.$section)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppNavigationRequest.send(section)
        return .result()
    }
}

/// 允许 Spotlight、Siri 与快捷指令直接打开应用内搜索结果。
struct SearchEhViewerIntent: AppIntent {
    static let title: LocalizedStringResource = "搜索 EhViewer 画廊"
    static let description = IntentDescription("打开 EhViewer 并搜索指定的关键词或标签。")
    static let openAppWhenRun = true

    @Parameter(title: "搜索内容")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("在 EhViewer 中搜索 \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw $query.needsValueError("请输入要搜索的关键词或标签。")
        }
        AppNavigationRequest.sendSearch(normalizedQuery)
        return .result()
    }
}

/// 从本地历史记录恢复最近一次阅读，不发起额外网络请求；阅读器会继续使用
/// 自己的本地下载检查、缓存和按需加载流程。
struct ContinueReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "继续阅读 EhViewer"
    static let description = IntentDescription("打开最近阅读的画廊并恢复到上次页码。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let latest = try await Task.detached(priority: .userInitiated) {
            try EhDatabase.shared.getAllHistory(limit: 1).first
        }.value

        guard let latest else {
            return .result(dialog: "暂无可继续的阅读记录。")
        }

        let progressKey = "reading_progress_\(latest.gid)"
        let storedPage = UserDefaults.standard.object(forKey: progressKey) as? Int
        let initialPage = storedPage.map { min(max(0, $0), max(0, latest.pages - 1)) }
        AppNavigationRequest.sendReader(ReaderWindowRoute(
            gid: latest.gid,
            token: latest.token,
            pages: latest.pages,
            previewSet: nil,
            initialPage: initialPage
        ))
        return .result(dialog: "正在恢复最近的阅读进度。")
    }
}

struct EhViewerAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenEhViewerSectionIntent(),
            phrases: [
                "在 \(.applicationName) 中打开 \(\.$section)",
                "用 \(.applicationName) 打开 \(\.$section)"
            ],
            shortTitle: "打开 EhViewer 页面",
            systemImageName: "rectangle.split.3x1"
        )
        AppShortcut(
            intent: SearchEhViewerIntent(),
            phrases: [
                "使用 \(.applicationName) 搜索画廊",
                "在 \(.applicationName) 中搜索画廊"
            ],
            shortTitle: "搜索画廊",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenEhViewerSectionIntent(section: .favorites),
            phrases: [
                "在 \(.applicationName) 中打开收藏",
                "用 \(.applicationName) 查看收藏"
            ],
            shortTitle: "打开收藏",
            systemImageName: "heart"
        )
        AppShortcut(
            intent: OpenEhViewerSectionIntent(section: .downloads),
            phrases: [
                "在 \(.applicationName) 中打开下载",
                "用 \(.applicationName) 查看下载"
            ],
            shortTitle: "打开下载",
            systemImageName: "arrow.down.circle"
        )
        AppShortcut(
            intent: OpenEhViewerSectionIntent(section: .history),
            phrases: [
                "在 \(.applicationName) 中打开历史",
                "用 \(.applicationName) 查看历史"
            ],
            shortTitle: "打开历史",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: OpenEhViewerSectionIntent(section: .subscription),
            phrases: [
                "在 \(.applicationName) 中打开订阅",
                "用 \(.applicationName) 查看订阅"
            ],
            shortTitle: "打开订阅",
            systemImageName: "star.bubble"
        )
        AppShortcut(
            intent: ContinueReadingIntent(),
            phrases: [
                "在 \(.applicationName) 中继续阅读",
                "用 \(.applicationName) 继续阅读"
            ],
            shortTitle: "继续阅读",
            systemImageName: "book.pages"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .purple
}

/// App Intent 可能在主界面订阅通知之前运行。请求同时写入 UserDefaults，
/// MainTabView 启动时消费一次，从而覆盖冷启动与已运行两种路径。
enum AppNavigationRequest {
    static let notification = Notification.Name("openEhViewerSection")
    static let searchNotification = Notification.Name("searchEhViewerGalleries")
    static let readerNotification = Notification.Name("continueReadingEhViewerGallery")
    private static let pendingSectionKey = "pendingAppIntentSection"
    private static let pendingSearchKey = "pendingAppIntentSearch"
    private static let pendingReaderKey = "pendingAppIntentReader"

    @MainActor
    static func send(_ section: EhViewerIntentSection) {
        // 导航请求互斥：冷启动前连续运行多个快捷指令时，只保留最后一次，
        // 避免下一窗口又消费到较早的搜索或阅读请求。
        UserDefaults.standard.removeObject(forKey: pendingSearchKey)
        UserDefaults.standard.removeObject(forKey: pendingReaderKey)
        UserDefaults.standard.set(section.rawValue, forKey: pendingSectionKey)
        NotificationCenter.default.post(
            name: notification,
            object: section.rawValue
        )
    }

    @MainActor
    static func sendSearch(_ query: String) {
        UserDefaults.standard.removeObject(forKey: pendingSectionKey)
        UserDefaults.standard.removeObject(forKey: pendingReaderKey)
        UserDefaults.standard.set(query, forKey: pendingSearchKey)
        NotificationCenter.default.post(name: searchNotification, object: query)
    }

    @MainActor
    static func sendReader(_ route: ReaderWindowRoute) {
        UserDefaults.standard.removeObject(forKey: pendingSectionKey)
        UserDefaults.standard.removeObject(forKey: pendingSearchKey)
        if let data = encodedReaderRoute(route) {
            UserDefaults.standard.set(data, forKey: pendingReaderKey)
        }
        NotificationCenter.default.post(name: readerNotification, object: route)
    }

    static func consumePending() -> EhViewerIntentSection? {
        guard let rawValue = UserDefaults.standard.string(forKey: pendingSectionKey) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: pendingSectionKey)
        return EhViewerIntentSection(rawValue: rawValue)
    }

    static func consumePendingSearch() -> String? {
        guard let query = UserDefaults.standard.string(forKey: pendingSearchKey) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: pendingSearchKey)
        return query
    }

    static func consumePendingReader() -> ReaderWindowRoute? {
        guard let data = UserDefaults.standard.data(forKey: pendingReaderKey) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: pendingReaderKey)
        return readerRoute(from: data)
    }

    static func encodedReaderRoute(_ route: ReaderWindowRoute) -> Data? {
        try? JSONEncoder().encode(route)
    }

    static func readerRoute(from data: Data) -> ReaderWindowRoute? {
        try? JSONDecoder().decode(ReaderWindowRoute.self, from: data)
    }
}
