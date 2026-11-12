import Foundation

/// Everything the Home screen and menu bar show, computed in one pass over the history.
struct Stats {
    struct Day: Identifiable { let day: Date; let words: Int; var id: Date { day } }
    struct Slot: Identifiable { let start: Date; let words: Int; var id: Date { start } }
    struct App: Identifiable { let name: String; let bundleID: String?; let words: Int; var id: String { name } }

    var totalWords = 0
    var totalDictations = 0
    var todayWords = 0
    var todayDictations = 0
    var speakingWPM = 0
    var typingWPM = 40
    var secondsSaved: Double = 0
    var streakDays = 0
    var streakStart: Date?
    var medianLatencyMs = 0
    var perDay: [Day] = []
    /// Today in 20-minute slots, from the start of the day's range to its end.
    var today: [Slot] = []
    var todayRange: ClosedRange<Date>
    var topApps: [App] = []

    var fasterThanTyping: Double { typingWPM > 0 ? Double(speakingWPM) / Double(typingWPM) : 0 }

    static let slotMinutes = 20

    init(items: [Dictation], typingWPM: Int, days: Int = 14, now: Date = .now) {
        self.typingWPM = typingWPM
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var byDay: [Date: Int] = [:]
        var byApp: [String: (String?, Int)] = [:]
        var bySlot: [Int: Int] = [:]
        var spokenWords = 0
        var spokenSeconds = 0.0
        var latencies: [Int] = []

        for d in items {
            totalWords += d.words
            totalDictations += 1
            let day = cal.startOfDay(for: d.date)
            byDay[day, default: 0] += d.words
            let app = d.appName ?? "Other"
            byApp[app] = (d.appBundleID ?? byApp[app]?.0, (byApp[app]?.1 ?? 0) + d.words)
            if day == today {
                todayDictations += 1
                let minute = Int(d.date.timeIntervalSince(today) / 60)
                bySlot[minute / Self.slotMinutes, default: 0] += d.words
            }
            if d.audioSeconds >= 1.5 {
                spokenWords += d.words
                spokenSeconds += d.audioSeconds
            }
            let typingSeconds = Double(d.words) / Double(typingWPM) * 60
            secondsSaved += max(0, typingSeconds - d.audioSeconds - Double(d.latencyMs) / 1000)
            if latencies.count < 50 { latencies.append(d.latencyMs) } // items come newest first
        }

        todayWords = byDay[today] ?? 0
        speakingWPM = spokenSeconds > 0 ? Int((Double(spokenWords) / spokenSeconds * 60).rounded()) : 0
        if !latencies.isEmpty { medianLatencyMs = latencies.sorted()[latencies.count / 2] }

        // Streak: consecutive days with a dictation, ending today (or yesterday if today is still empty).
        var cursor = byDay[today] != nil ? today : cal.date(byAdding: .day, value: -1, to: today)!
        while byDay[cursor] != nil {
            streakDays += 1
            streakStart = cursor
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }

        perDay = (0..<days).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            return Day(day: day, words: byDay[day] ?? 0)
        }
        topApps = byApp.sorted { $0.value.1 > $1.value.1 }.prefix(5).map { App(name: $0.key, bundleID: $0.value.0, words: $0.value.1) }

        // The day strip runs 08:00–24:00, stretched earlier if you were up before eight.
        let slotsPerHour = 60 / Self.slotMinutes
        let firstSlot = min(8 * slotsPerHour, bySlot.keys.min() ?? Int.max)
        let lastSlot = 24 * slotsPerHour - 1
        self.today = (firstSlot...lastSlot).map { s in
            Slot(start: today.addingTimeInterval(TimeInterval(s * Self.slotMinutes * 60)), words: bySlot[s] ?? 0)
        }
        todayRange = today.addingTimeInterval(TimeInterval(firstSlot * Self.slotMinutes * 60))...cal.date(byAdding: .day, value: 1, to: today)!
    }

    /// The next round number of total words to aim for.
    var nextMilestone: Int {
        let steps = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_500_000, 5_000_000]
        return steps.first { $0 > totalWords } ?? (totalWords / 1_000_000 + 1) * 1_000_000
    }
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func number(_ n: Int) -> String { n.formatted(.number) }

    static func seconds(_ ms: Int) -> String {
        (Double(ms) / 1000).formatted(.number.precision(.fractionLength(1))) + " s"
    }

    static func languageName(_ code: String?) -> String {
        switch code {
        case "en": "English"
        case "it": "Italian"
        case nil: "Unknown"
        case let c?: Locale.current.localizedString(forLanguageCode: c) ?? c.uppercased()
        }
    }
}
