import AppKit
import BroskiCore
import SwiftUI

/// Lets any view open Broski's companion features (Ask, riff, help, call) without passing callbacks around.
@MainActor
enum BroskiUI {
    static weak var app: AppModel?
}

/// A project's living page: where it stands, what's open, and what Broski suggests doing,
/// every line linked to the notes it came from.
struct ProjectOverview: View {
    @ObservedObject var library: Library
    let project: String
    @Binding var selectedID: String?

    private var page: ProjectPage? { library.pages[project] }
    private var compiling: Bool { library.compiling.contains(project) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                status
                if let page {
                    if !page.summary.isEmpty {
                        Text(page.summary)
                            .font(.system(size: 15))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    let actions = page.actions.filter { !$0.dismissed }
                    if !actions.isEmpty { suggestions(actions) }
                    ForEach(page.sections.filter { !$0.lines.isEmpty }, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                                PageLine(line: line, library: library, selectedID: $selectedID)
                            }
                        }
                    }
                } else {
                    Text("This page fills in as you capture notes for \(project).")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            if compiling {
                ProgressView().controlSize(.small)
                Text("Updating this page…")
            } else if let page {
                Image(systemName: page.source == .claude ? "sparkles" : "list.bullet.rectangle")
                    .foregroundStyle(page.source == .claude ? Brand.purple : .secondary)
                Text(page.source == .claude
                     ? "Written from your notes · \(page.compiled.formatted(.relative(presentation: .named)))"
                     : (library.brain.hasModel ? "Built from your notes · your model will refine it shortly" : "Built from your notes · choose a model in Settings › Models for the full page"))
            }
            if let problem = library.pageProblem, !compiling {
                Text("· \(problem)").foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            Button {
                BroskiUI.app?.showRiff(project: project, opening: nil)
            } label: { Label("Riff", systemImage: "bubble.left.and.text.bubble.right") }
                .help("Think out loud about \(project)")
            Button {
                library.compilePage(project)
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(compiling || !library.brain.hasModel)
                .help(library.brain.hasModel ? "Rewrite the page from your notes now" : "Choose a model in Settings › Models")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func suggestions(_ actions: [ProposedAction]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SUGGESTED")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(actions) { action in
                ActionCard(action: action, project: project, library: library, selectedID: $selectedID)
            }
        }
    }
}

/// One line of a living page, with its citations as small numbered chips.
struct PageLine: View {
    let line: ProjectPage.Line
    @ObservedObject var library: Library
    @Binding var selectedID: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 4, height: 4).offset(y: -3)
            VStack(alignment: .leading, spacing: 4) {
                Text(line.text)
                    .font(.system(size: 13.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !line.cites.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(line.cites, id: \.self) { id in
                            CitationChip(id: id, library: library) { open(id) }
                        }
                    }
                }
            }
        }
    }

    private func open(_ id: String) {
        if library.record(id: id) != nil { BroskiUI.app?.openNote(id) }
        else if library.item(id: id) != nil { selectedID = id }
        else if let session = library.session(forRef: id) { NSWorkspace.shared.open(session.file) }
    }
}

struct CitationChip: View {
    let id: String
    @ObservedObject var library: Library
    var number: Int?
    let action: () -> Void

