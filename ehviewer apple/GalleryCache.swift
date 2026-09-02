//
//  GalleryCache.swift
//  ehviewer apple
//
//  内存缓存层 — 对标 Android LruCache<Long, GalleryDetail> + 画廊列表缓存
//  避免切换 Tab / 返回时重复网络请求
//

import Foundation
import EhModels

/// 全局画廊缓存 (线程安全)
final class GalleryCache: @unchecked Sendable {
    static let shared = GalleryCache()

    // MARK: - Gallery Detail Cache (对标 Android LruCache<Long, GalleryDetail>, 容量 25)

    private let detailCache = NSCache<NSNumber, GalleryDetailWrapper>()

    // MARK: - Gallery List Cache (按 URL/mode 缓存列表页结果)

    private let listCache = NSCache<NSString, GalleryListResultWrapper>()

    // MARK: - Gallery Metadata Cache (标签、语言、作者等列表补全数据)

    private let metadataCache = NSCache<NSNumber, GalleryInfoWrapper>()
    private let hydratedMetadata = NSCache<NSNumber, NSNumber>()

    // MARK: - Image URL Cache (缓存已解析的图片 URL, 避免重复请求页面 HTML)

    private let imageURLCache = NSCache<NSString, NSString>()
    #if os(macOS)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

    private init() {
        // 对标 Android: LruCache for detail
        detailCache.countLimit = 50
        // 列表缓存: 最多保留 40 个不同查询的结果
        listCache.countLimit = 40
        metadataCache.countLimit = 2_000
        hydratedMetadata.countLimit = 4_000
        // 图片 URL 缓存: 最多 1000 条
        imageURLCache.countLimit = 1000

        #if os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.clearMemoryHeavyCaches()
            }
        }
        source.resume()
        memoryPressureSource = source
        #endif
    }

    deinit {
        #if os(macOS)
        memoryPressureSource?.cancel()
        #endif
    }

    // MARK: - Detail

    func getDetail(gid: Int64) -> GalleryDetail? {
        detailCache.object(forKey: NSNumber(value: gid))?.value
    }

    func putDetail(_ detail: GalleryDetail) {
        detailCache.setObject(GalleryDetailWrapper(detail), forKey: NSNumber(value: detail.info.gid))
    }

    func removeDetail(gid: Int64) {
        detailCache.removeObject(forKey: NSNumber(value: gid))
    }

    // MARK: - Gallery List

    /// 缓存 key = URL string (去掉 page 参数) + page
    func getListResult(forKey key: String) -> CachedGalleryListResult? {
        guard let wrapper = listCache.object(forKey: key as NSString) else { return nil }
        // 缓存有效期: 15 分钟
        if Date().timeIntervalSince(wrapper.timestamp) > 900 {
            listCache.removeObject(forKey: key as NSString)
            return nil
        }
        return wrapper.value
    }

    func putListResult(_ result: CachedGalleryListResult, forKey key: String) {
        listCache.setObject(GalleryListResultWrapper(result), forKey: key as NSString)
    }

    func removeListResult(forKey key: String) {
        listCache.removeObject(forKey: key as NSString)
    }

    // MARK: - Gallery Metadata

    func mergeCachedMetadata(into galleries: [GalleryInfo]) -> [GalleryInfo] {
        galleries.map { gallery in
            guard let cached = metadataCache.object(
                forKey: NSNumber(value: gallery.gid)
            )?.value else { return gallery }
            return Self.merge(primary: gallery, fallback: cached)
        }
    }

    func putMetadata(_ galleries: [GalleryInfo], markHydrated: Bool = false) {
        for gallery in galleries {
            let key = NSNumber(value: gallery.gid)
            let merged: GalleryInfo
            if let cached = metadataCache.object(forKey: key)?.value {
                merged = Self.merge(primary: gallery, fallback: cached)
            } else {
                merged = gallery
            }
            metadataCache.setObject(GalleryInfoWrapper(merged), forKey: key)
            if markHydrated {
                hydratedMetadata.setObject(NSNumber(value: 1), forKey: key)
            }
        }
    }

    func needsMetadataHydration(_ gallery: GalleryInfo) -> Bool {
        let key = NSNumber(value: gallery.gid)
        guard hydratedMetadata.object(forKey: key) == nil else { return false }
        return gallery.simpleTags?.isEmpty != false || gallery.simpleLanguage?.isEmpty != false
    }

    private static func merge(primary: GalleryInfo, fallback: GalleryInfo) -> GalleryInfo {
        var result = primary
        if result.title?.isEmpty != false { result.title = fallback.title }
        if result.titleJpn?.isEmpty != false { result.titleJpn = fallback.titleJpn }
        if result.thumb?.isEmpty != false { result.thumb = fallback.thumb }
        if result.posted?.isEmpty != false { result.posted = fallback.posted }
        if result.uploader?.isEmpty != false { result.uploader = fallback.uploader }
        if result.simpleTags?.isEmpty != false { result.simpleTags = fallback.simpleTags }
        if result.simpleLanguage?.isEmpty != false { result.simpleLanguage = fallback.simpleLanguage }
        if result.pages == 0 { result.pages = fallback.pages }
        if result.thumbWidth == 0 { result.thumbWidth = fallback.thumbWidth }
        if result.thumbHeight == 0 { result.thumbHeight = fallback.thumbHeight }
        if result.favoriteSlot == -2 { result.favoriteSlot = fallback.favoriteSlot }
        return result
    }

    // MARK: - Image URL

    /// key = "gid:pageIndex"
    func getImageURL(gid: Int64, page: Int) -> String? {
        let key = "\(gid):\(page)" as NSString
        return imageURLCache.object(forKey: key) as? String
    }

    func putImageURL(_ url: String, gid: Int64, page: Int) {
        let key = "\(gid):\(page)" as NSString
        imageURLCache.setObject(url as NSString, forKey: key)
    }

    func removeImageURL(gid: Int64, page: Int) {
        let key = "\(gid):\(page)" as NSString
        imageURLCache.removeObject(forKey: key)
    }

    // MARK: - Clear

    func clearAll() {
        detailCache.removeAllObjects()
        listCache.removeAllObjects()
        metadataCache.removeAllObjects()
        hydratedMetadata.removeAllObjects()
        imageURLCache.removeAllObjects()
    }

    /// 内存压力时只释放包含大量模型数组的缓存；图片 URL 是小字符串且能避免
    /// 重新解析阅读页 HTML，因此保留到用户主动清理缓存或自然逐出。
    private func clearMemoryHeavyCaches() {
        detailCache.removeAllObjects()
        listCache.removeAllObjects()
        metadataCache.removeAllObjects()
        hydratedMetadata.removeAllObjects()
    }

    func clearListCache() {
        listCache.removeAllObjects()
    }
}

// MARK: - Wrapper Types (NSCache 需要 class 类型)

private final class GalleryDetailWrapper: NSObject {
    let value: GalleryDetail
    init(_ value: GalleryDetail) { self.value = value }
}

struct CachedGalleryListResult {
    let galleries: [GalleryInfo]
    let hasMore: Bool
    let nextPage: Int?
    let nextHref: String?
    let firstHref: String?
    let lastHref: String?
    let totalPages: Int? // 对齐 Android: GalleryListResult.pages
}

private final class GalleryListResultWrapper: NSObject {
    let value: CachedGalleryListResult
    let timestamp: Date
    init(_ value: CachedGalleryListResult) {
        self.value = value
        self.timestamp = Date()
    }
}

private final class GalleryInfoWrapper: NSObject {
    let value: GalleryInfo
    init(_ value: GalleryInfo) { self.value = value }
}
