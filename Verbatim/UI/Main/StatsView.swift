import Charts
import SwiftData
import SwiftUI

/// Every number, all time, plus the fun ones.
struct StatsView: View {
    @Query(sort: \Dictation.date, order: .reverse) private var history: [Dictation]
    @Query private var vocab: [VocabEntry]
    @AppStorage(Prefs.Key.typingWPM) private var typingWPM = 40

    var body: some View {
        let stats = Stats(items: history, typingWPM: max(10, typingWPM))
        // The per-day chart covers the days you've actually used it, from a week up to 30 days.
        let span = history.last.map { min(30, max(7, (Calendar.current.dateComponents([.day], from: $0.date, to: .now).day ?? 0) + 1)) } ?? 7
        let info = Insights(items: history, vocab: vocab, days: span)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(info)
                    .padding(.bottom, 4)
                if history.isEmpty {
                    Text("Your numbers show up here after the first dictation. Double-tap ⌘ in any app and talk.")
                        .foregroundStyle(.secondary)
                } else {
                    Numbers(stats: stats, info: info, recent: Array(history.prefix(20).reversed()))
                    FunFacts(info: info)
                        .padding(.top, 10)
                    PerDayChart(info: info, span: span)
                        .padding(.top, 10)
                    // Hour and weekday patterns mean little until there's about a week of history.
                    if info.daysActive >= 5 {
                        HStack(alignment: .top, spacing: 12) {
                            HourChart(info: info).tile()
                            WeekdayChart(info: info).tile()
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        TopWords(words: info.topWords).tile()
                        VStack(spacing: 12) {
                            Languages(info: info).tile()
                            AllApps(apps: info.apps).tile()
                        }
                        .frame(width: 300)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if DEBUG
        .defaultScrollAnchor(UserDefaults.standard.bool(forKey: "scrollBottom") ? .bottom : .top)
        #endif
        .navigationTitle("Stats")
        .toolbarTitleDisplayMode(.inline)
    }

    private func header(_ info: Insights) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Format.number(info.totalWords)) words")
                .font(.pageTitle)
                .monospacedDigit()
            if let first = info.firstDate {
                Text("Since \(first.formatted(.dateTime.day().month(.wide).year())), in \(Format.number(info.dictations)) dictations. About \(Format.number(info.pages)) pages of text.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Numbers

private struct Numbers: View {
    let stats: Stats
    let info: Insights
    /// Newest last.
    let recent: [Dictation]

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let days = { (n: Int) in (0..<n).reversed().map { cal.date(byAdding: .day, value: -$0, to: today)! } }
        let typedSeconds = info.talkSeconds + stats.secondsSaved

        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Number(title: "Time talking", value: Format.duration(info.talkSeconds), detail: "each day, last 2 weeks") {
                    MiniBars(values: days(14).map { info.dayTalk[$0] ?? 0 })
                }
                Number(title: "Time saved", value: Format.duration(stats.secondsSaved), detail: nil) {
                    CompareBars(rows: [("Typing", typedSeconds, Format.duration(typedSeconds)),
                                       ("Talking", info.talkSeconds, Format.duration(info.talkSeconds))])
                }
                Number(title: "You talk at", value: "\(stats.speakingWPM) wpm", detail: nil) {
                    CompareBars(rows: [("Talking", Double(stats.speakingWPM), "\(stats.speakingWPM) wpm"),
                                       ("Typing", Double(stats.typingWPM), "\(stats.typingWPM) wpm")])
                }
                Number(title: "Per dictation", value: "\(info.averageWords) words", detail: "your last 20") {
                    MiniBars(values: recent.suffix(20).map { Double($0.words) })
                }
            }
            GridRow {
                Number(title: "Days you dictated", value: Format.number(info.daysActive), detail: "last 4 weeks") {
                    DayDots(active: days(28).map { (info.dayWords[$0] ?? 0) > 0 })
                }
                Number(title: "Current streak", value: count(stats.streakDays), detail: nil) {
                    WeekStrip(days: days(7), active: { (info.dayWords[$0] ?? 0) > 0 })
                }
                Number(title: "Longest streak", value: count(info.longestStreak), detail: nil) {
                    CompareBars(rows: [("Best", Double(info.longestStreak), count(info.longestStreak)),
                                       ("Now", Double(stats.streakDays), count(stats.streakDays))])
                }
                Number(title: "Wait to paste", value: Format.seconds(stats.medianLatencyMs), detail: "your last 20") {
                    MiniBars(values: recent.suffix(20).map { Double($0.latencyMs) })
                }
            }
        }
    }

    private func count(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }
}

private struct Number<Visual: View>: View {
    let title: String
    let value: String
    let detail: String?
    @ViewBuilder var visual: Visual

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Spacer(minLength: 12)
            visual.frame(height: 30, alignment: .bottom)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
            }
        }
        .padding(16)
        .tile()
    }
}

