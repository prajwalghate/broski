import AVFoundation
import AppKit
import BroskiCore
import ScreenCaptureKit
import SwiftUI

/// Call notes: records your mic ("Me") and the call's audio ("Them") as two tracks, transcribes each phrase
/// with local Whisper as the call goes, and at the end writes the notes with Claude. Always visible while
/// recording, and it reminds you to tell people you're taking notes.
@MainActor
final class CallModel: ObservableObject {
    enum Phase: Equatable { case idle, recording, writing, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = CallTranscript()
    @Published private(set) var pending = 0
    @Published var project: String?
    @Published var notes: CallTranscript.Notes?
    @Published var addActionItems = true
    @Published var saved: String?
    @Published private(set) var level: (me: Float, them: Float) = (0, 0)
    /// Why the recording ended before you pressed Stop, if the system ended it.
    @Published private(set) var interrupted: String?

    let library: Library
    let brain: Brain
    let transcription: Transcription
    var locale: () -> String = { "auto" }
    var onStateChange: (Bool) -> Void = { _ in }
    private var recorder: AnyObject?
    private let me = ChunkAccumulator()
    private let them = ChunkAccumulator()
    private var chain: Task<Void, Never>?
    /// Starting capture; ends with why it failed, if it did.
    private var starting: Task<String?, Never>?
    private var meters: Task<Void, Never>?

    init(library: Library, brain: Brain, transcription: Transcription) {
        self.library = library
        self.brain = brain
        self.transcription = transcription
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(transcript.started) }

    func start(project: String?) {
        // Not while the last call's notes are still being written: its Task would write into this one.
        guard phase != .recording, phase != .writing else { return }
        guard #available(macOS 15.0, *) else { return phase = .failed("Call notes need macOS 15 or later.") }
        guard transcription.isReady else { return phase = .failed("Download the voice model first (Settings › Voice).") }
        self.project = project
        transcript = CallTranscript()
        notes = nil
        saved = nil
        interrupted = nil
        me.reset()
        them.reset()
        let recorder = CallRecorder()
        recorder.onAudio = { [weak self] speaker, buffer, rms in
            guard let self else { return }
            let accumulator = speaker == .you ? self.me : self.them
            if let chunk = accumulator.append(buffer, rms: rms) {
                Task { @MainActor in self.enqueue(chunk, speaker: speaker) }
            }
        }
        recorder.onStop = { [weak self, weak recorder] error in
            Task { @MainActor in
                guard let self, let recorder else { return }
                let reason = (error as? SCStreamError)?.code == .userStopped
                    ? "You stopped screen capture from the menu bar"
                    : "Recording stopped early (\(error.localizedDescription))"
                Log.info("Call notes interrupted: \(error.localizedDescription)")
                self.finish(recorder, interruption: reason)
            }
        }
        self.recorder = recorder
        phase = .recording
        onStateChange(true)
        startMeters()
        starting = Task {
            do {
                try await recorder.start()
                Log.info("Call notes started")
                return nil
            } catch {
                let problem = "Couldn't start: \(error.localizedDescription). Broski needs Screen Recording and the microphone."
                // A Stop while macOS was still starting capture already ended this call; finish shows why.
                guard self.recorder === recorder else { return problem }
                self.recorder = nil
                stopMeters()
                phase = .failed(problem)
                onStateChange(false)
                return problem
            }
        }
    }

