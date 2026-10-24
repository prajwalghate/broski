import AVFoundation
import Foundation

/// Gets Bark's files (about 200 MB), each checked against its pinned size and SHA-256, for the Mac and the iPhone.
public enum BarkDownloader {
    public enum Failure: Error, CustomStringConvertible {
        case http(Int), checksum(String)
        public var description: String {
            switch self {
            case .http(let code): return "the server answered \(code)"
            case .checksum(let path): return "\(path) didn't match its checksum"
            }
        }
    }

    /// Downloads every file that isn't already there and intact. `progress` gets 0…1 over all the files.
    public static func download(into directory: URL = BarkModel.directory, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // It can be downloaded again, so it stays out of iCloud and Time Machine backups.
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        var done: Int64 = 0
        for file in BarkModel.files {
            try Task.checkCancellation()
            let target = directory.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) == file.size, BarkModel.verify(target, against: file) {
                done += file.size
                progress(Double(done) / Double(BarkModel.totalBytes))
                continue
            }
            let staged = target.appendingPathExtension("part")
            let base = done
            try await FileFetcher.fetch(BarkModel.remoteURL(file), to: staged) { written in
                progress(Double(base + written) / Double(BarkModel.totalBytes))
            }
            guard BarkModel.verify(staged, against: file) else {
                try? fm.removeItem(at: staged)
                throw Failure.checksum(file.path)
            }
            try? fm.removeItem(at: target)
            try fm.moveItem(at: staged, to: target)
            done += file.size
        }
        progress(1)
    }
}

public extension BarkModel {
    /// Where the encoder compiled for this device is kept.
    static var cache: URL { directory.appendingPathComponent("cache", isDirectory: true) }
    private static var marker: URL { cache.appendingPathComponent("prepared.txt") }

    /// Bark has loaded on this device and this OS version. The first load (and one after an OS update) prepares the
    /// model for the Neural Engine, which takes minutes, so callers use another engine until this is true.
    static var isPrepared: Bool {
        FileManager.default.fileExists(atPath: cache.appendingPathComponent("BarkEncoder.mlmodelc").path)
            && (try? String(contentsOf: marker, encoding: .utf8)) == ProcessInfo.processInfo.operatingSystemVersionString
    }

    static func markPrepared() {
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? ProcessInfo.processInfo.operatingSystemVersionString.write(to: marker, atomically: true, encoding: .utf8)
    }
}

/// Keeps what the mic hears as 16 kHz mono, the way Bark takes it. Fed from the audio thread.
public final class BarkAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// A note longer than this keeps its start; Bark would take too long on it anyway.
    private let limit = 16_000 * 60 * 15

    public init() {}

    public func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        converter = nil
        lock.unlock()
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard samples.count < limit else { return }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    /// Everything kept so far, and clears it.
    public func take() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let all = samples
        samples = []
        converter = nil
        return all
    }

    public var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / 16_000
    }

    /// A whole audio file as 16 kHz mono; nil when it can't be read.
    public static func read(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// One file download with progress. Writes to `destination` (replacing it).
final class FileFetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Error??

    private init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fetcher = FileFetcher(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: fetcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                fetcher.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this returns, so move it now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { outcome = .some(BarkDownloader.Failure.http(status)); return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            outcome = .some(nil)
        } catch {
            outcome = .some(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else if case .some(.some(let failure)) = outcome {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