/// A small bar per value, the newest darkest.
private struct MiniBars: View {
    let values: [Double]

    var body: some View {
        let top = max(values.max() ?? 0, 0.001)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(values.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i == values.count - 1 ? AnyShapeStyle(.primary) : AnyShapeStyle(values[i] > 0 ? .tertiary : .quaternary))
                    .frame(height: max(2, 30 * values[i] / top))
                    .frame(maxWidth: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Two bars to compare, the first darker.
private struct CompareBars: View {
    let rows: [(label: String, value: Double, text: String)]

    var body: some View {
        let top = max(rows.map(\.value).max() ?? 0, 0.001)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(i == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .frame(width: max(5, geo.size.width * rows[i].value / top))
                    }
                    .frame(height: 5)
                    Text("\(rows[i].label) \(rows[i].text)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).fixedSize()
                }
            }
        }
    }
}

/// Four weeks as two rows of small squares, filled on days you dictated.
private struct DayDots: View {
    let active: [Bool]

    var body: some View {
        let half = active.count / 2
        VStack(alignment: .leading, spacing: 4) {
            ForEach([0, half], id: \.self) { start in
                HStack(spacing: 4) {
                    ForEach(start..<min(start + half, active.count), id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(active[i] ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                            .frame(maxWidth: 13).frame(height: 13)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The last seven days with their initials, filled on days you dictated.
private struct WeekStrip: View {
    let days: [Date]
    let active: (Date) -> Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                VStack(spacing: 3) {
                    Circle()
                        .fill(active(day) ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                        .frame(width: 11, height: 11)
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Fun facts

private struct FunFacts: View {
    let info: Insights
    /// Which book to compare against. A new one each visit, and clicking it shows the next.
    @State private var bookTurn = Int.random(in: 0..<1000)
    /// Starts on a random fact each visit; it wraps around, so any number works.
    @State private var index = Int.random(in: 0..<1000)
    @State private var forward = true
    @State private var hovering = false
    /// How far through the current fact's time on screen, 0 to 1. Shown as the filling bar.
    @State private var progress = 0.0
    private let seconds = 7.0

    private struct Fact: Identifiable {
        let symbol: String
        let value: String
        let detail: String
        var id: String { value + detail }
    }

    var body: some View {
        let facts = makeFacts()
        let i = index % max(facts.count, 1)
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Fun facts")
            VStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .leading) {
                    slide(facts[i], isBook: i == 0)
                        .id(facts[i].id)
                        .transition(.push(from: forward ? .trailing : .leading))
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .clipped()

                HStack(spacing: 12) {
                    arrow("chevron.left") { go(-1, facts.count) }
                    Spacer()
                    // One segment per fact: the past ones full, the current one filling up until it moves on.
                    HStack(spacing: 5) {
                        ForEach(facts.indices, id: \.self) { n in
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.quaternary)
                                    Capsule().fill(.primary)
                                        .frame(width: g.size.width * (n < i ? 1 : n == i ? progress : 0))
                                }
                            }
                            .frame(maxWidth: 44)
                            .frame(height: 3)
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                            .onTapGesture { forward = n > i; progress = 0; withAnimation(.snappy) { index = n } }
                        }
                    }
                    .frame(maxWidth: 420)
                    .help(hovering ? "Paused while the pointer is here" : "Moves on every \(Int(seconds)) seconds")
                    Spacer()
                    arrow("chevron.right") { go(1, facts.count) }
                }
            }
            .padding(20)
            .tile()
            .onHover { hovering = $0 }
            // Moves on by itself every few seconds, but holds still while the pointer is over it.
            .task {
                let tick = 1.0 / 30
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(tick))
                    guard !hovering else { continue }
                    progress += tick / seconds
                    if progress >= 1 { go(1, makeFacts().count) }
                }
            }
        }
    }

    private func go(_ step: Int, _ count: Int) {
        guard count > 0 else { return }
        forward = step > 0
        progress = 0
        withAnimation(.smooth(duration: 0.45)) { index = (index % count + step + count) % count }
    }

    private func slide(_ fact: Fact, isBook: Bool) -> some View {
        HStack(spacing: 18) {
            Image(systemName: fact.symbol)
                .font(.system(size: 22))
                .frame(width: 56, height: 56)
                .background(.fill.tertiary, in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(fact.value)
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit()
                Text(fact.detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if isBook {
                    Text("Click for another book").font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .onTapGesture { if isBook { withAnimation(.snappy) { bookTurn += 1 } } }
    }

    private func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.small)
    }

    private func makeFacts() -> [Fact] {
        var out: [Fact] = []
        let books = info.bookChoices
        let book = books[bookTurn % books.count]
        if info.totalWords < book.words {
            let pct = max(1, Int((Double(info.totalWords) / Double(book.words) * 100).rounded()))
            out.append(Fact(symbol: "book.closed", value: "\(pct)% of \(book.title)", detail: "You've said \(Format.number(info.totalWords)) of its roughly \(Format.number(book.words)) words."))
        } else {
            let times = Double(info.totalWords) / Double(book.words)
            out.append(Fact(symbol: "book.closed", value: "\(times.formatted(.number.precision(.fractionLength(1))))× \(book.title)", detail: "\(Format.number(info.totalWords)) words, all said out loud."))
        }
        if let top = info.topWords.first {
            out.append(Fact(symbol: "quote.opening", value: "“\(top.name)”", detail: "Your most said word, \(Format.number(top.count)) times."))
        }
        if info.fillersRemoved > 0 {
            out.append(Fact(symbol: "scissors", value: "\(Format.number(info.fillersRemoved)) ums and uhs", detail: "Taken out before anything was pasted."))
        }
        if let l = info.longest {
            out.append(Fact(symbol: "text.alignleft", value: "\(Format.number(l.words)) words in one go", detail: "Your longest dictation\(l.app.map { ", in \($0)" } ?? ""), \(day(l.date))."))
        }
        if let b = info.busiestDay {
            out.append(Fact(symbol: "calendar", value: "\(Format.number(b.words)) words in a day", detail: "Your busiest day, \(b.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))."))
        }
        if let f = info.fastestWPM {
            out.append(Fact(symbol: "hare", value: "\(f.words) wpm", detail: "Your fastest dictation, \(day(f.date))."))
        }
        if let late = info.latestNight {
            out.append(Fact(symbol: "moon.stars", value: "Up at \(late.formatted(date: .omitted, time: .shortened))", detail: "Your latest dictation, the night of \(day(late))."))
        } else if let early = info.earliestMorning {
            out.append(Fact(symbol: "sunrise", value: "Up at \(early.formatted(date: .omitted, time: .shortened))", detail: "Your earliest dictation, \(day(early))."))
        }
        if let h = info.favouriteHour {
            out.append(Fact(symbol: "clock", value: "\(String(format: "%02d", h)):00 to \(String(format: "%02d", (h + 1) % 24)):00", detail: "The hour you talk the most."))
        }
        if let fixed = info.mostFixed {
            out.append(Fact(symbol: "character.cursor.ibeam", value: fixed.word, detail: "Heard \(fixed.ways) different ways before you taught it."))
        }
        if info.swears > 0 {
            out.append(Fact(symbol: "exclamationmark.bubble", value: info.swears == 1 ? "1 swear" : "\(Format.number(info.swears)) swears", detail: "Said out loud and pasted as is."))
        }
        return out
    }

    private func day(_ date: Date) -> String { date.formatted(.dateTime.day().month(.wide)) }
}

// MARK: - Charts

private struct PerDayChart: View {
    let info: Insights
    let span: Int

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Words per day", detail: span == 30 ? "last 30 days" : "last \(span) days")
                Chart(info.perDay) { d in
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Words", d.words), width: .ratio(0.62))
                        .foregroundStyle(Calendar.current.isDateInToday(d.day) ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.22)))
                        .clipShape(.rect(cornerRadius: 3))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: span > 10 ? 7 : 1)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(.separator)
                        AxisValueLabel()
                    }
                }
                .frame(height: 140)
            }
        }
    }
}

