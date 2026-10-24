import BroskiCore
import SwiftUI
import UIKit

/// One note being written. The draft (text, photos, choices) survives leaving the app, so nothing is lost.
/// Nothing is saved until you tap Save.
@MainActor
final class CaptureModel: ObservableObject {
    @Published var text = "" { didSet { textChanged() } }
    @Published private(set) var attachments: [URL] = []
    @Published var destination: String? = nil { didSet { saveDraft() } }   // nil = decide from the text; "" = Inbox; else a project
    @Published var kind: NoteKind? = nil { didSet { saveDraft() } }
    @Published private(set) var proposal: Interpretation?
    @Published private(set) var thinking = false
    @Published private(set) var saving = false
    @Published var toast: Toast?
    /// Bumped to bring up the keyboard (from "New Broski note").
    @Published var focusRequest = 0

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var detail: String
        var undo: Item?
    }

    private let store: PhoneStore
    private var proposalTask: Task<Void, Never>?
    private static let draftText = "BroskiDraftText"
    private static let draftFiles = "BroskiDraftFiles"
    private static let draftDestination = "BroskiDraftDestination"
    private static let draftKind = "BroskiDraftKind"

    static var draftsFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    init(store: PhoneStore) {
        self.store = store
        text = UserDefaults.standard.string(forKey: Self.draftText) ?? ""
        attachments = (UserDefaults.standard.stringArray(forKey: Self.draftFiles) ?? [])
            .map { Self.draftsFolder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        destination = UserDefaults.standard.string(forKey: Self.draftDestination)
        kind = UserDefaults.standard.string(forKey: Self.draftKind).flatMap { NoteKind(rawValue: $0) }
        // Setting `text` here doesn't run didSet: without this, the plan line wouldn't match what Save does.
        if !trimmed.isEmpty { proposal = Rules.interpret(trimmed, catalog: store.catalog, activeSession: store.activeSession) }
    }

    var hasContent: Bool { !trimmed.isEmpty || !attachments.isEmpty }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Editing

    func addSpoken(_ spoken: String) {
        let heard = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return }
        let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            text = heard
        } else if current.split(separator: "\n", omittingEmptySubsequences: false).last?.hasPrefix(">") == true {
            // After a pasted quote, what you say is yours: a new paragraph, not more of the quote.
            text = current + "\n\n" + heard
        } else if text.hasSuffix("\n") {
            // You started a new line: the words go on it.
            text += heard
        } else {
            text = TextTools.joinPhrase(current, heard)
        }
    }

    func addImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        addImageData(data, ext: "jpg")
    }

    func addImageData(_ data: Data, ext: String) {
        let url = Self.draftsFolder.appendingPathComponent("\(UUID().uuidString).\(ext)")
        guard (try? data.write(to: url)) != nil else { return }
        attachments.append(url)
        saveDraft()
    }

    func remove(_ url: URL) {
        attachments.removeAll { $0 == url }
        try? FileManager.default.removeItem(at: url)
        saveDraft()
    }

    func paste() {
        let board = UIPasteboard.general
        if let image = board.image {
            addImage(image)
        } else if let url = board.url {
            text = trimmed.isEmpty ? url.absoluteString : trimmed + "\n" + url.absoluteString
        } else if let string = board.string, !string.isEmpty {
            let quoted = string.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            text = trimmed.isEmpty ? quoted : trimmed + "\n\n" + quoted
        }
    }

    func discard() {
        attachments.forEach { try? FileManager.default.removeItem(at: $0) }
        attachments = []
        text = ""
        destination = nil
        kind = nil
        proposal = nil
        saveDraft()
    }

    private func textChanged() {
        saveDraft()
        proposalTask?.cancel()
        let text = trimmed
        guard !text.isEmpty else { proposal = nil; return }
        // Rules answer instantly; Claude (if you've added a key) refines it after you pause typing.
        proposal = Rules.interpret(text, catalog: store.catalog, activeSession: store.activeSession)
        guard let key = Keychain.claudeKey, !touchesLocalOnly(text) else { return }
        let catalog = store.catalog
        let session = store.activeSession
        let count = attachments.count
        proposalTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            // The project picked, or the session, can change while waiting: check again right before sending.
            guard !Task.isCancelled, !touchesLocalOnly(text) else { return }
            thinking = true
            defer { thinking = false }
            let request = Interpreter.Request(
                // Claude isn't told local-only projects exist, so it can't file anything into them.
                text: text, spoken: false, projects: catalog.projects.map(\.name).filter { !store.localOnly.contains($0) },
                activeSession: session.map { "\($0.kind.label) “\($0.title)” for \($0.project ?? "the inbox")" },
                context: ItemContext(app: "iPhone"), attachmentCount: count)
            if var result = try? await Interpreter.interpret(request, with: ClaudeClient(apiKey: key)),
               !Task.isCancelled, self.trimmed == text {
                result.project = catalog.match(result.project)?.name ?? result.project
                proposal = result
            }
        }
    }

    /// A capture for a local-only project is filed by the rules, so its text never leaves the phone.
    private func touchesLocalOnly(_ text: String) -> Bool {
        // Without the shared folder there's no config.json to say which projects are local only.
        guard !store.sharedUnavailable else { return true }
        store.refreshLocalOnly()
        return LocalOnly.touches(text, projects: [proposal?.project, destination, store.activeSession?.project],
                                 localOnly: store.localOnly, catalog: store.catalog)
    }

    private func saveDraft() {
        UserDefaults.standard.set(text, forKey: Self.draftText)
        UserDefaults.standard.set(attachments.map(\.lastPathComponent), forKey: Self.draftFiles)
        UserDefaults.standard.set(destination, forKey: Self.draftDestination)
        UserDefaults.standard.set(kind?.rawValue, forKey: Self.draftKind)
    }

    // MARK: Where it goes

    /// "Will save to strado as a bug: “…”"
    var plan: String? {
        guard hasContent else { return nil }
        let p = proposal ?? Interpretation(title: attachments.isEmpty ? "" : "Photo from iPhone")
        if destination == nil {
            switch p.action {
            case "start_session": return "Will start a \((SessionKind(rawValue: p.sessionKind)?.label ?? "session").lowercased())" + (p.project.isEmpty ? "" : " for \(p.project)")
            case "end_session": return "Will wrap up the session and write the report"
            case "cancel": return attachments.isEmpty ? "Will throw this away" : "Will drop the text, keep the photos"
            case "open_dashboard": break
            default:
                if let session = store.activeSession { return "Will add to \(session.title)" }
            }
        }
        let place = destination.map { $0.isEmpty ? "Inbox" : $0 } ?? (p.project.isEmpty ? "Inbox" : p.project)
        let kindName = (kind ?? NoteKind(rawValue: p.kind) ?? .note).label.lowercased()
        let title = p.title.isEmpty ? "" : ": “\(p.title)”"
        return "Will save to \(place) as \(kindName == "idea" ? "an" : "a") \(kindName)\(title)"
    }

    // MARK: Saving

    func save() async {
        guard hasContent, !saving else { return }
        // A note saved while the shared folder is out of reach would be stranded on this iPhone: try it again first.
        if self.store.sharedUnavailable { self.store.reload() }
        guard !self.store.sharedUnavailable else {
            toast = Toast(title: "Couldn't reach the shared folder", detail: "Your note is kept here. Try again in a moment, or pick the folder again in Settings.")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        saving = true
        defer { saving = false }
        // What this save takes. Words and photos added while it runs (the report can take a while) stay in the draft.
        let savedRaw = self.text
        let savedFiles = attachments
        let text = trimmed
        let store = self.store.store
        // As it is on disk now, not as of the last reload: the Mac may have added to the session or wrapped it up.
        let active = store.activeSession()
        var decision = proposal ?? (text.isEmpty
            ? Interpretation(title: "Photo from iPhone")
            : Rules.interpret(text, catalog: self.store.catalog, activeSession: active))
        if let destination {
            decision.action = "note"
            decision.project = destination
        }
        if let kind { decision.kind = kind.rawValue }
        let context = ItemContext(app: "iPhone")
        do {
            switch decision.action {
            case "start_session":
                let kind = SessionKind(rawValue: decision.sessionKind) ?? .qa
                let title = decision.sessionTitle.isEmpty ? "\(kind.label) \(Date().formatted(date: .abbreviated, time: .shortened))" : decision.sessionTitle
                var session = try store.startSession(kind: kind, project: decision.project.isEmpty ? nil : decision.project, title: title)
                if !attachments.isEmpty { session = try store.append(text: "", files: attachments, context: context, to: session) }
                done("\(kind.label) started", "Photos and notes go into it until you say “wrap up”.")
            case "end_session":
                guard var session = active else {
                    self.store.reload()
                    return done("No session is running", "")
                }
                // Photos, and anything said beyond "wrap up", go into the session before it ends, not away with the draft.
                let said = text.isEmpty || Rules.isOnlyEndCommand(text) ? "" : text
                if !said.isEmpty || !attachments.isEmpty { session = try store.append(text: said, files: attachments, context: context, to: session) }
                let ended = try store.endSession(session)
                self.store.refreshLocalOnly()
                try store.writeReport(await Self.report(for: ended, localOnly: self.store.localOnly), for: ended)
                done("Report ready", "\(ended.entries.count) captures from \(ended.title)")
            case "cancel" where !attachments.isEmpty:
                // Only the words go: photos are thrown away only with Discard.
                self.text = ""
                return done("Dropped the text", "Photos kept")
            case "cancel":
                done("Dropped it", "")
            default:
                let body = [decision.title, decision.body].filter { !$0.isEmpty }.joined(separator: "\n")
                if let session = active, destination == nil {
                    // When the rules only split what you said into a title and a body, the entry keeps your words as said.
                    let said = body.isEmpty || body.split(whereSeparator: \.isWhitespace) == text.split(whereSeparator: \.isWhitespace) ? text : body
                    let updated = try store.append(text: text.isEmpty ? "" : said, files: attachments, context: context, to: session)
                    done("Added to \(session.title)", "\(updated.entries.count) captures")
                } else {
                    let item = try store.create(ItemDraft(
                        project: decision.project.isEmpty ? nil : decision.project,
                        kind: NoteKind(rawValue: decision.kind) ?? .note,
                        priority: Priority(rawValue: decision.priority) ?? .normal,
                        tags: decision.tags,
                        title: decision.title.isEmpty ? String(text.prefix(90)) : decision.title,
                        body: decision.body,
                        context: context,
                        attachments: attachments))
                    done(item.title, "\(item.project ?? "Inbox") · \(item.kind.label.lowercased())" + (item.attachments.isEmpty ? "" : " · \(item.attachments.count) photo\(item.attachments.count == 1 ? "" : "s")"), undo: item)
                }
            }
            clearSaved(text: savedRaw, files: savedFiles)
            self.store.reload()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            toast = Toast(title: "Couldn't save", detail: error.localizedDescription)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// Clears what a save took, and only that: words or photos added while it ran stay in the draft.
    private func clearSaved(text savedRaw: String, files savedFiles: [URL]) {
        savedFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        attachments.removeAll { savedFiles.contains($0) }
        if !savedRaw.isEmpty, text.hasPrefix(savedRaw) {
            text = String(text.dropFirst(savedRaw.count).drop(while: \.isWhitespace))
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            destination = nil
            kind = nil
            proposal = nil
        }
        saveDraft()
    }

    func undo(_ item: Item) {
        _ = try? store.store.delete(item)
        store.reload()
        toast = Toast(title: "Undone", detail: "")
    }

    private func done(_ title: String, _ detail: String, undo: Item? = nil) {
        toast = Toast(title: title, detail: detail, undo: undo)
    }

    /// A local-only session's entries and photos stay on the phone: it gets the plain report.
    private static func report(for session: Session, localOnly: Set<String>) async -> String {
        guard let key = Keychain.claudeKey, session.project.map(localOnly.contains) != true else { return ReportWriter.basic(session) }
        let folder = session.folder
        let paths = Array(session.entries.flatMap(\.attachments).prefix(20))
        // Off the main actor: decoding and resizing up to 20 photos would freeze the screen.
        let images = await Task.detached { () -> [String: (data: Data, mediaType: String)] in
            var images: [String: (data: Data, mediaType: String)] = [:]
            for path in paths {
                if let image = UIImage(contentsOfFile: folder.appendingPathComponent(path).path),
                   let jpeg = image.resized(maxSide: 1568).jpegData(compressionQuality: 0.8) {
                    images[path] = (jpeg, "image/jpeg")
                }
            }
            return images
        }.value
        if let report = try? await ReportWriter.write(session, images: images, with: ClaudeClient(apiKey: key)) {
            return report.reportMarkdown
        }
        return ReportWriter.basic(session)
    }
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        guard scale < 1 else { return self }
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        // Scale 1, so maxSide is pixels: the screen's 3x would make a bitmap bigger than the photo itself.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
