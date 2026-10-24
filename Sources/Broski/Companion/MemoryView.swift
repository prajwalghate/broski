import AppKit
import BroskiCore
import SwiftUI

/// What Broski knows: the about-you file, what you asked it to remember (each one forgettable), and every project's
/// decisions with the ones a later decision replaced.
@MainActor
final class MemoryModel: ObservableObject {
    struct DecisionRow: Identifiable, Equatable {
        var id: String
        var date: String
        var text: String
        /// "Replaced Oct 24: Paper-trade a week first"
        var replacedBy: String?
    }

    @Published private(set) var aboutFile = ""
    @Published private(set) var facts: [String] = []
    @Published private(set) var decisions: [(project: String, rows: [DecisionRow])] = []
    @Published private(set) var reflections: [Reflection.LogEntry] = []
    @Published private(set) var lastRun: Date?
    @Published private(set) var reflecting = false
    @Published var reflectStatus: String?
    @Published var problem: String?
    private let root: URL
    private let library: Library
    /// Runs reflection now and says what changed.
    var reflect: (() async -> String)?
    var reflectionOn: (get: () -> Bool, set: (Bool) -> Void) = ({ true }, { _ in })

    init(root: URL, library: Library) {
        self.root = root
        self.library = library
    }

    private var aboutURL: URL { root.appendingPathComponent("memory/about-you.md") }

    func reload() {
        aboutFile = (try? String(contentsOf: aboutURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        facts = Memory.remembered(root: root)
        decisions = ([nil] + library.projectNames.map(Optional.some)).compactMap { project in
            let all = DecisionLog.all(root: root, project: project)
            guard !all.isEmpty else { return nil }
            let replacing = Dictionary(all.compactMap { d in d.replaces.map { ($0, d) } }, uniquingKeysWith: { first, _ in first })
            let rows = all.reversed().map { d in
                DecisionRow(id: d.id, date: Recall.dayString(d.at), text: d.text,
                            replacedBy: replacing[d.id].map { "Replaced \(Recall.dayString($0.at)): \($0.text)" })
            }
            return (project ?? "Inbox", rows)
        }
        reflections = Reflection.log(root: root)
        lastRun = Reflection.loadState(root: root).lastRun
    }

    func undo(_ entry: Reflection.LogEntry) {
        do {
            try Reflection.undo(entry, root: root, device: "mac")
        } catch {
            problem = "Couldn't undo that: \(error.localizedDescription)"
        }
        reload()
    }

    func reflectNow() {
        guard let reflect, !reflecting else { return }
        reflecting = true
        reflectStatus = nil
        Task {
            reflectStatus = await reflect()
            reflecting = false
            reload()
        }
    }

    func forget(_ fact: String) {
        do {
            try Memory.forget(fact, root: root, device: "mac")
        } catch {
            problem = "Couldn't forget that: \(error.localizedDescription)"
        }
        reload()
    }

    /// Opens about-you.md in your editor, starting it from a short template the first time.
    func editAboutYou() {
        if !FileManager.default.fileExists(atPath: aboutURL.path) {
            try? FileManager.default.createDirectory(at: aboutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? """
            # About you

            Broski reads this at the start of every conversation. Write what helps it help you: how you work, the tools you
            use, how you like answers, who you work with.

            """.write(to: aboutURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(aboutURL)
    }
}

struct MemoryView: View {
    @ObservedObject var model: MemoryModel
    @State private var tab: Int

    init(model: MemoryModel, tab: Int = 0) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                Text("About you").tag(0)
                Text("Decisions").tag(1)
                Text("Reflection").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case 0: about
                    case 1: decisions
                    default: reflection
                    }
                    if let problem = model.problem { Text(problem).font(.system(size: 12)).foregroundStyle(.orange) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.reload() }
    }

    @ViewBuilder private var about: some View {
        Text("Broski reads this at the start of every conversation (never in private mode).")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        HStack {
            Text("ABOUT-YOU.MD").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Button(model.aboutFile.isEmpty ? "Write it" : "Edit") { model.editAboutYou() }.controlSize(.small)
        }
        Text(model.aboutFile.isEmpty ? "Empty. Write how you work, the tools you use, how you like answers." : model.aboutFile)
            .font(.system(size: 13)).foregroundStyle(model.aboutFile.isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        Text("REMEMBERED FROM CONVERSATIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
        if model.facts.isEmpty {
            Text("Nothing yet. Say “remember that …” in a conversation.").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        ForEach(model.facts, id: \.self) { fact in
            HStack(alignment: .top) {
                Text(fact).font(.system(size: 13)).textSelection(.enabled)
                Spacer()
                Button("Forget") { model.forget(fact) }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    @ViewBuilder private var reflection: some View {
        Text("When your Mac is idle, Broski rereads what you said (never its own replies, files, or local-only projects) and updates what it knows about you. Every change is here, with why, and can be undone.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        HStack(spacing: 10) {
            Toggle("Reflect when the Mac is idle", isOn: Binding(get: model.reflectionOn.get, set: { model.reflectionOn.set($0); model.reload() }))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
            Spacer()
            if model.reflecting { ProgressView().controlSize(.small) }
            Button("Reflect now") { model.reflectNow() }.controlSize(.small).disabled(model.reflecting)
        }
        Text(model.reflectStatus ?? model.lastRun.map { "Last ran \(Self.when($0))." } ?? "Hasn't run yet.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        if model.reflections.isEmpty {
            Text("No changes yet.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 6)
        }
        ForEach(model.reflections) { entry in
            HStack(alignment: .top, spacing: 10) {
                Text(entry.op == "remember" ? "Added" : "Dropped")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(entry.op == "remember" ? Color.green : Color.orange)
                    .frame(width: 56, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text).font(.system(size: 13)).strikethrough(entry.undone).foregroundStyle(entry.undone ? .secondary : .primary)
                    Text((entry.why.isEmpty ? "Reflected \(Recall.dayString(entry.at))" : entry.why) + (entry.undone ? " · undone" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if !entry.undone {
                    Button("Undo") { model.undo(entry) }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    private static func when(_ date: Date) -> String {
        let format = DateFormatter()
        format.doesRelativeDateFormatting = true
        format.dateStyle = .medium
        format.timeStyle = .short
        return format.string(from: date)
    }

    @ViewBuilder private var decisions: some View {
        Text("Decisions you saved, newest first. A decision that changes an earlier one replaces it, so Broski never mixes old and new.")
            .font(.system(size: 12)).foregroundStyle(.secondary)
        if model.decisions.isEmpty {
            Text("None yet. When you decide something in a conversation, Broski offers to save it.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        ForEach(model.decisions, id: \.project) { group in
            Text(group.project).font(.system(size: 14, weight: .semibold)).padding(.top, 6)
            ForEach(group.rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    Text(row.date).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.text).font(.system(size: 13)).strikethrough(row.replacedBy != nil)
                            .foregroundStyle(row.replacedBy == nil ? .primary : .secondary)
                        if let replaced = row.replacedBy {
                            Text(replaced).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
