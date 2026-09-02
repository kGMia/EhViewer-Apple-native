import Foundation
import EhModels
import EhDatabase
import EhSpider
#if canImport(UIKit)
import UIKit
#endif

// MARK: - DownloadManager (对应 Android DownloadManager.java)
// 下载队列管理 Actor

public actor DownloadManager {
    public static let shared = DownloadManager()

    // MARK: - 状态常量

    public static let stateInvalid = -1
    public static let stateNone    = 0
    public static let stateWait    = 1
    public static let stateDownload = 2
    public static let stateFinish  = 3
    public static let stateFailed  = 4

    // MARK: - 属性

    private var downloadQueue: [DownloadTask] = []
    private var activeTask: DownloadTask?
    private let maxConcurrent = 1  // 同一时间只下载一个画廊
    private var isRunning = false
    /// 数据库加载只执行一次；所有会读写队列的公开入口先等待同一个任务，
    /// 避免冷启动时空队列覆盖恢复结果或新任务被迟到的加载覆盖。
    private var initialLoadTask: Task<[DownloadRecord], Never>?
    private var hasLoadedInitialQueue = false

    /// 下载监听器（用于通知集成）
    public weak var listener: DownloadListener?

    /// 下载目录
    public nonisolated var downloadDirectory: URL {
        if let custom = DownloadDirectoryResolver.shared.resolve() {
            return custom
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("download")
    }

    /// 保存由系统目录选择器授予的持久访问权限。新目录只影响之后的下载；
    /// 既有文件不会被隐式移动，避免跨卷移动失败或造成不可逆的数据改写。
    public nonisolated static func setDownloadDirectory(_ url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        #if os(macOS)
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        let bookmark = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
        UserDefaults.standard.set(bookmark, forKey: DownloadDirectoryResolver.bookmarkKey)
        UserDefaults.standard.set(url.path, forKey: "downloadPath")
        DownloadDirectoryResolver.shared.invalidate()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public nonisolated static func resetDownloadDirectory() {
        UserDefaults.standard.removeObject(forKey: DownloadDirectoryResolver.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: "downloadPath")
        DownloadDirectoryResolver.shared.invalidate()
    }

    private init() {
        initialLoadTask = Task.detached(priority: .userInitiated) {
            do {
                return try EhDatabase.shared.getAllDownloads()
            } catch {
                print("Failed to load downloads from database: \(error)")
                return []
            }
        }

        // 确保下载目录存在
        var dir = downloadDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // iOS/iPadOS: 排除 iCloud 备份
        #if os(iOS)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? dir.setResourceValues(resourceValues)
        #endif

    }

    private func ensureInitialQueueLoaded() async {
        guard !hasLoadedInitialQueue else { return }
        guard let initialLoadTask else {
            hasLoadedInitialQueue = true
            return
        }

        let records = await initialLoadTask.value
        // Actor 在 await 期间可重入；只允许最先恢复的调用写入一次。
        guard !hasLoadedInitialQueue else { return }
        downloadQueue = records.map { record in
            // 上次进程若在下载中退出，内存中的 Spider 已不存在；恢复为等待
            // 状态，让后台恢复或用户操作可以安全地重新建立任务。
            let restoredState = DownloadTaskLifecycle.recoveredState(from: record.state)
            return DownloadTask(
                gallery: record.galleryInfo,
                label: record.label,
                state: restoredState
            )
        }
        for record in records where record.state == Self.stateDownload {
            try? EhDatabase.shared.updateDownloadState(gid: record.gid, state: Self.stateWait)
        }
        hasLoadedInitialQueue = true
        self.initialLoadTask = nil
    }

    // MARK: - 公共接口

    /// 添加下载任务 (Fix A-1: 已有 failed/none 状态时自动恢复而非静默忽略)
    public func startDownload(gallery: GalleryInfo, label: String? = nil) async {
        await ensureInitialQueueLoaded()
        // 检查是否已在队列中
        if let existingIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gallery.gid }) {
            let existingState = downloadQueue[existingIndex].state
            if DownloadTaskLifecycle.canResume(from: existingState) {
                // 已暂停或已失败 → 重置为等待并恢复
                downloadQueue[existingIndex].state = Self.stateWait
                try? EhDatabase.shared.updateDownloadState(gid: gallery.gid, state: Self.stateWait)
                if !isRunning { processQueue() }
            }
            // stateWait / stateDownload / stateFinish → 不重复操作
            return
        }

        let task = DownloadTask(gallery: gallery, label: label)
        downloadQueue.append(task)

        // 持久化到数据库
        let record = gallery.downloadRecord(state: Self.stateWait, label: label)
        try? EhDatabase.shared.insertDownload(record)

        // 启动队列处理
        if !isRunning {
            processQueue()
        }
    }

    /// 暂停下载
    public func pauseDownload(gid: Int64) async {
        await ensureInitialQueueLoaded()
        if activeTask?.gallery.gid == gid {
            let title = activeTask?.gallery.bestTitle ?? ""
            if let spider = activeTask?.spider {
                Task { await spider.cancelAll() }
            }
            activeTask?.state = Self.stateNone
            activeTask = nil
            await listener?.onDownloadPause(gid: gid, title: title)
            processQueue()
        }
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].state = Self.stateNone
            try? EhDatabase.shared.updateDownloadState(gid: gid, state: Self.stateNone)
        }
    }

    /// 暂停所有下载（磁盘满时紧急调用）
    public func pauseAllDownloads() async {
        await ensureInitialQueueLoaded()
        let pausedGID = activeTask?.gallery.gid
        let pausedTitle = activeTask?.gallery.bestTitle
        // 取消当前活跃任务
        if let spider = activeTask?.spider {
            Task { await spider.cancelAll() }
        }
        activeTask = nil

        if let pausedGID {
            await listener?.onDownloadPause(gid: pausedGID, title: pausedTitle ?? "")
        }

        // 暂停队列中所有等待/下载中的任务
        for i in downloadQueue.indices {
            if downloadQueue[i].state == Self.stateWait || downloadQueue[i].state == Self.stateDownload {
                downloadQueue[i].state = Self.stateNone
                try? EhDatabase.shared.updateDownloadState(gid: downloadQueue[i].gallery.gid, state: Self.stateNone)
            }
        }
        print("[DownloadManager] ⚠️ 所有下载已暂停（磁盘空间不足）")
    }

    /// 恢复下载
    public func resumeDownload(gid: Int64) async {
        await ensureInitialQueueLoaded()
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].state = Self.stateWait
            try? EhDatabase.shared.updateDownloadState(gid: gid, state: Self.stateWait)
            if !isRunning {
                processQueue()
            }
        }
    }

    /// 删除下载 (可选删除文件)
    public func deleteDownload(gid: Int64, deleteFiles: Bool = false) async {
        await ensureInitialQueueLoaded()
        // 先获取 gallery 信息 (必须在 removeAll 之前)
        let task = downloadQueue.first(where: { $0.gallery.gid == gid })
        let title = task?.gallery.bestTitle
        let pages = task?.gallery.pages ?? 0

        if activeTask?.gallery.gid == gid {
            if let spider = activeTask?.spider {
                Task { await spider.cancelAll() }
            }
            activeTask = nil
            await listener?.onDownloadPause(gid: gid, title: title ?? "")
        }

        downloadQueue.removeAll { $0.gallery.gid == gid }
        try? EhDatabase.shared.deleteDownload(gid: gid)

        if deleteFiles {
            // 清除 SpiderDen 阅读缓存
            if pages > 0 {
                SpiderDen.clearCache(forGid: gid, pages: pages)
            }

            if let title = title, !title.isEmpty {
                // 精确匹配: 使用实际标题
                let dir = galleryDirectory(gid: gid, title: title)
                try? FileManager.default.removeItem(at: dir)
            } else {
                // 回退: 枚举下载目录中匹配 "gid-*" 前缀的目录
                let prefix = "\(gid)-"
                if let contents = try? FileManager.default.contentsOfDirectory(
                    at: downloadDirectory, includingPropertiesForKeys: nil) {
                    for item in contents where item.lastPathComponent.hasPrefix(prefix) {
                        try? FileManager.default.removeItem(at: item)
                    }
                }
            }
        }

        processQueue()
    }

    /// 获取所有下载任务
    public func getAllTasks() async -> [DownloadTask] {
        await ensureInitialQueueLoaded()
        return downloadQueue
    }

    /// 获取任务状态
    public func getTaskState(gid: Int64) async -> Int {
        await ensureInitialQueueLoaded()
        if activeTask?.gallery.gid == gid {
            return activeTask?.state ?? Self.stateNone
        }
        return downloadQueue.first(where: { $0.gallery.gid == gid })?.state ?? Self.stateInvalid
    }

    /// 更改下载标签 (对齐 Android DownloadManager.changeLabel)
    public func changeLabel(gids: [Int64], label: String?) async {
        await ensureInitialQueueLoaded()
        for gid in gids {
            if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
                downloadQueue[index].label = label
                // 同步到数据库
                if var record = try? EhDatabase.shared.getDownload(gid: gid) {
                    record.label = label
                    try? EhDatabase.shared.updateDownload(record)
                }
            }
        }
    }

    /// 更新下载进度 (由 SpiderInfoUpdater 调用，同步到队列以便 UI 读取)
    public func updateDownloadedPages(gid: Int64, count: Int) {
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[index].downloadedPages = count
        }
    }

    /// 设置下载监听器
    public func setListener(_ listener: DownloadListener?) {
        self.listener = listener
    }

    // MARK: - 后台任务支持

    /// 暂停当前活跃下载 (用于后台任务过期时, 保留 stateWait 以便恢复)
    public func pauseActiveIfNeeded() {
        guard let task = activeTask else { return }
        if let spider = task.spider {
            Task { await spider.cancelAll() }
        }
        if let index = downloadQueue.firstIndex(where: { $0.gallery.gid == task.gallery.gid }) {
            downloadQueue[index].state = Self.stateWait
            try? EhDatabase.shared.updateDownloadState(gid: task.gallery.gid, state: Self.stateWait)
        }
        activeTask = nil
        isRunning = false
        Task { await listener?.onDownloadPause(gid: task.gallery.gid, title: task.gallery.bestTitle) }
    }

    /// 恢复队列处理 (用于 BGProcessingTask 唤醒时)
    public func resumeAllWaiting() async {
        await ensureInitialQueueLoaded()
        guard !isRunning else { return }
        if downloadQueue.contains(where: { $0.state == Self.stateWait }) {
            processQueue()
        }
    }

    // MARK: - 队列处理

    private func processQueue() {
        guard activeTask == nil else { return }

        // 找到下一个等待中的任务
        guard let nextIndex = downloadQueue.firstIndex(where: { $0.state == Self.stateWait }) else {
            isRunning = false
            return
        }

        isRunning = true
        downloadQueue[nextIndex].state = Self.stateDownload
        activeTask = downloadQueue[nextIndex]

        let gid = downloadQueue[nextIndex].gallery.gid
        Task { await executeDownload(gid: gid) }
    }

    private func executeDownload(gid: Int64) async {
        guard let initialIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) else {
            return
        }

        // iOS: 申请后台执行时间, 防止进入后台后 ~30 秒被系统杀死
        #if canImport(UIKit)
        let bgTaskId = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "EhGalleryDownload") {
                Task { await DownloadManager.shared.pauseActiveIfNeeded() }
            }
        }
        #endif

        let gallery = downloadQueue[initialIndex].gallery
        let dir = galleryDirectory(gid: gallery.gid, title: gallery.bestTitle)

        // 通知监听器下载开始
        await listener?.onDownloadStart(gid: gallery.gid, title: gallery.bestTitle)

        // 尝试从 .ehviewer 文件读取已有的 SpiderInfo
        var spiderInfo: SpiderInfo
        if let existing = SpiderInfoFile.read(from: dir) {
            spiderInfo = existing
        } else {
            spiderInfo = SpiderInfo(
                startPage: 0,
                gid: gallery.gid,
                token: gallery.token,
                pages: gallery.pages
            )
            // 保存初始 .ehviewer 文件
            try? SpiderInfoFile.write(spiderInfo, to: dir)
        }

        // 创建 SpiderQueen
        let spider = SpiderQueen(galleryInfo: gallery, spiderInfo: spiderInfo, mode: .download)
        if let currentIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) {
            downloadQueue[currentIndex].spider = spider
        }
        if activeTask?.gallery.gid == gid {
            activeTask?.spider = spider
        }

        // 设置代理以便更新 .ehviewer 文件和进度通知
        let updater = SpiderInfoUpdater(
            directory: dir,
            gid: gallery.gid,
            title: gallery.bestTitle,
            total: gallery.pages,
            listener: listener
        )
        await spider.setDelegate(updater)

        // 开始下载所有页面 (现在 startDownload() 是真正的 async，会等待全部页面完成)
        await spider.startDownload()

        // 下载完成后更新 .ehviewer 文件
        let finalInfo = await spider.getSpiderInfo()
        try? SpiderInfoFile.write(finalInfo, to: dir)

        // 统计下载结果 (对齐 Android DownloadManager.onFinished)
        var finishedCount = 0
        var failedCount = 0
        for i in 0..<gallery.pages {
            let state = await spider.getPageState(i)
            if state == SpiderQueen.stateFinish {
                finishedCount += 1
            } else if state == SpiderQueen.stateFailed {
                failedCount += 1
            }
        }

        // 下载期间任务可能被暂停、删除，或队列顺序发生变化。按 gid
        // 重新定位，并且只允许仍处于下载状态的任务提交最终结果。
        guard let finalIndex = downloadQueue.firstIndex(where: { $0.gallery.gid == gid }) else {
            if activeTask?.gallery.gid == gid { activeTask = nil }
            processQueue()
            return
        }
        guard downloadQueue[finalIndex].state == Self.stateDownload else {
            if activeTask?.gallery.gid == gid { activeTask = nil }
            processQueue()
            return
        }

        // 下载完成
        let completionState = DownloadTaskLifecycle.completionState(
            finishedPages: finishedCount,
            totalPages: gallery.pages
        )
        let success = completionState == Self.stateFinish
        downloadQueue[finalIndex].state = completionState
        downloadQueue[finalIndex].downloadedPages = finishedCount
        try? EhDatabase.shared.updateDownloadState(gid: gallery.gid, state: downloadQueue[finalIndex].state)

        // 通知监听器下载完成
        await listener?.onDownloadFinish(gid: gallery.gid, title: gallery.bestTitle, success: success)

        // iOS: 释放后台执行时间
        #if canImport(UIKit)
        await MainActor.run {
            UIApplication.shared.endBackgroundTask(bgTaskId)
        }
        #endif

        if activeTask?.gallery.gid == gid { activeTask = nil }
        processQueue()
    }

    // MARK: - 文件管理

    // MARK: - 路径统一 (Fix D-1, A-3: 全局唯一的目录命名算法)

    /// 文件名清理 (移除非法字符) — 公开静态方法，保证所有组件使用同一逻辑
    public nonisolated static func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = name.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = sanitized.prefix(128)
        return String(trimmed).trimmingCharacters(in: .whitespaces)
    }

    /// 画廊目录名 — 唯一真相源 (所有路径引用必须通过此方法)
    /// 格式: `{gid}-{sanitizeFilename(title).prefix(128)}`
    public nonisolated static func galleryDirectoryName(gid: Int64, title: String) -> String {
        let sanitized = sanitizeFilename(title)
        return "\(gid)-\(sanitized)"
    }

    /// 画廊下载目录 (对应 Android: gid-sanitized_title)
    public nonisolated func galleryDirectory(gid: Int64, title: String) -> URL {
        let dirName = Self.galleryDirectoryName(gid: gid, title: title)
        return downloadDirectory.appendingPathComponent(dirName)
    }

    /// 图片文件名 (对应 Android: String.format("%08d%s", index+1, ext))
    public nonisolated func imageFilename(index: Int, ext: String = ".jpg") -> String {
        String(format: "%08d%@", index + 1, ext)
    }

    // MARK: - 下载状态真实检查 (Fix D-2, B-1)

    /// 检查画廊是否已完整下载 — 同时验证数据库状态 AND 磁盘文件存在
    public func isGalleryFullyDownloaded(gid: Int64) async -> Bool {
        await ensureInitialQueueLoaded()
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }),
              task.state == Self.stateFinish else { return false }
        let dir = galleryDirectory(gid: gid, title: task.gallery.bestTitle)
        return FileManager.default.fileExists(atPath: dir.path)
    }

    /// 获取已下载画廊的目录路径 (由 ReaderViewModel 调用，替代硬编码路径)
    public func getDownloadedGalleryDirectory(gid: Int64) async -> URL? {
        await ensureInitialQueueLoaded()
        guard let task = downloadQueue.first(where: { $0.gallery.gid == gid }) else { return nil }
        return galleryDirectory(gid: gid, title: task.gallery.bestTitle)
    }
}

