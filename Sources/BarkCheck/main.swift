import AVFoundation
import BroskiBark
import CoreML
import Foundation

// Transcribes audio files with Bark: `swift run BarkCheck <model folder> <audio>... [--expect "text"]`.
// Prints each transcript, its time, and (with --expect) the word error rate against the expected text.

func samples16k(_ url: URL) throws -> [Float] {
    guard let samples = BarkAudio.read(url) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
    return samples
}

func words(_ s: String) -> [String] {
    s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}

func wer(_ hypothesis: String, _ reference: String) -> Double {
    let h = words(hypothesis), r = words(reference)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var d = Array(0...h.count)
    for i in 1...r.count {
        var previous = d[0]
        d[0] = i
        for j in 1...max(h.count, 1) where j <= h.count {
            let temp = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, previous + (r[i - 1] == h[j - 1] ? 0 : 1))
            previous = temp
        }
    }
    return Double(d[h.count]) / Double(r.count)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("usage: BarkCheck <model folder> <audio>... [--expect text]"); exit(2) }
let folder = URL(fileURLWithPath: args[0], isDirectory: true)
var audios: [String] = []
var expected: [String] = []
var i = 1
var units = "ane"
var dumpFeatures: String?
var windows = [8, 15]
while i < args.count {
    if args[i] == "--expect", i + 1 < args.count { expected.append(args[i + 1]); i += 2 }
    else if args[i] == "--units", i + 1 < args.count { units = args[i + 1]; i += 2 }
    else if args[i] == "--dump-features", i + 1 < args.count { dumpFeatures = args[i + 1]; i += 2 }
    else if args[i] == "--windows", i + 1 < args.count { windows = args[i + 1].split(separator: ",").compactMap { Int($0) }; i += 2 }
    else { audios.append(args[i]); i += 1 }
}
@available(macOS 15.0, *)
func run() async {
    do {
        var started = Date()
        let computeUnits: MLComputeUnits = ["gpu": .cpuAndGPU, "cpu": .cpuOnly, "all": .all][units] ?? .cpuAndNeuralEngine
        let bark = try await BarkTranscriber.load(directory: folder, cache: folder.appendingPathComponent("cache"), computeUnits: computeUnits, windows: windows)
        print(String(format: "loaded in %.1fs", Date().timeIntervalSince(started)))
        var totalWER = 0.0
        for (n, path) in audios.enumerated() {
            let audio = try samples16k(URL(fileURLWithPath: path))
            if let dumpFeatures {
                let f = bark.features(for: audio)
                try f.values.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: dumpFeatures))
                print("features: \(f.frames) frames, \(f.valid) valid → \(dumpFeatures)")
            }
            started = Date()
            let text = try bark.transcribe(samples: audio)
            let seconds = Date().timeIntervalSince(started)
            let duration = Double(audio.count) / 16_000
            print(String(format: "\n%@ (%.1fs of audio, %.2fs, %.0f× real time)\n  %@", (path as NSString).lastPathComponent, duration, seconds, duration / max(seconds, 0.001), text))
            if n < expected.count {
                let rate = wer(text, expected[n])
                totalWER += rate
                print(String(format: "  WER %.1f%%  expected: %@", rate * 100, expected[n]))
            }
        }
        if !expected.isEmpty { print(String(format: "\nmean WER %.1f%% over %d clips", totalWER / Double(min(expected.count, audios.count)) * 100, min(expected.count, audios.count))) }
    } catch {
        print("failed: \(error)")
    }
}

guard #available(macOS 15.0, *) else { print("Bark needs macOS 15"); exit(1) }
let semaphore = DispatchSemaphore(value: 0)
Task {
    if #available(macOS 15.0, *) { await run() }
    semaphore.signal()
}
semaphore.wait()
