import Foundation
import EhModels
import SwiftSoup

public enum HomeParser {
    // Parse rendered text, not exact tag/newline placement. The cost is optional:
    // a missing reset button must not make an otherwise valid quota unreadable.
    private static let quotaRegex = try! NSRegularExpression(
        pattern: #"You are currently at\s*([\d,\s]+?)\s*towards\s+[^.]*?limit of\s*([\d,\s]+)"#,
        options: .caseInsensitive
    )
    private static let costRegex = try! NSRegularExpression(
        pattern: #"(?:reset your image quota by spending|Reset Cost:)\s*([\d,\s]+)\s*GP"#,
        options: .caseInsensitive
    )

    /// Compatibility entry point for callers that explicitly accept no data.
    public static func parse(_ body: String) -> HomeDetail {
        (try? parseQuota(body)) ?? HomeDetail()
    }

    public static func parseQuota(_ body: String) throws -> HomeDetail {
        let doc = try SwiftSoup.parse(body)
        let text = try doc.text()
        let lower = text.lowercased()
        let hasPasswordField = !(try doc.select("input[type=password]")).isEmpty()
        if lower.contains("requires you to log on") || lower.contains("you must be logged in")
            || hasPasswordField {
            throw EhParseError.parseFailure("Image quota requires sign-in")
        }
        if body.contains("cf-chl-") || lower.contains("checking your browser") || lower.contains("verify you are human") {
            throw EhParseError.parseFailure("Image quota blocked by verification")
        }
        if lower.contains("you are currently using ip-based limits") {
            return HomeDetail(limitMode: lower.contains("no restrictions are currently in effect") ? .ipBasedUnrestricted : .ipBased)
        }
        let range = NSRange(text.startIndex..., in: text)
        var used: Int?
        var total: Int?
        if let match = quotaRegex.firstMatch(in: text, range: range) {
            used = number(match, group: 1, text: text)
            total = number(match, group: 2, text: text)
        }
        if used == nil || total == nil {
            for paragraph in try doc.select("p") {
                let wording = try paragraph.text().lowercased()
                guard wording.contains("currently"), wording.contains("limit") else { continue }
                let values = try paragraph.select("strong").compactMap {
                    Int(try $0.text().filter { $0.isASCII && $0.isNumber })
                }
                if values.count >= 2 { used = values[0]; total = values[1]; break }
            }
        }
        guard let used, let total, total > 0 else {
            // Login pages, challenges and changed markup are not a 0/0 quota.
            throw EhParseError.parseFailure("Image quota unavailable")
        }
        let cost = costRegex.firstMatch(in: text, range: range)
            .flatMap { number($0, group: 1, text: text) }
        return HomeDetail(currentUsed: used, totalLimit: total, resetCost: cost)
    }

    private static func number(_ match: NSTextCheckingResult, group: Int, text: String) -> Int? {
        guard let range = Range(match.range(at: group), in: text) else { return nil }
        let digits = text[range].filter { $0.isASCII && $0.isNumber }
        return Int(digits)
    }
}