private struct HourChart: View {
    let info: Insights

    static func label(_ hour: Int) -> String { String(format: "%02d:00", hour) }

    var body: some View {
        let peak = info.favouriteHour
        Pad {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Time of day")
                Chart(info.byHour) { h in
                    BarMark(x: .value("Hour", Self.label(h.hour)), y: .value("Words", h.words), width: .ratio(0.7))
                        .foregroundStyle(h.hour == peak ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.22)))
                        .clipShape(.rect(cornerRadius: 2))
                }
                .chartXAxis {
                    // Every bar gets a mark, but only 00, 06, 12 and 18 get a label.
                    AxisMarks { v in
                        AxisValueLabel(collisionResolution: .disabled) {
                            let s = v.as(String.self) ?? ""
                            Text(["00:00", "06:00", "12:00", "18:00"].contains(s) ? s : "")
                        }
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 110)
            }
        }
    }
}

private struct WeekdayChart: View {
    let info: Insights

    var body: some View {
        let top = info.byWeekday.map(\.words).max() ?? 0
        Pad {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Day of the week")
                Chart(info.byWeekday) { d in
                    BarMark(x: .value("Day", d.name), y: .value("Words", d.words), width: .ratio(0.55))
                        .foregroundStyle(d.words == top && top > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.22)))
                        .clipShape(.rect(cornerRadius: 3))
                }
                .chartXAxis { AxisMarks { _ in AxisValueLabel() } }
                .chartYAxis(.hidden)
                .frame(height: 110)
            }
        }
    }
}

