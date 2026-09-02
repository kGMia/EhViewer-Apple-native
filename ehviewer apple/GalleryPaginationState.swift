import Foundation
import EhModels

/// 画廊信息流统一分页状态。服务器可能返回整数页码，也可能返回不透明的
/// prev/next 游标链接；调用方不应猜测或自行递增服务器游标。
struct GalleryPaginationState {
    struct Snapshot: Codable {
        let currentPage: Int
        let firstLoadedPage: Int
        let lastLoadedPage: Int
        let nextPage: Int?
        let firstHref: String?
        let prevHref: String?
        let nextHref: String?
        let lastHref: String?
        let totalPages: Int
        let hasMore: Bool
    }

    enum NextRequest: Equatable {
        case page(Int)
        case href(String)
    }

    private(set) var currentPage = 0
    private(set) var firstLoadedPage = 0
    private(set) var lastLoadedPage = 0
    private(set) var nextPage: Int?
    private(set) var firstHref: String?
    private(set) var prevHref: String?
    private(set) var nextHref: String?
    private(set) var lastHref: String?
    private(set) var totalPages = 0
    private(set) var hasMore = false
    private var seenGalleryIDs: Set<Int64> = []

    var nextRequest: NextRequest? {
        guard hasMore else { return nil }
        if let nextHref, !nextHref.isEmpty { return .href(nextHref) }
        if let nextPage, nextPage > lastLoadedPage { return .page(nextPage) }
        return nil
    }

    mutating func reset() {
        self = GalleryPaginationState()
    }

    var snapshot: Snapshot {
        Snapshot(
            currentPage: currentPage,
            firstLoadedPage: firstLoadedPage,
            lastLoadedPage: lastLoadedPage,
            nextPage: nextPage,
            firstHref: firstHref,
            prevHref: prevHref,
            nextHref: nextHref,
            lastHref: lastHref,
            totalPages: totalPages,
            hasMore: hasMore
        )
    }

    mutating func restore(_ snapshot: Snapshot, galleries: [GalleryInfo]) {
        currentPage = max(0, snapshot.currentPage)
        firstLoadedPage = max(0, snapshot.firstLoadedPage)
        lastLoadedPage = max(firstLoadedPage, snapshot.lastLoadedPage)
        nextPage = Self.normalized(page: snapshot.nextPage)
        firstHref = Self.nonempty(snapshot.firstHref)
        prevHref = Self.nonempty(snapshot.prevHref)
        nextHref = Self.nonempty(snapshot.nextHref)
        lastHref = Self.nonempty(snapshot.lastHref)
        totalPages = max(0, snapshot.totalPages)
        let hasForwardCursor = nextPage != nil || nextHref != nil
        hasMore = snapshot.hasMore && hasForwardCursor
        seenGalleryIDs = Set(galleries.map(\.gid))
    }

    mutating func restore(
        nextPage: Int?,
        nextHref: String?,
        firstHref: String? = nil,
        lastHref: String? = nil,
        totalPages: Int,
        hasMore: Bool
    ) {
        currentPage = 0
        firstLoadedPage = 0
        lastLoadedPage = 0
        self.nextPage = Self.normalized(page: nextPage)
        self.firstHref = Self.nonempty(firstHref)
        prevHref = nil
        self.nextHref = Self.nonempty(nextHref)
        self.lastHref = Self.nonempty(lastHref)
        self.totalPages = totalPages
        self.hasMore = hasMore && (self.nextPage != nil || self.nextHref != nil)
        seenGalleryIDs.removeAll(keepingCapacity: true)
    }

    /// 保留服务器顺序、过滤响应内部及跨页重复项。首屏替换时会重置身份集合。
    mutating func merge(_ galleries: [GalleryInfo], replacing: Bool) -> [GalleryInfo] {
        if replacing { seenGalleryIDs.removeAll(keepingCapacity: true) }
        return galleries.filter { seenGalleryIDs.insert($0.gid).inserted }
    }

    mutating func consume(
        nextPage: Int?,
        firstHref: String? = nil,
        prevHref: String?,
        nextHref: String?,
        lastHref: String? = nil,
        totalPages: Int,
        loadedPage: Int,
        appendedCount: Int,
        replacing: Bool
    ) {
        if replacing {
            currentPage = loadedPage
            firstLoadedPage = loadedPage
            lastLoadedPage = loadedPage
            self.nextPage = Self.normalized(page: nextPage)
            self.firstHref = Self.nonempty(firstHref)
            self.prevHref = Self.nonempty(prevHref)
            self.nextHref = Self.nonempty(nextHref)
            self.lastHref = Self.nonempty(lastHref)
            self.totalPages = totalPages
        } else {
            // Appending advances only the lower edge of the list. Keep the
            // original `prev` cursor so a later pull-down never points into
            // pages that are already visible.
            currentPage = max(currentPage, loadedPage)
            lastLoadedPage = max(lastLoadedPage, loadedPage)
            self.nextPage = Self.normalized(page: nextPage)
            self.nextHref = Self.nonempty(nextHref)
            if self.firstHref == nil { self.firstHref = Self.nonempty(firstHref) }
            if let lastHref = Self.nonempty(lastHref) { self.lastHref = lastHref }
            self.totalPages = max(self.totalPages, totalPages)
        }

        let hasCursor = self.nextPage != nil || self.nextHref != nil
        // 首屏即便为空也应忠实采用服务器状态；追加页完全重复时停止，
        // 防止异常边缘节点返回同一游标造成无限请求循环。
        hasMore = hasCursor && (replacing || appendedCount > 0)
    }

    /// Consumes a page inserted before the currently loaded range. The next
    /// boundary deliberately remains unchanged because those pages are
    /// already present below the insertion point.
    mutating func consumePrepending(
        firstHref: String? = nil,
        prevHref: String?,
        totalPages: Int,
        loadedPage: Int,
        prependedCount: Int
    ) {
        firstLoadedPage = min(firstLoadedPage, loadedPage)
        self.prevHref = prependedCount > 0 ? Self.nonempty(prevHref) : nil
        if self.firstHref == nil { self.firstHref = Self.nonempty(firstHref) }
        self.totalPages = max(self.totalPages, totalPages)
    }

    private static func normalized(page: Int?) -> Int? {
        page.flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
