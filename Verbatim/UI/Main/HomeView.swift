import Charts
import SwiftData
import SwiftUI

struct HomeView: View {
    @Query(sort: \Dictation.date, order: .reverse) private var history: [Dictation]
    @Query(filter: #Predicate<VocabEntry> { $0.learned }, sort: \VocabEntry.added, order: .reverse)
    private var learned: [VocabEntry]
    @AppStorage(Prefs.Key.typingWPM) private var typingWPM = 40

    var body: some View {
        let stats = Stats(items: history, typingWPM: max(10, typingWPM))

        // One page, no scrolling: the charts row and the recent list share whatever height the window has.
        // GeometryReader measures the area below the toolbar; without it the page runs under the bottom edge.
        GeometryReader { geo in
        VStack(alignment: .leading, spacing: 16) {
            header(stats)
            if history.isEmpty {
                EmptyHome()
                Spacer(minLength: 0)
            } else {
                StatRow(stats: stats)
                HStack(alignment: .top, spacing: 16) {
                    WordsPerDay(stats: stats)
                    WhereYouTalk(stats: stats)
                }
                .frame(minHeight: 170, maxHeight: 280)
                HStack(alignment: .top, spacing: 16) {
                    RecentList(items: Array(history.prefix(12)))
                    LearnedPanel(words: learned.prefix(12).map(\.word))
                        .frame(width: 300)
                }
                .frame(minHeight: 160, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inline)
    }

    private func header(_ stats: Stats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Format.number(stats.todayWords)) words today")
                .font(.pageTitle)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(subtitle(stats))
                .foregroundStyle(.secondary)
        }
    }

    private func subtitle(_ stats: Stats) -> String {
        guard stats.todayDictations > 0 else { return "Double-tap ⌘ anywhere and start talking." }
        let saved = stats.todayWords > 0
            ? Format.duration(Double(stats.todayWords) / Double(stats.typingWPM) * 60)
            : "0m"
        return "\(stats.todayDictations) dictations, about \(saved) of typing."
    }
}

// MARK: - Today

private struct StatRow: View {
    let stats: Stats

    var body: some View {
        HStack(spacing: 12) {
            StatCell(title: "Words dictated", value: Format.number(stats.totalWords),
                     detail: "in \(Format.number(stats.totalDictations)) dictations")
                .tile()
            StatCell(title: "Faster than typing",
                     value: stats.fasterThanTyping > 0 ? stats.fasterThanTyping.formatted(.number.precision(.fractionLength(1))) + "×" : "–",
                     detail: nil) {
                SpeedBars(speaking: stats.speakingWPM, typing: stats.typingWPM)
            }
            .tile()
            StatCell(title: "Time saved", value: Format.duration(stats.secondsSaved),
                     detail: "against typing at \(stats.typingWPM) wpm")
                .tile()
            StatCell(title: "Streak", value: stats.streakDays == 1 ? "1 day" : "\(stats.streakDays) days",
                     detail: stats.streakStart.map { "since \($0.formatted(.dateTime.month(.abbreviated).day()))" })
                .tile()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct StatCell<Extra: View>: View {
    let title: String
    let value: String
    let detail: String?
    @ViewBuilder var extra: Extra

    init(title: String, value: String, detail: String?, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.title = title
        self.value = value
        self.detail = detail
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            extra
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }
}

private struct SpeedBars: View {
    let speaking: Int
    let typing: Int

    var body: some View {
        let top = Double(max(speaking, typing, 1))
        VStack(alignment: .leading, spacing: 4) {
            bar("Talking", speaking, top, .primary)
            bar("Typing", typing, top, .tertiary)
        }
    }

    private func bar(_ label: String, _ value: Int, _ top: Double, _ style: some ShapeStyle) -> some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                Capsule().fill(style).frame(width: max(4, geo.size.width * Double(value) / top))
            }
            .frame(height: 5)
            Text("\(value) wpm")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Charts

private struct WordsPerDay: View {
    let stats: Stats

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Words per day", detail: "last 14 days")
                Chart(stats.perDay) { d in
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Words", d.words), width: .ratio(0.62))
                        .foregroundStyle(Calendar.current.isDateInToday(d.day) ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.22)))
                        .clipShape(.rect(cornerRadius: 3))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(.separator)
                        AxisValueLabel()
                    }
                }
                .frame(minHeight: 80, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct WhereYouTalk: View {
    let stats: Stats

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Where you talk")
                let top = Double(stats.topApps.first?.words ?? 1)
                VStack(spacing: 11) {
                    ForEach(stats.topApps.prefix(5)) { app in
                        HStack(spacing: 10) {
                            AppIconView(bundleID: app.bundleID, size: 18)
                            Text(app.name).frame(width: 84, alignment: .leading).lineLimit(1)
                            GeometryReader { geo in
                                Capsule()
                                    .fill(app.id == stats.topApps.first?.id ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.3)))
                                    .frame(width: max(6, geo.size.width * Double(app.words) / top))
                            }
                            .frame(height: 6)
                            Text(Format.number(app.words))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 54, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Recent and learned

private struct RecentList: View {
    let items: [Dictation]

    var body: some View {
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title: "Recent").padding(16)
                // Only whole rows: as many as the window has room for.
                GeometryReader { geo in
                    let shown = Array(items.prefix(max(1, Int((geo.size.height - 6) / 39))))
                    VStack(spacing: 0) {
                        ForEach(shown) { d in
                            RecentRow(item: d)
                            if d.id != shown.last?.id { Divider().padding(.leading, 46) }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct RecentRow: View {
    let item: Dictation
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(bundleID: item.appBundleID, size: 20)
            Text(item.text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if hover {
                Button(copied ? "Copied" : "Copy") {
                    Paster.copy(item.text)
                    copied = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            } else {
                Text(item.date.shortTime).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .contentShape(.rect)
        .onHover { hover = $0; if !$0 { copied = false } }
        .contextMenu {
            Button("Copy") { Paster.copy(item.text) }
        }
    }
}

private struct LearnedPanel: View {
    let words: [String]

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Learned from your fixes")
                if words.isEmpty {
                    Text("Fix a word after it's pasted and it'll be spelled right next time.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(words, id: \.self) { Chip(text: $0) }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
        }
    }
}

private struct EmptyHome: View {
    var body: some View {
        Panel(padding: 28) {
            VStack(alignment: .leading, spacing: 10) {
                KeyCaps(keys: ["⌘", "⌘"])
                Text("Double-tap Command in any app, talk, then tap ⌘ once more.")
                    .font(.title3)
                Text("Your words land where the cursor is. Stats and history show up here after the first one.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
