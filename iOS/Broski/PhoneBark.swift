import BroskiBark
import BroskiCore
import UIKit

/// Bark 3.0 on the iPhone (iOS 18+, English): downloaded once in Settings, prepared for the Neural Engine once,
/// then it writes each note's final text from the recording. Apple's recognizer still shows the words as you talk,
/// and writes the text whenever Bark isn't ready.
@MainActor
final class PhoneBark: ObservableObject {
    static let shared = PhoneBark()

    enum State: Equatable {
        case missing, downloading(Double), preparing, ready, failed(String), unsupported
    }

    @Published private(set) var state: State = .missing
    /// The Settings switch: Bark writes English notes when it's ready.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { warmUp() }
        }
    }
    private static let enabledKey = "BroskiUseBark"

    /// A BarkTranscriber once loaded (typed loosely: it exists on iOS 18 and later only).
    private var bark: AnyObject?
    private var loading: Task<AnyObject, Error>?
    private var download: Task<Void, Never>?

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        guard #available(iOS 18.0, *) else { state = .unsupported; return }
        if BarkModel.isDownloaded() { state = BarkModel.isPrepared ? .ready : .preparing }
    }

    /// Bark takes this note: English, switched on, and loaded or ready to load quickly.
    var usable: Bool {
        guard enabled, state == .ready else { return false }
        return Locale.current.language.languageCode?.identifier == "en"
    }

    /// Loads Bark in the background (and prepares it the first time), so the first note isn't slow.
    func warmUp() {
        guard enabled, bark == nil, loading == nil, state == .ready || state == .preparing else { return }
        Task { _ = try? await loaded() }
    }

    func startDownload() {
        guard #available(iOS 18.0, *), download == nil else { return }
        state = .downloading(0)
        // A locked screen suspends the app and the download with it.
        UIApplication.shared.isIdleTimerDisabled = true
        download = Task { [weak self] in
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                try await Task.detached {
                    try await BarkDownloader.download { fraction in
                        Task { @MainActor in self?.state = .downloading(fraction) }
                    }
                }.value
                guard let self else { return }
                self.download = nil
                self.state = .preparing
                _ = try await self.loaded()
            } catch {
                self?.download = nil
                self?.state = .failed("The download didn't finish (\(error)). Try again on Wi-Fi.")
            }
        }
    }

    func cancelDownload() {
        download?.cancel()
        download = nil
        state = BarkModel.isDownloaded() ? .preparing : .missing
    }

    private func loaded() async throws -> AnyObject {
        if let bark { return bark }
        if let loading { return try await loading.value }
        guard #available(iOS 18.0, *) else { throw BarkUnavailable() }
        let task = Task.detached(priority: .utility) { () -> AnyObject in
            try await BarkTranscriber.load(directory: BarkModel.directory, cache: BarkModel.cache)
        }
        loading = task
        // The first load prepares the model for this iPhone (minutes); a locked screen would suspend the app mid-way.
        let firstTime = !BarkModel.isPrepared
        if firstTime { state = .preparing; UIApplication.shared.isIdleTimerDisabled = true }
        defer {
            loading = nil
            if firstTime { UIApplication.shared.isIdleTimerDisabled = false }
        }
        do {
            let made = try await task.value
            bark = made
            state = .ready
            BarkModel.markPrepared()
            return made
        } catch {
            state = .failed("Bark couldn't load (\(error)). Download it again.")
            throw error
        }
    }

    /// The note's text from its recording, tidied with your project names; nil when Bark can't take it now
    /// (Apple's text is used instead).
    func transcribe(_ samples: [Float], vocabulary: [String]) async -> String? {
        guard usable, samples.count >= 16_000 / 2, #available(iOS 18.0, *) else { return nil }
        // Not loaded yet (just opened, or iOS was updated and it's preparing again): this note uses Apple's text.
        guard let bark = bark as? BarkTranscriber else {
            warmUp()
            return nil
        }
        do {
            let raw = try await Task.detached(priority: .userInitiated) { try bark.transcribe(samples: samples) }.value
            let text = TranscriptPolish.apply(raw, vocabulary: vocabulary)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    // MARK: Checking it on a real iPhone

    /// `--bark-selftest <file in tmp>`: downloads Bark if needed, prepares it, transcribes the file, and writes
    /// timings and the text to tmp/bark-selftest.txt, for checking Bark on a device without talking to it.
    /// (tmp, not Documents, so none of it shows up in the Files app.)
    func selfTest(file: String) async {
        let folder = FileManager.default.temporaryDirectory
        let report = folder.appendingPathComponent("bark-selftest.txt")
        var lines: [String] = []
        func note(_ line: String) {
            lines.append(line)
            try? (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        }
        note("Bark self-test \(Date()) · \(ProcessInfo.processInfo.operatingSystemVersionString) · state \(state)")
        guard #available(iOS 18.0, *) else { return note("unsupported: needs iOS 18") }
        var started = Date()
        if !BarkModel.isDownloaded() {
            startDownload()
            while case .downloading = state { try? await Task.sleep(nanoseconds: 500_000_000) }
            note(String(format: "downloaded in %.0fs → %@", Date().timeIntervalSince(started), "\(state)"))
        }
        started = Date()
        guard let bark = (try? await loaded()) as? BarkTranscriber else { return note("load failed: \(state)") }
        note(String(format: "loaded in %.1fs", Date().timeIntervalSince(started)))
        let url = folder.appendingPathComponent(file)
        guard let samples = BarkAudio.read(url) else { return note("couldn't read \(file)") }
        for run in 1...3 {
            started = Date()
            let text = (try? bark.transcribe(samples: samples)) ?? "(failed)"
            note(String(format: "run %d: %.1fs of audio in %.2fs: %@", run, Double(samples.count) / 16_000, Date().timeIntervalSince(started), text))
        }
        note("done")
    }
}

struct BarkUnavailable: Error, CustomStringConvertible {
    var description: String { "Bark needs iOS 18 or later" }
}
