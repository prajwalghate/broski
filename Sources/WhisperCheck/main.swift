import BroskiWhisper
import Foundation

/// Usage: WhisperCheck <audio-file>... [--model <path>] [--prompt <text>] [--language <code|auto>] [--beam <n>] [--cpu] [--verbose]
var files: [URL] = []
var modelURL = WhisperModel.default.localURL
var prompt: String?
var language: String? = "en"
var useGPU = true
var verbose = false
var beamSize = 1

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--model": modelURL = URL(fileURLWithPath: args.next() ?? "")
    case "--prompt": prompt = args.next()
    case "--language": language = args.next().flatMap { $0 == "auto" ? nil : $0 }
    case "--cpu": useGPU = false
    case "--beam": beamSize = Int(args.next() ?? "") ?? 1
    case "--verbose": verbose = true
    default: files.append(URL(fileURLWithPath: arg))
    }
}
guard !files.isEmpty else {
    print("usage: WhisperCheck <audio-file>... [--model <path>] [--prompt <text>] [--language <code|auto>] [--beam <n>] [--cpu] [--verbose]")
    exit(2)
}

func seconds(since start: Date) -> String { String(format: "%.2fs", Date().timeIntervalSince(start)) }

@MainActor func run() async throws {
    WhisperTranscriber.setLogging(enabled: verbose)
    print("model: \(modelURL.path)  gpu: \(useGPU)  beam: \(beamSize)  threads: \(WhisperTranscriber.performanceCores)")
    var start = Date()
    let transcriber = try WhisperTranscriber(modelURL: modelURL, useGPU: useGPU, beamSize: beamSize)
    print("load: \(seconds(since: start))")

    for file in files {
        start = Date()
        let samples = try WhisperTranscriber.loadAudioFile(file)
        let audioSeconds = Double(samples.count) / WhisperTranscriber.sampleRate
        print("\n\(file.lastPathComponent): \(String(format: "%.2f", audioSeconds))s audio, decoded in \(seconds(since: start))")
        start = Date()
        let text = try await transcriber.transcribe(samples: samples, language: language, prompt: prompt)
        print("transcribe: \(seconds(since: start))")
        print("text: \(text)")
    }
}

do {
    try await run()
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
