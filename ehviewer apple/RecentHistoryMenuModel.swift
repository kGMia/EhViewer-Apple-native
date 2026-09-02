import Foundation
import Observation
import EhDatabase

extension Notification.Name {
    static let ehHistoryDidChange = Notification.Name("ehViewerHistoryDidChange")
}

/// Small, independently refreshed snapshot used by the native macOS Browse menu.
/// Database work stays off the main actor so opening menus never waits on SQLite.
@MainActor
@Observable
final class RecentHistoryMenuModel {
    static let shared = RecentHistoryMenuModel()

    private(set) var records: [HistoryRecord] = []
    private var changeObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?

    private init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .ehHistoryDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await RecentHistoryMenuModel.shared.refresh()
            }
        }
    }

    func refresh() async {
        refreshTask?.cancel()
        let task = Task { @MainActor in
            do {
                let recent = try await Task.detached(priority: .utility) {
                    try EhDatabase.shared.getAllHistory(limit: 10)
                }.value
                guard !Task.isCancelled else { return }
                records = recent
            } catch {
                debugLog("Failed to refresh history menu: \(error)")
            }
        }
        refreshTask = task
        await task.value
    }
}
