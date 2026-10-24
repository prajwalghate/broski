import Foundation
import Testing
@testable import BroskiCore

/// Phase 3: what you share is kept with its project, a new project can start from a conversation, and trackers grow
/// by packs that are data, not code.
@Suite("Resources, new projects and packs")
struct ProjectsTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let day = ISO8601DateFormatter().date(from: "2026-10-24T10:00:00Z")!

    // MARK: Resources

    @Test("a shared file is copied into the project's resources with a dated, unique name")
    func addResource() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("chart.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
        let first = try Resources.add(file: source, project: "strado", root: root, date: day)
        let second = try Resources.add(file: source, project: "strado", root: root, date: day)
        let loose = try Resources.add(file: source, project: nil, root: root, date: day)
        #expect(first == "projects/strado/resources/2026-10-24-chart.png")
        #expect(second == "projects/strado/resources/2026-10-24-chart-2.png")
        #expect(loose == "inbox/resources/2026-10-24-chart.png")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(first).path))
        #expect(FileManager.default.fileExists(atPath: source.path), "the original stays where it was")
    }

    @Test("links are found in what you say and listed with the project's files, newest first")
    func linksAndListing() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let links = Resources.links(in: "Like this app https://example.com/workout and docs at http://docs.example.org/api, not ftp")
        #expect(links.map(\.absoluteString) == ["https://example.com/workout", "http://docs.example.org/api"])
        try Resources.record(links: links, project: "setlog", turn: "t1", root: root, device: "mac", date: day)
        let pdf = root.appendingPathComponent("spec.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        _ = try Resources.add(file: pdf, project: "setlog", root: root, date: day.addingTimeInterval(60))
        let listed = Resources.list(root: root, project: "setlog")
        #expect(listed.map(\.kind) == [.pdf, .link, .link])
        #expect(listed.first?.name == "2026-10-24-spec.pdf")
        #expect(listed.contains { $0.name == "https://example.com/workout" })
    }

    @Test("attachments become what the model reads: images, PDFs, text files, and a line for anything else")
    func modelParts() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let files: [(String, Data)] = [("a.png", Data([1, 2])), ("b.pdf", Data("%PDF".utf8)), ("c.md", Data("# Plan\nShip it.".utf8)),
                                       ("d.zip", Data([0, 0]))]
        var paths: [String] = []
        for (name, data) in files {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("inbox/resources"), withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent("inbox/resources/\(name)"))
            paths.append("inbox/resources/\(name)")
        }
        let parts = Resources.parts(for: paths, root: root)
        #expect(parts.count == 4)
        if case .image(_, let type) = parts[0] { #expect(type == "image/png") } else { Issue.record("not an image") }
        if case .pdf = parts[1] {} else { Issue.record("not a PDF") }
        if case .text(let text) = parts[2] { #expect(text.contains("<file name=\"c.md\">") && text.contains("Ship it.")) } else { Issue.record("not text") }
        if case .text(let text) = parts[3] { #expect(text.contains("d.zip")) } else { Issue.record("no line for the zip") }
    }

    @Test("attachments ride on your latest message, after its text")
    func attachmentsInContext() {
        let turn = Turn(device: "mac", speaker: .you, text: "What's wrong in this chart?")
        let request = ConversationContext.build(aboutYou: nil, page: nil, project: nil, turns: [turn], isPrivate: false,
                                                attachments: [.image(Data([1]), mediaType: "image/png")])
        #expect(request.messages.last?.parts.count == 2)
        #expect(request.needs.contains(.images))
        if case .text(let text) = request.messages.last?.parts.first { #expect(text == "What's wrong in this chart?") } else { Issue.record("text first") }
    }

    // MARK: New projects

    @Test("the review can propose a new project; an empty name means none")
    func proposal() throws {
        let json = #"{"project":"","topic":"gym logging","items":[],"new_project":{"name":"Set Log","summary":"Log gym sets by voice on the iPhone.","packs":["mobile","ai","spaceship"],"goals":["Parse a spoken set offline"],"questions":["Kilos only?"]}}"#
        let proposal = try #require(ProjectProposal.from(json))
        #expect(proposal.name == "Set Log" && proposal.slug == "set-log")
        #expect(proposal.packs == ["mobile", "ai"])
        #expect(ProjectProposal.from(#"{"new_project":{"name":"","summary":"","packs":[],"goals":[],"questions":[]}}"#) == nil)
    }

    @Test("creating a project sets up its folder, tracker, packs, registry entry, first note and setup drafts")
    func createProject() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = ProjectProposal(name: "Set Log", summary: "Log gym sets by voice on the iPhone.", packs: ["mobile", "ai"],
                                       goals: ["Parse a spoken set offline"], questions: ["Kilos only?"])
        let id = try ProjectSetup.create(proposal, root: root, date: day)
        #expect(id == "set-log")
        let base = root.appendingPathComponent("projects/set-log")
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("tracker/TRACKER.md").path))
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("tracker/layers/builds/README.md").path))
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("tracker/layers/evals/README.md").path))
        let claude = try String(contentsOf: base.appendingPathComponent("setup/CLAUDE.md"), encoding: .utf8)
        #expect(claude.contains("Set Log") && claude.contains("Parse a spoken set offline"))
        let center = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("setup/command-center.json"))) as? [String: Any]
        #expect(center?["packs"] as? [String] == ["core", "mobile", "ai"])
        let entry = ProjectRegistry.load(from: root).entry(notes: "set-log")
        #expect(entry?.name == "Set Log" && entry?.trackers.first?.readOnly == false)
        #expect(ItemStore(root: root).allItems().contains { $0.project == "set-log" && $0.title.contains("Set Log") })
        #expect(throws: ProjectSetup.Failure.exists("set-log")) { try ProjectSetup.create(proposal, root: root, date: day) }
    }

    // MARK: Packs

    @Test("built-in packs, your own packs overriding them, and packs suggested from a repo")
    func packs() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Packs.builtIn.map(\.id) == ["core", "web", "web3", "ai", "mobile", "personal"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("packs"), withIntermediateDirectories: true)
        let mine = #"{"v":1,"id":"web3","name":"Web3 (mine)","about":"","sections":[{"id":"audits","title":"Audits","about":"Every audit."}],"widgets":[]}"#
        try mine.write(to: root.appendingPathComponent("packs/web3.json"), atomically: true, encoding: .utf8)
        #expect(Packs.all(root: root).first { $0.id == "web3" }?.name == "Web3 (mine)")

        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "".write(to: repo.appendingPathComponent("foundry.toml"), atomically: true, encoding: .utf8)
        try "".write(to: repo.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        #expect(Packs.suggest(forFolder: repo) == ["web3", "mobile"])
    }
}
