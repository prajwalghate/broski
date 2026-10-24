import CryptoKit
import Foundation

/// Underdog Bark 3.0, on-device English speech recognition (CC-BY 4.0, built on NVIDIA's parakeet-tdt-0.6b-v3):
/// its Core ML package for the Apple Neural Engine. https://huggingface.co/ConwayResearch/Underdog-Bark-3.0
/// Every file is pinned to one commit, its size and its SHA-256, so what runs is what was measured.
public enum BarkModel {
    public struct File: Sendable {
        public let path: String
        public let size: Int64
        public let sha256: String
    }

    static let commit = "85db2ad18ab41e534a222ee253c29191d77ed919"
    static let remoteFolder = "coreml/ane/"
    static let package = "BarkEncoder.mlpackage"

    public static let files: [File] = [
        File(path: "\(package)/Manifest.json", size: 617, sha256: "d37c121561b99da49b9bf1e28c00152c14c56a943815fa83008ee0691b8f1149"),
        File(path: "\(package)/Data/com.apple.CoreML/model.mlmodel", size: 1_784_701,
             sha256: "7c3f1c1612ba21bcc4d8efff1b32154b39cb3e1e2f10020117793acc5c96fcdf"),
        File(path: "\(package)/Data/com.apple.CoreML/weights/weight.bin", size: 189_133_632,
             sha256: "98979e5dd731486ddfb2c312f80a3038205c058aac9fe0f403ba26e1a158d385"),
        File(path: "decoder.npz", size: 11_168_286, sha256: "1ce79071f54c3dcec9aa9bb1d488486766f1fdbb3fd988b776da3f4da8024665"),
        File(path: "vocab.json", size: 115_878, sha256: "eee86951e9f74921342fdc60ba26711eb70f7188e8784d98d2aecfc525b72270"),
    ]

    public static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public static func remoteURL(_ file: File) -> URL {
        URL(string: "https://huggingface.co/ConwayResearch/Underdog-Bark-3.0/resolve/\(commit)/\(remoteFolder)\(file.path)")!
    }

    /// ~/Library/Application Support/Broski/models/bark-3.0/
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Broski/models/bark-3.0", isDirectory: true)
    }

    /// Every file is there at its pinned size. (The hashes are checked once, when the download lands.)
    public static func isDownloaded(in directory: URL = directory) -> Bool {
        files.allSatisfy { file in
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file.path).path))?[.size] as? Int64
            return size == file.size
        }
    }

    /// Checks a file against its pinned size and SHA-256, reading it in pieces (the weights are 189 MB).
    public static func verify(_ url: URL, against file: File) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hash = SHA256()
        var total: Int64 = 0
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
            total += Int64(chunk.count)
        }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return total == file.size && hex == file.sha256
    }

    /// Bark credits, as its license asks.
    public static let attribution = "Speech recognition: Underdog Bark 3.0 by Conway Research (CC BY 4.0), built on NVIDIA parakeet-tdt-0.6b-v3 (CC BY 4.0)."
}
