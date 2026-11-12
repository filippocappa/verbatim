#if DEBUG
import AppKit
import AVFoundation
import SwiftData

/// Debug-only helpers for screenshots: `-demoPhase listening` holds the pill in one state,
/// `-demoData YES` fills the library with sample dictations, `-openMain YES` opens the main window.
enum Demo {
    static func runIfRequested(_ controller: DictationController) {
        let d = UserDefaults.standard
        if d.bool(forKey: "demoData") { seed() }
        if let look = d.string(forKey: "demoAppearance") {
            NSApp.appearance = NSAppearance(named: look == "light" ? .aqua : .darkAqua)
        }
        if let bundle = d.string(forKey: "testLearning") {
            Task { await testLearning(in: bundle, text: d.string(forKey: "learnText"), editByHand: !d.bool(forKey: "learnWait")); exit(0) }
            return
        }
        // -testTap com.apple.QuickTimePlayerX: listens to that app (and the mic) for -tapSeconds, printing levels,
        // then transcribes what the app played. -testTap all listens to the whole Mac.
        if let prefix = d.string(forKey: "testTap") {
            Task { await testTap(prefix == "all" ? [] : [prefix], seconds: max(d.double(forKey: "tapSeconds"), 8)); exit(0) }
            return
        }
        // -meetingPill offer|started|cantHear: shows that pill, for screenshots.
        if let pill = d.string(forKey: "meetingPill") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                switch pill {
                case "started": controller.showMeeting(.started(title: "Google Meet in Chrome"))
                case "cantHear": controller.showMeeting(.cantHear)
                case "listening": controller.demoPhase(.listening)
                default: controller.showMeeting(.offer(app: "Chrome", title: "Google Meet in Chrome", bundleID: "com.google.Chrome", service: "meet.google.com"))
                }
            }
        }
        if d.bool(forKey: "probeMic") {
            for m in Microphone.inputs() { print("input:", m.name, m.uid, m.isBluetooth ? "bluetooth" : m.isBuiltIn ? "built-in" : "other") }
            print("system default:", Microphone.systemDefault()?.name ?? "none")
            print("auto picks:", Microphone.choose(Microphone.automatic)?.name ?? "system default (no switch)")
            Task {
                let r = AudioRecorder()
                print("before:\n" + Microphone.debugState())
                do { try r.start(device: Microphone.choose(Microphone.automatic)) } catch { print("start failed:", error); exit(1) }
                try? await Task.sleep(for: .seconds(1.5))
                print("while recording:\n" + Microphone.debugState())
                let (samples, peak) = r.stop()
                print("recorded", samples.count, "samples, peak rms", peak)
                exit(0)
            }
            return
        }
        if d.bool(forKey: "rateInfo") {
            Task {
                guard let key = Keychain.groqKey else { print("no key"); exit(1) }
                func show(_ label: String, _ resp: URLResponse?) {
                    guard let h = resp as? HTTPURLResponse else { print(label, "no response"); return }
                    print("\(label): status \(h.statusCode)")
                    for (k, v) in h.allHeaderFields {
                        if let k = k as? String, k.lowercased().hasPrefix("x-ratelimit") { print("  \(k.lowercased()): \(v)") }
                    }
                }
                var chat = URLRequest(url: Groq.base.appendingPathComponent("chat/completions"))
                chat.httpMethod = "POST"
                chat.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
                chat.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "model": Prefs.cleanupModel, "max_completion_tokens": 5, "reasoning_effort": "none",
                    "messages": [["role": "user", "content": "Say ok"]]])
                show("cleanup model \(Prefs.cleanupModel)", try? await URLSession.shared.data(for: chat).1)

                var audio = URLRequest(url: Groq.base.appendingPathComponent("audio/transcriptions"))
                audio.httpMethod = "POST"
                audio.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let boundary = UUID().uuidString
                audio.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                var body = Data()
                func field(_ n: String, _ v: String) { body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!) }
                field("model", "whisper-large-v3-turbo")
                body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
                body.append(WAV.encode([Float](repeating: 0, count: 16_000)))
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
                audio.httpBody = body
                show("whisper-large-v3-turbo", try? await URLSession.shared.data(for: audio).1)
                exit(0)
            }
            return
        }
        if d.bool(forKey: "testCommands") {
            Task {
                // Snippets: matched as whole words, through the commas and capitals cleanup adds.
                let snips = [Snippet(trigger: "my email", text: "me@example.com"), Snippet(trigger: "my work email", text: "work@example.com"),
                             Snippet(trigger: "zoom link", text: "https://zoom.us/j/123")]
                for t in ["Send it to my email, please.", "Use My Email.", "my work email is fine", "Here's the Zoom link: ", "the emailmy email", "my emails"] {
                    print("snippet:", t, "→", Snippets.expand(t, snips).text)
                }
                print("whole:", Snippets.whole("My email.", snips)?.text ?? "nil", "/", Snippets.whole("my email is", snips)?.text ?? "nil")
                print("boost quiet:", AudioRecorder.boost([0.01, -0.02, 0.005]), "loud:", AudioRecorder.boost([0.5, -0.4]))

                guard let key = Keychain.groqKey else { print("no key"); exit(1) }
                let phrases = ["open YouTube", "apri Slack", "search YouTube for lo-fi beats", "google best pizza in Milan",
                               "cerca ricetta carbonara su youtube", "open Gmail", "open notes", "apri le note", "go to get hub",
                               "what's the weather in Milan tomorrow", "look up the iPhone 17 on Amazon", "open Cursor",
                               "delete all my files", "play Bohemian Rhapsody on Spotify", "vai su reddit", "open Linear"]
                for p in phrases where !d.bool(forKey: "onlyRewrite") {
                    let start = Date()
                    let a = (try? await Commands.parse(p, key: key)) ?? .none
                    var what = "\(a)"
                    switch a {
                    case let .open(target, kind, domain):
                        if let app = Apps.find(target, exactOnly: true) ?? (kind == "app" ? Apps.find(target, exactOnly: false) : nil) { what += "  → app \(app.url.path)" }
                        else { what += "  → \(Commands.siteURL(target, domain: domain)?.absoluteString ?? "nothing")" }
                    case let .search(site, query, domain):
                        what += "  → \(Commands.searchURL(site: site, query: query, domain: domain)?.absoluteString ?? "nothing")"
                    case .none, .custom: break
                    }
                    print(String(format: "%4.0f ms ", Date().timeIntervalSince(start) * 1000) + p + "  ⇒  " + what)
                }
                if d.bool(forKey: "onlyTone") {
                    let raws = ["um hey so are we still on for tomorrow i'll bring the demo and uh the new pricing numbers",
                                "i think the problem is that the server goes down when too many people log in at the same time we should add a queue",
                                "ciao allora stasera ci vediamo alle otto da marco porto io il vino"]
                    for raw in raws {
                        for t in [Tone.formal, .normal, .casual, .veryCasual] {
                            let r: String
                            do { r = t.finish(try await Groq.cleanup(raw, key: key, model: Prefs.cleanupModel, style: t == .formal ? .polished : .clean, tone: t,
                                                                      vocabulary: [], appName: "Discord")) } catch { r = "ERROR \(error)" }
                            print("tone [\(t.title)]:", r)
                        }
                        print("")
                        // Free Groq accounts get 7,000 input tokens a minute; each round is about 3,600.
                        try? await Task.sleep(for: .seconds(35))
                    }
                    exit(0)
                }
                if d.bool(forKey: "onlyCustom") {
                    let mine = UserCommands.ideas
                    for said in ["Bullets.", "bullets, keep it to three", "TL DR", "Standup finished the login page, working on stats, nothing blocked.", "open YouTube"] {
                        let m = UserCommands.match(said, in: mine)
                        print("match:", said, "→", m.map { "\($0.command.name) + [\($0.extra)]" } ?? "none")
                    }
                    let text = "We moved the launch to Thursday because the payment flow still has a bug. Marco is fixing it today. Design is done and copy is final. We still need the App Store screenshots."
                    for name in ["bullets", "tldr"] {
                        let c = mine.first { $0.name == name }!
                        let r = (try? await Commands.rewrite(text, instruction: c.instruction, key: key)) ?? "ERROR"
                        print("rewrite [\(name)]:", r.replacingOccurrences(of: "\n", with: " ⏎ "))
                    }
                    let su = mine.first { $0.name == "standup" }!
                    let w = (try? await Commands.write(instruction: su.instruction, said: "finished the login page, working on stats, nothing blocked", key: key)) ?? "ERROR"
                    print("write [standup]:", w.replacingOccurrences(of: "\n", with: " ⏎ "))
                    exit(0)
                }
                let sample = "hey so i was thinking we could maybe move the meeting to thursday if that works for everyone, let me know"
                for i in ["make it shorter", "more formal", "translate to Italian", "make it a list", "fix the grammar"] {
                    let r: String
                    do { r = try await Commands.rewrite(sample, instruction: i, key: key) } catch { r = "ERROR \(error)" }
                    print("rewrite [\(i)]:", r.replacingOccurrences(of: "\n", with: " ⏎ "))
                }
                exit(0)
            }
            return
        }
        if let bundle = d.string(forKey: "probeFocus") {
            Task {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate()
                try? await Task.sleep(for: .seconds(1))
                var role: CFTypeRef?
                if let f = FocusedField.current() {
                    AXUIElementCopyAttributeValue(f.element, kAXRoleAttribute as CFString, &role)
                    print("focused: role \(role as? String ?? "?"), text readable: \(f.value.map { "\($0.count) chars" } ?? "no"), cursor known: \(f.selection != nil)")
                } else { print("focused: nothing readable") }
                exit(0)
            }
            return
        }
        if d.bool(forKey: "testFixes") {
            let cases = [
                ("the word that came out was cloud", "the word that came out was Claude"),
                ("the word that came out was cloud", "the word that came out was claude"),
                ("We are moving to super base today", "We are moving to Supabase today"),
                ("deploy it on vessel tonight", "deploy it on Vercel tonight"),
                ("wrap it in a use effect hook", "wrap it in a useEffect hook"),
                ("I think we should ship it tomorrow", "I think we should ship it on Friday"),
                ("send it to marco", "send it to Marco"),
                ("this is fine", "this whole sentence was rewritten by hand"),
                ("Vani is faster than Dino", "Bun is faster than Deno"),
                ("We are paying for recent, Clerk, and Upstairs Redis.", "We are paying for Resend, Clerk, and Upstash Redis."),
                ("Check the post-hoc funnel", "Check the PostHog funnel"),
                ("Before we push to ourselves,", "Before we push to Vercel,"),
                ("send it to Marco", "send it to Luca"),
            ]
            let wrapped = "> Ok, so the text was all translated in Italian, I\n  don't know the reason, so check on that please. And\n  I tried correcting the last word"
            print("wrapped text found:", CorrectionWatcher.find("I don't know the reason, so check on that please. And I tried", in: wrapped).location != NSNotFound)
            for (a, b) in cases { print("\(a)  =>  \(b)\n   learned: \(CorrectionWatcher.fixes(from: a, to: b).map { "\($0.heard) -> \($0.word)" })") }
            exit(0)
        }
        if let path = d.string(forKey: "partsTest") {
            Task { await partsTest(path); exit(0) }
            return
        }
        if let path = d.string(forKey: "speedTest") {
            Task { await speedTest(path); exit(0) }
            return
        }
        if let name = d.string(forKey: "localDownload"), let m = LocalModel(rawValue: name) {
            Task {
                let t0 = ContinuousClock.now
                LocalModels.shared.download(m)
                var last = ""
                while true {
                    let state = "\(LocalModels.shared.state(m))"
                    if state != last { print("\(t0.duration(to: .now)) \(state)"); last = state }
                    if case .ready = LocalModels.shared.state(m) { break }
                    if case .failed = LocalModels.shared.state(m) { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                exit(0)
            }
            return
        }
        if let paths = d.string(forKey: "localTranscribe") {
            Task {
                for name in LocalModel.allCases where name.isOnDisk {
                    let t0 = ContinuousClock.now
                    try? await LocalSpeech.shared.warm(name)
                    print("\(name.rawValue) loaded in \(t0.duration(to: .now))")
                    for path in paths.split(separator: ",").map(String.init) {
                        do {
                            let samples = try load(path)
                            let t1 = ContinuousClock.now
                            let lang = d.string(forKey: "transcribeLanguage")
                            let t = try await LocalSpeech.shared.transcribe(samples, model: name, language: lang, prompt: nil)
                            print("\(name.rawValue) \((path as NSString).lastPathComponent) (\(t1.duration(to: .now)), \(t.language ?? "?")): \(t.text)")
                        } catch {
                            print("\(name.rawValue) failed: \(error)")
                        }
                    }
                    await LocalSpeech.shared.unload(name)
                }
                exit(0)
            }
            return
        }
        if let path = d.string(forKey: "transcribeFile") {
            Task { await transcribe(path); exit(0) }
            return
        }
        if d.bool(forKey: "listModels") {
            Task {
                var req = URLRequest(url: Groq.base.appendingPathComponent("models"))
                req.setValue("Bearer \(Keychain.groqKey ?? "")", forHTTPHeaderField: "Authorization")
                if let (data, _) = try? await Groq.session.data(for: req),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = obj["data"] as? [[String: Any]] {
                    for m in list { print("model:", m["id"] ?? "?") }
                }
                exit(0)
            }
            return
        }
        if let path = d.string(forKey: "cleanupSuite") {
            Task {
                let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                var total = Duration.zero
                for raw in lines where !raw.isEmpty {
                    let t = ContinuousClock.now
                    let out: String
                    do {
                        let c = try await Groq.cleanup(raw, key: Keychain.groqKey ?? "", model: Prefs.cleanupModel, style: .clean, vocabulary: [], appName: "Rex Beta")
                        out = Cleanup.accept(c, raw: raw) ?? "<rejected> \(c)"
                    } catch { out = "<error> \(error.localizedDescription)" }
                    let dt = t.duration(to: .now); total += dt
                    print(String(format: "%5.0fms  ", Double(dt.components.attoseconds) / 1e15 + Double(dt.components.seconds) * 1000) + out)
                }
                print("avg:", total / max(1, lines.count))
                exit(0)
            }
            return
        }
        if let text = d.string(forKey: "cleanupText") {
            Task {
                if let key = Keychain.groqKey {
                    let t = ContinuousClock.now
                    do {
                        let c = try await Groq.cleanup(text, key: key, model: Prefs.cleanupModel, style: .clean, vocabulary: [], appName: "Terminal")
                        print("cleanup (\(t.duration(to: .now))) returned: [\(c)]")
                        print("accepted: \(Cleanup.accept(c, raw: text) ?? "<rejected>")")
                    } catch { print("cleanup failed: \(error)") }
                }
                exit(0)
            }
            return
        }
        if d.bool(forKey: "openSettings") {
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                NSApp.activate()
                WindowRouter.openSettings?()
            }
        }
        if d.bool(forKey: "openMain") {
            Task {
                try? await Task.sleep(for: .milliseconds(600)); WindowRouter.show(WindowID.main)
                if let size = d.string(forKey: "windowSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                    try? await Task.sleep(for: .milliseconds(400))
                    for w in NSApp.windows where w.isVisible && w.frame.width > 500 { w.setContentSize(NSSize(width: size[0], height: size[1])) }
                }
            }
        }
        if let name = d.string(forKey: "demoPhase") {
            let phase: DictationController.Phase = switch name {
            case "writing": .writing
            case "pasted": .pasted(words: 38, latencyMs: 412, offline: false)
            case "offline": .pasted(words: 38, latencyMs: 1630, offline: true)
            case "copied": .copied(words: 38)
            case "learned": .learned(word: "Supabase")
            case "nothing": .notice(.nothingHeard)
            case "opened": .done(symbol: "arrow.up.right", title: "Searched YouTube", detail: "lo-fi beats to study")
            case "rewrote": .done(symbol: "checkmark", title: "Rewrote", detail: "make it shorter")
            case "rewriting": .writing
            default: .listening
            }
            let command: DictationController.CommandKind? = switch name {
            case "command": .action
            case "rewrite", "rewriting": .rewrite
            default: nil
            }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                controller.preview(phase, levels: sampleLevels, command: command)
            }
        }
    }

    /// Times the upload formats against each other on one clip, three runs each.
    static func testTap(_ prefixes: [String], seconds: Double) async {
        print("processes using audio:")
        for p in SystemAudio.processes() where p.input || p.output { print("  ", p) }
        let them = SystemAudio()
        let you = AudioRecorder()
        do { try them.start(prefixes: prefixes) } catch { print("tap failed:", error.localizedDescription); return }
        print("listening to:", them.tapped.joined(separator: ", "))
        do { try you.start(device: Microphone.systemDefault()) } catch { print("mic failed:", error.localizedDescription) }
        let rate = Int(AudioRecorder.sampleRate)
        func rms(_ x: [Float]) -> Float { x.isEmpty ? 0 : sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(x.count)) }
        var lastThem = 0, lastYou = 0
        for second in 1...Int(seconds) {
            try? await Task.sleep(for: .seconds(1))
            let t = them.sampleCount, y = you.sampleCount
            let lt = rms(them.samples(from: lastThem, to: t)), ly = rms(you.samples(from: lastYou, to: y))
            print(String(format: "%2ds  them %.4f (%d samples)  you %.4f", second, lt, t - lastThem, ly))
            lastThem = t; lastYou = y
        }
        let audio = them.samples(from: 0, to: them.sampleCount)
        them.stop()
        _ = you.stop()
        print(String(format: "them: %.1f s, peak %.4f", Double(audio.count) / Double(rate), them.peakRMS))
        if them.peakRMS < 0.0005 { print("SILENT: probably no System Audio Recording permission"); return }
        guard let key = Keychain.groqKey else { return }
        let up = Groq.upload(audio)
        if let t = try? await Groq.transcribe(wav: up.data, key: key, prompt: nil, language: "auto", filename: up.filename) {
            print("them said:", t.text)
        }
    }

    static func speedTest(_ path: String) async {
        guard let key = Keychain.groqKey, let samples = try? load(path) else { print("no key or clip"); return }
        print("audio: \(Double(samples.count) / 16_000) s")
        let wav = WAV.encode(samples)
        var t = ContinuousClock.now
        let m4a = Compressed.encode(samples, kind: "m4a")
        print("m4a encode \(t.duration(to: .now)), \(m4a?.count ?? 0) bytes")
        t = ContinuousClock.now
        let flac = Compressed.encode(samples, kind: "flac")
        print("flac encode \(t.duration(to: .now)), \(flac?.count ?? 0) bytes; wav \(wav.count) bytes")
        _ = try? await Groq.transcribe(wav: m4a!, key: key, prompt: nil, language: "en", filename: "a.m4a") // warm up
        for (name, data) in [("wav", wav), ("flac", flac!), ("m4a", m4a!)] {
            for _ in 0..<3 {
                let t0 = ContinuousClock.now
                let r = try? await Groq.transcribe(wav: data, key: key, prompt: nil, language: "auto", filename: "a.\(name)")
                print("\(name) single: \(t0.duration(to: .now))  \(r?.text.prefix(70) ?? "FAILED")")
            }
        }
        for (name, data) in [("wav", wav), ("m4a", m4a!)] {
            let t0 = ContinuousClock.now
            let r = try? await Groq.transcribeAuto(wav: data, key: key, words: [])
            print("\(name) auto x2: \(t0.duration(to: .now))  \(r?.pick.text.prefix(70) ?? "FAILED")")
        }
        let raw = (try? await Groq.transcribe(wav: m4a!, key: key, prompt: nil, language: "auto", filename: "a.m4a"))?.text ?? ""
        let t2 = ContinuousClock.now
        _ = try? await Groq.cleanup(raw, key: key, model: Prefs.cleanupModel, style: .clean, vocabulary: [], appName: "Terminal")
        print("cleanup of \(raw.split(separator: " ").count) words: \(t2.duration(to: .now))")
    }

    /// Plays a clip through the same pause finder a live recording uses, a second at a time,
    /// and compares the parts joined up with the whole clip in one go.
    static func partsTest(_ path: String) async {
        guard let key = Keychain.groqKey, let samples = try? load(path) else { print("no key or clip"); return }
        let rate = Int(AudioRecorder.sampleRate)
        var cuts: [Int] = []
        var t = rate
        while t <= samples.count {
            let start = cuts.last ?? 0
            if t - start >= rate * 15 {
                let pending = Array(samples[start..<t])
                if let at = AudioRecorder.pause(in: Array(pending.dropLast(rate / 5)), lookback: rate * 4) { cuts.append(start + at) }
            }
            t += rate
        }
        print("audio \(samples.count / rate) s, cuts at", cuts.map { String(format: "%.1f", Double($0) / Double(rate)) })
        var texts: [String] = []
        var prev = 0
        for c in cuts + [samples.count] {
            let r = try? await Groq.transcribe(wav: Groq.upload(Array(samples[prev..<c])).data, key: key, prompt: nil, language: "auto", filename: "a.m4a")
            texts.append(r?.text ?? "FAILED")
            prev = c
        }
        let t0 = ContinuousClock.now
        _ = try? await Groq.transcribe(wav: Groq.upload(Array(samples[(cuts.last ?? 0)...])).data, key: key, prompt: nil, language: "auto", filename: "a.m4a")
        print("last part alone: \(t0.duration(to: .now))")
        let t1 = ContinuousClock.now
        let whole = try? await Groq.transcribe(wav: Groq.upload(samples).data, key: key, prompt: nil, language: "auto", filename: "a.m4a")
        print("whole clip: \(t1.duration(to: .now))")
        print("PARTS: " + texts.joined(separator: " | "))
        print("WHOLE: " + (whole?.text ?? "FAILED"))
    }

    static func load(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: inBuf)
        let conv = AVAudioConverter(from: file.processingFormat, to: fmt)!
        let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate + 1024))!
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// Runs a sound file through the same engines as a dictation and prints what comes back.
    static func transcribe(_ path: String) async {
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: inBuf)
            let conv = AVAudioConverter(from: file.processingFormat, to: fmt)!
            let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate + 1024))!
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return inBuf
            }
            let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
            print("audio: \(Double(samples.count) / 16_000) s")

            let lang = UserDefaults.standard.string(forKey: "transcribeLanguage") ?? "en"
            let t0 = ContinuousClock.now
            let apple = try await AppleTranscriber.transcribe(samples: samples, languageCode: lang, vocabulary: ["Supabase"])
            print("apple (\(t0.duration(to: .now))): \(apple)")

            if let key = Keychain.groqKey {
                let t1 = ContinuousClock.now
                let g: Groq.Transcript
                if let prompt = UserDefaults.standard.string(forKey: "whisperPrompt") {
                    g = try await Groq.transcribe(wav: WAV.encode(samples), key: key, prompt: prompt, language: "auto")
                } else {
                    let r = try await Groq.transcribeAuto(wav: WAV.encode(samples), key: key, words: ["Supabase"])
                    print("  primed (it \(Int(Groq.italianShare(r.primed?.text ?? "") * 100))%): \(r.primed?.text.prefix(90) ?? "-")")
                    print("  plain  (it \(Int(Groq.italianShare(r.plain?.text ?? "") * 100))%): \(r.plain?.text.prefix(90) ?? "-")")
                    g = r.pick
                }
                print("groq (\(t1.duration(to: .now)), \(g.language ?? "?")): \(g.text)")
                let t2 = ContinuousClock.now
                let c = try await Groq.cleanup(g.text, key: key, model: Prefs.cleanupModel, style: .clean, vocabulary: [], appName: "Terminal")
                print("cleanup (\(t2.duration(to: .now))): \(Cleanup.accept(c, raw: g.text) ?? "<rejected>")")
            } else {
                print("groq: no key saved, skipped")
            }
        } catch {
            print("failed: \(error)")
        }
    }

    static func seed() {
        let ctx = Store.context
        guard (try? ctx.fetchCount(FetchDescriptor<Dictation>())) == 0 else { return }
        let apps: [(String, String)] = [
            ("Cursor", "com.todesktop.230313mzl4w4u92"), ("Terminal", "com.apple.Terminal"),
            ("Slack", "com.tinyspeck.slackmacgap"), ("Arc", "company.thebrowser.Browser"),
            ("Notes", "com.apple.Notes"), ("Messages", "com.apple.MobileSMS"),
        ]
        let lines = [
            "Refactor the auth middleware so the session check runs before the rate limiter, and add a test for the expired token case.",
            "Can you look at why the build fails on CI but not locally? I think it's the node version in the workflow file.",
            "Ok ci vediamo domani alle dieci in ufficio, porto io il portatile con la demo.",
            "Move the pricing table into its own component and make the annual toggle default to yearly.",
            "Add a migration that renames user_name to display_name and backfills it from the profiles table.",
            "Sounds good, ship it after lunch.",
            "Scrivi una mail a Marco per dire che la call di venerdì è spostata a lunedì mattina.",
            "Use Supabase row level security instead of checking the user id in every API route.",
            "The dropdown flickers when you hover the first item, check the z-index on the popover.",
            "Let's keep the onboarding to three steps and move the API key to the end.",
        ]
        let cal = Calendar.current
        let now = Date.now
        var rng = SystemRandomNumberGenerator()
        for dayOffset in 0..<18 {
            let count = dayOffset == 0 ? 34 : Int.random(in: 12...40, using: &rng)
            for i in 0..<count {
                let day = cal.date(byAdding: .day, value: -dayOffset, to: now)!
                var comps = cal.dateComponents([.year, .month, .day], from: day)
                comps.hour = Int.random(in: 0...6, using: &rng) == 0 ? Int.random(in: 7...8, using: &rng) : Int.random(in: 9...23, using: &rng)
                comps.minute = Int.random(in: 0...59, using: &rng)
                var date = cal.date(from: comps)!
                if dayOffset == 0 && date > now { date = now.addingTimeInterval(-Double(i) * 600) }
                let text = lines.randomElement(using: &rng)!
                let app = apps[min(apps.count - 1, Int(Double.random(in: 0...1, using: &rng).squareRoot() * Double(apps.count)) )]
                let it = text.contains("domani") || text.contains("Scrivi")
                let filler = Int.random(in: 0...3, using: &rng) == 0 ? "um, " : ""
                let d = Dictation(date: date, text: text, raw: filler + text.lowercased().replacingOccurrences(of: ",", with: ""),
                                  audioSeconds: Double(text.split(separator: " ").count) / 2.4,
                                  latencyMs: Int.random(in: 280...620, using: &rng),
                                  appName: app.0, appBundleID: app.1, engine: "groq", language: it ? "it" : "en")
                ctx.insert(d)
            }
        }
        for (w, h) in [("Supabase", "super base"), ("Claude", "cloud"), ("Vercel", "vessel"), ("useEffect", "use effect"), ("Tailwind", "tail wind"), ("Prisma", "prism")] {
            ctx.insert(VocabEntry(word: w, heardAs: [h], learned: true))
        }
        ctx.insert(VocabEntry(word: "Groq", heardAs: []))
        for (t, x, n) in [("my email", "hello@example.com", 14), ("my address", "Via Roma 12, 20121 Milano", 3),
                          ("meeting link", "https://meet.google.com/abc-defg-hij", 9),
                          ("sign off", "Thanks,\nAlex", 0)] {
            let sn = Snippet(trigger: t, text: x)
            sn.uses = n
            ctx.insert(sn)
        }
        try? ctx.save()
    }
}
/// Pastes a sentence into the frontmost window of `bundleID`, then edits one word through
/// Accessibility (like a user would by hand) and reports what the watcher learned.
@MainActor
func testLearning(in bundleID: String, text custom: String?, editByHand: Bool) async {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return print("not running: \(bundleID)") }
    app.activate()
    try? await Task.sleep(for: .seconds(1))
    guard let field = FocusedField.current() else { return print("no focused field") }
    print("focused field: \(field.value?.count ?? -1) chars readable, secure: \(field.isSecure)")
    let text = custom ?? "We are deploying the app on vessel tonight."
    Paster.paste(text)
    let watcher = CorrectionWatcher()
    var learned: [CorrectionWatcher.Fix]?
    watcher.onFixes = { learned = $0 }
    watcher.watch(pasted: text, in: field)
    try? await Task.sleep(for: .seconds(1.5))
    guard let value = FocusedField.readValue(field.element) else { return print("can't read the field after pasting") }
    print("after paste: \(value.contains(text) ? "found our text" : "our text is NOT in the field")")
    if editByHand {
        let edited = value.replacingOccurrences(of: "on vessel", with: "on Vercel")
        let err = AXUIElementSetAttributeValue(field.element, kAXValueAttribute as CFString, edited as CFString)
        print("edited by hand (AX set): \(err == .success ? "ok" : "failed \(err.rawValue)")")
    } else {
        print("READY: edit the text now")
        fflush(stdout)
    }
    for _ in 0..<(editByHand ? 12 : 80) where learned == nil { try? await Task.sleep(for: .seconds(0.5)) }
    print("learned: \(learned.map { $0.map { "\($0.heard) -> \($0.word)" }.joined(separator: ", ") } ?? "nothing")")
}

/// Keeps the audio of the last 100 dictations so they can be replayed with `-transcribeFile`.
enum DebugAudio {
    static let dir = URL.applicationSupportDirectory.appending(path: "\(AppInfo.bundleID)/DebugAudio")

    static func save(_ samples: [Float]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = Date.now.formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted)) + ".wav"
        try? WAV.encode(samples).write(to: dir.appending(path: name))
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for old in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(100) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
#endif
