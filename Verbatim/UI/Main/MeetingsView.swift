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
        // From start to the file's last write (the recap, just after the call ends).
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? started
        let minutes = Int(modified.timeIntervalSince(started) / 60)
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
    private var controller: MeetingController { .shared }

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
                    Text("When a call starts in Zoom, Meet, Teams or another call app, \(AppInfo.name) offers to take notes. Each meeting gets a recap and a transcript here.")
                } actions: {
                    Button("Take Notes Now") { controller.start() }.buttonStyle(.glass)
                }
            } else {
                HStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(sections, id: \.day) { section in
                            Section(header(section.day)) {
                                ForEach(section.items) { m in
                                    MeetingRow(meeting: m, live: isLive(m)).tag(m.url)
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
                        MeetingDetail(meeting: m, live: isLive(m)) { reload() }
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
    }

    private func isLive(_ m: MeetingFile) -> Bool { controller.isRecording && controller.lastFile == m.url }

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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let service = meeting.service, let logo = ServiceLogos.shared.image(service) {
                    Image(nsImage: logo).resizable().frame(width: 20, height: 20).clipShape(.rect(cornerRadius: 5))
                } else {
                    AppIconView(bundleID: meeting.bundleID, size: 20)
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).lineLimit(1)
                HStack(spacing: 5) {
                    if live {
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
    let changed: () -> Void

    private enum Block: Hashable {
        case section(String), heading(String), bullet(String), task(String, done: Bool, line: Int)
        case line(time: String, them: Bool, text: String), note(String), text(String)
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
                let head = l[l.index(l.startIndex, offsetBy: 2)..<end.lowerBound].split(separator: " ")
                out.append(.line(time: head.first.map(String.init) ?? "", them: head.last == "Them",
                                 text: String(l[end.upperBound...]).trimmingCharacters(in: .whitespaces)))
            }
            else if l.hasPrefix("_") && l.hasSuffix("_") { out.append(.note(String(l.dropFirst().dropLast()))) }
            else if out.isEmpty { continue } // the date line, shown in the header
            else { out.append(.text(l)) }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.title).font(.pageTitle)
                    HStack(spacing: 6) {
                        if live {
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
                    Button("Copy Notes") { Paster.copy(meeting.text.replacingOccurrences(of: #"<!--.*-->\n\n"#, with: "", options: .regularExpression)) }
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
        case let .line(time, them, text):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(time).font(.callout).monospacedDigit().foregroundStyle(.tertiary).frame(width: 44, alignment: .trailing)
                Text(them ? "Them" : "You").font(.callout.weight(.semibold)).foregroundStyle(them ? .secondary : .primary)
                    .frame(width: 40, alignment: .leading)
                Text(text)
            }
            .padding(.vertical, 5)
        case let .note(t):
            Text(t).foregroundStyle(.secondary).italic().padding(.vertical, 2)
        case let .text(t):
            Text(inline(t)).padding(.vertical, 2)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
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
