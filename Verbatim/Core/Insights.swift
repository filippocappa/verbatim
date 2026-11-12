import Foundation

/// Everything on the Stats page, computed in one pass over the whole history.
struct Insights {
    struct Hour: Identifiable { let hour: Int; let words: Int; var id: Int { hour } }
    struct Weekday: Identifiable { let index: Int; let name: String; let words: Int; var id: Int { index } }
    struct Ranked: Identifiable { let name: String; let count: Int; var id: String { name } }
    struct Moment { let date: Date; let words: Int; let app: String? }
    struct Book { let title: String; let words: Int }

    var totalWords = 0
    var dictations = 0
    var talkSeconds = 0.0
    var firstDate: Date?
    var daysActive = 0
    var longestStreak = 0
    var averageWords = 0

    var perDay: [Stats.Day] = []
    /// Words and seconds of talking for every day with a dictation, keyed by start of day.
    var dayWords: [Date: Int] = [:]
    var dayTalk: [Date: Double] = [:]
    var byHour: [Hour] = []
    var byWeekday: [Weekday] = []
    var languages: [Ranked] = []
    var apps: [Stats.App] = []
    var topWords: [Ranked] = []

    // Fun facts. Each is nil or zero when there's nothing worth showing.
    var fillersRemoved = 0
    var swears = 0
    var longest: Moment?
    var busiestDay: Moment?
    var latestNight: Date?
    var earliestMorning: Date?
    var fastestWPM: Moment?
    var favouriteHour: Int?
    var mostFixed: (word: String, ways: Int)?

