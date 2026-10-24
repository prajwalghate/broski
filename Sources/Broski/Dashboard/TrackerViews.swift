import AppKit
import BroskiCore
import SwiftUI

/// A project's tracker inside Broski: its core sections and project layer, read in place. Broski never edits a
/// project's tracker; actions open the tracker's board or file, or hand the record to the thread that owns it.
struct TrackerPane: View {
    @ObservedObject var library: Library
    let project: Library.ProjectInfo
    @State private var section: CoreSection = .findings
    @State private var showClosed = false
    @State private var query = ""
    @State private var selectedID: String?
    @State private var onboarding = false
    @State private var addingItem = false
    /// Whether the onboarding still fits (refreshed after every read), and the stream's latest changes.
    @State private var health: Onboarding.Health?
    @State private var recent: [ChangeEvent] = []
    @State private var showRecent = false
    @State private var askingThreads = false
    /// The delta run "Ask the threads" just started, for the onboarding sheet to open on.
    @State private var deltaRun: URL?

    /// The tracker Broski owns for this project, if it has one: the only kind it edits.
    private var ownedTracker: TrackerSource? { project.entry?.trackers.first { !$0.readOnly } }

    private var records: [TrackerRecord] { project.records.filter { !$0.archived } }

    private var visible: [TrackerRecord] {
        records.filter { r in
            r.section == section && (showClosed || r.open || !hasOpen(section))
                && (query.isEmpty || (r.recordID + " " + r.title + " " + r.summary).localizedCaseInsensitiveContains(query))
        }
        .sorted { a, b in
            if a.open != b.open { return a.open }
            let rank = ["crit": 0, "high": 1, "med": 2, "low": 3, "info": 4]
            if (rank[a.severity] ?? 5) != (rank[b.severity] ?? 5) { return (rank[a.severity] ?? 5) < (rank[b.severity] ?? 5) }
            return (a.date ?? .distantPast) > (b.date ?? .distantPast)
        }
    }

    /// Sections whose records have a status (findings, decisions); others (runbooks, docs) list everything.
    private func hasOpen(_ section: CoreSection) -> Bool {
        records.contains { $0.section == section && $0.canonical != .none && $0.canonical != .live }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let health, health.drifted { healthStrip(health) }
                if !recent.isEmpty { recentChanges }
                sectionChips
                HStack(spacing: 10) {
                    SearchField(text: $query).frame(maxWidth: 260)
                    if hasOpen(section) { Toggle("Show closed", isOn: $showClosed).toggleStyle(.checkbox) }
                    Spacer()
                    Text("\(visible.count) shown").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                List(visible, selection: $selectedID) { record in
                    RecordRow(record: record).tag(record.id)
                }
                .listStyle(.inset)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            if let record = records.first(where: { $0.id == selectedID }) ?? project.records.first(where: { $0.id == selectedID }) {
                Divider()
                RecordInspector(record: record, library: library) { selectedID = nil }
                    .frame(width: 360)
            }
        }
        .sheet(isPresented: $onboarding) {
            OnboardSheet(library: library, project: project, initial: deltaRun) { onboarding = false; deltaRun = nil }
        }
        .sheet(isPresented: $addingItem) {
            if let tracker = ownedTracker { NewItemSheet(library: library, project: project, tracker: tracker) { addingItem = false } }
        }
        .onReceive(library.$selectRequest.compactMap { $0 }) { id in
            guard let record = project.records.first(where: { $0.id == id }) else { return }
            section = record.section
            showClosed = !record.open
            selectedID = id
            library.selectRequest = nil
        }
        // Set right after each read's snapshots, so both are current here.
        .onReceive(library.$trackerRecords) { all in refreshHealth(records: all[project.id] ?? project.records) }
        .onChange(of: project.id) { _ in refreshHealth(records: library.trackerRecords[project.id] ?? project.records) }
    }

    /// Drift comes with each read; the runs and the stream are small files of Broski's own, so this is cheap per read.
    private func refreshHealth(records: [TrackerRecord]) {
        guard let entry = project.entry else {
            health = nil
            recent = []
            return
        }
        health = OnboardKit.health(for: entry, root: library.store.root, records: records, snapshots: library.snapshots)
        recent = Array(library.changes(project: project.id, since: .distantPast).suffix(30).reversed())
    }

