//
//  ReaderViewModel.swift
//  ehviewer apple
//
//  阅读器 ViewModel — 管理页面加载、双页逻辑、预加载策略、内存优化
//  从 ImageReaderView.swift 分离，对齐 Android GalleryActivity ViewModel
//

import SwiftUI
import EhModels
import EhSpider
import EhSettings
import EhDownload
import CoreImage
import Network

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import ImageIO

// MARK: - Reading Direction

enum ReadingDirection: Int, CaseIterable {
    case leftToRight = 0
    case rightToLeft = 1
    case topToBottom = 2

    var label: String {
        switch self {
        case .leftToRight: return AppLocalization.localized("从左到右")
        case .rightToLeft: return AppLocalization.localized("从右到左")
        case .topToBottom: return AppLocalization.localized("从上到下")
        }
    }

    var icon: String {
        switch self {
        case .leftToRight: return "arrow.right"
        case .rightToLeft: return "arrow.left"
        case .topToBottom: return "arrow.down"
        }
    }
}

enum ReaderPageDisplayMode: Int, CaseIterable {
    case single = 0
    case double = 1

    var label: String {
        switch self {
        case .single: return AppLocalization.localized("单页")
        case .double: return AppLocalization.localized("双页")
        }
    }
}

// MARK: - Scale Mode

enum ScaleMode: Int, CaseIterable {
    case origin = 0
    case fitWidth = 1
    case fitHeight = 2
    case fit = 3
    case fixed = 4

    var label: String {
        switch self {
        case .origin: return AppLocalization.localized("原始大小")
        case .fitWidth: return AppLocalization.localized("适应宽度")
        case .fitHeight: return AppLocalization.localized("适应高度")
        case .fit: return AppLocalization.localized("适应屏幕")
        case .fixed: return AppLocalization.localized("固定缩放")
        }
    }
}

// MARK: - Start Position

enum StartPosition: Int, CaseIterable {
    case topLeft = 0
    case topRight = 1
    case bottomLeft = 2
    case bottomRight = 3
    case center = 4

    var label: String {
        switch self {
        case .topLeft: return AppLocalization.localized("左上")
        case .topRight: return AppLocalization.localized("右上")
        case .bottomLeft: return AppLocalization.localized("左下")
        case .bottomRight: return AppLocalization.localized("右下")
        case .center: return AppLocalization.localized("居中")
        }
    }
}

// MARK: - Page Spread (双页模式数据模型)

/// 一个"展页"— 单页或双页并排
struct PageSpread: Identifiable, Equatable {
    let id: Int
    let primaryPage: Int
    let secondaryPage: Int?

    var pages: [Int] {
        if let s = secondaryPage { return [primaryPage, s] } else { return [primaryPage] }
    }

    var isSingle: Bool { secondaryPage == nil }
}

/// 生成稳定、有界且按距离排序的预取计划。当前页由前台加载，不会再次
/// 出现在计划中；较近的后一页和前一页优先于更远页面。
enum ReaderPrefetchPlanner {
    static func pages(
        around currentPage: Int,
        totalPages: Int,
        ahead: Int,
        behind: Int = 1
    ) -> [Int] {
        guard totalPages > 0, currentPage >= 0, currentPage < totalPages else { return [] }
        let forwardCount = max(0, ahead)
        let backwardCount = max(0, behind)
        let maxDistance = max(forwardCount, backwardCount)
        guard maxDistance > 0 else { return [] }

        var result: [Int] = []
        result.reserveCapacity(forwardCount + backwardCount)
        for distance in 1...maxDistance {
            let next = currentPage + distance
            if distance <= forwardCount, next < totalPages {
                result.append(next)
            }
            let previous = currentPage - distance
            if distance <= backwardCount, previous >= 0 {
                result.append(previous)
            }
        }
        return result
    }

    static func retainedPages(
        around currentPage: Int,
        totalPages: Int,
        radius: Int
    ) -> Set<Int> {
        guard totalPages > 0, currentPage >= 0, currentPage < totalPages else { return [] }
        let distance = max(0, radius)
        let lowerBound = max(0, currentPage - distance)
        let upperBound = min(totalPages - 1, currentPage + distance)
        return Set(lowerBound...upperBound)
    }
}

private struct SpreadImageCacheKey: Hashable {
    let spreadID: Int
    let direction: Int
}

// MARK: - ReaderViewModel

@MainActor
@Observable
class ReaderViewModel {

    // MARK: - Page State

    var currentPage: Int = 0
    var totalPages: Int = 0
    var gid: Int64 = 0
    var token: String = ""
    var isDownloaded: Bool = false
    /// Perf P0-1: scrollPosition 绑定用 Optional Int (ScrollView 要求 Binding<Int?>)
    var lazyCurrentPage: Int? = 0
    /// Perf P0-2: 垂直滚动模式页码追踪 (scrollPosition 绑定)
    var verticalScrollPage: Int? = 0

    // MARK: - Double Page

    /// 是否启用双页模式 (screenWidth > 600pt)
    var isDoublePageEnabled: Bool = false
    /// 双页模式下是否让封面（第 1 页）独占一个跨页，默认开启。
    var firstPageStandalone: Bool = true
    /// 页面展页列表 (单页模式下每个 spread 只有一页)
    var spreads: [PageSpread] = []
    /// 当前展页索引 (Perf P0-1: Optional for scrollPosition binding)
    var currentSpreadIndex: Int? = 0

    // MARK: - Image Loading

    var imageURLs: [Int: String] = [:]
    var originalImageURLs: [Int: String] = [:]
    var pagesUsingOriginalImage: Set<Int> = []
    /// 已解码的图片 (Observable 层，触发 SwiftUI 刷新)
    var cachedImages: [Int: PlatformImage] = [:]
    var errorPages: Set<Int> = []
    var errorMessages: [Int: String] = [:]
    var retryingPages: [Int: Int] = [:]
    var downloadProgress: [Int: Double] = [:]
    var retryGeneration: [Int: Int] = [:]

    // MARK: - Visual