    init(items: [Dictation], vocab: [VocabEntry], days: Int = 30, now: Date = .now) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var byDay: [Date: Int] = [:]
        var hours = [Int](repeating: 0, count: 24)
        var weekdays = [Int](repeating: 0, count: 8) // Calendar weekdays are 1...7
        var langs: [String: Int] = [:]
        var appWords: [String: (String?, Int)] = [:]
        var wordCounts: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]
        var latestScore = -1, earliestScore = Int.max

        for d in items {
            totalWords += d.words
            dictations += 1
            talkSeconds += d.audioSeconds
            if firstDate == nil || d.date < firstDate! { firstDate = d.date }

            let day = cal.startOfDay(for: d.date)
            byDay[day, default: 0] += d.words
            dayTalk[day, default: 0] += d.audioSeconds
            let hour = cal.component(.hour, from: d.date), minute = cal.component(.minute, from: d.date)
            hours[hour] += d.words
            weekdays[cal.component(.weekday, from: d.date)] += d.words
            langs[Format.languageName(d.language), default: 0] += d.words
            let app = d.appName ?? "Other"
            appWords[app] = (d.appBundleID ?? appWords[app]?.0, (appWords[app]?.1 ?? 0) + d.words)

            if d.words > (longest?.words ?? 0) { longest = Moment(date: d.date, words: d.words, app: d.appName) }
            // Short clips give silly speeds, so only count real sentences.
            if d.audioSeconds >= 4, d.words >= 8 {
                let wpm = Int(Double(d.words) / d.audioSeconds * 60)
                if wpm > (fastestWPM?.words ?? 0), wpm < 320 { fastestWPM = Moment(date: d.date, words: wpm, app: d.appName) }
            }
            // Night: 22:00 to 04:59 counts as late, with after-midnight later than before.
            let clock = hour * 60 + minute
            if hour >= 22 || hour < 5 {
                let score = hour < 5 ? clock + 24 * 60 : clock
                if score > latestScore { latestScore = score; latestNight = d.date }
            } else if hour < 8, clock < earliestScore {
                earliestScore = clock; earliestMorning = d.date
            }

            for token in Self.tokens(d.text) {
                let key = token.lowercased()
                if Self.swearWords.contains(where: { key.hasPrefix($0) }) { swears += 1 }
                guard key.count >= 3, !Self.stopWords.contains(key), key.contains(where: \.isLetter) else { continue }
                wordCounts[key, default: 0] += 1
                spellings[key, default: [:]][token, default: 0] += 1
            }
            let heardFillers = Self.tokens(d.raw).filter { Self.fillers.contains($0.lowercased()) }.count
            let keptFillers = Self.tokens(d.text).filter { Self.fillers.contains($0.lowercased()) }.count
            fillersRemoved += max(0, heardFillers - keptFillers)
        }

        averageWords = dictations > 0 ? totalWords / dictations : 0
        daysActive = byDay.count
        dayWords = byDay

        // Longest run of consecutive days with at least one dictation.
        var run = 0, previous: Date?
        for day in byDay.keys.sorted() {
            if let previous, cal.date(byAdding: .day, value: 1, to: previous) == day { run += 1 } else { run = 1 }
            longestStreak = max(longestStreak, run)
            previous = day
        }
        if let best = byDay.max(by: { $0.value < $1.value }) { busiestDay = Moment(date: best.key, words: best.value, app: nil) }

        perDay = (0..<days).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            return Stats.Day(day: day, words: byDay[day] ?? 0)
        }
        byHour = hours.enumerated().map { Hour(hour: $0.offset, words: $0.element) }
        favouriteHour = hours.max().flatMap { $0 > 0 ? hours.firstIndex(of: $0) : nil }

        // Weekdays in the order the user's calendar starts the week.
        let symbols = cal.shortWeekdaySymbols
        byWeekday = (0..<7).map { i in
            let index = (cal.firstWeekday - 1 + i) % 7 + 1
            return Weekday(index: index, name: symbols[index - 1], words: weekdays[index])
        }

        // A language under 1% is almost always one misheard clip (Korean, on a silent recording).
        languages = langs.filter { $0.value * 100 >= totalWords }
            .sorted { $0.value > $1.value }.map { Ranked(name: $0.key, count: $0.value) }
        apps = appWords.sorted { $0.value.1 > $1.value.1 }.map { Stats.App(name: $0.key, bundleID: $0.value.0, words: $0.value.1) }
        topWords = wordCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(10)
            .map { key, count in
                // Show the spelling used most often (Supabase, not supabase).
                let shown = spellings[key]?.max(by: { $0.value < $1.value })?.key ?? key
                return Ranked(name: shown, count: count)
            }

        if let entry = vocab.max(by: { $0.heardAs.count < $1.heardAs.count }), entry.heardAs.count >= 2 {
            mostFixed = (entry.word, entry.heardAs.count)
        }
    }

    /// Books worth comparing against right now: ones you're at least 1% of the way through,
    /// plus the biggest one you've already out-talked.
    var bookChoices: [Book] {
        let reading = Self.books.filter { $0.words > totalWords && totalWords * 100 >= $0.words }
        let done = Self.books.last { $0.words <= totalWords }
        let all = (done.map { [$0] } ?? []) + reading
        return all.isEmpty ? [Self.books[0]] : all
    }

    var pages: Int { totalWords / 250 }

    // MARK: - Word lists

    static func tokens(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "'" || $0 == "’") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }

    /// Rounded word counts, so the page doesn't claim more precision than the sources have.
    static let books = [
        Book(title: "The Little Prince", words: 17_000),
        Book(title: "The Old Man and the Sea", words: 27_000),
        Book(title: "Of Mice and Men", words: 30_000),
        Book(title: "Animal Farm", words: 30_000),
        Book(title: "Fahrenheit 451", words: 46_000),
        Book(title: "The Great Gatsby", words: 47_000),
        Book(title: "The Catcher in the Rye", words: 73_000),
        Book(title: "Harry Potter and the Philosopher's Stone", words: 77_000),
        Book(title: "1984", words: 89_000),
        Book(title: "The Hobbit", words: 95_000),
        Book(title: "To Kill a Mockingbird", words: 100_000),
        Book(title: "Pride and Prejudice", words: 122_000),
        Book(title: "Moby-Dick", words: 206_000),
        Book(title: "The Lord of the Rings", words: 481_000),
        Book(title: "War and Peace", words: 587_000),
    ]

    static let fillers: Set<String> = ["um", "umm", "uh", "uhm", "uhh", "erm", "ehm", "eh", "ehh", "hmm", "mmm", "mm"]

    static let swearWords = ["fuck", "shit", "damn", "bullshit", "cazz", "merd", "vaffanculo", "minchia", "stronz", "porca", "porco"]

    nonisolated static let stopWords: Set<String> = [
        // English
        "the", "and", "for", "but", "not", "you", "your", "yours", "are", "was", "were", "been", "being", "have", "has", "had",
        "this", "that", "these", "those", "with", "from", "into", "onto", "about", "over", "under", "then", "than", "there",
        "here", "what", "when", "where", "which", "who", "whom", "why", "how", "all", "any", "some", "each", "can", "could",
        "would", "should", "will", "shall", "may", "might", "must", "just", "like", "also", "very", "really", "get", "got",
        "going", "want", "make", "one", "two", "let", "let's", "it's", "i'm", "don't", "doesn't", "didn't", "that's", "we're",
        "you're", "they're", "i'll", "it'll", "i've", "can't", "won't", "isn't", "aren't", "there's", "what's", "okay", "yeah",
        "yes", "they", "them", "their", "our", "ours", "his", "her", "hers", "its", "she", "him", "out", "now", "too", "more",
        "most", "much", "many", "only", "own", "same", "such", "both", "few", "other", "again", "still", "does", "did", "doing",
        "done", "say", "said", "see", "way", "thing", "things", "something", "maybe", "know", "think", "need", "use", "put",
        "after", "before", "because", "while", "off", "every", "even", "well", "back", "into", "whole", "actually",
        // Italian
        "che", "non", "per", "con", "una", "uno", "del", "della", "dei", "delle", "dello", "degli", "alla", "alle", "allo",
        "agli", "nel", "nella", "nei", "nelle", "sul", "sulla", "sui", "sono", "sei", "siamo", "siete", "era", "erano", "come",
        "anche", "più", "piu", "questo", "questa", "questi", "queste", "quello", "quella", "quelli", "cosa", "cose", "poi",
        "già", "gia", "hai", "abbiamo", "avete", "hanno", "essere", "fare", "fatto", "molto", "tutto", "tutti", "tutta",
        "io", "lui", "lei", "noi", "voi", "loro", "mio", "mia", "tuo", "tua", "suo", "sua", "dove", "quando", "perché",
        "perche", "però", "pero", "quindi", "cioè", "cioe", "allora", "bene", "c'è", "dell", "nell", "all", "sull", "dall",
        "dai", "dal", "dalla", "tra", "fra", "solo", "ancora", "ogni", "qui", "qua", "così", "cosi", "mi", "ti", "ci",
        "vi", "si", "ne", "gli", "le", "lo", "la", "il", "un", "di", "da", "in", "su", "ma", "se", "ho", "ha", "va",
    ]
}
