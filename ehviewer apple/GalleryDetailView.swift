//
//  GalleryDetailView.swift
//  ehviewer apple
//
//  画廊详情视图
//

import SwiftUI
import EhModels
import EhDownload
import EhAPI
import EhSettings
import EhDatabase
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - 标签导航支持 (对齐 Android: onTagClick → 推入新画廊列表到左侧导航栈)

/// 标签搜索导航目标 — 用于 NavigationStack 的 path
struct TagSearchDestination: Hashable {
    let tag: String
}

struct UploaderSearchDestination: Hashable {
    let keyword: String
}

/// 标签导航动作 — 从 Detail 列传递到 Content/Sidebar 列的 NavigationStack
struct TagNavigationAction {
    let navigate: (String) -> Void
}

struct UploaderSearchNavigationAction {
    let navigate: (String) -> Void
}

struct GalleryDetailBackAction {
    let perform: () -> Void
}

private struct TagNavigationActionKey: EnvironmentKey {
    static let defaultValue: TagNavigationAction? = nil
}

private struct UploaderSearchNavigationActionKey: EnvironmentKey {
    static let defaultValue: UploaderSearchNavigationAction? = nil
}

private struct GalleryDetailBackActionKey: EnvironmentKey {
    static let defaultValue: GalleryDetailBackAction? = nil
}

extension EnvironmentValues {
    var tagNavigationAction: TagNavigationAction? {
        get { self[TagNavigationActionKey.self] }
        set { self[TagNavigationActionKey.self] = newValue }
    }

    var uploaderSearchNavigationAction: UploaderSearchNavigationAction? {
        get { self[UploaderSearchNavigationActionKey.self] }
        set { self[UploaderSearchNavigationActionKey.self] = newValue }
    }

    var galleryDetailBackAction: GalleryDetailBackAction? {
        get { self[GalleryDetailBackActionKey.self] }
        set { self[GalleryDetailBackActionKey.self] = newValue }
    }
}

// MARK: - Edge-aware cover lighting

/// 以线性 RGB 平均实际可见裁剪区域的边缘色，再转换回 sRGB。
/// alpha 是依据亮度和色彩浓度计算的强度：过暗或接近灰色的边缘会更透明，
/// 避免封面周围形成脏黑色光晕。
private struct CoverGlowColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    static func average(_ colors: CoverGlowColor...) -> CoverGlowColor {
        guard !colors.isEmpty else {
            return CoverGlowColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        let count = Double(colors.count)
        return CoverGlowColor(
            red: colors.reduce(0) { $0 + $1.red } / count,
            green: colors.reduce(0) { $0 + $1.green } / count,
            blue: colors.reduce(0) { $0 + $1.blue } / count,
            alpha: colors.reduce(0) { $0 + $1.alpha } / count
        )
    }

    /// 浅色背景会吞掉高明度反射。保持色相的同时压低极亮中间调、提高
    /// 淡色的饱和度，使彩色光晕可见；深色边缘则保留其自然暗度。
    func adaptedForLightBackground() -> CoverGlowColor {
        let sourceLuminance = luminance
        let saturationGain = sourceLuminance > 0.58 ? 1.55 : 1.18
        var adjustedRed = sourceLuminance + (red - sourceLuminance) * saturationGain
        var adjustedGreen = sourceLuminance + (green - sourceLuminance) * saturationGain
        var adjustedBlue = sourceLuminance + (blue - sourceLuminance) * saturationGain

        if sourceLuminance > 0.72 {
            let adjustedLuminance = 0.2126 * adjustedRed
                + 0.7152 * adjustedGreen
                + 0.0722 * adjustedBlue
            let scale = 0.78 / max(adjustedLuminance, 0.001)
            adjustedRed *= scale
            adjustedGreen *= scale
            adjustedBlue *= scale
        }

        return CoverGlowColor(
            red: min(1, max(0, adjustedRed)),
            green: min(1, max(0, adjustedGreen)),
            blue: min(1, max(0, adjustedBlue)),
            alpha: sourceLuminance > 0.58 ? max(alpha, 0.78) : max(0.46, alpha * 0.72)
        )
    }
}

private struct CoverGlowPalette: Equatable, Sendable {
    let topLeading: CoverGlowColor
    let top: CoverGlowColor
    let topTrailing: CoverGlowColor
    let leading: CoverGlowColor
    let trailing: CoverGlowColor
    let bottomLeading: CoverGlowColor
    let bottom: CoverGlowColor
    let bottomTrailing: CoverGlowColor

    var averageColor: CoverGlowColor {
        CoverGlowColor.average(
            topLeading, top, topTrailing, leading,
            trailing, bottomLeading, bottom, bottomTrailing
        )
    }

    func adaptedForLightBackground() -> CoverGlowPalette {
        CoverGlowPalette(
            topLeading: topLeading.adaptedForLightBackground(),
            top: top.adaptedForLightBackground(),
            topTrailing: topTrailing.adaptedForLightBackground(),
            leading: leading.adaptedForLightBackground(),
            trailing: trailing.adaptedForLightBackground(),
            bottomLeading: bottomLeading.adaptedForLightBackground(),
            bottom: bottom.adaptedForLightBackground(),
            bottomTrailing: bottomTrailing.adaptedForLightBackground()
        )
    }
}

private struct SendableCGImage: @unchecked Sendable {
    let value: CGImage
}

/// 封面按压只改变已合成的图层变换，不重新采样 MeshGradient；
/// 因此封面与泛光会一起弹性收缩，不会增加解码/模糊负担。
private struct ElasticCoverButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.025 : 0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.66),
                value: configuration.isPressed
            )
    }
}

