import SwiftUI
import EhModels
import EhSettings

/// Keep one stable action on the trailing edge for both add and remove.
struct GalleryWatchLaterSwipeButton: View {
    let gallery: GalleryInfo
    @State private var isUpdating = false

    var body: some View {
        let service = GalleryActionService.shared
        let isSaved = service.isInWatchLater(gid: gallery.gid)
        Button {
            guard !isUpdating else { return }
            isUpdating = true
            Task {
                defer { isUpdating = false }
                if service.isInWatchLater(gid: gallery.gid) {
                    await service.removeFromWatchLater(gid: gallery.gid)
                } else {
                    await service.addToWatchLater(gallery)
                }
            }
        } label: {
            Label(AppLocalization.localized(isSaved ? "移除" : "稍后再看"),
                  systemImage: isSaved ? "bookmark.slash" : "bookmark")
        }
        .tint(.orange)
        .disabled(isUpdating)
        .accessibilityLabel(AppLocalization.localized(isSaved ? "移除稍后再看" : "稍后再看"))
    }
}
