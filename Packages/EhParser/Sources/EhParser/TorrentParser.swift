import Foundation

// MARK: - TorrentParser (对应 Android TorrentParser.java)
// 解析种子列表页面 HTML

public enum TorrentParser {

    /// 种子链接 + 名称正则 (对应 Android PATTERN)
    /// <td colspan="5"> &nbsp; <a href="URL">NAME</a></td>
    private static let pattern = try! NSRegularExpression(
        pattern: #"<td colspan="5"> &nbsp; <a href="([^"]+)"[^<]+>([^<]+)</a></td>"#
    )

    /// 解析种子列表
    /// - Returns: [(url, name)] 数组，url 已移除 `?p=` 前缀
    public static func parse(_ body: String) -> [(String, String)] {
        var result: [(String, String)] = []

        let nsBody = body as NSString
        let range = NSRange(location: 0, length: nsBody.length)

        for match in pattern.matches(in: body, range: range) {
            guard let urlRange = Range(match.range(at: 1), in: body),
                  let nameRange = Range(match.range(at: 2), in: body) else {
                continue
            }

            var url = String(body[urlRange])
            let name = String(body[nameRange])

            // 对应 Android: 移除 "?p=" 参数前缀
            // url = url.replace("?p=", "")
            // 实际是去除 URL 中的 ?p= 及其值
            if let range = url.range(of: "?p=") {
                // 这里 Android 做法是简单 replace ?p= → ""，我们需要去掉整个 query param
                let idx = range.lowerBound
                url = String(url[..<idx])
            }

            result.append((url, name))
        }

        return result
    }
}
