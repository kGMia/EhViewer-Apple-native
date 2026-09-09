//
//  QuickSearchView.swift
//  ehviewer apple
//
//  快速搜索管理视图
//

import SwiftUI
import EhModels
import EhDatabase
import EhSettings

enum SearchPanelKeyboardAction: Equatable {
    case previous
    case next
    case confirm
}

struct SearchPanelKeyboardCommand: Equatable {
    let id = UUID()
    let action: SearchPanelKeyboardAction
}

/// 统一搜索记录下拉面板：直接显示在搜索框下方，搜索历史在上、
/// 已保存搜索在下。保留数据库格式与应用逻辑，但不再创建侧边抽屉。
struct SearchRecordsPanelContent: View {
    @Bindable var vm: QuickSearchViewModel
    @State private var selectedKeyboardIndex: Int?
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .caption) private var sectionHeight: CGFloat = 30
    @Binding var selectedSearch: QuickSearchRecord?
    let searchHistory: [String]
    let currentSearch: QuickSearchRecord
    let searchText: String
    let suggestions: [(chinese: String, english: String)]
    let onSelectHistory: (String) -> Void
    let onDeleteHistory: (String) -> Void
    let onSelectSuggestion: (String) -> Void
    let onSubmitCurrentSearch: () -> Void
    let onDismiss: () -> Void
    let keyboardCommand: SearchPanelKeyboardCommand?
    var canSaveCurrentSearch = true
    var maximumHeight: CGFloat = 320

    var body: some View {
        let items = keyboardItems
        let selection = selectedKeyboardIndex.flatMap { items.indices.contains($0) ? items[$0] : nil }
        return VStack(spacing: 0) {
            ScrollViewReader { scroll in
                List {
                    if currentKeyword.isEmpty {
                        Section {
                            if searchHistory.isEmpty {
                                emptyRow("暂无搜索历史")
                            } else {
                                ForEach(recentSearchHistory, id: \.self) { term in
                                    historyRow(term, item: .history(term), selection: selection)
                                }
                            }
                        } header: {
                            sectionHeader("搜索历史", systemImage: "clock")
                        }

                        Section {
                            if vm.searches.isEmpty {
                                emptyRow("暂无已保存搜索")
                            } else {
                                ForEach(vm.searches, id: \.id) { search in
                                    savedSearchRow(search, item: .saved(search), selection: selection)
                                }
                            }
                        } header: {
                            sectionHeader("已保存的搜索", systemImage: "bookmark")
                        }
                    } else {
                        if !matchingHistory.isEmpty {
                            Section {
                                ForEach(matchingHistory, id: \.self) { term in
                                    historyRow(term, item: .history(term), selection: selection)
                                }
                            } header: {
                                sectionHeader("搜索历史", systemImage: "clock")
                            }
                        }

                        if !matchingSavedSearches.isEmpty {
                            Section {
                                ForEach(matchingSavedSearches, id: \.id) { search in
                                    savedSearchRow(search, item: .saved(search), selection: selection)
                                }
                            } header: {
                                sectionHeader("已保存的搜索", systemImage: "bookmark")
                            }
                        }

                        if !suggestions.isEmpty {
                            Section {
                                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                                    suggestionRow(
                                        suggestion,
                                        item: .suggestion(
                                            chinese: suggestion.chinese,
                                            english: suggestion.english
                                        ), selection: selection
                                    )
                                }
                            } header: {
                                sectionHeader("候选搜索", systemImage: "sparkle.magnifyingglass")
                            }
                        } else if !hasMatchingRecord {
                            emptyRow("暂无候选搜索")
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .environment(\.defaultMinListRowHeight, rowHeight)
                .contentMargins(.vertical, 6, for: .scrollContent)
                #if os(iOS)
                .listSectionSpacing(.compact)
                #endif
                .frame(height: panelHeight)
                .onChange(of: selectedKeyboardIndex) { _, index in
                    guard let index, keyboardItems.indices.contains(index) else { return }
                    scroll.scrollTo(keyboardItems[index].scrollID, anchor: .center)
                }
            }

            if canSaveCurrentSearch && !currentKeyword.isEmpty && !isCurrentSearchSaved {
                Divider()

                Button(action: saveCurrentSearch) {
                    Label("保存当前搜索", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(vm.isMutating)
                .padding(.horizontal, SearchSurfaceStyle.inset)
                .padding(.vertical, 11)
                .background((selection == .save) ? Color.accentColor.opacity(0.13) : Color.clear)
                .onHover { hovering in
                    if hovering { selectKeyboardItem(.save) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: SearchSurfaceStyle.cornerRadius, style: .continuous))
        .background {
            SearchElasticSurface(isField: false)
                .allowsHitTesting(false)
        }
        .padding(.top, SearchSurfaceStyle.spacing)
        .accessibilityIdentifier("quickSearch.panel")
        .task { await vm.loadSearches() }
        .onChange(of: searchText) { _, _ in selectedKeyboardIndex = nil }
        .onChange(of: keyboardItems.count) { _, count in
            if let selectedKeyboardIndex, selectedKeyboardIndex >= count {
                self.selectedKeyboardIndex = count > 0 ? count - 1 : nil
            }
        }
        .onChange(of: keyboardCommand) { _, command in
            guard let command else { return }
            handleKeyboardCommand(command.action)
        }
    }

    private var panelHeight: CGFloat {
        let rows: Int
        let sections: Int
        if currentKeyword.isEmpty {
            rows = max(1, recentSearchHistory.count) + max(1, vm.searches.count)
            sections = 2
        } else {
            rows = max(1, matchingHistory.count + matchingSavedSearches.count + suggestions.count)
            sections = (matchingHistory.isEmpty ? 0 : 1) + (matchingSavedSearches.isEmpty ? 0 : 1)
                + (suggestions.isEmpty ? 0 : 1)
        }
        let footerHeight: CGFloat = canSaveCurrentSearch && !currentKeyword.isEmpty && !isCurrentSearchSaved ? rowHeight + 1 : 0
        let available = max(rowHeight, maximumHeight - footerHeight - 4)
        return min(available, CGFloat(rows) * rowHeight + CGFloat(sections) * sectionHeight + 12)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Text(AppLocalization.localized(title))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    private func emptyRow(_ title: String) -> some View {
        Text(AppLocalization.localized(title))
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
    }

    private var currentKeyword: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var recentSearchHistory: [String] {
        Array(searchHistory.prefix(5))
    }

    private var matchingHistory: [String] {
        Array(searchHistory.filter { SearchRecordMatching.matches($0, query: currentKeyword) }.prefix(8))
    }

    private var matchingSavedSearches: [QuickSearchRecord] {
        vm.searches.filter { search in
            SearchRecordMatching.matches(search.keyword ?? "", query: currentKeyword)
                || SearchRecordMatching.matches(search.name ?? "", query: currentKeyword)
        }
    }

    private var hasMatchingRecord: Bool {
        !matchingHistory.isEmpty || !matchingSavedSearches.isEmpty
    }

    private var isCurrentSearchSaved: Bool {
        vm.searches.contains { vm.isEquivalent($0, to: currentSearch) }
    }

    private func historyRow(_ term: String, item: KeyboardItem, selection: KeyboardItem?) -> some View {
        HStack(spacing: 8) {
            Button {
                onSelectHistory(term)
                onDismiss()
            } label: {
                Label {
                    Text(term).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            deleteButton(help: "删除历史记录 \(term)") {
                onDeleteHistory(term)
            }
        }
        .padding(.leading, SearchSurfaceStyle.inset)
        .padding(.trailing, 9)
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.primary.opacity(0.08))
        .id(item.scrollID)
        .background(
            (selection == item) ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { hovering in
            if hovering { selectKeyboardItem(item) }
        }
    }

    private func savedSearchRow(_ search: QuickSearchRecord, item: KeyboardItem, selection: KeyboardItem?) -> some View {
        HStack(spacing: 8) {
            Button {
                selectedSearch = search
                onDismiss()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(search.name ?? search.keyword ?? "未命名")
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let keyword = search.keyword, !keyword.isEmpty,
                           search.name != nil {
                            Text(keyword)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } icon: {
                    Image(systemName: "bookmark")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            deleteButton(help: "删除已保存搜索") {
                Task { await vm.delete(searches: [search]) }
            }
        }
        .padding(.leading, SearchSurfaceStyle.inset)
        .padding(.trailing, 9)
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.primary.opacity(0.08))
        .id(item.scrollID)
        .background(
            (selection == item) ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { hovering in
            if hovering { selectKeyboardItem(item) }
        }
    }

    private func suggestionRow(
        _ suggestion: (chinese: String, english: String),
        item: KeyboardItem, selection: KeyboardItem?
    ) -> some View {
        Button {
            onSelectSuggestion(suggestion.english)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.chinese)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(suggestion.english)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SearchSurfaceStyle.inset)
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.primary.opacity(0.08))
        .id(item.scrollID)
        .background(
            (selection == item) ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { hovering in
            if hovering { selectKeyboardItem(item) }
        }
    }

    private func deleteButton(help: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .disabled(vm.isMutating)
    }

    private func saveCurrentSearch() {
        guard canSaveCurrentSearch, !currentKeyword.isEmpty, !isCurrentSearchSaved else { return }
        Task { await vm.addSearch(currentSearch) }
    }

    private enum KeyboardItem: Equatable {
        case history(String)
        case saved(QuickSearchRecord)
        case suggestion(chinese: String, english: String)
        case save

        var scrollID: String {
            switch self {
            case .history(let term): "history:\(term)"
            case .saved(let search): "saved:\(search.id ?? 0)"
            case .suggestion(_, let english): "suggestion:\(english)"
            case .save: "save"
            }
        }
    }

    private var keyboardItems: [KeyboardItem] {
        var items: [KeyboardItem]
        if currentKeyword.isEmpty {
            items = recentSearchHistory.map(KeyboardItem.history)
                + vm.searches.map(KeyboardItem.saved)
        } else {
            items = matchingHistory.map(KeyboardItem.history)
                + matchingSavedSearches.map(KeyboardItem.saved)
                + suggestions.map {
                    KeyboardItem.suggestion(chinese: $0.chinese, english: $0.english)
                }
            if canSaveCurrentSearch && !isCurrentSearchSaved { items.append(.save) }
        }
        return items
    }

    private func selectKeyboardItem(_ item: KeyboardItem) {
        selectedKeyboardIndex = keyboardItems.firstIndex(of: item)
    }

    private func handleKeyboardCommand(_ action: SearchPanelKeyboardAction) {
        let items = keyboardItems
        switch action {
        case .previous:
            guard !items.isEmpty else { return }
            selectedKeyboardIndex = selectedKeyboardIndex.map {
                ($0 - 1 + items.count) % items.count
            } ?? (items.count - 1)
        case .next:
            guard !items.isEmpty else { return }
            selectedKeyboardIndex = selectedKeyboardIndex.map {
                ($0 + 1) % items.count
            } ?? 0
        case .confirm:
            guard let selectedKeyboardIndex,
                  items.indices.contains(selectedKeyboardIndex)
            else {
                onSubmitCurrentSearch()
                return
            }
            perform(items[selectedKeyboardIndex])
        }
    }

    private func perform(_ item: KeyboardItem) {
        switch item {
        case .history(let term):
            onSelectHistory(term)
            onDismiss()
        case .saved(let search):
            selectedSearch = search
            onDismiss()
        case .suggestion(_, let english):
            selectedKeyboardIndex = nil
            onSelectSuggestion(english)
        case .save:
            saveCurrentSearch()
        }
    }
}

// MARK: - ViewModel

/// Disk operations run on this serial actor, never while laying out a panel.
actor QuickSearchStore {
    static let shared = QuickSearchStore()
    private let database: EhDatabase?

    init(database: EhDatabase? = nil) { self.database = database }

    func load() throws -> [QuickSearchRecord] {
        try (database ?? .shared).getAllQuickSearches()
    }

    func add(_ record: QuickSearchRecord) throws -> [QuickSearchRecord] {
        let database = database ?? .shared
        if try !database.getAllQuickSearches().contains(where: { SearchRecordMatching.equivalent($0, record) }) {
            try database.insertQuickSearch(record)
        }
        return try database.getAllQuickSearches()
    }

    func delete(_ ids: Set<Int64>) throws -> [QuickSearchRecord] {
        let database = database ?? .shared
        for id in ids { try database.deleteQuickSearch(id: id) }
        return try database.getAllQuickSearches()
    }
}

enum SearchRecordMatching {
    nonisolated static func matches(_ value: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !query.isEmpty && value.localizedStandardContains(query)
    }

    nonisolated static func equivalent(_ lhs: QuickSearchRecord, _ rhs: QuickSearchRecord) -> Bool {
        lhs.mode == rhs.mode && lhs.category == rhs.category
            && lhs.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
                == rhs.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
            && lhs.advanceSearch == rhs.advanceSearch && lhs.minRating == rhs.minRating
            && lhs.pageFrom == rhs.pageFrom && lhs.pageTo == rhs.pageTo
    }
}

@MainActor
@Observable
final class QuickSearchViewModel {
    private(set) var searches: [QuickSearchRecord] = []
    private(set) var isMutating = false
    @ObservationIgnored private let store: QuickSearchStore
    @ObservationIgnored private var generation = 0

    init(store: QuickSearchStore = .shared) { self.store = store }

    func loadSearches() async {
        guard !isMutating else { return }
        generation &+= 1
        let request = generation
        do {
            let records = try await store.load()
            guard request == generation, !Task.isCancelled else { return }
            searches = records
        } catch { debugLog("Failed to load quick searches: \(error)") }
    }

    func addSearch(_ record: QuickSearchRecord) async {
        guard !isMutating else { return }
        isMutating = true
        generation &+= 1 // invalidate a panel load already in flight
        defer { isMutating = false }
        do { searches = try await store.add(record) }
        catch { debugLog("Failed to add quick search: \(error)") }
    }

    func isEquivalent(_ lhs: QuickSearchRecord, to rhs: QuickSearchRecord) -> Bool {
        SearchRecordMatching.equivalent(lhs, rhs)
    }

    func delete(searches records: [QuickSearchRecord]) async {
        guard !isMutating else { return }
        isMutating = true
        generation &+= 1
        defer { isMutating = false }
        do { searches = try await store.delete(Set(records.compactMap(\.id))) }
        catch {
            // Reload after a possible partial failure, so the UI agrees with
            // what was actually deleted. Never automatically retry a write.
            debugLog("Failed to delete quick search: \(error)")
            if let remaining = try? await store.load() { searches = remaining }
        }
    }
}
