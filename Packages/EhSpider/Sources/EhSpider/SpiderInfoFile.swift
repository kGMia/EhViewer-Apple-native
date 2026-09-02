import Foundation
import EhModels

// MARK: - SpiderInfoFile

/// 处理 .ehviewer 文件的读写
public struct SpiderInfoFile: Sendable {
    /// .ehviewer 文件名
    public static let filename = ".ehviewer"

    // MARK: - 读取

    /// 从画廊目录读取 SpiderInfo
    /// - Parameter directory: 画廊下载目录
    /// - Returns: 解析后的 SpiderInfo，失败返回 nil
    public static func read(from directory: URL) -> SpiderInfo? {
        let fileURL = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            return SpiderInfo.deserialize(from: content)
        } catch {
            print("[SpiderInfoFile] Failed to read: \(error)")
            return nil
        }
    }

    /// 从 URL 读取 SpiderInfo
    /// - Parameter fileURL: .ehviewer 文件路径
    /// - Returns: 解析后的 SpiderInfo，失败返回 nil
    public static func read(fileURL: URL) -> SpiderInfo? {
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            return SpiderInfo.deserialize(from: content)
        } catch {
            print("[SpiderInfoFile] Failed to read: \(error)")
            return nil
        }
    }

    // MARK: - 写入

    /// 将 SpiderInfo 写入画廊目录
    /// - Parameters:
    ///   - info: 要保存的 SpiderInfo
    ///   - directory: 画廊下载目录
    /// - Throws: 文件写入错误
    public static func write(_ info: SpiderInfo, to directory: URL) throws {
        // 确保目录存在
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent(filename)
        let content = info.serialize()
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - 删除

    /// 删除画廊目录中的 .ehviewer 文件
    /// - Parameter directory: 画廊下载目录
    public static func delete(from directory: URL) {
        let fileURL = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 扫描离线画廊

    /// 扫描下载目录，查找所有可用的离线画廊
    /// - Parameter downloadDirectory: 下载根目录
    /// - Returns: (画廊目录 URL, SpiderInfo) 元组数组
    public static func scanOfflineGalleries(in downloadDirectory: URL) -> [(URL, SpiderInfo)] {
        var result: [(URL, SpiderInfo)] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: downloadDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return result
        }

        for item in contents {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            if let info = read(from: item) {
                result.append((item, info))
            }
        }

        return result
    }

    // MARK: - 图片文件检测

    /// 检查画廊目录中已下载的图片页面
    /// - Parameters:
    ///   - directory: 画廊目录
    ///   - totalPages: 总页数
    /// - Returns: 已下载的页面索引集合
    public static func getDownloadedPages(in directory: URL, totalPages: Int) -> Set<Int> {
        var downloaded = Set<Int>()

        for pageIndex in 0..<totalPages {
            // 尝试常见图片扩展名
            for ext in [".jpg", ".png", ".gif", ".webp"] {
                let filename = String(format: "%08d%@", pageIndex + 1, ext)
                let fileURL = directory.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    downloaded.insert(pageIndex)
                    break
                }
            }
        }

        return downloaded
    }

    /// 获取页面的本地图片 URL (如果存在)
    /// - Parameters:
    ///   - directory: 画廊目录
    ///   - pageIndex: 页面索引 (0-based)
    /// - Returns: 本地图片 URL，不存在返回 nil
    public static func getLocalImageURL(in directory: URL, pageIndex: Int) -> URL? {
        for ext in [".jpg", ".png", ".gif", ".webp"] {
            let filename = String(format: "%08d%@", pageIndex + 1, ext)
            let fileURL = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
        }
        return nil
    }
}