/// URL bookmark 解析与 security-scope 生命周期集中在一个加锁对象中。
/// `downloadDirectory` 是 nonisolated 热路径，不能依赖 actor hop。
private final class DownloadDirectoryResolver: @unchecked Sendable {
    static let shared = DownloadDirectoryResolver()
    static let bookmarkKey = "downloadDirectoryBookmark"

    private let lock = NSLock()
    private var cachedBookmark: Data?
    private var cachedURL: URL?
    private var holdsSecurityScope = false
    private var hasResolved = false

    func resolve() -> URL? {
        let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey)
        lock.lock()
        defer { lock.unlock() }

        if hasResolved, bookmark == cachedBookmark {
            return cachedURL
        }
        releaseCachedScope()
        cachedBookmark = bookmark
        hasResolved = true

        guard let bookmark else {
            // 兼容旧版 macOS 设置；下一次选择目录后会自动迁移到 bookmark。
            if let path = UserDefaults.standard.string(forKey: "downloadPath"), !path.isEmpty {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                cachedURL = url
                return url
            }
            return nil
        }

        do {
            var isStale = false
            #if os(macOS)
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #else
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #endif
            holdsSecurityScope = url.startAccessingSecurityScopedResource()
            cachedURL = url
            return url
        } catch {
            cachedURL = nil
            return nil
        }
    }

    func invalidate() {
        lock.lock()
        releaseCachedScope()
        cachedBookmark = nil
        hasResolved = false
        lock.unlock()
    }

    private func releaseCachedScope() {
        if holdsSecurityScope, let cachedURL {
            cachedURL.stopAccessingSecurityScopedResource()
        }
        holdsSecurityScope = false
        cachedURL = nil
    }
}

