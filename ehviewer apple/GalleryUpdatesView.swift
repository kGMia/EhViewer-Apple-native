import SwiftUI
import EhAPI
import EhCookie
import EhDatabase
import EhModels
import EhSettings

/// Explicit, read-only checks. A cancelled or failed run retains its queue only
/// in memory; resuming never rechecks completed batches or schedules auto-retries.
@MainActor
@Observable
final class GalleryUpdateChecker {
    static let shared = GalleryUpdateChecker()

    struct Candidates: Sendable {
        let galleries: [GalleryInfo]
        var warning: String?
    }

    struct Dependencies {
        var context: () -> String = {
            "\(AppSettings.shared.gallerySite.rawValue):\(EhCookieManager.shared.memberId ?? "guest")"
        }
        var load: (EhSite) async throws -> Candidates = { try await GalleryUpdateChecker.loadCandidates(site: $0) }
        var check: ([GalleryInfo], EhSite) async throws -> [GalleryVersionCheck] = {
            try await EhAPI.shared.getGalleryVersionChecks(galleries: $0, site: $1)
        }
        var pause: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    enum Phase { case idle, preparing, checking, finished, cancelled, failed }
    private(set) var phase: Phase = .idle
    private(set) var checkedCount = 0
    private(set) var totalCount = 0
    private(set) var updates: [GalleryVersionCheck] = []
    private(set) var unavailable: [GalleryVersionCheck] = []
    private(set) var warning: String?
    private(set) var failure: String?
    private(set) var checkedAt: Date?
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var context: String?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var candidates: [GalleryInfo] = []
    @ObservationIgnored private var pending: [GalleryInfo] = []
    @ObservationIgnored private var nextOffset = 0
    @ObservationIgnored private var results: [Int64: GalleryVersionCheck] = [:]
    @ObservationIgnored private var didPrepare = false
    // Keep pacing across cancel/resume and failed requests, not just one loop.
    @ObservationIgnored private var requestCount = 0
    private(set) var remainingCount = 0
    private(set) var queueCount = 0

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    convenience init() {
        self.init(dependencies: Dependencies())
    }

    var isRunning: Bool { phase == .preparing || phase == .checking }
    var canResume: Bool { !isRunning && didPrepare && remainingCount > 0 }
    var canRetryUnavailable: Bool { !isRunning && remainingCount == 0 && !unavailable.isEmpty }
    private var currentContext: String { dependencies.context() }

    func invalidateIfNeeded() {
        guard let context, context != currentContext else { return }
        task?.cancel()
        runID = UUID()
        task = nil
        self.context = nil
        reset()
    }

    private func reset() {
        phase = .idle
        updates = []
        unavailable = []
        checkedCount = 0
        totalCount = 0
        remainingCount = 0
        queueCount = 0
        checkedAt = nil
        warning = nil
        failure = nil
        candidates = []
        pending = []
        nextOffset = 0
        results = [:]
        didPrepare = false
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        invalidateIfNeeded()
        guard !isRunning else { return task }
        reset()
        context = currentContext
        return launch()
    }

    @discardableResult
    func resume() -> Task<Void, Never>? {
        invalidateIfNeeded()
        guard canResume else { return nil }
        return launch()
    }

    @discardableResult
    func retryUnavailable() -> Task<Void, Never>? {
        invalidateIfNeeded()
        guard canRetryUnavailable else { return nil }
        pending = unavailable.map(\.gallery)
        nextOffset = 0
        remainingCount = pending.count
        queueCount = pending.count
        return launch()
    }

    private func launch() -> Task<Void, Never> {
        let identity = currentContext
        let site = AppSettings.shared.gallerySite
        let id = UUID()
        runID = id
        phase = didPrepare ? .checking : .preparing
        failure = nil
        checkedAt = nil
        let work = Task { await run(site: site, identity: identity, id: id) }
        task = work
        return work
    }

    func cancel() { task?.cancel() }

    private func validateRun(identity: String, id: UUID) throws {
        try Task.checkCancellation()
        guard runID == id, context == identity, currentContext == identity else {
            throw CancellationError()
        }
    }

