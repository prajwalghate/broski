import AVFoundation
import AppKit
import BroskiCore
import Speech

/// `Broski --diagnose <audio file> <report file>` feeds a recording, in real time, through the
/// recognition-task sequences the app could use, and writes down which ones return text.
/// No microphone involved. Launch it with `open -n Broski.app --args …` so it runs with Broski's permissions.
@MainActor
enum Diagnostics {
    static func run(audio: URL, report: URL, args: [String] = CommandLine.arguments) {
        var lines: [String] = []
        func note(_ line: String) {
            lines.append(line)
            try? (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        }

        note("speech authorization: \(SFSpeechRecognizer.authorizationStatus().rawValue) (3 = authorized)")
        note("screen recording allowed: \(CGPreflightScreenCaptureAccess())")
        note("accessibility allowed: \(ContextCapture.accessibilityAllowed)")
        if args.contains("--permissions-only") { return }
        // `--overlays <Broski folder>/trackers` reads with the manifests kept there, as the app does.
        let overlays = args.firstIndex(of: "--overlays").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1], isDirectory: true) : nil }
        if let i = args.firstIndex(of: "--export-manifest"), i + 3 < args.count {
            // --export-manifest <path> <id> <out>: the manifest a tracker is read with, as an overlay file to keep or edit.
            let source = TrackerSource(id: args[i + 2], name: args[i + 2], path: args[i + 1])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                try encoder.encode(TrackerManifest.resolve(for: source, overlays: overlays)).write(to: URL(fileURLWithPath: args[i + 3]))
                note("wrote the manifest for \(source.id) to \(args[i + 3])")
            } catch {
                note("couldn't write the manifest: \(error)")
            }
            return note("done")
        }
        if let i = args.firstIndex(of: "--read-tracker"), i + 2 < args.count {
            // --read-tracker <path> <id> [questions…] [--overlays <dir>]
            let path = args[i + 1]
            let source = TrackerSource(id: args[i + 2], name: args[i + 2], path: path)
            let snap = TrackerReader.snapshot(source, project: "test", overlays: overlays)
            let records = snap.records
            note(String(format: "%@ via %@ at %@: %d records in %.2fs %@", source.id, snap.manifest, snap.revision.map { String($0.prefix(7)) } ?? "working tree",
                        records.count, snap.seconds, snap.problems.joined(separator: "; ")))
            for section in CoreSection.allCases {
                let inSection = records.filter { $0.section == section }
                guard !inSection.isEmpty else { continue }
                let kinds = Dictionary(grouping: inSection, by: \.kind).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
                note("\(section.label): \(inSection.count), open \(inSection.filter(\.open).count) — \(kinds)")
            }
            let findings = records.filter { $0.kind == "finding" || $0.kind == "ops" }
            note("findings by native status: " + Dictionary(grouping: findings, by: \.status).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", "))
            note("open crit: " + findings.filter { $0.open && $0.severity == "crit" }.map(\.recordID).sorted().joined(separator: ", "))
            note("open with fixed_on: \(findings.filter { $0.open && $0.fields["fixed_on"] != nil }.count)")
            let decisions = records.filter { $0.kind == "decision" }
            note("decisions \(decisions.count), open: " + decisions.filter(\.open).map(\.recordID).sorted().joined(separator: ", "))
            for plan in ["launch", "rehearsal", "prelaunch", "mainnet", "testnet"] {
                let steps = records.filter { $0.kind == "step" && $0.launch == plan }
                if !steps.isEmpty { note("plan \(plan): \(steps.count) steps (state \(steps.first!.canonical.rawValue))") }
            }
            note("runbook actions: \(records.filter { $0.kind == "runbook" && $0.fields["dataset"] == "runbook" }.count)")
            note("threads: " + records.filter { $0.kind == "thread" }.map(\.recordID).joined(separator: ", "))
            let unread = records.filter { $0.kind == "message" && $0.canonical == .unread }
            note("unread remarks: " + Dictionary(grouping: unread, by: { $0.fields["to"] ?? "?" }).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", "))
            note("open conflicts: \(records.filter { $0.kind == "conflict" && $0.open }.count) of \(records.filter { $0.kind == "conflict" }.count)")
            let owners = Dictionary(grouping: findings.filter(\.open), by: { $0.fields["owner_thread"] ?? "-" }).map { "\($0.key) \($0.value.count)" }.sorted()
            note("open findings by owner: " + owners.joined(separator: ", "))
            note("generated: " + records.filter(\.derived).map(\.recordID).joined(separator: ", "))
            note("archived records: \(records.filter(\.archived).count), low-trust: \(records.filter(\.lowTrust).count)")
            let leaks = records.filter { ($0.body + $0.title + $0.summary).range(of: "google-oauth2_[0-9]+", options: .regularExpression) != nil }
            note("redaction leaks: \(leaks.count)")
            let index = NotesIndex(records.filter { !$0.archived }.map(\.noteRef))
            for q in args.dropFirst(i + 3).prefix(while: { !$0.hasPrefix("--") }) {
                note("Q: \(q)")
                for hit in index.search(q, limit: 5) { note("   \(String(format: "%.2f", hit.score)) [\(hit.ref.id)] \(hit.ref.title.prefix(90))") }
            }
            return note("done")
        }
        if let i = args.firstIndex(of: "--transcribe") { return runTranscribe(Array(args[(i + 1)...]), note: note) }
        if let i = args.firstIndex(of: "--converse"), i + 1 < args.count { return runConverse(args[i + 1], note: note) }
        if args.contains("--brain") { return runBrain(note: note) }
        if let i = args.firstIndex(of: "--ask") { return runAsk(Array(args.dropFirst(i + 1)), note: note) }
        if let i = args.firstIndex(of: "--companion"), i + 1 < args.count { return runCompanion(helper: args[i + 1], note: note) }
        if args.contains("--request-accessibility") {
            ContextCapture.requestAccessibility()
            note("asked macOS for Accessibility; waiting up to 3 minutes")
            let deadline = Date().addingTimeInterval(180)
            while !ContextCapture.accessibilityAllowed && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            }
            note("accessibility allowed: \(ContextCapture.accessibilityAllowed)")
        }
        if let i = args.firstIndex(of: "--clip"), i + 1 < args.count { return runClip(helper: args[i + 1], note: note) }
        guard let chunks = try? loadChunks(audio), !chunks.isEmpty else {
            note("couldn't read \(audio.path)")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) else {
            note("no recognizer for \(Locale.current.identifier)")
            return
        }
        recognizer.queue = .main
        note("recognizer \(Locale.current.identifier), on-device \(recognizer.supportsOnDeviceRecognition), available \(recognizer.isAvailable)")
        note("audio: \(chunks.count) chunks of 0.1s, \(chunks[0].format)")

        runWhisperPipeline(chunks: chunks, note: note)
        runChunked(chunks: chunks, note: note)
        if args.contains("--whisper-only") { return note("done") }
        runEngine(chunks: chunks, note: note)

        for kind in Scenario.Kind.allCases {
            let scenario = Scenario(kind: kind, recognizer: recognizer, chunks: chunks, log: note)
            scenario.start()
            let deadline = Date().addingTimeInterval(Double(chunks.count) * 0.1 + 10)
            while !scenario.finished && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            scenario.stop()
            note("[\(kind)] RESULT \(scenario.summary)\n")
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        }
        note("done")
    }

    /// What a button capture does: record through SpeechEngine (no live preview), then Whisper, then Broski's rules.
    /// `--transcribe <audio>...`: each file through the app's own transcriber, Bark then Whisper, with your project
    /// names as the vocabulary; then room noise, which must come out as nothing.
    /// `--converse "<what you'd say>"`: one real turn through the model gateway with your key, then a save-card suggestion,
    /// in a throwaway folder (nothing of yours is read or written). Prints the reply, the model, the cost and the card.
    static func runConverse(_ text: String, note: @escaping (String) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("broski-converse-\(UUID().uuidString)", isDirectory: true)
        let gateway = ModelGateway(settings: .defaults, root: root, device: "mac") { id in id == "claude" ? Secrets.get(Secrets.claudeKey) : nil }
        let catalog = ProjectCatalog(projects: ["strado", "broski"].map { Project(name: $0) })
        // An older conversation and a standing decision, so recall, citations and replacing a decision are exercised.
        let earlier = Turn(at: Date().addingTimeInterval(-4 * 86_400), device: "mac", speaker: .you,
                           text: "For strado live trading, risk limit is max 2% of the account per position, always.", project: "strado")
        let standing = Decision(at: Date().addingTimeInterval(-3 * 86_400), device: "mac", project: "strado", text: "Start strado live with $500")
        try? ConversationStore(root: root, device: "mac").append(earlier)
        try? DecisionLog.record(standing, root: root)
        let index = NotesIndex(Recall.refs(turns: [earlier], root: root) + Recall.refs(decisions: [standing], root: root))
        let recall = Recall.find(text, index: index, excluding: [], hidden: [])
        note("recall: " + recall.map(\.label).joined(separator: " | "))
        let turn = Turn(device: "mac", speaker: .you, text: text, project: "strado")
        let request = ConversationContext.build(aboutYou: "Prefers short, direct answers.", page: nil, project: "strado", turns: [turn],
                                                isPrivate: false, decisions: DecisionLog.current(root: root, project: "strado"), recall: recall)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let started = Date()
                let (reply, route) = try await gateway.send(request, role: .everyday, project: "strado")
                let (clean, sources) = Recall.cited(in: reply.text, hits: recall)
                note(String(format: "reply via %@ in %.1fs: %@", route.model, Date().timeIntervalSince(started), clean))
                note("cited: " + (sources.isEmpty ? "nothing" : sources.joined(separator: " | ")))
                let transcript = "User: \(text)\n\nBroski: \(clean)"
                let ask = ModelRequest(system: SaveCard.instructions + "\n\nThe user's projects: strado, broski\n\nCurrent decisions on strado:\n<decisions>\n- \(standing.text)\n</decisions>",
                                       messages: [ModelMessage(role: .user, text: "<turns>\n\(transcript)\n</turns>")], maxTokens: 1500,
                                       schemaJSON: SaveCard.schemaJSON)
                let (cardReply, cardRoute) = try await gateway.send(ask, role: .fast, project: "strado")
                let review = SaveCard.review(cardReply.text, catalog: catalog, decisions: [standing])
                note("review via \(cardRoute.model): project \(review?.project ?? "none"), topic \(review?.topic ?? "none")")
                if let proposal = review?.newProject {
                    note("new project proposed: \(proposal.name) (\(proposal.slug)) · packs \(proposal.packs.joined(separator: ", ")) · goals \(proposal.goals.joined(separator: "; "))")
                }
                note("save card: " + (review?.card.map { c in c.items.map { "\($0.kind.rawValue) \($0.title)" + ($0.replaces == standing.id ? " (replaces the $500 decision)" : "") }.joined(separator: " | ") } ?? "nothing to save"))
                let spent = UsageLog.entries(root: root)
                note(String(format: "logged %d calls, $%.5f", spent.count, spent.reduce(0) { $0 + $1.usd }))
            } catch {
                note("failed: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: root)
            note("done")
            done.signal()
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func runTranscribe(_ files: [String], note: @escaping (String) -> Void) {
        let transcription = Transcription()
        var engine = "bark"
        transcription.settings = { (engine, "en-IN") }
        let root = AppModel.notesRoot
        let vocabulary = Array(Set(ItemStore(root: root).projectNames() + ProjectRegistry.load(from: root).projects.flatMap { [$0.notes, $0.name] + $0.aliases })).sorted()
        note("bark: \(transcription.barkState), whisper: \(transcription.state), vocabulary: \(vocabulary.count) names")
        func buffers(_ path: String) -> [AVAudioPCMBuffer] {
            guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil else { return [] }
            return [buffer]
        }
        var done = false
        Task { @MainActor in
            transcription.warmUp()
            for engineName in ["bark", "whisper"] {
                engine = engineName
                for path in files {
                    let started = Date()
                    do {
                        let text = try await transcription.transcribe(buffers(path), language: "en", vocabulary: vocabulary)
                        note(String(format: "[%@] %@ %.2fs: %@", engineName, (path as NSString).lastPathComponent, Date().timeIntervalSince(started), text))
                    } catch {
                        note("[\(engineName)] \((path as NSString).lastPathComponent) failed: \(error)")
                    }
                }
            }
            engine = "bark"
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            var noise: [AVAudioPCMBuffer] = []
            for _ in 0..<40 {
                guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800) else { break }
                b.frameLength = b.frameCapacity
                for i in 0..<Int(b.frameLength) { b.floatChannelData![0][i] = Float.random(in: -0.02...0.02) }
                noise.append(b)
            }
            let fromNoise = (try? await transcription.transcribe(noise, language: "en", vocabulary: vocabulary)) ?? "(failed)"
            note("[noise] 4s of room noise → \(fromNoise.isEmpty ? "nothing (good)" : "“\(fromNoise)” (BAD)")")
            done = true
        }
        let deadline = Date().addingTimeInterval(900)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        note("done")
    }

    static func runWhisperPipeline(chunks: [AVAudioPCMBuffer], note: @escaping (String) -> Void) {
        let engine = SpeechEngine()
        engine.simulatedInput = true
        let transcription = Transcription()
        guard transcription.isReady else { note("[whisper] model not downloaded"); return }
        do { try engine.beginDictation(replay: 0, live: false) } catch { note("[whisper] begin failed \(error)"); return }
        for chunk in chunks { engine.simulate(chunk) }
        let audio = engine.takeRecording()
        engine.stop()
        note("[whisper] recorded \(audio.count) buffers")
        var done = false
        let started = Date()
        Task { @MainActor in
            do {
                let text = try await transcription.transcribe(audio, language: "en", vocabulary: ["strado", "hip3 observatory", "trading bot"])
                note(String(format: "[whisper] %.1fs: %@", Date().timeIntervalSince(started), text))
                let catalog = ProjectCatalog(projects: ["strado", "hip3-observatory", "trading-bot"].map { Project(name: $0) })
                let decision = Brain.rules(text, catalog: catalog, activeSession: nil)
                note("[whisper] filed as: \(decision.action) · project \(decision.project) · \(decision.kind) · “\(decision.title)”")
                // Room noise must never become a note.
                let format = audio.first?.format ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
                var noise: [AVAudioPCMBuffer] = []
                for _ in 0..<40 {
                    guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate / 10)) else { break }
                    b.frameLength = b.frameCapacity
                    for i in 0..<Int(b.frameLength) { b.floatChannelData![0][i] = Float.random(in: -0.02...0.02) }
                    noise.append(b)
                }
                let fromNoise = try await transcription.transcribe(noise, language: "en", vocabulary: ["strado", "trading bot"])
                note("[noise] 4s of room noise → \(fromNoise.isEmpty ? "nothing (good)" : "“\(fromNoise)” (BAD)")")
                note("[mic] " + (await SpeechEngine().micCheck(seconds: 2)))
            } catch {
                note("[whisper] failed: \(error.localizedDescription)")
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(120)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        note("")
    }

    /// Ask Broski end to end: real notes, every tracker in projects.json (read in place), the briefing
    /// (waiting on you, what changed, live board readings) and Claude. Questions come from the arguments,
    /// or one per line from a file given as @path.
    static func runAsk(_ questions: [String], note: @escaping (String) -> Void) {
        let brain = Brain()
        let library = Library(store: ItemStore(root: AppModel.notesRoot), brain: brain)
        let localOnly = localOnlyProjects(library.store.root)
        library.brainSettings = { (false, localOnly) }
        brain.localOnly = { localOnly }
        library.startWatching()
        let deadline = Date().addingTimeInterval(120)
        while (library.readingTrackers || library.allRecords.isEmpty) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        note("index: \(library.index.refs.count) refs (\(library.allRecords.count) tracker records, \(library.allItems.count) notes) across \(library.registry.projects.count) projects")
        for (id, snap) in library.snapshots.sorted(by: { $0.key < $1.key }) {
            note(String(format: "  %@: %@ %@ %d records %.1fs %@", id, snap.manifest, snap.revision.map { String($0.prefix(7)) } ?? "", snap.records.count, snap.seconds, snap.problems.joined(separator: "; ")))
        }
        var list = questions
        if let first = questions.first, first.hasPrefix("@"), let text = try? String(contentsOfFile: String(first.dropFirst()), encoding: .utf8) {
            list = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        var done = false
        Task { @MainActor in
            defer { done = true }
            for q in list {
                let started = Date()
                do {
                    let answer = try await library.ask(q)
                    note(String(format: "\n### %@\n(%.1fs, %d sources, ai %@)\n%@\nSOURCES: %@", q, Date().timeIntervalSince(started), answer.sources.count,
                                answer.usedAI ? "yes" : "no", answer.markdown, answer.sources.map(\.id).joined(separator: ", ")))
                } catch {
                    note("\n### \(q)\nFAILED: \(error.localizedDescription)")
                }
            }
        }
        let end = Date().addingTimeInterval(1800)
        while !done && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        note("done")
    }

    /// The companion against Claude, on a test window (never your real screen): Help with this, a riff and its
    /// wrap-up, call notes from a sample transcript, and the call recorder hearing a spoken sentence.
    static func runCompanion(helper: String, note: @escaping (String) -> Void) {
        guard let key = Secrets.get(Secrets.claudeKey), !key.isEmpty else { return note("no Claude key saved") }
        let client = ClaudeClient(apiKey: key)
        var done = false
        Task { @MainActor in
            defer { done = true }
            // Help with this
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            try? process.run()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(options: [.activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            var started = Date()
            // Only ever the test window: if the helper didn't start or macOS kept another app in front, grabbing
            // "the front window" would send your real screen to Claude.
            let helperInFront = process.isRunning && NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
            let grabbed: WindowGrabber.Result
            if helperInFront { grabbed = await WindowGrabber.frontWindow() } else { grabbed = .failed("the test window isn't in front; skipped so your own screen isn't sent") }
            switch grabbed {
            case .image(let jpeg, _):
                note("[help] grabbed \(jpeg.count / 1024) KB of “\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")”")
                do {
                    let help = try await ScreenHelp.help(screenshot: jpeg, mediaType: "image/jpeg", context: ItemContext(app: "Test", window: "localhost:3000 — Console"),
                                                         page: nil, question: nil, client: client)
                    note(String(format: "[help · sonnet] %.1fs:\n%@", Date().timeIntervalSince(started), help))
                } catch { note("[help] failed: \(error.localizedDescription)") }
            case .needsPermission: note("[help] needs Screen Recording")
            case .failed(let message): note("[help] grab failed: \(message)")
            }
            process.terminate()

            // Riff
            var riff = Riff(project: "broski")
            riff.turns.append(.init(role: .you, text: "I'm thinking the iPhone app should start recording the moment I press the Action Button, and save on its own when I stop. Good idea?"))
            started = Date()
            do {
                let reply = try await riff.reply(page: nil, client: client)
                note(String(format: "[riff · opus] %.1fs: %@", Date().timeIntervalSince(started), reply))
                riff.turns.append(.init(role: .broski, text: reply))
                riff.turns.append(.init(role: .you, text: "Fair. Keep the review step, but make saving one tap. Add a todo for that."))
                started = Date()
                let wrap = try await riff.wrapUp(client: client)
                note(String(format: "[riff wrap · sonnet] %.1fs: “%@” · %d ideas · %d decisions · %d todos: %@", Date().timeIntervalSince(started),
                            wrap.title, wrap.ideas.count, wrap.decisions.count, wrap.todos.count, wrap.todos.joined(separator: "; ")))
            } catch { note("[riff] failed: \(error.localizedDescription)") }

            // Call notes from a sample transcript
            var transcript = CallTranscript(started: Date().addingTimeInterval(-300))
            transcript.lines = [
                .init(time: Date().addingTimeInterval(-290), speaker: .them, text: "Onboarding takes us about twenty minutes, mostly connecting the exchange."),
                .init(time: Date().addingTimeInterval(-280), speaker: .you, text: "What if we guide that step and test the connection before the first bot runs?"),
                .init(time: Date().addingTimeInterval(-270), speaker: .them, text: "That would help. I can send you screen recordings of our setup by Friday."),
                .init(time: Date().addingTimeInterval(-260), speaker: .you, text: "Great, I'll sketch the guided flow this week."),
            ]
            transcript.marks = [Date().addingTimeInterval(-279)]
            started = Date()
            do {
                let notes = try await transcript.notes(project: "strado", page: nil, client: client)
                note(String(format: "[call notes · sonnet] %.1fs: “%@” · actions: %@", Date().timeIntervalSince(started), notes.title, notes.action_items.joined(separator: "; ")))
            } catch { note("[call notes] failed: \(error.localizedDescription)") }

            // The call recorder: system audio while macOS speaks a sentence
            if #available(macOS 15.0, *) {
                let transcription = Transcription()
                guard transcription.isReady else { return note("[call] no voice model") }
                let recorder = CallRecorder()
                let heardAudio = ChunkAccumulator()
                let mic = ChunkAccumulator()
                recorder.onAudio = { speaker, buffer, rms in
                    _ = (speaker == .them ? heardAudio : mic).append(buffer, rms: rms)
                }
                do {
                    try await recorder.start()
                    let say = Process()
                    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    say.arguments = ["The guided exchange connection should ship before the beta."]
                    try? say.run()
                    try? await Task.sleep(nanoseconds: 7_000_000_000)
                    await recorder.stop()
                    let heard = heardAudio.flush()?.buffers ?? []
                    let text = try await transcription.transcribe(heard, language: "en", vocabulary: [])
                    note("[call recorder] them: \(heard.count) buffers → “\(text)” · me: \(mic.flush() == nil ? "quiet room" : "heard the mic")")
                } catch { note("[call recorder] failed: \(error.localizedDescription)") }
            }
        }
        let deadline = Date().addingTimeInterval(400)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        note("done")
    }

    /// The brain against your real notes and Claude key, without changing anything:
    /// filing with Haiku, a living page with Sonnet, and Ask Broski with citations.
    /// The local-only projects, read the same way the MCP server does: never written, closed when unreadable.
    static func localOnlyProjects(_ root: URL) -> Set<String> {
        BroskiConfig.localOnly(root: root) { ItemStore(root: root).projectNames() + ProjectRegistry.load(from: root).projects.map(\.notes) }
    }

    static func runBrain(note: @escaping (String) -> Void) {
        let store = ItemStore(root: AppModel.notesRoot)
        // A diagnostic sends real notes to Claude, so local-only projects are left out of everything it sends.
        let localOnly = localOnlyProjects(store.root)
        let items = store.allItems().filter { !localOnly.contains($0.project ?? "") }
        let sessions = store.allSessions().filter { !localOnly.contains($0.project ?? "") }
        let index = NotesIndex(items: items, sessions: sessions)
        let names = store.projectNames().filter { !localOnly.contains($0) }
        let catalog = ProjectCatalog(projects: names.map { Project(name: $0) })
        note("notes: \(items.count) in \(names.count) projects (\(names.joined(separator: ", "))), session entries: \(index.refs.count - items.count)")
        guard let key = Secrets.get(Secrets.claudeKey), !key.isEmpty else { return note("no Claude key saved") }
        let client = ClaudeClient(apiKey: key)
        let busiest = names.max { a, b in index.refs.filter { $0.project == a }.count < index.refs.filter { $0.project == b }.count } ?? names.first
        var done = false
        Task { @MainActor in
            defer { done = true }
            do {
                var started = Date()
                let filed = try await Interpreter.interpret(.init(text: "in the \(busiest ?? "broski") project add a bug the save button does nothing on the second click",
                                                                 spoken: true, projects: names, activeSession: nil, context: ItemContext(), attachmentCount: 0), with: client)
                note(String(format: "[filing · haiku] %.1fs → %@ · %@ · “%@”", Date().timeIntervalSince(started), filed.project, filed.kind, filed.title))
                guard let busiest else { return }
                let refs = index.refs.filter { $0.project == busiest }
                started = Date()
                let page = try await ProjectPageBuilder.compile(project: busiest, refs: refs, previous: nil, client: client)
                let cited = page.allCitations
                let valid = cited.filter { id in refs.contains { $0.id == id } }.count
                note(String(format: "[page · sonnet] %@ from %d notes in %.1fs, %d citations (%d valid), %d actions",
                            busiest, refs.count, Date().timeIntervalSince(started), cited.count, valid, page.actions.count))
                note(page.render().components(separatedBy: "\n---\n").last ?? "")
                started = Date()
                let question = "What's still open on \(busiest) and what should I do first?"
                let answer = try await Ask.answer(question, index: index, catalog: catalog, pages: [page], client: client, localOnly: localOnly)
                note(String(format: "[ask · sonnet] %.1fs, %d sources: %@", Date().timeIntervalSince(started), answer.sources.count, question))
                note(answer.markdown)
            } catch {
                note("brain failed: \(error.localizedDescription)")
            }
        }
        let deadline = Date().addingTimeInterval(300)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        note("done")
    }

    /// Starts a helper app with highlighted text in front, then grabs the selection the way ⌥⇧C does:
    /// through Accessibility, then by copying (the path browsers and Electron apps need).
    static func runClip(helper: String, note: @escaping (String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        try? process.run()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(options: [.activateIgnoringOtherApps])
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        note("frontmost: \(front)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("clipboard before", forType: .string)
        for force in [false, true] {
            UserDefaults.standard.set(force, forKey: "BroskiClipForceCopy")
            let context = ContextCapture.snapshot(includeBrowser: false, includeAccessibility: true)
            var done = false
            Task { @MainActor in
                switch await SelectionGrabber.grab(context) {
                case .text(let text): note("[\(force ? "copy" : "accessibility")] got: \(text)")
                case .nothing: note("[\(force ? "copy" : "accessibility")] nothing")
                case .needsAccessibility: note("[\(force ? "copy" : "accessibility")] needs Accessibility")
                }
                done = true
            }
            while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        UserDefaults.standard.removeObject(forKey: "BroskiClipForceCopy")
        note("clipboard after: \(NSPasteboard.general.string(forType: .string) ?? "nil") (should be “clipboard before”)")
        process.terminate()
        note("done")
    }

    /// What a long capture does: the mic keeps recording while Whisper writes out each phrase at a pause.
    /// Pauses never end the capture; the joined text should match transcribing it all at once.
    static func runChunked(chunks: [AVAudioPCMBuffer], note: @escaping (String) -> Void) {
        let engine = SpeechEngine()
        engine.simulatedInput = true
        let transcription = Transcription()
        guard transcription.isReady else { return }
        do { try engine.beginDictation(replay: 0, live: false) } catch { return }
        var pieces: [[AVAudioPCMBuffer]] = []
        var spoke = false, quiet = 0
        for chunk in chunks {
            engine.simulate(chunk)
            let samples = UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
            if rms > 0.01 { spoke = true; quiet = 0 } else { quiet += 1 }
            if spoke && quiet >= 9 {
                pieces.append(engine.drainRecording())
                spoke = false
            }
        }
        pieces.append(engine.takeRecording())
        engine.stop()
        var done = false
        let started = Date()
        Task { @MainActor in
            var text = ""
            for (i, piece) in pieces.enumerated() {
                let part = (try? await transcription.transcribe(piece, language: "en", vocabulary: ["strado", "hip3 observatory"])) ?? ""
                note(String(format: "[chunked] phrase %d (%.1fs audio): %@", i + 1, Double(piece.count) * 0.1, part.isEmpty ? "(silence)" : part))
                if !part.isEmpty { text = text.isEmpty ? part : text + " " + part }
            }
            note(String(format: "[chunked] %d phrases in %.1fs → %@", pieces.count, Date().timeIntervalSince(started), text))
            done = true
        }
        let deadline = Date().addingTimeInterval(120)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        note("")
    }

    /// The real SpeechEngine, fed from a background queue the way the microphone tap feeds it.
    static func runEngine(chunks: [AVAudioPCMBuffer], note: @escaping (String) -> Void) {
        let engine = SpeechEngine()
        engine.simulatedInput = true
        note("[engine] configure: \(engine.configure(locale: "auto") ?? "ok")")
        engine.contextualStrings = ["broski", "SAI", "Tamer", "broski", "bugbyte aso", "hip3 observatory", "marketroom", "strado"]
        engine.wantsWake = true
        let matcher = WakeWordMatcher(wakeWords: ["broski"])
        let started = Date()
        func t() -> String { String(format: "t=%.2f", Date().timeIntervalSince(started)) }
        var done = false
        var dictated = ""
        engine.onWakeTranscript = { text in
            guard engine.mode == .wake, matcher.firstMatch(in: text) != nil else { return }
            note("[engine] \(t()) wake word seen in: \(text)")
            do { try engine.beginDictation(replay: 2.5) } catch { note("[engine] beginDictation threw \(error)") }
        }
        engine.onDictationTranscript = { text in
            if dictated.isEmpty { note("[engine] \(t()) first dictation text: \(text)") }
            dictated = text
        }
        engine.onDictationEnded = { error in
            note("[engine] \(t()) dictation ended, \(SpeechEngine.code(of: error)), text: \(dictated)")
            done = true
        }
        engine.onProblem = { note("[engine] \(t()) problem: \($0)") }
        engine.startWake()

        let mic = DispatchQueue(label: "fake-mic")
        var index = 0
        let timer = DispatchSource.makeTimerSource(queue: mic)
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler {
            if index < chunks.count {
                engine.simulate(chunks[index])
                index += 1
                if index == chunks.count {
                    DispatchQueue.main.async {
                        note("[engine] \(t()) audio over, mode \(engine.mode); ending dictation")
                        engine.endDictation()
                    }
                }
            }
        }
        timer.resume()
        let deadline = Date().addingTimeInterval(Double(chunks.count) * 0.1 + 8)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        timer.cancel()
        engine.stop()
        note("[engine] RESULT \(dictated.isEmpty ? "no text" : dictated)\n")
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    }

    /// 0.1-second buffers, plus a second of silence at the end like a pause after speaking.
    static func loadChunks(_ url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate / 10)
        var out: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            out.append(buffer)
        }
        for _ in 0..<10 {
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            silence.frameLength = frames
            for ch in 0..<Int(format.channelCount) {
                silence.floatChannelData?[ch].update(repeating: 0, count: Int(frames))
            }
            out.append(silence)
        }
        return out
    }
}

private final class Scenario {
    enum Kind: String, CaseIterable {
        /// One punctuated task fed the whole clip. Baseline.
        case singleTask
        /// Cancel a task after 0.5s and start a fresh one right away (the periodic wake restart).
        case restartTask
        /// What the app does today: on the wake word, cancel the wake task inside its own
        /// result callback and start a dictation task seeded with 2.5s of replayed audio.
        case switchInCallback
        /// Like the app's cancelTask(): end the wake request's audio, cancel, then start the dictation task.
        case switchEndThenCancel
        /// Same, but start the dictation task 0.3s after cancelling.
        case switchDeferred
        /// End the wake task's audio and start the dictation task once it reports its final result.
        case switchAfterFinal
        /// Never switch: one punctuated task; the note is whatever follows the wake word.
        case keepOneTask
    }

    let kind: Kind
    let recognizer: SFSpeechRecognizer
    let chunks: [AVAudioPCMBuffer]
    let log: (String) -> Void
    let matcher = WakeWordMatcher(wakeWords: ["broski"])

    private(set) var finished = false
    private(set) var summary = "no text"
    private var fed = 0
    private var target: SFSpeechAudioBufferRecognitionRequest?
    private var tasks: [SFSpeechRecognitionTask] = []
    private var timer: Timer?
    private let started = Date()
    private var switched = false
    private var wakeAt = Date()
    private var startWhenFinal = false
    private var endedAudio = false

    init(kind: Kind, recognizer: SFSpeechRecognizer, chunks: [AVAudioPCMBuffer], log: @escaping (String) -> Void) {
        self.kind = kind
        self.recognizer = recognizer
        self.chunks = chunks
        self.log = log
    }

    private var t: String { String(format: "t=%.2f", Date().timeIntervalSince(started)) }

    func start() {
        switch kind {
        case .singleTask, .keepOneTask: startTask("B", punctuation: true, replay: 0)
        default: startTask("A", punctuation: false, replay: 0)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.feed() }
        if kind == .restartTask {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.tasks.last?.cancel()
                self.startTask("B", punctuation: true, replay: 0)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        tasks.forEach { $0.cancel() }
    }

    private func feed() {
        if fed < chunks.count {
            target?.append(chunks[fed])
            fed += 1
        } else if !endedAudio {
            endedAudio = true
            target?.endAudio()
            log("[\(kind)] \(t) end of audio")
        }
    }

    private func startTask(_ label: String, punctuation: Bool, replay seconds: Double) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = punctuation
        request.taskHint = .dictation
        request.contextualStrings = ["broski"]
        var sawFirst = false
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if !sawFirst {
                    sawFirst = true
                    self.log("[\(self.kind)] \(self.t) \(label) first result: \(text)")
                }
                if label == "B" { self.summary = text }
                if result.isFinal {
                    self.log("[\(self.kind)] \(self.t) \(label) final: \(text)")
                    if label == "B" { self.finished = true }
                    if label == "A" && self.startWhenFinal { self.startB(afterFinal: true) }
                }
                if label == "A", !self.switched, self.matcher.firstMatch(in: text) != nil { self.wake(request) }
            }
            if let error {
                self.log("[\(self.kind)] \(self.t) \(label) error: \(SpeechEngine.code(of: error))")
                if label == "B" { self.finished = true }
                if label == "A" && self.startWhenFinal { self.startB(afterFinal: true) }
            }
        }
        tasks.append(task)
        let n = seconds > 0 ? min(fed, Int(seconds * 10)) : 0
        for chunk in chunks[(fed - n)..<fed] { request.append(chunk) }
        target = request
        log("[\(kind)] \(t) \(label) started, replayed \(n) chunks")
    }

    private func wake(_ wakeRequest: SFSpeechAudioBufferRecognitionRequest) {
        guard [.switchInCallback, .switchEndThenCancel, .switchDeferred, .switchAfterFinal].contains(kind) else { return }
        switched = true
        wakeAt = Date()
        log("[\(kind)] \(t) wake word seen")
        switch kind {
        case .switchInCallback:
            tasks.last?.cancel()
            startTask("B", punctuation: true, replay: 2.5)
        case .switchEndThenCancel:
            wakeRequest.endAudio()
            tasks.last?.cancel()
            startTask("B", punctuation: true, replay: 2.5)
        case .switchDeferred:
            tasks.last?.cancel()
            target = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.startB(afterFinal: false) }
        case .switchAfterFinal:
            wakeRequest.endAudio()
            target = nil
            startWhenFinal = true
        default:
            break
        }
    }

    private func startB(afterFinal: Bool) {
        guard !(afterFinal && !startWhenFinal) else { return }
        startWhenFinal = false
        startTask("B", punctuation: true, replay: Date().timeIntervalSince(wakeAt) + 2.5)
    }
}
