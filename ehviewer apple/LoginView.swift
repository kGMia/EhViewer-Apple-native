//
//  LoginView.swift
//  ehviewer apple
//
//  登录界面 — E-Hentai Forums 认证
//  对齐 Android: 账号密码登录 / WebView 登录 / Cookie 登录 / 跳过登录
//

import SwiftUI
import EhSettings
import EhAPI
import EhCookie
import EhParser
import WebKit

struct LoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCookieLogin = false
    @State private var showWebViewLogin = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // Logo
                    VStack(spacing: 8) {
                        Image(systemName: "book.pages")
                            .font(.system(size: 64))
                            .foregroundStyle(Color.accentColor)
                        Text("EhViewer")
                            .font(.largeTitle.bold())
                        Text("E-Hentai / ExHentai Gallery Browser")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)

                    // 登录表单
                    VStack(spacing: 16) {
                        TextField("用户名", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.username)
                            #if os(iOS)
                            .autocapitalization(.none)
                            #endif
                            .disabled(isLoading)

                        SecureField("密码", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.password)
                            .disabled(isLoading)
                            .onSubmit { Task { await signIn() } }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        Button(action: { Task { await signIn() } }) {
                            Group {
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("登录")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(username.isEmpty || password.isEmpty || isLoading)
                    }
                    .frame(maxWidth: 360)

                    // 替代登录方式
                    VStack(spacing: 12) {
                        Divider()

                        // WebView 登录 (对齐 Android: 网页登录)
                        Button("网页登录") {
                            showWebViewLogin = true
                        }
                        .buttonStyle(.bordered)

                        Button("Cookie 登录") {
                            showCookieLogin = true
                        }
                        .buttonStyle(.bordered)

                        Button("跳过登录 (仅 E-Hentai)") {
                            // 游客模式: 强制使用 E-Hentai 站点，不能访问 ExHentai
                            AppSettings.shared.gallerySite = .eHentai
                            AppSettings.shared.skipSignIn = true
                            Task { await EhCookieManager.shared.injectNWCookie() }
                            appState.isSignedIn = true
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Link("注册账号", destination: URL(string: EhURL.registerUrl)!)
                            .font(.caption)
                    }
                    .frame(maxWidth: 360)
                }
                .padding()
            }
            .navigationTitle("登录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showCookieLogin) {
                CookieLoginView()
                    .environment(appState)
            }
            .sheet(isPresented: $showWebViewLogin) {
                WebViewLoginView()
                    .environment(appState)
            }
        }
        .onChange(of: appState.isSignedIn) { _, isSignedIn in
            // 作为设置页 sheet 打开时关闭整个登录流程；作为启动页打开时
            // dismiss 是空操作，RootView 会依据同一状态切换到主界面。
            if isSignedIn { dismiss() }
        }
    }

    /// 使用 EhAPI.signIn() + SignInParser 进行登录
    private func signIn() async {
        isLoading = true
        errorMessage = nil

        do {
            // 使用 EhAPI 统一的 signIn 方法 (内部使用 EhRequestBuilder + SignInParser)
            let displayName = try await EhAPI.shared.signIn(username: username, password: password)

            // 登录成功 — 同步 Cookie 到 ExHentai
            await EhCookieManager.shared.syncLoginCookies()

            // 保存用户信息
            AppSettings.shared.isLogin = true
            AppSettings.shared.displayName = displayName

            // 保存 UID
            if let uid = EhCookieManager.shared.memberId {
                AppSettings.shared.userId = uid
            }

            // 异步获取完整用户资料 (avatar 等) — RootView 统一处理

            appState.isSignedIn = true
        } catch let error as EhParseError {
            switch error {
            case .signInError(let msg):
                errorMessage = msg
            case .parseFailure(let msg):
                errorMessage = AppLocalization.format("解析失败: %@", msg)
            }
        } catch let ehError as EhError {
            if case .cloudflare403 = ehError {
                errorMessage = ehError.localizedDescription
            } else {
                errorMessage = AppLocalization.format("网络错误: %@", ehError.localizedDescription)
            }
        } catch {
            errorMessage = AppLocalization.format("网络错误: %@", error.localizedDescription)
        }

        isLoading = false
    }

}

// MARK: - WebView 登录 (对齐 Android WebView 登录方式)

