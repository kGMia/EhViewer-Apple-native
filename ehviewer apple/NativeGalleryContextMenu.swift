import SwiftUI
import EhSettings

/// URL payload and local preview shared by both detail layouts and platforms.
struct GalleryShareLink<Label: View>: View {
    let urlString: String
    let title: String
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let url = URL(string: urlString) {
            ShareLink(item: url, preview: SharePreview(title), label: label)
        }
    }
}

#if os(iOS)
/// SwiftUI owns lifting and returning the source. Waterfall previews provide
/// live title scrolling without modifying the visibility of the source card.
struct GalleryActionMenu: ViewModifier {
    let title: String
    let isWatchLater: Bool
    let isFavorited: Bool
    let shareURL: URL?
    let toggleWatchLater: @MainActor @Sendable () -> Void
    let download: @MainActor @Sendable () -> Void
    let toggleFavorite: @MainActor @Sendable () -> Void
    let copyLink: @MainActor @Sendable () -> Void
    var listPreview: GalleryListPreview? = nil
    var waterfallPreview: GalleryWaterfallPreview? = nil

    @ViewBuilder
    func body(content: Content) -> some View {
        if let waterfallPreview, !GalleryPreviewDiagnostics.useSystemSnapshot {
            content
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 13))
                .contextMenu { menuItems } preview: { waterfallPreview }
        } else if let listPreview, !GalleryPreviewDiagnostics.useSystemSnapshot {
            content
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 13))
                .contextMenu { menuItems } preview: { listPreview }
        } else {
            content
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 13))
                .contextMenu { menuItems }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        let _ = PerformanceDiagnostics.event("GalleryMenuContentRequested")
        Button(action: toggleWatchLater) {
            Label(AppLocalization.localized(isWatchLater ? "从稍后再看移除" : "稍后再看"),
                  systemImage: isWatchLater ? "bookmark.slash" : "bookmark")
        }
        Button(action: download) {
            Label("下载", systemImage: "arrow.down.circle")
        }
        Button(action: toggleFavorite) {
            Label(AppLocalization.localized(isFavorited ? "取消收藏" : "收藏"),
                  systemImage: isFavorited ? "heart.slash" : "heart")
        }
        Divider()
        Button(action: copyLink) {
            Label("复制链接", systemImage: "doc.on.doc")
        }
        if let shareURL, !GalleryPreviewDiagnostics.omitShareLink {
            ShareLink(item: shareURL, preview: SharePreview(title)) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// A larger horizontal card; no network work or source visibility changes.
struct GalleryListPreview: View {
    let title: String
    let thumbnailURL: URL?
    let uploader: String?
    let category: String
    let pages: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Color(uiColor: .secondarySystemBackground)
                .frame(width: 120, height: 174)
                .overlay {
                    if let image = thumbnailURL.flatMap({ ThumbnailMemoryCache.shared.get($0) }) {
                        Image(uiImage: image.images?.first ?? image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .clipShape(.rect(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                if let uploader, !uploader.isEmpty {
                    Text(uploader).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(category).font(.caption).foregroundStyle(.secondary)
                if let pages {
                    Text("\(pages)P").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 312)
        .frame(minHeight: 174)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 13))
        .accessibilityElement(children: .combine)
        .onAppear { PerformanceDiagnostics.event("GalleryListPreviewAppeared") }
        .onDisappear { PerformanceDiagnostics.event("GalleryListPreviewDisappeared") }
    }
}

struct GalleryWaterfallPreview: View {
    let title: String
    let thumbnailURL: URL?
    let aspectRatio: CGFloat

    var body: some View {
        let _ = PerformanceDiagnostics.event("GalleryPreviewBody")
        VStack(spacing: 9) {
            Color(uiColor: .secondarySystemBackground)
                .frame(height: min(360, 256 / max(aspectRatio, 0.2)))
                .overlay {
                    // Read the already decoded thumbnail when the preview is
                    // requested; no image request or row-local preview state.
                    if let image = thumbnailURL.flatMap({ ThumbnailMemoryCache.shared.get($0) }) {
                        Image(uiImage: image.images?.first ?? image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
            if GalleryPreviewDiagnostics.useStaticTitle {
                Text(title).font(.subheadline).lineLimit(1)
            } else {
                GalleryPreviewMarquee(title: title)
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .onAppear { PerformanceDiagnostics.event("GalleryPreviewAppeared") }
        .onDisappear { PerformanceDiagnostics.event("GalleryPreviewDisappeared") }
    }
}

private struct GalleryPreviewMarquee: View {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var lineHeight: CGFloat = 22
    @State private var textWidth: CGFloat = 0
    @State private var started = Date()
    @State private var isVisible = false

    var body: some View {
        GeometryReader { geometry in
            let distance = max(0, textWidth - geometry.size.width)
            TimelineView(.animation(minimumInterval: 1.0 / 30,
                                    paused: !isVisible || reduceMotion || distance <= 1)) { timeline in
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        textWidth = $0
                        started = Date()
                    }
                    .offset(x: reduceMotion ? 0 : GalleryMarqueeMotion.offset(
                        elapsed: timeline.date.timeIntervalSince(started), distance: distance
                    ))
                    .frame(height: lineHeight, alignment: .leading)
            }
            .onChange(of: geometry.size.width) { _, _ in started = Date() }
        }
        .frame(height: lineHeight)
        .clipped()
        .accessibilityLabel(title)
        .onAppear { started = Date(); isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: title) { _, _ in started = Date() }
        .onChange(of: reduceMotion) { _, _ in started = Date() }
    }
}
#endif

/// Pauses at both ends and traverses the complete title without a snap back.
enum GalleryMarqueeMotion {
    nonisolated static func offset(elapsed: TimeInterval, distance: CGFloat) -> CGFloat {
        guard distance > 1, elapsed > 0 else { return 0 }
        let pause = 0.7
        let travel = max(1, Double(distance) / 38)
        let phase = elapsed.truncatingRemainder(dividingBy: 2 * (pause + travel))
        if phase < pause { return 0 }
        if phase < pause + travel { return -distance * (phase - pause) / travel }
        if phase < 2 * pause + travel { return -distance }
        return -distance * (1 - (phase - 2 * pause - travel) / travel)
    }
}


#if os(macOS)
import AppKit

/// AppKit-backed feed menu. SwiftUI's contextMenu bridge performs a one-time
/// hosting-tree snapshot on the first secondary click; this view receives only
/// right-clicks and builds a small NSMenu directly, while ordinary clicks pass
/// through to the surrounding SwiftUI Button/List selection.
struct NativeGalleryContextMenu: NSViewRepresentable {
    let isWatchLater: Bool
    let isFavorited: Bool
    let shareURL: URL?
    let toggleWatchLater: @MainActor @Sendable () -> Void
    let download: @MainActor @Sendable () -> Void
    let toggleFavorite: @MainActor @Sendable () -> Void
    let copyLink: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: RightClickView, context: Context) {
        context.coordinator.configuration = Configuration(
            isWatchLater: isWatchLater,
            isFavorited: isFavorited,
            shareURL: shareURL,
            toggleWatchLater: { toggleWatchLater() },
            download: { download() },
            toggleFavorite: { toggleFavorite() },
            copyLink: { copyLink() }
        )
        context.coordinator.sourceView = nsView
    }

    @MainActor
    final class Coordinator: NSObject {
        var configuration: Configuration? {
            didSet { rebuildMenu() }
        }
        private var preparedMenu: NSMenu?
        private var preparedMenuKey: MenuKey?

        private struct MenuKey: Equatable {
            let isWatchLater: Bool
            let isFavorited: Bool
            let canShare: Bool
            let language: String
            let locale: String
        }
        weak var sourceView: NSView?
        private var sharingPicker: NSSharingServicePicker?

        func menu() -> NSMenu? {
            rebuildMenu()
            return preparedMenu
        }

        private func rebuildMenu() {
            guard let configuration else {
                preparedMenu = nil
                preparedMenuKey = nil
                return
            }
            let key = MenuKey(
                isWatchLater: configuration.isWatchLater,
                isFavorited: configuration.isFavorited,
                canShare: configuration.shareURL != nil,
                language: AppSettings.shared.appLanguage.rawValue,
                locale: Locale.current.identifier
            )
            guard key != preparedMenuKey else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(item(
                title: AppLocalization.localized(
                    configuration.isWatchLater ? "从稍后再看移除" : "稍后再看"
                ),
                symbol: configuration.isWatchLater ? "bookmark.slash" : "bookmark",
                actionIndex: 0
            ))
            menu.addItem(item(title: AppLocalization.localized("下载"), symbol: "arrow.down.circle", actionIndex: 1))
            menu.addItem(item(
                title: AppLocalization.localized(configuration.isFavorited ? "取消收藏" : "收藏"),
                symbol: configuration.isFavorited ? "heart.slash" : "heart",
                actionIndex: 2
            ))
            menu.addItem(.separator())
            menu.addItem(item(title: AppLocalization.localized("复制链接"), symbol: "doc.on.doc", actionIndex: 3))
            if configuration.shareURL != nil {
                menu.addItem(item(title: AppLocalization.localized("分享"), symbol: "square.and.arrow.up", actionIndex: 4))
            }
            preparedMenu = menu
            preparedMenuKey = key
        }

        private func item(title: String, symbol: String, actionIndex: Int) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = actionIndex
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.isEnabled = true
            return item
        }

        @objc private func performAction(_ sender: NSMenuItem) {
            guard let configuration else { return }
            switch sender.tag {
            case 0: configuration.toggleWatchLater()
            case 1: configuration.download()
            case 2: configuration.toggleFavorite()
            case 3: configuration.copyLink()
            case 4:
                guard let url = configuration.shareURL, let sourceView else { return }
                let picker = NSSharingServicePicker(items: [url])
                sharingPicker = picker
                picker.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .minY)
            default: break
            }
        }
    }

    struct Configuration {
        let isWatchLater: Bool
        let isFavorited: Bool
        let shareURL: URL?
        let toggleWatchLater: @MainActor @Sendable () -> Void
        let download: @MainActor @Sendable () -> Void
        let toggleFavorite: @MainActor @Sendable () -> Void
        let copyLink: @MainActor @Sendable () -> Void
    }

    final class RightClickView: NSView {
        weak var coordinator: Coordinator?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = window?.currentEvent ?? NSApp.currentEvent,
                  event.type == .rightMouseDown else { return nil }
            return bounds.contains(point) ? self : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = coordinator?.menu() else {
                super.rightMouseDown(with: event)
                return
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
#endif
