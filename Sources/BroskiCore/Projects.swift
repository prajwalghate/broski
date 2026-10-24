import Foundation

// MARK: Resources

/// Something kept with a project: a file you shared, or a link you mentioned.
public struct Resource: Equatable, Sendable {
    public enum Kind: String, Sendable { case image, pdf, text, file, link }

    public var kind: Kind
    /// The file's name, or the link itself.
    public var name: String
    /// Inside the Broski folder, for files.
    public var path: String?
    public var date: Date
}

/// What you share in a conversation, kept with its project (`projects/strado/resources/2026-10-24-chart.png`), and
/// turned into what a model can read.
public enum Resources {
    static func relative(_ project: String?) -> String {
        project.map { "projects/\($0)/resources" } ?? "inbox/resources"
    }

    static func folder(root: URL, project: String?) -> URL {
        root.appendingPathComponent(relative(project), isDirectory: true)
    }

    static func kind(of name: String) -> Resource.Kind {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp": return .image
        case "pdf": return .pdf
        case "md", "markdown", "txt", "json", "csv", "yml", "yaml", "swift", "py", "js", "ts", "tsx", "html", "css", "sql", "toml", "sol":
            return .text
        default: return .file
        }
    }

    static func mediaType(of name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// Copies a file into the project's resources under a dated name that doesn't clash, and returns its path inside
    /// the Broski folder. The original is left where it was.
    public static func add(file: URL, project: String?, root: URL, date: Date = Date()) throws -> String {
        let folder = folder(root: root, project: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let day = ConversationStore.dayKey(date)
        let base = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ":", with: "-")
        let ext = file.pathExtension.isEmpty ? "" : "." + file.pathExtension
        var name = "\(day)-\(base)\(ext)"
        var copy = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(day)-\(base)-\(copy)\(ext)"
            copy += 1
        }
        try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(name))
        return relative(project) + "/" + name
    }

    /// Web links in what was said.
    public static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    struct LinkRecord: Codable {
        var v: Int
        var at: Date
        var device: String
        var url: String
        var project: String?
        var turn: String?
    }

    /// Keeps links with the project, one file per device (`links.mac.jsonl`).
    public static func record(links: [URL], project: String?, turn: String?, root: URL, device: String, date: Date = Date()) throws {
        let file = folder(root: root, project: project).appendingPathComponent("links.\(device).jsonl")
        for link in links {
            try JSONLines.append(LinkRecord(v: 1, at: date, device: device, url: link.absoluteString, project: project, turn: turn), to: file)
        }
    }

    /// A project's files and links, newest first.
    public static func list(root: URL, project: String?) -> [Resource] {
        let folder = folder(root: root, project: project)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [Resource] = []
        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix("links."), url.pathExtension == "jsonl" {
                out += JSONLines.read(LinkRecord.self, from: url).map { Resource(kind: .link, name: $0.url, path: nil, date: $0.at) }
            } else if !name.hasPrefix(".") {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                out.append(Resource(kind: kind(of: name), name: name, path: relative(project) + "/" + name, date: date))
            }
        }
        return out.sorted { $0.date == $1.date ? $0.name < $1.name : $0.date > $1.date }
    }

    /// What a model reads for each attachment: images and PDFs as themselves, text files fenced as data, and a line
    /// naming anything else (or anything too large to send).
    public static func parts(for paths: [String], root: URL) -> [ModelPart] {
        parts(forFiles: paths.map { root.appendingPathComponent($0) })
    }

    /// The same for files outside the Broski folder (a private conversation keeps nothing, so nothing is copied).
    public static func parts(forFiles urls: [URL]) -> [ModelPart] {
        urls.map { url in
            let name = url.lastPathComponent
            let kept = "\(name) is kept in the project's resources"
            guard let data = try? Data(contentsOf: url) else { return .text("(\(name) couldn't be read.)") }
            switch kind(of: name) {
            case .image:
                return data.count <= 5_000_000 ? .image(data, mediaType: mediaType(of: name)) : .text("(The image \(kept); it's too large to send.)")
            case .pdf:
                return data.count <= 30_000_000 ? .pdf(data) : .text("(The PDF \(kept); it's too large to send.)")
            case .text:
                guard data.count <= 200_000, let text = String(data: data, encoding: .utf8) else { return .text("(The file \(kept); it's too large to send.)") }
                return .text("<file name=\"\(name)\">\n\(text)\n</file>")
            case .file, .link:
                return .text("(Attached: \(name), kept in the project's resources.)")
            }
        }
    }
}

