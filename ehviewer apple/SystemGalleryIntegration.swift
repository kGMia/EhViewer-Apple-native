import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import EhModels
import EhDatabase

/// Native discovery and continuity hooks shared by Spotlight and Handoff.
enum SystemGalleryIntegration {
    static let activityType = "kgmia.ehviewer-apple.view-gallery"
    private static let spotlightDomain = "kgmia.ehviewer-apple.galleries"

    static func deepLink(for gallery: GalleryInfo) -> URL? {
        var components = URLComponents()
        components.scheme = "ehviewer"
        components.host = "gallery"
        components.queryItems = [
            URLQueryItem(name: "gid", value: String(gallery.gid)),
            URLQueryItem(name: "token", value: gallery.token)
        ]
        return components.url
    }

    static func configure(_ activity: NSUserActivity, gallery: GalleryInfo) {
        activity.title = gallery.bestTitle
        var userInfo: [String: Any] = [
            "gid": gallery.gid,
            "token": gallery.token,
            "pages": gallery.pages,
            "category": gallery.category.rawValue
        ]
        if let title = gallery.title { userInfo["title"] = title }
        if let titleJpn = gallery.titleJpn { userInfo["titleJpn"] = titleJpn }
        if let thumb = gallery.thumb { userInfo["thumb"] = thumb }
        if let uploader = gallery.uploader { userInfo["uploader"] = uploader }
        activity.userInfo = userInfo
        activity.requiredUserInfoKeys = ["gid", "token"]
        // Do not publish a website fallback. On a second Apple device this made
        // Handoff advertise the activity as Safari instead of EhViewer.
        activity.webpageURL = nil
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = true
        activity.isEligibleForPublicIndexing = false
        activity.persistentIdentifier = NSUserActivityPersistentIdentifier("gallery-\(gallery.gid)")
        activity.contentAttributeSet = attributes(for: gallery)
    }

    static func gallery(from activity: NSUserActivity) -> GalleryInfo? {
        guard activity.activityType == activityType else { return nil }
        let rawGID = activity.userInfo?["gid"]
        let gid = (rawGID as? Int64)
            ?? (rawGID as? NSNumber)?.int64Value
            ?? (rawGID as? String).flatMap(Int64.init)
        guard let gid,
              let token = activity.userInfo?["token"] as? String,
              !token.isEmpty
        else { return nil }
        let userInfo = activity.userInfo
        let pages = (userInfo?["pages"] as? NSNumber)?.intValue
            ?? (userInfo?["pages"] as? Int)
            ?? 0
        let categoryRaw = (userInfo?["category"] as? NSNumber)?.intValue
            ?? (userInfo?["category"] as? Int)
            ?? EhCategory.misc.rawValue
        let identity = GalleryInfo(
            gid: gid,
            token: token,
            title: userInfo?["title"] as? String ?? activity.title,
            titleJpn: userInfo?["titleJpn"] as? String,
            thumb: userInfo?["thumb"] as? String,
            category: EhCategory(rawValue: categoryRaw),
            uploader: userInfo?["uploader"] as? String,
            pages: pages
        )
        return GalleryCache.shared.mergeCachedMetadata(into: [identity]).first ?? identity
    }

    static func index(_ gallery: GalleryInfo) async {
        let item = CSSearchableItem(
            uniqueIdentifier: "gallery-\(gallery.gid)",
            domainIdentifier: spotlightDomain,
            attributeSet: attributes(for: gallery)
        )
        do {
            try await CSSearchableIndex.default().indexSearchableItems([item])
        } catch {
            debugLog("[Spotlight] Failed to index gallery \(gallery.gid): \(error)")
        }
    }

    static func indexRecentHistory(limit: Int = 100) async {
        let records = await Task.detached(priority: .utility) {
            (try? EhDatabase.shared.getAllHistory(limit: limit)) ?? []
        }.value
        guard !records.isEmpty else { return }
        let items = records.map { record in
            let gallery = record.galleryInfo
            return CSSearchableItem(
                uniqueIdentifier: "gallery-\(gallery.gid)",
                domainIdentifier: spotlightDomain,
                attributeSet: attributes(for: gallery)
            )
        }
        do {
            try await CSSearchableIndex.default().indexSearchableItems(items)
        } catch {
            debugLog("[Spotlight] Failed to index reading history: \(error)")
        }
    }

    private static func attributes(for gallery: GalleryInfo) -> CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = gallery.bestTitle
        attributes.displayName = gallery.bestTitle
        attributes.contentDescription = [gallery.uploader, gallery.simpleLanguage]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        attributes.keywords = gallery.simpleTags
        attributes.contentURL = deepLink(for: gallery)
        if let thumb = gallery.thumb.flatMap(URL.init(string:)) {
            attributes.thumbnailURL = thumb
        }
        return attributes
    }
}
