//
//  RootView.swift
//  ehviewer apple
//
//  Root navigation: Warning → SiteSelection → Login → Main app
//

import SwiftUI
import EhSettings
import EhAPI
import EhCookie
import EhDownload
import EhModels

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 根视图: 引导流程控制器
/// 流程: 18+警告 → 站点选择 → 登录检查 → 主界面
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState: AppState   // 仅在 init() 中初始化，避免创建多余实例
    @State private var flowStep: OnboardingStep
    @State private var credentialsReady = false
    
    /// 剪贴板画廊检测 (对齐 Android MainActivity.onResume 检测 EH 链接)
    @State private var clipboardGallery: (gid: Int64, token: String)?
    @State private var showClipboardAlert = false
    @State private var lastClipboardContent: String?

    /// ExHentai 切换提示
    @State private var showExHAlert = false

    /// Sad Panda / igneous 失效警告 (V-15)
    @State private var showSadPandaAlert = false
    /// 磁盘空间不足警告
    @State private var showDiskFullAlert = false
    enum OnboardingStep {
        case checking      // 检查状态中
        case warning       // 18+ 警告
        case rejected      // 拒绝 18+ 警告 (iOS 不能 exit, 显示永久阻断页)
        case selectSite    // 站点选择
        case login         // 登录页
        case main          // 主界面
    }

    // MARK: - Lightweight initial state; authentication is restored after presentation
    init() {
        let settings = AppSettings.shared
        let bypassOnboardingForUITests = ProcessInfo.processInfo.environment["EH_UI_TEST_BYPASS_ONBOARDING"] == "1"
        let step: OnboardingStep
        if bypassOnboardingForUITests {
            step = .main
        } else {
            step = .checking
        }
        _flowStep = State(initialValue: step)
        // 应用锁已移除。清理旧版留下的开关，避免降级/再升级时意外进入旧锁定流程。
        if settings.enableSecurity {
            settings.enableSecurity = false
        }
        let initState = AppState()
        initState.isSignedIn = bypassOnboardingForUITests
        _appState = State(initialValue: initState)
    }

    var body: some View {
        // Do not start authenticated feed requests before Keychain restoration.
        Group {
            if flowStep == .checking {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if flowStep == .main {
                MainTabView()
                    .environment(appState)
            } else {
                onboardingOverlay
            }
        }
        .withGlobalErrorBoundary()
        // 已登录用户: 启动时异步获取资料 + ExH 检测 (不 mutate isSignedIn，不触发重渲染)
        .task {
            let interval = PerformanceDiagnostics.begin("LaunchAuthenticationRestore")
            async let restoreCredentials: Void = EhCookieManager.shared.ensureCredentialsRestored()
            async let prepareRequests: Void = ApplicationBootstrap.shared.prepareForRequests()
            _ = await (restoreCredentials, prepareRequests)
            interval.end()
            guard !Task.isCancelled else { return }
            credentialsReady = true
            if flowStep == .checking { determineNextStep() }
            await ApplicationBootstrap.shared.start()
        }
        .task(id: credentialsReady && appState.isSignedIn && !AppSettings.shared.skipSignIn) {
            if credentialsReady && appState.isSignedIn && !AppSettings.shared.skipSignIn {
                await postLoginActions()
            }
        }
        .onChange(of: appState.isSignedIn) { _, isSignedIn in
            if isSignedIn && credentialsReady {
                flowStep = .main
            }
        }
        .onChange(of: flowStep) { _, step in
            if step == .main { checkClipboardForGalleryUrl() }
        }
        .alert("ExHentai 可用", isPresented: $showExHAlert) {
            Button("切换到 ExHentai") {
                AppSettings.shared.gallerySite = .exHentai
            }
            Button("保持 E-Hentai", role: .cancel) {}
        } message: {
            Text("检测到你的账号拥有 ExHentai 访问权限，是否切换到 ExHentai？")
        }
        // Sad Panda / igneous 失效警告 (V-15)
        .onReceive(NotificationCenter.default.publisher(for: .ehSadPandaDetected)) { _ in
            showSadPandaAlert = true
        }
        // 磁盘空间不足警告
        .onReceive(NotificationCenter.default.publisher(for: .ehDiskFull)) { _ in
            showDiskFullAlert = true
        }
        .alert("磁盘空间不足", isPresented: $showDiskFullAlert) {
            Button("我知道了", role: .cancel) {}
        } message: {
            Text("磁盘剩余空间不足，所有下载已自动暂停。\n请前往系统设置释放存储空间后，手动恢复下载。")
        }
        .alert("ExHentai 访问失效", isPresented: $showSadPandaAlert) {
            Button("重新登录") {
                AppSettings.shared.gallerySite = .eHentai
                appState.isSignedIn = false
                flowStep = .login
            }
            Button("切换到 E-Hentai", role: .cancel) {
                AppSettings.shared.gallerySite = .eHentai
            }
        } message: {
            Text("igneous Cookie 已失效 (Sad Panda)，已自动清除。\n请重新登录以恢复 ExHentai 访问权限，或切换到 E-Hentai。")
        }
        // 对齐 Android: 深色模式支持 (Settings.KEY_THEME)
        // 0=跟随系统, 1=浅色, 2=深色。theme 已接入 Observation，修改后
        // 直接更新现有窗口，不再要求重新启动应用。
        .preferredColorScheme(Self.computeColorScheme())
        .onOpenURL(perform: handleDeepLink)
        .onContinueUserActivity(SystemGalleryIntegration.activityType) { activity in
            guard let gallery = SystemGalleryIntegration.gallery(from: activity) else { return }
            openGallery(gallery)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                checkClipboardForGalleryUrl()
            case .inactive, .background:
                if phase == .background {
                    ApplicationBootstrap.shared.scheduleDatabaseMaintenance()
                }
            @unknown default:
                break
            }
        }
        .alert("检测到画廊链接", isPresented: $showClipboardAlert) {
            Button("打开") {
                if let gallery = clipboardGallery {
                    NotificationCenter.default.post(
                        name: .openGalleryFromClipboard,
                        object: nil,
                        userInfo: ["gid": gallery.gid, "token": gallery.token]
                    )
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let gallery = clipboardGallery {
                Text("剪贴板含有画廊链接 (GID: \(gallery.gid))，是否打开？")
            }
        }
    }
    
    // MARK: - 引导覆盖层

    @ViewBuilder
    private var onboardingOverlay: some View {
        switch flowStep {
        case .warning:
            WarningView(
                onAccept: {
                    AppSettings.shared.showWarning = false
                    determineNextStep()
                },
                onReject: {
                    #if os(macOS)
                    NSApplication.shared.terminate(nil)
                    #else
                    flowStep = .rejected
                    #endif
                }
            )

        case .rejected:
            VStack(spacing: 20) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text("您已拒绝使用条款")
                    .font(.title2.bold())
                Text("请关闭应用。")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)

        case .selectSite:
            SelectSiteView(onComplete: {
                determineNextStep()
            })

        case .login:
            LoginView()
                .environment(appState)

        case .checking, .main:
            EmptyView()
        }
    }

    // MARK: - 流程控制

    /// 登录后异步操作：获取用户资料 + ExH 检测
    private func postLoginActions() async {
        // Let the selected feed receive the initial network/CPU budget. Profile
        // and ExH capability checks are secondary and remain cancellable.
        try? await Task.sleep(for: .milliseconds(900))
        guard !Task.isCancelled else { return }

        // 1. 保存 UID
        if let uid = EhCookieManager.shared.memberId {
            AppSettings.shared.userId = uid
        }

        // 2. 获取用户资料
        do {
            let profile = try await EhAPI.shared.getProfile()
            guard !Task.isCancelled else { return }
            if let name = profile.displayName {
                AppSettings.shared.displayName = name
            }
            if let avatar = profile.avatar {
                AppSettings.shared.avatar = avatar
            }
        } catch {
            debugLog("[RootView] 获取用户资料失败: \(error)")
        }

        // 3. ExH 可达性检测
        guard !Task.isCancelled else { return }
        do {
            guard let url = URL(string: "https://exhentai.org/") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(EhRequestBuilder.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let config = URLSessionConfiguration.default
            config.httpCookieStorage = .shared
            let exSession = URLSession(configuration: config)
            defer { exSession.finishTasksAndInvalidate() }
            let (data, response) = try await exSession.data(for: request)
            guard !Task.isCancelled else { return }

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200, data.count >= 1000 {
                // ExHentai 可访问 — 提示切换
                showExHAlert = true
            }
        } catch {
            debugLog("[RootView] ExHentai 检测失败: \(error)")
        }
    }

    /// 深色模式偏好 (对齐 Android: Settings.KEY_THEME)
    /// 直接读取可观察设置，让已打开的场景即时跟随主题变化。
    private static func computeColorScheme() -> ColorScheme? {
        switch AppSettings.shared.theme {
        case 1: return .light
        case 2: return .dark
        default: return nil // 0: 跟随系统
        }
    }
    
    private func determineNextStep() {
        let settings = AppSettings.shared
        
        // 1. 检查 18+ 警告
        if settings.showWarning {
            flowStep = .warning
            return
        }
        
        // 2. 检查站点选择
        if !settings.hasSelectedSite {
            flowStep = .selectSite
            return
        }
        
        // 3. 检查登录状态
        appState.checkLoginStatus()
        
        // 如果设置了跳过登录 (游客模式)，直接进入主界面
        if appState.isSignedIn || AppSettings.shared.skipSignIn {
            if !appState.isSignedIn {
                appState.isSignedIn = true  // 仅在值不同时写入，避免 withMutation 触发无效重渲染
            }
            flowStep = .main
        } else {
            flowStep = .login
        }
    }
    
    /// Live Activity 与系统深链接的单一入口。先完成操作，再导航到下载页，
    /// 避免冷启动时页面已显示但队列状态还没刷新。
    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "ehviewer" else { return }

        switch url.host?.lowercased() {
        case "gallery":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let rawGID = components.queryItems?.first(where: { $0.name == "gid" })?.value,
                  let gid = Int64(rawGID),
                  let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
                  !token.isEmpty
            else { return }
            openGallery(GalleryInfo(gid: gid, token: token))
        case "downloads":
            AppNavigationRequest.send(.downloads)
        case "pause-download":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let rawGID = components.queryItems?.first(where: { $0.name == "gid" })?.value,
                  let gid = Int64(rawGID)
            else { return }
            Task {
                await DownloadManager.shared.pauseDownload(gid: gid)
                AppNavigationRequest.send(.downloads)
            }
        default:
            break
        }
    }

    private func openGallery(_ gallery: GalleryInfo) {
        // Keep cold-launch links until MainTabView has mounted its navigation.
        appState.pendingIncomingGallery = gallery
    }

    /// 检查剪贴板中的画廊链接 (对齐 Android MainActivity.checkClipboardUrl)
    private func checkClipboardForGalleryUrl() {
        guard flowStep == .main else { return }

        #if os(iOS)
        // iOS 16+: 先用 detectPatterns 检测是否包含 URL，避免触发粘贴板隐私弹窗
        if #available(iOS 16.0, *) {
            Task {
                do {
                    let patterns: Set<PartialKeyPath<UIPasteboard.DetectedValues>> = [\.probableWebURL]
                    let results = try await UIPasteboard.general.detectedPatterns(for: patterns)
                    guard results.contains(\.probableWebURL) else { return }
                    // 剪贴板确实包含 URL，再读取内容 (此时系统不会再弹隐私提示)
                    await MainActor.run {
                        readClipboardContent()
                    }
                } catch {
                    // 检测失败则不读取
                }
            }
        } else {
            readClipboardContent()
        }
        #else
        readClipboardContent()
        #endif
    }

    /// 读取剪贴板内容并匹配画廊链接
    private func readClipboardContent() {
        #if os(iOS)
        guard let content = UIPasteboard.general.string else { return }
        #else
        guard let content = NSPasteboard.general.string(forType: .string) else { return }
        #endif

        // 避免重复检测同一内容
        guard content != lastClipboardContent else { return }
        lastClipboardContent = content

        // 匹配 EH 画廊 URL: https://e-hentai.org/g/GID/TOKEN/
        let pattern = #"https?://(e-hentai|exhentai)\.org/g/(\d+)/([0-9a-f]{10})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              match.numberOfRanges >= 4,
              let gidRange = Range(match.range(at: 2), in: content),
              let tokenRange = Range(match.range(at: 3), in: content),
              let gid = Int64(content[gidRange]) else { return }

        let token = String(content[tokenRange])
        clipboardGallery = (gid: gid, token: token)
        showClipboardAlert = true
    }
}