/// 下载任务生命周期中的纯状态转换。
/// 与文件、数据库和网络无关，因此可以稳定地覆盖异常退出、失败重试和
/// 完成判定，而不需要在单元测试中真正启动 Spider。
public enum DownloadTaskLifecycle: Sendable {
    /// 进程退出后不存在仍可继续工作的 Spider；下载中状态必须恢复为等待。
    public static func recoveredState(from persistedState: Int) -> Int {
        persistedState == DownloadManager.stateDownload
            ? DownloadManager.stateWait
            : persistedState
    }

    /// 用户开始同一画廊时，仅暂停或失败任务可以被恢复；等待、下载中和
    /// 已完成任务保持幂等，避免重复排队。
    public static func canResume(from state: Int) -> Bool {
        state == DownloadManager.stateNone || state == DownloadManager.stateFailed
    }

    public static func completionState(finishedPages: Int, totalPages: Int) -> Int {
        guard totalPages > 0, finishedPages == totalPages else {
            return DownloadManager.stateFailed
        }
        return DownloadManager.stateFinish
    }
}

// MARK: - DownloadTask

public struct DownloadTask: Sendable {
    public let gallery: GalleryInfo
    public var label: String?
    public var state: Int
    public var downloadedPages: Int
    public var spider: SpiderQueen?

