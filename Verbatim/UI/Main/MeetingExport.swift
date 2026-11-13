import AppKit
import UniformTypeIdentifiers

/// Saves a meeting as Markdown, plain text or PDF, wherever the user picks.
@MainActor
enum MeetingExport {
    enum Format: String, CaseIterable {
        case markdown = "Markdown", text = "Plain Text", pdf = "PDF"
        var type: UTType {
            switch self {
            case .markdown: UTType(filenameExtension: "md") ?? .plainText
            case .text: .plainText
            case .pdf: .pdf
            }
        }
    }

    static func save(_ meeting: MeetingFile, as format: Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = safeName(meeting.title)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try write(meeting, as: format, to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    static func write(_ meeting: MeetingFile, as format: Format, to url: URL) throws {
        switch format {
        case .markdown: try markdown(meeting).write(to: url, atomically: true, encoding: .utf8)
        case .text: try plain(meeting).write(to: url, atomically: true, encoding: .utf8)
        case .pdf: try pdf(meeting, to: url)
        }
    }

    /// The notes file without the hidden line Verbatim keeps for itself.
    static func markdown(_ meeting: MeetingFile) -> String {
        meeting.text.replacingOccurrences(of: #"<!--.*-->\n\n"#, with: "", options: .regularExpression)
    }

    static func plain(_ meeting: MeetingFile) -> String {
        markdown(meeting).components(separatedBy: "\n").map { raw -> String in
            var l = raw
            for h in ["### ", "## ", "# "] where l.hasPrefix(h) { l = String(l.dropFirst(h.count)); break }
            if l.hasPrefix("- [ ] ") { l = "[ ] " + l.dropFirst(6) }
            if l.lowercased().hasPrefix("- [x] ") { l = "[x] " + l.dropFirst(6) }
            l = l.replacingOccurrences(of: "**", with: "")
            if l.count > 1, l.hasPrefix("_"), l.hasSuffix("_") { l = String(l.dropFirst().dropLast()) }
            return l
        }.joined(separator: "\n")
    }

    // MARK: PDF

    private static func pdf(_ meeting: MeetingFile, to url: URL) throws {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842) // A4
        info.topMargin = 56; info.bottomMargin = 56; info.leftMargin = 56; info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.textStorage?.setAttributedString(styled(meeting))
        view.isVerticallyResizable = true
        view.sizeToFit()
        let op = NSPrintOperation.pdfOperation(with: view, inside: view.bounds, toPath: url.path, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func styled(_ meeting: MeetingFile) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11)
        let bold = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let grey = NSColor(white: 0.45, alpha: 1)
        func para(before: CGFloat = 0, after: CGFloat = 4, indent: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.lineSpacing = 2
            p.headIndent = indent
            return p
        }
        func add(_ s: String, _ font: NSFont, color: NSColor = .black, style: NSParagraphStyle) {
            out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        /// **bold** inside a line, the way the recap writes names and labels.
        func inline(_ s: String, style: NSParagraphStyle) {
            for (i, part) in s.components(separatedBy: "**").enumerated() {
                add(part, i % 2 == 1 ? bold : body, style: style)
            }
        }

        for raw in markdown(meeting).components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if l.hasPrefix("# ") {
                add(String(l.dropFirst(2)) + "\n", .systemFont(ofSize: 20, weight: .bold), style: para(after: 2))
            } else if l.hasPrefix("## ") {
                add(String(l.dropFirst(3)) + "\n", .systemFont(ofSize: 14, weight: .semibold), style: para(before: 16, after: 6))
            } else if l.hasPrefix("### ") {
                add(String(l.dropFirst(4)) + "\n", bold, color: grey, style: para(before: 8, after: 3))
            } else if l.hasPrefix("- [ ] ") || l.lowercased().hasPrefix("- [x] ") {
                let done = !l.hasPrefix("- [ ] ")
                inline((done ? "☑︎  " : "☐  ") + l.dropFirst(6) + "\n", style: para(indent: 16))
            } else if l.hasPrefix("- ") || l.hasPrefix("* ") {
                inline("•  " + l.dropFirst(2) + "\n", style: para(indent: 12))
            } else if l.hasPrefix("**"), let end = l.range(of: ":**") {
                // "**12:04 Sara:** text" → time in grey, name in bold.
                let head = l[l.index(l.startIndex, offsetBy: 2)..<end.lowerBound].split(separator: " ", maxSplits: 1)
                let style = para(after: 5, indent: 0)
                add((head.first.map(String.init) ?? "") + "   ", .monospacedDigitSystemFont(ofSize: 10, weight: .regular), color: grey, style: style)
                add((head.count > 1 ? String(head[1]) : "Them") + "  ", bold, style: style)
                add(l[end.upperBound...].trimmingCharacters(in: .whitespaces) + "\n", body, style: style)
            } else if l.count > 1, l.hasPrefix("_"), l.hasSuffix("_") {
                add(String(l.dropFirst().dropLast()) + "\n", .systemFont(ofSize: 11).italic, color: grey, style: para())
            } else {
                inline(l + "\n", style: para(after: out.length < 200 ? 2 : 4))
            }
        }
        return out
    }

    private static func safeName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return cleaned.isEmpty ? "Meeting" : cleaned
    }
}

private extension NSFont {
    var italic: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask) }
}
