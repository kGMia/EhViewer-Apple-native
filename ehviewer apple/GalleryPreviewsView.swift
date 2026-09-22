//
//  GalleryPreviewsView.swift
//  ehviewer apple
//
//  预览图懒加载查看 (对齐 Android GalleryPreviewsScene - 滚动加载全部预览)
//

import SwiftUI
import EhModels
import EhAPI
import EhSettings
#if os(iOS)
import UIKit
#else
import AppKit
import UniformTypeIdentifiers
#endif

struct GalleryPreviewsView: View {
    let gid: Int64
    let token: String
    let totalPages: Int
    let galleryPages: Int
    let initialPreviewSet: PreviewSet
    
    @State private var vm = GalleryPreviewsViewModel()
    @State private var scrollAnchor: Int?
    @State private var pageNavigation = PreviewPageNavigation()
    @State private var scrollRequest: PreviewScrollRequest?
    @State private var isScrubbing = false
    @Namespace private var pagingGlass
    @State private var showsPageSlider = false
    @State private var sliderPage = 1.0
    @State private var jumpTask: Task<Void, Never>?
    @State private var failedJumpPage: Int?
    @State private var imageSearchRoute: NativeImageSearchRoute?
    @Environment(\.responsiveLayout) private var responsiveLayout
    @Environment(\.readerPresentationAction) private var readerPresentationAction
    @Environment(\.gallerySearchNavigationAction) private var gallerySearchNavigationAction
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @State private var readerTarget: ReaderTarget? = nil
    #else
    @Environment(\.openWindow) private var openWindow
    #endif
    
    // 预览图尺寸 (对齐 Android gallery_grid_column_width_middle = 120dp)
    private let previewWidth: CGFloat = 120
    private var visiblePage: Int { pageNavigation.currentPage }

    private struct PreviewScrollRequest: Equatable {
        let request: PreviewPageNavigation.Request
        let position: Int
        let animated: Bool
    }

    private var pageControlHeight: CGFloat {
        #if os(macOS)
        32
        #else
        44
        #endif
    }

    private var pageControlTint: Color {
        if let selected = AppSettings.shared.accentColor.swiftUIColor { return selected }
        #if os(macOS)
        return Color(nsColor: .controlAccentColor)
        #else
        return .accentColor
        #endif
    }

    private var horizontalContentInset: CGFloat {
        responsiveLayout.horizontalSizeClass == .regular
            && (responsiveLayout.height > responsiveLayout.width
                || AppSettings.shared.wideScreenListMode == 1) ? 28 : 8
    }
    
