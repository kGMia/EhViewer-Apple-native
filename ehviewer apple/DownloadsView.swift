//
//  DownloadsView.swift
//  ehviewer apple
//
//  下载管理视图 (对齐 Android DownloadsScene: 标签分组、搜索、批量操作、状态过滤)
//

import SwiftUI
import EhModels
import EhDownload
import EhDatabase
import EhSettings
#if os(macOS)
import AppKit
#endif

// MARK: - 状态过滤枚举

enum DownloadStatusFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case downloading = "下载中"
    case waiting = "等待中"
    case paused = "已暂停"
    case finished = "已完成"
    case failed = "失败"

    var id: String { rawValue }
    var localizedTitle: String { AppLocalization.localized(rawValue) }
}

struct DownloadsView: View {
    @State private var vm = DownloadsViewModel()
    @Environment(\.readerPresentationAction) private var readerPresentationAction

    /// 嵌入父级导航栈时不再创建嵌套的 `NavigationStack`。
    private let isPushed: Bool

    init(isPushed: Bool = false) {
        self.isPushed = isPushed
    }

    private var floatingHeaderInset: CGFloat {
        #if os(macOS)
        104
        #else
        isPushed ? 104 : 44
        #endif
    }

    // MARK: - 标签/搜索/过滤
    @State private var labels: [DownloadLabelRecord] = []
    /// nil = 全部, "" = 默认(无标签), 其他 = 具体标签
    @State private var selectedLabel: String? = nil
    @State private var searchText = ""
    @State private var statusFilter: DownloadStatusFilter = .all

    // MARK: - 批量操作
    @State private var isSelectMode = false
    @State private var selectedGids: Set<Int64> = []
    @State private var showBatchDeleteConfirm = false
    /// 单项删除确认必须由页面持有。若把 confirmationDialog 放在可滑动行
    /// 内，List 收起 swipe 时可能重建/回收该行，菜单会随宿主一起消失。
    @State private var pendingDeleteTask: DownloadTask?
    @State private var showMoveLabelSheet = false
    @State private var showGalleryUpdates = false

    // MARK: - 标签管理
    @State private var showNewLabelAlert = false
    @State private var newLabelName = ""
    @State private var showRenameLabelAlert = false
    @State private var renamingLabel: DownloadLabelRecord?
    @State private var renameText = ""
    @State private var showDeleteLabelConfirm = false
    @State private var deletingLabel: DownloadLabelRecord?

