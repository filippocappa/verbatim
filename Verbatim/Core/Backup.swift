import Foundation
import SwiftData
import os

/// One zip with what you'd miss on a new Mac: meetings, history, Dictionary, snippets, and settings (styles,
/// commands, sites). API keys stay in the Keychain and aren't in it.
///
/// Restoring adds what's missing and never deletes: meetings and dictations already here stay, so restoring
/// an old backup on top of newer work is safe. Settings come back as they were in the backup.
@MainActor
enum Backup {
    struct Counts {
        var meetings = 0, dictations = 0, words = 0, snippets = 0
        var text: String {
            "\(meetings) meetings, \(dictations) dictations, \(words) Dictionary words, \(snippets) snippets"
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let log = Logger(subsystem: AppInfo.bundleID, category: "backup")
    private static let folderName = "\(AppInfo.name) Backup"
    /// Belong to this Mac, not to you.
    private static let machineKeys: Set<String> = [Prefs.Key.microphone, Prefs.Key.didOnboard, Prefs.Key.paused]

    static var suggestedName: String {
        "\(AppInfo.name) Backup \(Date.now.formatted(.iso8601.year().month().day())).zip"
    }

    // MARK: Back up

    @discardableResult
    static func make(to zip: URL) throws -> Counts {
        try? Store.context.save()
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "verbatim-backup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let root = work.appending(path: folderName)
        let meetings = root.appending(path: "Meetings")
        try fm.createDirectory(at: meetings, withIntermediateDirectories: true)

        var counts = Counts()
        for url in (try? fm.contentsOfDirectory(at: MeetingNotes.folder, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "md" {
            try fm.copyItem(at: url, to: meetings.appending(path: url.lastPathComponent))
            counts.meetings += 1
        }

        // A consistent copy of the open database, write-ahead log included.
        let library = root.appending(path: "Library.store")
        try run("/usr/bin/sqlite3", [Store.url.path, ".backup '\(library.path)'"])
        counts.dictations = (try? Store.context.fetchCount(FetchDescriptor<Dictation>())) ?? 0
        counts.words = (try? Store.context.fetchCount(FetchDescriptor<VocabEntry>())) ?? 0
        counts.snippets = (try? Store.context.fetchCount(FetchDescriptor<Snippet>())) ?? 0

        let settings = UserDefaults.standard.persistentDomain(forName: AppInfo.bundleID) ?? [:]
        try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
            .write(to: root.appending(path: "Settings.plist"))

        try? fm.removeItem(at: zip)
        try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", root.path, zip.path])
        log.notice("backup: \(counts.text, privacy: .public)")
        return counts
    }

    // MARK: Restore

    /// What was added.
    @discardableResult
    static func restore(from zip: URL) throws -> Counts {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "verbatim-restore-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        // The folder inside, whatever the zip was renamed to.
        let root = [work.appending(path: folderName), work]
            .first { fm.fileExists(atPath: $0.appending(path: "Library.store").path) }
        guard let root else { throw Failure(message: "This isn't a \(AppInfo.name) backup.") }

        var added = Counts()
        let meetings = root.appending(path: "Meetings")
        try? fm.createDirectory(at: MeetingNotes.folder, withIntermediateDirectories: true)
        for url in (try? fm.contentsOfDirectory(at: meetings, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "md" {
            let target = MeetingNotes.folder.appending(path: url.lastPathComponent)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try fm.copyItem(at: url, to: target)
            added.meetings += 1
        }

        try merge(library: root.appending(path: "Library.store"), into: &added)

        if let data = try? Data(contentsOf: root.appending(path: "Settings.plist")),
           let settings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in settings where !machineKeys.contains(key) && !key.hasPrefix("NS") && !key.hasPrefix("groq") {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        log.notice("restore added: \(added.text, privacy: .public)")
        return added
    }

    private static func merge(library url: URL, into added: inout Counts) throws {
        // A copy in a temporary folder, so it can be opened like any library (read-only fails on its log file).
        let config = ModelConfiguration("Backup", url: url)
        let other = try ModelContainer(for: Dictation.self, VocabEntry.self, Snippet.self, configurations: config)
        let from = ModelContext(other)
        let here = Store.context

        func key(_ d: Dictation) -> String { "\(Int(d.date.timeIntervalSince1970))|\(d.text)" }
        let have = Set(((try? here.fetch(FetchDescriptor<Dictation>())) ?? []).map(key))
        for d in try from.fetch(FetchDescriptor<Dictation>()) where !have.contains(key(d)) {
            here.insert(Dictation(date: d.date, text: d.text, raw: d.raw, audioSeconds: d.audioSeconds, latencyMs: d.latencyMs,
                                  appName: d.appName, appBundleID: d.appBundleID, engine: d.engine, language: d.language))
            added.dictations += 1
        }

        let words = Set(((try? here.fetch(FetchDescriptor<VocabEntry>())) ?? []).map { $0.word.lowercased() })
        for w in try from.fetch(FetchDescriptor<VocabEntry>()) where !words.contains(w.word.lowercased()) {
            here.insert(VocabEntry(word: w.word, heardAs: w.heardAs, learned: w.learned, alwaysReplace: w.alwaysReplace, added: w.added))
            added.words += 1
        }

        let triggers = Set(((try? here.fetch(FetchDescriptor<Snippet>())) ?? []).map { $0.trigger.lowercased() })
        for s in try from.fetch(FetchDescriptor<Snippet>()) where !triggers.contains(s.trigger.lowercased()) {
            let copy = Snippet(trigger: s.trigger, text: s.text, added: s.added)
            copy.uses = s.uses
            here.insert(copy)
            added.snippets += 1
        }
        try here.save()
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.error("\(tool, privacy: .public) failed: \(msg, privacy: .public)")
            throw Failure(message: "Couldn't \(tool.hasSuffix("ditto") ? "zip or unzip" : "copy") the files.")
        }
    }
}
