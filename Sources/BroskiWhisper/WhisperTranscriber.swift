import AVFoundation
import Foundation
import whisper

public enum WhisperError: LocalizedError {
    case modelMissing(URL)
    case modelLoadFailed(URL)
    case transcriptionFailed(Int32)
    case audioConversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let url): return "No Whisper model at \(url.path)."
        case .modelLoadFailed(let url): return "Couldn't load the Whisper model \(url.lastPathComponent)."
        case .transcriptionFailed(let code): return "Whisper failed to transcribe (code \(code))."
        case .audioConversionFailed(let reason): return "Couldn't convert audio for Whisper: \(reason)"
        }
    }
}

/// Downloadable ggml Whisper models, hosted on Hugging Face.
public enum WhisperModel: String, CaseIterable, Sendable {
    case largeV3TurboQ5
    case smallQ5
    case baseEn

    public static let `default`: WhisperModel = .largeV3TurboQ5

    public var fileName: String {
        switch self {
        case .largeV3TurboQ5: return "ggml-large-v3-turbo-q5_0.bin"
        case .smallQ5: return "ggml-small-q5_1.bin"
        case .baseEn: return "ggml-base.en.bin"
        }
    }

    public var displayName: String {
        switch self {
        case .largeV3TurboQ5: return "Large v3 Turbo (best)"
        case .smallQ5: return "Small (faster)"
        case .baseEn: return "Base, English only (fastest)"
        }
    }

    /// Approximate download size in megabytes.
    public var approximateSizeMB: Int {
        switch self {
        case .largeV3TurboQ5: return 574
        case .smallQ5: return 190
        case .baseEn: return 148
        }
    }

    /// Whether the model only understands English (no language detection).
    public var isEnglishOnly: Bool { self == .baseEn }

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    /// ~/Library/Application Support/Broski/models/
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Broski/models", isDirectory: true)
    }

    public var localURL: URL { Self.directory.appendingPathComponent(fileName) }
    public var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }
}

/// One loaded whisper.cpp model. Whisper contexts aren't thread-safe, so every call runs on a
/// private serial queue; the async variant keeps the main thread free.
public final class WhisperTranscriber: @unchecked Sendable {
    public let modelURL: URL
    /// 1 decodes greedily (fastest); 5 is Whisper's beam search (slightly more accurate, slower).
    public let beamSize: Int
    private let ctx: OpaquePointer
    private let queue = DispatchQueue(label: "dev.broski.whisper", qos: .userInitiated)

    /// Sample rate Whisper expects.
    public static let sampleRate: Double = 16_000

    /// Loads the model once. Metal is used when `useGPU` is true and available.
    public init(modelURL: URL, useGPU: Bool = true, beamSize: Int = 1) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw WhisperError.modelMissing(modelURL) }
        var params = whisper_context_default_params()
        params.use_gpu = useGPU
        params.flash_attn = useGPU
        guard let ctx = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw WhisperError.modelLoadFailed(modelURL)
        }
        self.modelURL = modelURL
        self.beamSize = max(1, beamSize)
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    /// Transcribes 16 kHz mono Float32 PCM. `language` is a code like "en", or nil to auto-detect.
    /// `prompt` nudges spelling and style, e.g. a list of project names.
    public func transcribe(samples: [Float], language: String? = "en", prompt: String? = nil) throws -> String {
        try queue.sync { try run(samples: samples, language: language, prompt: prompt) }
    }

    /// Same as `transcribe(samples:language:prompt:)`, off the calling thread.
    public func transcribe(samples: [Float], language: String? = "en", prompt: String? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.run(samples: samples, language: language, prompt: prompt) })
            }
        }
    }

    private func run(samples: [Float], language: String?, prompt: String?) throws -> String {
        // Whisper needs at least a second of audio; pad short clips with silence.
        var pcm = samples
        let minimum = Int(Self.sampleRate)
        if pcm.count < minimum { pcm += [Float](repeating: 0, count: minimum - pcm.count) }

        var params = whisper_full_default_params(beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        params.beam_search.beam_size = Int32(beamSize)
        params.n_threads = Int32(Self.performanceCores)
        params.no_timestamps = true
        params.single_segment = false
        params.no_context = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.translate = false
        params.no_speech_thold = 0.6

        let lang = strdup(language?.isEmpty == false ? language! : "auto")
        let initial = prompt.flatMap { $0.isEmpty ? nil : strdup($0) }
        defer { free(lang); free(initial) }
        params.language = UnsafePointer(lang)
        params.detect_language = false
        params.initial_prompt = UnsafePointer(initial)

        let status = pcm.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
        guard status == 0 else { throw WhisperError.transcriptionFailed(status) }

        // Drop segments Whisper itself thinks aren't speech, or that it's guessing at:
        // that's where invented sentences come from when the audio is noise or a film in the background.
        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            guard let segment = whisper_full_get_segment_text(ctx, i) else { continue }
            let noSpeech = whisper_full_get_segment_no_speech_prob(ctx, i)
            var total: Float = 0
            var count: Float = 0
            for t in 0..<whisper_full_n_tokens(ctx, i) {
                let data = whisper_full_get_token_data(ctx, i, t)
                if data.id >= whisper_token_eot(ctx) { continue }
                total += data.p
                count += 1
            }
            let confidence = count > 0 ? total / count : 0
            // Only drop text Whisper is both unsure about and thinks isn't speech; uncertain real words stay.
            if (noSpeech > 0.6 && confidence < 0.55) || confidence < 0.2 { continue }
            text += String(cString: segment)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Performance-core count on Apple Silicon, all active cores elsewhere.
    public static var performanceCores: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Turns whisper.cpp / ggml logging to stderr on or off (it is chatty by default).
    public static func setLogging(enabled: Bool) {
        if enabled {
            whisper_log_set(nil, nil)
        } else {
            whisper_log_set({ _, _, _ in }, nil)
        }
    }

    // MARK: - Audio

    /// The format Whisper wants: 16 kHz, mono, Float32, non-interleaved.
    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!

    /// Converts any PCM buffer (e.g. 44.1/48 kHz, mono or stereo) to 16 kHz mono Float32 samples.
    public static func resample(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let input = buffer.format
        if input.commonFormat == .pcmFormatFloat32, input.sampleRate == sampleRate,
           input.channelCount == 1, let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        guard buffer.frameLength > 0 else { return [] }
        guard let converter = AVAudioConverter(from: input, to: targetFormat) else {
            throw WhisperError.audioConversionFailed("unsupported format \(input)")
        }
        converter.downmix = true
        let ratio = sampleRate / input.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw WhisperError.audioConversionFailed("couldn't allocate buffer")
        }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw WhisperError.audioConversionFailed(conversionError?.localizedDescription ?? "unknown error")
        }
        guard let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// Reads an audio file (aiff, wav, m4a, caf...) as 16 kHz mono Float32 samples.
    public static func loadAudioFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw WhisperError.audioConversionFailed("couldn't allocate buffer")
        }
        try file.read(into: buffer)
        return try resample(buffer)
    }
}