    /// One line, shown only when the onboarding no longer fits: what drifted (hover a part for its items), and a way to ask.
    private func healthStrip(_ health: Onboarding.Health) -> some View {
        let drift = health.drift
        var parts: [(label: String, items: [String])] = []
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        if drift.unmappedCount > 0 {
            parts.append((plural(drift.unmappedCount, "file not read", "files not read"),
                          Array(drift.unmapped.prefix(40)) + (drift.unmappedCount > 40 ? ["…and \(drift.unmappedCount - 40) more"] : [])))
        }
        if !drift.deadSources.isEmpty {
            parts.append((plural(drift.deadSources.count, "mapping finds nothing", "mappings find nothing"), drift.deadSources))
        }
        if !drift.unknownStatuses.isEmpty {
            parts.append((plural(drift.unknownStatuses.count, "unknown status word", "unknown status words"), drift.statusWords))
        }
        if !health.newThreads.isEmpty {
            parts.append((plural(health.newThreads.count, "new thread", "new threads"), health.newThreads))
        }
        return HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Text("·").foregroundStyle(.tertiary) }
                Text(part.label).help(part.items.joined(separator: "\n"))
            }
            Spacer()
            if askingThreads { ProgressView().controlSize(.small) }
            Button("Ask the threads") { askThreads(health) }
                .disabled(askingThreads)
                .help("Start a short onboarding run that asks the threads only about what changed")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    /// Starts a delta run off the main thread (re-checking the last run's answers re-verifies every citation),
    /// then opens the onboarding sheet on it.
    private func askThreads(_ health: Onboarding.Health) {
        guard let entry = project.entry else { return }
        askingThreads = true
        let root = library.store.root
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try OnboardKit.startDelta(entry, health, stale: health.latestRun.map { OnboardKit.staleAnswers($0, root: root) } ?? [], root: root) }
            }.value
            askingThreads = false
            switch result {
            case .success(let run):
                deltaRun = run.folder
                onboarding = true
            case .failure(let error):
                library.show("Couldn't ask the threads: \(error)")
            }
        }
    }

    /// The change stream's latest events for this project, newest first; each opens its record.
    private var recentChanges: some View {
        DisclosureGroup(isExpanded: $showRecent) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, event in
                    let known = project.records.contains { $0.id == event.id }
                    Button { library.selectRequest = event.id } label: {
                        HStack(spacing: 6) {
                            Text(event.kind).font(.system(size: 10, weight: .semibold)).foregroundStyle(changeColor(event.kind))
                                .frame(width: 58, alignment: .leading)
                            Text(event.id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? event.id)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Text(event.title).font(.system(size: 11)).lineLimit(1)
                            if event.from != nil || event.to != nil {
                                Text("\(event.from ?? "–") → \(event.to ?? "–")").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(event.at, format: .relative(presentation: .named)).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // A removed record has nothing left to open.
                    .disabled(!known)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Recent changes (\(recent.count))").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .help("What changed between Broski's reads of this tracker, from its change stream")
        }
    }

    private func changeColor(_ kind: String) -> Color {
        switch kind {
        case "new": return Brand.purple
        case "closed", "decided": return .green
        case "reopened": return .orange
        case "removed": return .red
        case "attested": return .blue
        default: return .secondary
        }
    }

    private var header: some View {
        let sources = project.entry?.trackers ?? []
        return HStack(spacing: 8) {
            Image(systemName: "lock.doc").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(sources.map(\.name).joined(separator: ", ").ifEmpty("Docs from this project's folders"))
                    .font(.system(size: 12, weight: .semibold))
                Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if library.readingTrackers { ProgressView().controlSize(.small) }
            ForEach(sources, id: \.id) { source in
                if let board = source.board, let url = URL(string: board) {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Board", systemImage: "rectangle.on.rectangle") }
                        .help("Open \(source.name)'s own board for live state")
                }
                Button { NSWorkspace.shared.open(source.url) } label: { Label("Folder", systemImage: "folder") }
            }
            if ownedTracker != nil {
                Button { addingItem = true } label: { Label("New", systemImage: "plus") }
                    .help("Add a bug, task, risk, idea or decision to the tracker Broski keeps for this project")
            }
            Button { onboarding = true } label: { Label("Onboard", systemImage: "checklist") }
                .help("Ask this project's threads where everything lives, with evidence, and check every answer")
        }
    }

    private var statusLine: String {
        let parts = (project.entry?.trackers ?? []).compactMap { source -> String? in
            guard let snap = library.snapshots[source.id] else { return nil }
            let rev = snap.revision.map { "at \($0.prefix(7))" } ?? "working tree"
            return "\(source.id) \(rev), read \(snap.readAt.formatted(.relative(presentation: .named))), \(snap.records.count) records" + (snap.problems.isEmpty ? "" : " · \(snap.problems.joined(separator: "; "))")
        }
        let rule = ownedTracker == nil ? "read-only: the tracker is the source of truth" : "kept by Broski: edit it here or in its files"
        return (parts.isEmpty ? ["read in place"] : parts).joined(separator: " · ") + " · " + rule
    }

    private var sectionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CoreSection.allCases, id: \.self) { s in
                    let inSection = records.filter { $0.section == s }
                    if !inSection.isEmpty {
                        let open = inSection.filter(\.open).count
                        Button { section = s; selectedID = nil } label: {
                            HStack(spacing: 4) {
                                Text(s.label)
                                Text(open > 0 ? "\(open) open" : "\(inSection.count)").foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12, weight: section == s ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(section == s ? Brand.purple.opacity(0.15) : Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct RecordRow: View {
    let record: TrackerRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.recordID.split(separator: "/").last.map(String.init) ?? record.recordID)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(record.title).font(.system(size: 13)).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if !record.status.isEmpty { pill(record.canonical == .live ? "live state" : record.status, record.open ? Brand.purple : .secondary) }
                    if !record.severity.isEmpty { pill(record.severity, ["crit", "high"].contains(record.severity) ? .red : .orange) }
                    if let owner = record.fields["owner_thread"] ?? (record.owner.isEmpty ? nil : record.owner) { Text(owner).foregroundStyle(.secondary) }
                    if let date = record.date { Text(date, format: .dateTime.day().month(.abbreviated)).foregroundStyle(.tertiary) }
                    if record.lowTrust { Text("prose").foregroundStyle(.tertiary).help("May be out of date: the records are the truth") }
                }
                .font(.system(size: 11))
            }
        }
        .padding(.vertical, 3)
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }

    private var symbol: String {
        switch record.kind {
        case "finding", "ops": return "exclamationmark.triangle"
        case "bug": return "ladybug"
        case "risk": return "exclamationmark.shield"
        case "idea": return "lightbulb"
        case "incident": return "flame"
        case "release", "deployment", "milestone": return "shippingbox"
        case "decision": return "checkmark.seal"
        case "step", "test": return "flag"
        case "runbook", "lesson": return "book"
        case "thread": return "person.2"
        case "message": return record.canonical == .unread ? "envelope.badge" : "envelope.open"
        case "conflict": return "arrow.triangle.branch"
        case "task": return "checkmark.circle"
        default: return "doc.text"
        }
    }

    private var color: Color {
        switch record.kind {
        case "finding", "ops", "risk", "bug", "incident": return .red
        case "idea": return .yellow
        case "decision": return Brand.purple
        case "step", "test": return .blue
        case "message": return .orange
        default: return .secondary
        }
    }
}

/// One record, read-only, with the ways to act on it without touching the tracker.
struct RecordInspector: View {
    let record: TrackerRecord
    @ObservedObject var library: Library
    let onClose: () -> Void
    @State private var copied: String?
    @State private var answer = ""

    /// Set when the record lives in a tracker Broski owns, so it can change its status.
    private var owned: (source: TrackerSource, entry: ProjectRegistry.Entry)? {
        guard let entry = library.registry.entry(notes: record.project),
              let source = entry.trackers.first(where: { $0.id == record.source && !$0.readOnly }) else { return nil }
        return (source, entry)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(record.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close")
                }
                Text(record.title).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
                if !record.summary.isEmpty { Text(record.summary).font(.system(size: 13)).textSelection(.enabled) }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    row("Status", record.canonical == .live ? "live (ask the board)" : "\(record.status.ifEmpty("—")) · \(record.canonical.rawValue)")
                    if !record.severity.isEmpty { row("Severity", record.severity) }
                    if let thread = record.fields["owner_thread"] { row("Thread", thread) }
                    if !record.owner.isEmpty { row("Owner", record.owner) }
                    if let date = record.date { row("Dated", date.formatted(date: .abbreviated, time: .shortened)) }
                    row("Section", record.section.label + (record.layer.isEmpty ? "" : " · \(record.layer)"))
                    row("File", record.path)
                }
                .font(.system(size: 12))
                if owned != nil, record.canonical != .none, record.canonical != .live { statusControls }
                actions
                if let copied { Text(copied).font(.system(size: 11)).foregroundStyle(.green) }
                let shown = record.fields.filter { !["owner_thread", "dataset", "parent"].contains($0.key) }.sorted { $0.key < $1.key }
                if !shown.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(shown, id: \.key) { key, value in
                            (Text(key + ": ").bold() + Text(value)).font(.system(size: 11)).textSelection(.enabled)
                        }
                    }
                }
                if !record.body.isEmpty {
                    Divider()
                    Text(record.body).font(.system(size: 12)).textSelection(.enabled)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let link = record.link, let url = URL(string: link) {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Board", systemImage: "rectangle.on.rectangle") }
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([record.file]) } label: { Label("File", systemImage: "doc") }
                Button {
                    BroskiUI.app?.showAsk(nil)
                    BroskiUI.app?.prefillAsk("Tell me about \(record.id): where it stands, what it blocks, and what's next")
                } label: { Label("Ask", systemImage: "sparkle.magnifyingglass") }
            }
            HStack(spacing: 8) {
                Button {
                    Exporter.copy(handoff)
                    copied = "Copied a prompt for the \(record.fields["owner_thread"] ?? "owning") thread. Paste it into its Claude Code session."
                } label: { Label("Hand to thread", systemImage: "arrowshape.turn.up.right") }
                    .help("Broski never writes to the tracker; this copies a prompt for the thread that owns this record")
                Button { makeNote() } label: { Label("Make a note", systemImage: "square.and.pencil") }
                Button {
                    Exporter.copy("[[\(record.id)]]")
                    copied = "Copied [[\(record.id)]]"
                } label: { Image(systemName: "link") }
                    .help("Copy the citation")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Status changes for a record in a Broski-owned tracker. A decision is closed with its answer.
    private var statusControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if record.kind == "decision" {
                HStack(spacing: 8) {
                    TextField("The decision", text: $answer).textFieldStyle(.roundedBorder)
                    Button("Decide") { setStatus("decided", note: answer) }.disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(["open", "doing", "blocked", "done", "wontfix"], id: \.self) { status in
                        Button(status) { setStatus(status, note: nil) }.disabled(record.status == status)
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func setStatus(_ status: String, note: String?) {
        guard let owned else { return }
        do {
            try TrackerTemplate.setStatus(record.recordID, to: status, note: note, tracker: owned.source.url, root: library.store.root)
            library.readTrackers(of: owned.entry)
            copied = "\(record.recordID) is now \(status)."
            answer = ""
        } catch {
            copied = "Couldn't change it: \(error)"
        }
    }

    /// A ready-to-paste prompt for the thread that owns the record.
    private var handoff: String {
        let thread = record.fields["owner_thread"] ?? "owning"
        return """
        You are the \(thread) thread. The user is looking at \(record.id) (\(record.kind), status \(record.status.ifEmpty("none"))): \(record.title)
        File: \(record.path)\(record.link.map { "\nBoard: \($0)" } ?? "")

        Read it and its references, then tell him in a few lines where it really stands, what it blocks, and the next step and who does it. Follow your tracker's own rules for any change (reserve ids, dated updates, sync); don't change anything until he says go.
        """
    }

    private func makeNote() {
        do {
            let item = try library.store.create(ItemDraft(project: record.project, kind: record.open && ["finding", "ops", "bug"].contains(record.kind) ? .bug : .note,
                                                          title: "About \(record.recordID.split(separator: "/").last ?? ""): \(record.title.prefix(70))",
                                                          body: "[[\(record.id)]]\n\n", context: ItemContext(app: "Broski tracker")))
            library.reload()
            library.selectRequest = item.id
            copied = "Note created in \(record.project). Add your thoughts there."
        } catch {
            copied = "Couldn't create the note: \(error.localizedDescription)"
        }
    }
}

/// "Waiting on you", across every project: decisions you decide, your tasks and notes, and your launch steps.
struct WaitingPanel: View {
    @ObservedObject var library: Library

    var body: some View {
        let localOnly = library.brainSettings().localOnly
        let lines = WaitingOn.lines(records: library.allRecords.filter { !localOnly.contains($0.project) && $0.kind != "step" },
                                    notes: library.allItems.filter { !localOnly.contains($0.project ?? "") })
        let grouped = Dictionary(grouping: lines, by: \.project).sorted { $0.value.count > $1.value.count }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WAITING ON YOU").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Ask what's waiting") { BroskiUI.app?.showAsk(nil); BroskiUI.app?.prefillAsk("What's waiting on me across all my projects right now?") }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
            if lines.isEmpty {
                Text("Nothing in your notes or trackers is waiting on you.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(grouped.prefix(8), id: \.key) { project, items in
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.registry.entry(notes: project)?.name ?? project).font(.system(size: 12, weight: .semibold))
                    ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { _, line in
                        Button { BroskiUI.app?.openNote(line.cite) } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: line.kind == "decision" ? "checkmark.seal" : "circle").font(.system(size: 9)).foregroundStyle(Brand.purple).padding(.top, 3)
                                Text(line.text).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if items.count > 5 { Text("+ \(items.count - 5) more").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.purple.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.purple.opacity(0.15)))
    }
}

/// Adds an item or a decision to the tracker Broski keeps for a project.
struct NewItemSheet: View {
    @ObservedObject var library: Library
    let project: Library.ProjectInfo
    let tracker: TrackerSource
    let onClose: () -> Void
    @State private var kind = "task"
    @State private var title = ""
    @State private var severity = "med"
    @State private var detail = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New in \(project.displayName)").font(.system(size: 15, weight: .semibold))
            Picker("Kind", selection: $kind) {
                ForEach(["task", "bug", "risk", "finding", "idea", "decision"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField(kind == "decision" ? "The question to decide" : "Title", text: $title).textFieldStyle(.roundedBorder)
            if ["bug", "risk", "finding"].contains(kind) {
                Picker("Severity", selection: $severity) {
                    ForEach(["crit", "high", "med", "low", "info"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Text(kind == "decision" ? "Context and options (optional)" : "Details (optional)").font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: $detail).font(.system(size: 12)).frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func add() {
        do {
            let id = try TrackerTemplate.add(kind: kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: detail,
                                             severity: ["bug", "risk", "finding"].contains(kind) ? severity : nil, tracker: tracker.url, root: library.store.root)
            if let entry = project.entry { library.readTrackers(of: entry) }
            library.show("Added \(id) to \(project.displayName)")
            onClose()
        } catch {
            self.error = "\(error)"
        }
    }
}

/// Onboarding a project: start a run, hand each thread its questions, check every answer's evidence, then draft
/// and approve the manifest. Answers live in Broski's folder; the project's tracker is never written.
struct OnboardSheet: View {
    @ObservedObject var library: Library
    let project: Library.ProjectInfo
    /// A run to open on (a delta run just started from the health strip).
    var initial: URL? = nil
    let onClose: () -> Void
    @State private var runs: [URL] = []
    @State private var selected: URL?
    @State private var summary = ""
    @State private var working = false
    @State private var message: String?

    private var root: URL { library.store.root }
    private var run: Onboarding.Run? { selected.flatMap(Onboarding.loadRun) }
    private var draftID: String? {
        guard let entry = project.entry else { return nil }
        return (entry.trackers.first(where: \.readOnly) ?? Library.sources(of: entry).first(where: { $0.scope == .docs }))?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Onboard \(project.displayName)").font(.system(size: 15, weight: .semibold))
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            Text("Each of the project's threads (its Claude Code sessions) answers a short questionnaire about where everything lives, citing real files, commits, records or transcripts. Broski checks every citation, then drafts how to read the tracker. Nothing is written to the project.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { start() } label: { Label("Start a run", systemImage: "play") }.disabled(project.entry == nil || working)
                if project.entry?.trackers.isEmpty == true {
                    Button { createTracker() } label: { Label("Create a Broski tracker", systemImage: "folder.badge.plus") }
                        .help("For a project with no tracker: a plain-markdown tracker in Broski's folder, which Broski can edit")
                }
                Spacer()
                if !runs.isEmpty {
                    Picker("Run", selection: $selected) {
                        ForEach(runs, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
                    }
                    .frame(width: 240)
                }
            }
            if let run {
                Divider()
                if let note = run.note {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WHAT CHANGED SINCE THE LAST RUN").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        ScrollView { Text(note).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 120)
                    }
                }
                ForEach(run.assign.keys.sorted(), id: \.self) { thread in
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                        Text(thread).font(.system(size: 12, weight: .semibold))
                        Text("\(run.assign[thread]?.count ?? 0) questions · \(answered(run, thread)) answered").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy command") {
                            Exporter.copy(OnboardKit.forkCommand(thread: thread, run: run))
                            message = "Copied. Paste it in Terminal: it forks \(thread)'s newest Claude Code session and asks it the questions."
                        }
                        Button("Prompt") { NSWorkspace.shared.open(run.folder.appendingPathComponent("PROMPT-\(thread).md")) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                HStack(spacing: 8) {
                    Button { check(run) } label: { Label("Check answers", systemImage: "checkmark.shield") }.disabled(working)
                    Button { assemble(run) } label: { Label("Draft manifest", systemImage: "doc.badge.gearshape") }.disabled(working)
                    if let id = draftID, FileManager.default.fileExists(atPath: root.appendingPathComponent("trackers/" + TrackerManifest.overlayName(id, draft: true)).path) {
                        Button { approve(id) } label: { Label("Approve draft", systemImage: "checkmark") }
                            .help("Broski reads the tracker with the drafted manifest from now on; the previous one is kept beside it")
                    }
                    Button { NSWorkspace.shared.open(run.folder) } label: { Label("Folder", systemImage: "folder") }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true) }
            if !summary.isEmpty {
                ScrollView { Text(summary).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minHeight: 120, maxHeight: 260)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear { refresh() }
    }

    private func refresh() {
        runs = OnboardKit.runs(for: project.name, root: root)
        if selected == nil, let initial { selected = runs.first { $0.lastPathComponent == initial.lastPathComponent } }
        if selected == nil || !runs.contains(selected!) { selected = runs.first }
    }

    private func answered(_ run: Onboarding.Run, _ thread: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: run.folder.path)) ?? []).filter { $0.hasPrefix("Q-") && $0.hasSuffix(".\(thread).md") }.count
    }

    private func start() {
        guard let entry = project.entry else { return }
        working = true
        let root = root
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try OnboardKit.start(entry, root: root) } }.value
            working = false
            switch result {
            case .success(let run):
                refresh()
                selected = run.folder
                message = "Started \(run.id). Copy each thread's command and paste it in Terminal."
            case .failure(let error):
                message = "Couldn't start: \(error)"
            }
        }
    }

    private func check(_ run: Onboarding.Run) {
        working = true
        let root = root
        Task {
            let report = await Task.detached(priority: .userInitiated) { OnboardKit.check(run, root: root) }.value
            working = false
            summary = OnboardKit.summary(report)
            message = report.failures == 0 ? "Every answer's evidence checks out." : "\(report.failures) answers need fixing: hand the failures back to their threads."
        }
    }

    private func assemble(_ run: Onboarding.Run) {
        working = true
        let root = root
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try OnboardKit.assemble(run, root: root) } }.value
            working = false
            switch result {
            case .success(let url): message = "Drafted \(url.lastPathComponent). Review it, then approve."
            case .failure(let error): message = "Couldn't draft: \(error)"
            }
        }
    }

    private func approve(_ id: String) {
        do {
            try OnboardKit.approveDraft(trackerID: id, root: root)
            if let entry = project.entry { library.readTrackers(of: entry) }
            message = "Approved. Broski reads \(project.displayName) with the new manifest."
        } catch {
            message = "Couldn't approve: \(error)"
        }
    }

    private func createTracker() {
        do {
            let folder = try OnboardKit.newTracker(for: project.name, root: root)
            library.loadRegistry()
            message = "Created \(folder.path). It's listed as this project's tracker."
        } catch {
            message = "Couldn't create it: \(error)"
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