    /// 每页的主色调 (用于模糊背景填充)
    var dominantColors: [Int: Color] = [:]
    /// 预览图只用于首帧的快速估色；完整页解码后会覆盖它。
    private var previewSeededDominantPages: Set<Int> = []
    private var fullColorPagesInFlight: Set<Int> = []
    /// 双页合成图只在源图片发生变化时生成一次，避免 SwiftUI body 刷新时
    /// 在主线程反复执行大图拼接。
    private var spreadImageCache: [SpreadImageCacheKey: PlatformImage] = [:]

    // MARK: - Private

    private var pTokens: [Int: String] = [:]
    private var showKeys: [Int: String] = [:]
    private var loadingPages: Set<Int> = []
    private var downloadDir: URL?
    private var imageLoadTasks: [Int: InFlightImageLoad] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var lastPrefetchPage: Int?
    private var prefetchDirection = 1
    private let networkMonitor = NWPathMonitor()
    private var networkIsExpensive = false
    private var networkIsConstrained = false
    #if os(iOS)
    /// NotificationCenter invokes the handler on the main queue; unsafe
    /// nonisolated storage is limited to deinit so Swift 6 can unregister it.
    @ObservationIgnored
    nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?
    #endif
    #if os(macOS)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

    private struct InFlightImageLoad {
        let id: UUID
        let task: Task<ImageLoadOutcome, Never>
    }

    private enum ImageLoadOutcome: @unchecked Sendable {
        case image(PlatformImage)
        case invalidData
        case cancelled
        case failure(String)
    }