// MARK: New projects

/// A project Broski proposes when you describe something new to build: name, one line, packs, first goals and open
/// questions. Nothing is created until you tap Create.
public struct ProjectProposal: Equatable, Sendable {
    public var name: String
    public var summary: String
    public var packs: [String]
    public var goals: [String]
    public var questions: [String]

    public init(name: String, summary: String, packs: [String] = [], goals: [String] = [], questions: [String] = []) {
        self.name = name
        self.summary = summary
        self.packs = packs
        self.goals = goals
        self.questions = questions
    }

    /// The project's folder name: "Set Log" → "set-log".
    public var slug: String { Self.slugify(name) }

    static func slugify(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
    }

    /// The `new_project` part of the review JSON; nil when it has no name.
    public static func from(_ json: String) -> ProjectProposal? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let raw = object["new_project"] as? [String: Any] else { return nil }
        func clean(_ value: Any?) -> String { ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func list(_ value: Any?) -> [String] { ((value as? [Any]) ?? []).map(clean).filter { !$0.isEmpty }.prefix(5).map { $0 } }
        let name = clean(raw["name"])
        guard !name.isEmpty, !slugify(name).isEmpty else { return nil }
        let known = Set(Packs.builtIn.map(\.id)).subtracting(["core"])
        return ProjectProposal(name: name, summary: clean(raw["summary"]), packs: list(raw["packs"]).filter(known.contains),
                               goals: list(raw["goals"]), questions: list(raw["questions"]))
    }
}

/// Sets up a new project in the Broski folder: its notes folder, a tracker Broski keeps (core sections plus its packs),
/// an entry in projects.json, a first note from the conversation, and setup drafts (`setup/`) that Claude Code can
/// apply to a repo later. Repos are never touched.
public enum ProjectSetup {
    public enum Failure: Error, Equatable, LocalizedError {
        case exists(String)
        case badName
        case noFolder(String)

        public var errorDescription: String? {
            switch self {
            case .exists(let id): return "There's already a project called \(id). Pick another name."
            case .badName: return "That name has no letters or digits to make a folder from."
            case .noFolder(let path): return "There's no folder at \(path)."
            }
        }
    }

    /// What connecting a repo found.
    public struct Connection: Equatable, Sendable {
        /// Packs that fit, from the repo's files.
        public var packs: [String]
        /// The tracker shape found in the repo, read in place from now on; nil when it has only plain docs.
        public var tracker: String?
    }