    /// The meters update ten times a second from each track's loudest moment, not once per audio buffer,
    /// so the call window isn't redrawn about 100 times a second.
    private func startMeters() {
        meters?.cancel()
        meters = Task {
            while !Task.isCancelled {
                level = (me.takePeak(), them.takePeak())
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func stopMeters() {
        meters?.cancel()
        meters = nil
        level = (0, 0)
    }

    func mark() {
        transcript.marks.append(Date())
    }

    func stop() {
        guard phase == .recording, #available(macOS 15.0, *), let recorder = recorder as? CallRecorder else { return }
        finish(recorder, interruption: nil)
    }

    /// Ends the call once, whether you stopped it or the system did, and writes the notes from what was heard.
    @available(macOS 15.0, *)
    private func finish(_ recorder: CallRecorder, interruption: String?) {
        guard phase == .recording, self.recorder === recorder else { return }
        // State changes before any await, so a second Stop (window, pill, menu) or a system stop does nothing.
        phase = .writing
        self.recorder = nil
        interrupted = interruption
        stopMeters()
        onStateChange(false)
        let starting = self.starting
        Task {
            // A capture still starting (e.g. behind a permission prompt) must come up first: stopping it sooner
            // does nothing and it would then record unseen, so there's no timeout. If it failed, say why.
            if let problem = await starting?.value {
                phase = .failed(problem)
                return
            }
            await recorder.stop()
            if let chunk = me.flush() { enqueue(chunk, speaker: .you) }
            if let chunk = them.flush() { enqueue(chunk, speaker: .them) }
            await chain?.value
            Log.info("Call notes stopped: \(transcript.lines.count) lines")
            await write()
        }
    }

    private func enqueue(_ chunk: ChunkAccumulator.Chunk, speaker: CallTranscript.Line.Speaker) {
        let previous = chain
        pending += 1
        let vocabulary = library.projectNames
        let language = Transcription.language(for: locale())
        chain = Task {
            await previous?.value
            defer { pending -= 1 }
            guard let text = try? await transcription.transcribe(chunk.buffers, language: language, vocabulary: vocabulary),
                  !text.isEmpty else { return }
            transcript.lines.append(.init(time: chunk.started, speaker: speaker, text: text))
        }
    }

    private func write() async {
        guard !transcript.lines.isEmpty else { return phase = .failed(interrupted.map { "\($0) before Broski heard anything." } ?? "Nothing was said that Broski could hear.") }
        // A call picked for, or talking about, a local-only project gets plain notes: the transcript stays on the Mac.
        let localOnly = LocalOnly.touches(transcript.text, projects: [project], localOnly: Set(BroskiUI.app?.config.localOnlyProjects ?? []),
                                          catalog: library.catalog)
        guard let gateway = brain.gateway, !localOnly else {
            notes = CallTranscript.Notes(title: "Call, \(transcript.started.formatted(date: .abbreviated, time: .shortened))",
                                         summary_markdown: "", decisions: [], action_items: [], follow_ups: [])
            return phase = .done
        }
        do {
            notes = try await transcript.notes(project: project, page: project.flatMap { library.pages[$0] }, gateway: gateway)
            phase = .done
        } catch {
            notes = CallTranscript.Notes(title: "Call, \(transcript.started.formatted(date: .abbreviated, time: .shortened))",
                                         summary_markdown: "The model couldn't write the notes (\(error.localizedDescription)); the transcript is below.",
                                         decisions: [], action_items: [], follow_ups: [])
            phase = .done
        }
    }

    func save() {
        guard let notes else { return }
        var body = notes.summary_markdown
        if !notes.decisions.isEmpty { body += "\n\n**Decisions**\n" + notes.decisions.map { "- \($0)" }.joined(separator: "\n") }
        if !notes.action_items.isEmpty { body += "\n\n**Action items**\n" + notes.action_items.map { "- [ ] \($0)" }.joined(separator: "\n") }
        if !notes.follow_ups.isEmpty { body += "\n\n**Follow-ups**\n" + notes.follow_ups.map { "- \($0)" }.joined(separator: "\n") }
        if let interrupted { body = "_\(interrupted); these notes cover the call up to that point._\n\n" + body }
        body += "\n\n<details><summary>Transcript</summary>\n\n" + transcript.text + "\n</details>"
        do {
            let store = library.store
            let context = ItemContext(app: "Call notes")
            let item = try store.create(ItemDraft(project: project, kind: .note, tags: ["call"], title: notes.title, body: body, context: context))
            if addActionItems {
                for action in notes.action_items {
                    _ = try store.create(ItemDraft(project: project, kind: .todo, tags: ["call"], title: action,
                                                   body: "From the call “\(notes.title)”.", context: context))
                }
            }
            library.reload()
            saved = "Saved to \(item.project ?? "Inbox")"
        } catch {
            saved = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// A call in a given state, for snapshots.
    func preview(phase: Phase, transcript: CallTranscript, notes: CallTranscript.Notes? = nil) {
        self.phase = phase
        self.transcript = transcript
        self.notes = notes
    }

    func reset() {
        // The notes are still being written; resetting now would offer Start over a call that isn't finished.
        guard phase != .writing else { return }
        phase = .idle
        notes = nil
        saved = nil
        interrupted = nil
    }
}

/// Collects one speaker's audio and cuts it into phrases at pauses (or every ~25 s), on the audio thread.
final class ChunkAccumulator: @unchecked Sendable {
    struct Chunk {
        var buffers: [AVAudioPCMBuffer]
        var started: Date
    }

    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var duration: Double = 0
    private var voiced: Double = 0
    private var quiet: Double = 0
    private var floor: Float = 0.02
    private var peak: Float = 0

    func reset() {
        lock.lock(); defer { lock.unlock() }
        buffers = []
        duration = 0
        voiced = 0
        quiet = 0
        floor = 0.02
        peak = 0
    }

    /// The loudest level since the last call, for the meter.
    func takePeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let loudest = peak
        peak = 0
        return loudest
    }

    func append(_ buffer: AVAudioPCMBuffer, rms: Float) -> Chunk? {
        lock.lock(); defer { lock.unlock() }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        peak = max(peak, rms)
        floor = rms < floor ? rms : floor + (rms - floor) * 0.002
        let speaking = rms > max(floor * 3, 0.012)
        // Don't keep long stretches of silence before anyone speaks.
        if !speaking, voiced == 0 {
            if duration > 2 { buffers.removeAll(); duration = 0 }
        }
        buffers.append(buffer)
        duration += seconds
        if speaking { voiced += seconds; quiet = 0 } else { quiet += seconds }
        let pause = voiced > 1.5 && quiet > 0.9 && duration > 4
        guard pause || duration > 25 else { return nil }
        return take()
    }

    func flush() -> Chunk? {
        lock.lock(); defer { lock.unlock() }
        return voiced > 0.4 ? take() : nil
    }

    private func take() -> Chunk {
        // Worked out from what's kept, so trimmed silence and earlier cuts can't leave a stale start time.
        let chunk = Chunk(buffers: buffers, started: Date().addingTimeInterval(-duration))
        buffers = []
        duration = 0
        voiced = 0
        quiet = 0
        return chunk
    }
}

/// System audio (the other people on the call) and your mic, through ScreenCaptureKit.
@available(macOS 15.0, *)
final class CallRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onAudio: (CallTranscript.Line.Speaker, AVAudioPCMBuffer, Float) -> Void = { _, _, _ in }
    /// The system ended capture (menu-bar Stop, a revoked permission, a display change). Called on any queue.
    var onStop: (Error) -> Void = { _ in }
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "dev.broski.call-audio")

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Audio only: the smallest, slowest possible video.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone, let buffer = sampleBuffer.pcmBuffer() else { return }
        onAudio(type == .microphone ? .you : .them, buffer, buffer.rms)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}

extension CMSampleBuffer {
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let description = formatDescription, var asbd = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

extension AVAudioPCMBuffer {
    var rms: Float {
        guard let data = floatChannelData?[0], frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(frameLength) { sum += data[i] * data[i] }
        return sqrt(sum / Float(frameLength))
    }
}

// MARK: View

struct CallView: View {
    @ObservedObject var model: CallModel
    var onClose: () -> Void
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .idle: setup
            case .recording: recording
            case .writing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.pending > 0 ? "Finishing the transcript (\(model.pending) left)…" : "Writing the notes…")
                }
                .padding(.vertical, 30)
            case .done: result
            case .failed(let message):
                Text(message).foregroundStyle(.orange)
                Button("Close", action: onClose)
            }
        }
        .padding(16)
        .frame(width: 420)
        .frame(minHeight: 200, alignment: .top)
        .onReceive(timer) { now = $0 }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Take notes on a call").font(.system(size: 15, weight: .semibold))
            Text("Broski records your mic and the call's audio on this Mac, writes it out locally with Whisper, and turns it into notes and action items when you stop.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label("Let everyone on the call know you're taking notes.", systemImage: "hand.raised")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            projectPicker
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                Button("Start") { model.start(project: model.project) }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text("Recording · \(Duration.seconds(Int(now.timeIntervalSince(model.transcript.started))).formatted(.time(pattern: .minuteSecond)))")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Spacer()
                meter("Me", model.level.me)
                meter("Them", model.level.them)
            }
            TranscriptLines(lines: model.transcript.lines).equatable()
            HStack {
                Button { model.mark() } label: { Label("Mark this moment", systemImage: "star") }
                    .help("Flag something important; the notes will cover it")
                if !model.transcript.marks.isEmpty { Text("\(model.transcript.marks.count) marked").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Button { model.stop() } label: { Label("Stop and write notes", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notes = model.notes {
                if let interrupted = model.interrupted {
                    Label(interrupted + ". The notes cover the call up to that point.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text(notes.title).font(.system(size: 15, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !notes.summary_markdown.isEmpty { Text(notes.summary_markdown).font(.system(size: 12.5)).textSelection(.enabled) }
                        section("Decisions", notes.decisions)
                        section("Action items", notes.action_items)
                        section("Follow-ups", notes.follow_ups)
                        DisclosureGroup("Transcript (\(model.transcript.lines.count) lines)") {
                            Text(model.transcript.text).font(.system(size: 11)).textSelection(.enabled)
                        }
                        .font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                projectPicker
                if !notes.action_items.isEmpty {
                    Toggle("Add the \(notes.action_items.count) action item\(notes.action_items.count == 1 ? "" : "s") as todos", isOn: $model.addActionItems)
                }
                HStack {
                    if let saved = model.saved { Label(saved, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Spacer()
                    Button(model.saved == nil ? "Discard" : "Close") { model.reset(); onClose() }
                    Button("Save notes") { model.save() }
                        .buttonStyle(.borderedProminent).tint(Brand.purple)
                        .disabled(model.saved != nil)
                }
            }
        }
    }

    private var projectPicker: some View {
        Picker("Project", selection: Binding(get: { model.project ?? "" }, set: { model.project = $0.isEmpty ? nil : $0 })) {
            Text("Inbox").tag("")
            ForEach(model.library.projectNames, id: \.self) { Text($0).tag($0) }
        }
        .frame(maxWidth: 260)
    }

    private func meter(_ label: String, _ level: Float) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Capsule().fill(Color.primary.opacity(0.1)).frame(width: 34, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(Brand.purple).frame(width: CGFloat(min(1, level * 12)) * 34, height: 4)
                }
        }
    }

    @ViewBuilder private func section(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(lines, id: \.self) { Text("• " + $0).font(.system(size: 12)) }
            }
        }
    }
}

/// The live transcript, kept out of CallView's body so the meters and the clock don't re-render every line.
private struct TranscriptLines: View, Equatable {
    let lines: [CallTranscript.Line]

    nonisolated static func == (a: Self, b: Self) -> Bool { a.lines == b.lines }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if lines.isEmpty {
                        Text("Lines appear here a few seconds after each phrase.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        (Text(line.speaker.rawValue + ": ").bold().foregroundColor(line.speaker == .you ? Brand.purple : .secondary)
                         + Text(line.text))
                            .font(.system(size: 12))
                            .id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            .onChange(of: lines.count) { count in withAnimation { proxy.scrollTo(count - 1) } }
        }
    }
}
