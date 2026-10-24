import BroskiCore
import Foundation

/// Where the iPhone keeps notes, and what's in there.
/// By default a folder on this iPhone (visible in the Files app). Pick the Mac's Broski folder in
/// iCloud Drive and both devices read and write the same markdown files.
@MainActor
final class PhoneStore: ObservableObject {
    @Published private(set) var root: URL
    @Published private(set) var sharedFolderName: String?
    @Published private(set) var items: [Item] = []
    @Published private(set) var projects: [String] = []
    @Published private(set) var activeSession: Session?
    /// Every note and session entry, searchable on the phone.
    @Published private(set) var index = NotesIndex([])
    /// Each project's living page: the Mac's (written by Claude) when the folder is shared, else built here.
    @Published private(set) var pages: [String: ProjectPage] = [:]
    @Published private(set) var downloading = 0
    /// The shared folder is picked but iOS won't open it right now (iCloud Drive still waking up after a reboot).
    /// Saving waits rather than strand notes on this iPhone; every reload tries the folder again.
    @Published private(set) var sharedUnavailable = false
    /// Projects the Mac keeps away from Claude (config.localOnlyProjects); the phone honours them too.
    private(set) var localOnly: Set<String> = []
    @Published var problem: String?

    private static let bookmarkKey = "BroskiFolderBookmark"
    private static let unavailable = "Can't open the shared Broski folder right now, so saving waits. If this doesn't clear up, pick the folder again in Settings."
    /// Folders inside a Broski folder: picking one of these instead of Broski itself makes the Mac see bogus projects.
    private static let innerFolders: Set<String> = ["inbox", "projects", "sessions", "attachments", "shots", ".broski"]
    private var scoped: URL?
    private var recheck: Task<Void, Never>?

    static var localRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Broski", isDirectory: true)
    }

    var store: ItemStore { ItemStore(root: root) }
    var catalog: ProjectCatalog { ProjectCatalog(projects: projects.map { Project(name: $0) }) }
    var isShared: Bool { sharedFolderName != nil }

    init() {
        root = Self.localRoot
        if UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil, !openBookmark() {
            // Not a quiet switch to this iPhone's folder: notes saved there would never reach the Mac.
            sharedUnavailable = true
            problem = Self.unavailable
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    /// Opens the remembered shared folder; false when iOS won't resolve it right now.
    private func openBookmark() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return false }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return false }
        scoped = url
        root = url
        sharedFolderName = url.lastPathComponent
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey) }
        return true
    }

    /// The folder picked in Files (iCloud Drive › Broski). Remembered across launches.
    func useFolder(_ url: URL) {
        guard !Self.innerFolders.contains(url.lastPathComponent) else {
            problem = "That's a folder inside Broski. Pick the Broski folder itself."
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            problem = "iOS didn't allow access to that folder. Try picking it again."
            return
        }
        do {
            let bookmark = try url.bookmarkData()
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        } catch {
            url.stopAccessingSecurityScopedResource()
            problem = "Couldn't remember that folder: \(error.localizedDescription)"
            return
        }
        scoped?.stopAccessingSecurityScopedResource()
        scoped = url
        root = url
        sharedFolderName = url.lastPathComponent
        sharedUnavailable = false
        problem = nil
        reload()
    }

    func useLocal() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        sharedUnavailable = false
        if problem == Self.unavailable { problem = nil }
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        root = Self.localRoot
        sharedFolderName = nil
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        if sharedUnavailable, openBookmark() {
            sharedUnavailable = false
            if problem == Self.unavailable { problem = nil }
        }
        downloading = requestDownloads()
        let store = store
        items = store.allItems().sorted { $0.updated > $1.updated }
        projects = store.projectNames().sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        activeSession = store.activeSession()
        refreshLocalOnly()
        let sessions = store.allSessions()
        index = NotesIndex(items: items, sessions: sessions)
        var fresh: [String: ProjectPage] = [:]
        for project in projects {
            // The phone reads pages; it doesn't write them, so it never fights the Mac over PROJECT.md.
            if let page = ProjectPage.load(project, from: store) {
                fresh[project] = page
            } else {
                let projectItems = items.filter { $0.project == project }
                guard !projectItems.isEmpty else { continue }
                fresh[project] = ProjectPageBuilder.rules(project: project, refs: index.refs.filter { $0.project == project },
                                                          items: projectItems, sessions: sessions.filter { $0.project == project })
            }
        }
        pages = fresh
        // Nothing tells the app when iCloud finishes a download: look again shortly while notes are still coming.
        recheck?.cancel()
        if downloading > 0 {
            recheck = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                reload()
            }
        }
    }

    func item(id: String) -> Item? { items.first { $0.id == id } }

    func ask(_ question: String) async throws -> Ask.Answer {
        // Re-read: the Mac may have marked a project local only since the last reload.
        refreshLocalOnly()
        let localOnly = localOnly
        return try await Ask.answer(question, index: index, catalog: catalog,
                                    pages: pages.values.filter { !localOnly.contains($0.project) },
                                    client: Keychain.claudeKey.map { ClaudeClient(apiKey: $0) }, localOnly: localOnly)
    }

    private static let unreadableConfig = "config.json on the Mac couldn't be read, so Claude is off for your projects until it's fixed."

    /// Re-reads config.json; callers about to send a project's text to Claude call this first.
    func refreshLocalOnly() {
        let (names, readable) = Self.localOnlyProjects(in: root, projects: projects)
        localOnly = names
        // Failing closed silently would just look like Claude stopped answering, so say why.
        if !readable {
            problem = Self.unreadableConfig
        } else if problem == Self.unreadableConfig {
            problem = nil
        }
    }

    /// The local-only list from the shared config.json, read without ever writing it: loadOrCreate would drop a
    /// defaults file into iCloud and race the Mac. A file iCloud hasn't fetched yet, or one that won't parse,
    /// counts every project as local only, so nothing slips out to Claude meanwhile. `readable` is false only
    /// for a file that's there but won't parse (a pending download isn't the user's to fix).
    private static func localOnlyProjects(in root: URL, projects: [String]) -> (names: Set<String>, readable: Bool) {
        let fm = FileManager.default
        let url = root.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: url.path) else {
            let pending = fm.fileExists(atPath: root.appendingPathComponent(".config.json.icloud").path)
            return (pending ? Set(projects) : [], true)
        }
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(BroskiConfig.self, from: data) else { return (Set(projects), false) }
        return (Set(config.localOnlyProjects), true)
    }

    func items(in project: String?) -> [Item] {
        items.filter { $0.project == project }
    }

    /// iCloud keeps files it hasn't fetched yet as hidden ".name.md.icloud" stubs. Ask for them (not the trash in
    /// .broski), and count the notes, pages and config still coming: photos can arrive later without holding up the list.
    private func requestDownloads() -> Int {
        guard isShared, let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".broski" {
                walker.skipDescendants()
                continue
            }
            guard name.hasPrefix("."), name.hasSuffix(".icloud") else { continue }
            let realName = String(name.dropFirst().dropLast(7))
            try? FileManager.default.startDownloadingUbiquitousItem(at: url.deletingLastPathComponent().appendingPathComponent(realName))
            if realName.hasSuffix(".md") || realName.hasSuffix(".json") { count += 1 }
        }
        return count
    }
}