struct WebViewLoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var loginDetected = false
    @State private var loadError: String?
    @State private var reloadID = 0

    var body: some View {
        NavigationStack {
            ZStack {
                WebViewLogin(
                    isLoading: $isLoading,
                    errorMessage: $loadError,
                    onLoginDetected: { displayName in
                        guard !loginDetected else { return }
                        loginDetected = true

                        Task {
                            // 等待 Cookie 持久化后再更新登录状态，避免首个请求抢跑。
                            await EhCookieManager.shared.syncLoginCookies()
                            AppSettings.shared.isLogin = true
                            if let name = displayName, !name.isEmpty {
                                AppSettings.shared.displayName = name
                            }
                            if let uid = EhCookieManager.shared.memberId {
                                AppSettings.shared.userId = uid
                            }
                            // 登录完成以认证 Cookie 为准。资料请求可能受网络影响，
                            // 不应阻塞登录窗口关闭或主界面切换。
                            appState.isSignedIn = true
                            dismiss()
                            await postLoginSetup()
                        }
                    }
                )
                .id(reloadID)

                if isLoading {
                    ProgressView("加载中...")
                }

                if let loadError, !isLoading {
                    ContentUnavailableView {
                        Label("无法载入登录网页", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("重新加载") {
                            self.loadError = nil
                            isLoading = true
                            reloadID += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                }
            }
            .navigationTitle("网页登录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 680)
        #endif
    }

    /// 登录后的异步设置：获取用户资料
    /// ExH 检测由 RootView 统一处理
    private func postLoginSetup() async {
        // 获取用户资料 (displayName, avatar)
        do {
            let profile = try await EhAPI.shared.getProfile()
            if let name = profile.displayName {
                AppSettings.shared.displayName = name
            }
            if let avatar = profile.avatar {
                AppSettings.shared.avatar = avatar
            }
        } catch {
            debugLog("[WebViewLogin] 获取用户资料失败: \(error)")
        }
    }
}

// MARK: - SwiftUI WebView 登录（系统 26 WebKit）

struct WebViewLogin: View {
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    var onLoginDetected: (String?) -> Void

    @State private var page: WebPage
    @State private var hasDetectedLogin = false

    init(
        isLoading: Binding<Bool>,
        errorMessage: Binding<String?>,
        onLoginDetected: @escaping (String?) -> Void
    ) {
        _isLoading = isLoading
        _errorMessage = errorMessage
        self.onLoginDetected = onLoginDetected

        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .default()
        _page = State(initialValue: WebPage(configuration: configuration))
    }

    var body: some View {
        WebView(page)
            .webViewBackForwardNavigationGestures(.enabled)
            .task { await loadSignInPage() }
            // Some forum responses install cookies before their redirect has
            // committed. A lightweight poll preserves the old cookie-store
            // observer's prompt detection without another platform bridge.
            .task { await monitorLoginCookies() }
    }

    private func loadSignInPage() async {
        guard let url = URL(string: EhURL.signInReferer) else { return }
        do {
            for try await event in page.load(url) {
                guard !Task.isCancelled else { return }
                switch event {
                case .startedProvisionalNavigation:
                    isLoading = true
                    errorMessage = nil
                case .finished:
                    isLoading = false
                    await detectLoginIfNeeded()
                case .receivedServerRedirect, .committed:
                    break
                @unknown default:
                    // New WebKit events must not break Swift 6 clients or
                    // prematurely mark an in-flight navigation as finished.
                    break
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func monitorLoginCookies() async {
        while !Task.isCancelled && !hasDetectedLogin {
            await detectLoginIfNeeded()
            try? await Task.sleep(for: .milliseconds(650))
        }
    }

    private func detectLoginIfNeeded() async {
        guard !hasDetectedLogin else { return }
        let cookies = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        let namesToSync = Set(["ipb_member_id", "ipb_pass_hash", "igneous", "sk", "star"])
        let cookiesToSync = cookies.filter { namesToSync.contains($0.name) }
        guard cookiesToSync.contains(where: { $0.name == "ipb_member_id" }),
              cookiesToSync.contains(where: { $0.name == "ipb_pass_hash" }),
              !hasDetectedLogin else { return }

        hasDetectedLogin = true
        await EhCookieManager.shared.storeCookies(cookiesToSync)
        _ = await EhCookieManager.shared.secureAuthCookies()
        let result = try? await page.callJavaScript(
            "document.querySelector('#userlinks .home b')?.textContent || document.querySelector('.home b')?.textContent || ''"
        )
        let name = result as? String
        onLoginDetected(name?.isEmpty == true ? nil : name)
    }
}

// MARK: - Cookie 手动登录

struct CookieLoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var memberId = ""
    @State private var passHash = ""
    @State private var igneous = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("必填") {
                    TextField("ipb_member_id", text: $memberId)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                    TextField("ipb_pass_hash", text: $passHash)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                }
                Section("可选 (ExHentai)") {
                    TextField("igneous", text: $igneous)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                }
                Section {
                    Button("确认登录") {
                        Task { await applyCookies() }
                    }
                    .disabled(memberId.isEmpty || passHash.isEmpty)
                }
            }
            .navigationTitle("Cookie 登录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func applyCookies() async {
        // 使用 EhCookieManager 统一设置 Cookie
        let cookieManager = EhCookieManager.shared

        for domain in [EhCookieManager.domainEhentai, EhCookieManager.domainExhentai] {
            await cookieManager.setCookie(name: EhCookieManager.keyIPBMemberId, value: memberId, domain: domain)
            await cookieManager.setCookie(name: EhCookieManager.keyIPBPassHash, value: passHash, domain: domain)
        }

        // 注入 nw=1 跳过内容警告
        await cookieManager.injectNWCookie()

        // igneous (ExHentai 权限 Cookie)
        if !igneous.isEmpty {
            await cookieManager.setCookie(name: EhCookieManager.keyIgneous, value: igneous, domain: EhCookieManager.domainExhentai)
        }

        _ = await cookieManager.persistCredentials()

        // 保存登录状态
        AppSettings.shared.isLogin = true
        appState.isSignedIn = true
        dismiss()
    }
}

#Preview {
    LoginView()
        .environment(AppState())
}
