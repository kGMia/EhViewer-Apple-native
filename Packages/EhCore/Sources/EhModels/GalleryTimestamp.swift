import Foundation

/// E-Hentai 页面时间不包含时区标记，服务端按 UTC 输出。统一在这里解析，
/// 展示时再转换到系统当前的地区与时区，避免列表和评论使用不同规则。
public enum GalleryTimestamp {
    private static let serverParsers: [DateFormatter] = [
        "yyyy-MM-dd HH:mm",
        "dd MMMM yyyy, HH:mm",
        "d MMMM yyyy, HH:mm",
    ].map { format in
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private static func makeDisplayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = presentationLocale
        formatter.calendar = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    /// EhModels 不依赖设置模块，因此直接读取双方约定的持久化键。
    /// 未指定应用语言时保持系统地区与时区行为。
    private static var presentationLocale: Locale {
        switch UserDefaults.standard.string(forKey: "app_language") {
        case "zh-Hans": return Locale(identifier: "zh-Hans")
        case "zh-Hant-TW": return Locale(identifier: "zh-Hant-TW")
        case "en-US": return Locale(identifier: "en-US")
        default: return .autoupdatingCurrent
        }
    }

    public static func serverDate(from rawValue: String) -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let timestamp = Double(value), timestamp > 0 {
            // API 通常返回秒；同时兼容毫秒时间戳。
            let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
            return Date(timeIntervalSince1970: seconds)
        }

        for parser in serverParsers {
            if let date = parser.date(from: value) { return date }
        }
        return nil
    }

    public static func localizedString(fromServerText rawValue: String) -> String {
        guard let date = serverDate(from: rawValue) else { return rawValue }
        return localizedString(from: date)
    }

    public static func localizedString(from date: Date) -> String {
        makeDisplayFormatter().string(from: date)
    }
}
