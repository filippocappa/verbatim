import AppKit
import SwiftUI

/// A meeting's notes file, read from Documents → Verbatim Meetings. The files are the record:
/// they open in any Markdown app, and this page just shows them nicely.
struct MeetingFile: Identifiable, Equatable {
    let url: URL
    let title: String
    let started: Date
    let bundleID: String?
    let service: String?
    /// Length, from the last line's time.
    let length: String?
    let text: String
    var id: URL { url }

    init?(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.url = url
        self.text = text
        let lines = text.components(separatedBy: "\n")
        title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? url.deletingPathExtension().lastPathComponent
        let meta = lines.first { $0.hasPrefix("<!-- verbatim") } ?? ""
        func field(_ k: String) -> String? {
            meta.components(separatedBy: " ").first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) }
        }
        bundleID = field("app").flatMap { $0.isEmpty ? nil : $0 }
        service = field("service").flatMap { $0.isEmpty ? nil : $0 }
        started = field("started").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            ?? ((try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        // A recording says how long it is. A call: from start to the file's last write (the recap, just after it ends).
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? started
        let minutes = Int((field("length").flatMap(Double.init) ?? modified.timeIntervalSince(started)) / 60)
        length = started == .distantPast ? nil : minutes < 1 ? "under a minute" : minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func all() -> [MeetingFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: MeetingNotes.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "md" }.compactMap(MeetingFile.init).sorted { $0.started > $1.started }
    }
}

struct MeetingsView: View {
    @State private var meetings: [MeetingFile] = []
    @State private var selection: URL?
    @State private var search = ""
    @State private var confirmDelete: MeetingFile?
    @State private var asking = false
    private var controller: MeetingController { .shared }
    private var importer: MeetingImport { .shared }

