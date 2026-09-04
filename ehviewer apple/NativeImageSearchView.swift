import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import EhAPI
import EhModels
import EhSettings
import EhCookie

struct ImageSearchPresentationAction {
    let present: @MainActor (Data) -> Void
}

struct NativeImageSearchRoute: Identifiable {
    let id = UUID()
    let initialData: Data?
}

private struct ImageSearchPresentationActionKey: EnvironmentKey {
    static let defaultValue: ImageSearchPresentationAction? = nil
}

extension EnvironmentValues {
    var imageSearchPresentationAction: ImageSearchPresentationAction? {
        get { self[ImageSearchPresentationActionKey.self] }
        set { self[ImageSearchPresentationActionKey.self] = newValue }
    }
}

struct SearchImage: @unchecked Sendable {
    let original: Data
    let originalType: String?
    let thumbnail: CGImage
    let similarityData: Data

    nonisolated static func prepare(_ data: Data) throws -> SearchImage {
        guard !data.isEmpty, data.count <= 20 * 1024 * 1024 else { throw PreparationError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw PreparationError.invalidImage }
        let type = CGImageSourceGetType(source) as String?
        let mime: String? = switch type {
        case UTType.jpeg.identifier: "image/jpeg"
        case UTType.png.identifier: "image/png"
        case UTType.gif.identifier: "image/gif"
        default: nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PreparationError.invalidImage
        }
        // A bounded preview strips metadata for similarity search. Exact search
        // deliberately preserves the file bytes because its hash is significant.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PreparationError.invalidImage }
        return SearchImage(original: data, originalType: mime, thumbnail: image, similarityData: output as Data)
    }

    enum PreparationError: Error { case tooLarge, invalidImage }
}

struct NativeImageSearchView: View {
    let initialData: Data?
    let onResult: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var showFiles = false
    @State private var image: SearchImage?
    @State private var similarity = true
    @State private var coversOnly = false
    @State private var isBusy = false
    @State private var isUploading = false
    @State private var message: String?
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var didPrepareInitialData = false

    init(initialData: Data? = nil, onResult: @escaping (URL) -> Void) {
        self.initialData = initialData
        self.onResult = onResult
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                            Label("选择照片", systemImage: "photo.on.rectangle")
                        }
                        Button("选择图片文件", systemImage: "folder") { showFiles = true }
                    }
                    .disabled(isBusy)
                    if let image {
                        Image(decorative: image.thumbnail, scale: 1)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Toggle("搜索相似图片", isOn: $similarity)
                        .disabled(isBusy)
                    Toggle("仅搜索封面", isOn: $coversOnly)
                        .disabled(isBusy)
                    if !similarity && image?.originalType == nil {
                        Text("精确匹配需要 JPEG、PNG 或 GIF 原文件；其他格式请使用相似搜索。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                    if isBusy {
                        ProgressView(AppLocalization.localized(isUploading ? "正在上传搜索图片…" : "正在准备图片…"))
                    }
                    Button("开始以图搜图", systemImage: "magnifyingglass") { search() }
                        .disabled(isBusy || image == nil || (!similarity && image?.originalType == nil))
                } footer: {
                    Text("仅点击开始后上传到当前 EH/EX 站点。相似搜索使用去除元数据的缩略图；精确搜索上传原文件（可能包含位置等元数据）。单张文件上限为 20 MB。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("以图搜图")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { work?.cancel(); dismiss() }
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                prepare {
                    try await Task.detached(priority: .userInitiated) {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 20 * 1024 * 1024 else { throw SearchImage.PreparationError.tooLarge }
                        return try SearchImage.prepare(Data(contentsOf: url))
                    }.value
                }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            prepare {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw SearchImage.PreparationError.invalidImage
                }
                return try await Task.detached(priority: .userInitiated) { try SearchImage.prepare(data) }.value
            }
        }
        .task {
            guard !didPrepareInitialData, let initialData else { return }
            didPrepareInitialData = true
            prepare {
                try await Task.detached(priority: .userInitiated) {
                    try SearchImage.prepare(initialData)
                }.value
            }
        }
        .onDisappear { work?.cancel(); generation = UUID() }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 440, idealHeight: 630)
        #endif
    }

    private func prepare(_ operation: @escaping @Sendable () async throws -> SearchImage) {
        work?.cancel()
        let id = UUID()
        generation = id
        image = nil
        message = nil
        isBusy = true
        isUploading = false
        work = Task {
            defer { if generation == id { isBusy = false } }
            do {
                let value = try await operation()
                guard !Task.isCancelled, generation == id else { return }
                image = value
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                message = AppLocalization.localized(error as? SearchImage.PreparationError == .tooLarge
                    ? "图片超过 20 MB，请选择较小的文件。" : "无法读取图片，请选择有效的图片文件。")
            }
        }
    }

    private func search() {
        guard let image, !isBusy else { return }
        let site = AppSettings.shared.gallerySite
        let member = EhCookieManager.shared.memberId
        let useSimilarity = similarity
        let covers = coversOnly
        isBusy = true
        isUploading = true
        message = nil
        work = Task {
            defer { isBusy = false; isUploading = false }
            do {
                let url = try await EhAPI.shared.uploadSearchImage(
                    imageData: useSimilarity ? image.similarityData : image.original,
                    contentType: useSimilarity ? "image/jpeg" : (image.originalType ?? ""),
                    site: site, useSimilarity: useSimilarity, onlyCovers: covers
                )
                try Task.checkCancellation()
                guard site == AppSettings.shared.gallerySite, member == EhCookieManager.shared.memberId else { return }
                onResult(url)
            } catch {
                guard !Task.isCancelled else { return }
                message = AppLocalization.localized("以图搜图失败，请检查网络、登录状态或换一张图片重试。")
            }
        }
    }
}