    public init(gallery: GalleryInfo, label: String? = nil, state: Int = DownloadManager.stateWait) {
        self.gallery = gallery
        self.label = label
        self.state = state
        self.downloadedPages = 0
    }
}

// MARK: - SpiderInfo 扩展 (简化构造)

extension SpiderInfo {
    init(startPage: Int, gid: Int64, token: String, pages: Int) {
        self.init()
        self.startPage = startPage
        self.gid = gid
        self.token = token
        self.pages = pages
    }
}

// MARK: - SpiderInfoUpdater (用于下载时更新 .ehviewer 文件)

actor SpiderInfoUpdater: SpiderDelegate {
    private let directory: URL
    private let gid: Int64
    private let title: String
    private let totalPages: Int
    private weak var listener: DownloadListener?

    private var downloadedCount = 0
    private var startTime: Date = Date()
    private var lastNotifyTime: Date = .distantPast
    private let notifyInterval: TimeInterval = 1.0 // 每秒最多通知一次

    init(directory: URL, gid: Int64, title: String, total: Int, listener: DownloadListener?) {
        self.directory = directory
        self.gid = gid
        self.title = title
        self.totalPages = total
        self.listener = listener
        self.startTime = Date()
    }

    func onPageLoaded(index: Int, imageUrl: String) async {
        downloadedCount += 1

        // 同步更新 DownloadManager 队列中的进度 (便于 UI 读取)
        await DownloadManager.shared.updateDownloadedPages(gid: gid, count: downloadedCount)

        // 计算速度 (字节/秒，这里简化为页数/秒 * 估计大小)
        let elapsed = Date().timeIntervalSince(startTime)
        let pagesPerSecond = elapsed > 0 ? Double(downloadedCount) / elapsed : 0
        let estimatedBytesPerPage: Int64 = 500_000 // 估计每页 500KB
        let speed = Int64(pagesPerSecond * Double(estimatedBytesPerPage))

        // 节流通知
        let now = Date()
        if now.timeIntervalSince(lastNotifyTime) >= notifyInterval {
            lastNotifyTime = now
            await listener?.onDownloadProgress(
                gid: gid,
                title: title,
                downloaded: downloadedCount,
                total: totalPages,
                speed: speed
            )
        }
    }

    func onPageFailed(index: Int, error: Error) async {
        print("[SpiderInfoUpdater] Page \(index) failed: \(error)")
    }

    func onImageLimitReached() async {
        print("[SpiderInfoUpdater] Image limit (509) reached")
        await listener?.on509Error()
    }

    func onDiskFull() async {
        print("[SpiderInfoUpdater] ⚠️ 磁盘空间不足，暂停所有下载")
        await DownloadManager.shared.pauseAllDownloads()
        await listener?.onDiskFull()
    }

    func onDownloadProgress(downloaded: Int, total: Int) async {
        downloadedCount = downloaded
    }
}

// MARK: - DownloadListener (下载事件监听器)

public protocol DownloadListener: AnyObject, Sendable {
    /// 下载开始
    func onDownloadStart(gid: Int64, title: String) async

    /// 下载进度更新
    func onDownloadProgress(gid: Int64, title: String, downloaded: Int, total: Int, speed: Int64) async

    /// 下载完成
    func onDownloadFinish(gid: Int64, title: String, success: Bool) async

    /// 下载被用户或系统暂停
    func onDownloadPause(gid: Int64, title: String) async

    /// 509错误
    func on509Error() async

    /// 磁盘空间不足
    func onDiskFull() async
}

public extension DownloadListener {
    func onDownloadPause(gid: Int64, title: String) async {}
}
