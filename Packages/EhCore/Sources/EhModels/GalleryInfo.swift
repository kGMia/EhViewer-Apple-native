import Foundation

// MARK: - 画廊基础信息 (对应 Android GalleryInfo.java)

public struct GalleryInfo: Identifiable, Sendable, Codable, Hashable {
    public var id: Int64 { gid }

    // MARK: 核心标识
    public var gid: Int64
    public var token: String

    // MARK: 元数据
    public var title: String?
    public var titleJpn: String?
    public var thumb: String?
    public var category: EhCategory
    public var posted: String?
    public var uploader: String?
    public var rating: Float
    public var rated: Bool

    // MARK: 附加信息
    public var pages: Int
    public var simpleTags: [String]?
    public var simpleLanguage: String?

    // MARK: 收藏状态
    public var favoriteSlot: Int  // -2=未初始化, -1=未收藏, 0-9=收藏分组
    public var favoriteName: String?

    // MARK: 缩略图布局信息
    public var thumbWidth: Int
    public var thumbHeight: Int

    public init(
        gid: Int64 = 0,
        token: String = "",
        title: String? = nil,
        titleJpn: String? = nil,
        thumb: String? = nil,
        category: EhCategory = .misc,
        posted: String? = nil,
        uploader: String? = nil,
        rating: Float = 0,
        rated: Bool = false,
        pages: Int = 0,
        simpleTags: [String]? = nil,
        simpleLanguage: String? = nil,
        favoriteSlot: Int = -2,
        favoriteName: String? = nil,
        thumbWidth: Int = 0,
        thumbHeight: Int = 0
    ) {
        self.gid = gid
        self.token = token
        self.title = title
        self.titleJpn = titleJpn
        self.thumb = thumb
        self.category = category
        self.posted = posted
        self.uploader = uploader
        self.rating = rating
        self.rated = rated
        self.pages = pages
        self.simpleTags = simpleTags
        self.simpleLanguage = simpleLanguage
        self.favoriteSlot = favoriteSlot
        self.favoriteName = favoriteName
        self.thumbWidth = thumbWidth
        self.thumbHeight = thumbHeight
    }

    /// 获取最佳显示标题 (优先日文 - 默认行为)
    public var bestTitle: String {
        titleJpn ?? title ?? "未命名画廊"
    }

    /// 根据设置获取适合的标题 (对齐 Android EhUtils.getSuitableTitle)
    /// - Parameter preferJpn: 是否优先显示日文/中文标题
    /// - Returns: 适合的标题
    public func suitableTitle(preferJpn: Bool) -> String {
        if preferJpn {
            // 优先日文/中文标题，如果为空则显示英文
            let jpn = titleJpn ?? ""
            return jpn.isEmpty ? (title ?? "未命名画廊") : jpn
        } else {
            // 优先英文标题，如果为空则显示日文/中文
            let eng = title ?? ""
            return eng.isEmpty ? (titleJpn ?? "未命名画廊") : eng
        }
    }

    /// 信息流可直接展示的作者标签。保持服务端顺序并去重，不把上传者与
    /// `artist:` 标签混为一谈，因为二者在 EH 中代表不同身份。
    public var authorNames: [String] {
        var seen: Set<String> = []
        return (simpleTags ?? []).compactMap { rawTag in
            let parts = rawTag.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].localizedCaseInsensitiveCompare("artist") == .orderedSame
            else { return nil }
            let name = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
    }

    // MARK: - 从标签推断语言 (对应 Android GalleryInfo.generateSLang)

    /// 语言标签 → 简称映射表 (对应 Android S_LANG_TAGS → S_LANGS)
    private static let langTagMap: [(tag: String, lang: String)] = [
        ("language:chinese", "ZH"),
        ("language:english", "EN"),
        ("language:japanese", "JA"),
        ("language:korean", "KO"),
        ("language:french", "FR"),
        ("language:german", "DE"),
        ("language:spanish", "ES"),
        ("language:italian", "IT"),
        ("language:russian", "RU"),
        ("language:thai", "TH"),
        ("language:portuguese", "PT"),
        ("language:polish", "PL"),
        ("language:dutch", "NL"),
        ("language:hungarian", "HU"),
        ("language:vietnamese", "VI"),
        ("language:czech", "CS"),
        ("language:indonesian", "ID"),
        ("language:arabic", "AR"),
        ("language:turkish", "TR"),
    ]

    /// 根据 simpleTags 中的 language:xxx 标签推断语言简称
    public mutating func generateSLang() {
        guard let tags = simpleTags else { return }
        for (tag, lang) in Self.langTagMap {
            if tags.contains(tag) {
                simpleLanguage = lang
                return
            }
        }
    }
}
