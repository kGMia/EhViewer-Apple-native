import Foundation
import EhModels
import SwiftSoup

// MARK: - 用户标签列表解析器 (对应 Android MyTagLitParser.java)

public enum MyTagListParser {

    /// 错误检测正则
    private static let errorRegex = try! NSRegularExpression(
        pattern: #"<div class="d">\n<p>([^<]+)</p>"#
    )

    /// 解析用户标签列表 (对应 Android MyTagLitParser.parse)
    public static func parse(_ body: String) throws -> UserTagList {
        var list = UserTagList()

        // 错误检测
        let nsBody = body as NSString
        let fullRange = NSRange(location: 0, length: nsBody.length)
        if let match = errorRegex.firstMatch(in: body, range: fullRange),
           let range = Range(match.range(at: 1), in: body) {
            throw MyTagError.serverError(String(body[range]))
        }

        let doc = try SwiftSoup.parse(body)
        guard let outer = try doc.getElementById("usertags_outer") else {
            return list
        }

        // The site has used both direct children and nested wrappers for user
        // tag rows. Selecting by the stable row id avoids silently returning an
        // empty list when that surrounding markup changes.
        let rows = try outer.select("[id^=usertag_]").filter { element in
            element.id().dropFirst("usertag_".count).allSatisfy(\.isNumber)
        }
        for tag in rows {
            if let userTag = parseUserTag(tag) {
                list.userTags.append(userTag)
            }
        }

        return list
    }

    /// 解析单个用户标签 (对应 Android MyTagLitParser.parserUserTag)
    private static func parseUserTag(_ tag: Element) -> UserTag? {
        do {
            let userTagId = tag.id()
            let id = String(userTagId.dropFirst("usertag_".count))

            // Both tagpreview{id} and tagpreview_{id} have existed. Fall back
            // to the row's first tagpreview element and its visible text.
            let preview = try tag.getElementById("tagpreview\(id)")
                ?? tag.getElementById("tagpreview_\(id)")
                ?? tag.select("[id^=tagpreview]").first()
            let title = try preview?.attr("title") ?? ""
            let tagName = title.isEmpty ? (try preview?.text() ?? "") : title
            guard !tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            // watched: #tagwatch{id} 的 checked 属性
            let watchInput = try tag.getElementById("tagwatch\(id)")
                ?? tag.getElementById("tagwatch_\(id)")
                ?? tag.select("[id^=tagwatch]").first()
            let watched = watchInput?.hasAttr("checked") == true

            // hidden: #taghide{id} 的 checked 属性
            let hideInput = try tag.getElementById("taghide\(id)")
                ?? tag.getElementById("taghide_\(id)")
                ?? tag.select("[id^=taghide]").first()
            let hidden = hideInput?.hasAttr("checked") == true

            // color: #tagcolor{id} 的 placeholder 属性
            let colorInput = try tag.getElementById("tagcolor\(id)")
                ?? tag.getElementById("tagcolor_\(id)")
                ?? tag.select("[id^=tagcolor]").first()
            let color = try colorInput?.attr("placeholder")

            // tagWeight: #tagweight{id} 的 value 属性
            let weightInput = try tag.getElementById("tagweight\(id)")
                ?? tag.getElementById("tagweight_\(id)")
                ?? tag.select("[id^=tagweight]").first()
            let weightString = try weightInput?.attr("value") ?? "0"
            let tagWeight = Int(weightString) ?? 0

            return UserTag(
                userTagId: userTagId,
                tagName: tagName,
                watched: watched,
                hidden: hidden,
                color: color?.isEmpty == true ? nil : color,
                tagWeight: tagWeight
            )
        } catch {
            return nil
        }
    }
}

// MARK: - 错误

public enum MyTagError: LocalizedError, Sendable {
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .serverError(let msg): return msg
        }
    }
}
