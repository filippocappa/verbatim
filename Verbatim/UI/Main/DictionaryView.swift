import SwiftData
import SwiftUI

struct DictionaryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \VocabEntry.added, order: .reverse) private var entries: [VocabEntry]
    @State private var selection = Set<PersistentIdentifier>()
    @State private var newWord = ""
    @State private var newHeard = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No words yet", systemImage: "character.book.closed")
                } description: {
                    Text("Add names and jargon you use. Or just fix a word after it's pasted, and it gets learned here.")
                }
            } else {
                Table(entries, selection: $selection) {
                    TableColumn("Word") { e in
                        Text(e.word).fontWeight(.medium)
                    }
                    .width(min: 120, ideal: 180)
                    TableColumn("Heard as") { e in
                        Text(e.heardAs.isEmpty ? "–" : e.heardAs.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Added") { e in
                        Text(e.learned ? "Learned" : "By you").foregroundStyle(.secondary)
                    }
                    .width(90)
                    TableColumn("Always replace") { e in
                        Toggle("", isOn: Binding(get: { e.alwaysReplace }, set: { e.alwaysReplace = $0; try? context.save() }))
                            .labelsHidden()
                            .disabled(e.heardAs.isEmpty)
                            .help(e.heardAs.isEmpty ? "Add a “heard as” spelling first" : "Swap it in without asking the cleanup model")
                    }
                    .width(110)
                }
                .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
                    Button("Delete", role: .destructive) { delete(ids) }
                }
                .onDeleteCommand { delete(selection) }
            }
        }
        .navigationTitle("Dictionary")
        .navigationSubtitle(entries.isEmpty ? "" : "\(entries.count) words")
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            TextField("Word or name", text: $newWord)
                .focused($addFocused)
                .onSubmit(add)
            TextField("Heard as (optional)", text: $newHeard)
                .onSubmit(add)
            Button("Add", action: add)
                .buttonStyle(.glass)
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
    }

    private func add() {
        guard Vocabulary.add(word: newWord, heardAs: newHeard.isEmpty ? nil : newHeard, in: context) != nil else { return }
        newWord = ""
        newHeard = ""
        addFocused = true
    }

    private func delete(_ ids: Set<PersistentIdentifier>) {
        for e in entries where ids.contains(e.persistentModelID) { context.delete(e) }
        try? context.save()
        selection.subtract(ids)
    }
}