    init() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.networkIsExpensive = path.isExpensive
                self?.networkIsConstrained = path.isConstrained
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "Reader.NetworkPath", qos: .utility))

        #if os(iOS)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMemoryPressure() }
        }
        #endif

        #if os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure()
            }
        }
        source.resume()
        memoryPressureSource = source
        #endif
    }

    deinit {
        networkMonitor.cancel()
        #if os(iOS)
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        #endif
    }

    /// NSCache composite key: "gid:pageIndex" — 防止切换画廊时命中旧画廊的图片缓存
    private func cacheKey(for page: Int) -> NSString {
        "\(gid):\(page)" as NSString
    }

    /// Returns a decoded page from either the observable working set or the
    /// shared memory cache. Pages evicted from `cachedImages` remain immediately
    /// displayable when the reader moves back to them, avoiding a false loading
    /// state while `downloadImageData` promotes the same object again.
    func image(at page: Int) -> PlatformImage? {
        cachedImages[page] ?? Self.imageCache.object(forKey: cacheKey(for: page))
    }

    /// 最大解码像素尺寸 (屏幕长边 × 3 倍，限制超大图解码内存)
    /// 15000×20000 的长条漫会被降采样到合理尺寸，避免 OOM
    private static let maxDecodePixelSize: CGFloat = {
        #if os(iOS)
        // iOS 26+ 废弃 UIScreen.main，通过 connectedScenes 获取屏幕信息
        let screenMax: CGFloat
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            let screen = scene.screen
            screenMax = max(screen.bounds.width, screen.bounds.height) * screen.scale
        } else {
            // App 未完全初始化时的保守默认值 (iPhone Pro Max @3x)
            screenMax = 2868
        }
        #else
        let screenMax = max(NSScreen.main?.frame.width ?? 2560, NSScreen.main?.frame.height ?? 1440) * (NSScreen.main?.backingScaleFactor ?? 2)
        #endif
        return max(screenMax * 3, 4096) // 至少 4096px，最大约 3× 屏幕
    }()

    /// NSCache 后端: 根据设备物理内存动态调整
    /// 审计修复 M-1: iPhone SE (3GB) → 80MB; iPhone 15 Pro (6GB) → 200MB; Mac → 400MB
    /// cost 使用解码后像素字节数而非压缩数据大小
    private static let imageCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        let physicalMemory = ProcessInfo.processInfo.physicalMemory // bytes
        let memoryGB = Double(physicalMemory) / (1024 * 1024 * 1024)
        
        let cacheLimitMB: Int
        if memoryGB < 4 {
            cacheLimitMB = 80   // iPhone SE, 低端设备
        } else if memoryGB < 6 {
            cacheLimitMB = 150  // iPhone 15 等中端
        } else if memoryGB < 8 {
            cacheLimitMB = 250  // iPhone 15 Pro, iPad
        } else {
            cacheLimitMB = 400  // Mac, 高端 iPad
        }
        
        cache.totalCostLimit = cacheLimitMB * 1024 * 1024
        cache.countLimit = min(40, cacheLimitMB / 5) // 每张约 5MB 估算
        return cache
    }()

    /// 供设置页统一释放阅读器解码缓存。当前阅读页持有的可见图片仍会正常显示，
    /// 后续页面会按需重新从磁盘或网络加载。
    static func clearDecodedImageCache() {
        imageCache.removeAllObjects()
    }

    /// 降采样解码: 用 ImageIO 在解码阶段限制像素尺寸，而非先全量解码再缩放
    /// 一张 15000×20000 JPEG 全量解码 = 1.2GB; 降采样到 4096px 宽 ≈ 40MB
    nonisolated private static func downsampledImage(
        data: Data,
        maxPixelSize: CGFloat
    ) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false  // 不缓存原始数据
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }

        if CGImageSourceGetCount(source) > 1,
           let animated = decodeAnimatedPlatformImage(
               data: data,
               source: source,
               requestedMaxPixelSize: min(maxPixelSize, 1_200),
               maximumFrames: 48,
               pixelBudget: 16_000_000
           ) {
            return animated
        }

        // 获取原图尺寸
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            // 无法读取尺寸，退回普通解码但仍有 NSCache 保护
            return PlatformImage(data: data)
        }

        let maxDimension = max(pixelWidth, pixelHeight)

        // 如果图片在安全范围内，直接解码
        if maxDimension <= maxPixelSize {
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
                return PlatformImage(data: data)
            }
            #if os(iOS)
            return UIImage(cgImage: cgImage)
            #else
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            #endif
        }

        // 超大图: 降采样到 maxDecodePixelSize
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            return PlatformImage(data: data)
        }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    /// 计算解码后图片的实际像素内存占用 (bytes)
    nonisolated private static func decodedCost(of image: PlatformImage) -> Int {
        #if os(iOS)
        if let frames = image.images, !frames.isEmpty {
            return frames.reduce(into: 0) { cost, frame in
                if let cgImage = frame.cgImage {
                    cost += cgImage.bytesPerRow * cgImage.height
                }
            }
        }
        guard let cg = image.cgImage else { return 1024 * 1024 } // 1MB fallback
        return cg.bytesPerRow * cg.height
        #else
        // tiffRepresentation 会重新编码整张图片，并可能在主线程造成明显停顿。
        // 下载管线生成的 NSImage 已由 CGImage 支撑，直接读取像素布局即可。
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 1024 * 1024
        }
        return cg.bytesPerRow * cg.height
        #endif
    }

    /// 共享 URLSession (保持 cookies)
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    private static let pTokenUrlPattern = try! NSRegularExpression(
        pattern: #"/s/([0-9a-f]+)/(\d+)-(\d+)"#
    )

    private static let pagesPattern = try! NSRegularExpression(
        pattern: #"(\d+)\s*pages?"#, options: .caseInsensitive
    )
    private static let imgSrcPattern = try! NSRegularExpression(
        pattern: #"id="img"\s+src="([^"]+)""#
    )
    private static let showKeyPattern = try! NSRegularExpression(
        pattern: #"var showkey\s*=\s*"([^"]+)""#
    )

    private static let originalImagePattern = try! NSRegularExpression(
        pattern: #"<a[^>]+href="([^"]+)"[^>]*>\s*Download original"#,
        options: .caseInsensitive
    )

    // MARK: - Double Page Logic

    /// 根据屏幕尺寸更新双页模式 — 仅横屏 + 宽度 > 700pt 时启用
    /// 修复: iPad 竖屏不再触发双页模式
    func updateLayout(screenWidth: CGFloat, screenHeight: CGFloat) {
        let shouldDouble = screenWidth > screenHeight && screenWidth > 700
        guard shouldDouble != isDoublePageEnabled else { return }
        let anchoredPage = currentPage
        isDoublePageEnabled = shouldDouble
        computeSpreads()
        // 旋转会在单页 ID 与 spread ID 之间切换；用逻辑页一次性校准
        // 所有原生 scrollPosition，防止旧 spread 索引越界或反写首页。
        synchronizePagePosition(anchoredPage)
    }

    /// 计算 spreads 数组。可让封面(page 0)独占，或从第一页开始两两配对。
    func computeSpreads() {
        guard totalPages > 0 else { spreads = []; return }

        spreadImageCache.removeAll(keepingCapacity: true)

        if !isDoublePageEnabled {
            spreads = (0..<totalPages).map {
                PageSpread(id: $0, primaryPage: $0, secondaryPage: nil)
            }
            return
        }

        var result: [PageSpread] = []
        var i = 0
        var spreadIdx = 0
        if firstPageStandalone {
            result.append(PageSpread(id: spreadIdx, primaryPage: 0, secondaryPage: nil))
            i = 1
            spreadIdx += 1
        }
        while i < totalPages {
            if i + 1 < totalPages {
                result.append(PageSpread(id: spreadIdx, primaryPage: i, secondaryPage: i + 1))
                i += 2
            } else {
                result.append(PageSpread(id: spreadIdx, primaryPage: i, secondaryPage: nil))
                i += 1
            }
            spreadIdx += 1
        }
        spreads = result
    }

    /// 根据 currentPage 同步 currentSpreadIndex
    func syncSpreadIndex() {
        currentSpreadIndex = spreadIndex(for: currentPage)
    }

    /// 同步阅读器的逻辑页码与三个原生滚动位置。
    /// `ScrollView.scrollPosition` 若仍停留在 0，会在首帧布局时把首页
    /// 反写到 currentPage，造成进度正确而画面显示首页。
    func synchronizePagePosition(_ page: Int) {
        let target = min(max(0, page), max(0, totalPages - 1))
        currentPage = target
        lazyCurrentPage = target
        verticalScrollPage = target
        currentSpreadIndex = spreadIndex(for: target)
    }

    /// 查找某页所在的 spread 索引
    func spreadIndex(for page: Int) -> Int {
        spreads.firstIndex(where: { $0.pages.contains(page) }) ?? 0
    }

    /// 获取某 spread 的主页码
    func pageForSpread(_ idx: Int) -> Int {
        guard idx >= 0 && idx < spreads.count else { return 0 }
        return spreads[idx].primaryPage
    }

    // MARK: - Composite Image (双页合成)

    /// 将一个 spread 的两页合成为一张图片
    func spreadImage(at index: Int, direction: ReadingDirection) -> PlatformImage? {
        guard index >= 0 && index < spreads.count else { return nil }
        let spread = spreads[index]

        guard let primary = image(at: spread.primaryPage) else { return nil }
        guard let secPage = spread.secondaryPage,
              let secondary = image(at: secPage) else {
            return primary
        }

        let key = SpreadImageCacheKey(spreadID: spread.id, direction: direction.rawValue)
        _ = secondary // 两页均已就绪后才允许命中合成缓存。
        return spreadImageCache[key]
    }

    /// 在后台生成双页合成图。AppKit/UIKit 图片只在 MainActor 上提取 CGImage，
    /// 实际像素绘制由 Core Graphics 在 detached task 中完成。
    func prepareSpreadImage(at index: Int, direction: ReadingDirection) async {
        guard index >= 0 && index < spreads.count else { return }
        let spread = spreads[index]
        guard let secondaryPage = spread.secondaryPage,
              let primary = image(at: spread.primaryPage),
              let secondary = image(at: secondaryPage) else { return }

        let key = SpreadImageCacheKey(spreadID: spread.id, direction: direction.rawValue)
        guard spreadImageCache[key] == nil else { return }

        // RTL: 高页码在左 (漫画翻书序)
        let (left, right): (PlatformImage, PlatformImage)
        if direction == .rightToLeft {
            left = secondary
            right = primary
        } else {
            left = primary
            right = secondary
        }

        #if os(iOS)
        // `UIImage.animatedImage` itself does not always expose `cgImage`.
        // Spreads are intentionally composited from the first frame: animating two
        // independent pages inside one bitmap would multiply both memory and CPU use.
        guard let leftCG = (left.images?.first ?? left).cgImage,
              let rightCG = (right.images?.first ?? right).cgImage else { return }
        #else
        guard let leftCG = left.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rightCG = right.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        #endif

        let maxDimension = Self.maxDecodePixelSize
        let compositedCG = await Task.detached(priority: .userInitiated) {
            Self.compositeCGImages(left: leftCG, right: rightCG, maxDimension: maxDimension)
        }.value
        guard let compositedCG else { return }

        #if os(iOS)
        spreadImageCache[key] = UIImage(cgImage: compositedCG)
        #else
        spreadImageCache[key] = NSImage(
            cgImage: compositedCG,
            size: NSSize(width: compositedCG.width, height: compositedCG.height)
        )
        #endif
    }

    /// 双页合成只处理不可变 CGImage，可安全地在后台线程运行。
    nonisolated private static func compositeCGImages(
        left: CGImage,
        right: CGImage,
        maxDimension: CGFloat
    ) -> CGImage? {
        var maxH = CGFloat(max(left.height, right.height))
        var totalW = CGFloat(left.width + right.width)

        // 安全阀: 如果合成尺寸过大，按比例缩小
        let sourceMaxDimension = max(totalW, maxH)
        let scale: CGFloat = sourceMaxDimension > maxDimension
            ? maxDimension / sourceMaxDimension
            : 1.0

        if scale < 1.0 {
            totalW *= scale
            maxH *= scale
        }

        let outputWidth = max(1, Int(totalW.rounded(.up)))
        let outputHeight = max(1, Int(maxH.rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        let lw = CGFloat(left.width) * scale
        let lh = CGFloat(left.height) * scale
        let rw = CGFloat(right.width) * scale
        let rh = CGFloat(right.height) * scale
        let leftY = (maxH - lh) / 2
        let rightY = (maxH - rh) / 2
        context.draw(left, in: CGRect(x: 0, y: leftY, width: lw, height: lh))
        context.draw(right, in: CGRect(x: lw, y: rightY, width: rw, height: rh))
        return context.makeImage()
    }

    // MARK: - Dominant Color (模糊背景主色调提取)

    /// 使用详情页已经解码/缓存的预览图提前点亮阅读背景。
    /// 这里只读缓存，不会为氛围色额外发起网络请求。
    func seedDominantColor(from previewSet: PreviewSet, for page: Int) {
        guard dominantColors[page] == nil else { return }

        let descriptor: (url: URL, crop: CGRect?)?
        switch previewSet {
        case .normal(let previews):
            guard let preview = previews.first(where: { $0.position == page }),
                  let url = URL(string: preview.imageUrl) else { return }
            let crop: CGRect? = preview.clipWidth > 0 && preview.clipHeight > 0
                ? CGRect(
                    x: preview.offsetX,
                    y: preview.offsetY,
                    width: preview.clipWidth,
                    height: preview.clipHeight
                )
                : nil
            descriptor = (url, crop)
        case .large(let previews):
            guard let preview = previews.first(where: { $0.position == page }),
                  let url = URL(string: preview.imageUrl) else { return }
            descriptor = (url, nil)
        }

        guard let descriptor else { return }

        if let image = ThumbnailMemoryCache.shared.get(descriptor.url),
           let cgImage = Self.cgImage(from: image) {
            seedDominantColor(from: cgImage, crop: descriptor.crop, page: page)
            return
        }

        var request = URLRequest(url: descriptor.url, cachePolicy: .returnCacheDataDontLoad)
        request.setValue(
            AppSettings.shared.gallerySite == .exHentai
                ? "https://exhentai.org/"
                : "https://e-hentai.org/",
            forHTTPHeaderField: "Referer"
        )
        guard let data = URLCache.shared.cachedResponse(for: request)?.data else { return }
        let crop = descriptor.crop

        Task.detached(priority: .userInitiated) { [weak self] in
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let color = Self.computeDominantColor(
                    from: Self.croppedPreviewImage(cgImage, crop: crop)
                  ) else { return }
            await self?.applyPreviewDominantColor(color, page: page)
        }
    }

    private func seedDominantColor(from cgImage: CGImage, crop: CGRect?, page: Int) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let color = Self.computeDominantColor(
                from: Self.croppedPreviewImage(cgImage, crop: crop)
            ) else { return }
            await self?.applyPreviewDominantColor(color, page: page)
        }
    }

    private func applyPreviewDominantColor(_ color: Color, page: Int) {
        guard dominantColors[page] == nil else { return }
        dominantColors[page] = color
        previewSeededDominantPages.insert(page)
    }

    nonisolated private static func croppedPreviewImage(_ image: CGImage, crop: CGRect?) -> CGImage {
        guard let crop else { return image }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let integralCrop = crop.integral.intersection(bounds)
        guard !integralCrop.isEmpty, let cropped = image.cropping(to: integralCrop) else {
            return image
        }
        return cropped
    }

    nonisolated private static func cgImage(from image: PlatformImage) -> CGImage? {
        #if os(iOS)
        (image.images?.first ?? image).cgImage
        #else
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /// 提取图片平均色用于模糊氛围背景 — CIFilter 在后台线程执行
    func extractDominantColor(for page: Int) {
        guard (dominantColors[page] == nil || previewSeededDominantPages.contains(page)),
              !fullColorPagesInFlight.contains(page),
              let image = cachedImages[page] else { return }

        #if os(iOS)
        guard let cgImage = (image.images?.first ?? image).cgImage else { return }
        #else
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        #endif

        fullColorPagesInFlight.insert(page)
        Task.detached(priority: .utility) { [weak self] in
            let color = Self.computeDominantColor(from: cgImage)
            await self?.applyFullDominantColor(color, page: page)
        }
    }

    private func applyFullDominantColor(_ color: Color?, page: Int) {
        fullColorPagesInFlight.remove(page)
        if let color {
            dominantColors[page] = color
            previewSeededDominantPages.remove(page)
        }
    }

    /// 纯计算: CIFilter 提取平均色 (nonisolated, 可在任意线程运行)
    nonisolated private static func computeDominantColor(from cgImage: CGImage) -> Color? {
        let ciImage = CIImage(cgImage: cgImage)

        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: ciImage.extent)
        ]),
        let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(output, toBitmap: &bitmap, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)

        return Color(
            red: Double(bitmap[0]) / 255.0,
            green: Double(bitmap[1]) / 255.0,
            blue: Double(bitmap[2]) / 255.0
        ).opacity(0.5)
    }

    // MARK: - Memory Management

    /// 主动释放距当前页过远的图片，防止 OOM
    func evictDistantPages(from page: Int) {
        let retentionRadius = min(6, max(2, AppSettings.shared.preloadImage))
        let pagesToKeep = ReaderPrefetchPlanner.retainedPages(
            around: page,
            totalPages: totalPages,
            radius: retentionRadius
        )

        var toEvict: [Int] = []
        for (p, _) in cachedImages where !pagesToKeep.contains(p) {
            toEvict.append(p)
        }
        for p in toEvict {
            cachedImages.removeValue(forKey: p)
            // NSCache 保留自身引用，这里只释放 Observable 层
        }
        if !toEvict.isEmpty {
            spreadImageCache = spreadImageCache.filter { key, _ in
                guard let spread = spreads.first(where: { $0.id == key.spreadID }) else { return false }
                return spread.pages.allSatisfy(pagesToKeep.contains)
            }
        }
    }

    /// 系统发出内存压力时只保留当前可见 spread，并取消其他尚未完成的
    /// 网络/解码工作。NSCache 清空不会影响 cachedImages 中正在显示的图片。
    func handleMemoryPressure() {
        var visiblePages: Set<Int> = [currentPage]
        if isDoublePageEnabled,
           let spreadIndex = currentSpreadIndex,
           spreads.indices.contains(spreadIndex) {
            visiblePages.formUnion(spreads[spreadIndex].pages)
        }

        cancelImageLoads(outside: visiblePages)
        cachedImages = cachedImages.filter { visiblePages.contains($0.key) }
        spreadImageCache = spreadImageCache.filter { key, _ in
            guard let spread = spreads.first(where: { $0.id == key.spreadID }) else { return false }
            return spread.pages.allSatisfy(visiblePages.contains)
        }
        dominantColors = dominantColors.filter { visiblePages.contains($0.key) }
        Self.imageCache.removeAllObjects()
        PerformanceDiagnostics.event("ReaderMemoryPressure")
    }

    func cancelBackgroundWork() {
        prefetchTask?.cancel()
        prefetchTask = nil
        for entry in imageLoadTasks.values {
            entry.task.cancel()
        }
        imageLoadTasks.removeAll()
    }

    private func cancelImageLoads(outside pagesToKeep: Set<Int>) {
        let pagesToCancel = imageLoadTasks.keys.filter { !pagesToKeep.contains($0) }
        for page in pagesToCancel {
            imageLoadTasks.removeValue(forKey: page)?.task.cancel()
        }
    }

    // MARK: - Context Switch (画廊切换身份守卫)

    /// 身份核对守卫 — 检测是否需要切换画廊上下文
    /// - Hit Cache: `gid` 未变且已有数据 → 跳过重新加载
    /// - Context Switch: `gid` 变更 → 重置全部状态后加载新画廊
    /// - Returns: `true` = 需要重新加载; `false` = 命中缓存可跳过
    func prepareForGallery(targetGid: Int64, targetToken: String) -> Bool {
        if self.gid == targetGid && self.totalPages > 0 {
            // Hit Cache: 同一画廊且数据已就绪 → 不重新加载
            return false
        }

        if self.gid != targetGid {
            // Context Switch: 换书了 → 先清空旧状态
            resetState()
        }

        // 设置新身份
        self.gid = targetGid
        self.token = targetToken
        return true
    }

    /// 彻底重置所有状态 — 在加载新画廊前调用
    /// UI 会因 totalPages == 0 立即切入 Loading 状态
    private func resetState() {
        // 页面状态
        currentPage = 0
        totalPages = 0
        isDownloaded = false
        lazyCurrentPage = 0
        verticalScrollPage = 0

        // 双页模式
        spreads = []
        currentSpreadIndex = 0

        // 图片数据
        imageURLs.removeAll()
        originalImageURLs.removeAll()
        pagesUsingOriginalImage.removeAll()
        cachedImages.removeAll()
        spreadImageCache.removeAll()
        errorPages.removeAll()
        errorMessages.removeAll()
        retryingPages.removeAll()
        downloadProgress.removeAll()
        retryGeneration.removeAll()

        // ⚠️ 关键: 清空 NSCache 防止旧画廊图片被复用
        Self.imageCache.removeAllObjects()

        // 视觉
        dominantColors.removeAll()
        previewSeededDominantPages.removeAll()
        fullColorPagesInFlight.removeAll()

        // 私有状态
        pTokens.removeAll()
        showKeys.removeAll()
        loadingPages.removeAll()
        cancelBackgroundWork()
        downloadDir = nil
    }

    // MARK: - Setup (Fix D-1, B-1: 从 DownloadManager 查询真实下载状态，不再信任调用方传入的 Bool)

    /// 检查下载状态并设置本地目录 — 替代旧的硬编码 `isDownloaded` + `gid-token` 路径
    /// 验证: 数据库状态 == stateFinish AND 磁盘目录存在
    func setupLocalGallery() async {
        let fullyDownloaded = await DownloadManager.shared.isGalleryFullyDownloaded(gid: gid)
        if fullyDownloaded,
           let dir = await DownloadManager.shared.getDownloadedGalleryDirectory(gid: gid) {
            self.isDownloaded = true
            self.downloadDir = dir
        } else {
            self.isDownloaded = false
            self.downloadDir = nil
        }
    }

    func extractPTokens(from previewSet: PreviewSet) {
        let urls: [String]
        switch previewSet {
        case .normal(let items): urls = items.map { $0.pageUrl }
        case .large(let items): urls = items.map { $0.pageUrl }
        }

        for url in urls {
            let range = NSRange(url.startIndex..., in: url)
            if let match = Self.pTokenUrlPattern.firstMatch(in: url, range: range),
               let ptRange = Range(match.range(at: 1), in: url),
               let pnRange = Range(match.range(at: 3), in: url) {
                let pt = String(url[ptRange])
                let pn = Int(url[pnRange]) ?? 0
                pTokens[pn - 1] = pt
            }
        }
    }

    // MARK: - Network: Gallery Info

    func fetchGalleryInfo() async {
        let site = GalleryActionService.siteBaseURL
        let urlStr = "\(site)g/\(gid)/\(token)/"
        guard let url = URL(string: urlStr) else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                             forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, _) = try await Self.session.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""

            if let match = Self.pagesPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let pages = Int(html[range]) ?? 0
                await MainActor.run { self.totalPages = pages }
            }

            let range = NSRange(html.startIndex..., in: html)
            let matches = Self.pTokenUrlPattern.matches(in: html, range: range)
            for m in matches {
                guard let ptRange = Range(m.range(at: 1), in: html),
                      let pnRange = Range(m.range(at: 3), in: html) else { continue }
                let pt = String(html[ptRange])
                let pn = Int(html[pnRange]) ?? 0
                pTokens[pn - 1] = pt
            }
        } catch {}
    }

    // MARK: - Page Loading

    func loadCurrentPage() async {
        cancelImageLoads(outside: pagesRetainedForLoading(around: currentPage))
        await loadPage(currentPage)
        await downloadImageData(currentPage)
        // 初次进入也必须触发氛围色，不再需要等用户翻页。
        extractDominantColor(for: currentPage)
        schedulePrefetch(around: currentPage)
    }

    func onPageChange(_ page: Int) async {
        guard page >= 0, page < totalPages else { return }
        if let lastPrefetchPage, page != lastPrefetchPage {
            prefetchDirection = page > lastPrefetchPage ? 1 : -1
        }
        lastPrefetchPage = page
        cancelImageLoads(outside: pagesRetainedForLoading(around: page, direction: prefetchDirection))

        // 更新 spread 索引
        let spreadIdx = spreadIndex(for: page)
        if spreadIdx != currentSpreadIndex {
            await MainActor.run { self.currentSpreadIndex = spreadIdx }
        }

        await loadPage(page)
        await downloadImageData(page)

        // 双页模式下同时加载副页
        if isDoublePageEnabled, spreadIdx < spreads.count {
            let spread = spreads[spreadIdx]
            for p in spread.pages where p != page {
                await loadPage(p)
                await downloadImageData(p)
            }
        }

        schedulePrefetch(around: page)

        // 提取主色调 (内部已在后台线程执行)
        extractDominantColor(for: page)

        // 释放远处页面
        evictDistantPages(from: page)
    }

    /// 下载图片数据到 NSCache，带进度追踪
    func downloadImageData(
        _ index: Int,
        priority: TaskPriority = .userInitiated
    ) async {
        // 已缓存 → 直接提升到 Observable 层 (使用 gid:page 复合 key)
        let key = cacheKey(for: index)
        if let cached = Self.imageCache.object(forKey: key) {
            await MainActor.run {
                if self.cachedImages[index] == nil {
                    self.cachedImages[index] = cached
                }
            }
            return
        }

        // The configured reader cache stores compressed source bytes. Decode
        // only after a hit and keep both disk access and ImageIO off MainActor.
        let galleryID = gid
        let maxPixelSize = Self.maxDecodePixelSize
        if let diskCached = await Task.detached(priority: .utility, operation: {
            guard let data = SpiderDen.cachedImageData(gid: galleryID, page: index)
            else { return nil as PlatformImage? }
            return Self.downsampledImage(data: data, maxPixelSize: maxPixelSize)
        }).value {
            Self.imageCache.setObject(
                diskCached,
                forKey: key,
                cost: Self.decodedCost(of: diskCached)
            )
            cachedImages[index] = diskCached
            downloadProgress.removeValue(forKey: index)
            errorPages.remove(index)
            errorMessages.removeValue(forKey: index)
            return
        }
        guard let urlString = imageURLs[index], let url = URL(string: urlString) else { return }
        let performanceInterval = PerformanceDiagnostics.begin("ReaderImageLoadDecode")
        defer { performanceInterval.end() }

        // Downloaded galleries use file URLs. Reading them through URLSession
        // adds network retry/connection machinery and may fail on some OS
        // versions. Read and decode locally, entirely away from MainActor.
        if url.isFileURL {
            let outcome = await Task.detached(priority: priority) {
                do {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard let image = Self.downsampledImage(
                        data: data,
                        maxPixelSize: maxPixelSize
                    ) else {
                        return ImageLoadOutcome.invalidData
                    }
                    return ImageLoadOutcome.image(image)
                } catch is CancellationError {
                    return ImageLoadOutcome.cancelled
                } catch {
                    return ImageLoadOutcome.failure(error.localizedDescription)
                }
            }.value

            switch outcome {
            case .image(let image):
                Self.imageCache.setObject(
                    image,
                    forKey: key,
                    cost: Self.decodedCost(of: image)
                )
                cachedImages[index] = image
                downloadProgress.removeValue(forKey: index)
                errorPages.remove(index)
                errorMessages.removeValue(forKey: index)
            case .invalidData:
                errorPages.insert(index)
                errorMessages[index] = AppLocalization.localized("图片数据无效")
            case .failure(let message):
                errorPages.insert(index)
                errorMessages[index] = message
            case .cancelled:
                break
            }
            return
        }

        let entry: InFlightImageLoad
        if let existing = imageLoadTasks[index] {
            entry = existing
        } else {
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue(GalleryActionService.siteBaseURL, forHTTPHeaderField: "Referer")
            request.timeoutInterval = 60

            let session = Self.session
            let id = UUID()
            let task = Task.detached(priority: priority) {
                for attempt in 0..<3 {
                    guard !Task.isCancelled else { return ImageLoadOutcome.cancelled }
                    do {
                        let (data, response) = try await session.data(for: request)
                        if let response = response as? HTTPURLResponse,
                           !(200...299).contains(response.statusCode) {
                            throw URLError(.badServerResponse)
                        }
                        guard !Task.isCancelled else { return ImageLoadOutcome.cancelled }
                        guard let image = Self.downsampledImage(
                            data: data,
                            maxPixelSize: maxPixelSize
                        ) else {
                            return ImageLoadOutcome.invalidData
                        }
                        _ = SpiderDen.cacheImageData(data, gid: galleryID, page: index)
                        return ImageLoadOutcome.image(image)
                    } catch is CancellationError {
                        return ImageLoadOutcome.cancelled
                    } catch let error as URLError where error.code == .cancelled {
                        return ImageLoadOutcome.cancelled
                    } catch {
                        guard attempt < 2 else {
                            return ImageLoadOutcome.failure(error.localizedDescription)
                        }
                        do {
                            try await Task.sleep(for: .seconds(1 << attempt))
                        } catch {
                            return ImageLoadOutcome.cancelled
                        }
                    }
                }
                return ImageLoadOutcome.failure("未知错误")
            }
            entry = InFlightImageLoad(id: id, task: task)
            imageLoadTasks[index] = entry
        }

        let outcome = await entry.task.value
        if imageLoadTasks[index]?.id == entry.id {
            imageLoadTasks.removeValue(forKey: index)
        }

        switch outcome {
        case .image(let image):
            let cost = Self.decodedCost(of: image)
            Self.imageCache.setObject(image, forKey: cacheKey(for: index), cost: cost)
            if pagesRetainedForLoading(around: currentPage).contains(index) {
                cachedImages[index] = image
            }
            downloadProgress.removeValue(forKey: index)
            errorPages.remove(index)
            errorMessages.removeValue(forKey: index)
            evictDistantPages(from: currentPage)
        case .invalidData:
            errorPages.insert(index)
            errorMessages[index] = AppLocalization.localized("图片数据无效")
            downloadProgress.removeValue(forKey: index)
        case .failure(let message):
            guard !Task.isCancelled else { return }
            debugLog("[Reader] Image download failed page \(index): \(message)")
            errorPages.insert(index)
            errorMessages[index] = AppLocalization.format("下载失败: %@", message)
            downloadProgress.removeValue(forKey: index)
        case .cancelled:
            return
        }
    }

    /// Re-resolves the page and replaces the displayed source with the site's
    /// "Download original" URL. The decoded cache must be cleared because its
    /// key intentionally identifies a page rather than a particular source URL.
    func loadOriginalImage(_ index: Int) async {
        guard index >= 0, index < totalPages else { return }

        let originalURL: URL
        do {
            originalURL = try await resolveOriginalImageURL(for: index)
        } catch {
            debugLog("[Reader] Original image lookup failed page \(index): \(error.localizedDescription)")
            return
        }
        Self.imageCache.removeObject(forKey: cacheKey(for: index))
        cachedImages.removeValue(forKey: index)
        spreadImageCache.removeAll(keepingCapacity: true)
        imageURLs[index] = originalURL.absoluteString
        pagesUsingOriginalImage.insert(index)
        errorPages.remove(index)
        await downloadImageData(index)
    }

    /// 预览菜单直接保存/拷贝原图时使用。只获取原始字节，不创建大尺寸
    /// 解码图或污染阅读器当前页缓存，避免一次菜单操作带来额外内存峰值。
    func originalSourceImageData(for index: Int) async throws -> Data {
        guard index >= 0, index < totalPages else { throw URLError(.badURL) }
        let url = try await resolveOriginalImageURL(for: index)
        return try await sourceImageData(from: url)
    }

    /// Returns the exact bytes behind the current page URL. Unlike the image
    /// used for display, this data has not been downsampled by the reader.
    func sourceImageData(for index: Int) async throws -> Data {
        guard let source = imageURLs[index], let url = URL(string: source) else {
            throw URLError(.badURL)
        }
        return try await sourceImageData(from: url)
    }

    private func sourceImageData(from url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(GalleryActionService.siteBaseURL, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 90
        let (data, response) = try await Self.session.data(for: request)
        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func resolveOriginalImageURL(for index: Int) async throws -> URL {
        if let cached = originalImageURLs[index], let url = URL(string: cached) {
            return url
        }

        let pToken: String
        if let cachedToken = pTokens[index] {
            pToken = cachedToken
        } else {
            pToken = try await fetchPToken(page: index)
            pTokens[index] = pToken
        }

        let site = GalleryActionService.siteBaseURL
        guard let pageURL = URL(string: "\(site)s/\(pToken)/\(gid)-\(index + 1)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: pageURL)
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 20
        let (data, response) = try await Self.session.data(for: request)
        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        cacheOriginalImageURL(
            from: String(data: data, encoding: .utf8) ?? "",
            for: index
        )
        guard let resolved = originalImageURLs[index], let url = URL(string: resolved) else {
            throw URLError(.cannotParseResponse)
        }
        return url
    }

    private func cacheOriginalImageURL(from html: String, for index: Int) {
        guard let match = Self.originalImagePattern.firstMatch(
            in: html,
            range: NSRange(html.startIndex..., in: html)
        ), let range = Range(match.range(at: 1), in: html) else { return }
        originalImageURLs[index] = String(html[range])
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// 带重试的页面 URL 获取 (最多 5 次)
    func loadPageWithRetry(_ index: Int) async {
        let maxRetries = 5
        for attempt in 0..<maxRetries {
            guard !Task.isCancelled else { return }
            await MainActor.run { self.retryingPages[index] = attempt }
            await loadPage(index)
            if imageURLs[index] != nil {
                await MainActor.run { _ = self.retryingPages.removeValue(forKey: index) }
                return
            }
            if errorPages.contains(index) { return }
            guard !Task.isCancelled else { return }
            let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
        }
        guard !Task.isCancelled else { return }
        await MainActor.run {
            self.errorPages.insert(index)
            self.errorMessages[index] = AppLocalization.localized("加载超时，请点击重试")
            self.retryingPages.removeValue(forKey: index)
        }
    }

    func loadPage(_ index: Int) async {
        guard index >= 0, index < totalPages else { return }
        guard imageURLs[index] == nil else { return }
        if loadingPages.contains(index) {
            // 可见页与预取命中同一 HTML 请求时等待该请求，而不是直接返回。
            // 若原预取被取消，集合会在 defer 中释放，当前调用随后接管重试。
            while loadingPages.contains(index) {
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return
                }
            }
            guard imageURLs[index] == nil else { return }
            guard !Task.isCancelled else { return }
        }

        // 优先本地 (Fix D-1: 通过 DownloadManager 统一路径，本地找不到时回退网络)
        if isDownloaded, let dir = downloadDir {
            if let localURL = SpiderInfoFile.getLocalImageURL(in: dir, pageIndex: index) {
                await MainActor.run {
                    self.imageURLs[index] = localURL.absoluteString
                    self.errorPages.remove(index)
                }
                return
            }
            // 本地文件缺失 — 不 return，继续尝试网络加载
        }

        // URL 缓存
        if let cached = GalleryCache.shared.getImageURL(gid: gid, page: index) {
            await MainActor.run {
                self.imageURLs[index] = cached
                self.errorPages.remove(index)
            }
            return
        }

        loadingPages.insert(index)
        defer { loadingPages.remove(index) }

        do {
            let site = GalleryActionService.siteBaseURL
            let pageUrl: String

            if let pToken = pTokens[index] {
                pageUrl = "\(site)s/\(pToken)/\(gid)-\(index + 1)"
            } else {
                let pToken = try await fetchPToken(page: index)
                pTokens[index] = pToken
                pageUrl = "\(site)s/\(pToken)/\(gid)-\(index + 1)"
            }

            guard let url = URL(string: pageUrl) else { return }

            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                             forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, _) = try await Self.session.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""
            cacheOriginalImageURL(from: html, for: index)

            if let m = Self.imgSrcPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                let imgUrl = String(html[r])
                GalleryCache.shared.putImageURL(imgUrl, gid: gid, page: index)
                await MainActor.run {
                    self.imageURLs[index] = imgUrl
                    self.errorPages.remove(index)
                }
            } else {
                debugLog("[Reader] Failed to extract image URL from page HTML for page \(index)")
                await MainActor.run { _ = self.errorPages.insert(index) }
                return
            }

            if let m = Self.showKeyPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                showKeys[index] = String(html[r])
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            if !Task.isCancelled {
                debugLog("[Reader] Page \(index) load error: \(error.localizedDescription)")
            }
        }
    }

    func retryLoadPage(_ index: Int) async {
        await MainActor.run {
            self.imageURLs[index] = nil
            self.cachedImages.removeValue(forKey: index)
            self.spreadImageCache.removeAll(keepingCapacity: true)
            self.errorPages.remove(index)
            self.errorMessages.removeValue(forKey: index)
            self.retryingPages.removeValue(forKey: index)
            self.downloadProgress.removeValue(forKey: index)
            self.retryGeneration[index, default: 0] += 1
        }
        Self.imageCache.removeObject(forKey: cacheKey(for: index))
        pTokens.removeValue(forKey: index)
        GalleryCache.shared.removeImageURL(gid: gid, page: index)
        loadingPages.remove(index)
        await loadPageWithRetry(index)
        await downloadImageData(index)
    }

    private func schedulePrefetch(around page: Int) {
        prefetchTask?.cancel()
        let direction = prefetchDirection
        prefetchTask = Task { [weak self] in
            await self?.preload(around: page, direction: direction)
        }
    }

    /// 方向感知预加载：快速反向翻页会取消旧计划；低数据模式和昂贵网络
    /// 会主动缩小窗口，避免无用请求占用带宽与图片解码内存。
    func preload(around page: Int, direction: Int = 1) async {
        let configured = AppSettings.shared.preloadImage
        let preloadNum: Int
        if networkIsConstrained {
            preloadNum = 1
        } else if networkIsExpensive {
            preloadNum = min(2, configured)
        } else {
            preloadNum = configured
        }
        let ahead = direction >= 0 ? preloadNum : 1
        let behind = direction >= 0 ? 1 : preloadNum
        let pagesToLoad = ReaderPrefetchPlanner.pages(
            around: page,
            totalPages: totalPages,
            ahead: ahead,
            behind: behind
        )
        guard !pagesToLoad.isEmpty else { return }

        // 同时最多处理 3 页，避免高分辨率图片并发解码造成瞬时内存峰值。
        await withTaskGroup(of: Void.self) { group in
            var iterator = pagesToLoad.makeIterator()
            for _ in 0..<min(3, pagesToLoad.count) {
                guard let page = iterator.next() else { break }
                group.addTask(priority: .utility) {
                    await self.loadPage(page)
                    await self.downloadImageData(page, priority: .utility)
                }
            }

            while await group.next() != nil {
                guard !Task.isCancelled, let page = iterator.next() else { continue }
                group.addTask(priority: .utility) {
                    await self.loadPage(page)
                    await self.downloadImageData(page, priority: .utility)
                }
            }
        }
    }

    private func pagesRetainedForLoading(around page: Int, direction: Int = 1) -> Set<Int> {
        let radius = min(6, max(2, AppSettings.shared.preloadImage))
        let ahead = direction >= 0 ? radius : 1
        let behind = direction >= 0 ? 1 : radius
        var pages = Set(ReaderPrefetchPlanner.pages(
            around: page,
            totalPages: totalPages,
            ahead: ahead,
            behind: behind
        ))
        pages.insert(page)
        if isDoublePageEnabled {
            let spreadIndex = spreadIndex(for: page)
            if spreads.indices.contains(spreadIndex) {
                pages.formUnion(spreads[spreadIndex].pages)
            }
        }
        return pages
    }

    private func fetchPToken(page: Int) async throws -> String {
        let site = GalleryActionService.siteBaseURL
        let detailPage = page / 20
        let urlStr = "\(site)g/\(gid)/\(token)/\(detailPage > 0 ? "?p=\(detailPage)" : "")"
        guard let url = URL(string: urlStr) else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, _) = try await Self.session.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""

        let range = NSRange(html.startIndex..., in: html)
        let matches = Self.pTokenUrlPattern.matches(in: html, range: range)

        for m in matches {
            guard let ptRange = Range(m.range(at: 1), in: html),
                  let pnRange = Range(m.range(at: 3), in: html) else { continue }
            let pt = String(html[ptRange])
            let pn = Int(html[pnRange]) ?? 0
            pTokens[pn - 1] = pt
        }

        if let pt = pTokens[page] { return pt }
        throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "pToken not found"])
    }
}
