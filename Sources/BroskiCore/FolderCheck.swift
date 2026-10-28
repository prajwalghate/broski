import Foundation

/// Reads the whole Broski folder the way the app does, without writing anything, and counts what each stored format
/// reads and what it can't. `scripts/install-mac.sh` runs it with the installed version and with the new one before
/// replacing anything, and refuses a new version that reads less. The report holds counts only, never content.
public enum FolderCheck {
    public struct Format: Codable, Equatable, Sendable {
        public var files: Int
        public var read: Int
        public var unreadable: Int

        public init(files: Int = 0, read: Int = 0, unreadable: Int = 0) {
            self.files = files
            self.read = read
            self.unreadable = unreadable
        }
    }

    public struct Report: Codable, Equatable, Sendable {
        public var v = 1
        public var root: String
        /// config, projects, conversations, usage, memory, riff rules, notes, change stream, vault.
        public var formats: [String: Format]
        /// What's wrong enough to stop an install (a config.json that doesn't parse).
        public var problems: [String]

        public var ok: Bool { problems.isEmpty }
    }

    public static func run(root: URL) -> Report {
        var formats: [String: Format] = [:]
        var problems: [String] = []

        func file<T: Decodable>(_ type: T.Type, _ name: String, at url: URL, required: Bool) {
            var format = Format()
            if FileManager.default.fileExists(atPath: url.path) {
                format.files = 1
                if let data = try? Data(contentsOf: url), (try? JSONDecoder().decode(T.self, from: data)) != nil {
                    format.read = 1
                } else {
                    format.unreadable = 1
                    if required { problems.append("\(url.lastPathComponent) doesn't parse.") }
                }
            }
            formats[name] = format
        }
        file(BroskiConfig.self, "config", at: root.appendingPathComponent("config.json"), required: true)
        file(ProjectRegistry.self, "projects", at: root.appendingPathComponent(ProjectRegistry.fileName), required: false)
        file(Vault.Header.self, "vault", at: Vault.headerURL(root), required: false)

        let memory = root.appendingPathComponent("memory", isDirectory: true)
        formats["conversations"] = lines(Turn.self, in: jsonl(under: root.appendingPathComponent("conversations", isDirectory: true)))
        formats["usage"] = lines(UsageLog.Entry.self, in: jsonl(under: root.appendingPathComponent("usage", isDirectory: true)))
        formats["memory"] = lines(Memory.Event.self, in: jsonl(under: memory).filter { $0.lastPathComponent.hasPrefix("remembered.") })
        formats["riff rules"] = lines(RiffMode.Event.self, in: jsonl(under: memory).filter { $0.lastPathComponent.hasPrefix("riff-rules.") })
        formats["notes"] = notes(root)
        formats["change stream"] = lines(ChangeEvent.self, in: ChangeStream.streamFiles(root: root, project: nil), decoder: ChangeStream.decoder())
        return Report(root: root.path, formats: formats, problems: problems)
    }

    /// The `.jsonl` files under `folder`, skipping hidden ones (and iCloud's placeholders for files not downloaded yet).
    static func jsonl(under folder: URL) -> [URL] {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
    }

    static func lines<T: Decodable>(_ type: T.Type, in files: [URL], decoder: JSONDecoder = JSONLines.decoder) -> Format {
        var format = Format(files: files.count)
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                format.unreadable += 1
                continue
            }
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if (try? decoder.decode(T.self, from: Data(line.utf8))) != nil { format.read += 1 } else { format.unreadable += 1 }
            }
        }
        return format
    }

    /// Notes in the inbox and every project folder, as the note store reads them.
    static func notes(_ root: URL) -> Format {
        let store = ItemStore(root: root)
        var format = Format()
        for project in [nil] + store.projectNames().map(Optional.some) {
            let folder = store.folder(for: project)
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "md" && $0.lastPathComponent != ProjectPage.fileName }
            format.files += files.count
            for file in files {
                if ItemStore.read(file, project: project) != nil { format.read += 1 } else { format.unreadable += 1 }
            }
        }
        return format
    }
}
