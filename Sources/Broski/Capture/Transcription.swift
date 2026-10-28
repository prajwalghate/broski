import AVFoundation
import BroskiBark
import BroskiCore
import BroskiWhisper

/// Local speech-to-text: Bark 3.0 for English (on the Neural Engine, macOS 15+) and Whisper for every language and
/// as the fallback. Downloads each model once, keeps it loaded, and turns recorded audio into text.
@MainActor
final class Transcription: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case missing
        case downloading(Double)
        /// Bark only: compiling the model for this Mac, once, after the download (a few minutes).
        case preparing
        case ready
        case failed(String)
    }

    /// Whisper's model.
    @Published private(set) var state: State = .missing { didSet { updateVoiceState() } }
    /// Bark's model.
    @Published private(set) var barkState: State = .missing { didSet { updateVoiceState() } }
    /// What the panel's badge shows: ready when either engine can take the next note.
    @Published private(set) var voiceState: State = .missing
    let model: WhisperModel = .largeV3TurboQ5
    private var transcriber: WhisperTranscriber?
    private var loading: Task<WhisperTranscriber, Error>?
    private var download: URLSessionDownloadTask?
    /// The speech engine setting ("auto", "bark", "whisper") and the speech locale, from the config.
    var settings: () -> (engine: String, locale: String) = { ("auto", "auto") }
    /// A BarkTranscriber, once loaded (typed loosely: it exists on macOS 15 and later only).
    private var bark: AnyObject?
    private var barkLoading: Task<AnyObject, Error>?
    private var barkDownload: Task<Void, Never>?

    override init() {
        super.init()
        state = model.isDownloaded ? .ready : .missing
        if !Self.barkSupported {
            barkState = .failed("Bark needs macOS 15 or later.")
        } else if BarkModel.isDownloaded() {
            // Ready once it has loaded on this Mac and this macOS: the first load (or one after an update) prepares
            // it for the Neural Engine, which takes minutes, so until then it prepares in the background (warmUp).
            barkState = Self.barkPrepared ? .ready : .preparing
        }
        updateVoiceState()
    }

    static var barkSupported: Bool { if #available(macOS 15.0, *) { return true } else { return false } }
    static var barkCache: URL { BarkModel.cache }
    static var barkPrepared: Bool { BarkModel.isPrepared }

    /// Some engine can transcribe the next note: Whisper, or Bark when the note is in English.
    var isReady: Bool { state == .ready || barkUsable(Self.language(for: settings().locale)) }

    /// Bark takes English when it's downloaded, unless the setting picks Whisper.
    /// Only once it's ready: while it compiles (minutes, once) notes go to Whisper or Apple's dictation, not a wait.
    func barkUsable(_ language: String?) -> Bool {
        guard Self.barkSupported, barkState == .ready, settings().engine != "whisper" else { return false }
        return Self.isEnglish(language)
    }

    static func isEnglish(_ language: String?) -> Bool {
        language == "en" || (language == nil && Locale.current.identifier.hasPrefix("en"))
    }

    private func updateVoiceState() {
        if isReady { voiceState = .ready; return }
        for candidate in [barkState, state] {
            if case .downloading = candidate { voiceState = candidate; return }
            if candidate == .preparing { voiceState = .preparing; return }
        }
        if case .failed = state { voiceState = state } else { voiceState = .missing }
    }

    /// The model worth getting for this Mac and language: Bark for English on macOS 15+, else Whisper.
    func downloadPreferred() {
        if Self.barkSupported, settings().engine != "whisper", Self.isEnglish(Self.language(for: settings().locale)) {
            downloadBark()
        } else {
            downloadModel()
        }
    }

    // MARK: Model

    func downloadModel() {
        guard download == nil, !model.isDownloaded else { return }
        try? FileManager.default.createDirectory(at: WhisperModel.directory, withIntermediateDirectories: true)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.downloadTask(with: model.downloadURL)
        download = task
        state = .downloading(0)
        task.resume()
        Log.info("Downloading Whisper model \(model.fileName)")
    }

    func cancelDownload() {
        download?.cancel()
        download = nil
        state = .missing
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor in self.state = .downloading(fraction) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this returns, so move it now.
        let model = WhisperModel.largeV3TurboQ5
        let staged = model.localURL.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: staged)
        let moved = (try? FileManager.default.moveItem(at: location, to: staged)) != nil
        let ok = (downloadTask.response as? HTTPURLResponse)?.statusCode == 200
        let id = downloadTask.taskIdentifier
        Task { @MainActor in
            var installed: Result<Void, Error>?
            if moved, ok {
                // Only the pinned file is installed; hashing its 574 MB stays off the main thread.
                installed = await Task.detached { Result { try model.pinned.install(staged, at: model.localURL) } }.value
            }
            try? FileManager.default.removeItem(at: staged)
            // Cancelled or started again while it was checked: that wins, unless the model is now in place.
            guard self.download?.taskIdentifier == id else {
                if self.download == nil, model.isDownloaded { self.state = .ready; self.warmUp() }
                return
            }
            self.download = nil
            switch installed {
            case .success?:
                self.state = .ready
                Log.info("Whisper model ready")
                self.warmUp()
            case .failure(let error as PinnedFile.Mismatch)?:
                Log.info("Whisper download refused: \(error.localizedDescription)")
                self.state = .failed("The download didn't match the expected file, so it was deleted. Try again.")
            default:
                self.state = .failed("The download didn't finish. Try again.")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            self.download = nil
            self.state = .failed(error.localizedDescription)
        }
    }

    /// Loads the models in the background so the first note isn't slow (and compiles Bark once, if it needs to).
    func warmUp() {
        if state == .ready { Task { _ = try? await loadedTranscriber() } }
        if barkState == .ready || barkState == .preparing { Task { _ = try? await loadedBark() } }
    }

    // MARK: Bark

    /// Downloads Bark's files one by one, each checked against its pinned size and SHA-256, then prepares it.
    func downloadBark() {
        guard Self.barkSupported, barkDownload == nil else { return }
        barkState = .downloading(0)
        Log.info("Downloading Bark 3.0 (\(BarkModel.totalBytes / 1_000_000) MB)")
        barkDownload = Task { [weak self] in
            do {
                // Downloading and hashing 200 MB stays off the main thread; progress hops back to it.
                try await Task.detached {
                    try await BarkDownloader.download { fraction in
                        Task { @MainActor in self?.barkState = .downloading(fraction) }
                    }
                }.value
                guard let self else { return }
                self.barkState = .preparing
                self.barkDownload = nil
                _ = try await self.loadedBark()
            } catch {
                Log.info("Bark download failed: \(error)")
                self?.barkState = .failed("The Bark download didn't finish (\(error)). Try again.")
                self?.barkDownload = nil
            }
        }
    }

    func cancelBarkDownload() {
        barkDownload?.cancel()
        barkDownload = nil
        barkState = BarkModel.isDownloaded() ? .preparing : .missing
    }

    /// Loads Bark, compiling it for this Mac the first time (a few minutes, once; the compiled copy is kept).
    private func loadedBark() async throws -> AnyObject {
        if let bark { return bark }
        if let barkLoading { return try await barkLoading.value }
        guard #available(macOS 15.0, *) else { throw BarkUnavailable() }
        let task = Task.detached(priority: .utility) { () -> AnyObject in
            try await BarkTranscriber.load(directory: BarkModel.directory, cache: Self.barkCache)
        }
        barkLoading = task
        defer { barkLoading = nil }
        do {
            let started = Date()
            let made = try await task.value
            bark = made
            barkState = .ready
            BarkModel.markPrepared()
            Log.info(String(format: "Bark ready in %.1fs", Date().timeIntervalSince(started)))
            return made
        } catch {
            barkState = .failed("Bark couldn't load (\(error)). Download it again, or use Whisper.")
            Log.info("Bark failed to load: \(error)")
            throw error
        }
    }

    private func loadedTranscriber() async throws -> WhisperTranscriber {
        if let transcriber { return transcriber }
        if let loading { return try await loading.value }
        let url = model.localURL
        // Beam search: a little slower than greedy, noticeably fewer dropped or wrong words.
        let task = Task.detached(priority: .userInitiated) { try WhisperTranscriber(modelURL: url, beamSize: 5) }
        loading = task
        defer { loading = nil }
        do {
            let made = try await task.value
            transcriber = made
            return made
        } catch {
            // A model that won't load would fail every phrase: say so, so captures use Apple's dictation meanwhile
            // and the badge offers the download again.
            state = .failed("The voice model couldn't load (\(error.localizedDescription)). Download it again.")
            Log.info("Whisper model failed to load: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: Transcribing

    /// `language` is a Whisper code like "en", or nil to detect it. `vocabulary` (project names) helps spelling.
    func transcribe(_ buffers: [AVAudioPCMBuffer], language: String?, vocabulary: [String]) async throws -> String {
        let samples = try await Task.detached(priority: .userInitiated) { () -> [Float] in
            var all: [Float] = []
            for buffer in buffers { all += try WhisperTranscriber.resample(buffer) }
            return all
        }.value
        guard let speech = Self.speechOnly(samples) else {
            Log.info("No speech in \(String(format: "%.1f", Double(samples.count) / 16_000))s of audio; skipped transcription")
            return ""
        }
        // Bark not loaded yet (just launched, or macOS was updated and it's preparing again): this note goes to
        // Whisper while Bark loads in the background, rather than waiting on it.
        if barkUsable(language), bark == nil, state == .ready {
            Task { _ = try? await loadedBark() }
        } else if barkUsable(language), #available(macOS 15.0, *) {
            do {
                guard let bark = try await loadedBark() as? BarkTranscriber else { throw BarkUnavailable() }
                let started = Date()
                let raw = try await Task.detached(priority: .userInitiated) { try bark.transcribe(samples: speech) }.value
                Log.info(String(format: "Bark: %.1fs of speech in %.2fs", Double(speech.count) / 16_000, Date().timeIntervalSince(started)))
                // Bark can't be primed with project names, so the polish snaps near-misses to them. No prompt, no echo check.
                return Self.clean(TranscriptPolish.apply(raw, vocabulary: vocabulary))
            } catch {
                Log.info("Bark failed, using Whisper: \(error)")
                guard state == .ready else { throw error }
            }
        }
        let whisper = try await loadedTranscriber()
        // A plain word list nudges spelling without giving Whisper a sentence to continue.
        let prompt = (["Broski"] + vocabulary.prefix(40)).joined(separator: ", ") + "."
        let started = Date()
        let text = try await whisper.transcribe(samples: speech, language: language, prompt: prompt)
        Log.info(String(format: "Whisper: %.1fs of speech (of %.1fs) in %.1fs", Double(speech.count) / 16_000,
                        Double(samples.count) / 16_000, Date().timeIntervalSince(started)))
        return Self.clean(text, vocabulary: vocabulary)
    }

    /// Trims silence from both ends. Nil when there's less than ~0.4 s of speech-level sound,
    /// so silence and room noise never reach Whisper (which invents text for them).
    nonisolated static func speechOnly(_ samples: [Float]) -> [Float]? {
        let frame = 320  // 20 ms
        guard samples.count >= frame * 10 else { return nil }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame)
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            levels.append(10 * log10(max(sum / Float(frame), 1e-10)))
            i += frame
        }
        let floor = levels.sorted()[levels.count / 10]
        let threshold = max(floor + 10, -50)
        let loud = levels.indices.filter { levels[$0] > threshold }
        guard loud.count >= 20, let first = loud.first, let last = loud.last else { return nil }
        // Generous margins so soft first and last words survive the trim.
        let start = max(0, first - 30) * frame
        let end = min(levels.count, last + 40) * frame
        return Array(samples[start..<min(end, samples.count)])
    }

    /// Phrases Whisper produces for silence, music or applause rather than real speech.
    static let hallucinations: Set<String> = [
        "thank you", "thanks", "thank you very much", "thanks for watching", "thank you for watching", "you", "bye",
        "bye bye", "okay", "ok", "so", "oh", "hmm", "uh", "um", "please subscribe", "subscribe", "the end",
        "subtitles by the amara org community", "transcribed by", "music", "applause", "broski",
    ]

    /// Strips Whisper's non-speech markers and known silence phrases, and an echo of the prompt.
    static func clean(_ text: String, vocabulary: [String] = []) -> String {
        var s = text.replacingOccurrences(of: #"\[[^\]]*\]|\((?:silence|music|inaudible|applause|laughs?)[^)]*\)|♪+"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let squashed = s.lowercased().components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted).joined()
            .trimmingCharacters(in: .whitespaces)
        if hallucinations.contains(squashed) { return "" }
        let words = Set(squashed.split(separator: " ").map(String.init))
        let promptWords = Set((["broski"] + vocabulary).flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) })
        if !words.isEmpty, words.isSubset(of: promptWords) { return "" }
        return s
    }


    /// Whisper language code from Broski's locale setting.
    static func language(for locale: String) -> String? {
        let id = locale == "auto" ? Locale.current.identifier : locale
        let code = String(id.prefix(2)).lowercased()
        return code.isEmpty ? nil : code
    }
}

/// Bark isn't available here (before macOS 15).
struct BarkUnavailable: Error, CustomStringConvertible {
    var description: String { "Bark needs macOS 15 or later" }
}
