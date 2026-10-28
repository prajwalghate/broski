import Foundation
import Testing
@testable import BroskiCore

/// Before a new version is installed it reads the person's whole Broski folder, without writing anything, so a
/// version that would misread their notes or conversations never replaces one that doesn't.
@Suite("Folder check")
struct FolderCheckTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every file under `root` with its size and modification date, to show nothing was written.
    private func listing(_ root: URL) -> [String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)?.compactMap { $0 as? URL } ?? []
        return files.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return "\(url.path) \(values?.fileSize ?? -1) \(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.sorted()
    }

    @Test("counts what each format reads, and what it can't")
    func counts() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try BroskiConfig.defaults.save(to: root.appendingPathComponent("config.json"))
        let store = ConversationStore(root: root, device: "mac")
        try store.append(Turn(device: "mac", speaker: .you, text: "When do we launch?"))
        try store.append(Turn(device: "mac", speaker: .broski, text: "Friday."))
        let day = try #require(FileManager.default.enumerator(at: root.appendingPathComponent("conversations"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.pathExtension == "jsonl" })
        let handle = try FileHandle(forWritingTo: day)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        try UsageLog.append(UsageLog.Entry(device: "mac", role: .fast, provider: "claude", model: ClaudeModel.fast, project: nil,
                                           usage: ModelUsage(input: 1)), root: root)
        try Memory.remember("Prefers short answers", root: root, device: "mac")
        _ = try ItemStore(root: root).create(ItemDraft(project: nil, kind: .todo, title: "Buy a domain"))

        let report = FolderCheck.run(root: root)
        #expect(report.ok)
        #expect(report.formats["config"] == FolderCheck.Format(files: 1, read: 1, unreadable: 0))
        #expect(report.formats["conversations"] == FolderCheck.Format(files: 1, read: 2, unreadable: 1))
        #expect(report.formats["usage"]?.read == 1 && report.formats["memory"]?.read == 1 && report.formats["notes"]?.read == 1)
    }

    @Test("a config.json that doesn't parse is a problem; a folder that's new is not")
    func configProblems() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FolderCheck.run(root: root).ok)
        try Data("{ \"localOnlyProjects\": [".utf8).write(to: root.appendingPathComponent("config.json"))
        let report = FolderCheck.run(root: root)
        #expect(!report.ok && report.problems.contains { $0.contains("config.json") })
    }

    @Test("reading the folder writes nothing, not even a default config")
    func readOnly() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try ConversationStore(root: root, device: "iphone").append(Turn(device: "iphone", speaker: .you, text: "hi"))
        let before = listing(root)
        _ = FolderCheck.run(root: root)
        #expect(listing(root) == before)
    }

    @Test("the report says nothing of what's in the files")
    func noContent() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try ConversationStore(root: root, device: "mac").append(Turn(device: "mac", speaker: .you, text: "my secret plan"))
        let json = String(decoding: try JSONEncoder().encode(FolderCheck.run(root: root)), as: UTF8.self)
        #expect(!json.contains("secret plan"))
    }
}
