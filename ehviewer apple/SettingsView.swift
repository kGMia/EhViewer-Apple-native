//
//  SettingsView.swift
//  ehviewer apple
//
//  设置视图
//

import SwiftUI
import EhSettings
import EhAPI
import EhDownload
import EhDatabase
import EhSpider
import UniformTypeIdentifiers
#if os(iOS)
import AppIntents
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SettingsView: View {
    @State private var vm = SettingsViewModel()
    @State private var settingsRevision = 0
    @State private var newBlockedTag = ""
    @State private var informationSheet: InformationSheet?
    @State private var showGalleryUpdates = false
    @State private var showImageQuota = false
    @Environment(\.openURL) private var openURL

    private enum InformationSheet: String, Identifiable {
        case about, licenses
        var id: String { rawValue }
    }

    /// 被推入父导航栈时，不创建自己的 NavigationStack，避免嵌套
    private var isPushed: Bool = false

    init(isPushed: Bool = false) {
        self.isPushed = isPushed
    }

    /// AppSettings 中仍由 UserDefaults 承载的值需要显式触发一次视图刷新，
    /// 否则 macOS 的 Toggle/Picker 会在写入后继续显示旧快照。
    private func settingBinding<Value>(
        _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                _ = settingsRevision
                return AppSettings.shared[keyPath: keyPath]
            },
            set: { newValue in
                AppSettings.shared[keyPath: keyPath] = newValue
                settingsRevision &+= 1
            }
        )
    }

    var body: some View {
        if isPushed {
            settingsInnerContent
        } else {
            NavigationStack {
                settingsInnerContent
            }
        }
    }

    private var settingsInnerContent: some View {
        Group {
            #if os(macOS)
            // macOS Form 会把全部子项的理想高度反馈给 Settings 窗口，
            // 使窗口被内容撑大。List 提供有界视口和原生滚动。
            List {
                settingsSections
            }
            .listStyle(.inset)
            #else
            Form {
                settingsSections
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("设置")
        .sheet(isPresented: $showGalleryUpdates) { GalleryUpdatesView() }
        .sheet(isPresented: $showImageQuota) { ImageQuotaView() }
        .sheet(item: $informationSheet) { destination in
            NavigationStack {
                Group {
                    switch destination {
                    case .about: aboutDetailView
                    case .licenses: licensesView
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", systemImage: "xmark") { informationSheet = nil }
                            .labelStyle(.iconOnly)
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 460, idealWidth: 560, minHeight: 400, idealHeight: 560)
            #else
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            #endif
        }
        .onChange(of: vm.showLogin) { _, isPresented in
            if !isPresented { vm.checkLoginState() }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var settingsSections: some View {
            accountSection
            siteSection
            filterSection
            displaySection
            favoritesSection
            networkSection
            readingSection
            downloadSection
            cacheSection
            advancedSection
            #if os(iOS)
            shortcutsSection
            #endif
            aboutSection
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("账号") {
            Button("图片配额", systemImage: "gauge.with.dots.needle.50percent") {
                showImageQuota = true
            }
            if vm.isLoggedIn {
                HStack {
                    Image(systemName: "person.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        if let name = vm.displayName, !name.isEmpty {
                            Text(name)
                                .font(.subheadline.bold())
                        } else {
                            Text("已登录")
                                .font(.subheadline.bold())
                        }
                        HStack(spacing: 8) {
                            if let uid = vm.userId, !uid.isEmpty {
                                Text("UID: \(uid)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(AppLocalization.localized(vm.hasExAccess ? "ExHentai 可用" : "仅 E-Hentai (未登录)"))
                                .font(.caption)
                                .foregroundStyle(vm.hasExAccess ? Color.green : .secondary)
                        }
                    }
                }

                // 身份 Cookies (对齐 Android: identity_cookie)
                NavigationLink("身份 Cookies") {
                    identityCookiesView
                }

                Button("注销", role: .destructive) {
                    vm.showLogoutConfirm = true
                }
            } else {
                Button("登录") {
                    vm.showLogin = true
                }
            }
        }
        .confirmationDialog("确认注销？", isPresented: $vm.showLogoutConfirm, titleVisibility: .visible) {
            Button("注销", role: .destructive) {
                vm.logout()
            }
        }
        .sheet(isPresented: $vm.showLogin) {
            LoginView()
        }
    }

    // MARK: - Site

    private var siteSection: some View {
        Section("站点") {
            Picker("默认站点", selection: $vm.gallerySite) {
                Text("E-Hentai").tag(0)
                Text("ExHentai").tag(1)
            }

            // EH 站点设置 (对齐 Android: u_config)
            Button {
                let site = AppSettings.shared.gallerySite
                let url = site == .exHentai
                    ? "https://exhentai.org/uconfig.php"
                    : "https://e-hentai.org/uconfig.php"
                openURL(URL(string: url)!)
            } label: {
                HStack {
                    Text("EH 站点设置")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await vm.syncHiddenTags() }
            } label: {
                HStack {
                    Text("从“我的标签”同步屏蔽项")
                    Spacer()
                    if vm.isSyncingHiddenTags {
                        ProgressView().controlSize(.small)
                    } else if let result = vm.hiddenTagSyncResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!vm.isLoggedIn || vm.isSyncingHiddenTags)

            // 我的标签 (对齐 Android: my_tags)
            Button {
                let site = AppSettings.shared.gallerySite
                let url = site == .exHentai
                    ? "https://exhentai.org/mytags"
                    : "https://e-hentai.org/mytags"
                openURL(URL(string: url)!)
            } label: {
                HStack {
                    Text("我的标签")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("列表模式", selection: $vm.listMode) {
                Text("列表").tag(0)
                Text("瀑布流").tag(1)
            }

            Toggle("显示日文标题", isOn: settingBinding(\.showJpnTitle))

            // 标签翻译设置
            Toggle("显示标签翻译", isOn: settingBinding(\.showTagTranslations))
            
            if AppSettings.shared.showTagTranslations {
                HStack {
                    Text("标签数据库")
                    Spacer()
                    if vm.isUpdatingTagDb {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text(vm.tagDbStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Button {
                    Task { await vm.updateTagDatabase() }
                } label: {
                    HStack {
                        Text("更新标签翻译数据库")
                        Spacer()
                        if vm.tagDbUpdateSuccess {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .disabled(vm.isUpdatingTagDb)

                // 标签翻译来源标注 (对齐 Android: tag_translations_source)
                Button {
                    openURL(URL(string: "https://github.com/EhTagTranslation")!)
                } label: {
                    HStack {
                        Text("补充翻译（由 EhTagTranslator 提供）")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            NavigationLink {
                blockedTagsView
            } label: {
                HStack {
                    Text("已屏蔽标签")
                    Spacer()
                    Text("\(AppSettings.shared.blockedTags.count)")
                        .foregroundStyle(.secondary)
                }
            }

        }
    }

    // MARK: - Filter / Search (对齐 Android: 默认分类/排除标签命名空间/排除语言)
    private var filterSection: some View {
        Section("搜索过滤") {
            NavigationLink("默认搜索分类") {
                defaultCategoriesView
            }
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        Section("网络") {
            Text("网络请求遵循 macOS 的系统 DNS、代理与 VPN 设置。连接失败时会自动尝试内置地址回退。")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            // 网络诊断按钮
            Button {
                vm.runNetworkDiagnostics()
            } label: {
                HStack {
                    Text("网络诊断")
                    Spacer()
                    if vm.isDiagnosing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if !vm.diagnosisResult.isEmpty {
                        Image(systemName: vm.diagnosisSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(vm.diagnosisSuccess ? .green : .orange)
                    }
                }
            }
            .disabled(vm.isDiagnosing)
            
            if !vm.diagnosisResult.isEmpty {
                Text(vm.diagnosisResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Display (对齐 Android Settings: 外观)

    private var displaySection: some View {
        Section("外观") {
            Picker("界面语言", selection: settingBinding(\.appLanguage)) {
                Text("跟随系统").tag(AppLanguage.system)
                Text("简体中文").tag(AppLanguage.simplifiedChinese)
                Text("繁體中文（台灣）").tag(AppLanguage.traditionalChineseTaiwan)
                Text("English (United States)").tag(AppLanguage.englishUnitedStates)
            }

            // 深色模式 (对齐 Android Settings.KEY_THEME)
            Picker("主题", selection: settingBinding(\.theme)) {
                Text("跟随系统").tag(0)
                Text("浅色").tag(1)
                Text("深色").tag(2)
            }

            Picker("主题色", selection: settingBinding(\.accentColor)) {
                ForEach(AppAccentColor.allCases) { accent in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(accent.previewColor)
                            .frame(width: 10, height: 10)
                        Text(accent.displayName)
                    }
                    .tag(accent)
                }
            }

            // 启动页面 (对齐 Android Settings.KEY_LAUNCH_PAGE)
            Picker("启动页面", selection: settingBinding(\.launchPage)) {
                Text("首页").tag(0)
                Text("热门").tag(1)
                Text("排行榜").tag(2)
                Text("收藏").tag(3)
                Text("下载").tag(4)
                Text("历史").tag(5)
                Text("订阅").tag(6)
            }

            Toggle("显示画廊页数", isOn: settingBinding(\.showGalleryPages))

            Toggle("显示评论区", isOn: settingBinding(\.showGalleryComment))

            Toggle("显示评分", isOn: settingBinding(\.showGalleryRating))

            Toggle("兼容旧缩略图链接", isOn: settingBinding(\.fixThumbUrl))

            // iPad 横屏与窄窗口会即时响应，无需重新启动应用。
            Picker("大屏幕浏览布局", selection: settingBinding(\.wideScreenListMode)) {
                Text("自动双栏（列表+详情）").tag(0)
                Text("始终单栏").tag(1)
            }
        }
    }

    // MARK: - Favorites (对齐 Android Settings: 收藏)

    private var favoritesSection: some View {
        Section("收藏") {
            // 默认收藏夹 (对齐 Android Settings.KEY_DEFAULT_FAV_SLOT)
            Picker("默认收藏夹", selection: settingBinding(\.defaultFavSlot)) {
                Text("每次询问").tag(-2)
                ForEach(0..<10) { slot in
                    Text(AppSettings.shared.favCatName(slot)).tag(slot)
                }
            }

            NavigationLink("收藏夹名称") {
                favCatNamesView
            }
        }
    }

    private var favCatNamesView: some View {
        List {
            ForEach(0..<10, id: \.self) { slot in
                HStack {
                    Text("收藏夹 \(slot)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("名称", text: Binding(
                        get: { AppSettings.shared.favCatName(slot) },
                        set: { AppSettings.shared.setFavCatName(slot, $0) }
                    ))
                    .multilineTextAlignment(.trailing)
                }
            }
        }
        .navigationTitle("收藏夹名称")
    }

    // MARK: - Reading

    private var readingSection: some View {
        Section("阅读") {
            // 阅读方向 (对齐 Android Settings.KEY_READING_DIRECTION)
            Picker("阅读方向", selection: settingBinding(\.readingDirection)) {
                Text("左→右").tag(0)
                Text("右→左").tag(1)
                Text("上→下").tag(2)
            }

            // 页面缩放 (对齐 Android Settings.KEY_PAGE_SCALING)
            Picker("页面缩放", selection: settingBinding(\.pageScaling)) {
                Text("原始大小").tag(0)
                Text("适应宽度").tag(1)
                Text("适应高度").tag(2)
                Text("适应屏幕").tag(3)
                Text("固定缩放").tag(4)
            }

            // 起始位置 (对齐 Android Settings.KEY_START_POSITION)
            Picker("起始位置", selection: settingBinding(\.startPosition)) {
                Text("左上").tag(0)
                Text("右上").tag(1)
                Text("左下").tag(2)
                Text("右下").tag(3)
                Text("居中").tag(4)
            }

            // 屏幕旋转 (对齐 Android Settings.KEY_SCREEN_ROTATION)
            #if os(iOS)
            Picker("屏幕旋转", selection: Binding(
                get: { AppSettings.shared.screenRotation },
                set: { newValue in
                    AppSettings.shared.screenRotation = newValue
                    // 立即应用旋转设置
                    #if os(iOS)
                    applyScreenRotation(newValue)
                    #endif
                }
            )) {
                Text("跟随系统").tag(0)
                Text("竖屏锁定").tag(1)
                Text("横屏锁定").tag(2)
            }
            #endif

            Stepper("预加载页数: \(vm.preloadImage)", value: $vm.preloadImage, in: 1...10)

            Toggle("保持屏幕常亮", isOn: settingBinding(\.keepScreenOn))

            Toggle("全屏阅读", isOn: settingBinding(\.readingFullscreen))

            Toggle("显示时钟", isOn: settingBinding(\.showClock))

            Toggle("显示进度", isOn: settingBinding(\.showProgress))

            Toggle("显示电量", isOn: settingBinding(\.showBattery))

            Toggle("显示页间距", isOn: settingBinding(\.showPageInterval))

            // 自定义亮度 (对齐 Android Settings.KEY_CUSTOM_SCREEN_LIGHTNESS)
            #if os(iOS)
            Toggle("自定义亮度", isOn: settingBinding(\.customScreenLightness))

            if AppSettings.shared.customScreenLightness {
                Slider(value: Binding(
                    get: { Double(AppSettings.shared.screenLightness) },
                    set: { AppSettings.shared.screenLightness = Int($0) }
                ), in: 0...100, step: 1) {
                    Text("亮度: \(AppSettings.shared.screenLightness)%")
                }
            }
            #endif

            // 自动翻页间隔 (对齐 Android Settings.KEY_AUTO_PAGE_INTERVAL)
            Stepper("自动翻页间隔: \(vm.autoPageInterval)s", value: $vm.autoPageInterval, in: 1...60)

        }
    }

    // MARK: - Download

    private var downloadSection: some View {
        Section("下载") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                Text("下载位置")
                Spacer()
                Text(vm.downloadPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300, alignment: .trailing)

                #if os(macOS)
                Button("更改…") {
                    vm.chooseDownloadPath()
                }
                .buttonStyle(.link)
                #else
                Button("更改…") {
                    vm.showDownloadDirectoryPicker = true
                }
                .buttonStyle(.borderless)
                .fileImporter(
                    isPresented: $vm.showDownloadDirectoryPicker,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    vm.handleDownloadDirectorySelection(result)
                }
                #endif
                }

                HStack {
                    Text("更改位置会先暂停下载，已有文件不会自动移动。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if vm.hasCustomDownloadPath {
                        Button("恢复默认") {
                            vm.resetDownloadPath()
                        }
                        .font(.caption)
                    }
                }
            }

            Stepper("并发线程: \(vm.multiThread)", value: $vm.multiThread, in: 1...5)

            Stepper("超时 (秒): \(vm.downloadTimeout)", value: $vm.downloadTimeout, in: 10...120, step: 10)

            // 下载延迟 (对齐 Android Settings.KEY_DOWNLOAD_DELAY)
            Stepper("下载延迟: \(vm.downloadDelay) ms", value: $vm.downloadDelay, in: 0...2000, step: 100)

            // 下载原图 (对齐 Android Settings.KEY_DOWNLOAD_ORIGIN_IMAGE)
            Toggle("下载原始图片", isOn: settingBinding(\.downloadOriginImage))

            // 恢复下载项目 (对齐 Android: restore_download_items)
            Button {
                vm.restoreDownloadItems()
            } label: {
                HStack {
                    Text("恢复下载项目")
                    Spacer()
                    if vm.isRestoring {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
            .disabled(vm.isRestoring)

            if let msg = vm.restoreResultMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 清除冗余数据 (对齐 Android: clean_redundancy)
            Button {
                vm.cleanRedundancy()
            } label: {
                HStack {
                    Text("清除下载冗余数据")
                    Spacer()
                    if vm.isCleaning {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
            .disabled(vm.isCleaning)
            .confirmationDialog(
                "发现 \(vm.cleanOrphanCount) 个冗余目录 (\(vm.cleanOrphanSize))，确认删除？",
                isPresented: $vm.showCleanConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    vm.confirmCleanRedundancy()
                }
                Button("取消", role: .cancel) {
                    vm.cancelClean()
                }
            }

            if let msg = vm.cleanResultMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        Section("缓存") {
            // 阅读缓存大小 (对齐 Android Settings.KEY_READ_CACHE_SIZE)
            Picker("阅读缓存大小", selection: settingBinding(\.readCacheSize)) {
                Text("40 MB").tag(40)
                Text("80 MB").tag(80)
                Text("120 MB").tag(120)
                Text("160 MB").tag(160)
                Text("240 MB").tag(240)
                Text("320 MB").tag(320)
                Text("480 MB").tag(480)
                Text("640 MB").tag(640)
            }
            .onChange(of: AppSettings.shared.readCacheSize) { _, megabytes in
                SpiderDen.updateReadCacheLimit(megabytes: megabytes)
                vm.calculateCacheSize()
            }

            HStack {
                Text("磁盘缓存")
                Spacer()
                Text(vm.diskCacheSize)
                    .foregroundStyle(.secondary)
            }

            // 清除内存缓存 (对齐 Android: clear_memory_cache)
            Button("清除内存缓存") {
                vm.clearMemoryCache()
            }

            Button("清除磁盘缓存") {
                vm.clearCache()
            }
            .disabled(vm.isClearingDiskCache)
        }
    }

    // MARK: - Advanced (对齐 Android Settings: 高级)

    private var advancedSection: some View {
        Section("高级") {
            Button("检查画廊更新", systemImage: "arrow.clockwise") {
                showGalleryUpdates = true
            }
            // 历史记录容量 (对齐 Android Settings.KEY_HISTORY_INFO_SIZE)
            Stepper("历史记录上限: \(vm.historyInfoSize)", value: $vm.historyInfoSize, in: 100...2000, step: 100)

            // 导出数据 (对齐 Android: export_data)
            Button("导出数据") {
                vm.exportData()
            }

            // 导入数据 (对齐 Android: import_data)
            Button("导入数据") {
                vm.importData()
            }
            .fileImporter(
                isPresented: $vm.showImportPicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                vm.handleImport(result)
            }
        }
    }

    #if os(iOS)
    private var shortcutsSection: some View {
        Section("Siri 与快捷指令") {
            ShortcutsLink()
                .shortcutsLinkStyle(.automatic)

            Text("可从快捷指令、Siri 或 Spotlight 搜索画廊、打开常用页面并继续阅读。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    #endif

    // MARK: - About

    private var aboutSection: some View {
        Section("关于") {
            Button {
                informationSheet = .about
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "books.vertical.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("EhViewer")
                            .font(.headline)
                        Text("版本 \(appVersion) (构建 \(appBuild))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button("开源协议") {
                informationSheet = .licenses
            }
        }
        .sheet(isPresented: $vm.showLogExport) {
            LogExportView()
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var currentPlatformDescription: String {
        #if os(macOS)
        "macOS"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
    }

    private var aboutDetailView: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 82, height: 82)
                        .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 22))
                    Text("EhViewer")
                        .font(.title2.bold())
                    Text("适用于 Apple 平台的原生 E-Hentai / ExHentai 阅读器")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            Section("版本信息") {
                LabeledContent("版本", value: appVersion)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        vm.versionTapCount += 1
                        if vm.versionTapCount >= 5 {
                            vm.versionTapCount = 0
                            vm.showLogExport = true
                        }
                    }
                LabeledContent("构建", value: appBuild)
                LabeledContent("平台", value: currentPlatformDescription)
            }

            Section("项目") {
                LabeledContent("项目名称", value: "EhViewer Apple Native")
                LabeledContent("作者与维护者", value: "kGMia")
                LabeledContent("上游作者", value: "felixchaos")
                LabeledContent("开源协议", value: "Apache-2.0")
                Button {
                    openURL(URL(string: "https://github.com/kGMia/EhViewer-Apple-native")!)
                } label: {
                    Label("源代码", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button {
                    openURL(URL(string: "https://github.com/kGMia/EhViewer-Apple-native/issues")!)
                } label: {
                    Label("报告问题", systemImage: "exclamationmark.bubble")
                }
                Button {
                    openURL(URL(string: "https://github.com/felixchaos/EhViewer-Apple")!)
                } label: {
                    Label("上游项目", systemImage: "arrow.triangle.branch")
                }
                Text("基于 EhViewer-Apple 持续开发，专注于 Apple 平台的原生体验。感谢上游作者与所有贡献者。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    licensesView
                } label: {
                    Label("开源协议与致谢", systemImage: "doc.text")
                }
            }

            Section("隐私") {
                Label("不包含广告、跨应用跟踪或第三方分析 SDK", systemImage: "hand.raised")
                Text("登录 Cookie、阅读记录、收藏与下载数据保存在设备上；网络请求会直接发送到用户选择的 E-Hentai 或 ExHentai 站点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于 EhViewer")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $vm.showLogExport) {
            LogExportView()
        }
    }

    private var licensesView: some View {
        List {
            // 本项目
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("EhViewer-Apple")
                            .font(.headline)
                        Spacer()
                        Text("Apache-2.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Copyright © 2024–2026 felixchaos and contributors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("原生分支维护", value: "kGMia")
                        .font(.caption)
                    Text(verbatim: """
Licensed under the Apache License, Version 2.0 (the "License"); \
you may not use this file except in compliance with the License. \
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software \
distributed under the License is distributed on an "AS IS" BASIS, \
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. \
See the License for the specific language governing permissions and \
limitations under the License.
""")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("本项目")
            }

            // 致谢
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("EhViewer")
                        .font(.subheadline.bold())
                    Text("原始 Android EhViewer 项目")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("EhViewer_CN_SXJ")
                        .font(.subheadline.bold())
                    Text("EhViewer 中文分支，本项目参考了其 UI 设计与功能逻辑")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("EhPanda / JHenTai")
                        .font(.subheadline.bold())
                    Text("活跃的同类开源项目，为导航、阅读与网络交互提供了参考")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("致谢")
            }

            // 第三方库
            Section {
                ForEach(licensedLibraries, id: \.name) { lib in
                    DisclosureGroup {
                        Text(lib.licenseText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Text(lib.name)
                                .font(.subheadline)
                            Spacer()
                            Text(lib.license)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("第三方开源库")
            }
        }
        .navigationTitle("开源协议")
    }

    private struct LicensedLibrary {
        let name: String
        let license: String
        let licenseText: String
    }

    private var licensedLibraries: [LicensedLibrary] {
        [
            LicensedLibrary(
                name: "GRDB.swift",
                license: "MIT",
                licenseText: """
Copyright (C) 2015-2024 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy \
of this software and associated documentation files (the "Software"), to deal \
in the Software without restriction, including without limitation the rights \
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
copies of the Software, and to permit persons to whom the Software is \
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all \
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
SOFTWARE.
"""
            ),
            LicensedLibrary(
                name: "SwiftSoup",
                license: "MIT",
                licenseText: """
Copyright (c) 2016 Nabil Chatbi

Permission is hereby granted, free of charge, to any person obtaining a copy \
of this software and associated documentation files (the "Software"), to deal \
in the Software without restriction, including without limitation the rights \
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
copies of the Software, and to permit persons to whom the Software is \
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all \
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
SOFTWARE.
"""
            ),
            LicensedLibrary(
                name: "SDWebImageSwiftUI",
                license: "MIT",
                licenseText: """
Copyright (c) 2019 lizhuoli1126@126.com

Permission is hereby granted, free of charge, to any person obtaining a copy \
of this software and associated documentation files (the "Software"), to deal \
in the Software without restriction, including without limitation the rights \
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
copies of the Software, and to permit persons to whom the Software is \
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all \
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
SOFTWARE.
"""
            ),
        ]
    }

    // MARK: - Screen Rotation Helper

    #if os(iOS)
    /// 立即应用屏幕旋转设置 (对齐 Android setRequestedOrientation)
    private func applyScreenRotation(_ mode: Int) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }

        let orientations: UIInterfaceOrientationMask
        switch mode {
        case 1:
            orientations = .portrait
        case 2:
            orientations = .landscape
        default:
            orientations = .allButUpsideDown
        }

        let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
        windowScene.requestGeometryUpdate(geometryPreferences) { error in
            debugLog("[SettingsView] 旋转更新错误: \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: - Identity Cookies View (对齐 Android: IdentityCookiePreference)

    private var identityCookiesView: some View {
        List {
            let ehCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://e-hentai.org")!) ?? []
            let exCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://exhentai.org")!) ?? []

            Section("E-Hentai Cookies") {
                ForEach(ehCookies, id: \.name) { cookie in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cookie.name)
                            .font(.subheadline.bold())
                        Text(cookie.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .contextMenu {
                        Button("复制") {
                            #if os(iOS)
                            UIPasteboard.general.string = "\(cookie.name)=\(cookie.value)"
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(cookie.name)=\(cookie.value)", forType: .string)
                            #endif
                        }
                    }
                }
                if ehCookies.isEmpty {
                    Text("无 Cookie")
                        .foregroundStyle(.secondary)
                }
            }

            Section("ExHentai Cookies") {
                ForEach(exCookies, id: \.name) { cookie in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cookie.name)
                            .font(.subheadline.bold())
                        Text(cookie.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .contextMenu {
                        Button("复制") {
                            #if os(iOS)
                            UIPasteboard.general.string = "\(cookie.name)=\(cookie.value)"
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(cookie.name)=\(cookie.value)", forType: .string)
                            #endif
                        }
                    }
                }
                if exCookies.isEmpty {
                    Text("无 Cookie")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("身份 Cookies")
    }

    // MARK: - Default Categories View (对齐 Android: DefaultCategoryActivity)

    private var defaultCategoriesView: some View {
        let allCategories: [(String, Int)] = [
            ("同人志 (Doujinshi)", 1),
            ("漫画 (Manga)", 2),
            ("画师CG (Artist CG)", 4),
            ("游戏CG (Game CG)", 8),
            ("欧美 (Western)", 512),
            ("非H (Non-H)", 256),
            ("图集 (Image Set)", 16),
            ("Cosplay", 32),
            ("亚洲 (Asian Porn)", 64),
            ("杂项 (Misc)", 128),
        ]

        return List {
            ForEach(allCategories, id: \.1) { name, bit in
                Toggle(name, isOn: Binding(
                    get: {
                        _ = settingsRevision
                        return (AppSettings.shared.defaultCategories & bit) != 0
                    },
                    set: { newValue in
                        if newValue {
                            AppSettings.shared.defaultCategories |= bit
                        } else {
                            AppSettings.shared.defaultCategories &= ~bit
                        }
                        settingsRevision &+= 1
                    }
                ))
            }
        }
        .navigationTitle("默认搜索分类")
    }

    private var blockedTagsView: some View {
        List {
            Section {
                HStack {
                    TextField("namespace:tag", text: $newBlockedTag)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addBlockedTag)
                    Button("添加", action: addBlockedTag)
                        .disabled(newBlockedTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("屏蔽标签会应用到首页、热门、订阅和搜索结果。列表缺少标签摘要时，应用会通过图库 API 补全后再显示。")
            }

            Section("已屏蔽（\(AppSettings.shared.blockedTags.count)）") {
                if AppSettings.shared.blockedTags.isEmpty {
                    ContentUnavailableView("暂无屏蔽标签", systemImage: "eye.slash")
                } else {
                    ForEach(AppSettings.shared.blockedTags, id: \.self) { tag in
                        Text(tag)
                            .textSelection(.enabled)
                            .contextMenu {
                                Button("取消屏蔽", role: .destructive) {
                                    AppSettings.shared.unblockTag(tag)
                                }
                            }
                    }
                    .onDelete { offsets in
                        let tags = AppSettings.shared.blockedTags
                        for index in offsets where tags.indices.contains(index) {
                            AppSettings.shared.unblockTag(tags[index])
                        }
                    }
                }
            }

            if !AppSettings.shared.blockedTags.isEmpty {
                Section {
                    Button("清空屏蔽标签", role: .destructive) {
                        AppSettings.shared.blockedTags = []
                    }
                }
            }
        }
        .navigationTitle("已屏蔽标签")
    }

    private func addBlockedTag() {
        let tag = newBlockedTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        AppSettings.shared.blockTag(tag)
        newBlockedTag = ""
    }

    // MARK: - Excluded Tag Namespaces View (对齐 Android: ExcludedTagNamespacesActivity)

    private var excludedNamespacesView: some View {
        let namespaces: [(String, Int)] = [
            ("Reclass", 1),
            ("Language", 2),
            ("Parody", 4),
            ("Character", 8),
            ("Group", 16),
            ("Artist", 32),
            ("Male", 64),
            ("Female", 128),
            ("Mixed", 256),
            ("Cosplayer", 512),
            ("Other", 1024),
            ("Temp", 2048),
        ]

        return List {
            Section {
                Text("已选中的命名空间将从搜索结果的标签列表中排除")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(namespaces, id: \.1) { name, bit in
                Toggle(name, isOn: Binding(
                    get: {
                        _ = settingsRevision
                        return (AppSettings.shared.excludedTagNamespaces & bit) != 0
                    },
                    set: { newValue in
                        if newValue {
                            AppSettings.shared.excludedTagNamespaces |= bit
                        } else {
                            AppSettings.shared.excludedTagNamespaces &= ~bit
                        }
                        settingsRevision &+= 1
                    }
                ))
            }
        }
        .navigationTitle("排除的标签命名空间")
    }

    // MARK: - Excluded Languages View (对齐 Android: ExcludedLanguagesActivity)

    private var excludedLanguagesView: some View {
        let languages = [
            "Japanese", "English", "Chinese", "Dutch", "French",
            "German", "Hungarian", "Italian", "Korean", "Polish",
            "Portuguese", "Russian", "Spanish", "Thai", "Vietnamese",
            "N/A", "Other",
        ]

        return List {
            Section {
                Text("已选中的语言将从搜索结果中排除")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(languages.enumerated()), id: \.offset) { index, lang in
                let bit = 1 << index
                Toggle(lang, isOn: Binding(
                    get: {
                        _ = settingsRevision
                        let current = Int(AppSettings.shared.excludedLanguages ?? "0") ?? 0
                        return (current & bit) != 0
                    },
                    set: { newValue in
                        var current = Int(AppSettings.shared.excludedLanguages ?? "0") ?? 0
                        if newValue {
                            current |= bit
                        } else {
                            current &= ~bit
                        }
                        AppSettings.shared.excludedLanguages = String(current)
                        settingsRevision &+= 1
                    }
                ))
            }
        }
        .navigationTitle("排除的语言")
    }
}

// MARK: - ViewModel

@MainActor
@Observable
class SettingsViewModel {
    var isLoggedIn = false
    var hasExAccess = false
    var displayName: String?
    var userId: String?
    var showLogoutConfirm = false
    var showLogin = false
    var isSyncingHiddenTags = false
    var hiddenTagSyncResult: String?

    var gallerySite: Int = 0 {
        didSet {
            let newSite = EhSite(rawValue: gallerySite) ?? .eHentai
            guard newSite != AppSettings.shared.gallerySite else { return }
            AppSettings.shared.gallerySite = newSite
            GalleryCache.shared.clearAll()
            hiddenTagSyncResult = nil
        }
    }
    var listMode: Int = 0 {
        didSet { AppSettings.shared.listMode = ListMode(rawValue: listMode) ?? .list }
    }
    var showJpnTitle: Bool = false {
        didSet { AppSettings.shared.showJpnTitle = showJpnTitle }
    }
    var showTagTranslations: Bool = true {
        didSet { AppSettings.shared.showTagTranslations = showTagTranslations }
    }
    
    // 标签数据库状态
    var isUpdatingTagDb = false
    var tagDbUpdateSuccess = false
    var tagDbStatus: String {
        let db = EhTagDatabase.shared
        if db.isLoaded {
            if let version = db.version {
                return AppLocalization.format("已加载 (%@)", String(version.prefix(10)))
            }
            return AppLocalization.localized("已加载")
        }
        return AppLocalization.localized("未加载")
    }
    
    func updateTagDatabase() async {
        isUpdatingTagDb = true
        tagDbUpdateSuccess = false
        
        do {
            try await EhTagDatabase.shared.updateDatabase(forceUpdate: true)
            await MainActor.run {
                self.tagDbUpdateSuccess = true
                self.isUpdatingTagDb = false
            }
        } catch {
            debugLog("[SettingsVM] Failed to update tag database: \(error)")
            await MainActor.run {
                self.isUpdatingTagDb = false
            }
        }
    }
    
    var domainFronting: Bool = false {
        didSet { AppSettings.shared.domainFronting = domainFronting }
    }
    var dnsOverHttps: Bool = false {
        didSet { AppSettings.shared.dnsOverHttps = dnsOverHttps }
    }
    var builtInHosts: Bool = false {
        didSet { AppSettings.shared.builtInHosts = builtInHosts }
    }
    var preloadImage: Int = 5 {
        didSet { AppSettings.shared.preloadImage = preloadImage }
    }
    var keepScreenOn: Bool = false {
        didSet { AppSettings.shared.keepScreenOn = keepScreenOn }
    }
    var multiThread: Int = 3 {
        didSet { AppSettings.shared.multiThreadDownload = multiThread }
    }
    var downloadTimeout: Int = 60 {
        didSet { AppSettings.shared.downloadTimeout = downloadTimeout }
    }
    var downloadDelay: Int = 0 {
        didSet { AppSettings.shared.downloadDelay = downloadDelay }
    }
    var autoPageInterval: Int = 5 {
        didSet { AppSettings.shared.autoPageInterval = autoPageInterval }
    }
    var historyInfoSize: Int = 100 {
        didSet { AppSettings.shared.historyInfoSize = historyInfoSize }
    }

    // 日志导出 (连点 5 次版本号触发)
    var versionTapCount = 0
    var showLogExport = false

    // 网络诊断状态
    var isDiagnosing = false
    var diagnosisResult = ""
    var diagnosisSuccess = false

    var diskCacheSize: String = AppLocalization.localized("计算中...")
    var isClearingDiskCache = false
    @ObservationIgnored private var cacheSizeRequest = 0

    func calculateCacheSize() {
        guard !isClearingDiskCache else { return }
        cacheSizeRequest &+= 1
        let request = cacheSizeRequest
        Task { [weak self] in
            let size = await Task.detached(priority: .utility) {
                Int64(URLCache.shared.currentDiskUsage) + SpiderDen.readCacheUsage()
            }.value
            guard let self, self.cacheSizeRequest == request else { return }
            self.updateCacheSize(size)
        }
    }

    private func updateCacheSize(_ bytes: Int64) {
        let byteFormatter = ByteCountFormatter()
        byteFormatter.allowedUnits = [.useMB, .useGB]
        byteFormatter.countStyle = .file
        diskCacheSize = byteFormatter.string(fromByteCount: bytes)
    }

    func clearCache() {
        guard !isClearingDiskCache else { return }
        isClearingDiskCache = true
        // Invalidate an older size calculation while deletion is in progress.
        cacheSizeRequest &+= 1
        // 清除内存缓存
        GalleryCache.shared.clearAll()
        ThumbnailMemoryCache.shared.removeAll()
        ReaderViewModel.clearDecodedImageCache()
        Task { [weak self] in
            let size = await Task.detached(priority: .utility) {
                URLCache.shared.removeAllCachedResponses()
                SpiderDen.clearReadCache()
                return Int64(URLCache.shared.currentDiskUsage) + SpiderDen.readCacheUsage()
            }.value
            guard let self else { return }
            self.updateCacheSize(size)
            self.isClearingDiskCache = false
        }
    }

    var showDownloadDirectoryPicker = false
    private var downloadLocationRevision = 0

    var downloadPath: String {
        _ = downloadLocationRevision
        return DownloadManager.shared.downloadDirectory.path
    }

    var hasCustomDownloadPath: Bool {
        _ = downloadLocationRevision
        return UserDefaults.standard.data(forKey: "downloadDirectoryBookmark") != nil
            || UserDefaults.standard.string(forKey: "downloadPath")?.isEmpty == false
    }

    #if os(macOS)
    func chooseDownloadPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = AppLocalization.localized("选择下载目录")
        panel.prompt = AppLocalization.localized("选择")

        if panel.runModal() == .OK, let url = panel.url {
            applyDownloadDirectory(url)
        }
    }
    #endif

    func handleDownloadDirectorySelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            applyDownloadDirectory(url)
        } catch {
            ErrorHandler.shared.handle(error, context: "ChooseDownloadDirectory")
        }
    }

    func resetDownloadPath() {
        Task {
            await DownloadManager.shared.pauseAllDownloads()
            DownloadManager.resetDownloadDirectory()
            downloadLocationRevision &+= 1
        }
    }

    private func applyDownloadDirectory(_ url: URL) {
        Task {
            await DownloadManager.shared.pauseAllDownloads()
            do {
                try DownloadManager.setDownloadDirectory(url)
                downloadLocationRevision &+= 1
            } catch {
                ErrorHandler.shared.handle(error, context: "SetDownloadDirectory")
            }
        }
    }

    init() {
        // 从 AppSettings 加载初始值到 stored properties
        // (didSet 不会在 init 中触发，所以这些赋值不会写回 AppSettings)
        gallerySite = AppSettings.shared.gallerySite.rawValue
        listMode = AppSettings.shared.listMode.rawValue
        showJpnTitle = AppSettings.shared.showJpnTitle
        showTagTranslations = AppSettings.shared.showTagTranslations
        domainFronting = AppSettings.shared.domainFronting
        dnsOverHttps = AppSettings.shared.dnsOverHttps
        builtInHosts = AppSettings.shared.builtInHosts
        preloadImage = AppSettings.shared.preloadImage
        keepScreenOn = AppSettings.shared.keepScreenOn
        multiThread = AppSettings.shared.multiThreadDownload
        downloadTimeout = AppSettings.shared.downloadTimeout
        downloadDelay = AppSettings.shared.downloadDelay
        autoPageInterval = AppSettings.shared.autoPageInterval
        historyInfoSize = AppSettings.shared.historyInfoSize
        
        checkLoginState()
        calculateCacheSize()
    }

    func checkLoginState() {
        let ehCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://e-hentai.org")!) ?? []
        isLoggedIn = ehCookies.contains { $0.name == "ipb_member_id" }

        // ExH 访问权限: 只要已登录(有 memberId + passHash)就允许切换到 ExHentai
        // igneous Cookie 只有首次访问 exhentai.org 后才会被种下
        // Android 端同样允许已登录用户自由切换站点
        let exCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://exhentai.org")!) ?? []
        let hasIgneous = exCookies.contains { $0.name == "igneous" && !$0.value.isEmpty && $0.value != "mystery" }
        hasExAccess = isLoggedIn || hasIgneous

        // 加载保存的用户信息
        displayName = AppSettings.shared.displayName
        userId = AppSettings.shared.userId

        // 如果没有保存 UID，尝试从 Cookie 读取
        if userId == nil || userId?.isEmpty == true {
            if let memberId = ehCookies.first(where: { $0.name == "ipb_member_id" })?.value {
                userId = memberId
                AppSettings.shared.userId = memberId
            }
        }
    }

    func syncHiddenTags() async {
        guard !isSyncingHiddenTags else { return }
        isSyncingHiddenTags = true
        hiddenTagSyncResult = nil
        defer { isSyncingHiddenTags = false }

        do {
            let list = try await EhAPI.shared.getWatchedList(
                url: EhURL.myTagsUrl(for: AppSettings.shared.gallerySite)
            )
            let hiddenTags = list.userTags.filter(\.hidden).map(\.tagName)
            AppSettings.shared.blockedTags.append(contentsOf: hiddenTags)
            hiddenTagSyncResult = hiddenTags.isEmpty
                ? AppLocalization.localized("没有屏蔽项")
                : AppLocalization.format("已同步 %lld 项", hiddenTags.count)
        } catch {
            hiddenTagSyncResult = AppLocalization.localized("同步失败")
            debugLog("[SettingsVM] 同步我的标签失败: \(error)")
        }
    }

    func logout() {
        // 清除所有 EH 相关 Cookie
        let storage = HTTPCookieStorage.shared
        for domain in ["e-hentai.org", "exhentai.org", ".e-hentai.org", ".exhentai.org"] {
            if let cookies = storage.cookies(for: URL(string: "https://\(domain)")!) {
                for cookie in cookies { storage.deleteCookie(cookie) }
            }
        }
        isLoggedIn = false
        hasExAccess = false
        displayName = nil
        userId = nil
        AppSettings.shared.isLogin = false
        AppSettings.shared.displayName = nil
        AppSettings.shared.userId = nil
        AppSettings.shared.avatar = nil
    }
    
    /// 网络诊断
    func runNetworkDiagnostics() {
        guard !isDiagnosing else { return }
        isDiagnosing = true
        diagnosisResult = ""
        diagnosisSuccess = false
        
        Task {
            var results: [String] = []
            var allSuccess = true
            
            // 1. DNS 解析测试
            let hosts = ["e-hentai.org", "exhentai.org"]
            for host in hosts {
                let hostRef = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
                var resolved = DarwinBoolean(false)
                CFHostStartInfoResolution(hostRef, .addresses, nil)
                if let addresses = CFHostGetAddressing(hostRef, &resolved)?.takeUnretainedValue() as? [Data], !addresses.isEmpty {
                    // 提取 IP 地址
                    if let addr = addresses.first {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        addr.withUnsafeBytes { ptr in
                            let sockaddr = ptr.bindMemory(to: sockaddr.self).baseAddress!
                            getnameinfo(sockaddr, socklen_t(addr.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                        }
                        let ip = String(cString: hostname)
                        results.append("✓ \(host) → \(ip)")
                    }
                } else {
                    results.append(AppLocalization.format("✗ %@ DNS 解析失败", host))
                    allSuccess = false
                }
            }
            
            // 2. HTTPS 连接测试
            for host in hosts {
                let url = URL(string: "https://\(host)/")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                request.httpMethod = "HEAD"
                
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse {
                        if httpResponse.statusCode == 200 || httpResponse.statusCode == 302 {
                            results.append(AppLocalization.format("✓ %@ HTTPS 连接正常", host))
                        } else {
                            results.append(AppLocalization.format("⚠ %@ HTTP %lld", host, httpResponse.statusCode))
                        }
                    }
                } catch let error as NSError {
                    if error.domain == NSURLErrorDomain {
                        switch error.code {
                        case NSURLErrorTimedOut:
                            results.append(AppLocalization.format("✗ %@ 连接超时", host))
                        case NSURLErrorCannotConnectToHost:
                            results.append(AppLocalization.format("✗ %@ 无法连接", host))
                        case NSURLErrorSecureConnectionFailed:
                            results.append(AppLocalization.format("✗ %@ TLS 错误 (可能被阻断)", host))
                        case NSURLErrorServerCertificateUntrusted:
                            results.append(AppLocalization.format("✗ %@ 证书不受信任", host))
                        default:
                            results.append(AppLocalization.format("✗ %@ 错误: %@", host, error.localizedDescription))
                        }
                    } else {
                        results.append(AppLocalization.format("✗ %@ 错误: %@", host, error.localizedDescription))
                    }
                    allSuccess = false
                }
            }
            
            // 3. 代理检测
            #if os(iOS)
            let proxySettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
            if let httpProxy = proxySettings?["HTTPProxy"] as? String, !httpProxy.isEmpty {
                results.append(AppLocalization.format("ℹ 检测到 HTTP 代理: %@", httpProxy))
            }
            #endif
            
            await MainActor.run {
                self.diagnosisResult = results.joined(separator: "\n")
                self.diagnosisSuccess = allSuccess
                self.isDiagnosing = false
            }
        }
    }

    // MARK: - 下载管理 (对齐 Android)

    // MARK: - 恢复/清理 状态
    var isRestoring = false
    var restoreResultMessage: String?
    var isCleaning = false
    var cleanResultMessage: String?
    var showCleanConfirm = false
    var cleanOrphanCount = 0
    var cleanOrphanSize: String = ""

    /// 恢复下载项目 (对齐 Android: RestoreDownloadPreference)
    /// 扫描下载目录中的 .ehviewer 文件，将不在数据库中的画廊重新加入下载记录
    func restoreDownloadItems() {
        guard !isRestoring else { return }
        isRestoring = true
        restoreResultMessage = nil

        Task {
            let downloadDir = DownloadManager.shared.downloadDirectory
            var restoredCount = 0
            var errorCount = 0

            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(
                at: downloadDir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                await MainActor.run {
                    self.restoreResultMessage = AppLocalization.localized("无法读取下载目录")
                    self.isRestoring = false
                }
                return
            }

            // 获取数据库中已有的 gid 集合
            let existingGids: Set<Int64>
            do {
                let records = try EhDatabase.shared.getAllDownloads()
                existingGids = Set(records.map { $0.gid })
            } catch {
                await MainActor.run {
                    self.restoreResultMessage = AppLocalization.format("数据库读取失败: %@", error.localizedDescription)
                    self.isRestoring = false
                }
                return
            }

            for dir in contents where dir.hasDirectoryPath {
                let ehviewerFile = dir.appendingPathComponent(".ehviewer")
                guard fm.fileExists(atPath: ehviewerFile.path) else { continue }

                // 读取 SpiderInfo 以获取 gid/token/pages
                guard let spiderInfo = SpiderInfoFile.read(from: dir) else { continue }
                guard spiderInfo.gid > 0, !spiderInfo.token.isEmpty else { continue }

                // 跳过已在数据库中的
                if existingGids.contains(spiderInfo.gid) { continue }

                // 从目录名提取标题: 格式为 "gid-title"
                let dirName = dir.lastPathComponent
                let prefix = "\(spiderInfo.gid)-"
                let title = dirName.hasPrefix(prefix) ? String(dirName.dropFirst(prefix.count)) : dirName

                // 统计已下载页数
                let imageFiles = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
                    .map { $0.filter { url in
                        let ext = url.pathExtension.lowercased()
                        return ["jpg", "jpeg", "png", "gif", "webp"].contains(ext)
                    }.count } ?? 0

                let record = DownloadRecord(
                    gid: spiderInfo.gid,
                    token: spiderInfo.token,
                    title: title,
                    pages: spiderInfo.pages,
                    state: imageFiles >= spiderInfo.pages ? DownloadManager.stateFinish : DownloadManager.stateNone,
                    date: Date()
                )

                do {
                    try EhDatabase.shared.insertDownload(record)
                    restoredCount += 1
                } catch {
                    errorCount += 1
                }
            }

            await MainActor.run {
                if restoredCount > 0 {
                    let restored = AppLocalization.format("成功恢复 %lld 个下载项目", restoredCount)
                    self.restoreResultMessage = errorCount > 0
                        ? restored + AppLocalization.format(" (%lld 个失败)", errorCount)
                        : restored
                } else {
                    self.restoreResultMessage = AppLocalization.localized("没有需要恢复的下载项目")
                }
                self.isRestoring = false
            }
        }
    }

    /// 清除冗余数据 (对齐 Android: CleanRedundancyPreference)
    /// 扫描下载目录，找出不在数据库记录中的孤立文件夹，提示用户确认删除
    func cleanRedundancy() {
        guard !isCleaning else { return }
        isCleaning = true
        cleanResultMessage = nil

        Task {
            let downloadDir = DownloadManager.shared.downloadDirectory
            let fm = FileManager.default

            guard let contents = try? fm.contentsOfDirectory(
                at: downloadDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                await MainActor.run {
                    self.cleanResultMessage = AppLocalization.localized("无法读取下载目录")
                    self.isCleaning = false
                }
                return
            }

            // 获取数据库中所有 gid
            let dbGids: Set<Int64>
            do {
                let records = try EhDatabase.shared.getAllDownloads()
                dbGids = Set(records.map { $0.gid })
            } catch {
                await MainActor.run {
                    self.cleanResultMessage = AppLocalization.localized("数据库读取失败")
                    self.isCleaning = false
                }
                return
            }

            // 找出孤立目录 (目录名以 gid- 开头，但 gid 不在数据库中)
            var orphanDirs: [URL] = []
            var totalSize: Int64 = 0
            for dir in contents where dir.hasDirectoryPath {
                let dirName = dir.lastPathComponent
                // 尝试提取 gid (格式: "gid-title")
                if let dashRange = dirName.firstIndex(of: "-"),
                   let gid = Int64(dirName[dirName.startIndex..<dashRange]) {
                    if !dbGids.contains(gid) {
                        orphanDirs.append(dir)
                        // 计算目录大小
                        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                            let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }
                            for fileURL in fileURLs {
                                let size = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
                                totalSize += Int64(size)
                            }
                        }
                    }
                }
            }

            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            let sizeStr = formatter.string(fromByteCount: totalSize)

            await MainActor.run {
                if orphanDirs.isEmpty {
                    self.cleanResultMessage = AppLocalization.localized("没有冗余数据")
                    self.isCleaning = false
                } else {
                    self.cleanOrphanCount = orphanDirs.count
                    self.cleanOrphanSize = sizeStr
                    self.showCleanConfirm = true
                    // isCleaning 保持 true 直到用户确认或取消
                }
            }
        }
    }

    /// 确认清除冗余数据 — 实际删除孤立目录
    func confirmCleanRedundancy() {
        Task {
            let downloadDir = DownloadManager.shared.downloadDirectory
            let fm = FileManager.default

            guard let contents = try? fm.contentsOfDirectory(
                at: downloadDir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                await MainActor.run {
                    self.cleanResultMessage = AppLocalization.localized("清除失败")
                    self.isCleaning = false
                }
                return
            }

            let dbGids: Set<Int64>
            do {
                let records = try EhDatabase.shared.getAllDownloads()
                dbGids = Set(records.map { $0.gid })
            } catch {
                await MainActor.run {
                    self.cleanResultMessage = AppLocalization.localized("清除失败")
                    self.isCleaning = false
                }
                return
            }

            var deletedCount = 0
            for dir in contents where dir.hasDirectoryPath {
                let dirName = dir.lastPathComponent
                if let dashRange = dirName.firstIndex(of: "-"),
                   let gid = Int64(dirName[dirName.startIndex..<dashRange]),
                   !dbGids.contains(gid) {
                    try? fm.removeItem(at: dir)
                    deletedCount += 1
                }
            }

            await MainActor.run {
                self.cleanResultMessage = AppLocalization.format("已清除 %lld 个冗余目录", deletedCount)
                self.isCleaning = false
            }
        }
    }

    func cancelClean() {
        isCleaning = false
        cleanResultMessage = nil
    }

    /// 清除内存缓存
    func clearMemoryCache() {
        GalleryCache.shared.clearAll()
        ThumbnailMemoryCache.shared.removeAll()
        ReaderViewModel.clearDecodedImageCache()
    }

    // MARK: - 数据导出/导入 (对齐 Android: ExportDataPreference / ImportDataPreference)

    var showImportPicker = false
    var showExportSuccess = false

    /// 仅导入导出当前 Apple 平台确实使用的设置。除避免把 Android 遗留项
    /// 再次带回外，也防止任意 JSON 写入应用的其他 UserDefaults 键。
    private static let portableSettingKeys: Set<String> = [
        "gallery_site", "multi_thread_download", "preload_image",
        "download_delay", "download_timeout", "download_origin_image",
        "read_cache_size", "list_mode", "show_jpn_title",
        "show_tag_translations", "show_gallery_comment", "show_gallery_pages",
        "show_gallery_rating", "wide_screen_list_mode", "default_categories",
        "blocked_gallery_tags", "reading_direction", "page_scaling",
        "start_position", "keep_screen_on", "reading_fullscreen",
        "gallery_show_clock", "gallery_show_progress", "gallery_show_battery",
        "show_page_interval", "auto_page_interval", "default_favorite_2",
        "fix_thumb_url", "enable_secure", "security_delay", "history_info_size",
        "app_language", "accent_color", "theme", "launch_page",
    ]

    /// 导出数据: 将 UserDefaults 设置导出为 JSON
    func exportData() {
        let defaults = UserDefaults.standard

        var exportDict: [String: Any] = [:]
        for key in Self.portableSettingKeys {
            if let value = defaults.object(forKey: key) {
                exportDict[key] = value
            }
        }

        // 收藏夹名称
        for i in 0..<10 {
            if let name = defaults.string(forKey: "fav_cat_\(i)") {
                exportDict["fav_cat_\(i)"] = name
            }
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: exportDict, options: .prettyPrinted) else {
            return
        }

        #if os(iOS)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ehviewer_settings.json")
        try? jsonData.write(to: tempURL)

        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
        #else
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ehviewer_settings.json"
        panel.title = AppLocalization.localized("导出设置")
        if panel.runModal() == .OK, let url = panel.url {
            try? jsonData.write(to: url)
        }
        #endif
    }

    /// 导入数据
    func importData() {
        showImportPicker = true
    }

    func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let defaults = UserDefaults.standard
        for (key, value) in dict {
            let isFavoriteName = (0..<10).contains { key == "fav_cat_\($0)" }
            guard Self.portableSettingKeys.contains(key) || isFavoriteName else { continue }
            defaults.set(value, forKey: key)
        }

        // 重新加载 ViewModel 的存储属性
        gallerySite = AppSettings.shared.gallerySite.rawValue
        listMode = AppSettings.shared.listMode.rawValue
        showJpnTitle = AppSettings.shared.showJpnTitle
        showTagTranslations = AppSettings.shared.showTagTranslations
        domainFronting = AppSettings.shared.domainFronting
        dnsOverHttps = AppSettings.shared.dnsOverHttps
        builtInHosts = AppSettings.shared.builtInHosts
        preloadImage = AppSettings.shared.preloadImage
        keepScreenOn = AppSettings.shared.keepScreenOn
        multiThread = AppSettings.shared.multiThreadDownload
        downloadTimeout = AppSettings.shared.downloadTimeout
        downloadDelay = AppSettings.shared.downloadDelay
        autoPageInterval = AppSettings.shared.autoPageInterval
        historyInfoSize = AppSettings.shared.historyInfoSize
    }
}

#Preview {
    SettingsView()
}
