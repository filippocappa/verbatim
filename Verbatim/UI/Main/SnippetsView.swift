import SwiftData
import SwiftUI

struct SnippetsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Snippet.added, order: .reverse) private var snippets: [Snippet]
    @State private var newTrigger = ""
    @State private var newText = ""
    @State private var editing: Snippet?
    @FocusState private var addFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Snippets")
                        .font(.pageTitle)
                    Text(verbatim: "Say a trigger while dictating and the saved text goes in its place. “Send it to my email” comes out as “Send it to you@example.com”.")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                addBar
                    .padding(16)
                    .tile()

                if snippets.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Start from one of these").font(.headline)
                        Text("Click one to put it in the boxes above, change it to yours, then Add.")
                            .font(.callout).foregroundStyle(.secondary)
                        VStack(spacing: 6) {
                            ForEach(Self.ideas, id: \.trigger) { idea in
                                Button {
                                    newTrigger = idea.trigger
                                    newText = idea.text
                                    addFocused = true
                                } label: {
                                    SnippetLine(trigger: idea.trigger, text: idea.text, uses: nil)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(16)
                    .tile()
                } else {
                    VStack(spacing: 6) {
                        ForEach(snippets) { s in
                            SnippetLine(trigger: s.trigger, text: s.text, uses: s.uses)
                                .contentShape(.rect)
                                .onTapGesture(count: 2) { editing = s }
                                .contextMenu {
                                    Button("Edit…") { editing = s }
                                    Button("Delete", role: .destructive) { context.delete(s); try? context.save() }
                                }
                        }
                    }
                    .padding(10)
                    .tile()
                    Text("Double-click a snippet to edit it. Right-click to delete.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Snippets")
        .toolbarTitleDisplayMode(.inline)
        .sheet(item: $editing) { s in
            SnippetEditor(snippet: s)
        }
    }

    static let ideas: [(trigger: String, text: String)] = [
        ("my email", "you@example.com"),
        ("my phone", "+39 333 123 4567"),
        ("my address", "Via Roma 1, 20121 Milano"),
        ("meeting link", "https://cal.com/you/30min"),
        ("sign off", "Thanks,\nYour name"),
    ]

    private var addBar: some View {
        HStack(spacing: 8) {
            TextField("When you say, e.g. my email", text: $newTrigger)
                .focused($addFocused)
                .frame(maxWidth: 240)
                .onSubmit(add)
            TextField("It writes", text: $newText)
                .onSubmit(add)
            Button("Add", action: add)
                .buttonStyle(.glass)
                .disabled(!canAdd)
                .keyboardShortcut(.defaultAction)
        }
        .textFieldStyle(.roundedBorder)
    }

    private var canAdd: Bool {
        !Snippets.key(newTrigger).isEmpty && !newText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func add() {
        guard canAdd else { return }
        let trigger = newTrigger.trimmingCharacters(in: .whitespaces)
        if let existing = snippets.first(where: { Snippets.key($0.trigger) == Snippets.key(trigger) }) {
            existing.text = newText
        } else {
            context.insert(Snippet(trigger: trigger, text: newText))
        }
        try? context.save()
        newTrigger = ""
        newText = ""
        addFocused = true
    }

}

/// One snippet: the trigger, then what it turns into.
private struct SnippetLine: View {
    let trigger: String
    let text: String
    let uses: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(trigger)
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: .capsule)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            Text(text.replacingOccurrences(of: "\n", with: " ⏎ "))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let uses {
                Text(uses == 0 ? "not used yet" : "used \(uses)×")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 10))
    }
}

/// Double-click a snippet to edit it. The text can span several lines.
private struct SnippetEditor: View {
    @Bindable var snippet: Snippet
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("When you say").font(.headline)
                TextField("my email", text: $snippet.trigger)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("It writes").font(.headline)
                TextEditor(text: $snippet.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))
                    .frame(minHeight: 140)
            }
            HStack {
                Spacer()
                Button("Done") {
                    try? context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Snippets.key(snippet.trigger).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
