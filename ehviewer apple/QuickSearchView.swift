//
//  QuickSearchView.swift
//  ehviewer apple
//
//  快速搜索管理视图
//

import SwiftUI
import EhModels
import EhDatabase

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
    @State private var vm = QuickSearchViewModel()
    @State private var selectedKeyboardIndex: Int?
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

    var body: some View {
        VStack(spacing: 0) {
            List {
                if currentKeyword.isEmpty {
                    Section {
                        if searchHistory.isEmpty {
                            emptyRow("暂无搜索历史")
                        } else {
                            ForEach(recentSearchHistory, id: \.self) { term in
                                historyRow(term, item: .history(term))
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
                                savedSearchRow(search, item: .saved(search))
                            }
                        }
                    } header: {
                        sectionHeader("已保存的搜索", systemImage: "bookmark")
                    }
                } else {
                    if !matchingHistory.isEmpty {
                        Section {
                            ForEach(matchingHistory, id: \.self) { term in
                                historyRow(term, item: .history(term))
                            }
                        } header: {
                            sectionHeader("搜索历史", systemImage: "clock")
                        }
                    }

                    if !matchingSavedSearches.isEmpty {
                        Section {
                            ForEach(matchingSavedSearches, id: \.id) { search in
                                savedSearchRow(search, item: .saved(search))
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
                                    )
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
            .contentMargins(.vertical, 6, for: .scrollContent)
            .frame(maxHeight: 320)

            if !currentKeyword.isEmpty && !isCurrentSearchSaved {
                Divider()

                Button(action: saveCurrentSearch) {
                    Label("保存当前搜索", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(isKeyboardSelected(.save) ? Color.accentColor.opacity(0.13) : Color.clear)
                .onHover { hovering in
                    if hovering { selectKeyboardItem(.save) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .accessibilityIdentifier("quickSearch.panel")
        .task { vm.loadSearches() }
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

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private func emptyRow(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private var currentKeyword: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var recentSearchHistory: [String] {
        Array(searchHistory.prefix(5))
    }

    private var matchingHistory: [String] {
        recentSearchHistory.filter { normalized($0) == normalized(currentKeyword) }
    }

    private var matchingSavedSearches: [QuickSearchRecord] {
        vm.searches.filter { search in
            normalized(search.keyword ?? "") == normalized(currentKeyword)
                || normalized(search.name ?? "") == normalized(currentKeyword)
        }
    }

    private var hasMatchingRecord: Bool {
        !matchingHistory.isEmpty || !matchingSavedSearches.isEmpty
    }

    private var isCurrentSearchSaved: Bool {
        vm.searches.contains { vm.isEquivalent($0, to: currentSearch) }
    }

    private func historyRow(_ term: String, item: KeyboardItem) -> some View {
        HStack(spacing: 8) {
            Button {
                onSelectHistory(term)
                onDismiss()
            } label: {
                Label(term, systemImage: "clock")
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            deleteButton(help: "删除历史记录 \(term)") {
                onDeleteHistory(term)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .padding(.vertical, 5)
        .listRowInsets(EdgeInsets())
        .background(
            isKeyboardSelected(item) ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { hovering in
            if hovering { selectKeyboardItem(item) }
        }
    }

    private func savedSearchRow(_ search: QuickSearchRecord, item: KeyboardItem) -> some View {
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
                vm.delete(searches: [search])
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .padding(.vertical, 5)
        .listRowInsets(EdgeInsets())
        .background(
            isKeyboardSelected(item) ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { hovering in
            if hovering { selectKeyboardItem(item) }
        }
    }

    private func suggestionRow(
        _ suggestion: (chinese: String, english: String),
        item: KeyboardItem
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
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .listRowInsets(EdgeInsets())
        .background(
            isKeyboardSelected(item) ? Color.accentColor.opacity(0.13) : Color.clear,
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
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func saveCurrentSearch() {
        guard !currentKeyword.isEmpty, !isCurrentSearchSaved else { return }
        vm.addSearch(currentSearch)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private enum KeyboardItem: Equatable {
        case history(String)
        case saved(QuickSearchRecord)
        case suggestion(chinese: String, english: String)
        case save
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
            if !isCurrentSearchSaved { items.append(.save) }
        }
        return items
    }

    private func isKeyboardSelected(_ item: KeyboardItem) -> Bool {
        guard let selectedKeyboardIndex,
              keyboardItems.indices.contains(selectedKeyboardIndex)
        else { return false }
        return keyboardItems[selectedKeyboardIndex] == item
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

@Observable
class QuickSearchViewModel {
    var searches: [QuickSearchRecord] = []

    func loadSearches() {
        do {
            searches = try EhDatabase.shared.getAllQuickSearches()
        } catch {
            debugLog("Failed to load quick searches: \(error)")
        }
    }

    func addSearch(_ record: QuickSearchRecord) {
        guard !searches.contains(where: { isEquivalent($0, to: record) }) else { return }
        do {
            try EhDatabase.shared.insertQuickSearch(record)
            loadSearches()
        } catch {
            debugLog("Failed to add quick search: \(error)")
        }
    }

    func isEquivalent(_ lhs: QuickSearchRecord, to rhs: QuickSearchRecord) -> Bool {
        lhs.mode == rhs.mode
            && lhs.category == rhs.category
            && lhs.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
                == rhs.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
            && lhs.advanceSearch == rhs.advanceSearch
            && lhs.minRating == rhs.minRating
            && lhs.pageFrom == rhs.pageFrom
            && lhs.pageTo == rhs.pageTo
    }

    func delete(at offsets: IndexSet) {
        let records = offsets.compactMap { index in
            searches.indices.contains(index) ? searches[index] : nil
        }
        delete(searches: records)
    }

    func delete(searches records: [QuickSearchRecord]) {
        let ids = Set(records.compactMap(\.id))
        for id in ids {
            do {
                try EhDatabase.shared.deleteQuickSearch(id: id)
            } catch {
                debugLog("Failed to delete quick search: \(error)")
            }
        }
        searches.removeAll { record in
            guard let id = record.id else { return false }
            return ids.contains(id)
        }
    }
}