    /// Adds a code folder to a project (creating its entry if needed), and reads a tracker found there in place,
    /// read-only. Broski never writes to the repo.
    @discardableResult
    public static func connect(folder: URL, project: String, root: URL) throws -> Connection {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw Failure.noFolder(folder.path)
        }
        let path = folder.standardizedFileURL.path
        let source = TrackerSource(id: project, name: project, path: path, readOnly: true)
        let shape = TrackerPresets.detect(source).adapter
        let tracker = shape == "generic-markdown" ? nil : shape
        var registry = ProjectRegistry.load(from: root)
        var entry = registry.entry(notes: project) ?? ProjectRegistry.Entry(name: project, notes: project)
        if !entry.folders.contains(path) { entry.folders.append(path) }
        if tracker != nil, !entry.trackers.contains(where: { $0.path == path }) { entry.trackers.append(source) }
        if let index = registry.projects.firstIndex(where: { $0.notes == project }) {
            registry.projects[index] = entry
        } else {
            registry.projects.append(entry)
        }
        try registry.save(to: root)
        return Connection(packs: Packs.suggest(forFolder: folder), tracker: tracker)
    }

    @discardableResult
    public static func create(_ proposal: ProjectProposal, root: URL, date: Date = Date()) throws -> String {
        let id = proposal.slug
        guard !id.isEmpty else { throw Failure.badName }
        let base = root.appendingPathComponent("projects/\(id)", isDirectory: true)
        var registry = ProjectRegistry.load(from: root)
        guard !FileManager.default.fileExists(atPath: base.path), registry.entry(notes: id) == nil else { throw Failure.exists(id) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let packs = Packs.resolve(["core"] + proposal.packs, root: root)
        let tracker = try TrackerTemplate.create(project: id, title: proposal.name, about: proposal.summary, root: root, date: date)
        try Packs.apply(packs, to: tracker)

        let setup = base.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: setup.appendingPathComponent("prompts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: setup.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try claudeMD(proposal, packs: packs, date: date).write(to: setup.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let center: [String: Any] = ["v": 1, "project": id, "packs": packs.map(\.id),
                                     "widgets": packs.flatMap(\.widgets).map { ["id": $0.id, "title": $0.title, "shows": $0.shows] }]
        try JSONSerialization.data(withJSONObject: center, options: [.prettyPrinted, .sortedKeys])
            .write(to: setup.appendingPathComponent("command-center.json"))
        try "Prompts this project uses, one file each, versioned with the project.\n"
            .write(to: setup.appendingPathComponent("prompts/README.md"), atomically: true, encoding: .utf8)
        try "Claude Code agent definitions for this project, one file each (`<name>.md`).\n"
            .write(to: setup.appendingPathComponent("agents/README.md"), atomically: true, encoding: .utf8)

        registry.projects.append(ProjectRegistry.Entry(name: proposal.name, notes: id, about: proposal.summary,
                                                       trackers: [TrackerSource(id: id, name: proposal.name, path: tracker.path, readOnly: false)]))
        try registry.save(to: root)

        var body = proposal.summary
        if !proposal.goals.isEmpty { body += "\n\n**First goals**\n" + proposal.goals.map { "- \($0)" }.joined(separator: "\n") }
        if !proposal.questions.isEmpty { body += "\n\n**Open questions**\n" + proposal.questions.map { "- \($0)" }.joined(separator: "\n") }
        _ = try ItemStore(root: root).create(ItemDraft(project: id, kind: .idea, tags: ["project-start"],
                                                       title: "\(proposal.name): \(proposal.summary)", body: body,
                                                       context: ItemContext(app: "Broski conversation")))
        return id
    }

    static func claudeMD(_ proposal: ProjectProposal, packs: [Pack], date: Date) -> String {
        var text = "# \(proposal.name)\n\n\(proposal.summary)\n"
        if !proposal.goals.isEmpty { text += "\n## Goals\n\n" + proposal.goals.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !proposal.questions.isEmpty { text += "\n## Open questions\n\n" + proposal.questions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        text += """

        ## How to work here

        - Broski keeps this project's tracker. Read it before starting, and record decisions and work items there (through \
        Broski), not in this file.
        - Write the test first, keep changes small, and say what you checked.
        - Keep secrets out of the repo.

        """
        let sections = packs.flatMap(\.sections)
        if !sections.isEmpty {
            text += "\n## What this project tracks\n\n" + sections.map { "- \($0.title): \($0.about)" }.joined(separator: "\n") + "\n"
        }
        text += "\n_Drafted by Broski on \(ConversationStore.dayKey(date)). Ask Claude Code to apply Broski's setup when the repo exists._\n"
        return text
    }
}

// MARK: Packs

/// What a kind of project adds to its tracker and command center, as data: sections (tracker layers) and widgets.
public struct Pack: Codable, Equatable, Sendable {
    public struct Section: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var about: String
    }

    public struct Widget: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// What it shows, in words (the command center lays it out).
        public var shows: String
    }

    public var v: Int
    public var id: String
    public var name: String
    public var about: String
    public var sections: [Section]
    public var widgets: [Widget]
}

public enum Packs {
    private static func pack(_ id: String, _ name: String, _ about: String, _ sections: [(String, String, String)],
                             _ widgets: [(String, String, String)]) -> Pack {
        Pack(v: 1, id: id, name: name, about: about, sections: sections.map { Pack.Section(id: $0.0, title: $0.1, about: $0.2) },
             widgets: widgets.map { Pack.Widget(id: $0.0, title: $0.1, shows: $0.2) })
    }