// MARK: - Words, languages, apps

private struct TopWords: View {
    let words: [Insights.Ranked]

    var body: some View {
        Pad {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Most said words", detail: "leaving out the, che and friends")
                let top = Double(words.first?.count ?? 1)
                VStack(spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.element.id) { i, w in
                        HStack(spacing: 10) {
                            Text("\(i + 1)")
                                .font(.callout).foregroundStyle(.tertiary).monospacedDigit()
                                .frame(width: 18, alignment: .trailing)
                            Text(w.name).lineLimit(1).frame(width: 120, alignment: .leading)
                            GeometryReader { geo in
                                Capsule()
                                    .fill(i == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.3)))
                                    .frame(width: max(6, geo.size.width * Double(w.count) / top))
                            }
                            .frame(height: 5)
                            Text(Format.number(w.count))
                                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Languages: View {
    let info: Insights

    var body: some View {
        let total = Double(max(1, info.languages.reduce(0) { $0 + $1.count }))
        Pad {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Languages")
                // One bar split by language, darkest for the one you use most.
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(info.languages.enumerated()), id: \.element.id) { i, l in
                            Rectangle()
                                .fill(.primary.opacity(i == 0 ? 1 : i == 1 ? 0.35 : 0.15))
                                .frame(width: max(3, (geo.size.width - 2 * Double(info.languages.count - 1)) * Double(l.count) / total))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                ForEach(Array(info.languages.enumerated()), id: \.element.id) { i, l in
                    HStack {
                        Circle().fill(.primary.opacity(i == 0 ? 1 : i == 1 ? 0.35 : 0.15)).frame(width: 7, height: 7)
                        Text(l.name)
                        Spacer()
                        Text("\(Int((Double(l.count) / total * 100).rounded()))%")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

private struct AllApps: View {
    let apps: [Stats.App]

    var body: some View {
        Pad {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Apps", detail: apps.count == 1 ? "1 app" : "\(apps.count) apps")
                ForEach(apps.prefix(8)) { app in
                    HStack(spacing: 10) {
                        AppIconView(bundleID: app.bundleID, size: 18)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Text(Format.number(app.words)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Inner spacing for a block that gets its tile from the parent.
private struct Pad<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
}
