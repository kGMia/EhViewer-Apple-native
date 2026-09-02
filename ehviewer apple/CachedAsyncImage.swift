//
//  CachedAsyncImage.swift
//  ehviewer apple
//
//  macOS 图片流水线：请求合并、内存/磁盘缓存、后台降采样与自动重试。
//

import SwiftUI
import EhAPI
import EhSettings
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 共享连接池，避免每个图片视图各自创建 URLSession。
private enum ImageSessionProvider {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = URLCache.shared
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpAdditionalHeaders = ["User-Agent": EhRequestBuilder.userAgent]
        return URLSession(configuration: config)
    }()
}

/// 统一处理早期画廊留下的缩略图格式。旧数据可能使用 http、协议相对
/// 地址、带引号的 CSS url()，或已经失效的 ehgt 根域名；先规范化主地址，
/// 加载失败时再轮询同一路径的官方 CDN 变体。
enum ThumbnailURLResolver {
    static func url(for rawValue: String?, fixLegacy: Bool, site: EhSite) -> URL? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }

        if value.hasPrefix("url(") && value.hasSuffix(")") {
            value.removeFirst(4)
            value.removeLast()
        }
        value = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            .replacingOccurrences(of: "&amp;", with: "&")

        if value.hasPrefix("//") {
            value = "https:" + value
        } else if value.hasPrefix("/") {
            return URL(string: value, relativeTo: URL(string: EhURL.host(for: site)))?.absoluteURL
        } else if !value.contains("://") {
            value = "https://" + value
        }

        guard fixLegacy, var components = URLComponents(string: value) else {
            return URL(string: value)
        }
        if components.scheme == "http" { components.scheme = "https" }

        let host = components.host?.lowercased() ?? ""
        let isLegacyCDN = host == "ehgt.org"
            || (host.hasPrefix("gt") && host.hasSuffix(".ehgt.org"))

        if site == .exHentai, isLegacyCDN {
            components.host = "exhentai.org"
            if !components.path.hasPrefix("/t/") {
                components.path = "/t" + (components.path.hasPrefix("/") ? components.path : "/" + components.path)
            }
        } else if site == .eHentai, host == "ehgt.org" {
            // ehgt 根域名对一部分旧对象已不再稳定，优先选择实际 CDN 节点。
            components.host = "gt1.ehgt.org"
        }
        return components.url
    }

    static func candidates(for primaryURL: URL, fixLegacy: Bool, site: EhSite) -> [URL] {
        guard fixLegacy, let host = primaryURL.host?.lowercased() else { return [primaryURL] }
        let isEhgt = host == "ehgt.org" || (host.hasPrefix("gt") && host.hasSuffix(".ehgt.org"))
        let isExThumb = host == "exhentai.org" && primaryURL.path.hasPrefix("/t/")
        guard isEhgt || isExThumb else { return [primaryURL] }

        let cdnPath = isExThumb
            ? String(primaryURL.path.dropFirst(2))
            : primaryURL.path
        var values = [primaryURL]

        func append(host candidateHost: String, path: String) {
            var components = URLComponents(url: primaryURL, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            components?.host = candidateHost
            components?.path = path
            if let candidate = components?.url, !values.contains(candidate) {
                values.append(candidate)
            }
        }

        if site == .exHentai {
            append(host: "exhentai.org", path: "/t" + cdnPath)
        }
        for candidateHost in ["gt0.ehgt.org", "gt1.ehgt.org", "gt2.ehgt.org", "gt3.ehgt.org", "ehgt.org"] {
            append(host: candidateHost, path: cdnPath)
        }
        return values
    }
}

/// NSCache 自身线程安全；包装为 Sendable 以供图片流水线跨隔离域使用。
nonisolated final class ThumbnailMemoryCache: @unchecked Sendable {
    static let shared = ThumbnailMemoryCache()
    private let cache = NSCache<NSURL, PlatformImage>()
    #if os(macOS)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 96 * 1024 * 1024

        #if os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            // NSCache 会自行逐出对象，但在 macOS 内存压力下主动清空可更快
            // 释放已解码位图；URLCache 仍保留压缩数据，重新显示无需重下。
            self?.cache.removeAllObjects()
        }
        source.resume()
        memoryPressureSource = source
        #endif
    }

    deinit {
        #if os(macOS)
        memoryPressureSource?.cancel()
        #endif
    }

    func get(_ url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    func set(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: Self.decodedCost(of: image))
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private static func decodedCost(of image: PlatformImage) -> Int {
        #if os(macOS)
        if let rep = image.representations.first {
            return max(rep.pixelsWide, 1) * max(rep.pixelsHigh, 1) * 4
        }
        #else
        if let frames = image.images, !frames.isEmpty {
            return frames.reduce(into: 0) { cost, frame in
                if let cgImage = frame.cgImage {
                    cost += cgImage.bytesPerRow * cgImage.height
                }
            }
        }
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        #endif
        return 512 * 1024
    }
}

