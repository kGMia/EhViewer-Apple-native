import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

nonisolated struct DownloadActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var progress: Double
        var downloadedPages: Int
        var totalPages: Int
        var speed: Int64
        var statusText: String
    }

    var gid: Int64
    var title: String
}

@main
struct EhViewerLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivityWidget()
    }
}

struct DownloadLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(context.state.statusText, systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                    Link(destination: Self.pauseURL(gid: context.attributes.gid)) {
                        Image(systemName: "pause.fill")
                            .font(.caption.weight(.semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("暂停下载")
                }
                Text(context.attributes.title)
                    .font(.caption)
                    .lineLimit(1)
                Link(destination: Self.downloadsURL) {
                    ProgressView(value: context.state.progress)
                        .tint(.accentColor)
                }
                .accessibilityLabel("打开下载页")
                HStack {
                    Text("\(context.state.downloadedPages)/\(context.state.totalPages) 页")
                    Spacer()
                    Text(Self.speed(context.state.speed))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding()
            .activityBackgroundTint(Color(uiColor: .systemBackground))
            .activitySystemActionForegroundColor(.primary)
            .widgetURL(Self.downloadsURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 8) {
                        Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.tint)
                        Link(destination: Self.pauseURL(gid: context.attributes.gid)) {
                            Image(systemName: "pause.fill")
                                .frame(width: 28, height: 28)
                                .contentShape(Circle())
                        }
                        .accessibilityLabel("暂停下载")
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 5) {
                        Link(destination: Self.downloadsURL) {
                            ProgressView(value: context.state.progress).tint(.accentColor)
                        }
                        .accessibilityLabel("打开下载页")
                        HStack {
                            Text("\(context.state.downloadedPages)/\(context.state.totalPages)")
                            Spacer()
                            Text(Self.speed(context.state.speed))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            } compactTrailing: {
                Link(destination: Self.downloadsURL) {
                    Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tint)
                }
            } minimal: {
                Image(systemName: "arrow.down").foregroundStyle(.tint)
            }
        }
    }

    private static let downloadsURL = URL(string: "ehviewer://downloads")!

    private static func pauseURL(gid: Int64) -> URL {
        URL(string: "ehviewer://pause-download?gid=\(gid)")!
    }

    private static func speed(_ bytesPerSecond: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file) + "/s"
    }
}