    private func run(site: EhSite, identity: String, id: UUID) async {
        defer { if runID == id { task = nil } }
        do {
            try validateRun(identity: identity, id: id)
            if !didPrepare {
                let snapshot = try await dependencies.load(site)
                try validateRun(identity: identity, id: id)
                candidates = Self.uniqueGalleries(snapshot.galleries)
                pending = candidates
                nextOffset = 0
                totalCount = candidates.count
                remainingCount = pending.count
                queueCount = pending.count
                warning = snapshot.warning
                didPrepare = true
            }
            phase = .checking

            while nextOffset < pending.count {
                // At most 25 per request; pause longer after every four attempts.
                if requestCount > 0 {
                    try await dependencies.pause(.milliseconds(requestCount % 4 == 0 ? 5000 : 500))
                }
                try validateRun(identity: identity, id: id)
                let end = min(nextOffset + 25, pending.count)
                let batch = Array(pending[nextOffset..<end])
                requestCount += 1
                let checks = try await dependencies.check(batch, site)
                try validateRun(identity: identity, id: id)
                var received: [Int64: GalleryVersionCheck] = [:]
                for check in checks { received[check.gallery.gid] = check }
                for gallery in batch {
                    results[gallery.gid] = received[gallery.gid]
                        ?? GalleryVersionCheck(gallery: gallery, error: "Missing gallery metadata")
                }
                nextOffset = end
                remainingCount = pending.count - end
                // One result per original gallery, even when failures are retried.
                checkedCount = results.count
                updates = candidates.compactMap { results[$0.gid] }.filter { $0.latest != nil && $0.error == nil }
                unavailable = candidates.compactMap { results[$0.gid] }.filter { $0.error != nil }
            }
            try validateRun(identity: identity, id: id)
            phase = .finished
            checkedAt = Date()
        } catch {
            guard runID == id, context == identity else { return }
            if currentContext != identity {
                invalidateIfNeeded()
            } else if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                phase = .cancelled
            } else {
                phase = .failed
                failure = error.localizedDescription
            }
        }
    }

    private static func loadCandidates(site: EhSite) async throws -> Candidates {
        let identity = EhCookieManager.shared.memberId
        let signedIn = EhCookieManager.shared.isSignedIn
        var includeCloud = false
        var warning: String?
        if signedIn {
            let index = FavoriteMetadataIndexService.shared
            // Await an explicit outcome. A concurrent/cancelled sync is not proof
            // that its partial on-disk index is a complete favorites snapshot.
            sync: while true {
                try Task.checkCancellation()
                guard AppSettings.shared.gallerySite == site,
                      EhCookieManager.shared.memberId == identity else { throw CancellationError() }
                switch await index.syncIfNeeded(force: true) {
                case .complete:
                    includeCloud = true
                    break sync
                case .busy:
                    try await Task.sleep(for: .milliseconds(200))
                case .cancelled:
                    throw CancellationError()
                case .unchanged:
                    // A forced sync never uses a cached completeness assumption.
                    throw URLError(.badServerResponse)
                case .failed(let error):
                    warning = AppLocalization.format("云端收藏同步未完成，本次仅检查本地收藏与下载：%@", error)
                    break sync
                }
            }
        } else {
            warning = AppLocalization.localized("未登录，仅检查本地收藏与下载。")
        }
        try Task.checkCancellation()
        guard AppSettings.shared.gallerySite == site,
              EhCookieManager.shared.memberId == identity else { throw CancellationError() }
        let shouldIncludeCloud = includeCloud
        let galleries = try await Task.detached(priority: .utility) {
            var values = try EhDatabase.shared.getAllDownloads().map(\.galleryInfo)
            values += try EhDatabase.shared.getAllLocalFavorites().map(\.galleryInfo)
            if shouldIncludeCloud {
                values += try EhDatabase.shared.fetchFavoriteMetadata(site: site.rawValue).map(\.galleryInfo)
            }
            return Self.uniqueGalleries(values)
        }.value
        return Candidates(galleries: galleries, warning: warning)
    }