/// AppKit/UIKit 图片不是 Sendable，但解码完成后只作为不可变值传回主线程显示。
private struct LoadedThumbnail: @unchecked Sendable {
    let image: PlatformImage
}

/// 参考 EhPanda 的统一 ImageClient：相同 URL 的并发请求只下载、解码一次。
private actor ThumbnailImagePipeline {
    static let shared = ThumbnailImagePipeline()

    private var inFlight: [URL: Task<LoadedThumbnail?, Never>] = [:]
    private var recentFailures: [URL: Date] = [:]
    // Covers are normally rendered below 320 pt. Decoding each thumbnail at
    // 1600 px retained only a few images and forced costly re-decodes on tabs.
    private let maxPixelSize: CGFloat = 900
    private let maxRetries = 3
    private let failureCooldown: TimeInterval = 120

    func image(
        for url: URL,
        referer: String,
        bypassFailureCache: Bool = false
    ) async -> LoadedThumbnail? {
        if let cached = ThumbnailMemoryCache.shared.get(url) {
            return LoadedThumbnail(image: cached)
        }
        if bypassFailureCache {
            recentFailures[url] = nil
        } else if let failedAt = recentFailures[url],
           Date().timeIntervalSince(failedAt) < failureCooldown {
            return nil
        }
        if let task = inFlight[url] {
            return await task.value
        }

        let maxPixelSize = maxPixelSize
        let maxRetries = maxRetries
        let task = Task(priority: .utility) {
            await Self.fetchImage(
                url: url,
                referer: referer,
                maxPixelSize: maxPixelSize,
                maxRetries: maxRetries
            )
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil

        if let result {
            recentFailures[url] = nil
            ThumbnailMemoryCache.shared.set(result.image, for: url)
        } else {
            recentFailures[url] = Date()
            if recentFailures.count > 500 {
                let cutoff = Date().addingTimeInterval(-failureCooldown)
                recentFailures = recentFailures.filter { $0.value >= cutoff }
            }
        }
        return result
    }

    private static func fetchImage(
        url: URL,
        referer: String,
        maxPixelSize: CGFloat,
        maxRetries: Int
    ) async -> LoadedThumbnail? {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
        request.setValue(referer, forHTTPHeaderField: "Referer")

        if let cached = URLCache.shared.cachedResponse(for: request),
           let image = await decode(cached.data, maxPixelSize: maxPixelSize) {
            return LoadedThumbnail(image: image)
        }

        for attempt in 0..<maxRetries {
            guard !Task.isCancelled else { return nil }
            do {
                let (data, response) = try await ImageSessionProvider.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    return nil
                }
                guard let image = await decode(data, maxPixelSize: maxPixelSize) else {
                    return nil
                }
                URLCache.shared.storeCachedResponse(
                    CachedURLResponse(response: response, data: data),
                    for: request
                )
                return LoadedThumbnail(image: image)
            } catch is CancellationError {
                return nil
            } catch let error as URLError where error.code == .cancelled {
                return nil
            } catch {
                guard attempt < maxRetries - 1 else { return nil }
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        return nil
    }

    private static func decode(_ data: Data, maxPixelSize: CGFloat) async -> PlatformImage? {
        await Task.detached(priority: .utility) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                return nil
            }
            if CGImageSourceGetCount(source) > 1,
               let animated = decodeAnimatedPlatformImage(
                   data: data,
                   source: source,
                   requestedMaxPixelSize: min(maxPixelSize, 420),
                   maximumFrames: 24,
                   pixelBudget: 4_000_000
               ) {
                return animated
            }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ) else {
                return nil
            }
            #if os(macOS)
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            #else
            return UIImage(cgImage: cgImage)
            #endif
        }.value
    }
}

