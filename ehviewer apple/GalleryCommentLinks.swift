import SwiftUI
import EhModels

/// 评论中的 EH/EX 画廊链接。显示文本仍保留原网址，但点击时
/// 使用应用内部 scheme，避免先跳 Safari 再回到应用。
nonisolated enum GalleryCommentLinks {
    private static let anchorRegex = try! NSRegularExpression(
        pattern: #"<a\b[^>]*href\s*=\s*[\"'](https?://(?:e-hentai\.org|exhentai\.org)/g/\d+/[A-Za-z0-9]+/?[^\"']*)[\"'][^>]*>(.*?)</a>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let htmlTagRegex = try! NSRegularExpression(
        pattern: #"<[^>]+>"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let galleryURLRegex = try! NSRegularExpression(
        pattern: #"https?://(?:e-hentai\.org|exhentai\.org)/g/(\d+)/([A-Za-z0-9]+)(?:/[^\s<]*)?"#,
        options: [.caseInsensitive]
    )

    static func attributedText(fromHTML html: String) -> AttributedString {
        let fullRange = NSRange(html.startIndex..., in: html)
        var plain = anchorRegex.stringByReplacingMatches(
            in: html,
            range: fullRange,
            withTemplate: "$2 ($1)"
        )
        plain = htmlTagRegex.stringByReplacingMatches(
            in: plain,
            range: NSRange(plain.startIndex..., in: plain),
            withTemplate: ""
        )
        plain = decodeCommonEntities(plain)

        var attributed = AttributedString(plain)
        let matches = galleryURLRegex.matches(
            in: plain,
            range: NSRange(plain.startIndex..., in: plain)
        )
        for match in matches.reversed() {
            guard let full = Range(match.range(at: 0), in: plain),
                  let gidRange = Range(match.range(at: 1), in: plain),
                  let tokenRange = Range(match.range(at: 2), in: plain),
                  let gid = Int64(plain[gidRange]),
                  let start = AttributedString.Index(full.lowerBound, within: attributed),
                  let end = AttributedString.Index(full.upperBound, within: attributed),
                  let internalURL = URL(
                    string: "ehviewer-gallery://open?gid=\(gid)&token=\(plain[tokenRange])"
                  ) else { continue }
            attributed[start..<end].link = internalURL
            attributed[start..<end].foregroundColor = .accentColor
            attributed[start..<end].underlineStyle = .single
        }
        return attributed
    }

    @MainActor
    static func gallery(from url: URL) -> GalleryInfo? {
        guard url.scheme == "ehviewer-gallery",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let gidText = components.queryItems?.first(where: { $0.name == "gid" })?.value,
              let gid = Int64(gidText),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else { return nil }
        let identity = GalleryInfo(gid: gid, token: token)
        return GalleryCache.shared.mergeCachedMetadata(into: [identity]).first ?? identity
    }

    private static func decodeCommonEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