    // MARK: - 阅读器 (fullScreenCover 呈现，隐藏导航栏)
    #if os(iOS)
    @State private var readerGallery: GalleryInfo?
    #else
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        Group {
            if isPushed {
                downloadsContent
            } else {
                NavigationStack {
                    downloadsContent
                }
            }
        }
        .task {
            await vm.loadTasks()
            await loadLabels()
        }
        .onDisappear {
            vm.stopRefreshing()
        }
    }

    private var downloadsContent: some View {
        ZStack(alignment: .top) {
            Group {
                // 内容
                if filteredTasks.isEmpty {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: "arrow.down.circle",
                        description: Text(emptyDescription)
                    )
                    .padding(.top, floatingHeaderInset)
                } else {
                    downloadList
                }
            }

            VStack(spacing: 0) {
                if isPushed {
                    ContentColumnSearchBar(text: $searchText, prompt: "搜索下载", isFloating: true) {
                        mainToolbarMenu
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                } else {
                    #if os(macOS)
                    ContentColumnSearchBar(text: $searchText, prompt: "搜索下载", isFloating: true) {
                        mainToolbarMenu
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    #endif
                }

                // 标签选择栏
                labelPicker
            }
            .zIndex(10)
        }
        .navigationTitle("下载")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .searchableWhen(!isPushed, text: $searchText, prompt: "搜索下载")
            .toolbar {
                if !isPushed {
                    ToolbarItem(placement: .automatic) {
                        mainToolbarMenu
                    }
                }
            }
            #endif
            // 批量移动标签 Sheet
            .sheet(isPresented: $showMoveLabelSheet) {
                batchMoveLabelSheet
            }
            .sheet(isPresented: $showGalleryUpdates) { GalleryUpdatesView() }
            // 批量删除确认
            .confirmationDialog("确认删除 \(selectedGids.count) 个下载？", isPresented: $showBatchDeleteConfirm, titleVisibility: .visible) {
                Button("仅删除记录", role: .destructive) {
                    batchDelete(withFiles: false)
                }
                Button("删除记录和文件", role: .destructive) {
                    batchDelete(withFiles: true)
                }
            }
            .confirmationDialog(
                "确认删除“\(pendingDeleteTask?.gallery.bestTitle ?? "该下载")”？",
                isPresented: Binding(
                    get: { pendingDeleteTask != nil },
                    set: { if !$0 { pendingDeleteTask = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("仅删除记录", role: .destructive) {
                    deletePendingTask(withFiles: false)
                }
                Button("删除记录和文件", role: .destructive) {
                    deletePendingTask(withFiles: true)
                }
                Button("取消", role: .cancel) {
                    pendingDeleteTask = nil
                }
            }
            // 新建标签
            .alert("新建标签", isPresented: $showNewLabelAlert) {
                TextField("标签名称", text: $newLabelName)
                Button("取消", role: .cancel) { newLabelName = "" }
                Button("创建") {
                    createLabel(newLabelName)
                    newLabelName = ""
                }
            }
            // 重命名标签
            .alert("重命名标签", isPresented: $showRenameLabelAlert) {
                TextField("新名称", text: $renameText)
                Button("取消", role: .cancel) { renameText = "" }
                Button("确定") {
                    if let label = renamingLabel {
                        renameLabel(label, newName: renameText)
                    }
                    renameText = ""
                }
            }
            // 删除标签确认
        .confirmationDialog("确认删除标签「\(deletingLabel?.label ?? "")」？\n该标签下的下载将移至默认分组。", isPresented: $showDeleteLabelConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let label = deletingLabel {
                        deleteLabel(label)
                    }
                }
        }
    }

    // MARK: - 过滤后的任务列表

    private var filteredTasks: [DownloadTask] {
        var tasks = vm.tasks

        // 标签过滤
        if let label = selectedLabel {
            if label.isEmpty {
                // "默认" = 无标签
                tasks = tasks.filter { $0.label == nil || $0.label?.isEmpty == true }
            } else {
                tasks = tasks.filter { $0.label == label }
            }
        }

        // 状态过滤
        switch statusFilter {
        case .all: break
        case .downloading:
            tasks = tasks.filter { $0.state == DownloadManager.stateDownload }
        case .waiting:
            tasks = tasks.filter { $0.state == DownloadManager.stateWait }
        case .paused:
            tasks = tasks.filter { $0.state == DownloadManager.stateNone }
        case .finished:
            tasks = tasks.filter { $0.state == DownloadManager.stateFinish }
        case .failed:
            tasks = tasks.filter { $0.state == DownloadManager.stateFailed }
        }

        // 搜索过滤
        if !searchText.isEmpty {
            tasks = tasks.filter {
                $0.gallery.bestTitle.localizedCaseInsensitiveContains(searchText)
            }
        }

        return tasks
    }

    private var emptyTitle: String {
        if selectedLabel != nil || statusFilter != .all || !searchText.isEmpty {
            return AppLocalization.localized("无匹配下载")
        }
        return AppLocalization.localized("暂无下载")
    }

    private var emptyDescription: String {
        if selectedLabel != nil || statusFilter != .all || !searchText.isEmpty {
            return AppLocalization.localized("试试更换筛选条件")
        }
        return AppLocalization.localized("在画廊详情页点击下载按钮")
    }

    // MARK: - 标签选择栏 (对齐 Android DownloadsScene Label Drawer)

    private var labelPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                // 全部
                labelChip(title: "全部", isSelected: selectedLabel == nil) {
                    selectedLabel = nil
                    exitSelectMode()
                }

                // 默认 (无标签)
                labelChip(title: "默认", isSelected: selectedLabel == "") {
                    selectedLabel = ""
                    exitSelectMode()
                }

                // 自定义标签
                ForEach(labels, id: \.id) { label in
                    labelChip(title: label.label, isSelected: selectedLabel == label.label) {
                        selectedLabel = label.label
                        exitSelectMode()
                    }
                    .contextMenu {
                        Button {
                            renamingLabel = label
                            renameText = label.label
                            showRenameLabelAlert = true
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            deletingLabel = label
                            showDeleteLabelConfirm = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }

                // 新增标签按钮
                Button {
                    showNewLabelAlert = true
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollClipDisabled()
    }

    private func labelChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        LiquidGlassFilterChip(isSelected: isSelected, action: action) {
            Text(title)
        }
    }

    private func countForFilter(_ filter: DownloadStatusFilter) -> Int {
        // 先用标签+搜索过滤，再按状态计数
        var tasks = vm.tasks
        if let label = selectedLabel {
            if label.isEmpty {
                tasks = tasks.filter { $0.label == nil || $0.label?.isEmpty == true }
            } else {
                tasks = tasks.filter { $0.label == label }
            }
        }
        if !searchText.isEmpty {
            tasks = tasks.filter { $0.gallery.bestTitle.localizedCaseInsensitiveContains(searchText) }
        }

        switch filter {
        case .all: return tasks.count
        case .downloading: return tasks.filter { $0.state == DownloadManager.stateDownload }.count
        case .waiting: return tasks.filter { $0.state == DownloadManager.stateWait }.count
        case .paused: return tasks.filter { $0.state == DownloadManager.stateNone }.count
        case .finished: return tasks.filter { $0.state == DownloadManager.stateFinish }.count
        case .failed: return tasks.filter { $0.state == DownloadManager.stateFailed }.count
        }
    }

    // MARK: - 主工具栏菜单

    private var mainToolbarMenu: some View {
        Menu {
            if isSelectMode {
                // 选择模式工具
                Button {
                    let allGids = Set(filteredTasks.map { $0.gallery.gid })
                    if selectedGids == allGids {
                        selectedGids.removeAll()
                    } else {
                        selectedGids = allGids
                    }
                } label: {
                    let allGids = Set(filteredTasks.map { $0.gallery.gid })
                    Label(AppLocalization.localized(selectedGids == allGids ? "取消全选" : "全选"),
                          systemImage: selectedGids == allGids ? "square" : "checkmark.square")
                }

                Divider()

                Button {
                    batchResume()
                } label: {
                    Label("批量开始 (\(selectedGids.count))", systemImage: "play")
                }
                .disabled(selectedGids.isEmpty)

                Button {
                    batchPause()
                } label: {
                    Label("批量暂停 (\(selectedGids.count))", systemImage: "pause")
                }
                .disabled(selectedGids.isEmpty)

                // 移动标签
                if !labels.isEmpty {
                    Button {
                        showMoveLabelSheet = true
                    } label: {
                        Label("移动标签 (\(selectedGids.count))", systemImage: "tag")
                    }
                    .disabled(selectedGids.isEmpty)
                }

                Divider()

                Button(role: .destructive) {
                    showBatchDeleteConfirm = true
                } label: {
                    Label("批量删除 (\(selectedGids.count))", systemImage: "trash")
                }
                .disabled(selectedGids.isEmpty)

                Divider()

                Button {
                    exitSelectMode()
                } label: {
                    Label("退出选择", systemImage: "xmark.circle")
                }
            } else {
                // 普通模式
                Button("检查画廊更新", systemImage: "arrow.clockwise") {
                    showGalleryUpdates = true
                }
                Divider()

                // 状态过滤 (对齐 Android DownloadsScene 状态筛选)
                Picker("状态过滤", selection: $statusFilter) {
                    ForEach(DownloadStatusFilter.allCases) { filter in
                        let count = countForFilter(filter)
                        if filter == .all {
                            Text(filter.localizedTitle).tag(filter)
                        } else {
                            Text(AppLocalization.format("%@ (%lld)", filter.localizedTitle, count)).tag(filter)
                        }
                    }
                }

                Divider()

                Button {
                    isSelectMode = true
                    selectedGids.removeAll()
                } label: {
                    Label("批量操作", systemImage: "checkmark.circle")
                }

                Divider()

                Button {
                    vm.resumeAll()
                } label: {
                    Label("全部开始", systemImage: "play.fill")
                }

                Button {
                    vm.pauseAll()
                } label: {
                    Label("全部暂停", systemImage: "pause.fill")
                }

                Divider()

                Button(role: .destructive) {
                    vm.clearFinished()
                } label: {
                    Label("清空已完成", systemImage: "trash")
                }
            }
        } label: {
            Label(
                AppLocalization.localized(isSelectMode ? "选择中" : "管理"),
                systemImage: isSelectMode ? "checkmark" : "slider.horizontal.3"
            )
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 13)
            .frame(height: 40)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    // MARK: - 下载列表

    private var downloadList: some View {
        List {
            Color.clear
                .frame(height: floatingHeaderInset)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ForEach(filteredTasks, id: \.gallery.gid) { task in
                if isSelectMode {
                    HStack(spacing: 12) {
                        Image(systemName: selectedGids.contains(task.gallery.gid) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedGids.contains(task.gallery.gid) ? Color.accentColor : Color.secondary)

                        DownloadTaskRow(
                            task: task,
                            fileSize: vm.fileSizes[task.gallery.gid],
                            showsInlineControl: false,
                            onPause: { vm.pauseTask(gid: task.gallery.gid) },
                            onResume: { vm.resumeTask(gid: task.gallery.gid) },
                            onRequestDelete: { pendingDeleteTask = task }
                        )
                    }
                    .contentShape(Rectangle())
                    // DownloadTaskRow 自身还有右键/滑动手势；选择手势
                    // 使用高优先级，确保点整行而不是只点圆圈都能选中。
                    .highPriorityGesture(
                        TapGesture().onEnded { toggleSelection(gid: task.gallery.gid) }
                    )
                } else {
                    // 点击打开阅读器 (使用 fullScreenCover 避免导航栏残留)
                    DownloadTaskRow(
                        task: task,
                        fileSize: vm.fileSizes[task.gallery.gid],
                        onOpen: {
                        #if os(iOS)
                        let route = ReaderWindowRoute(
                            gid: task.gallery.gid,
                            token: task.gallery.token,
                            pages: task.gallery.pages,
                            previewSet: nil,
                            initialPage: nil
                        )
                        if let readerPresentationAction {
                            readerPresentationAction.present(route)
                        } else {
                            readerGallery = task.gallery
                        }
                        #else
                        openWindow(value: ReaderWindowRoute(
                            gid: task.gallery.gid,
                            token: task.gallery.token,
                            pages: task.gallery.pages,
                            previewSet: nil,
                            initialPage: nil
                        ))
                        #endif
                        },
                        onPause: { vm.pauseTask(gid: task.gallery.gid) },
                        onResume: { vm.resumeTask(gid: task.gallery.gid) },
                        onRequestDelete: { pendingDeleteTask = task }
                    )
                }
            }
            .reorderable()
        }
        .reorderContainer(for: DownloadTask.self, itemID: \.gallery.gid,
                          isEnabled: !isSelectMode && selectedLabel == nil && statusFilter == .all && searchText.isEmpty && !vm.isReordering) { difference in
            let before: Int64?
            switch difference.destination.position {
            case .before(let id): before = id
            case .end: before = nil
            }
            Task { await vm.reorder(moving: difference.sources, before: before) }
        }
        .listStyle(.plain)
        #if os(iOS)
        .fullScreenCover(item: $readerGallery) { gallery in
            ImageReaderView(gid: gallery.gid, token: gallery.token, pages: gallery.pages)
                .id(gallery.gid)
        }
        #endif
    }

    // MARK: - 批量移动标签 Sheet

    private var batchMoveLabelSheet: some View {
        NavigationStack {
            List {
                // 移到默认 (无标签)
                Button {
                    batchChangeLabel(nil)
                    showMoveLabelSheet = false
                } label: {
                    Label("默认", systemImage: "tray")
                }

                // 具体标签
                ForEach(labels, id: \.id) { label in
                    Button {
                        batchChangeLabel(label.label)
                        showMoveLabelSheet = false
                    } label: {
                        Label(label.label, systemImage: "tag")
                    }
                }
            }
            .navigationTitle("移动到标签")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showMoveLabelSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - 辅助

    private func toggleSelection(gid: Int64) {
        if selectedGids.contains(gid) {
            selectedGids.remove(gid)
        } else {
            selectedGids.insert(gid)
        }
    }

    private func exitSelectMode() {
        isSelectMode = false
        selectedGids.removeAll()
    }

    private func deletePendingTask(withFiles: Bool) {
        guard let task = pendingDeleteTask else { return }
        pendingDeleteTask = nil
        vm.deleteTask(gid: task.gallery.gid, withFiles: withFiles)
    }

    // MARK: - 标签管理

    private func loadLabels() async {
        labels = await Task.detached(priority: .userInitiated) {
            (try? EhDatabase.shared.getAllDownloadLabels()) ?? []
        }.value
    }

    private func createLabel(_ name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        try? EhDatabase.shared.insertDownloadLabel(name.trimmingCharacters(in: .whitespaces))
        Task { await loadLabels() }
    }

    private func renameLabel(_ record: DownloadLabelRecord, newName: String) {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let oldLabel = record.label
        var updated = record
        updated.label = newName.trimmingCharacters(in: .whitespaces)
        try? EhDatabase.shared.updateDownloadLabel(updated)

        // 更新使用旧标签的下载任务
        Task {
            let tasksWithOldLabel = await DownloadManager.shared.getAllTasks().filter { $0.label == oldLabel }
            await DownloadManager.shared.changeLabel(gids: tasksWithOldLabel.map { $0.gallery.gid }, label: updated.label)
            await vm.loadTasks()
        }

        if selectedLabel == oldLabel {
            selectedLabel = updated.label
        }
        Task { await loadLabels() }
    }

    private func deleteLabel(_ record: DownloadLabelRecord) {
        guard let id = record.id else { return }
        let labelName = record.label

        // 将该标签下的任务移至默认 (无标签)
        Task {
            let tasksWithLabel = await DownloadManager.shared.getAllTasks().filter { $0.label == labelName }
            await DownloadManager.shared.changeLabel(gids: tasksWithLabel.map { $0.gallery.gid }, label: nil)
            await vm.loadTasks()
        }

        try? EhDatabase.shared.deleteDownloadLabel(id: id)
        if selectedLabel == labelName { selectedLabel = nil }
        Task { await loadLabels() }
    }

    // MARK: - 批量操作

    private func batchPause() {
        Task {
            for gid in selectedGids {
                await DownloadManager.shared.pauseDownload(gid: gid)
            }
            await vm.loadTasks()
            exitSelectMode()
        }
    }

    private func batchResume() {
        Task {
            for gid in selectedGids {
                await DownloadManager.shared.resumeDownload(gid: gid)
            }
            await vm.loadTasks()
            exitSelectMode()
        }
    }

    private func batchDelete(withFiles: Bool) {
        Task {
            for gid in selectedGids {
                await DownloadManager.shared.deleteDownload(gid: gid, deleteFiles: withFiles)
            }
            await vm.loadTasks()
            exitSelectMode()
        }
    }

    private func batchChangeLabel(_ label: String?) {
        Task {
            await DownloadManager.shared.changeLabel(gids: Array(selectedGids), label: label)
            await vm.loadTasks()
            exitSelectMode()
        }
    }
}

// MARK: - Download Task Row

struct DownloadTaskRow: View {
    let task: DownloadTask
    let fileSize: Int64?
    var showsInlineControl = true
    var onOpen: (() -> Void)?
    let onPause: () -> Void
    let onResume: () -> Void
    let onRequestDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 封面
            CachedAsyncImage(url: ThumbnailURLResolver.url(
                for: task.gallery.thumb,
                fixLegacy: AppSettings.shared.fixThumbUrl,
                site: AppSettings.shared.gallerySite
            )) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(.tertiarySystemFill)
            }
            .frame(width: 52, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 6) {
                // 标题
                Text(task.gallery.bestTitle)
                    .font(.subheadline)
                    .lineLimit(2)

                // 状态
                HStack(spacing: 8) {
                    statusIcon
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 进度条 + 页数详情
                if task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                    VStack(spacing: 2) {
                        ProgressView(value: progress)
                            .tint(.accentColor)
                        HStack {
                            Text("\(task.downloadedPages)/\(task.gallery.pages)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if showsInlineControl, task.state != DownloadManager.stateFinish {
                Button {
                    isActive ? onPause() : onResume()
                } label: {
                    Image(systemName: isActive ? "pause.fill" : "play.fill")
                        .font(.callout.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isActive ? .orange : .green)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(AppLocalization.localized(isActive ? "暂停" : "开始"))
                .accessibilityLabel(AppLocalization.localized(isActive ? "暂停下载" : "开始下载"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .contextMenu {
            // 暂停/恢复
            if task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                Button {
                    onPause()
                } label: {
                    Label("暂停", systemImage: "pause")
                }
            } else if task.state != DownloadManager.stateFinish {
                Button {
                    onResume()
                } label: {
                    Label("继续", systemImage: "play")
                }
            }

            Divider()

            // 删除
            Button(role: .destructive) {
                onRequestDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }

            #if os(macOS)
            // Mac: 在 Finder 中显示 (Fix A-3: 使用统一路径算法)
            if task.state == DownloadManager.stateFinish {
                Button {
                    let dirName = DownloadManager.galleryDirectoryName(gid: task.gallery.gid, title: task.gallery.bestTitle)
                    let dir = DownloadManager.shared.downloadDirectory
                        .appendingPathComponent(dirName)
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
            }
            #endif
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onRequestDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                Button {
                    onPause()
                } label: {
                    Label("暂停", systemImage: "pause")
                }
                .tint(.orange)
            } else if task.state != DownloadManager.stateFinish {
                Button {
                    onResume()
                } label: {
                    Label("继续", systemImage: "play")
                }
                .tint(.green)
            }
        }
    }

    private var isActive: Bool {
        task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait
    }

    private var statusIcon: some View {
        Group {
            switch task.state {
            case DownloadManager.stateDownload:
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            case DownloadManager.stateWait:
                Image(systemName: "clock.fill")
                    .foregroundStyle(.orange)
            case DownloadManager.stateFinish:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case DownloadManager.stateFailed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            default:
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var statusText: String {
        switch task.state {
        case DownloadManager.stateDownload: return AppLocalization.localized("下载中")
        case DownloadManager.stateWait: return AppLocalization.localized("等待中")
        case DownloadManager.stateFinish: return AppLocalization.localized("已完成")
        case DownloadManager.stateFailed: return AppLocalization.localized("失败")
        default: return AppLocalization.localized("已暂停")
        }
    }

    private var progress: Double {
        guard task.gallery.pages > 0 else { return 0 }
        return Double(task.downloadedPages) / Double(task.gallery.pages)
    }

    private var summaryText: String {
        guard let fileSize else { return AppLocalization.format("%lld 页", task.gallery.pages) }
        return AppLocalization.format(
            "%lld 页 · %@",
            task.gallery.pages,
            fileSize.formatted(.byteCount(style: .file).locale(AppLocalization.locale))
        )
    }
}

// MARK: - ViewModel

@MainActor
@Observable
class DownloadsViewModel {
    var tasks: [DownloadTask] = []
    /// 从磁盘异步计算的实际文件大小。它不参与每秒任务状态轮询。
    var fileSizes: [Int64: Int64] = [:]
    /// 有活跃下载时运行的可取消进度刷新任务。
    private var refreshTask: Task<Void, Never>?
    private var fileSizeTask: Task<Void, Never>?
    private var refreshTick = 0

    private(set) var isReordering = false

    func reorder(moving ids: [Int64], before destination: Int64?) async {
        guard !isReordering else { return }
        isReordering = true
        defer { isReordering = false }
        do {
            try await DownloadManager.shared.reorderDownloads(moving: ids, before: destination)
            await loadTasks()
        } catch { ErrorHandler.shared.handle(error, context: "ReorderDownloads") }
    }

    func loadTasks() async {
        let latestTasks = await DownloadManager.shared.getAllTasks()
        apply(latestTasks)
        refreshFileSizes(for: latestTasks, includeActive: true)
        updateRefreshTimer()
    }

    /// 检查是否有活跃下载，有则启动定时刷新
    private func updateRefreshTimer() {
        let hasActive = tasks.contains(where: {
            $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait
        })

        if hasActive && refreshTask == nil {
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    guard let self else { return }
                    let latestTasks = await DownloadManager.shared.getAllTasks()
                    self.apply(latestTasks)
                    self.refreshTick += 1
                    if self.refreshTick.isMultiple(of: 3) {
                        self.refreshFileSizes(for: latestTasks, includeActive: true)
                    }
                    let stillActive = latestTasks.contains {
                        $0.state == DownloadManager.stateDownload || $0.state == DownloadManager.stateWait
                    }
                    if !stillActive {
                        self.refreshTask = nil
                        return
                    }
                }
            }
        } else if !hasActive {
            stopRefreshing()
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
        fileSizeTask?.cancel()
        fileSizeTask = nil
    }

    func pauseTask(gid: Int64) {
        Task {
            await DownloadManager.shared.pauseDownload(gid: gid)
            await loadTasks()
        }
    }

    func resumeTask(gid: Int64) {
        Task {
            await DownloadManager.shared.resumeDownload(gid: gid)
            await loadTasks()
        }
    }

    func deleteTask(gid: Int64, withFiles: Bool = false) {
        Task {
            await DownloadManager.shared.deleteDownload(gid: gid, deleteFiles: withFiles)
            await loadTasks()
        }
    }

    func pauseAll() {
        Task {
            for task in tasks where task.state == DownloadManager.stateDownload || task.state == DownloadManager.stateWait {
                await DownloadManager.shared.pauseDownload(gid: task.gallery.gid)
            }
            await loadTasks()
        }
    }

    func resumeAll() {
        Task {
            for task in tasks where task.state == DownloadManager.stateNone || task.state == DownloadManager.stateFailed {
                await DownloadManager.shared.resumeDownload(gid: task.gallery.gid)
            }
            await loadTasks()
        }
    }

    /// Fix A-2: 清除已完成下载时同时删除文件，释放磁盘空间
    func clearFinished() {
        Task {
            for task in tasks where task.state == DownloadManager.stateFinish {
                await DownloadManager.shared.deleteDownload(gid: task.gallery.gid, deleteFiles: true)
            }
            await loadTasks()
        }
    }

    /// 只有展示相关字段发生变化时才替换数组，避免相同的一秒轮询结果
    /// 触发整个 List 重新求值和图片视图更新。
    private func apply(_ latestTasks: [DownloadTask]) {
        let hasSamePresentation = tasks.count == latestTasks.count
            && zip(tasks, latestTasks).allSatisfy { old, new in
                old.gallery.gid == new.gallery.gid
                    && old.gallery.bestTitle == new.gallery.bestTitle
                    && old.gallery.pages == new.gallery.pages
                    && old.state == new.state
                    && old.downloadedPages == new.downloadedPages
                    && old.label == new.label
            }

        if !hasSamePresentation {
            tasks = latestTasks
        }

        let liveGIDs = Set(latestTasks.map { $0.gallery.gid })
        if fileSizes.keys.contains(where: { !liveGIDs.contains($0) }) {
            fileSizes = fileSizes.filter { liveGIDs.contains($0.key) }
        }
    }

    private func refreshFileSizes(for tasks: [DownloadTask], includeActive: Bool) {
        guard fileSizeTask == nil else { return }
        let baseDirectory = DownloadManager.shared.downloadDirectory
        let inputs = tasks.compactMap { task -> FileSizeInput? in
            let isActive = task.state == DownloadManager.stateDownload
                || task.state == DownloadManager.stateWait
            guard fileSizes[task.gallery.gid] == nil || (includeActive && isActive) else {
                return nil
            }
            let directoryName = DownloadManager.galleryDirectoryName(
                gid: task.gallery.gid,
                title: task.gallery.bestTitle
            )
            return FileSizeInput(
                gid: task.gallery.gid,
                directory: baseDirectory.appendingPathComponent(directoryName)
            )
        }
        guard !inputs.isEmpty else { return }

        fileSizeTask = Task { [weak self] in
            let measured = await Task.detached(priority: .utility) {
                Self.measureFileSizes(inputs)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.fileSizes.merge(measured, uniquingKeysWith: { _, latest in latest })
            self.fileSizeTask = nil
        }
    }

    nonisolated private static func measureFileSizes(_ inputs: [FileSizeInput]) -> [Int64: Int64] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey
        ]
        var result: [Int64: Int64] = [:]
        result.reserveCapacity(inputs.count)

        for input in inputs {
            guard let enumerator = fileManager.enumerator(
                at: input.directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                result[input.gid] = 0
                continue
            }

            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true
                else { continue }
                total += Int64(values.fileSize ?? 0)
            }
            result[input.gid] = total
        }
        return result
    }

    private struct FileSizeInput: Sendable {
        let gid: Int64
        let directory: URL
    }
}

#Preview {
    DownloadsView()
}