    nonisolated static func uniqueGalleries(_ galleries: [GalleryInfo]) -> [GalleryInfo] {
        var seen: Set<Int64> = []
        return galleries.filter { $0.gid > 0 && !$0.token.isEmpty && seen.insert($0.gid).inserted }
    }
}

struct GalleryUpdatesView: View {
    @State private var checker = GalleryUpdateChecker.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("手动检查收藏与下载是否有新版。不会自动下载、替换旧文件或修改收藏。")
                        .font(.callout)
                    if checker.phase == .preparing {
                        ProgressView("正在同步收藏并读取本地资料…")
                        if FavoriteMetadataIndexService.shared.isSyncing {
                            Text("已同步 \(FavoriteMetadataIndexService.shared.completedPages) 页")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } else if checker.isRunning {
                        ProgressView(value: Double(checker.queueCount - checker.remainingCount),
                                     total: Double(max(1, checker.queueCount)))
                    }
                    Text("已检查 \(checker.checkedCount) / \(checker.totalCount) · 新版 \(checker.updates.count) · 未能检查 \(checker.unavailable.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if checker.remainingCount > 0 {
                        Text("待检查 \(checker.remainingCount) 项")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let date = checker.checkedAt {
                        LabeledContent("检查时间") { Text(date, format: .dateTime) }
                            .font(.caption)
                    }
                    if let warning = checker.warning { Text(warning).font(.caption).foregroundStyle(.secondary) }
                    if let failure = checker.failure { Text(failure).font(.caption).foregroundStyle(.red) }
                    switch checker.phase {
                    case .finished where checker.totalCount == 0:
                        Text("没有可检查的收藏或下载。")
                    case .finished where checker.updates.isEmpty:
                        Text(AppLocalization.localized(checker.unavailable.isEmpty && checker.warning == nil
                             ? "本次检查未发现新版。" : "已完成的检查中未发现新版，部分范围或项目未能检查。"))
                            .font(.callout)
                    case .cancelled: Text("检查已取消，以下为已完成的部分结果。")
                    default: EmptyView()
                    }
                    if checker.isRunning {
                        Button("取消检查", systemImage: "stop.circle") { checker.cancel() }
                    } else {
                        if checker.canResume {
                            Button("继续检查", systemImage: "play.circle") { checker.resume() }
                        }
                        if checker.canRetryUnavailable {
                            Button("仅重试失败项", systemImage: "arrow.clockwise") { checker.retryUnavailable() }
                        }
                        Button(AppLocalization.localized(checker.phase == .idle ? "检查画廊更新" : "重新检查全部")) {
                            checker.start()
                        }
                    }
                } footer: {
                    Text("结果保留至退出应用；打开新版后可自行决定是否下载。")
                }

                if !checker.updates.isEmpty {
                    Section("发现新版") {
                        ForEach(checker.updates, id: \.gallery.gid) { check in
                            if let latest = check.latest {
                                NavigationLink {
                                    GalleryDetailView(gallery: latest)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(check.gallery.suitableTitle(preferJpn: AppSettings.shared.showJpnTitle))
                                            .lineLimit(2)
                                        Text("#\(check.gallery.gid) → #\(latest.gid)")
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        Text("查看新版").font(.caption).foregroundStyle(Color.accentColor)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
                if !checker.unavailable.isEmpty {
                    Section("未能检查") {
                        ForEach(checker.unavailable, id: \.gallery.gid) { check in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(check.gallery.suitableTitle(preferJpn: AppSettings.shared.showJpnTitle)).lineLimit(2)
                                Text(AppLocalization.localized(check.error ?? "")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("画廊更新")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .onAppear { checker.invalidateIfNeeded() }
        .onChange(of: AppSettings.shared.gallerySite) { _, _ in checker.invalidateIfNeeded() }
        .onDisappear { checker.cancel() }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 620, minHeight: 400, idealHeight: 580)
        #endif
    }
}
