import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Dictation.date, order: .reverse) private var history: [Dictation]
    @State private var search = ""
    @State private var language = "all"
    @State private var selection: PersistentIdentifier?
    @State private var showInspector = true

    private var filtered: [Dictation] {
        history.filter { d in
            (language == "all" || d.language == language) &&
            (search.isEmpty || d.text.localizedCaseInsensitiveContains(search) || (d.appName ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    private var sections: [(day: Date, items: [Dictation])] {
        let cal = Calendar.current
        var out: [(Date, [Dictation])] = []
        for d in filtered {
            let day = cal.startOfDay(for: d.date)
            if out.last?.0 == day { out[out.count - 1].1.append(d) } else { out.append((day, [d])) }
        }
        return out
    }

    private var selected: Dictation? {
        guard let selection else { return nil }
        return history.first { $0.persistentModelID == selection }
    }

    var body: some View {
        Group {
            if history.isEmpty {
                ContentUnavailableView("Nothing dictated yet", systemImage: "waveform",
                                       description: Text("Everything you dictate is kept here, with what you said and what got pasted."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(selection: $selection) {
                    ForEach(sections, id: \.day) { section in
                        Section(header(section.day)) {
                            ForEach(section.items) { d in
                                HistoryRow(item: d).tag(d.persistentModelID)
                                    .contextMenu {
                                        Button("Copy") { Paster.copy(d.text) }
                                        Divider()
                                        Button("Delete", role: .destructive) { delete(d) }
                                    }
                            }
                        }
                    }
                }
                .onDeleteCommand { if let s = selected { delete(s) } }
                .onCopyCommand { selected.map { [NSItemProvider(object: $0.text as NSString)] } ?? [] }
            }
        }
        .navigationTitle("History")
        .searchable(text: $search, placement: .toolbar, prompt: "Search what you said")
        .toolbar {
            ToolbarItem {
                Picker("Language", selection: $language) {
                    Text("All languages").tag("all")
                    Text("English").tag("en")
                    Text("Italian").tag("it")
                }
                .pickerStyle(.menu)
            }
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
            }
        }
        #if DEBUG
        .onAppear {
            if UserDefaults.standard.bool(forKey: "selectFirst") { selection = filtered.first?.persistentModelID }
        }
        #endif
        .inspector(isPresented: $showInspector) {
            HistoryInspector(item: selected) { delete($0) }
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
    }

    private func header(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private func delete(_ d: Dictation) {
        if selection == d.persistentModelID { selection = nil }
        context.delete(d)
        try? context.save()
    }
}

private struct HistoryRow: View {
    let item: Dictation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(bundleID: item.appBundleID, size: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text).lineLimit(2)
                Text("\(item.appName ?? "Unknown app"), \(item.words) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(item.date.shortTime)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 5)
    }
}

private struct HistoryInspector: View {
    let item: Dictation?
    let onDelete: (Dictation) -> Void

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pasted").font(.caption).foregroundStyle(.secondary)
                        Text(item.text).textSelection(.enabled)
                    }
                    if item.raw != item.text {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What you said").font(.caption).foregroundStyle(.secondary)
                            Text(item.raw).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        row("App", item.appName ?? "Unknown")
                        row("When", item.date.formatted(date: .abbreviated, time: .shortened))
                        row("Language", Format.languageName(item.language))
                        row("Words", "\(item.words)")
                        row("Speaking", Format.duration(item.audioSeconds))
                        row("Ready in", Format.seconds(item.latencyMs))
                        row("Engine", HistoryView.engineName(item.engine))
                    }
                    .font(.callout)
                    HStack {
                        Button("Copy") { Paster.copy(item.text) }
                        Button("Delete", role: .destructive) { onDelete(item) }
                    }
                    .buttonStyle(.glass)
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("No selection", systemImage: "text.quote",
                                   description: Text("Pick a dictation to see what you said and what got pasted."))
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v)
        }
    }
}

extension HistoryView {
    static func engineName(_ engine: String) -> String {
        switch engine {
        case "groq": "Groq cloud"
        case "parakeet": "Parakeet, on this Mac"
        case "whisper": "Whisper, on this Mac"
        default: "Apple, on this Mac"
        }
    }
}
