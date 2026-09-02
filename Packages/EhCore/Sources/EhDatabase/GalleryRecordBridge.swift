import Foundation
import EhModels

/// 数据库记录与 GalleryInfo 的唯一转换入口。所有持久化路径必须保留标题、
/// 封面、上传者、语言及评分，避免下载/历史/收藏之间往返后元数据逐步丢失。
public extension GalleryInfo {
    private var persistenceTitle: String {
        title ?? titleJpn ?? "未命名画廊"
    }

    func historyRecord(mode: Int = 0, date: Date = Date()) -> HistoryRecord {
        HistoryRecord(
            gid: gid, token: token, title: persistenceTitle,
            titleJpn: titleJpn, thumb: thumb,
            category: category.rawValue, posted: posted, uploader: uploader,
            rating: rating, simpleLanguage: simpleLanguage,
            pages: pages, mode: mode, date: date
        )
    }

    func downloadRecord(state: Int, label: String? = nil, date: Date = Date()) -> DownloadRecord {
        DownloadRecord(
            gid: gid, token: token, title: persistenceTitle,
            titleJpn: titleJpn, thumb: thumb,
            category: category.rawValue, posted: posted, uploader: uploader,
            rating: rating, simpleLanguage: simpleLanguage,
            pages: pages, state: state, label: label, date: date
        )
    }

    func localFavoriteRecord(date: Date = Date()) -> LocalFavoriteRecord {
        var record = LocalFavoriteRecord(
            gid: gid, token: token, title: persistenceTitle,
            category: category.rawValue, pages: pages, date: date
        )
        record.titleJpn = titleJpn
        record.thumb = thumb
        record.posted = posted
        record.uploader = uploader
        record.rating = rating
        record.simpleLanguage = simpleLanguage
        return record
    }

    func watchLaterRecord(date: Date = Date()) -> WatchLaterRecord {
        WatchLaterRecord(
            gid: gid, token: token, title: persistenceTitle,
            titleJpn: titleJpn, thumb: thumb,
            category: category.rawValue, posted: posted, uploader: uploader,
            rating: rating, simpleLanguage: simpleLanguage,
            pages: pages, date: date
        )
    }

    func favoriteMetadataRecord(
        site: EhSite,
        serverOrder: Int,
        syncID: String,
        syncedAt: Date = Date()
    ) -> FavoriteMetadataRecord {
        let tagsJSON = simpleTags.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        return FavoriteMetadataRecord(
            site: site.rawValue,
            gid: gid,
            token: token,
            title: persistenceTitle,
            titleJpn: titleJpn,
            thumb: thumb,
            category: category.rawValue,
            posted: posted,
            uploader: uploader,
            rating: rating,
            simpleLanguage: simpleLanguage,
            pages: pages,
            tagsJSON: tagsJSON,
            favoriteSlot: favoriteSlot,
            serverOrder: serverOrder,
            syncID: syncID,
            syncedAt: syncedAt
        )
    }
}

public extension HistoryRecord {
    var galleryInfo: GalleryInfo {
        GalleryInfo(
            gid: gid, token: token, title: title, titleJpn: titleJpn, thumb: thumb,
            category: EhCategory(rawValue: category), posted: posted, uploader: uploader,
            rating: rating, pages: pages, simpleLanguage: simpleLanguage
        )
    }
}

public extension DownloadRecord {
    var galleryInfo: GalleryInfo {
        GalleryInfo(
            gid: gid, token: token, title: title, titleJpn: titleJpn, thumb: thumb,
            category: EhCategory(rawValue: category), posted: posted, uploader: uploader,
            rating: rating, pages: pages, simpleLanguage: simpleLanguage
        )
    }
}

public extension LocalFavoriteRecord {
    var galleryInfo: GalleryInfo {
        GalleryInfo(
            gid: gid, token: token, title: title, titleJpn: titleJpn, thumb: thumb,
            category: EhCategory(rawValue: category), posted: posted, uploader: uploader,
            rating: rating, pages: pages, simpleLanguage: simpleLanguage
        )
    }
}

public extension WatchLaterRecord {
    var galleryInfo: GalleryInfo {
        GalleryInfo(
            gid: gid, token: token, title: title, titleJpn: titleJpn, thumb: thumb,
            category: EhCategory(rawValue: category), posted: posted, uploader: uploader,
            rating: rating, pages: pages, simpleLanguage: simpleLanguage
        )
    }
}

public extension FavoriteMetadataRecord {
    var galleryInfo: GalleryInfo {
        let tags = tagsJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        return GalleryInfo(
            gid: gid,
            token: token,
            title: title,
            titleJpn: titleJpn,
            thumb: thumb,
            category: EhCategory(rawValue: category),
            posted: posted,
            uploader: uploader,
            rating: rating,
            pages: pages,
            simpleTags: tags,
            simpleLanguage: simpleLanguage,
            favoriteSlot: favoriteSlot
        )
    }
}
