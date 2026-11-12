import AppKit
import SwiftUI

/// A quiet grouped surface for content (glass is reserved for controls and floating chrome).
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

extension View {
    /// One rounded tile. Rows of these sit side by side with a gap, rather than one panel cut up by lines.
    func tile() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.fill.quinary, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

struct SectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

/// The real icon of the app a dictation went into.
struct AppIconView: View {
    let bundleID: String?
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: AppIconCache.icon(for: bundleID))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage {
        let key = bundleID ?? ""
        if let hit = cache[key] { return hit }
        let image: NSImage
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .application)
        }
        cache[key] = image
        return image
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.fill.tertiary, in: .capsule)
    }
}

extension Date {
    var shortTime: String { formatted(date: .omitted, time: .shortened) }
}

extension Font {
    /// Big page titles. Serif (Apple's New York) to set them apart from the UI text; `-sansTitles YES` switches back.
    static var pageTitle: Font {
        UserDefaults.standard.bool(forKey: "sansTitles")
            ? .system(size: 30, weight: .semibold)
            : .system(size: 32, weight: .medium, design: .serif)
    }
}