/// 缓存友好的异步图片视图。SwiftUI 会在 URL 改变或视图离屏时取消当前等待，
/// 底层共享请求仍可供其他可见单元格复用。
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let showProgress: Bool
    let onImageSize: ((CGSize) -> Void)?
    let onImageLoaded: ((PlatformImage) -> Void)?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: PlatformImage?
    @State private var isLoading = false
    @State private var hasFailed = false
    @State private var retryGeneration = 0

    init(
        url: URL?,
        showProgress: Bool = true,
        onImageSize: ((CGSize) -> Void)? = nil,
        onImageLoaded: ((PlatformImage) -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.showProgress = showProgress
        self.onImageSize = onImageSize
        self.onImageLoaded = onImageLoaded
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                if image.isAnimatedPlatformImage {
                    PlatformAnimatedImageView(image: image, contentMode: .fill)
                        .onAppear {
                            onImageSize?(image.size)
                        }
                } else {
                #if os(macOS)
                content(Image(nsImage: image))
                    .onAppear { onImageSize?(image.size) }
                #else
                content(Image(uiImage: image))
                    .onAppear { onImageSize?(image.size) }
                #endif
                }
            } else if hasFailed {
                placeholder()
                    .overlay {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        hasFailed = false
                        retryGeneration += 1
                    }
            } else {
                ZStack {
                    placeholder()
                    if isLoading && showProgress {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .task(id: LoadID(url: url, generation: retryGeneration)) {
            await load()
        }
        .onChange(of: url) { _, _ in
            image = nil
            hasFailed = false
        }
    }

    private func load() async {
        guard let url else { return }
        isLoading = true
        defer { isLoading = false }

        let referer = AppSettings.shared.gallerySite == .exHentai
            ? "https://exhentai.org/"
            : "https://e-hentai.org/"
        let candidates = ThumbnailURLResolver.candidates(
            for: url,
            fixLegacy: AppSettings.shared.fixThumbUrl,
            site: AppSettings.shared.gallerySite
        )

        for candidate in candidates {
            guard !Task.isCancelled else { return }
            if let loaded = await ThumbnailImagePipeline.shared.image(
                for: candidate,
                referer: referer,
                bypassFailureCache: retryGeneration > 0
            ) {
                guard !Task.isCancelled else { return }
                // The pipeline already cached the successful candidate. Only
                // add an alias when legacy URL resolution used another host.
                if candidate != url {
                    ThumbnailMemoryCache.shared.set(loaded.image, for: url)
                }
                image = loaded.image
                onImageLoaded?(loaded.image)
                hasFailed = false
                return
            }
        }
        if !Task.isCancelled {
            hasFailed = true
        }
    }

    private struct LoadID: Equatable {
        let url: URL?
        let generation: Int
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    var isAnimatedPlatformImage: Bool {
        #if os(iOS)
        return (images?.count ?? 0) > 1
        #else
        return representations.contains { representation in
            guard let bitmap = representation as? NSBitmapImageRep else { return false }
            return (bitmap.value(forProperty: .frameCount) as? Int ?? 0) > 1
        }
        #endif
    }
}

/// Decode animated formats with a bounded frame/pixel budget. Static images
/// never enter this path, and very long animations are sampled instead of
/// retaining hundreds of full decoded frames in memory.
nonisolated func decodeAnimatedPlatformImage(
    data: Data,
    source: CGImageSource,
    requestedMaxPixelSize: CGFloat,
    maximumFrames: Int = 48,
    pixelBudget: Double = 16_000_000
) -> PlatformImage? {
    let frameCount = CGImageSourceGetCount(source)
    guard frameCount > 1 else { return nil }

    #if os(macOS)
    // NSBitmapImageRep keeps animated data lazy and NSImageView drives frame
    // timing, which is considerably cheaper than expanding every frame here.
    return NSImage(data: data)
    #else
    let boundedFrameCount = max(maximumFrames, 2)
    let stride = max(1, Int(ceil(Double(frameCount) / Double(boundedFrameCount))))
    let selectedIndices = Array(Swift.stride(from: 0, to: frameCount, by: stride))
    // The caller selects a budget appropriate for a thumbnail or full reader.
    // Four bytes per pixel means 4M pixels is roughly 16 MB.
    let budgetedDimension = sqrt(pixelBudget / Double(max(selectedIndices.count, 1)))
    let maxPixelSize = max(320, min(Double(requestedMaxPixelSize), budgetedDimension))
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceShouldCacheImmediately: true
    ]

    var frames: [UIImage] = []
    frames.reserveCapacity(selectedIndices.count)
    var totalDuration: TimeInterval = 0
    for index in selectedIndices {
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            index,
            options as CFDictionary
        ) else { continue }
        frames.append(UIImage(cgImage: cgImage))
        let end = min(index + stride, frameCount)
        for timingIndex in index..<end {
            totalDuration += animatedFrameDuration(source: source, index: timingIndex)
        }
    }
    guard frames.count > 1 else { return frames.first }
    return UIImage.animatedImage(
        with: frames,
        duration: max(totalDuration, Double(frames.count) / 12)
    )
    #endif
}

nonisolated private func animatedFrameDuration(source: CGImageSource, index: Int) -> TimeInterval {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
        as? [CFString: Any],
          let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    else { return 0.1 }
    let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
    let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
    return max(unclamped ?? clamped ?? 0.1, 0.02)
}

struct PlatformAnimatedImageView: View {
    let image: PlatformImage
    let contentMode: ContentMode

    var body: some View {
        PlatformAnimatedImageRepresentable(image: image, contentMode: contentMode)
            .aspectRatio(image.size, contentMode: contentMode)
    }
}

#if os(iOS)
private struct PlatformAnimatedImageRepresentable: UIViewRepresentable {
    let image: UIImage
    let contentMode: ContentMode

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        if view.image !== image { view.image = image }
        view.startAnimating()
    }
}
#else
private struct PlatformAnimatedImageRepresentable: NSViewRepresentable {
    let image: NSImage
    let contentMode: ContentMode

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.imageScaling = .scaleProportionallyUpOrDown
        if view.image !== image { view.image = image }
        view.animates = true
    }
}
#endif
