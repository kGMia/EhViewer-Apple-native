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
    @Environment(\.responsiveLayout) private var responsiveLayout
    @Environment(\.readerPresentationAction) private var readerPresentationAction
    #if os(iOS)
    @State private var readerTarget: ReaderTarget? = nil
    #else
    @Environment(\.openWindow) private var openWindow
    #endif
    
    // 预览图尺寸 (对齐 Android gallery_grid_column_width_middle = 120dp)
    private let previewWidth: CGFloat = 120

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
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: previewWidth, maximum: previewWidth + 20), spacing: 8)], spacing: 16) {
                ForEach(vm.allPreviews, id: \.position) { preview in
                    previewItem(preview: preview)
                }

                // 作为 LazyVGrid 的最后一个单元格，仅滚动到末尾时才开始下一页。
                if let nextPage = vm.nextPage(totalPages: totalPages) {
                    Group {
                        if let loadError = vm.loadError {
                            Button("重试") {
                                vm.loadError = nil
                                Task {
                                    await vm.loadNextPageIfNeeded(
                                        gid: gid,
                                        token: token,
                                        totalPages: totalPages
                                    )
                                }
                            }
                            .help(loadError)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: previewWidth, height: 44)
                    .task(id: nextPage) {
                        await vm.loadNextPageIfNeeded(
                            gid: gid,
                            token: token,
                            totalPages: totalPages
                        )
                    }
                }
            }
            .padding(.horizontal, horizontalContentInset)
            .padding(.top, 16)
            .padding(.bottom, 68)
        }
        #if os(macOS)
        .scrollClipDisabled()
        #endif
        .navigationTitle("预览 (\(galleryPages)张)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .task(id: gid) {
            if vm.allPreviews.isEmpty {
                vm.initialize(initialPreviewSet: initialPreviewSet)
            }
        }
        .overlay {
            if vm.isInitialLoading {
                ProgressView("加载中...")
            }
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
                    SpritePreviewView(preview: normalPreview)
                        .frame(
                            width: previewWidth,
                            height: previewWidth / normalPreview.previewAspectRatio
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

/// 独立预览图加载后读取真实尺寸，使详情页与完整预览窗口都保持原始比例。
struct OriginalRatioPreviewImage: View {
    let url: URL?
    let width: CGFloat
    let cornerRadius: CGFloat

    @State private var aspectRatio: CGFloat = 2.0 / 3.0

    var body: some View {
        CachedAsyncImage(
            url: url,
            onImageSize: { size in
                guard size.width > 0, size.height > 0 else { return }
                aspectRatio = size.width / size.height
            }
        ) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Color(.tertiarySystemFill)
                .overlay { ProgressView() }
        }
        .frame(width: width, height: width / aspectRatio)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

@MainActor
@Observable
class GalleryPreviewsViewModel {
    var allPreviews: [PreviewItem] = []
    var isInitialLoading = false
    var isLoadingMore = false
    var loadError: String?
    private var loadedPages: Set<Int> = []
    private var currentPage = 0
    
    func initialize(initialPreviewSet: PreviewSet) {
        appendPreviews(from: initialPreviewSet)
        loadedPages.insert(0)
        currentPage = 0
    }
    
    func loadNextPageIfNeeded(gid: Int64, token: String, totalPages: Int) async {
        guard !isLoadingMore else { return }
        
        let nextPage = currentPage + 1
        guard nextPage < totalPages else { return }
        guard !loadedPages.contains(nextPage) else { return }
        
        isLoadingMore = true
        loadError = nil
        
        do {
            let site = GalleryActionService.siteBaseURL
            let urlStr = "\(site)g/\(gid)/\(token)/?p=\(nextPage)"
            debugLog("Loading preview page \(nextPage): \(urlStr)")
            let (previewSet, _) = try await EhAPI.shared.getPreviewSet(url: urlStr)
            
            try Task.checkCancellation()
            appendPreviews(from: previewSet)
            loadedPages.insert(nextPage)
            currentPage = nextPage
            isLoadingMore = false
            debugLog("Loaded preview page \(nextPage) with \(previewSet.count) items, total: \(allPreviews.count)")
        } catch {
            isLoadingMore = false
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
            loadError = error.localizedDescription
            debugLog("Failed to load preview page \(nextPage): \(error)")
        }
    }

    func nextPage(totalPages: Int) -> Int? {
        let next = currentPage + 1
        return next < totalPages && !loadedPages.contains(next) ? next : nil
    }
    
    private func appendPreviews(from previewSet: PreviewSet) {
        switch previewSet {
        case .large(let items):
            let newItems = items.map { preview in
                PreviewItem(position: preview.position, type: .large(imageUrl: preview.imageUrl))
            }
            // 去重并排序
            let existingPositions = Set(allPreviews.map { $0.position })
            let filtered = newItems.filter { !existingPositions.contains($0.position) }
            allPreviews.append(contentsOf: filtered)
            allPreviews.sort { $0.position < $1.position }
            
        case .normal(let items):
            let newItems = items.map { preview in
                PreviewItem(position: preview.position, type: .normal(preview))
            }
            let existingPositions = Set(allPreviews.map { $0.position })
            let filtered = newItems.filter { !existingPositions.contains($0.position) }
            allPreviews.append(contentsOf: filtered)
            allPreviews.sort { $0.position < $1.position }
        }
    }
}
