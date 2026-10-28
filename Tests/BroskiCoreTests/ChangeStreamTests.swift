import Foundation
import Testing
@testable import BroskiCore

/// The change stream on disk: each device appends to its own `projects/<p>/stream.<device>.jsonl`, so iCloud never
/// merges two writers; reading merges every device's file, and the shared `stream.jsonl` older versions wrote.
@Suite("Change stream files")
struct ChangeStreamTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-25T10:00:00Z")!

    private func event(_ kind: String, _ title: String, at offset: TimeInterval = 0, project: String = "strado",
                       source: String = "strado") -> ChangeEvent {
        ChangeEvent(at: now.addingTimeInterval(offset), project: project, source: source, kind: kind, id: "\(project):x/\(title)", title: title)
    }

    private func streamFiles(_ root: URL, _ project: String) -> [String] {
        let folder = root.appendingPathComponent("projects/\(project)", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("stream") }.sorted()
    }

    private func lines(_ root: URL, _ path: String) -> Int {
        ((try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    @Test("what a device appends reads back the same, oldest first, from its own file")
    func roundTrip() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let read = [
            ChangeEvent(at: now, project: "strado", source: "strado", revision: "a1b2c3d", kind: "closed", id: "strado:STR-12",
                        title: "Fill price drifts", from: "open", to: "solved"),
            ChangeEvent(at: now, project: "strado", source: "strado", revision: "a1b2c3d", kind: "new", id: "strado:STR-13",
                        title: "Slippage on exits"),
        ]
        try ChangeStream.append(read, root: root, project: "strado", device: "mac")
        let later = event("attested", "Go-live checklist", at: 60)
        try ChangeStream.append([later], root: root, project: "strado", device: "mac")

        #expect(ChangeStream.read(root: root, project: "strado") == read + [later])
        #expect(ChangeStream.read(root: root, project: "strado", since: now.addingTimeInterval(30)) == [later])
        #expect(streamFiles(root, "strado") == ["stream.mac.jsonl"])
        let text = try String(contentsOf: root.appendingPathComponent("projects/strado/stream.mac.jsonl"), encoding: .utf8)
        #expect(text.split(separator: "\n").allSatisfy { $0.contains(#""v":1"#) }, "each line says its format's version")
    }

    @Test("two devices write two files, and reading merges them in time order")
    func twoDevices() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // The Mac's tracker reads and a decision saved on the iPhone, interleaved in time.
        try ChangeStream.append([event("closed", "Fill price drifts", at: 0)], root: root, project: "strado", device: "mac")
        try ChangeStream.append([event("decided", "Paper-trade a week first", at: 10, source: "broski")], root: root, project: "strado", device: "iphone")
        try ChangeStream.append([event("reopened", "Fill price drifts", at: 20)], root: root, project: "strado", device: "mac")
        try ChangeStream.append([event("new", "Backtest", at: 15, project: "trader", source: "trader")], root: root, project: "trader", device: "iphone")

        #expect(streamFiles(root, "strado") == ["stream.iphone.jsonl", "stream.mac.jsonl"])
        #expect(lines(root, "projects/strado/stream.mac.jsonl") == 2 && lines(root, "projects/strado/stream.iphone.jsonl") == 1)
        #expect(ChangeStream.read(root: root, project: "strado").map(\.kind) == ["closed", "decided", "reopened"])
        #expect(ChangeStream.read(root: root, project: nil).map(\.kind) == ["closed", "decided", "new", "reopened"])
        #expect(ChangeStream.read(root: root, project: nil, since: now.addingTimeInterval(12)).map(\.kind) == ["new", "reopened"])

        // Lines keep the second, so two devices tie: the order is the files' names, whichever was written first.
        try ChangeStream.append([event("status", "On the Mac", at: 30)], root: root, project: "strado", device: "mac")
        try ChangeStream.append([event("decided", "On the iPhone", at: 30, source: "broski")], root: root, project: "strado", device: "iphone")
        #expect(ChangeStream.read(root: root, project: "strado").suffix(2).map(\.title) == ["On the iPhone", "On the Mac"])
    }

    @Test("the shared stream.jsonl an older version wrote is still read, merged with the devices' files, and left as it was")
    func oldSharedStream() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("projects/strado", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // As Mac 0.11.0 and iPhone 0.7.0 wrote it: a tracker change, then a decision saved on the iPhone in its time zone.
        let old = """
        {"at":"2026-10-25T09:00:00Z","from":"open","id":"strado:STR-12","kind":"closed","project":"strado","revision":"a1b2c3d","source":"strado","title":"Fill price drifts","to":"solved"}
        {"at":"2026-10-25T11:30:30+02:00","id":"strado:decision/d1","kind":"decided","project":"strado","source":"broski","title":"Paper-trade a week first"}

        """
        try Data(old.utf8).write(to: folder.appendingPathComponent("stream.jsonl"))

        // A Mac event in the same second as the old line comes after it: the old file is read first.
        try ChangeStream.append([event("status", "Fill price drifts", at: -3600), event("reopened", "Fill price drifts", at: 0)],
                                root: root, project: "strado", device: "mac")
        try ChangeStream.append([event("new", "Slippage on exits", at: -2700)], root: root, project: "strado", device: "iphone")

        let read = ChangeStream.read(root: root, project: "strado")
        #expect(read.map(\.kind) == ["closed", "status", "new", "decided", "reopened"])
        #expect(read.first == ChangeEvent(at: ISO8601DateFormatter().date(from: "2026-10-25T09:00:00Z")!, project: "strado", source: "strado",
                                          revision: "a1b2c3d", kind: "closed", id: "strado:STR-12", title: "Fill price drifts",
                                          from: "open", to: "solved"))
        #expect(read.first?.v == 1, "a line from before the stream was versioned reads as version 1")
        let decided = try #require(read.first { $0.id == "strado:decision/d1" })
        #expect(decided.at == ISO8601DateFormatter().date(from: "2026-10-25T09:30:30Z")! && decided.title == "Paper-trade a week first")
        #expect(ChangeStream.read(root: root, project: nil).count == 5)
        #expect(try String(contentsOf: folder.appendingPathComponent("stream.jsonl"), encoding: .utf8) == old, "the old file isn't written again")
    }
}