    init(gid: Int64, token: String, totalPages: Int, galleryPages: Int, initialPreviewSet: PreviewSet) {
        self.gid = gid
        self.token = token
        self.totalPages = totalPages
        self.galleryPages = galleryPages
        self.initialPreviewSet = initialPreviewSet
    }
    
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 0) {
                if let previousPage = vm.previousPage {
                    PreviewPageBoundary(error: vm.errors[previousPage]) {
                        await vm.loadAdjacent(page: previousPage)
                    }
                    .id("previous-\(previousPage)")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: previewWidth, maximum: previewWidth + 20), spacing: 8)], spacing: 16) {
                    ForEach(vm.allPreviews, id: \.position) { preview in
                        previewItem(preview: preview)
                            .id(preview.position)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, horizontalContentInset)
                .padding(.top, 16)
                if let nextPage = vm.nextPage {
                    PreviewPageBoundary(error: vm.errors[nextPage]) {
                        await vm.loadAdjacent(page: nextPage)
                    }
                    .id("next-\(nextPage)")
                }
            }
            .padding(.bottom, 16)
        }
        // SwiftUI tracks the visible preview identity and its offset when
        // preceding previews are inserted; never scroll to the list's beginning.
        .scrollPosition(id: $scrollAnchor)
        .onChange(of: scrollRequest) { _, target in
            guard let target else { return }
            // Explicit alignment also works when the target is already visible
            // or has the same identity as the previous scroll request.
            withAnimation(reduceMotion || !target.animated ? nil : .smooth(duration: 0.24), completionCriteria: .removed) {
                proxy.scrollTo(target.position, anchor: .top)
            } completion: {
                pageNavigation.complete(target.request)
            }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting {
                jumpTask?.cancel()
                vm.cancelRequests()
                pageNavigation.cancel()
                scrollRequest = nil
            }
        }
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.1) { positions in
            guard !vm.isJumping, pageNavigation.followsVisibility, pageNavigation.pending == nil, let position = positions.min(),
                  let page = vm.page(containing: position) else { return }
            pageNavigation.observe(page: page)
            if !isScrubbing { sliderPage = Double(page + 1) }
        }
        #if os(macOS)
        .scrollClipDisabled()
        #endif
        .navigationTitle("预览 (\(galleryPages)张)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .task(id: "\(gid):\(token)") {
            vm.initialize(gid: gid, token: token, totalPages: totalPages, initialPreviewSet: initialPreviewSet)
            if vm.allPreviews.isEmpty {
                jump(to: 0)
            }
        }
        .onDisappear {
            jumpTask?.cancel()
            vm.cancelRequests()
            pageNavigation.cancel()
            scrollRequest = nil
        }
        // Keep paging chrome in the system bar layer, outside the scrolling
        // content. This also reserves its real height at large text sizes.
        .safeAreaBar(edge: .bottom, spacing: 0) {
            pageControl
                .padding(.vertical, 12)
        }
        .overlay {
            if vm.isJumping {
                ProgressView("加载中...")
                    .padding(20)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
        }
        .alert("加载失败", isPresented: Binding(
            get: { failedJumpPage != nil },
            set: { if !$0 { failedJumpPage = nil } }
        )) {
            Button("重试") {
                if let page = failedJumpPage {
                    failedJumpPage = nil
                    jump(to: page)
                }
            }
            Button("取消", role: .cancel) { failedJumpPage = nil }
        } message: {
            Text(failedJumpPage.flatMap { vm.errors[$0] } ?? "")
        }
        #if os(iOS)
        .fullScreenCover(item: $readerTarget) { target in
            ImageReaderView(
                gid: gid,
                token: token,
                pages: galleryPages,
                previewSet: initialPreviewSet,
                initialPage: target.page
            )
        }
        #endif
        }
        .environment(\.imageSearchPresentationAction, ImageSearchPresentationAction { data in
            imageSearchRoute = NativeImageSearchRoute(initialData: data)
        })
        .sheet(item: $imageSearchRoute) { route in
            NativeImageSearchView(initialData: route.initialData) { url in
                imageSearchRoute = nil
                Task { @MainActor in
                    // Let the image-search sheet leave first, then remove the
                    // full-preview layer so it cannot cover the result list.
                    await Task.yield()
                    dismiss()
                    gallerySearchNavigationAction?.imageSearch?(url)
                }
            }
        }
    }

    private var pageControl: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if showsPageSlider {
                    HStack(spacing: 10) {
                        Text("\(Int(sliderPage)) / \(vm.pageCount)")
                            .font(.subheadline.monospacedDigit())
                            .fixedSize()
                        Slider(value: $sliderPage, in: 1...Double(max(2, vm.pageCount)), step: 1) { editing in
                            isScrubbing = editing
                            if !editing { jump(to: Int(sliderPage) - 1) }
                        }
                        .tint(pageControlTint)
                        .accessibilityLabel("跳转到预览页")
                        .accessibilityValue("\(Int(sliderPage)) / \(vm.pageCount)")
                        .disabled(vm.pageCount <= 1)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: 290, minHeight: pageControlHeight)
                    .glassEffect(.regular.interactive(!reduceMotion), in: .capsule)
                    .glassEffectID("page", in: pagingGlass)

                    pagingButton("关闭", symbol: "xmark") {
                        showsPageSlider = false
                    }
                } else {
                    pagingButton("上一页", symbol: "chevron.left") {
                        jump(to: visiblePage - 1)
                    }
                    .disabled(visiblePage <= 0)

                    Button {
                        sliderPage = Double(visiblePage + 1)
                        showsPageSlider = true
                    } label: {
                        Text("\(visiblePage + 1) / \(vm.pageCount)")
                            .font(.subheadline.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 16)
                            .frame(minHeight: pageControlHeight)
                            .contentShape(.capsule)
                    }
                    // Size the complete surface once; glass button styles add
                    // their own insets outside an already-sized label.
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(!reduceMotion), in: .capsule)
                    .glassEffectID("page", in: pagingGlass)
                    .accessibilityLabel("跳转到预览页")
                    .accessibilityValue("\(visiblePage + 1) / \(vm.pageCount)")
                    .accessibilityHint("点击后拖动滑块跳页")
                    .help("跳转到预览页")
                    .disabled(vm.pageCount <= 1)

                    pagingButton("下一页", symbol: "chevron.right") {
                        jump(to: visiblePage + 1)
                    }
                    .disabled(visiblePage >= vm.pageCount - 1)
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: showsPageSlider)
        .padding(.horizontal, 16)
    }

    private func pagingButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: pageControlHeight, height: pageControlHeight)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(!reduceMotion), in: .circle)
        .accessibilityLabel(Text(title))
        .help(Text(title))
    }

    private func jump(to page: Int) {
        let request = pageNavigation.begin(page: page, pageCount: vm.pageCount)
        sliderPage = Double(request.page + 1)
        failedJumpPage = nil
        let isInLoadedWindow = !vm.allPreviews.isEmpty && (
            (vm.lowerPage...vm.upperPage).contains(request.page)
                || request.page == vm.previousPage || request.page == vm.nextPage
        )
        jumpTask?.cancel()
        jumpTask = Task {
            guard !Task.isCancelled, pageNavigation.pending == request else { return }
            if let position = await vm.jump(to: request.page) {
                guard !Task.isCancelled, pageNavigation.pending == request else { return }
                scrollRequest = PreviewScrollRequest(request: request, position: position, animated: isInLoadedWindow)
            } else if !Task.isCancelled, pageNavigation.pending == request {
                pageNavigation.cancel()
                sliderPage = Double(visiblePage + 1)
                failedJumpPage = request.page
            }
        }
    }
    
    // MARK: - 预览项 (点击跳转到阅读器，对齐 Android GalleryPreviewsScene.onItemClick)
    
    @ViewBuilder
    private func previewItem(preview: PreviewItem) -> some View {
        Button {
            // 对齐 Android: 预览点击直接进入阅读器并定位页面
            #if os(iOS)
            let route = ReaderWindowRoute(
                gid: gid,
                token: token,
                pages: galleryPages,
                previewSet: initialPreviewSet,
                initialPage: preview.position
            )
            if let readerPresentationAction {
                readerPresentationAction.present(route)
            } else {
                readerTarget = ReaderTarget(page: preview.position)
            }
            #else
            openWindow(value: ReaderWindowRoute(
                gid: gid,
                token: token,
                pages: galleryPages,
                previewSet: initialPreviewSet,
                initialPage: preview.position
            ))
            #endif
        } label: {
            VStack(spacing: 6) {
                switch preview.type {
                case .large(let imageUrl):
                    OriginalRatioPreviewImage(
                        url: URL(string: imageUrl),
                        width: previewWidth,
                        cornerRadius: 6
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                    
                case .normal(let normalPreview):
                    SpritePreviewView(preview: normalPreview, contentMode: .fit)
                        .frame(
                            width: previewWidth,
                            height: PreviewThumbnailLayout.height(width: previewWidth, aspectRatio: normalPreview.previewAspectRatio)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                }
                
                // 页码标签 (1-based，对齐 Android preview.getPosition() + 1)
                Text("\(preview.position + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .previewHoverLift()
        .previewOriginalImageActions(
            gid: gid,
            token: token,
            pages: galleryPages,
            previewSet: initialPreviewSet,
            page: preview.position
        )
    }
}

/// Only request a neighboring page when the boundary is actually visible,
/// not merely because LazyVGrid has prefetched its view.
private struct PreviewPageBoundary: View {
    let error: String?
    let load: @MainActor () async -> Void
    @State private var isVisible = false

    var body: some View {
        Group {
            if let error {
                Button("重试") { Task { await load() } }
                    .help(error)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
        .task(id: isVisible) {
            if isVisible && error == nil { await load() }
        }
    }
}

/// Bound the thumbnail canvas; fit rendering preserves the complete image.
nonisolated enum PreviewThumbnailLayout {
    static let maximumHeight: CGFloat = 240

    static func height(width: CGFloat, aspectRatio: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 2.0 / 3.0
        return min(width / ratio, maximumHeight)
    }
}

/// 独立预览图按真实比例完整缩放，超长图片限制预览高度。
struct OriginalRatioPreviewImage: View {
    let url: URL?
    let width: CGFloat
    let cornerRadius: CGFloat

    @State private var aspectRatio: CGFloat = 2.0 / 3.0

    var body: some View {
        CachedAsyncImage(
            url: url,
            animatedContentMode: .fit,
            onImageSize: { size in
                guard size.width > 0, size.height > 0 else { return }
                aspectRatio = size.width / size.height
            }
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } placeholder: {
            Color(.tertiarySystemFill)
                .overlay { ProgressView() }
        }
        .frame(width: width, height: PreviewThumbnailLayout.height(width: width, aspectRatio: aspectRatio))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onChange(of: url) { _, _ in aspectRatio = 2.0 / 3.0 }
    }
}

extension NormalPreview {
    var previewAspectRatio: CGFloat {
        guard clipWidth > 0, clipHeight > 0 else { return 2.0 / 3.0 }
        return CGFloat(clipWidth) / CGFloat(clipHeight)
    }
}

    #if os(iOS)
    private struct ReaderTarget: Identifiable {
        let id = UUID()
        let page: Int
    }
    #endif

// MARK: - 统一预览项模型

struct PreviewItem: Identifiable {
    let id: Int
    let position: Int
    let type: PreviewType
    
    enum PreviewType {
        case large(imageUrl: String)
        case normal(NormalPreview)
    }
    
    init(position: Int, type: PreviewType) {
        self.id = position
        self.position = position
        self.type = type
    }
}

// MARK: - Pointer Hover

struct PreviewHoverLiftModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering ? 1.035 : 1)
            .offset(y: isHovering ? -4 : 0)
            .shadow(
                color: .black.opacity(isHovering ? 0.22 : 0.08),
                radius: isHovering ? 9 : 2,
                y: isHovering ? 6 : 1
            )
            .zIndex(isHovering ? 1 : 0)
            .animation(.smooth(duration: 0.18), value: isHovering)
            #if os(macOS)
            .onHover { isHovering = $0 }
            #else
            .hoverEffect(.lift)
            #endif
    }
}

extension View {
    func previewHoverLift() -> some View {
        modifier(PreviewHoverLiftModifier())
    }
}

// MARK: - Preview original-image actions

extension View {
    func previewOriginalImageActions(
        gid: Int64,
        token: String,
        pages: Int,
        previewSet: PreviewSet,
        page: Int
    ) -> some View {
        modifier(PreviewOriginalImageActionsModifier(
            gid: gid,
            token: token,
            pages: pages,
            previewSet: previewSet,
            page: page
        ))
    }
}

private struct PreviewOriginalImageActionsModifier: ViewModifier {
    let gid: Int64
    let token: String
    let pages: Int
    let previewSet: PreviewSet
    let page: Int

    @Environment(\.imageSearchPresentationAction) private var imageSearchPresentationAction
    @State private var isLoadingOriginal = false

    func body(content: Content) -> some View {
        content
        #if os(iOS)
        // Keep UIKit's context-menu snapshot to the visible thumbnail. This
        // avoids rasterizing the surrounding lazy-grid cell on first press.
        .contentShape(
            .contextMenuPreview,
            RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        #endif
        .contextMenu {
            Button {
                saveOriginalImage()
            } label: {
                Label(
                    AppLocalization.localized(isLoadingOriginal ? "正在加载原图…" : "下载原图"),
                    systemImage: "arrow.down.to.line"
                )
            }
            .disabled(isLoadingOriginal)

            Button {
                copyOriginalImage()
            } label: {
                Label("拷贝图片", systemImage: "doc.on.doc")
            }
            .disabled(isLoadingOriginal)

            if imageSearchPresentationAction != nil {
                Divider()

                Button {
                    searchOriginalImage()
                } label: {
                    Label(
                        AppLocalization.localized(isLoadingOriginal ? "正在加载原图…" : "以图搜图"),
                        systemImage: "magnifyingglass"
                    )
                }
                .disabled(isLoadingOriginal)
            }
        }
    }

    private func loadOriginalData() async throws -> Data {
        try await PreviewOriginalImageLoader.shared.data(
            gid: gid,
            token: token,
            pages: pages,
            previewSet: previewSet,
            page: page
        )
    }

    private func copyOriginalImage() {
        guard !isLoadingOriginal else { return }
        isLoadingOriginal = true
        Task {
            defer { isLoadingOriginal = false }
            do {
                let data = try await loadOriginalData()
                #if os(iOS)
                guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                UIPasteboard.general.image = image
                #else
                guard let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                #endif
                Haptics.success()
            } catch {
                ErrorHandler.shared.handle(error, context: "CopyPreviewOriginal")
            }
        }
    }

    private func saveOriginalImage() {
        guard !isLoadingOriginal else { return }
        isLoadingOriginal = true
        Task {
            defer { isLoadingOriginal = false }
            do {
                let data = try await loadOriginalData()
                #if os(iOS)
                guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                Haptics.success()
                #else
                let fileExtension = Self.fileExtension(for: data)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "\(gid)-\(page + 1).\(fileExtension)"
                panel.canCreateDirectories = true
                panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .image]
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                try data.write(to: destination, options: .atomic)
                Haptics.success()
                #endif
            } catch {
                ErrorHandler.shared.handle(error, context: "SavePreviewOriginal")
            }
        }
    }

    private func searchOriginalImage() {
        guard !isLoadingOriginal, let imageSearchPresentationAction else { return }
        isLoadingOriginal = true
        Task {
            defer { isLoadingOriginal = false }
            do {
                let data = try await loadOriginalData()
                imageSearchPresentationAction.present(data)
                Haptics.impact()
            } catch {
                ErrorHandler.shared.handle(error, context: "SearchPreviewOriginal")
            }
        }
    }

    private static func fileExtension(for data: Data) -> String {
        let prefix = Array(data.prefix(12))
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if prefix.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if prefix.count >= 12,
           prefix[0...3] == [0x52, 0x49, 0x46, 0x46],
           prefix[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return "jpg"
    }
}

@MainActor
private final class PreviewOriginalImageLoader {
    static let shared = PreviewOriginalImageLoader()

    private let cache = NSCache<NSString, NSData>()

    private init() {
        cache.countLimit = 8
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func data(
        gid: Int64,
        token: String,
        pages: Int,
        previewSet: PreviewSet,
        page: Int
    ) async throws -> Data {
        let key = "\(gid):\(page)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached as Data
        }

        let reader = ReaderViewModel()
        reader.gid = gid
        reader.token = token
        reader.totalPages = pages
        reader.extractPTokens(from: previewSet)
        let data = try await reader.originalSourceImageData(for: page)
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }
}

// MARK: - ViewModel

/// Keep the requested page separate from visibility callbacks during loading
/// and native scrolling. Rapid taps advance from the most recent target.
struct PreviewPageNavigation {
    struct Request: Equatable {
        let id = UUID()
        let page: Int
    }

    private(set) var settledPage = 0
    private(set) var pending: Request?
    private(set) var followsVisibility = true
    var currentPage: Int { pending?.page ?? settledPage }

    mutating func begin(page: Int, pageCount: Int) -> Request {
        let request = Request(page: min(max(0, page), max(0, pageCount - 1)))
        pending = request
        followsVisibility = false
        return request
    }

    mutating func observe(page: Int) {
        guard pending == nil, followsVisibility else { return }
        settledPage = page
    }

    mutating func complete(_ request: Request) {
        guard pending == request else { return }
        settledPage = request.page
        pending = nil
    }

    mutating func cancel() {
        pending = nil
        followsVisibility = true
    }
}

@MainActor
@Observable
class GalleryPreviewsViewModel {
    typealias Loader = @Sendable (String) async throws -> (PreviewSet, Int)
    private(set) var allPreviews: [PreviewItem] = []
    private(set) var pageCount = 1
    private(set) var lowerPage = 0
    private(set) var upperPage = 0
    private(set) var isJumping = false
    private(set) var errors: [Int: String] = [:]
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private var baseURL = ""
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pageCache: [Int: [PreviewItem]] = [:]
    @ObservationIgnored private var positionPages: [Int: Int] = [:]
    @ObservationIgnored private var requests: [Int: Task<(PreviewSet, Int), Error>] = [:]

    init(loader: @escaping Loader = { try await EhAPI.shared.getPreviewSet(url: $0) }) {
        self.loader = loader
    }

    var previousPage: Int? { lowerPage > 0 ? lowerPage - 1 : nil }
    var nextPage: Int? { upperPage + 1 < pageCount ? upperPage + 1 : nil }

    func initialize(gid: Int64, token: String, totalPages: Int, initialPreviewSet: PreviewSet) {
        let url = "\(GalleryActionService.siteBaseURL)g/\(gid)/\(token)/"
        guard baseURL != url else { return }
        cancelRequests()
        baseURL = url
        pageCount = max(1, totalPages)
        lowerPage = 0
        upperPage = 0
        errors.removeAll()
        pageCache.removeAll()
        positionPages.removeAll()
        allPreviews = Self.items(from: initialPreviewSet)
        if !allPreviews.isEmpty { pageCache[0] = allPreviews }
        for item in allPreviews { positionPages[item.position] = 0 }
    }

    func page(containing position: Int) -> Int? { positionPages[position] }

    /// A jump loads only the requested website page, not every intervening page.
    /// Adjacent loads subsequently grow a contiguous window in both directions.
    func jump(to requestedPage: Int) async -> Int? {
        let page = min(max(requestedPage, 0), pageCount - 1)
        cancelRequests()
        let identity = generation
        isJumping = true
        defer { if generation == identity { isJumping = false } }
        guard let items = await fetch(page: page), generation == identity, !Task.isCancelled else { return nil }
        if !allPreviews.isEmpty && (page == previousPage || page == nextPage) {
            mergeAdjacent(items, page: page)
        } else if !(lowerPage...upperPage).contains(page) || allPreviews.isEmpty {
            lowerPage = page
            upperPage = page
            allPreviews = items
        }
        trimInactiveCache()
        return items.first?.position
    }

    func loadAdjacent(page: Int) async {
        guard !isJumping, page == previousPage || page == nextPage else { return }
        let identity = generation
        guard let items = await fetch(page: page), generation == identity, !Task.isCancelled,
              page == previousPage || page == nextPage else { return }
        mergeAdjacent(items, page: page)
        trimInactiveCache()
    }

    private func mergeAdjacent(_ items: [PreviewItem], page: Int) {
        lowerPage = min(lowerPage, page)
        upperPage = max(upperPage, page)
        var positions = Set(allPreviews.map(\.position))
        allPreviews.append(contentsOf: items.filter { positions.insert($0.position).inserted })
        allPreviews.sort { $0.position < $1.position }
    }

    func cancelRequests() {
        generation = UUID()
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        isJumping = false
    }

    private func fetch(page: Int) async -> [PreviewItem]? {
        if let cached = pageCache[page] { return cached }
        let identity = generation
        errors[page] = nil
        let task: Task<(PreviewSet, Int), Error>
        if let existing = requests[page] {
            task = existing
        } else {
            let loader = loader
            let url = "\(baseURL)?p=\(page)"
            task = Task { try await loader(url) }
            requests[page] = task
        }
        defer { if generation == identity { requests[page] = nil } }
        do {
            let (previews, count) = try await task.value
            guard generation == identity else { return nil }
            let items = Self.items(from: previews)
            guard !items.isEmpty else { throw URLError(.cannotParseResponse) }
            // A partial/missing pager must not truncate an already known total.
            pageCount = max(pageCount, max(page + 1, count))
            pageCache[page] = items
            for item in items { positionPages[item.position] = page }
            // Scrolling away cancels the boundary's waiter, not a shared
            // request. Retain its result for a later visit without inserting it.
            return Task.isCancelled ? nil : items
        } catch {
            guard generation == identity, !Task.isCancelled,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return nil }
            errors[page] = error.localizedDescription
            return nil
        }
    }

    private func trimInactiveCache() {
        // Keep browsed pages plus a small recent-jump cache, never image bitmaps.
        let inactive = pageCache.keys.filter { !(lowerPage...upperPage).contains($0) }
            .sorted { abs($0 - lowerPage) > abs($1 - lowerPage) }
        for page in inactive.prefix(max(0, pageCache.count - 24)) {
            pageCache.removeValue(forKey: page)
        }
    }

    private static func items(from previewSet: PreviewSet) -> [PreviewItem] {
        let values: [PreviewItem]
        switch previewSet {
        case .large(let items):
            values = items.map { preview in
                PreviewItem(position: preview.position, type: .large(imageUrl: preview.imageUrl))
            }
        case .normal(let items):
            values = items.map { preview in
                PreviewItem(position: preview.position, type: .normal(preview))
            }
        }
        var positions = Set<Int>()
        return values.filter { positions.insert($0.position).inserted }.sorted { $0.position < $1.position }
    }
}