    private var filtered: [MeetingFile] {
        search.isEmpty ? meetings : meetings.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    private var sections: [(day: Date, items: [MeetingFile])] {
        var out: [(Date, [MeetingFile])] = []
        for m in filtered {
            let day = Calendar.current.startOfDay(for: m.started)
            if out.last?.0 == day { out[out.count - 1].1.append(m) } else { out.append((day, [m])) }
        }
        return out
    }

    private var selected: MeetingFile? { meetings.first { $0.url == selection } ?? filtered.first }

    var body: some View {
        Group {
            if meetings.isEmpty {
                ContentUnavailableView {
                    Label("No meetings yet", systemImage: "video")
                } description: {
                    Text("When a call starts in Zoom, Meet, Teams or another call app, \(AppInfo.name) offers to take notes. Each meeting gets a recap and a transcript here. You can also drop a recording here.")
                } actions: {
                    HStack {
                        Button("Take Notes Now") { controller.start() }
                        Button("Transcribe a Recording…") { importer.pick() }
                    }
                    .buttonStyle(.glass)
                }
            } else {
                HStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(sections, id: \.day) { section in
                            Section(header(section.day)) {
                                ForEach(section.items) { m in
                                    MeetingRow(meeting: m, live: isLive(m), note: note(m)).tag(m.url)
                                        .contextMenu {
                                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.url]) }
                                            Divider()
                                            Button("Move to Trash", role: .destructive) { confirmDelete = m }
                                        }
                                }
                            }
                        }
                    }
                    .frame(width: 280)
                    Divider()
                    if let m = selected {
                        MeetingDetail(meeting: m, live: isLive(m), note: note(m)) { reload() }
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
        }
        .navigationTitle("Meetings")
        .searchable(text: $search, placement: .toolbar, prompt: "Search meetings")
        .toolbar {
            ToolbarItem {
                if controller.isRecording {
                    Button { controller.stop() } label: { Label("Stop Notes", systemImage: "stop.circle") }
                } else {
                    Button { controller.start() } label: { Label("Take Notes", systemImage: "record.circle") }
                }
            }
            ToolbarItem {
                Button { asking = true } label: { Label("Ask", systemImage: "text.magnifyingglass") }
                    .help("Ask a question about all your meetings")
                    .disabled(meetings.isEmpty)
            }
            ToolbarItem {
                Button { importer.pick() } label: { Label("Transcribe a Recording", systemImage: "waveform.badge.plus") }
                    .help("Transcribe a recording or a video into a meeting. You can also drop it here.")
            }
            ToolbarItem {
                Button { NSWorkspace.shared.open(MeetingNotes.folder) } label: { Label("Show Folder", systemImage: "folder") }
            }
        }
        .confirmationDialog("Move “\(confirmDelete?.title ?? "")” to the Trash?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let m = confirmDelete { try? FileManager.default.trashItem(at: m.url, resultingItemURL: nil) }
                confirmDelete = nil
                reload()
            }
        }
        // Files change while a call is being written, and the recap lands after it ends.
        .task {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: controller.lastFile) { _, new in if let new { selection = new } }
        .onChange(of: importer.file) { _, new in if let new { reload(); selection = new } }
        .sheet(isPresented: $asking) {
            MeetingAskView { m in
                search = ""
                selection = m.url
                asking = false
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            importer.add(urls)
            return true
        }
        .alert(importer.lastError ?? "", isPresented: Binding(
            get: { importer.lastError != nil }, set: { if !$0 { importer.lastError = nil } })) {
            Button("OK") {}
        }
    }

    private func isLive(_ m: MeetingFile) -> Bool {
        (controller.isRecording && controller.lastFile == m.url) || importer.file == m.url
    }

    /// What a recording being transcribed is up to.
    private func note(_ m: MeetingFile) -> String? { importer.file == m.url ? importer.status : nil }

    private func reload() {
        let fresh = MeetingFile.all()
        if fresh != meetings { meetings = fresh }
        if selection == nil || !meetings.contains(where: { $0.url == selection }) { selection = meetings.first?.url }
    }

    private func header(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

private struct MeetingRow: View {
    let meeting: MeetingFile
    let live: Bool
    var note: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if meeting.service == MeetingNotes.recordingService {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(.quaternary, in: .rect(cornerRadius: 5))
                } else if let service = meeting.service, let logo = ServiceLogos.shared.image(service) {
                    Image(nsImage: logo).resizable().frame(width: 20, height: 20).clipShape(.rect(cornerRadius: 5))
                } else {
                    AppIconView(bundleID: meeting.bundleID, size: 20)
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).lineLimit(1)
                HStack(spacing: 5) {
                    if let note {
                        ProgressView().controlSize(.mini)
                        Text(note)
                    } else if live {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text("Taking notes")
                    } else {
                        Text(meeting.started.shortTime)
                        if let l = meeting.length { Text("· \(l)") }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Detail

private struct MeetingDetail: View {
    let meeting: MeetingFile
    let live: Bool
    var note: String?
    let changed: () -> Void

    private enum Block: Hashable {
        case section(String), heading(String), bullet(String), task(String, done: Bool, line: Int)
        case line(time: String, speaker: String, text: String, line: Int), note(String), text(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var titleSeen = false
        for (i, raw) in meeting.text.components(separatedBy: "\n").enumerated() {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("<!--") { continue }
            if l.hasPrefix("# ") && !titleSeen { titleSeen = true; continue }
            if l.hasPrefix("## ") { out.append(.section(String(l.dropFirst(3)))) }
            else if l.hasPrefix("### ") { out.append(.heading(String(l.dropFirst(4)))) }
            else if l.hasPrefix("- [ ] ") { out.append(.task(String(l.dropFirst(6)), done: false, line: i)) }
            else if l.lowercased().hasPrefix("- [x] ") { out.append(.task(String(l.dropFirst(6)), done: true, line: i)) }
            else if l.hasPrefix("- ") || l.hasPrefix("* ") { out.append(.bullet(String(l.dropFirst(2)))) }
            else if l.hasPrefix("**"), let end = l.range(of: ":**") {
                let head = l[l.index(l.startIndex, offsetBy: 2)..<end.lowerBound].split(separator: " ", maxSplits: 1)
                out.append(.line(time: head.first.map(String.init) ?? "", speaker: head.count > 1 ? String(head[1]) : "Them",
                                 text: String(l[end.upperBound...]).trimmingCharacters(in: .whitespaces), line: i))
            }
            else if l.hasPrefix("_") && l.hasSuffix("_") { out.append(.note(String(l.dropFirst().dropLast()))) }
            else if out.isEmpty { continue } // the date line, shown in the header
            else { out.append(.text(l)) }
        }
        return out
    }

    /// Everyone in the transcript, in order of first line.
    private var speakers: [String] {
        var out: [String] = []
        for case let .line(_, s, _, _) in blocks where !out.contains(s) { out.append(s) }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.title).font(.pageTitle)
                    HStack(spacing: 6) {
                        if let note {
                            ProgressView().controlSize(.small)
                            Text("\(note). The transcript fills in as it goes.")
                        } else if live {
                            Circle().fill(.red).frame(width: 7, height: 7)
                            Text("Taking notes now. The transcript fills in as you talk.")
                        } else {
                            Text(meeting.started.formatted(date: .complete, time: .shortened))
                            if let l = meeting.length { Text("·"); Text(l) }
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.bottom, 14)

                HStack(spacing: 8) {
                    Button("Copy Notes") { Paster.copy(MeetingExport.markdown(meeting)) }
                    Menu("Export") {
                        ForEach(MeetingExport.Format.allCases, id: \.self) { f in
                            Button("\(f.rawValue)…") { MeetingExport.save(meeting, as: f) }
                        }
                    }
                    .fixedSize()
                    .disabled(live)
                    Button("Open in Editor") { NSWorkspace.shared.open(meeting.url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.url]) }
                }
                .buttonStyle(.glass).controlSize(.small)
                .padding(.bottom, 8)

                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in view(b) }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private func view(_ b: Block) -> some View {
        switch b {
        case let .section(t):
            Text(t).font(.title3.weight(.semibold)).padding(.top, 26).padding(.bottom, 8)
        case let .heading(t):
            Text(t).font(.callout.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 14).padding(.bottom, 4)
        case let .bullet(t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(t))
            }
            .padding(.vertical, 2)
        case let .task(t, done, line):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { toggle(line) } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(done ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                Text(inline(t)).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
            }
            .padding(.vertical, 2)
        case let .line(time, speaker, text, line):
            TranscriptLine(time: time, speaker: speaker, text: text, speakers: speakers, editable: !live,
                           rename: { rename(speaker, to: $0) },
                           edit: { setLine(line, text: $0) },
                           saidBy: { setSpeaker(line, time: time, to: $0) },
                           delete: { removeLine(line) })
        case let .note(t):
            Text(t).foregroundStyle(.secondary).italic().padding(.vertical, 2)
        case let .text(t):
            Text(inline(t)).padding(.vertical, 2)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }

    /// Puts a name on a voice everywhere in the file: transcript labels and the recap.
    private func rename(_ old: String, to new: String) {
        let new = new.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
        guard !new.isEmpty, new != old, new != "You" else { return }
        let parts = meeting.text.components(separatedBy: "\n## Transcript")
        guard parts.count == 2 else { return }
        let escaped = NSRegularExpression.escapedPattern(for: old)
        // In the recap: the label as a whole word ("Person 1", not "Person 10").
        let recap = parts[0].replacingOccurrences(of: "(?<![\\w#])\(escaped)(?![\\w])", with: NSRegularExpression.escapedTemplate(for: new),
                                                  options: .regularExpression)
        // In the transcript: only the speaker labels, "**1:23 Person 1:**".
        let transcript = parts[1].replacingOccurrences(of: "(\\*\\*[0-9:]+ )\(escaped)(:\\*\\*)", with: "$1\(NSRegularExpression.escapedTemplate(for: new))$2",
                                                       options: .regularExpression)
        try? (recap + "\n## Transcript" + transcript).write(to: meeting.url, atomically: true, encoding: .utf8)
        VoiceBook.renamed(old, to: new, in: meeting.url)
        changed()
    }

    // MARK: Editing one line

    private func setLine(_ i: Int, text: String) {
        var lines = meeting.text.components(separatedBy: "\n")
        guard lines.indices.contains(i), let end = lines[i].range(of: ":**") else { return }
        let t = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return removeLine(i) }
        lines[i] = String(lines[i][..<end.upperBound]) + " " + t
        save(lines)
    }

    /// One line was said by someone else. The voice book isn't taught from a single line.
    private func setSpeaker(_ i: Int, time: String, to name: String) {
        var lines = meeting.text.components(separatedBy: "\n")
        guard lines.indices.contains(i), let end = lines[i].range(of: ":**") else { return }
        lines[i] = "**\(time) \(name):**" + lines[i][end.upperBound...]
        save(lines)
    }

    private func removeLine(_ i: Int) {
        var lines = meeting.text.components(separatedBy: "\n")
        guard lines.indices.contains(i) else { return }
        lines.remove(at: i)
        // And the blank line that separated it.
        if lines.indices.contains(i), lines[i].trimmingCharacters(in: .whitespaces).isEmpty { lines.remove(at: i) }
        else if i > 0, lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty { lines.remove(at: i - 1) }
        save(lines)
    }

    private func save(_ lines: [String]) {
        try? lines.joined(separator: "\n").write(to: meeting.url, atomically: true, encoding: .utf8)
        changed()
    }

    /// Ticks an action item in the file itself.
    private func toggle(_ line: Int) {
        var lines = meeting.text.components(separatedBy: "\n")
        guard line < lines.count else { return }
        if lines[line].contains("- [ ] ") { lines[line] = lines[line].replacingOccurrences(of: "- [ ] ", with: "- [x] ") }
        else { lines[line] = lines[line].replacingOccurrences(of: "- [x] ", with: "- [ ] ").replacingOccurrences(of: "- [X] ", with: "- [ ] ") }
        try? lines.joined(separator: "\n").write(to: meeting.url, atomically: true, encoding: .utf8)
        changed()
    }
}

/// One line of the transcript. Right-click (or the pencil) to fix what was heard, give it to another speaker,
/// or delete it.
private struct TranscriptLine: View {
    let time: String
    let speaker: String
    let text: String
    let speakers: [String]
    let editable: Bool
    let rename: (String) -> Void
    let edit: (String) -> Void
    let saidBy: (String) -> Void
    let delete: () -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(time).font(.callout).monospacedDigit().foregroundStyle(.tertiary).frame(width: 44, alignment: .trailing)
            SpeakerName(name: speaker, canRename: speaker != "You" && editable,
                        others: speakers.filter { $0 != speaker && $0 != "You" }, rename: rename)
                .frame(width: 76, alignment: .leading)
            if editing {
                TextField("What was said", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(save)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { if !focused && editing { save() } }
                    .onAppear { focused = true }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
                    .padding(.horizontal, -6).padding(.vertical, -3)
            } else {
                Text(text).frame(maxWidth: .infinity, alignment: .leading)
                if editable {
                    Button { start() } label: { Image(systemName: "pencil").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help("Edit this line")
                        .opacity(hover ? 1 : 0)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            if editable {
                Button("Edit Line") { start() }
                Menu("Said By") {
                    ForEach(speakers.filter { $0 != speaker }, id: \.self) { s in Button(s) { saidBy(s) } }
                }
                .disabled(speakers.count < 2)
                Divider()
                Button("Delete Line", role: .destructive, action: delete)
            }
        }
    }

    private func start() {
        draft = text
        editing = true
    }

    private func save() {
        editing = false
        if draft != text { edit(draft) }
    }
}

/// A speaker's name in the transcript. Click a voice from the other side to put a real name on it, or to say
/// it's the same person as another voice (the call split one person in two).
private struct SpeakerName: View {
    let name: String
    let canRename: Bool
    var others: [String] = []
    let rename: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var hover = false

    var body: some View {
        let text = Text(name).font(.callout.weight(.semibold)).foregroundStyle(name == "You" ? .primary : .secondary)
            .lineLimit(1).truncationMode(.tail)
        if canRename {
            Button { draft = name.hasPrefix("Person ") || name == "Them" ? "" : name; editing = true } label: {
                text.underline(hover, color: .secondary)
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("Rename \(name)")
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Who is \(name)?").font(.headline)
                    TextField("Name", text: $draft, prompt: Text("Name"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit(save)
                    Text("Changes it everywhere in this meeting.").font(.caption).foregroundStyle(.secondary)
                    if !others.isEmpty {
                        Divider()
                        Text("Or the same person as").font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(others, id: \.self) { other in
                                Button(other) { editing = false; rename(other) }.buttonStyle(.link)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { editing = false }
                        Button("Rename", action: save).keyboardShortcut(.defaultAction)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(14)
            }
        } else {
            text
        }
    }

    private func save() {
        editing = false
        rename(draft)
    }
}
