//
//  GalleryActionService.swift
//  ehviewer apple
//
//  统一画廊操作服务 — 收藏/下载/分享/复制链接的唯一真相源
//  所有 View 通过此服务执行操作，禁止在 Button(action:) 中直接写业务逻辑
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings
import EhDatabase
import EhDownload

// MARK: - 画廊操作服务 (Single Source of Truth)

@Observable
@MainActor
final class GalleryActionService {
    static let shared = GalleryActionService()
    private(set) var watchLaterGIDs: Set<Int64> = []
    /// GalleryInfo 来自服务器且为值类型。操作完成后用轻量覆盖表立即更新
    /// 当前列表，而不必刷新整页或等待服务器重新返回 favoriteSlot。
    private var favoriteOverrides: [Int64: Bool] = [:]
    /// SwiftUI 的滑动按钮、菜单和触控手势可能在极短时间内重复触发。
    /// 合并同一 gid 的收藏请求，避免一加一减或重复网络写入导致状态闪烁。
    private var activeFavoriteGIDs: Set<Int64> = []

    private init() {}

    // MARK: - 收藏

    /// 快速收藏 — 使用默认收藏夹 (对齐 Android: onModifyFavorite with defaultFavSlot)
    /// - 默认 slot >= 0: 直接添加到云端
    /// - 默认 slot == -1: 添加到本地
    /// - 默认 slot == -2: 返回 false，调用方应弹出选择器
    /// - Returns: true 表示已执行操作, false 表示需要弹出选择器
    @discardableResult
    func quickFavorite(gallery: GalleryInfo) async throws -> Bool {
        let defaultSlot = AppSettings.shared.defaultFavSlot
        if defaultSlot >= 0 && defaultSlot <= 9 {
            try await addFavorite(gid: gallery.gid, token: gallery.token, slot: defaultSlot)
            return true
        } else if defaultSlot == -1 {
            try await addLocalFavorite(gallery: gallery)
            return true
        }
        return false // 需要弹出选择器
    }

    /// 添加云端收藏 (Fix B-3: 失败时抛出错误，让调用方回滚)
    func addFavorite(gid: Int64, token: String, slot: Int) async throws {
        try await EhAPI.shared.addFavorites(gid: gid, token: token, dstCat: slot)
        favoriteOverrides[gid] = true
        AppSettings.shared.recentFavCat = slot
        NotificationCenter.default.post(name: .galleryFavoriteChanged,
                                        object: nil,
                                        userInfo: ["gid": gid, "favorited": true, "slot": slot])
    }

    /// 添加本地收藏 (对齐 Android FAV_CAT_LOCAL = -1)
    func addLocalFavorite(gallery: GalleryInfo) async throws {
        let record = gallery.localFavoriteRecord()
        try await Task.detached(priority: .userInitiated) {
            try EhDatabase.shared.insertLocalFavorite(record)
        }.value
        favoriteOverrides[gallery.gid] = true
        NotificationCenter.default.post(name: .galleryFavoriteChanged,
                                        object: nil,
                                        userInfo: ["gid": gallery.gid, "favorited": true, "slot": -1])
    }

    /// 取消收藏 (Fix B-3: 失败时抛出错误，让调用方回滚)
    func removeFavorite(gid: Int64, token: String) async throws {
        try await EhAPI.shared.addFavorites(gid: gid, token: token, dstCat: -1)
        try? await Task.detached(priority: .userInitiated) {
            try EhDatabase.shared.deleteLocalFavorite(gid: gid)
        }.value
        favoriteOverrides[gid] = false
        NotificationCenter.default.post(name: .galleryFavoriteChanged,
                                        object: nil,
                                        userInfo: ["gid": gid, "favorited": false])
    }

    func isFavorited(_ gallery: GalleryInfo) -> Bool {
        favoriteOverrides[gallery.gid] ?? (gallery.favoriteSlot >= 0)
    }

