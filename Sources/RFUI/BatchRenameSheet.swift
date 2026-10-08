import AppKit
import RFModel
import RFOperations
import SwiftUI

/// Rename N Items… (DESIGN.md I9): rules with a live preview; problems block the rename.
@MainActor
@Observable
final class BatchRenameModel {
    let items: [FileItem]
    let existing: Set<String>
    var rule = RenameRule()
    var onFinish: ((Bool) -> Void)?

    init(items: [FileItem], existing: Set<String>) {
        self.items = items
        self.existing = existing
    }

    var newNames: [String] { rule.newNames(for: items.map { ($0.name, $0.modified) }) }
    var problems: [Int: String] { RenameRule.problems(old: items.map(\.name), new: newNames, existing: existing) }
    var changeCount: Int { zip(items, newNames).filter { $0.0.name != $0.1 }.count }
    var canRename: Bool { rule.regexProblem == nil && problems.isEmpty && changeCount > 0 }

    var pairs: [OperationRequest.Pair] {
        zip(items, newNames).compactMap { item, name in
            name == item.name ? nil : .init(from: item.url, to: item.url.deletingLastPathComponent().appendingPathComponent(name))
        }
    }
}

struct BatchRenameView: View {
    @Bindable var model: BatchRenameModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(model.items.count) Items").font(.headline)
            Picker("", selection: $model.rule.mode) {
                ForEach(RenameRule.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Form { controls }.formStyle(.columns)
            Toggle("Include the extension", isOn: $model.rule.includeExtension)
            preview
            HStack {
                if let problem = model.rule.regexProblem {
                    Text(problem).foregroundStyle(.red)
                } else if !model.problems.isEmpty {
                    Text("\(model.problems.count) name\(model.problems.count == 1 ? "" : "s") can't be used.").foregroundStyle(.red)
                } else {
                    Text("\(model.changeCount) of \(model.items.count) will change.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.onFinish?(false) }.keyboardShortcut(.cancelAction)
                Button("Rename") { model.onFinish?(true) }.keyboardShortcut(.defaultAction).disabled(!model.canRename)
            }
        }
        .padding(18)
        .frame(width: 560, height: 470)
    }

    @ViewBuilder private var controls: some View {
        switch model.rule.mode {
        case .replace:
            TextField("Find:", text: $model.rule.find)
            TextField("Replace with:", text: $model.rule.replacement)
            HStack {
                Toggle("Regular expression", isOn: $model.rule.useRegex)
                    .help("Use $1, $2… in the replacement for captured groups")
                Toggle("Match case", isOn: $model.rule.caseSensitive)
            }
        case .add:
            TextField("Text:", text: $model.rule.text)
            Picker("Where:", selection: $model.rule.position) {
                Text("After name").tag(RenameRule.Position.after)
                Text("Before name").tag(RenameRule.Position.before)
            }
        case .format:
            TextField("Custom format:", text: $model.rule.baseName)
            Picker("Number:", selection: $model.rule.numberStyle) {
                Text("Index (1, 2, 3)").tag(RenameRule.NumberStyle.index)
                Text("Counter (00001)").tag(RenameRule.NumberStyle.counter)
                Text("Date modified").tag(RenameRule.NumberStyle.date)
            }
            Picker("Where:", selection: $model.rule.numberPosition) {
                Text("After name").tag(RenameRule.Position.after)
                Text("Before name").tag(RenameRule.Position.before)
            }
            TextField("Start numbers at:", value: $model.rule.startAt, format: .number)
        case .changeCase:
            Picker("Change to:", selection: $model.rule.newCase) {
                Text("lowercase").tag(RenameRule.Case.lower)
                Text("UPPERCASE").tag(RenameRule.Case.upper)
                Text("Title Case").tag(RenameRule.Case.title)
            }
        }
    }

    private var preview: some View {
        let names = model.newNames
        let problems = model.problems
        return List(Array(model.items.enumerated()), id: \.offset) { i, item in
            HStack {
                Text(item.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(names[i]).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(problems[i] != nil ? .red : (names[i] == item.name ? .secondary : .primary))
                    if let p = problems[i] { Text(p).font(.caption).foregroundStyle(.red) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 180)
    }
}

extension BrowserViewController {
    /// File › Rename with several items selected.
    func showBatchRename() {
        let items = state.selectedItems
        guard items.count > 1, let window = view.window else { return }
        let existing = Set(state.snapshot.items.map(\.name))
        let model = BatchRenameModel(items: items, existing: existing)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = NSHostingView(rootView: BatchRenameView(model: model))
        model.onFinish = { [weak self, weak window, weak sheet] rename in
            if let sheet { window?.endSheet(sheet) }
            guard rename, let self else { return }
            FileOperationsUI.shared.submit(.batchRename(model.pairs), from: self.state)
        }
        window.beginSheet(sheet)
    }
}
