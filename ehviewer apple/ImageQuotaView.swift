import SwiftUI
import EhAPI
import EhCookie
import EhModels
import EhParser
import EhSettings

@MainActor
@Observable
final class ImageQuotaViewModel {
    private(set) var detail: HomeDetail?
    private(set) var updatedAt: Date?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadedContext: String?
    @ObservationIgnored private let loader: () async throws -> HomeDetail
    @ObservationIgnored private let context: () -> String

    init(loader: @escaping () async throws -> HomeDetail = { try await EhAPI.shared.getHomeDetail() },
         context: @escaping () -> String = {
             "\(AppSettings.shared.gallerySite.rawValue):\(EhCookieManager.shared.memberId ?? "guest"):\(EhCookieManager.shared.isSignedIn)"
         }) {
        self.loader = loader
        self.context = context
    }

    var remaining: Int { max(0, (detail?.totalLimit ?? 0) - (detail?.currentUsed ?? 0)) }

    func invalidateIfNeeded() {
        guard let loadedContext, loadedContext != context() else { return }
        cancel()
        detail = nil
        updatedAt = nil
        errorMessage = nil
        self.loadedContext = nil
    }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        invalidateIfNeeded()
        if isLoading, let task { return task }
        let identity = context()
        loadedContext = identity
        let id = UUID()
        generation = id
        isLoading = true
        errorMessage = nil
        let work = Task {
            defer { if generation == id { isLoading = false; task = nil } }
            do {
                try Task.checkCancellation()
                let result = try await loader()
                try Task.checkCancellation()
                guard generation == id else { return }
                guard identity == context() else { invalidateIfNeeded(); return }
                guard result.limitMode != .account || (result.totalLimit > 0 && result.currentUsed >= 0) else {
                    throw EhParseError.parseFailure("Image quota unavailable")
                }
                detail = result
                updatedAt = Date()
            } catch {
                guard generation == id, !Task.isCancelled else { return }
                guard identity == context() else { invalidateIfNeeded(); return }
                if (error as? URLError)?.code == .cancelled { return }
                if case EhParseError.parseFailure(let reason) = error {
                    switch reason {
                    case "Image quota requires sign-in":
                        errorMessage = AppLocalization.localized("配额页面要求重新登录 E-Hentai。应用中的登录凭据可能已过期；浏览器的登录状态与应用并不共享。")
                    case "Image quota blocked by verification":
                        errorMessage = AppLocalization.localized("配额请求被网站验证拦截，请检查网络或稍后重试。")
                    default:
                        errorMessage = AppLocalization.localized("已收到网页，但未识别到配额信息。请在网站确认是否显示额度，并反馈页面中的配额文字。")
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
        task = work
        return work
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }
}

struct ImageQuotaView: View {
    @State private var vm = ImageQuotaViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let detail = vm.detail {
                        if detail.limitMode != .account {
                            Label("IP 限制模式", systemImage: "network")
                            Text(AppLocalization.localized(detail.limitMode == .ipBasedUnrestricted
                                 ? "目前没有限制" : "当前使用 IP 限制，具体状态请在网站查看。"))
                                .font(.headline)
                            Text("网站未提供数字配额，因此不显示已用、剩余和上限。这不代表账户拥有无限额度。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                        ProgressView(value: Double(min(detail.currentUsed, detail.totalLimit)),
                                     total: Double(detail.totalLimit))
                            .tint(AppSettings.shared.accentColor.previewColor)
                            .accessibilityLabel("已用额度")
                        LabeledContent("已用额度", value: detail.currentUsed.formatted())
                        LabeledContent("剩余额度", value: vm.remaining.formatted())
                        LabeledContent("额度上限", value: detail.totalLimit.formatted())
                        if let cost = detail.resetCost {
                            LabeledContent("网站重置费用", value: "\(cost.formatted()) GP")
                        }
                        }
                        if let date = vm.updatedAt {
                            LabeledContent("更新时间") { Text(date, format: .dateTime) }
                                .foregroundStyle(.secondary)
                        }
                    } else if !vm.isLoading && vm.errorMessage == nil {
                        Text("点击刷新以查看图片配额。")
                            .foregroundStyle(.secondary)
                    }
                    if vm.isLoading { ProgressView("加载中...") }
                    if let error = vm.errorMessage {
                        Text(error).foregroundStyle(.secondary)
                        if vm.detail != nil {
                            Text("刷新失败，以上为上次读取的数据。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("刷新", systemImage: "arrow.clockwise") { vm.refresh() }
                        .disabled(vm.isLoading)
                } header: {
                    Text("图片配额")
                } footer: {
                    Text("额度由网站统计，不等同于图片张数；恢复速度和上限以网站为准。这里只查询，不会扣费重置。")
                }
                Section {
                    Link("在网站管理配额", destination: URL(string: EhURL.homeUrl(for: .eHentai))!)
                    Link("配额说明", destination: URL(string: "https://ehwiki.org/wiki/My_Home")!)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("图片配额")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .task { await vm.refresh().value }
        .onChange(of: AppSettings.shared.gallerySite) { _, _ in vm.invalidateIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vm.invalidateIfNeeded() }
        }
        .onDisappear { vm.cancel() }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 550)
        #endif
    }
}