    func toggleFavorite(_ gallery: GalleryInfo) async {
        guard activeFavoriteGIDs.insert(gallery.gid).inserted else { return }
        defer { activeFavoriteGIDs.remove(gallery.gid) }

        do {
            if isFavorited(gallery) {
                try await removeFavorite(gid: gallery.gid, token: gallery.token)
            } else {
                // “每次询问”必须由调用方展示收藏夹选择器；这里不擅自
                // 选取收藏夹。列表和详情页都会在调用本方法前处理它。
                _ = try await quickFavorite(gallery: gallery)
            }
        } catch {
            ErrorHandler.shared.handle(error, context: "ToggleFavorite")
        }
    }

    // MARK: - 下载

    /// 快速下载 (Fix A-1: 已失败/已暂停的任务允许重新启动)
    func startDownload(gallery: GalleryInfo) async {
        // Ask only after an explicit download action, never during cold start.
        _ = await DownloadNotificationService.shared.requestAuthorization()
        await DownloadManager.shared.startDownload(gallery: gallery)
    }

    // MARK: - 稍后再看

    func isInWatchLater(gid: Int64) -> Bool {
        watchLaterGIDs.contains(gid)
    }

    func reloadWatchLaterState() async {
        let gids = (try? await Task.detached(priority: .utility) {
            Set(try EhDatabase.shared.getAllWatchLater().map(\.gid))
        }.value) ?? []
        watchLaterGIDs = gids
    }

    func addToWatchLater(_ gallery: GalleryInfo) async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try EhDatabase.shared.saveToWatchLater(gallery.watchLaterRecord())
            }.value
            watchLaterGIDs.insert(gallery.gid)
            NotificationCenter.default.post(name: .watchLaterChanged, object: gallery.gid)
        } catch {
            ErrorHandler.shared.handle(error, context: "AddWatchLater")
        }
    }

    func removeFromWatchLater(gid: Int64) async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try EhDatabase.shared.deleteWatchLater(gid: gid)
            }.value
            watchLaterGIDs.remove(gid)
            NotificationCenter.default.post(name: .watchLaterChanged, object: gid)
        } catch {
            ErrorHandler.shared.handle(error, context: "RemoveWatchLater")
        }
    }


    func clearWatchLater() async throws {
        try await Task.detached(priority: .userInitiated) {
            try EhDatabase.shared.clearWatchLater()
        }.value
        watchLaterGIDs.removeAll(keepingCapacity: true)
        NotificationCenter.default.post(name: .watchLaterChanged, object: nil)
    }

    // MARK: - 分享/复制

    /// 获取画廊 URL
    func galleryURL(gid: Int64, token: String) -> String {
        let site = Self.siteBaseURL
        return "\(site)g/\(gid)/\(token)/"
    }

    /// 复制画廊链接到剪贴板
    func copyLink(gid: Int64, token: String) {
        let url = galleryURL(gid: gid, token: token)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        #else
        UIPasteboard.general.string = url
        #endif
    }

    // MARK: - 站点工具

    /// 统一站点 URL — 替代分散在 4 个文件中的 getSite() 重复代码
    /// 包含 ExHentai cookie 验证回退逻辑 (对齐 Android: 检查 igneous cookie)
    static var siteBaseURL: String {
        switch AppSettings.shared.gallerySite {
        case .exHentai:
            let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://exhentai.org")!) ?? []
            let hasEX = cookies.contains { $0.name == "igneous" && !$0.value.isEmpty && $0.value != "mystery" }
            return hasEX ? "https://exhentai.org/" : "https://e-hentai.org/"
        case .eHentai:
            return "https://e-hentai.org/"
        }
    }
}

// MARK: - 通知名称

extension Notification.Name {
    /// 画廊收藏状态变化 (userInfo: gid, favorited, slot?)
    static let galleryFavoriteChanged = Notification.Name("galleryFavoriteChanged")
    static let watchLaterChanged = Notification.Name("watchLaterChanged")
}