// MARK: - 全局应用状态

@MainActor
@Observable
final class AppState {
    var isSignedIn = false
    var pendingIncomingGallery: GalleryInfo?
    var currentSite: SiteChoice = .eHentai

    enum SiteChoice: Int {
        case eHentai = 0
        case exHentai = 1
    }

    func checkLoginStatus() {
        // 检查 Cookie 是否存在
        let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://e-hentai.org")!) ?? []
        let hasMemberId = cookies.contains { $0.name == "ipb_member_id" }
        let hasPassHash = cookies.contains { $0.name == "ipb_pass_hash" }
        let newValue = hasMemberId && hasPassHash
        if newValue != isSignedIn {
            isSignedIn = newValue  // ★ 仅在值变化时写入，避免 withMutation 触发无效重渲染
        }

        // 未登录时不能访问 ExHentai。已登录时保留用户显式选择，
        // 由实际请求/Sad Panda 响应判断权限，避免 igneous 尚未写入时静默切回。
        if !isSignedIn && AppSettings.shared.gallerySite == .exHentai {
            AppSettings.shared.gallerySite = .eHentai
        }
    }

    /// 检查 ExHentai 访问权限 (igneous cookie)
    /// 无有效 igneous 时自动降级到 E-Hentai 并提示
    private func validateExHentaiAccess() {
        let exCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://exhentai.org")!) ?? []
        let hasIgneous = exCookies.contains { $0.name == "igneous" && !$0.value.isEmpty && $0.value != "mystery" }
        if !hasIgneous {
            AppSettings.shared.gallerySite = .eHentai
        }
    }

    func signOut() {
        Task { await EhCookieManager.shared.signOut() }
        isSignedIn = false
    }
}

#Preview {
    RootView()
}
