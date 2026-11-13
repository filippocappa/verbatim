import SwiftUI

/// Ask a question across every meeting. The answer links to the meetings it came from.
struct MeetingAskView: View {
    let open: (MeetingFile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var asked = ""
    @State private var answer: MeetingAsk.Answer?
    @State private var error: String?
    @State private var job: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var busy: Bool { job != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                TextField("Ask about your meetings, like “what did we decide about pricing?”", text: $question)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(ask)
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if busy {
                        Text("Reading your meetings…").foregroundStyle(.secondary)
                    } else if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else if let answer {
                        Text(asked).font(.headline)
                        Text(styled(answer))
                            .textSelection(.enabled)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if !answer.cited.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("From").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(answer.cited) { m in
                                    Button { open(m) } label: {
                                        HStack(spacing: 6) {
                                            Text(m.title)
                                            Text(m.started.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                            .padding(.top, 6)
                        }
                    } else {
                        Text("Claude reads your meeting notes and transcripts to answer, and links to where it found it. They're sent to Anthropic for this.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(minHeight: 160, maxHeight: 460)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "meeting", let answer, let i = Int(url.absoluteString.dropFirst("meeting:".count)),
                      answer.meetings.indices.contains(i) else { return .systemAction }
                open(answer.meetings[i])
                return .handled
            })

            Divider()
            HStack {
                Spacer()
                Button("Close") { job?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ask", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            .padding(12)
        }
        .frame(width: 600)
        .onAppear { focused = true }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        asked = q
        error = nil
        answer = nil
        job = Task {
            do {
                answer = try await MeetingAsk.answer(q)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            job = nil
        }
    }

    /// Markdown links and bold, with list dashes shown as bullets.
    private func styled(_ answer: MeetingAsk.Answer) -> AttributedString {
        let text = answer.text.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") || t.hasPrefix("* ") ? "•  " + t.dropFirst(2) : line
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