    var body: some View {
        let ref = library.index.ref(id: id)
        Button(action: action) {
            HStack(spacing: 3) {
                if let number { Text("\(number)").fontWeight(.semibold) }
                Image(systemName: ref?.isSessionEntry == true ? "record.circle" : (ref?.kind ?? .note).symbol)
                Text(ref.map { String($0.title.prefix(34)) + ($0.title.count > 34 ? "…" : "") } ?? "note")
                    .lineLimit(1)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(ref?.kind.color ?? .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill((ref?.kind.color ?? .secondary).opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(ref.map { "\($0.title)\n\($0.project ?? "Inbox") · \($0.date.formatted(date: .abbreviated, time: .shortened))" } ?? id)
    }
}

/// A suggestion from the brain, done in one click or dismissed for good.
struct ActionCard: View {
    let action: ProposedAction
    let project: String
    @ObservedObject var library: Library
    @Binding var selectedID: String?
    @State private var result: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.purple)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(action.title).font(.system(size: 13, weight: .semibold))
                if !action.detail.isEmpty, action.kind != .claudePrompt {
                    Text(action.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !action.cites.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(citeIDs, id: \.self) { id in
                            CitationChip(id: id, library: library) { if library.item(id: id) != nil { selectedID = id } }
                        }
                    }
                }
                if let result { Text(result).font(.system(size: 11)).foregroundStyle(.green) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button(primaryLabel) { Task { await perform() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.purple)
                    .controlSize(.small)
                Button { library.dismissAction(action, in: project) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Not useful; don't suggest it again")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.purple.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.purple.opacity(0.15)))
    }

    /// Saved pages can cite a note twice; merging it into itself would trash it.
    private var citeIDs: [String] {
        var seen = Set<String>()
        return action.cites.filter { seen.insert($0).inserted }
    }

    private var cited: [Item] { citeIDs.compactMap { library.item(id: $0) } }

    private var symbol: String {
        switch action.kind {
        case .issue: return "exclamationmark.bubble"
        case .markDone: return "checkmark.circle"
        case .merge: return "arrow.triangle.merge"
        case .prioritize: return "flag"
        case .claudePrompt: return "terminal"
        case .decide: return "questionmark.bubble"
        }
    }

    private var primaryLabel: String {
        switch action.kind {
        case .issue: return library.project(named: project)?.githubRepo != nil ? "File on GitHub" : "File issue"
        case .markDone: return "Mark done"
        case .merge: return "Merge"
        case .prioritize: return "Make high priority"
        case .claudePrompt: return "Copy prompt"
        case .decide: return "Think it through"
        }
    }

    private func perform() async {
        switch action.kind {
        case .issue:
            let repo = library.project(named: project)?.githubRepo
            let export = cited.count == 1 ? Exporter.export(cited[0], githubRepo: repo)
                : Exporter.export(cited, title: action.title, githubRepo: repo)
            result = await Exporter.send(export, to: repo != nil ? .github : .linear)
        case .markDone:
            for item in cited { library.setStatus(item, .done) }
            result = "Marked \(cited.count) done"
        case .merge:
            guard let keep = cited.first else { return }
            let rest = cited.filter { $0.file.standardizedFileURL != keep.file.standardizedFileURL }
            guard !rest.isEmpty else { result = "Nothing to merge"; return }
            do {
                try library.merge(rest, into: keep)
                result = "Merged into “\(keep.title)”"
            } catch {
                result = "Couldn't merge: \(error.localizedDescription)"
            }
        case .prioritize:
            // Only ever raise: an urgent note stays urgent.
            for item in cited where item.priority < .high {
                library.update(item) { $0.priority = max($0.priority, .high) }
            }
            result = "Raised to high"
        case .claudePrompt:
            Exporter.copy(action.detail.isEmpty ? action.title : action.detail)
            result = "Copied. Paste it into Claude Code."
            return
        case .decide:
            BroskiUI.app?.showRiff(project: project, opening: action.title + (action.detail.isEmpty ? "" : "\n\n" + action.detail))
            return
        }
        library.dismissAction(action, in: project)
    }
}

/// "All notes": ask anything, and every project's page at a glance.
struct BrainHome: View {
    @ObservedObject var library: Library
    @Binding var selectedID: String?
    var onOpenProject: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button { BroskiUI.app?.showAsk(nil) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Brand.purple)
                        Text("Ask Broski about any project… “what's left on strado?”").foregroundStyle(.secondary)
                        Spacer()
                        Text(BroskiUI.app?.askLabel ?? "⌥⇧A").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 14))
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)

                WaitingPanel(library: library)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    ForEach(library.projects) { project in
                        Button { onOpenProject(project.id) } label: { card(project) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(22)
        }
    }

    private func card(_ project: Library.ProjectInfo) -> some View {
        let page = library.pages[project.name]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.displayName).font(.system(size: 14, weight: .semibold))
                if project.hasTracker { Image(systemName: "lock.doc").font(.system(size: 10)).foregroundStyle(.secondary).help("Has a tracker, read in place") }
                Spacer()
                if library.compiling.contains(project.name) { ProgressView().controlSize(.mini) }
                else if page?.source == .claude { Image(systemName: "sparkles").foregroundStyle(Brand.purple).font(.system(size: 11)) }
            }
            Text(page?.summary ?? "\(project.items.count) notes")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let suggestions = page?.actions.filter({ !$0.dismissed }).count, suggestions > 0 {
                Label("\(suggestions) suggestion\(suggestions == 1 ? "" : "s")", systemImage: "lightbulb")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Brand.purple)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}
