import Foundation
import Observation
import EhAPI
import EhDatabase
import EhModels
import EhSettings

/// Incrementally mirrors cloud-favorite list metadata into GRDB. Network pages
/// are committed one at a time, while stale rows are pruned only after the
/// complete cursor chain succeeds.
@MainActor
@Observable
final class FavoriteMetadataIndexService {
    static let shared = FavoriteMetadataIndexService()

    private(set) var isSyncing = false
    private(set) var indexedCount = 0
    private(set) var completedPages = 0
    private(set) var lastError: String?
    private(set) var revision = 0

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private let refreshInterval: TimeInterval = 6 * 60 * 60

    func syncIfNeeded(force: Bool = false) async {
        let site = AppSettings.shared.gallerySite
        let defaultsKey = "favoriteMetadataIndex.lastSync.\(site.rawValue)"
        let lastSync = UserDefaults.standard.object(forKey: defaultsKey) as? Date
        let siteValue = site.rawValue
        let existingCount = await Task.detached(priority: .utility) {
            (try? EhDatabase.shared.favoriteMetadataCount(site: siteValue)) ?? 0
        }.value
        indexedCount = existingCount
        guard force || existingCount == 0 || lastSync.map({ Date().timeIntervalSince($0) > refreshInterval }) != false else {
            return
        }
        guard !isSyncing else { return }

        isSyncing = true
        completedPages = 0
        lastError = nil
        let syncID = UUID().uuidString
        let syncedAt = Date()

        do {
            var href = FavListUrlBuilder(favCat: -1).build(site: site)
            var visited: Set<String> = []
            var serverOrder = 0

            while visited.insert(href).inserted, completedPages < 2_000 {
                try Task.checkCancellation()
                let result = try await EhAPI.shared.getGalleryList(url: href)
                try Task.checkCancellation()

                let records = result.galleries.map { gallery in
                    defer { serverOrder += 1 }
                    return gallery.favoriteMetadataRecord(
                        site: site,
                        serverOrder: serverOrder,
                        syncID: syncID,
                        syncedAt: syncedAt
                    )
                }
                try await Task.detached(priority: .utility) {
                    try EhDatabase.shared.saveFavoriteMetadataPage(records)
                }.value
                completedPages += 1

                guard let next = result.nextHref, !next.isEmpty else { break }
                href = resolved(next, site: site)
                // Be courteous to EH and keep this background mirror below
                // interactive browsing traffic.
                try await Task.sleep(for: .milliseconds(100))
            }

            try await Task.detached(priority: .utility) {
                try EhDatabase.shared.finishFavoriteMetadataSync(site: site.rawValue, syncID: syncID)
            }.value
            indexedCount = try await Task.detached(priority: .utility) {
                try EhDatabase.shared.favoriteMetadataCount(site: siteValue)
            }.value
            UserDefaults.standard.set(Date(), forKey: defaultsKey)
            revision &+= 1
        } catch is CancellationError {
            // A later appearance or explicit refresh resumes with a fresh
            // generation; the last complete index remains queryable.
        } catch {
            lastError = error.localizedDescription
            let fallbackCount = await Task.detached(priority: .utility) {
                try? EhDatabase.shared.favoriteMetadataCount(site: siteValue)
            }.value
            indexedCount = fallbackCount ?? indexedCount
        }
        isSyncing = false
    }

    func forceSync() {
        syncTask?.cancel()
        syncTask = Task { await syncIfNeeded(force: true) }
    }

    private func resolved(_ href: String, site: EhSite) -> String {
        if let url = URL(string: href), url.scheme != nil { return url.absoluteString }
        return URL(string: href, relativeTo: URL(string: EhURL.host(for: site)))?
            .absoluteURL.absoluteString ?? href
    }
}