    public static let builtIn: [Pack] = [
        pack("core", "Core", "Every project: goals, work items, decisions, findings and risks, milestones, threads.", [],
             [("open", "Open now", "Open todos and bugs, newest first"), ("decisions", "Recent decisions", "The latest decisions, with dates"),
              ("milestone", "Next milestone", "The next milestone and its exit criteria")]),
        pack("web", "Web app", "Sites and web apps.",
             [("deploys", "Deploys", "Each deploy: when, what, where, and whether it rolled back."),
              ("environments", "Environments", "Production, staging and preview: their addresses and settings."),
              ("uptime", "Uptime", "Incidents and outages, with how long they lasted."),
              ("analytics", "Analytics", "The numbers that say whether it's working.")],
             [("deploy", "Last deploy", "When and what shipped last"), ("traffic", "Errors and traffic", "Once a source is connected")]),
        pack("web3", "Web3", "Contracts and on-chain systems.",
             [("contracts", "Contracts", "Each contract: what it does, its version, where it's deployed."),
              ("audits", "Audits", "Audit findings and their responses."),
              ("deployments", "Chain deployments", "Addresses by chain and network."),
              ("keys", "Keys and multisigs", "Who holds which key, and the signing ceremony.")],
             [("findings", "Open audit findings", "By severity"), ("contract-map", "Where each contract is deployed", "By chain")]),
        pack("ai", "AI", "Products built on models.",
             [("evals", "Evals", "Each eval: what it checks and its latest score."),
              ("prompts", "Prompts", "The prompts in use, versioned."),
              ("models", "Models and spend", "Which model does what, and what it costs.")],
             [("evals", "Eval scores", "Latest score per eval"), ("spend", "Model spend", "This month, by model")]),
        pack("mobile", "Mobile", "iPhone and Android apps.",
             [("builds", "Builds and TestFlight", "Each build: version, where it went, what changed."),
              ("review", "Store review", "Submissions and the store's answers.")],
             [("build", "Latest build", "Version and where it is"), ("review", "Review status", "The latest submission")]),
        pack("personal", "Personal", "Habits, routines and goals of your own.",
             [("habits", "Habits", "What you're building into your days."), ("routines", "Routines", "Recurring plans and how they went.")],
             [("week", "This week", "What's planned and done"), ("streaks", "Streaks", "Habits kept, day by day")]),
    ]

    /// The built-in packs, with your own (`packs/<id>.json`) replacing a built-in of the same id or adding new ones.
    public static func all(root: URL) -> [Pack] {
        let folder = root.appendingPathComponent("packs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let mine = files.filter { $0.pathExtension == "json" }.compactMap { url -> Pack? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Pack.self, from: data)
        }
        var packs = builtIn.map { pack in mine.first { $0.id == pack.id } ?? pack }
        packs += mine.filter { pack in !builtIn.contains { $0.id == pack.id } }
        return packs
    }

    /// The packs for these ids, in order, each once; unknown ids are left out.
    public static func resolve(_ ids: [String], root: URL) -> [Pack] {
        let available = all(root: root)
        var seen: Set<String> = []
        return ids.compactMap { id in
            guard !seen.contains(id), let pack = available.first(where: { $0.id == id }) else { return nil }
            seen.insert(id)
            return pack
        }
    }

    /// Adds each pack section to a Broski tracker as a layer (`layers/<section>/README.md`); existing files are kept.
    public static func apply(_ packs: [Pack], to tracker: URL) throws {
        for section in packs.flatMap(\.sections) {
            let folder = tracker.appendingPathComponent("layers/\(section.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let readme = folder.appendingPathComponent("README.md")
            if !FileManager.default.fileExists(atPath: readme.path) {
                try "# \(section.title)\n\n\(section.about)\n".write(to: readme, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Packs that fit a repo, from the files at its top: web, web3, ai, mobile.
    public static func suggest(forFolder folder: URL) -> [String] {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        func has(_ any: [String]) -> Bool { any.contains { names.contains($0) } }
        func hasSuffix(_ suffix: String) -> Bool { names.contains { $0.hasSuffix(suffix) } }
        var out: [String] = []
        if has(["package.json", "next.config.js", "next.config.mjs", "next.config.ts", "vite.config.ts", "vite.config.js", "index.html"]) { out.append("web") }
        if has(["foundry.toml", "hardhat.config.js", "hardhat.config.ts", "daml.yaml", "Anchor.toml", "Move.toml", "contracts"]) || hasSuffix(".sol") {
            out.append("web3")
        }
        if has(["evals", "prompts"]) { out.append("ai") }
        if has(["project.yml", "Podfile", "android", "pubspec.yaml", "app.json"]) || hasSuffix(".xcodeproj") { out.append("mobile") }
        return out
    }
}
