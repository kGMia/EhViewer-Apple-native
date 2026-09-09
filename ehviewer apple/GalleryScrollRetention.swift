import SwiftUI

/// Retain an item and its position within the viewport when prepending a page.
@MainActor @Observable
final class GalleryScrollRetention {
    struct Anchor {
        let id: Int64
        let alignment: CGFloat
    }
    struct Request {
        let token = UUID()
        let anchor: Anchor
    }

    let coordinateSpace = UUID()
    @ObservationIgnored var frames: [Int64: CGRect] = [:]
    @ObservationIgnored private var frameOwners: [Int64: UUID] = [:]
    @ObservationIgnored var viewportHeight: CGFloat = 0
    var request: Request?

    func update(_ frame: CGRect, id: Int64, owner: UUID) {
        frames[id] = frame
        frameOwners[id] = owner
    }

    func remove(id: Int64, owner: UUID) {
        // A replaced lazy column can disappear after its replacement reports
        // geometry for the same gallery; do not erase the replacement.
        guard frameOwners[id] == owner else { return }
        frames.removeValue(forKey: id)
        frameOwners.removeValue(forKey: id)
    }

    func capture() -> Anchor? {
        guard let entry = frames
            .filter({ $0.value.maxY > 0 && $0.value.minY < viewportHeight })
            .min(by: { $0.value.minY < $1.value.minY }) else { return nil }
        let available = viewportHeight - entry.value.height
        return Anchor(id: entry.key, alignment: abs(available) > 1 ? entry.value.minY / available : 0)
    }
}

struct GalleryScrollAnchorRow: ViewModifier {
    let retention: GalleryScrollRetention?
    let id: Int64
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        if let retention {
            content
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(retention.coordinateSpace))
                } action: { retention.update($0, id: id, owner: owner) }
                .onDisappear { retention.remove(id: id, owner: owner) }
        } else {
            content
        }
    }
}

struct GalleryScrollRetentionModifier: ViewModifier {
    let retention: GalleryScrollRetention?
    var isLayoutReady: Bool = true

    private struct Update: Equatable {
        let token: UUID?
        let isLayoutReady: Bool
    }

    func body(content: Content) -> some View {
        if let retention {
            ScrollViewReader { proxy in
                content
                    .coordinateSpace(name: retention.coordinateSpace)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        retention.viewportHeight = $0
                    }
                    .task(id: Update(token: retention.request?.token, isLayoutReady: isLayoutReady)) {
                        guard let request = retention.request,
                              isLayoutReady else { return }
                        // This task belongs to the rendered layout, not the
                        // network task; deferred waterfall columns are ready.
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo(request.anchor.id,
                                           anchor: UnitPoint(x: 0.5, y: request.anchor.alignment))
                        }
                        retention.request = nil
                    }
            }
        } else {
            content
        }
    }
}

struct GalleryPreviousPageButton: View {
    let isLoading: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Label("加载上一页", systemImage: "arrow.up")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityIdentifier("gallery.pagination.previous")
    }
}