/// 同一封面会同时参与完整与紧凑标题过渡；缓存和合并采样任务，避免滚动时
/// 对同一张位图重复创建颜色空间和像素缓冲区。
private actor CoverGlowPaletteCache {
    static let shared = CoverGlowPaletteCache()

    private var values: [String: CoverGlowPalette] = [:]
    private var insertionOrder: [String] = []
    private var inFlight: [String: Task<CoverGlowPalette?, Never>] = [:]
    private let countLimit = 80

    func palette(
        for key: String,
        image: SendableCGImage,
        targetAspect: CGFloat
    ) async -> CoverGlowPalette? {
        if let cached = values[key] { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task.detached(priority: .utility) {
            CoverEdgeSampler.sample(image.value, targetAspect: targetAspect)
        }
        inFlight[key] = task
        let palette = await task.value
        inFlight[key] = nil

        if let palette {
            if values.count >= countLimit, let oldest = insertionOrder.first {
                insertionOrder.removeFirst()
                values[oldest] = nil
            }
            values[key] = palette
            insertionOrder.append(key)
        }
        return palette
    }
}

private enum CoverEdgeSampler {
    private enum EdgeRegion {
        case topLeading, top, topTrailing
        case leading, trailing
        case bottomLeading, bottom, bottomTrailing
    }

    nonisolated static func sample(_ image: CGImage, targetAspect: CGFloat) -> CoverGlowPalette? {
        guard image.width > 1, image.height > 1, targetAspect > 0 else { return nil }

        let crop = aspectFillCropRect(
            imageSize: CGSize(width: image.width, height: image.height),
            targetAspect: targetAspect
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard crop.width > 1, crop.height > 1,
              let cropped = image.cropping(to: crop) else { return nil }

        // 只需一张很小的 sRGB 位图即可稳定取得色彩；先裁剪再降采样，确保
        // 得到的是屏幕上真正显示的边缘，而不是被 aspectFill 隐藏的像素。
        let sampleWidth = 48
        let sampleHeight = max(32, min(96, Int((CGFloat(sampleWidth) / targetAspect).rounded())))
        let bytesPerRow = sampleWidth * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * sampleHeight)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let drewImage = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: sampleWidth,
                    height: sampleHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    // 明确固定为 RGBA 字节顺序。仅指定 premultipliedLast 时，
                    // 在小端 CPU 上可能以不同内存顺序读取，造成红蓝通道偏差。
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .medium
            // CGBitmapContext 的首行与 CGImage 首行一致。额外的垂直翻转会把
            // 封面顶部颜色错误地分配给底部泛光，因此直接按原始行序绘制。
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard drewImage else { return nil }

        return CoverGlowPalette(
            topLeading: average(region: .topLeading, pixels: pixels, width: sampleWidth, height: sampleHeight),
            top: average(region: .top, pixels: pixels, width: sampleWidth, height: sampleHeight),
            topTrailing: average(region: .topTrailing, pixels: pixels, width: sampleWidth, height: sampleHeight),
            leading: average(region: .leading, pixels: pixels, width: sampleWidth, height: sampleHeight),
            trailing: average(region: .trailing, pixels: pixels, width: sampleWidth, height: sampleHeight),
            bottomLeading: average(region: .bottomLeading, pixels: pixels, width: sampleWidth, height: sampleHeight),
            bottom: average(region: .bottom, pixels: pixels, width: sampleWidth, height: sampleHeight),
            bottomTrailing: average(region: .bottomTrailing, pixels: pixels, width: sampleWidth, height: sampleHeight)
        )
    }

    nonisolated static func aspectFillCropRect(imageSize: CGSize, targetAspect: CGFloat) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, targetAspect > 0 else { return .zero }
        let sourceAspect = imageSize.width / imageSize.height
        if sourceAspect > targetAspect {
            let cropWidth = imageSize.height * targetAspect
            return CGRect(
                x: (imageSize.width - cropWidth) / 2,
                y: 0,
                width: cropWidth,
                height: imageSize.height
            )
        }
        let cropHeight = imageSize.width / targetAspect
        return CGRect(
            x: 0,
            y: (imageSize.height - cropHeight) / 2,
            width: imageSize.width,
            height: cropHeight
        )
    }

    nonisolated private static func average(
        region: EdgeRegion,
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> CoverGlowColor {
        let thickness = max(2, min(width, height) / 14)
        let firstX = width / 3
        let secondX = width * 2 / 3
        let firstY = height / 3
        let secondY = height * 2 / 3

        var linearRed = 0.0
        var linearGreen = 0.0
        var linearBlue = 0.0
        var totalWeight = 0.0
        for y in 0..<height {
            for x in 0..<width where includes(
                x: x,
                y: y,
                region: region,
                thickness: thickness,
                firstX: firstX,
                secondX: secondX,
                firstY: firstY,
                secondY: secondY,
                width: width,
                height: height
            ) {
                let offset = (y * width + x) * 4
                let alpha = Double(pixels[offset + 3]) / 255
                guard alpha > 0.01 else { continue }
                // CGContext 输出预乘 alpha；先还原通道再在线性光空间加权。
                let red = min(1, Double(pixels[offset]) / 255 / alpha)
                let green = min(1, Double(pixels[offset + 1]) / 255 / alpha)
                let blue = min(1, Double(pixels[offset + 2]) / 255 / alpha)
                linearRed += linearize(red) * alpha
                linearGreen += linearize(green) * alpha
                linearBlue += linearize(blue) * alpha
                totalWeight += alpha
            }
        }
        guard totalWeight > 0 else {
            return CoverGlowColor(red: 0, green: 0, blue: 0, alpha: 0)
        }

        var red = encode(linearRed / totalWeight)
        var green = encode(linearGreen / totalWeight)
        var blue = encode(linearBlue / totalWeight)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let chroma = maximum - minimum

        // 反射光应保留物体本来的色相，只做轻微饱和度补偿与中间调校正。
        // 过强的饱和/伽马会使综合色偏色，尤其容易把肤色推向橙红。
        let saturationGain = 1.12
        red = pow(clamp(luminance + (red - luminance) * saturationGain), 0.96)
        green = pow(clamp(luminance + (green - luminance) * saturationGain), 0.96)
        blue = pow(clamp(luminance + (blue - luminance) * saturationGain), 0.96)

        let brightnessWeight = 0.22 + 0.78 * smoothstep(0.035, 0.52, luminance)
        let colorWeight = 0.62 + 0.38 * smoothstep(0.02, 0.28, chroma)
        return CoverGlowColor(
            red: clamp(red),
            green: clamp(green),
            blue: clamp(blue),
            alpha: clamp(brightnessWeight * colorWeight)
        )
    }

    nonisolated private static func includes(
        x: Int,
        y: Int,
        region: EdgeRegion,
        thickness: Int,
        firstX: Int,
        secondX: Int,
        firstY: Int,
        secondY: Int,
        width: Int,
        height: Int
    ) -> Bool {
        switch region {
        case .topLeading:
            return (y < thickness && x < firstX) || (x < thickness && y < firstY)
        case .top:
            return y < thickness && x >= firstX && x < secondX
        case .topTrailing:
            return (y < thickness && x >= secondX) || (x >= width - thickness && y < firstY)
        case .leading:
            return x < thickness && y >= firstY && y < secondY
        case .trailing:
            return x >= width - thickness && y >= firstY && y < secondY
        case .bottomLeading:
            return (y >= height - thickness && x < firstX)
                || (x < thickness && y >= secondY)
        case .bottom:
            return y >= height - thickness && x >= firstX && x < secondX
        case .bottomTrailing:
            return (y >= height - thickness && x >= secondX)
                || (x >= width - thickness && y >= secondY)
        }
    }

    nonisolated private static func linearize(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    nonisolated private static func encode(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    nonisolated private static func smoothstep(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
        let t = clamp((value - lower) / (upper - lower))
        return t * t * (3 - 2 * t)
    }

    nonisolated private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

struct GalleryCommandActions {
    let read: () -> Void
    let download: () -> Void
    let toggleFavorite: () -> Void
}

private struct GalleryCommandActionsKey: FocusedValueKey {
    typealias Value = GalleryCommandActions
}

extension FocusedValues {
    var galleryCommandActions: GalleryCommandActions? {
        get { self[GalleryCommandActionsKey.self] }
        set { self[GalleryCommandActionsKey.self] = newValue }
    }
}

#if os(macOS)
private enum GalleryAuxiliaryRoute: Identifiable {
    case previews(
        gid: Int64,
        token: String,
        previewPages: Int,
        galleryPages: Int,
        initialPreviewSet: PreviewSet
    )
    case comments(
        gid: Int64,
        token: String,
        apiUid: Int64,
        apiKey: String,
        initialComments: [GalleryComment],
        hasMore: Bool
    )

    var id: Int {
        switch self {
        case .previews: return 0
        case .comments: return 1
        }
    }
}
#endif

struct GalleryDetailView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.responsiveLayout) private var responsiveLayout
    let gallery: GalleryInfo

    @State private var vm = GalleryDetailViewModel()
    @State private var showAllTags = false
    @State private var showRatingSheet = false
    @State private var showFavoritePicker = false
    @State private var showAddTagSheet = false
    @State private var newGalleryTags = ""
    @State private var isCompactHeaderVisible = false
    @State private var coverGlowPalette: CoverGlowPalette?
    @State private var coverGlowSamplingKey: String?
    @State private var linkedCommentGallery: GalleryInfo?
    #if os(macOS)
    @State private var auxiliaryRoute: GalleryAuxiliaryRoute?
    #endif

    /// Deep links and comment links initially carry only gid/token. Once the
    /// detail request completes, prefer its parsed metadata while retaining
    /// any richer fields supplied by the originating list or Handoff payload.
    private var displayInfo: GalleryInfo {
        guard var info = vm.detail?.info else { return gallery }
        if info.title?.isEmpty != false { info.title = gallery.title }
        if info.titleJpn?.isEmpty != false { info.titleJpn = gallery.titleJpn }
        if info.thumb?.isEmpty != false { info.thumb = gallery.thumb }
        if info.uploader?.isEmpty != false { info.uploader = gallery.uploader }
        if info.posted?.isEmpty != false { info.posted = gallery.posted }
        if info.pages == 0 { info.pages = gallery.pages }
        if info.category == .misc, gallery.category != .misc { info.category = gallery.category }
        return info
    }

    /// 标签点击导航动作 — 在 Split/三栏布局中将标签列表推入左侧栏
    @Environment(\.tagNavigationAction) private var tagNavigationAction
    @Environment(\.uploaderSearchNavigationAction) private var uploaderSearchNavigationAction
    @Environment(\.gallerySearchNavigationAction) private var gallerySearchNavigationAction
    @Environment(\.galleryDetailBackAction) private var galleryDetailBackAction
    @Environment(\.readerPresentationAction) private var readerPresentationAction
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #else
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        detailScroll
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(
            galleryDetailBackAction != nil ? .hidden : .visible,
            for: .navigationBar
        )
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        #if os(iOS)
        .fullScreenCover(item: $vm.readerLaunchItem) { item in
            // 全屏呈现阅读器，完全隐藏导航栏
            // item: 绑定保证每次打开都创建全新 ImageReaderView + ReaderViewModel
            ImageReaderView(
                gid: item.gid,
                token: item.token,
                pages: item.pages,
                previewSet: item.previewSet,
                initialPage: item.initialPage
            )
        }
        #endif
        .task(id: gallery.gid) {
            let loadingGID = gallery.gid
            // 画廊 ID 变更时重置 VM 状态并重新加载 (修复 SwiftUI 视图复用 bug)
            vm.reset()
            isCompactHeaderVisible = false
            coverGlowPalette = nil
            coverGlowSamplingKey = nil
            // Detail owns the critical path. My Tags and Spotlight used to
            // compete with its first network request and delayed presentation.
            await vm.loadDetail(gid: loadingGID, token: gallery.token)
            guard !Task.isCancelled else { return }
            async let tagLoad: Void = vm.loadMyTags()
            async let indexing: Void = SystemGalleryIntegration.index(vm.detail?.info ?? gallery)
            _ = await (tagLoad, indexing)
        }
        .userActivity(SystemGalleryIntegration.activityType, isActive: true) { activity in
            SystemGalleryIntegration.configure(activity, gallery: vm.detail?.info ?? gallery)
        }
        .focusedSceneValue(\.galleryCommandActions, GalleryCommandActions(
            read: { openReader() },
            download: { Task { await vm.startDownload(gallery: gallery) } },
            toggleFavorite: toggleFavoriteFromCommand
        ))
        .navigationDestination(item: $linkedCommentGallery) { gallery in
            GalleryDetailView(gallery: gallery)
        }
        #if os(macOS)
        .sheet(item: $auxiliaryRoute) { route in
            auxiliarySheet(for: route)
        }
        #endif
        .sheet(isPresented: $showFavoritePicker) {
            FavoriteSlotPicker(
                onSelect: { slot in
                    showFavoritePicker = false
                    if slot == -1 {
                        Task { await vm.addLocalFavorite(gallery: gallery) }
                    } else {
                        Task { await vm.addFavorite(gid: gallery.gid, token: gallery.token, slot: slot) }
                    }
                },
                onCancel: { showFavoritePicker = false }
            )
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
        }
        .sheet(isPresented: $showRatingSheet) {
            RatingSheet(
                currentRating: vm.displayRating ?? gallery.rating,
                onRate: { rating in
                    Task { await vm.rateGallery(gid: gallery.gid, token: gallery.token, rating: rating) }
                }
            )
            .presentationDetents([.height(200)])
        }
        .sheet(isPresented: $showAddTagSheet) {
            AddGalleryTagsSheet(
                text: $newGalleryTags,
                isSubmitting: vm.isUpdatingTags,
                onCancel: {
                    newGalleryTags = ""
                    showAddTagSheet = false
                },
                onSubmit: submitNewGalleryTags
            )
            #if os(iOS)
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            #endif
        }
        .alert("标签操作失败", isPresented: Binding(
            get: { vm.tagErrorMessage != nil },
            set: { if !$0 { vm.tagErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) { vm.tagErrorMessage = nil }
        } message: {
            Text(vm.tagErrorMessage ?? "未知错误")
        }
    }

    private var detailScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The expanded header participates in normal scroll layout.
                // Only the compact replacement is overlaid after this section
                // has mostly left the viewport, avoiding a dynamic-height
                // feedback loop between contentOffset and pinned content.
                headerSection
                Divider()
                actionBar
                Divider()
                detailContent
                    .padding(.horizontal, portraitTabletContentInset)
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // macOS reports the untouched content offset above zero by the
            // transparent titlebar/safe-area inset. Normalize that baseline so
            // the collapse distance reflects the user's actual scrolling. The UI
            // only needs the threshold state, not a mutation for every scroll pixel.
            max(0, geometry.contentOffset.y + geometry.contentInsets.top) >= 240
        } action: { _, isVisible in
            isCompactHeaderVisible = isVisible
        }
        .overlay(alignment: .top) {
            if isCompactHeaderVisible {
                compactHeader
                    // A single, bounded glass surface provides both the lens
                    // and its continuous rounded edge. Never refract through a
                    // zero-radius rectangle extended behind the safe area.
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -8)))
                    .zIndex(10)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: isCompactHeaderVisible)
    }

    private var portraitTabletContentInset: CGFloat {
        responsiveLayout.horizontalSizeClass == .regular
            && (responsiveLayout.height > responsiveLayout.width
                || AppSettings.shared.wideScreenListMode == 1) ? 12 : 0
    }

    @ViewBuilder
    private var detailContent: some View {
                if vm.isLoading {
                    ProgressView("加载详情...")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if let error = vm.errorMessage {
                    errorSection(error)
                } else {
                    if !vm.tags.isEmpty {
                        tagSection
                        Divider()
                    }
                    // 评论在预览图之前（对齐 Android 布局）
                    // 对齐 Android GalleryDetailScene: Settings.getShowGalleryComment() 控制显示
                    if AppSettings.shared.showGalleryComment {
                        commentSection
                    }
                    if let previewSet = vm.previewSet, !previewSet.isEmpty {
                        previewSection(previewSet)
                    }
                }
    }

    private func toggleFavoriteFromCommand() {
        if vm.isFavorited {
            Task { await vm.removeFavorite(gid: gallery.gid, token: gallery.token) }
        } else {
            let defaultSlot = AppSettings.shared.defaultFavSlot
            if (0...9).contains(defaultSlot) {
                Task { await vm.addFavorite(gid: gallery.gid, token: gallery.token, slot: defaultSlot) }
            } else {
                showFavoritePicker = true
            }
        }
    }

    private func openReader(initialPage: Int? = nil) {
        let item = ReaderLaunchItem(
            gid: gallery.gid,
            token: gallery.token,
            pages: vm.detail?.info.pages ?? gallery.pages,
            previewSet: vm.detail?.previewSet,
            initialPage: initialPage
        )
        #if os(macOS)
        openWindow(value: ReaderWindowRoute(
            gid: item.gid,
            token: item.token,
            pages: item.pages,
            previewSet: item.previewSet,
            initialPage: item.initialPage
        ))
        #else
        let route = ReaderWindowRoute(
            gid: item.gid,
            token: item.token,
            pages: item.pages,
            previewSet: item.previewSet,
            initialPage: item.initialPage
        )
        if let readerPresentationAction {
            readerPresentationAction.present(route)
        } else {
            vm.readerLaunchItem = item
        }
        #endif
    }

    // MARK: - Header

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            inlineDetailBackButton(style: .light)

            HStack(alignment: .top, spacing: 12) {
                detailCover(width: 64, height: 90, cornerRadius: 7, glowStrength: 0.80)
                    .frame(width: 72, height: 98)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayInfo.suitableTitle(preferJpn: AppSettings.shared.showJpnTitle))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .textSelection(.enabled)

                    if let uploader = displayInfo.uploader {
                        uploaderLink(uploader, compact: true)
                    }

                    HStack(spacing: 8) {
                        Text(displayInfo.category.name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(displayInfo.category.color, in: Capsule())

                        if AppSettings.shared.showGalleryRating {
                            Text(String(format: "%.1f", vm.displayRating ?? gallery.rating))
                                .foregroundStyle(.orange)
                                .accessibilityLabel("评分 \(String(format: "%.1f", vm.displayRating ?? gallery.rating))")
                        }

                        if let language = vm.language {
                            Text(compactLanguageLabel(language))
                                .lineLimit(1)
                                .accessibilityLabel("语言 \(language)")
                        }

                        if AppSettings.shared.showGalleryPages {
                            Text("\(displayInfo.pages)p")
                                .accessibilityLabel("\(displayInfo.pages) 页")
                        }

                        Label(vm.favoriteCount.formatted(), systemImage: "heart")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 7) {
                        compactActionButton(icon: "book", help: AppLocalization.localized(vm.hasReadingProgress ? "继续阅读" : "阅读")) {
                            openReader()
                        }
                        compactActionButton(icon: vm.isFavorited ? "heart.fill" : "heart", help: "收藏") {
                            performFavoriteAction()
                        }
                        compactActionButton(icon: vm.downloadIcon, help: vm.downloadTitle) {
                            if vm.downloadState == DownloadManager.stateFinish {
                                openReader()
                            } else {
                                Task { await vm.startDownload(gallery: gallery) }
                            }
                        }
                        GalleryShareLink(urlString: GalleryActionService.shared.galleryURL(
                            gid: gallery.gid,
                            token: gallery.token
                        ), title: gallery.suitableTitle(preferJpn: AppSettings.shared.showJpnTitle)) {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: compactActionSize, height: compactActionSize)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("分享")
                        .accessibilityLabel("分享")
                    }
                }
                .padding(.top, 2)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 108)
    }

    private var compactActionSize: CGFloat {
        #if os(iOS)
        44
        #else
        27
        #endif
    }

    private func compactActionButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: compactActionSize, height: compactActionSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(AppLocalization.localized(help))
    }

    @ViewBuilder
    private func inlineDetailBackButton(style: AppBackButton.Style = .light) -> some View {
        if let galleryDetailBackAction {
            AppBackButton(action: galleryDetailBackAction.perform, style: style)
                .help("返回信息流")
                .accessibilityIdentifier("gallery.detail.back")
        }
    }

    private func compactLanguageLabel(_ language: String) -> String {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases: [(tokens: [String], code: String)] = [
            (["chinese", "中文", "汉语", "漢語"], "ZH"),
            (["english", "英语", "英語"], "EN"),
            (["japanese", "日语", "日語"], "JA"),
            (["korean", "韩语", "韓語"], "KO"),
            (["spanish", "西班牙语", "西班牙語"], "ES"),
            (["french", "法语", "法語"], "FR"),
            (["german", "德语", "德語"], "DE"),
            (["russian", "俄语", "俄語"], "RU")
        ]
        if let match = aliases.first(where: { entry in
            entry.tokens.contains { normalized.contains($0.lowercased()) }
        }) {
            return match.code
        }
        return String(language.prefix(3)).uppercased()
    }

    @ViewBuilder
    private func uploaderLink(_ uploader: String, compact: Bool) -> some View {
        let query = uploaderSearchQuery(uploader)
        if let gallerySearchNavigationAction {
            Button {
                gallerySearchNavigationAction.searchFromGallery(query, gallery)
            } label: {
                uploaderLabel(uploader, compact: compact)
            }
            .buttonStyle(.plain)
            .help("搜索上传者 \(uploader)")
        } else if let searchNavigation = uploaderSearchNavigationAction {
            Button {
                searchNavigation.navigate(query)
            } label: {
                uploaderLabel(uploader, compact: compact)
            }
            .buttonStyle(.plain)
            .help("搜索上传者 \(uploader)")
        } else {
            NavigationLink {
                GalleryListView(mode: .search(keyword: query), isPushed: true)
            } label: {
                uploaderLabel(uploader, compact: compact)
            }
            .buttonStyle(.plain)
        }
    }

    private func uploaderLabel(_ uploader: String, compact: Bool) -> some View {
        Label(uploader, systemImage: "person")
            .font(compact ? .caption : .subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentShape(Rectangle())
    }

    private func uploaderSearchQuery(_ uploader: String) -> String {
        let escaped = uploader.replacingOccurrences(of: "\"", with: "\\\"")
        return "uploader:\"\(escaped)\""
    }

    private func performFavoriteAction() {
        if vm.isFavorited {
            Task { await vm.removeFavorite(gid: gallery.gid, token: gallery.token) }
            return
        }

        let defaultSlot = AppSettings.shared.defaultFavSlot
        if defaultSlot == -1 {
            Task { await vm.addLocalFavorite(gallery: gallery) }
        } else if (0...9).contains(defaultSlot) {
            Task { await vm.addFavorite(gid: gallery.gid, token: gallery.token, slot: defaultSlot) }
        } else {
            showFavoritePicker = true
        }
    }

    private func detailCover(
        width: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat,
        glowStrength: Double
    ) -> some View {
        let coverURL = ThumbnailURLResolver.url(
            for: displayInfo.thumb,
            fixLegacy: AppSettings.shared.fixThumbUrl,
            site: AppSettings.shared.gallerySite
        )
        let cover = CachedAsyncImage(
            url: coverURL,
            onImageLoaded: { image in
                updateCoverGlow(
                    from: image,
                    url: coverURL,
                    targetAspect: width / height
                )
            }
        ) { img in
            ZStack {
                if let coverGlowPalette, glowStrength > 0.01 {
                    directionalCoverGlow(
                        palette: coverGlowPalette,
                        width: width,
                        height: height,
                        strength: glowStrength
                    )
                    .transition(.opacity)
                }

                img
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .shadow(
                        color: coverShadowColor(for: coverGlowPalette),
                        radius: max(5, width * 0.09),
                        y: max(3, width * 0.05)
                    )
            }
        } placeholder: {
            Color(.secondarySystemBackground)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        // 为扩散层预留真实绘制空间，避免外沿被父布局过早裁切。
        .frame(width: width * 1.96, height: height * 1.70)

        return Button {
            Haptics.tap()
        } label: {
            cover
        }
        .buttonStyle(ElasticCoverButtonStyle())
        .accessibilityLabel("画廊封面")
    }

    private func directionalCoverGlow(
        palette: CoverGlowPalette,
        width: CGFloat,
        height: CGFloat,
        strength: Double
    ) -> some View {
        let renderedPalette = colorScheme == .light
            ? palette.adaptedForLightBackground()
            : palette
        let field = coverLightField(renderedPalette)
        let shape = RoundedRectangle(cornerRadius: max(2, width * 0.067), style: .continuous)
        let accessibilityFactor = reduceTransparency ? 0.55 : 1.0
        let farOpacity = (colorScheme == .light ? 0.42 : 0.36) * accessibilityFactor
        let middleOpacity = (colorScheme == .light ? 0.54 : 0.48) * accessibilityFactor
        let nearOpacity = (colorScheme == .light ? 0.34 : 0.30) * accessibilityFactor
        return ZStack {
            // 三个同源连续色场组成高斯混合衰减：近层建立接触色，中层
            // 承担主要反射，远层用更低密度延伸尾部。各层没有硬边，叠加后
            // 从封面向背景的 alpha 曲线连续，避免两级模糊交界处的视觉台阶。
            shape
                .fill(field)
                .frame(width: width * 1.04, height: height * 1.025)
                .blur(radius: max(22, width * 0.48))
                .opacity(strength * farOpacity)

            shape
                .fill(field)
                .frame(width: width, height: height)
                .blur(radius: max(12, width * 0.25))
                .opacity(strength * middleOpacity)

            shape
                .fill(field)
                .frame(width: width * 0.99, height: height * 0.99)
                .blur(radius: max(5, width * 0.105))
                .opacity(strength * nearOpacity)
        }
        .allowsHitTesting(false)
    }

    /// The cover hides the centre of this field, so a conic interpolation can
    /// map every sampled edge directly to the corresponding outer direction.
    /// Unlike MeshGradient this uses the system's long-established gradient
    /// pipeline and avoids compiling a mesh shader during the first detail
    /// presentation.
    private func coverLightField(_ palette: CoverGlowPalette) -> AngularGradient {
        AngularGradient(
            colors: [
                palette.trailing.color,
                palette.bottomTrailing.color,
                palette.bottom.color,
                palette.bottomLeading.color,
                palette.leading.color,
                palette.topLeading.color,
                palette.top.color,
                palette.topTrailing.color,
                palette.trailing.color,
            ],
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360)
        )
    }

    /// 浅色封面在浅色背景中使用低对比度的彩色接触阴影；深色封面仍保留
    /// 足够深的投影。泛光负责色彩反射，接触阴影只负责建立悬浮层次。
    private func coverShadowColor(for palette: CoverGlowPalette?) -> Color {
        guard colorScheme == .light else { return .black.opacity(0.24) }
        guard let average = palette?.averageColor else { return .black.opacity(0.12) }

        if average.luminance > 0.58 {
            let reflected = average.adaptedForLightBackground()
            return Color(
                .sRGB,
                red: reflected.red,
                green: reflected.green,
                blue: reflected.blue,
                opacity: 0.16
            )
        }
        return Color(
            .sRGB,
            red: average.red * 0.45,
            green: average.green * 0.45,
            blue: average.blue * 0.45,
            opacity: 0.27
        )
    }

    private func updateCoverGlow(
        from image: PlatformImage,
        url: URL?,
        targetAspect: CGFloat
    ) {
        let key = "\(url?.absoluteString ?? String(gallery.gid))#\(Int((targetAspect * 10_000).rounded()))"
        guard coverGlowSamplingKey != key,
              let cgImage = coverCGImage(from: image) else { return }
        coverGlowSamplingKey = key
        coverGlowPalette = nil

        Task { @MainActor in
            let palette = await CoverGlowPaletteCache.shared.palette(
                for: key,
                image: SendableCGImage(value: cgImage),
                targetAspect: targetAspect
            )
            guard coverGlowSamplingKey == key else { return }
            if reduceMotion {
                coverGlowPalette = palette
            } else {
                withAnimation(.easeOut(duration: 0.32)) {
                    coverGlowPalette = palette
                }
            }
        }
    }

    private func coverCGImage(from image: PlatformImage) -> CGImage? {
        #if os(macOS)
        var proposedRect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    private var headerSection: some View {
        let coverWidth: CGFloat = usesCompactDetailMetrics ? 112 : 120
        let coverHeight: CGFloat = usesCompactDetailMetrics ? 157 : 168
        return VStack(alignment: .leading, spacing: 10) {
            inlineDetailBackButton(style: .light)

            HStack(alignment: .top, spacing: 14) {
                detailCover(
                    width: coverWidth,
                    height: coverHeight,
                    cornerRadius: 8,
                    // 紧凑标题出现后，完整标题已离开视口；停止其昂贵的模糊层，
                    // 避免同时渲染两套 MeshGradient。
                    glowStrength: isCompactHeaderVisible ? 0 : 0.94
                )
                .frame(width: coverWidth + 12, height: coverHeight + 12)

                VStack(alignment: .leading, spacing: 6) {
                // 根据设置显示日文/中文或英文标题 (对齐 Android EhUtils.getSuitableTitle)
                Text(displayInfo.suitableTitle(preferJpn: AppSettings.shared.showJpnTitle))
                    .font(.headline)
                    .lineLimit(4)
                    .textSelection(.enabled)

                if let uploader = displayInfo.uploader {
                    uploaderLink(uploader, compact: false)
                }

                Spacer(minLength: 0)

                // 分类标签
                Text(displayInfo.category.name)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(displayInfo.category.color)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // 评分 (可点击)
                if AppSettings.shared.showGalleryRating {
                    HStack(spacing: 4) {
                        ForEach(0..<5) { i in
                            Image(systemName: ratingIcon(index: i, rating: vm.displayRating ?? gallery.rating))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text(String(format: "%.2f", vm.displayRating ?? gallery.rating))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        if vm.canRate {
                            showRatingSheet = true
                        }
                    }
                }

                // 详情信息
                if let lang = vm.language {
                    Label(lang, systemImage: "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                if let posted = displayInfo.posted, !posted.isEmpty {
                    Label(
                        GalleryTimestamp.localizedString(fromServerText: posted),
                        systemImage: "clock"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                }
                HStack(spacing: 12) {
                    if AppSettings.shared.showGalleryPages {
                        Label(
                            usesCompactDetailMetrics ? "\(displayInfo.pages)p" : "\(displayInfo.pages) 页",
                            systemImage: "doc"
                        )
                    }
                    if let size = vm.size {
                        Label(size, systemImage: "internaldrive")
                    }
                    Label(
                        usesCompactDetailMetrics
                            ? vm.favoriteCount.formatted()
                            : "\(vm.favoriteCount.formatted()) 人收藏",
                        systemImage: "heart"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                }
            }
        }
        .padding()
    }

    private var usesCompactDetailMetrics: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            let readTitle = AppLocalization.localized(vm.hasReadingProgress ? "继续阅读" : "阅读")
            actionButton(icon: "book", title: readTitle) {
                Haptics.tap()
                // 对齐 Android: 阅读按钮不传 KEY_PAGE，让阅读器自行恢复进度
                openReader()
            }
            Divider().frame(height: 32)
            actionButton(icon: vm.isFavorited ? "heart.fill" : "heart",
                         title: AppLocalization.localized(vm.isFavorited ? "已收藏" : "收藏"),
                         action: {
                Haptics.impact()
                if vm.isFavorited {
                    Task { await vm.removeFavorite(gid: gallery.gid, token: gallery.token) }
                } else {
                    let defaultSlot = AppSettings.shared.defaultFavSlot
                    if defaultSlot == -1 {
                        Task { await vm.addLocalFavorite(gallery: gallery) }
                    } else if defaultSlot >= 0 && defaultSlot <= 9 {
                        Task { await vm.addFavorite(gid: gallery.gid, token: gallery.token, slot: defaultSlot) }
                    } else {
                        showFavoritePicker = true
                    }
                }
            },
            // 对齐 Android: 长按收藏按钮始终弹出收藏夹选择，即使已设置默认
            longPressAction: {
                showFavoritePicker = true
            })
            Divider().frame(height: 32)
            actionButton(icon: vm.downloadIcon,
                         title: vm.downloadTitle) {
                // Fix F1-4: 已下载状态 → 打开阅读器，不是重新下载
                if vm.downloadState == DownloadManager.stateFinish {
                    Haptics.tap()
                    openReader()
                } else {
                    Haptics.impact()
                    Task { await vm.startDownload(gallery: gallery) }
                }
            }
            Divider().frame(height: 32)
            GalleryShareLink(urlString: GalleryActionService.shared.galleryURL(
                gid: gallery.gid,
                token: gallery.token
            ), title: gallery.suitableTitle(preferJpn: AppSettings.shared.showJpnTitle)) {
                actionButtonLabel(icon: "square.and.arrow.up", title: AppLocalization.localized("分享"))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func actionButton(
        icon: String,
        title: String,
        action: @escaping () -> Void,
        longPressAction: (() -> Void)? = nil
    ) -> some View {
        if let longPressAction {
            baseActionButton(icon: icon, title: title, action: action)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in longPressAction() }
                )
        } else {
            baseActionButton(icon: icon, title: title, action: action)
        }
    }

    private func baseActionButton(
        icon: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            actionButtonLabel(icon: icon, title: title)
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
    }

    private func actionButtonLabel(icon: String, title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
            Text(title)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Tags

    private var tagSection: some View {
        let showTranslations = AppSettings.shared.showTagTranslations
        let tagDb = EhTagDatabase.shared

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("标签")
                    .font(.headline)

                Spacer()

                Button {
                    vm.tagErrorMessage = nil
                    showAddTagSheet = true
                } label: {
                    Label("新增标签", systemImage: "plus")
                        .font(.caption.weight(.medium))
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(vm.isUpdatingTags)
            }
                .padding(.horizontal)
                .padding(.top, 12)

            ForEach(vm.tags, id: \.groupName) { group in
                HStack(alignment: .top, spacing: 8) {
                    // 翻译 namespace (对齐 Android: ehTags.getTranslation("n:" + groupName))
                    // 注意：Android使用 "n:" 前缀表示rows命名空间的翻译
                    let nsKey = "rows:\(group.groupName)"
                    let nsTranslation = showTranslations ? tagDb.getTranslation(nsKey) : nil
                    Text(nsTranslation ?? group.groupName)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                        // 与胶囊标签内部文字使用相同的顶部内边距，
                        // 避免 namespace 看起来比第一行标签高半行。
                        .padding(.vertical, 3)

                    FlowLayout(spacing: 4) {
                        ForEach(group.tags, id: \.self) { tag in
                            // 翻译 tag (对齐 Android: ehTags.getTranslation(namespace:tag))
                            let fullTag = "\(group.groupName):\(tag)"
                            let tagTranslation = showTranslations ? tagDb.getTranslation(fullTag) : nil
                            // 对齐 Android: onTagClick → 推入新画廊列表到左侧导航栈
                            tagButton(label: tagTranslation ?? tag, fullTag: fullTag)
                        }
                    }
                }
                .padding(.horizontal)
            }

            // 调试信息：提示用户下载标签数据库
            if showTranslations && !tagDb.isLoaded {
                Text("请在设置中更新标签翻译数据库")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom, 12)
    }

    /// 标签按钮 — Split/三栏布局: 推入左侧导航栈; iPhone compact: NavigationLink 推入当前栈
    @ViewBuilder
    private func tagButton(label: String, fullTag: String) -> some View {
        let isMyTag = vm.isMyTag(fullTag)
        let voteStatus = vm.tagVoteStatus(fullTag)
        if let gallerySearchNavigationAction {
            Button {
                gallerySearchNavigationAction.searchFromGallery(fullTag, gallery)
            } label: {
                tagLabel(label, isMyTag: isMyTag, voteStatus: voteStatus)
            }
            .buttonStyle(.plain)
            .contextMenu {
                tagContextMenu(label: label, fullTag: fullTag, voteStatus: voteStatus)
            }
        } else if let tagNav = tagNavigationAction {
            // iPad/macOS Split 布局: 用 Button 推入左侧 content/sidebar 列的 NavigationStack
            Button {
                tagNav.navigate(fullTag)
            } label: {
                tagLabel(label, isMyTag: isMyTag, voteStatus: voteStatus)
            }
            .buttonStyle(.plain)
            .contextMenu {
                tagContextMenu(label: label, fullTag: fullTag, voteStatus: voteStatus)
            }
        } else {
            // iPhone compact: NavigationLink 推入同一 NavigationStack
            NavigationLink {
                GalleryListView(mode: .tag(keyword: fullTag), isPushed: true)
            } label: {
                tagLabel(label, isMyTag: isMyTag, voteStatus: voteStatus)
            }
            .buttonStyle(.plain)
            .contextMenu {
                tagContextMenu(label: label, fullTag: fullTag, voteStatus: voteStatus)
            }
        }
    }

    @ViewBuilder
    private func tagContextMenu(
        label: String,
        fullTag: String,
        voteStatus: GalleryTagVoteStatus
    ) -> some View {
        switch voteStatus {
        case .none:
            Button {
                submitTagVote(fullTag, vote: 1)
            } label: {
                Label("赞同标签", systemImage: "hand.thumbsup")
            }
            .disabled(vm.isUpdatingTag(fullTag))

            Button {
                submitTagVote(fullTag, vote: -1)
            } label: {
                Label("反对标签", systemImage: "hand.thumbsdown")
            }
            .disabled(vm.isUpdatingTag(fullTag))
        case .up:
            Button {
                // EH 使用相反方向的投票撤回标签投票。
                submitTagVote(fullTag, vote: -1)
            } label: {
                Label("撤回标签赞同", systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(vm.isUpdatingTag(fullTag))
        case .down:
            Button {
                submitTagVote(fullTag, vote: 1)
            } label: {
                Label("撤回标签反对", systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(vm.isUpdatingTag(fullTag))
        }

        Divider()

        if AppSettings.shared.isTagBlocked(fullTag) {
            Button {
                AppSettings.shared.unblockTag(fullTag)
            } label: {
                Label("取消屏蔽此标签", systemImage: "eye")
            }
        } else {
            Button(role: .destructive) {
                AppSettings.shared.blockTag(fullTag)
            } label: {
                Label("屏蔽此标签", systemImage: "eye.slash")
            }
        }

        Button {
            let wikiTitle = fullTag.split(separator: ":", maxSplits: 1).last.map(String.init) ?? fullTag
            if let encodedTitle = wikiTitle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "https://ehwiki.org/wiki/\(encodedTitle)") {
                openURL(url)
            }
        } label: {
            Label("在 EHWiki 检视定义", systemImage: "book")
        }

        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fullTag, forType: .string)
            #else
            UIPasteboard.general.string = fullTag
            #endif
        } label: {
            Label("拷贝标签文本", systemImage: "doc.on.doc")
        }
    }

    private func tagLabel(
        _ text: String,
        isMyTag: Bool,
        voteStatus: GalleryTagVoteStatus
    ) -> some View {
        HStack(spacing: 3) {
            Text(text)

            if voteStatus != .none {
                Image(systemName: voteStatus == .up ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
            .font(.caption)
            .foregroundStyle(isMyTag ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isMyTag
                    ? Color.accentColor.opacity(0.12)
                    : Color(.tertiarySystemFill)
            )
            .clipShape(Capsule())
            .overlay {
                if isMyTag {
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.28), lineWidth: 0.75)
                }
            }
    }

    private func submitTagVote(_ fullTag: String, vote: Int) {
        Task {
            await vm.voteTag(
                fullTag,
                vote: vote,
                gid: gallery.gid,
                token: gallery.token
            )
        }
    }

    private func submitNewGalleryTags() {
        let tags = newGalleryTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        guard !tags.isEmpty else { return }

        Task {
            if await vm.addTags(tags, gid: gallery.gid, token: gallery.token) {
                newGalleryTags = ""
                showAddTagSheet = false
            }
        }
    }

    // MARK: - Previews (对齐 Android: 使用网格布局显示预览)

    private func previewSection(_ previewSet: PreviewSet) -> some View {
        // 预览图宽度固定，具体高度按每张预览的原始比例计算。
        let previewWidth: CGFloat = 100
        let columns = [GridItem(.adaptive(minimum: previewWidth, maximum: previewWidth + 20), spacing: 8)]
        
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("预览")
                    .font(.headline)
                Spacer()
                // 查看全部预览按钮
                if vm.previewPages > 1 {
                    #if os(macOS)
                    Button {
                        auxiliaryRoute = .previews(
                            gid: gallery.gid,
                            token: gallery.token,
                            previewPages: vm.previewPages,
                            galleryPages: vm.detail?.info.pages ?? gallery.pages,
                            initialPreviewSet: previewSet
                        )
                    } label: {
                        Text("查看全部 (\(vm.detail?.info.pages ?? gallery.pages)张)")
                            .font(.subheadline)
                    }
                    #else
                    NavigationLink {
                        GalleryPreviewsView(
                            gid: gallery.gid,
                            token: gallery.token,
                            totalPages: vm.previewPages,
                            galleryPages: vm.detail?.info.pages ?? gallery.pages,
                            initialPreviewSet: previewSet
                        )
                    } label: {
                        Text("查看全部 (\(vm.detail?.info.pages ?? gallery.pages)张)")
                            .font(.subheadline)
                    }
                    #endif
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // 网格布局预览 (对齐 Android: AutoGridLayoutManager 网格布局)
            LazyVGrid(columns: columns, spacing: 12) {
                switch previewSet {
                case .large(let items):
                    ForEach(items.sorted(by: { $0.position < $1.position }), id: \.position) { preview in
                        VStack(spacing: 4) {
                            OriginalRatioPreviewImage(
                                url: URL(string: preview.imageUrl),
                                width: previewWidth,
                                cornerRadius: 4
                            )
                            .onTapGesture {
                                // 对齐 Android: intent.putExtra(GalleryActivity.KEY_PAGE, index)
                                openReader(initialPage: preview.position)
                            }
                            
                            // 页码标签 (对齐 Android: position + 1)
                            Text("\(preview.position + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        .previewHoverLift()
                        .previewOriginalImageActions(
                            gid: gallery.gid,
                            token: gallery.token,
                            pages: vm.detail?.info.pages ?? gallery.pages,
                            previewSet: previewSet,
                            page: preview.position
                        )
                    }
                case .normal(let items):
                    ForEach(items.sorted(by: { $0.position < $1.position }), id: \.position) { preview in
                        VStack(spacing: 4) {
                            SpritePreviewView(preview: preview)
                                .frame(
                                    width: previewWidth,
                                    height: previewWidth / preview.previewAspectRatio
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .onTapGesture {
                                    // 对齐 Android: intent.putExtra(GalleryActivity.KEY_PAGE, index)
                                    openReader(initialPage: preview.position)
                                }
                            
                            // 页码标签
                            Text("\(preview.position + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        .previewHoverLift()
                        .previewOriginalImageActions(
                            gid: gallery.gid,
                            token: gallery.token,
                            pages: vm.detail?.info.pages ?? gallery.pages,
                            previewSet: previewSet,
                            page: preview.position
                        )
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 12)
    }

    // MARK: - Comments (对齐 Android: 默认显示前2条评论，每条最多5行)

    private var commentSection: some View {
        let maxShowCount = 2 // Android: maxShowCount = 2
        let displayComments = Array(vm.processedComments.prefix(maxShowCount))
        let hasMore = vm.processedComments.count > maxShowCount || vm.hasMoreComments
        
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("评论（\(vm.totalCommentsText)）")
                    .font(.headline)
                Spacer()
                // 即使评论不多也保持入口可见，用户可从这里发表评论。
                #if os(macOS)
                Button(AppLocalization.localized(hasMore ? "更多评论" : "发表评论")) {
                    auxiliaryRoute = .comments(
                        gid: gallery.gid,
                        token: gallery.token,
                        apiUid: vm.detail?.apiUid ?? -1,
                        apiKey: vm.detail?.apiKey ?? "",
                        initialComments: vm.comments,
                        hasMore: vm.hasMoreComments
                    )
                }
                .font(.subheadline)
                #else
                NavigationLink {
                    GalleryCommentsView(
                        gid: gallery.gid,
                        token: gallery.token,
                        apiUid: vm.detail?.apiUid ?? -1,
                        apiKey: vm.detail?.apiKey ?? "",
                        initialComments: vm.comments,
                        hasMore: vm.hasMoreComments,
                        onCommentsChange: vm.replaceComments
                    )
                } label: {
                    Text(AppLocalization.localized(hasMore ? "更多评论" : "发表评论"))
                        .font(.subheadline)
                }
                #endif
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if displayComments.isEmpty {
                Text("暂无评论")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(displayComments) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(comment.user)
                                .font(.subheadline.bold())
                            Spacer()
                            Text(GalleryTimestamp.localizedString(from: comment.time))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if comment.score != 0 {
                                Text(comment.score > 0 ? "+\(comment.score)" : "\(comment.score)")
                                    .font(.caption2)
                                    .foregroundStyle(comment.score > 0 ? .green : .red)
                            }
                        }
                        // Perf P0-4: 使用预处理的纯文本，避免 body 内正则计算
                        Text(comment.attributedBody)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(5) // Android: setMaxLines(5)
                            .textSelection(.enabled)
                            .environment(\.openURL, OpenURLAction { url in
                                guard let gallery = GalleryCommentLinks.gallery(from: url) else {
                                    return .systemAction
                                }
                                linkedCommentGallery = gallery
                                return .handled
                            })
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: - Error

    private func errorSection(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
            Button("重试") {
                Task { await vm.loadDetail(gid: gallery.gid, token: gallery.token) }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Helpers

    private func ratingIcon(index: Int, rating: Float) -> String {
        let fill = rating - Float(index)
        if fill >= 1.0 { return "star.fill" }
        if fill >= 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }

    #if os(macOS)
    @ViewBuilder
    private func auxiliarySheet(for route: GalleryAuxiliaryRoute) -> some View {
        let isPreviews = if case .previews = route { true } else { false }
        // Keep the larger preview sheet inside the usable desktop, including
        // menu bar/Dock space on smaller Mac screens. Comments keep their size.
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 900)
        let previewWidth = min(940, max(620, available.width - 100))
        let previewHeight = min(680, max(430, available.height - 140))
        NavigationStack {
            Group {
                switch route {
                case let .previews(gid, token, previewPages, galleryPages, previewSet):
                    GalleryPreviewsView(
                        gid: gid,
                        token: token,
                        totalPages: previewPages,
                        galleryPages: galleryPages,
                        initialPreviewSet: previewSet
                    )

                case let .comments(gid, token, apiUid, apiKey, comments, hasMore):
                    GalleryCommentsView(
                        gid: gid,
                        token: token,
                        apiUid: apiUid,
                        apiKey: apiKey,
                        initialComments: comments,
                        hasMore: hasMore,
                        onCommentsChange: vm.replaceComments,
                        onClose: { auxiliaryRoute = nil }
                    )
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if case .previews = route {
                Button {
                    auxiliaryRoute = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
                .padding(16)
                .help("关闭")
            }
        }
        .frame(
            minWidth: isPreviews ? min(720, previewWidth) : 620,
            idealWidth: isPreviews ? previewWidth : 720,
            minHeight: isPreviews ? min(500, previewHeight) : 430,
            idealHeight: isPreviews ? previewHeight : 540
        )
    }
    #endif
}

// MARK: - ViewModel

@MainActor
/// 阅读器启动参数 — 使用 item: 绑定确保每次打开阅读器都创建全新视图
struct ReaderLaunchItem: Identifiable {
    let id = UUID()  // 每次启动生成新 ID，保证 SwiftUI 创建新视图
    let gid: Int64
    let token: String
    let pages: Int
    let previewSet: PreviewSet?
    let initialPage: Int?
}

@MainActor @Observable
class GalleryDetailViewModel {
    var isLoading = false
    var errorMessage: String?
    var tagErrorMessage: String?
    var detail: GalleryDetail?
    var isFavorited = false
    var downloadState: Int = DownloadManager.stateInvalid
    /// 阅读器启动项 — 非 nil 时弹出阅读器 (item: 绑定确保视图完全重建)
    var readerLaunchItem: ReaderLaunchItem? = nil
    var displayRating: Float?
    var isLoadingComments = false
    /// Perf P0-5: 一次性读取阅读进度，避免 body 中读 UserDefaults
    var hasReadingProgress = false
    /// Perf P0-4: 预处理后的评论 (HTML 已剥离，避免 body 中执行 regex)
    var processedComments: [ProcessedComment] = []
    /// 当前站点“我的标签”，用于详情页的低对比度主题色提示。
    var myTagNames: Set<String> = []
    /// 正在提交的标签。Set 同时防止重复点击造成相互抵消的请求。
    var updatingTags: Set<String> = []
    var isUpdatingTags: Bool { !updatingTags.isEmpty }
    /// Fix F3-4: 下载状态轮询任务
    @ObservationIgnored
    var downloadPollingTask: Task<Void, Never>?
    /// 每次详情加载的唯一代次。页面切换会使旧请求失去写入资格，即使底层
    /// URLSession 或解析阶段没有及时响应取消也不会污染新页面。
    @ObservationIgnored
    private var detailLoadGeneration = UUID()

    private static var cachedMyTagSite: EhSite?
    private static var cachedMyTagNames: Set<String> = []
    private static var cachedMyTagDate: Date?

    // MARK: - Processed Comment (Perf P0-4)

    /// 预处理后的评论结构体 — 在 loadDetail 成功后后台计算
    nonisolated struct ProcessedComment: Identifiable, Sendable {
        let id: Int64
        let user: String
        let time: Date
        let score: Int
        let attributedBody: AttributedString
    }

    /// 预编译正则 (避免每次调用都重新编译)
    private static let htmlTagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "<[^>]+>", options: [])
    }()

    /// 从 HTML 中剥离标签 — 使用预编译正则
    private static func stripHTML(_ html: String) -> String {
        guard let regex = htmlTagRegex else {
            return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "")
    }

    // 从 GalleryDetail 导出的便捷属性
    var tags: [GalleryTagGroup] { detail?.tags ?? [] }
    var previewSet: PreviewSet? { detail?.previewSet }
    var previewPages: Int { detail?.previewPages ?? 0 }
    var comments: [GalleryComment] { detail?.comments.comments ?? [] }
    var hasMoreComments: Bool { detail?.comments.hasMore ?? false }
    var totalCommentsText: String {
        let count = comments.count
        if hasMoreComments {
            return "\(count)+"
        }
        return "\(count)"
    }
    var language: String? { detail?.language }
    var size: String? { detail?.size }
    var favoriteCount: Int { detail?.favoriteCount ?? 0 }
    var canRate: Bool { detail?.apiUid ?? -1 > 0 && !(detail?.apiKey.isEmpty ?? true) }

    deinit {
        downloadPollingTask?.cancel()
    }

    /// 重置所有状态，准备加载新画廊 (修复 SwiftUI 视图复用导致显示旧数据的问题)
    func reset() {
        detailLoadGeneration = UUID()
        downloadPollingTask?.cancel()
        downloadPollingTask = nil
        isLoading = false
        errorMessage = nil
        tagErrorMessage = nil
        detail = nil
        isFavorited = false
        downloadState = DownloadManager.stateInvalid
        readerLaunchItem = nil
        displayRating = nil
        isLoadingComments = false
        hasReadingProgress = false
        processedComments = []
        myTagNames = []
        updatingTags = []
    }

    func loadMyTags() async {
        let site = AppSettings.shared.gallerySite
        if Self.cachedMyTagSite == site,
           let cachedDate = Self.cachedMyTagDate,
           Date().timeIntervalSince(cachedDate) < 600 {
            myTagNames = Self.cachedMyTagNames
            return
        }

        do {
            let list = try await EhAPI.shared.getWatchedList(url: EhURL.myTagsUrl(for: site))
            let names = Set(list.userTags.compactMap { Self.canonicalTag($0.tagName) })
            // Do not cache an empty parse. It can mean an expired session or a
            // server markup change, and caching it made highlighting appear
            // permanently broken for the remainder of the session.
            if !names.isEmpty {
                Self.cachedMyTagSite = site
                Self.cachedMyTagNames = names
                Self.cachedMyTagDate = Date()
            }
            myTagNames = names
        } catch {
            // 标签高亮是辅助信息；请求失败不应覆盖详情加载错误或阻断页面。
            myTagNames = []
        }
    }

    func isMyTag(_ fullTag: String) -> Bool {
        guard let normalized = Self.canonicalTag(fullTag) else { return false }
        if myTagNames.contains(normalized) { return true }
        let tagOnly = normalized.split(separator: ":", maxSplits: 1).last.map(String.init) ?? normalized
        return myTagNames.contains(tagOnly)
    }

    func tagVoteStatus(_ fullTag: String) -> GalleryTagVoteStatus {
        let components = fullTag.split(separator: ":", maxSplits: 1)
        guard components.count == 2 else { return .none }
        let namespace = String(components[0])
        let tag = String(components[1])
        guard let group = tags.first(where: {
            $0.groupName.localizedCaseInsensitiveCompare(namespace) == .orderedSame
        }) else {
            return .none
        }

        if let metadata = group.metadata[tag] {
            return metadata.vote
        }
        return group.metadata.first(where: {
            $0.key.localizedCaseInsensitiveCompare(tag) == .orderedSame
        })?.value.vote ?? .none
    }

    func isUpdatingTag(_ fullTag: String) -> Bool {
        updatingTags.contains(fullTag.lowercased())
    }

    /// My Tags may expose either a full namespace (`female:tag`) or the search
    /// prefix form (`f:"tag$"`). Convert both into the same representation as
    /// GalleryDetailParser before comparing them.
    static func canonicalTag(_ rawTag: String) -> String? {
        var value = rawTag
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else { return nil }

        let prefixNamespaces = [
            "a": "artist", "cos": "cosplayer", "c": "character",
            "f": "female", "g": "group", "l": "language",
            "m": "male", "x": "mixed", "o": "other",
            "p": "parody", "r": "reclass", "n": "rows"
        ]

        let components = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if components.count == 2 {
            let rawNamespace = String(components[0]).trimmingCharacters(in: .whitespaces)
            let namespace = prefixNamespaces[rawNamespace] ?? rawNamespace
            value = String(components[1])
            value = cleanTagName(value)
            guard !namespace.isEmpty, !value.isEmpty else { return nil }
            return "\(namespace):\(value)"
        }

        value = cleanTagName(value)
        return value.isEmpty ? nil : value
    }

    private static func cleanTagName(_ rawValue: String) -> String {
        var value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if value.hasSuffix("$") { value.removeLast() }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    func loadDetail(gid: Int64, token: String) async {
        guard !isLoading else { return }
        let generation = UUID()
        detailLoadGeneration = generation
        let performanceInterval = PerformanceDiagnostics.begin("GalleryDetailLoad")
        defer { performanceInterval.end() }

        isLoading = true
        errorMessage = nil

        // 1) 先查内存缓存 (对标 Android: EhApplication.getGalleryDetailCache().get(gid))
        if let cached = GalleryCache.shared.getDetail(gid: gid) {
            self.detail = cached
            self.isFavorited = cached.isFavorited
            self.displayRating = cached.info.rating
            self.isLoading = false
            checkReadingProgress(gid: gid)
            // Publish the cached page before touching download persistence or
            // compiling the comment-link parser for the first time.
            async let dlState = DownloadManager.shared.getTaskState(gid: gid)
            async let comments: Void = preprocessComments(cached.comments.comments)
            let (resolvedDownloadState, _) = await (dlState, comments)
            guard isCurrentDetailLoad(generation) else { return }
            self.downloadState = resolvedDownloadState
            debugLog("Loaded from cache - Comments: \(cached.comments.comments.count), HasMore: \(cached.comments.hasMore)")
            return
        }

        do {
            let site = GalleryActionService.siteBaseURL
            let urlStr = "\(site)g/\(gid)/\(token)/"
            debugLog("Fetching detail from: \(urlStr)")
            let result = try await EhAPI.shared.getGalleryDetail(url: urlStr)
            try Task.checkCancellation()
            guard isCurrentDetailLoad(generation) else { return }

            // 2) 存入缓存 (对标 Android: EhApplication.getGalleryDetailCache().put(result.gid, result))
            GalleryCache.shared.putDetail(result)

            // Make the detail visible immediately. Download state, local
            // favorite lookup and comment transformation are secondary.
            self.detail = result
            self.isFavorited = result.isFavorited
            self.displayRating = result.info.rating
            self.isLoading = false
            checkReadingProgress(gid: gid)

            // 下载状态与本地收藏互不依赖，并行查询以缩短详情首屏等待时间。
            async let dlState = DownloadManager.shared.getTaskState(gid: gid)
            async let hasLocalFav: Bool = Task.detached(priority: .userInitiated) {
                (try? EhDatabase.shared.containsLocalFavorite(gid: gid)) ?? false
            }.value
            async let comments: Void = preprocessComments(result.comments.comments)
            let (resolvedDownloadState, resolvedLocalFavorite, _) = await (dlState, hasLocalFav, comments)
            guard isCurrentDetailLoad(generation) else { return }

            self.isFavorited = result.isFavorited || resolvedLocalFavorite
            self.downloadState = resolvedDownloadState

            // Fix F3-4: 如果当前正在下载，启动轮询任务监听状态变化
            startDownloadPollingIfNeeded(gid: gid)
        } catch {
            guard detailLoadGeneration == generation else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                self.isLoading = false
                return
            }
            debugLog("Error loading detail: \(error)")
            self.errorMessage = EhError.localizedMessage(for: error)
            self.isLoading = false
        }
    }

    private func isCurrentDetailLoad(_ generation: UUID) -> Bool {
        detailLoadGeneration == generation && !Task.isCancelled
    }

    /// Fix B-3: 乐观更新 + API 失败回滚
    func addFavorite(gid: Int64, token: String, slot: Int) async {
        self.isFavorited = true  // 乐观更新
        do {
            try await GalleryActionService.shared.addFavorite(gid: gid, token: token, slot: slot)
            Haptics.success()
        } catch {
            self.isFavorited = false  // 回滚
            self.errorMessage = AppLocalization.format("收藏失败: %@", error.localizedDescription)
        }
    }

    /// 添加到本地收藏 (对齐 Android FAV_CAT_LOCAL = -1, EhDB.putLocalFavorite)
    func addLocalFavorite(gallery: GalleryInfo) async {
        isFavorited = true
        do {
            try await GalleryActionService.shared.addLocalFavorite(gallery: gallery)
            Haptics.success()
        } catch {
            isFavorited = false
            errorMessage = AppLocalization.format("本地收藏失败: %@", error.localizedDescription)
        }
    }

    /// Fix B-3: 乐观更新 + API 失败回滚
    func removeFavorite(gid: Int64, token: String) async {
        self.isFavorited = false  // 乐观更新
        do {
            try await GalleryActionService.shared.removeFavorite(gid: gid, token: token)
            Haptics.impact()
        } catch {
            self.isFavorited = true  // 回滚
            self.errorMessage = AppLocalization.format("取消收藏失败: %@", error.localizedDescription)
        }
    }

    // MARK: - Perf P0-4: 预处理评论 HTML

    /// 在 loadDetail 成功后调用 — 后台剥离 HTML 标签，View body 直接读取纯文本
    func preprocessComments(_ rawComments: [GalleryComment]) async {
        let processed = await Task.detached(priority: .utility) {
            rawComments.map { comment in
                ProcessedComment(
                    id: comment.id,
                    user: comment.user,
                    time: comment.time,
                    score: comment.score,
                    attributedBody: GalleryCommentLinks.attributedText(fromHTML: comment.comment)
                )
            }
        }.value
        guard !Task.isCancelled else { return }
        processedComments = processed
    }

    // MARK: - Perf P0-5: 一次性检查阅读进度

    /// 在 loadDetail 成功后调用 — 避免 body 每次重算时读 UserDefaults
    func checkReadingProgress(gid: Int64) {
        let key = "reading_progress_\(gid)"
        hasReadingProgress = UserDefaults.standard.object(forKey: key) != nil
    }

    func startDownload(gallery: GalleryInfo) async {
        await GalleryActionService.shared.startDownload(gallery: gallery)
        let state = await DownloadManager.shared.getTaskState(gid: gallery.gid)
        self.downloadState = state
        // Fix F3-4: 开始下载后启动轮询
        startDownloadPollingIfNeeded(gid: gallery.gid)
    }

    /// Fix F3-4: 当下载状态为进行中/等待时，每 2 秒轮询状态更新
    func startDownloadPollingIfNeeded(gid: Int64) {
        // 只在下载中/等待中状态才轮询
        guard downloadState == DownloadManager.stateDownload || downloadState == DownloadManager.stateWait else {
            downloadPollingTask?.cancel()
            downloadPollingTask = nil
            return
        }
        // 避免重复启动
        guard downloadPollingTask == nil else { return }

        downloadPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self = self else { break }
                let newState = await DownloadManager.shared.getTaskState(gid: gid)
                self.downloadState = newState
                // 状态不再是“进行中”时停止轮询
                if newState != DownloadManager.stateDownload && newState != DownloadManager.stateWait {
                    break
                }
            }
            self?.downloadPollingTask = nil
        }
    }

    /// 根据 downloadState 返回按钮图标 (对齐 Android 下载状态)
    var downloadIcon: String {
        switch downloadState {
        case DownloadManager.stateDownload, DownloadManager.stateWait:
            return "arrow.down.circle.fill"
        case DownloadManager.stateFinish:
            return "checkmark.circle.fill"
        case DownloadManager.stateFailed:
            return "exclamationmark.circle"
        default:
            return "arrow.down.circle"
        }
    }

    /// 根据 downloadState 返回按钮标题
    var downloadTitle: String {
        switch downloadState {
        case DownloadManager.stateDownload:
            return AppLocalization.localized("下载中")
        case DownloadManager.stateWait:
            return AppLocalization.localized("等待中")
        case DownloadManager.stateFinish:
            return AppLocalization.localized("已下载")
        case DownloadManager.stateFailed:
            return AppLocalization.localized("失败")
        default:
            return AppLocalization.localized("下载")
        }
    }

    func rateGallery(gid: Int64, token: String, rating: Float) async {
        guard let detail = detail, detail.apiUid > 0, !detail.apiKey.isEmpty else { return }

        do {
            let result = try await EhAPI.shared.rateGallery(
                apiUid: detail.apiUid,
                apiKey: detail.apiKey,
                gid: gid,
                token: token,
                rating: rating
            )
            // 如果返回有效评分则使用，否则使用用户选择的评分
            self.displayRating = result.rating > 0 ? Float(result.rating) : rating
        } catch {
            debugLog("Rate gallery failed: \(error)")
        }
    }

    /// 新增标签与既有标签投票共用 EH 的 `taggallery` API。服务端返回完整
    /// tagpane，因此成功后直接替换标签组，可同时同步权重及当前用户的投票状态。
    @discardableResult
    func voteTag(
        _ tags: String,
        vote: Int,
        gid: Int64,
        token: String
    ) async -> Bool {
        let normalizedTags = tags.trimmingCharacters(in: .whitespacesAndNewlines)
        let operationKey = normalizedTags.lowercased()
        guard !operationKey.isEmpty,
              vote == 1 || vote == -1,
              !updatingTags.contains(operationKey)
        else {
            return false
        }

        updatingTags.insert(operationKey)
        tagErrorMessage = nil
        defer { updatingTags.remove(operationKey) }

        do {
            let credentials = try await resolveAPICredentials(gid: gid, token: token)
            let updatedGroups = try await EhAPI.shared.voteTag(
                apiUid: credentials.uid,
                apiKey: credentials.key,
                gid: gid,
                token: token,
                tags: normalizedTags,
                vote: vote
            )

            guard var updatedDetail = detail else { return false }
            updatedDetail.tags = updatedGroups
            detail = updatedDetail
            GalleryCache.shared.putDetail(updatedDetail)
            tagErrorMessage = nil
            Haptics.success()
            return true
        } catch {
            tagErrorMessage = EhError.localizedMessage(for: error)
            return false
        }
    }

    @discardableResult
    func addTags(_ tags: String, gid: Int64, token: String) async -> Bool {
        await voteTag(tags, vote: 1, gid: gid, token: token)
    }

    private func resolveAPICredentials(
        gid: Int64,
        token: String
    ) async throws -> (uid: Int64, key: String) {
        if let detail, detail.apiUid > 0, !detail.apiKey.isEmpty {
            return (detail.apiUid, detail.apiKey)
        }

        // 旧缓存可能来自登录前，缺少页面内的 API 凭证；此时刷新详情，
        // 避免用户必须手动切换页面后才能操作标签。
        let site = AppSettings.shared.gallerySite
        let url = EhURL.galleryDetailUrl(gid: gid, token: token, site: site)
        let refreshed = try await EhAPI.shared.getGalleryDetail(url: url)
        guard refreshed.apiUid > 0, !refreshed.apiKey.isEmpty else {
            throw EhError.parseError("登录凭据不可用，请重新登录后再试")
        }

        detail = refreshed
        GalleryCache.shared.putDetail(refreshed)
        await preprocessComments(refreshed.comments.comments)
        return (refreshed.apiUid, refreshed.apiKey)
    }

    /// 加载全部评论 (带 ?hc=1 参数获取所有评论)
    func loadAllComments(gid: Int64, token: String) async {
        guard !isLoadingComments else { return }

        isLoadingComments = true

        do {
            let site = GalleryActionService.siteBaseURL
            // 添加 hc=1 参数来获取全部评论
            let urlStr = "\(site)g/\(gid)/\(token)/?hc=1"
            let result = try await EhAPI.shared.getGalleryDetail(url: urlStr)

            // 更新详情（主要是评论列表）
            // 保留原有详情，只更新评论部分
            if var currentDetail = self.detail {
                currentDetail.comments = result.comments
                self.detail = currentDetail
                // 更新缓存
                GalleryCache.shared.putDetail(currentDetail)
            }
            await preprocessComments(result.comments.comments)
            self.isLoadingComments = false
        } catch {
            self.isLoadingComments = false
            debugLog("Load all comments failed: \(error)")
        }
    }

    func replaceComments(_ comments: GalleryCommentList) async {
        guard var updatedDetail = detail else { return }
        updatedDetail.comments = comments
        detail = updatedDetail
        await preprocessComments(comments.comments)
        GalleryCache.shared.putDetail(updatedDetail)
    }


}

// MARK: - FlowLayout (Tags)

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? 300, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxWidth = max(maxWidth, x)
        }

        return (offsets, CGSize(width: maxWidth, height: y + rowHeight))
    }
}

// MARK: - Add Gallery Tags

private struct AddGalleryTagsSheet: View {
    @Binding var text: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @FocusState private var isTextFocused: Bool

    private var canSubmit: Bool {
        !isSubmitting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: "tag.badge.plus")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 22, height: 22, alignment: .center)
                Text("新增标签")
                    .font(.title3.bold())
            }

            Text("请输入 namespace:tag；多个标签以逗号分隔。标签会提交至当前 EH 站点。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                Label("标签", systemImage: "number")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField(
                    "例如 female:glasses, language:chinese",
                    text: $text,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(2...3)
                .focused($isTextFocused)
                .onSubmit {
                    if canSubmit { onSubmit() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isTextFocused
                            ? Color.accentColor.opacity(0.72)
                            : Color.secondary.opacity(0.2),
                        lineWidth: isTextFocused ? 1.5 : 1
                    )
            }
            .animation(.easeOut(duration: 0.16), value: isTextFocused)

            HStack(spacing: 10) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在提交…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("取消", action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)

                Button(action: onSubmit) {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("提交")
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(18)
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480)
        #else
        .frame(maxWidth: 520)
        #endif
    }
}

// MARK: - RatingSheet

struct RatingSheet: View {
    let currentRating: Float
    let onRate: (Float) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRating: Float = 2.5

    var body: some View {
        VStack(spacing: 20) {
            Text("评分")
                .font(.headline)

            HStack(spacing: 8) {
                ForEach(0..<5) { i in
                    Image(systemName: starIcon(index: i))
                        .font(.title)
                        .foregroundStyle(.orange)
                        .onTapGesture {
                            selectedRating = Float(i) + 1.0
                            Haptics.select()
                        }
                }
            }

            Text(String(format: "%.1f", selectedRating))
                .font(.title2.bold())
                .monospacedDigit()

            HStack(spacing: 16) {
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("确定") {
                    Haptics.success()
                    onRate(selectedRating)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear {
            selectedRating = max(0.5, currentRating)
        }
    }

    private func starIcon(index: Int) -> String {
        let fill = selectedRating - Float(index)
        if fill >= 1.0 { return "star.fill" }
        if fill >= 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

// MARK: - 精灵图预览视图

nonisolated final class SpriteCGImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

/// 所有预览格子共享同一个精灵图请求。下载、解码和裁剪均不占用 MainActor，
/// 避免“查看全部”同时创建几十个格子时阻塞 AppKit 布局。
actor SpritePreviewPipeline {
    static let shared = SpritePreviewPipeline()

    private let sheetCache = NSCache<NSURL, SpriteCGImageBox>()
    private let cropCache = NSCache<NSString, SpriteCGImageBox>()
    private var inFlightSheets: [URL: Task<SpriteCGImageBox?, Never>] = [:]

    init() {
        sheetCache.countLimit = 24
        cropCache.countLimit = 600
        cropCache.totalCostLimit = 80 * 1024 * 1024
    }

    func croppedImage(
        for preview: NormalPreview,
        referer: String
    ) async -> SpriteCGImageBox? {
        guard let url = URL(string: preview.imageUrl) else { return nil }
        let key = cropKey(for: preview)
        if let cached = cropCache.object(forKey: key) {
            return cached
        }
        guard let sheet = await sheet(for: url, referer: referer) else { return nil }

        let requestedRect = CGRect(
            x: preview.offsetX,
            y: preview.offsetY,
            width: preview.clipWidth,
            height: preview.clipHeight
        ).integral
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: sheet.image.width,
            height: sheet.image.height
        )
        let cropRect = requestedRect.intersection(imageBounds)
        guard !cropRect.isNull, cropRect.width > 0, cropRect.height > 0 else {
            return nil
        }

        let cropped = await Task.detached(priority: .utility) {
            sheet.image.cropping(to: cropRect).map(SpriteCGImageBox.init)
        }.value
        if let cropped {
            cropCache.setObject(
                cropped,
                forKey: key,
                cost: cropped.image.bytesPerRow * cropped.image.height
            )
        }
        return cropped
    }

    private func sheet(for url: URL, referer: String) async -> SpriteCGImageBox? {
        if let cached = sheetCache.object(forKey: url as NSURL) {
            return cached
        }
        if let task = inFlightSheets[url] {
            return await task.value
        }

        let task = Task(priority: .utility) {
            await Self.loadSheet(url: url, referer: referer)
        }
        inFlightSheets[url] = task
        let result = await task.value
        inFlightSheets[url] = nil
        if let result {
            sheetCache.setObject(result, forKey: url as NSURL)
        }
        return result
    }

    private static func loadSheet(url: URL, referer: String) async -> SpriteCGImageBox? {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
        request.timeoutInterval = 30
        request.setValue(EhRequestBuilder.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")

        if let cached = URLCache.shared.cachedResponse(for: request),
           let decoded = await decode(cached.data) {
            return decoded
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return nil
            }
            guard let decoded = await decode(data) else { return nil }
            URLCache.shared.storeCachedResponse(
                CachedURLResponse(response: response, data: data),
                for: request
            )
            return decoded
        } catch {
            return nil
        }
    }

    private static func decode(_ data: Data) async -> SpriteCGImageBox? {
        await Task.detached(priority: .utility) {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else {
                return nil
            }
            return SpriteCGImageBox(image)
        }.value
    }

    private func cropKey(for preview: NormalPreview) -> NSString {
        "\(preview.imageUrl)|\(preview.offsetX),\(preview.offsetY),\(preview.clipWidth),\(preview.clipHeight)" as NSString
    }
}

struct SpritePreviewView: View {
    let preview: NormalPreview
    @State private var croppedImage: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let croppedImage {
                Image(decorative: croppedImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(.tertiarySystemFill)
                    .overlay {
                        if failed {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .task(id: SpriteLoadID(preview: preview)) {
            let referer = GalleryActionService.siteBaseURL
            guard let result = await SpritePreviewPipeline.shared.croppedImage(
                for: preview,
                referer: referer
            ),
                  !Task.isCancelled else {
                if !Task.isCancelled { failed = true }
                return
            }
            croppedImage = result.image
            failed = false
        }
    }

    private struct SpriteLoadID: Hashable {
        let url: String
        let offsetX: Int
        let offsetY: Int
        let width: Int
        let height: Int

        init(preview: NormalPreview) {
            url = preview.imageUrl
            offsetX = preview.offsetX
            offsetY = preview.offsetY
            width = preview.clipWidth
            height = preview.clipHeight
        }
    }
}

// MARK: - FavoriteSlotPicker (对齐 Android FavoritesActivity 收藏夹选择器)

struct FavoriteSlotPicker: View {
    let onSelect: (Int) -> Void
    let onCancel: () -> Void
    /// 是否显示本地收藏选项 (对齐 Android: slot -1 = 本地收藏)
    var showLocalOption: Bool = true

    var body: some View {
        NavigationStack {
            List {
                // 本地收藏 (对齐 Android FAV_CAT_LOCAL = -1)
                if showLocalOption {
                    Button {
                        onSelect(-1)
                    } label: {
                        HStack {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(.secondary)
                            Text("本地收藏")
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }

                // 云端收藏 0-9 (对齐 Android favCatArray)
                ForEach(0..<10) { slot in
                    Button {
                        onSelect(slot)
                    } label: {
                        HStack {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(favSlotColor(slot))
                            Text(AppSettings.shared.favCatName(slot))
                                .foregroundStyle(.primary)
                            Spacer()
                            let count = AppSettings.shared.favCount(slot)
                            if count > 0 {
                                Text("\(count)")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择收藏夹")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 420, idealHeight: 520)
        #endif
    }

    static func favSlotColor(_ slot: Int) -> Color {
        let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .brown, .gray]
        return slot >= 0 && slot < colors.count ? colors[slot] : .secondary
    }

    private func favSlotColor(_ slot: Int) -> Color {
        Self.favSlotColor(slot)
    }
}
