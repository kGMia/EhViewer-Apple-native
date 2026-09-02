//
//  DownloadLiveActivity.swift
//  ehviewer apple
//

#if os(iOS)
import ActivityKit
import Foundation
import EhSettings

struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var progress: Double
        var downloadedPages: Int
        var totalPages: Int
        var speed: Int64
        var statusText: String
    }

    var gid: Int64
    var title: String
}

/// 下载队列当前串行执行，因此一次只保留一个 Live Activity。
/// 每秒最多推送一次状态，减少 ActivityKit/Widget 刷新与电量消耗。
@MainActor
final class DownloadLiveActivityManager {
    static let shared = DownloadLiveActivityManager()

    private var currentActivity: Activity<DownloadActivityAttributes>?
    private var currentGID: Int64?
    private var lastUpdateTime: Date = .distantPast
    private var latestDownloaded = 0
    private var latestTotal = 0
    private var lastPublishedState: DownloadActivityAttributes.ContentState?
    private let updateInterval: TimeInterval = 1

    private init() {
        if let activity = Activity<DownloadActivityAttributes>.activities.first {
            currentActivity = activity
            currentGID = activity.attributes.gid
        }
    }

    func startActivity(gid: Int64, title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if currentGID == gid, currentActivity != nil { return }
        endActivity()

        let attributes = DownloadActivityAttributes(gid: gid, title: title)
        let state = DownloadActivityAttributes.ContentState(
            progress: 0,
            downloadedPages: 0,
            totalPages: 0,
            speed: 0,
            statusText: AppLocalization.localized("正在下载")
        )
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: .now.addingTimeInterval(90)),
                pushType: nil
            )
            currentGID = gid
            lastUpdateTime = .distantPast
            latestDownloaded = 0
            latestTotal = 0
            lastPublishedState = state
        } catch {
            debugLog("[LiveActivity] 启动失败: \(error)")
        }
    }

    func updateProgress(gid: Int64, downloaded: Int, total: Int, speed: Int64) {
        guard gid == currentGID, let activity = currentActivity else { return }
        latestDownloaded = downloaded
        latestTotal = total

        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= updateInterval else { return }
        lastUpdateTime = now
        let progress = total > 0 ? min(1, max(0, Double(downloaded) / Double(total))) : 0
        let state = DownloadActivityAttributes.ContentState(
            progress: progress,
            downloadedPages: downloaded,
            totalPages: total,
            speed: max(0, speed),
            statusText: AppLocalization.localized("正在下载")
        )
        guard state != lastPublishedState else { return }
        lastPublishedState = state
        Task {
            await activity.update(
                .init(state: state, staleDate: now.addingTimeInterval(90))
            )
        }
    }

    func finishActivity(gid: Int64, success: Bool) {
        guard gid == currentGID, let activity = currentActivity else { return }
        let state = DownloadActivityAttributes.ContentState(
            progress: success ? 1 : (latestTotal > 0 ? Double(latestDownloaded) / Double(latestTotal) : 0),
            downloadedPages: success ? max(latestDownloaded, latestTotal) : latestDownloaded,
            totalPages: latestTotal,
            speed: 0,
            statusText: AppLocalization.localized(success ? "下载完成" : "下载失败")
        )
        currentActivity = nil
        currentGID = nil
        lastPublishedState = nil
        Task {
            await activity.end(
                .init(state: state, staleDate: nil),
                dismissalPolicy: success ? .after(.now + 8) : .default
            )
        }
    }

    func endActivity(gid: Int64? = nil) {
        guard gid == nil || gid == currentGID else { return }
        let activity = currentActivity
        currentActivity = nil
        currentGID = nil
        lastPublishedState = nil
        Task { await activity?.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
