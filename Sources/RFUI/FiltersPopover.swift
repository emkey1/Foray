import AppKit
import RFFileSystem
import RFModel
import SwiftUI

/// The search criteria editor (DESIGN.md §4.6): the current filters in words, each removable, and
/// menus to add one. It edits the search text itself, so the field always shows the whole search.
@MainActor
@Observable
final class FiltersModel {
    var text: String
    var draft = SearchFilters.Draft()
    let onChange: (String) -> Void

    init(text: String, onChange: @escaping (String) -> Void) {
        self.text = text
        self.onChange = onChange
    }

    var items: [(token: String, description: String)] { SearchFilters.items(in: text) }

    func remove(at index: Int) {
        text = SearchFilters.removing(at: index, from: text)
        onChange(text)
    }

    func add() {
        guard let token = draft.token else { return }
        text = SearchFilters.adding(token, to: text)
        onChange(text)
        draft.text = ""
    }
}

struct FiltersView: View {
    @Bindable var model: FiltersModel
    private let kinds = KindCatalog.shared.categories
    private let tags = Tags.finderFavorites().map(\.name)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search filters").font(.headline)
            if model.items.isEmpty {
                Text("No filters yet: everything in the search scope matches.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                HStack {
                    Text(item.description)
                    Spacer()
                    Text(item.token).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    Button { model.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this filter")
                }
            }
            Divider()
            HStack {
                Picker("", selection: $model.draft.field) {
                    ForEach(SearchFilters.Field.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                valueControls
                Spacer()
                Button("Add") { model.add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.draft.token == nil)
            }
            Text("Filters are words in the search field, e.g. kind:images size:>5MB modified:<7d. You can type them too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 560)
    }

    @ViewBuilder private var valueControls: some View {
        switch model.draft.field {
        case .kind:
            Picker("", selection: $model.draft.kind) {
                ForEach(kinds, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().frame(width: 150)
        case .name, .content:
            TextField(model.draft.field == .name ? "contains…" : "word or phrase", text: $model.draft.text).frame(width: 200)
                .onSubmit { model.add() }
        case .ext:
            TextField("pdf", text: $model.draft.text).frame(width: 90).onSubmit { model.add() }
        case .tag:
            HStack {
                TextField("tag", text: $model.draft.text).frame(width: 120).onSubmit { model.add() }
                if !tags.isEmpty {
                    Menu("") { ForEach(tags, id: \.self) { t in Button(t) { model.draft.text = t } } }
                        .menuStyle(.borderlessButton).frame(width: 28)
                }
            }
        case .size:
            Picker("", selection: $model.draft.sizeComparison) {
                Text("larger than").tag(SearchFilters.SizeComparison.larger)
                Text("smaller than").tag(SearchFilters.SizeComparison.smaller)
            }
            .labelsHidden().frame(width: 120)
            TextField("", value: $model.draft.number, format: .number).frame(width: 60)
            Picker("", selection: $model.draft.sizeUnit) {
                ForEach(SearchFilters.SizeUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 70)
        case .modified, .created, .added, .opened:
            Picker("", selection: $model.draft.dateComparison) {
                ForEach(SearchFilters.DateComparison.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().frame(width: 140)
            switch model.draft.dateComparison {
            case .withinLast, .olderThan:
                TextField("", value: $model.draft.number, format: .number).frame(width: 50)
                Picker("", selection: $model.draft.dateUnit) {
                    ForEach(SearchFilters.DateUnit.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 90)
            case .inYear:
                TextField("", value: $model.draft.year, format: .number.grouping(.never)).frame(width: 70)
            case .today, .yesterday:
                EmptyView()
            }
        case .hidden:
            Text("include hidden files").foregroundStyle(.secondary)
        }
    }
}
