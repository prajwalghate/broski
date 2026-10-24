import AppKit
import BroskiCore
import SwiftUI
import WebKit

/// The dashboard: projects on the left; a board, list, sessions, or screenshots in the middle;
/// the selected note in an inspector on the right.
struct DashboardView: View {
    @ObservedObject var library: Library
    var shortcut: String
    var onCapture: () -> Void
    var onScreenshot: () -> Void

    @State private var selection: String?
    @State private var newProjectName = ""
    @State private var addingProject = false

    static let allID = "__all"
    static let sessionsID = "__sessions"

    init(library: Library, shortcut: String, onCapture: @escaping () -> Void, onScreenshot: @escaping () -> Void, selection: String? = DashboardView.allID) {
        self.library = library
        self.shortcut = shortcut
        self.onCapture = onCapture
        self.onScreenshot = onScreenshot
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            Group {
                if selection == Self.sessionsID {
                    SessionsPane(library: library, sessions: library.allSessions, title: "Sessions", showProject: true)
                } else {
                    ProjectPane(library: library, projectID: selection == Self.allID ? nil : selection,
                                shortcut: shortcut, onCapture: onCapture, onScreenshot: onScreenshot)
                }
            }
            .id(selection ?? Self.allID)
        }
        .frame(minWidth: 720, minHeight: 520)
        // The sent value, not library.focusRequest: @Published sends before the property changes.
        .onReceive(library.$focusRequest.compactMap { $0 }) { id in
            selection = id
            DispatchQueue.main.async { library.focusRequest = nil }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                SidebarRow(title: "All notes", symbol: "square.stack", total: library.allItems.count, open: library.allItems.filter(\.isOpenTask).count)
                    .tag(Self.allID)
                SidebarRow(title: "Inbox", symbol: "tray", total: library.inbox.items.count, open: library.inbox.openCount)
                    .tag(Library.inboxID)
                SidebarRow(title: "Sessions", symbol: library.activeSession != nil ? "record.circle" : "rectangle.stack.badge.play",
                           total: library.allSessions.count, open: library.activeSession != nil ? 1 : 0)
                    .tag(Self.sessionsID)
            }
            Section("Projects") {
                ForEach(library.projects.filter { $0.entry?.kind != .personal }) { project in
                    SidebarRow(title: project.displayName, symbol: project.hasTracker ? "lock.doc.fill" : (project.folder == nil ? "folder" : "folder.fill"),
                               total: project.items.count, open: project.openCount)
                        .tag(project.id)
                }
            }
            let personal = library.projects.filter { $0.entry?.kind == .personal }
            if !personal.isEmpty {
                Section("Personal") {
                    ForEach(personal) { project in
                        SidebarRow(title: project.displayName, symbol: "person.crop.circle", total: project.items.count, open: project.openCount)
                            .tag(project.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if addingProject {
                    HStack(spacing: 6) {
                        TextField("Project name", text: $newProjectName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(createProject)
                        Button("Add", action: createProject)
                    }
                } else {
                    Button { addingProject = true } label: {
                        Label("New project", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
        }
    }

    private func createProject() {
        if let id = library.createProject(named: newProjectName) { selection = id }
        newProjectName = ""
        addingProject = false
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let total: Int
    let open: Int

    var body: some View {
        HStack {
            Label(title, systemImage: symbol).lineLimit(1)
            Spacer()
            if open > 0 {
                Text("\(open)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Brand.purple))
            } else if total > 0 {
                Text("\(total)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Project

enum ProjectTab: String, CaseIterable, Identifiable {
    case overview = "Overview", center = "Command center", tracker = "Tracker", board = "Board", list = "List", sessions = "Sessions",
         screenshots = "Screenshots"
    var id: String { rawValue }
}

enum KindFilter: String, CaseIterable, Identifiable {
    case all = "All", todo = "Todos", bug = "Bugs", idea = "Ideas", note = "Notes"
    var id: String { rawValue }

    func matches(_ item: Item) -> Bool {
        switch self {
        case .all: return true
        case .todo: return item.kind == .todo
        case .bug: return item.kind == .bug
        case .idea: return item.kind == .idea
        case .note: return item.kind == .note
        }
    }
}

/// One project (or every note) with its board, list, sessions, and screenshots.
struct ProjectPane: View {
    @ObservedObject var library: Library
    let projectID: String?
    let shortcut: String
    let onCapture: () -> Void
    let onScreenshot: () -> Void

    @AppStorage("BroskiDashboardTab") private var tab = ProjectTab.board
    @State private var query = ""
    @State private var filter = KindFilter.all
    @State private var draft = ""
    @State private var selectedID: String?

    private var project: Library.ProjectInfo? { library.project(id: projectID) }
    private var title: String { project?.displayName ?? "All notes" }
    private var items: [Item] { project?.items ?? library.allItems }
    private var sessions: [Session] { project?.sessions ?? library.allSessions }

    private var visible: [Item] {
        items.filter { item in
            filter.matches(item) && (query.isEmpty
                || item.title.localizedCaseInsensitiveContains(query)
                || item.body.localizedCaseInsensitiveContains(query)
                || item.tags.contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    private var selected: Item? { items.first { $0.id == selectedID } }

    var body: some View {
        GeometryReader { geo in
            // In a narrow window the inspector floats over the board instead of squeezing it.
            let narrow = geo.size.width < 980
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        header
                        if tab == .board || tab == .list { composer }
                        Divider()
                        content
                        if let banner = library.banner { BannerView(library: library, text: banner) }
                    }
                    .frame(maxWidth: .infinity)
                    if !narrow, let item = inspected {
                        Divider()
                        inspector(item).frame(width: 330)
                    }
                }
                if narrow, let item = inspected {
                    inspector(item)
                        .frame(width: min(330, geo.size.width - 40))
                        .background(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.25), radius: 12, x: -2)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onReceive(library.$selectRequest.compactMap { $0 }) { id in
            // Only the note's own project (or the Inbox) takes it: "All notes" holds every note, and taking it
            // there would leave nothing for the project pane the dashboard switches to next.
            guard projectID != nil, items.contains(where: { $0.id == id }) else { return }
            if tab == .sessions { tab = .list }
            selectedID = id
            // Later: @Published sends before it sets, so clearing it now would be undone.
            DispatchQueue.main.async { library.selectRequest = nil }
        }
    }

    private var inspected: Item? {
        tab == .board || tab == .list || tab == .screenshots || tab == .overview ? selected : nil
    }

    private func inspector(_ item: Item) -> some View {
        ItemInspector(library: library, item: item, githubRepo: library.project(named: item.project)?.githubRepo,
                      onClose: { selectedID = nil })
            .id(item.id)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 24, weight: .bold)).lineLimit(1)
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 12)
                ViewThatFits(in: .horizontal) {
                    actions(labels: true)
                    actions(labels: false)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { tabPicker; filters; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 8) { tabPicker; HStack(spacing: 10) { filters; Spacer(minLength: 0) } }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(ProjectTab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 620)
    }

    @ViewBuilder private var filters: some View {
        if tab == .board || tab == .list {
            SearchField(text: $query).frame(minWidth: 140, maxWidth: 220)
            Picker("", selection: $filter) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 96)
        }
    }

    private func actions(labels: Bool) -> some View {
        HStack(spacing: 8) {
                    Button { BroskiUI.app?.showAsk(project.flatMap { $0.isInbox ? nil : $0.name }) } label: { label("Ask", "sparkle.magnifyingglass", labels) }
                        .help("Ask Broski about your notes (\(BroskiUI.app?.askLabel ?? "⌥⇧A"))")
                    Button(action: onCapture) { label("Talk", "mic.fill", labels) }
                        .help("Take a voice note (\(shortcut))")
                    Button(action: onScreenshot) { label("Screenshot", "camera.viewfinder", labels) }
                        .help("Capture part of the screen with a comment")
                    ExportMenu(library: library, label: labels ? "Send" : "") {
                        Exporter.export(visible, title: title, githubRepo: project?.githubRepo)
                    }
                    if let folder = project?.folder {
                        Button { NSWorkspace.shared.open(folder) } label: { Image(systemName: "folder") }
                            .help("Open the project folder")
                    }
                    if let repo = project?.githubRepo, let url = URL(string: "https://github.com/\(repo)") {
                        Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                            .help("Open \(repo) on GitHub")
                    }
        }
        .fixedSize()
    }

    @ViewBuilder private func label(_ text: String, _ symbol: String, _ show: Bool) -> some View {
        if show { Label(text, systemImage: symbol) } else { Image(systemName: symbol) }
    }

    private var summary: String {
        let open = items.filter(\.isOpenTask).count
        let bugs = items.filter { $0.kind == .bug && !$0.isDone }.count
        var parts = ["\(items.count) note\(items.count == 1 ? "" : "s")"]
        if open > 0 { parts.append("\(open) open") }
        if bugs > 0 { parts.append("\(bugs) bug\(bugs == 1 ? "" : "s")") }
        if !sessions.isEmpty { parts.append("\(sessions.count) session\(sessions.count == 1 ? "" : "s")") }
        if let folder = project?.folder { parts.append((folder.path as NSString).abbreviatingWithTildeInPath) }
        return parts.joined(separator: " · ")
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").font(.system(size: 16)).foregroundStyle(Brand.purple)
            TextField(project.map { "Add a note to \($0.name)… (⏎)" } ?? "Add a note… start with “in the <project> project,” to file it", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit {
                    library.add(draft, to: project, kind: nil)
                    draft = ""
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .overview:
            if let project, !project.isInbox {
                ProjectOverview(library: library, project: project.name, selectedID: $selectedID)
            } else {
                BrainHome(library: library, selectedID: $selectedID) { library.focusRequest = $0 }
            }
        case .center:
            if let project, !project.isInbox {
                CommandCenterView(library: library, project: project)
            } else {
                Text("Pick a project to see its command center.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .tracker:
            if let project, !project.records.isEmpty {
                TrackerPane(library: library, project: project)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "lock.doc").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(project == nil || project?.isInbox == true ? "Pick a project to see its tracker." : "No tracker or docs connected to \(project?.displayName ?? "this project") yet.")
                        .foregroundStyle(.secondary)
                    if let project, !project.isInbox {
                        Text("Add its folders in projects.json, or onboard it: Broski reads trackers in place and never copies them.")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .board:
            BoardView(library: library, items: visible, selectedID: $selectedID, showProject: project == nil)
        case .list:
            ItemList(library: library, items: visible, selectedID: $selectedID, showProject: project == nil, shortcut: shortcut)
        case .sessions:
            SessionsPane(library: library, sessions: sessions, title: nil, showProject: project == nil)
        case .screenshots:
            Gallery(items: items, sessions: sessions, selectedID: $selectedID)
        }
    }
}

struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

struct BannerView: View {
    @ObservedObject var library: Library
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: library.canUndo ? "trash" : "info.circle")
            Text(text).lineLimit(2)
            Spacer()
            if library.canUndo {
                Button("Undo") { library.undoDelete() }.buttonStyle(.borderless).foregroundStyle(Brand.purple)
            }
            Button { library.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.06))
    }
}

/// Sends whatever `make` builds to the chosen destination.
struct ExportMenu: View {
    @ObservedObject var library: Library
    let label: String
    let make: () -> Export

    var body: some View {
        Menu {
            ForEach(ExportTarget.allCases) { target in
                Button { send(target) } label: { Label(target.label, systemImage: target.symbol) }
                if target == .copy || target == .chatgpt || target == .notion { Divider() }
            }
        } label: {
            if label.isEmpty { Image(systemName: "paperplane") } else { Label(label, systemImage: "paperplane") }
        }
        .fixedSize()
    }

    private func send(_ target: ExportTarget) {
        let export = make()
        Task {
            let status = await Exporter.send(export, to: target)
            if !status.isEmpty { library.show(status) }
        }
    }
}

// MARK: Board

struct BoardView: View {
    @ObservedObject var library: Library
    let items: [Item]
    @Binding var selectedID: String?
    let showProject: Bool

    var body: some View {
        GeometryReader { geo in
            // Columns share the width; below ~180 pt each the board scrolls sideways instead.
            if geo.size.width - 32 - 36 >= 4 * 180 {
                columns(width: nil).padding(16)
            } else {
                ScrollView(.horizontal) { columns(width: 200).padding(16) }
            }
        }
    }

    private func columns(width: CGFloat?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(ItemStatus.allCases, id: \.self) { status in
                column(status).frame(width: width)
            }
        }
    }

    private func column(_ status: ItemStatus) -> some View {
        let cards = items.filter { $0.status == status }
            .sorted { ($0.priority, $0.updated) > ($1.priority, $1.updated) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(status.label).font(.system(size: 12, weight: .semibold))
                Text("\(cards.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cards) { item in
                        ItemCard(item: item, selected: item.id == selectedID, showProject: showProject)
                            .onTapGesture { selectedID = item.id }
                            .draggable(item.file.path)
                            .contextMenu { ItemMenu(library: library, item: item) }
                    }
                    if cards.isEmpty {
                        Text(status == .done ? "Drag finished things here" : "Nothing here")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .padding(10)
        .frame(minWidth: 170, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .dropDestination(for: String.self) { paths, _ in
            for path in paths {
                if let item = library.allItems.first(where: { $0.file.path == path }) { library.setStatus(item, status) }
            }
            return true
        }
    }
}

struct ItemCard: View {
    let item: Item
    let selected: Bool
    let showProject: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: item.kind.symbol).foregroundStyle(item.kind.color).font(.system(size: 12))
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(item.isDone, color: .secondary)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let first = item.attachmentURLs.first {
                Thumbnail(url: first, size: nil)
                    .frame(maxWidth: .infinity)
                    .frame(height: 90)
                    .clipped()
            }
            HStack(spacing: 6) {
                if item.priority >= .high {
                    Text(item.priority.rawValue).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(item.priority == .urgent ? Color.red : Color.orange))
                }
                if showProject { Text(item.project ?? "Inbox").foregroundStyle(Brand.purple) }
                ForEach(item.tags.prefix(2), id: \.self) { Text("#\($0)").foregroundStyle(.secondary) }
                Spacer()
                if item.attachments.count > 1 { Label("\(item.attachments.count)", systemImage: "photo").foregroundStyle(.secondary) }
                Text(item.created.formatted(.relative(presentation: .named))).foregroundStyle(.tertiary)
            }
            .font(.system(size: 10))
            .lineLimit(1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Brand.purple : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 0.5))
        .contentShape(Rectangle())
    }
}

/// Right-click actions shared by cards and rows.
struct ItemMenu: View {
    @ObservedObject var library: Library
    let item: Item

    var body: some View {
        Menu("Status") {
            ForEach(ItemStatus.allCases, id: \.self) { status in
                Button(status.label) { library.setStatus(item, status) }
            }
        }
        Menu("Type") {
            ForEach(NoteKind.allCases, id: \.self) { kind in
                Button(kind.label) { library.update(item) { $0.kind = kind } }
            }
        }
        Menu("Priority") {
            ForEach(Priority.allCases, id: \.self) { p in
                Button(p.rawValue.capitalized) { library.update(item) { $0.priority = p } }
            }
        }
        Menu("Move to") {
            Button("Inbox") { library.move(item, to: nil) }
            ForEach(library.projects) { p in Button(p.name) { library.move(item, to: p.name) } }
        }
        Divider()
        Button("Copy text") { Exporter.copy(item.body.isEmpty ? item.title : item.title + "\n\n" + item.body) }
        Button("Delete", role: .destructive) { library.delete(item) }
    }
}

// MARK: List

struct ItemList: View {
    @ObservedObject var library: Library
    let items: [Item]
    @Binding var selectedID: String?
    let showProject: Bool
    let shortcut: String

    var body: some View {
        if items.isEmpty {
            EmptyState(text: "Nothing here yet", detail: "Click Broski in the menu bar, press \(shortcut), or type above.")
        } else {
            List(selection: $selectedID) {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            ItemRow(library: library, item: item, showProject: showProject)
                                .tag(item.id)
                                .contextMenu { ItemMenu(library: library, item: item) }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private struct DayGroup {
        let title: String
        let items: [Item]
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        func bucket(_ date: Date) -> String {
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 { return "This week" }
            return date.formatted(.dateTime.month(.wide).year())
        }
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in items.sorted(by: { $0.created > $1.created }) {
            let key = bucket(item.created)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { DayGroup(title: $0, items: buckets[$0] ?? []) }
    }
}

struct ItemRow: View {
    @ObservedObject var library: Library
    let item: Item
    let showProject: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if item.kind == .todo || item.kind == .bug {
                Button { library.setStatus(item, item.isDone ? .todo : .done) } label: {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(item.isDone ? Color.green : item.kind.color)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: item.kind.symbol).font(.system(size: 13)).foregroundStyle(item.kind.color).frame(width: 15)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13.5))
                    .strikethrough(item.isDone, color: .secondary)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                if !item.body.isEmpty {
                    Text(item.body).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if showProject { Text(item.project ?? "Inbox").foregroundStyle(Brand.purple) }
                    Text(item.status.label).foregroundStyle(.secondary)
                    if item.priority >= .high { Text(item.priority.rawValue).foregroundStyle(.orange) }
                    ForEach(item.tags.prefix(3), id: \.self) { Text("#\($0)").foregroundStyle(.secondary) }
                    if !item.context.isEmpty { Label(item.context.app ?? "", systemImage: "eye").foregroundStyle(.tertiary) }
                    Text(item.created.formatted(.relative(presentation: .named))).foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
            }
            Spacer()
            if let first = item.attachmentURLs.first { Thumbnail(url: first, size: 44) }
        }
        .padding(.vertical, 4)
    }
}

struct EmptyState: View {
    let text: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(nsImage: BroskiArt.avatar(diameter: 72, crowned: false))
            Text(text).font(.system(size: 16, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Inspector

/// Edit one note: text, status, type, priority, tags, project, screenshots; send it anywhere.
struct ItemInspector: View {
    @ObservedObject var library: Library
    let item: Item
    let githubRepo: String?
    let onClose: () -> Void

    @State private var title = ""
    @State private var bodyText = ""
    @State private var tags = ""
    /// The note's text as last loaded or saved here. Only fields that differ from it are the user's edits,
    /// so a save never writes back text that changed underneath (Add more, a merge, the iPhone).
    @State private var baseTitle = ""
    @State private var baseBody = ""
    @State private var baseTags: [String] = []
    @State private var deleted = false
    @State private var editorID = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(item.kind.label, systemImage: item.kind.symbol).foregroundStyle(item.kind.color).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    ExportMenu(library: library, label: "Send") { Exporter.export(current, githubRepo: githubRepo) }
                    Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                TextField("Title", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold))
                    .onSubmit(commit)
                TextEditor(text: $bodyText)
                    .font(.system(size: 13))
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .overlay(alignment: .topLeading) {
                        if bodyText.isEmpty {
                            Text("Details, steps, a prompt to keep…").foregroundStyle(.tertiary).font(.system(size: 13)).padding(11).allowsHitTesting(false)
                        }
                    }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Status").foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { item.status }, set: { status in update { $0.status = status } })) {
                            ForEach(ItemStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Type").foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { item.kind }, set: { kind in update { $0.kind = kind } })) {
                            ForEach(NoteKind.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Priority").foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { item.priority }, set: { priority in update { $0.priority = priority } })) {
                            ForEach(Priority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Project").foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { item.project ?? "" }, set: { move(to: $0.isEmpty ? nil : $0) })) {
                            Text("Inbox").tag("")
                            ForEach(library.projects) { Text($0.name).tag($0.name) }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Tags").foregroundStyle(.secondary)
                        TextField("api, launch", text: $tags).textFieldStyle(.roundedBorder).onSubmit(commit)
                    }
                }
                .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Screenshots and files").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button { addFiles() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Attach files")
                    }
                    if item.attachments.isEmpty {
                        Text("None").font(.system(size: 11)).foregroundStyle(.tertiary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
                            ForEach(item.attachmentURLs, id: \.self) { url in
                                Thumbnail(url: url, size: 90).help("Double-click to open")
                            }
                        }
                    }
                }

                if !item.context.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("You were looking at").font(.system(size: 12, weight: .semibold))
                        if !item.context.summary.isEmpty { Text(item.context.summary).font(.system(size: 12)) }
                        if let url = item.context.url, let link = URL(string: url) {
                            Link(url, destination: link).font(.system(size: 11)).lineLimit(1)
                        }
                        if let selection = item.context.selection {
                            Text(selection).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(6)
                                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                        }
                    }
                }

                HStack {
                    Text("Created \(item.created.formatted(date: .abbreviated, time: .shortened))")
                    Spacer()
                    Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([item.file]) }.buttonStyle(.borderless)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Button("Delete note", role: .destructive) { deleteNote() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
            .padding(16)
        }
        .onAppear {
            title = item.title
            bodyText = item.body
            tags = item.tags.joined(separator: ", ")
            rebase(on: item)
            library.registerEditor(editorID) { commit() }
        }
        .onDisappear {
            commit()
            library.unregisterEditor(editorID)
        }
        .onChange(of: bodyText) { _ in if editedBody != baseBody { scheduleSave() } }
        .onChange(of: item) { fresh in adopt(fresh) }
    }

    private var editedTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? baseTitle : t
    }
    private var editedBody: String { bodyText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var editedTags: [String] { Self.normalized(tags.split(separator: ",").map(String.init)) }

    /// Tags as the field reads them back, so a note's own uppercase tags don't count as edits.
    private static func normalized(_ tags: [String]) -> [String] {
        tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    private var hasEdits: Bool { editedTitle != baseTitle || editedBody != baseBody || editedTags != baseTags }

    /// The note as it is now. `item` can be a render behind, and a debounced save holds an older copy;
    /// matched by file, so a note that was moved or deleted is never written back to its old path.
    private var latest: Item? {
        let file = item.file.standardizedFileURL
        return library.allItems.first { $0.file.standardizedFileURL == file }
    }

    /// The newest copy of the note with only the fields the user edited applied.
    private var current: Item {
        var edited = latest ?? item
        if editedTitle != baseTitle { edited.title = editedTitle }
        if editedBody != baseBody { edited.body = editedBody }
        if editedTags != baseTags { edited.tags = editedTags }
        return edited
    }

    private func rebase(on note: Item) {
        baseTitle = note.title
        baseBody = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        baseTags = Self.normalized(note.tags)
    }

    /// Takes in a newer version of the note without discarding typing in progress.
    private func adopt(_ fresh: Item) {
        let freshBody = fresh.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if editedTitle == baseTitle, fresh.title != baseTitle { title = fresh.title }
        if editedTags == baseTags, Self.normalized(fresh.tags) != baseTags { tags = fresh.tags.joined(separator: ", ") }
        if freshBody != baseBody {
            if editedBody == baseBody {
                bodyText = fresh.body
            } else if freshBody.hasPrefix(baseBody) {
                // Text was added below (Add more, a merge): keep the typing and carry the addition along.
                let addition = freshBody.dropFirst(baseBody.count).trimmingCharacters(in: .whitespacesAndNewlines)
                bodyText = [editedBody, addition].filter { !$0.isEmpty }.joined(separator: "\n\n")
            } else {
                library.show("This note changed elsewhere while you were typing. Your version is kept.")
            }
        }
        rebase(on: fresh)
    }

    @State private var saveTask: Task<Void, Never>?

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { commit() }
        }
    }

    private func commit() {
        saveTask?.cancel()
        guard !deleted else { return }
        let edited = current
        guard let fresh = latest else {
            // The note went away outside Broski (in-app moves, merges and deletes flush first): write the typing back.
            if hasEdits, library.save(edited) { rebase(on: edited) }
            return
        }
        // Rebase only once the text is on disk, so a failed write is retried by the next commit.
        if edited == fresh || library.save(edited) { rebase(on: edited) }
    }

    /// Saves the typing first, then changes the newest copy of the note, so neither overwrites the other.
    private func update(_ change: (inout Item) -> Void) {
        commit()
        guard let fresh = latest else { return }
        var changed = fresh
        change(&changed)
        // Applied to the note as it is on disk: this copy can be older than a change the phone made.
        if changed != fresh { library.update(fresh, change) }
    }

    private func move(to project: String?) {
        // Flush first: a save after the move would write the old path and bring the note back as a duplicate.
        commit()
        guard let fresh = latest else { return }
        library.move(fresh, to: project)
    }

    private func deleteNote() {
        commit()
        deleted = true
        if let fresh = latest { library.delete(fresh) }
        onClose()
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        commit()
        guard let fresh = latest else { return }
        library.attach(panel.urls, to: fresh)
    }
}

// MARK: Sessions

struct SessionsPane: View {
    @ObservedObject var library: Library
    let sessions: [Session]
    let title: String?
    let showProject: Bool
    @State private var selectedID: String?

    private var selected: Session? { sessions.first { $0.id == selectedID } ?? sessions.first }

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                HStack {
                    Text(title).font(.system(size: 24, weight: .bold))
                    Spacer()
                }
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 12)
                Divider()
            }
            if sessions.isEmpty {
                EmptyState(text: "No sessions yet",
                           detail: "Say “Broski, start a QA session for <project>”, then take screenshots and talk over them.\nSay “wrap up” and Broski writes the report.")
            } else {
                HStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(sessions) { session in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Image(systemName: session.isActive ? "record.circle" : session.hasReport ? "doc.text.fill" : "rectangle.stack")
                                        .foregroundStyle(session.isActive ? Color.red : Brand.purple)
                                    Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                }
                                Text("\(session.kind.label) · \(session.entries.count) captures · \(session.started.formatted(date: .abbreviated, time: .shortened))"
                                     + (showProject ? " · \(session.project ?? "Inbox")" : ""))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                            .tag(session.id)
                        }
                    }
                    .listStyle(.inset)
                    .frame(width: 290)
                    Divider()
                    if let session = selected {
                        SessionDetail(library: library, session: session).id(session.id)
                    }
                }
            }
            if let banner = library.banner, title != nil { BannerView(library: library, text: banner) }
        }
    }
}

struct SessionDetail: View {
    @ObservedObject var library: Library
    let session: Session
    @State private var showReport = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).font(.system(size: 18, weight: .bold))
                    Text("\(session.kind.label) · \(session.entries.count) captures · \(session.screenshotCount) screenshots"
                         + (session.isActive ? " · running" : ""))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if session.isActive {
                    Button("End session") { library.endSession(session) }
                }
                if library.writingReport == session.id {
                    ProgressView().controlSize(.small)
                    Text("Writing report…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button(session.hasReport ? "Rewrite report" : "Write report") {
                        Task { await library.writeReport(for: session) }
                    }
                    .disabled(session.entries.isEmpty)
                }
                if let issues = library.pendingIssues[session.id], !issues.isEmpty {
                    Button("Add \(issues.count) bugs to board") { library.addIssuesToBoard(from: session) }
                        .foregroundStyle(Brand.purple)
                }
                ExportMenu(library: library, label: "Send") {
                    Exporter.export(session, githubRepo: library.project(named: session.project)?.githubRepo)
                }
            }
            .padding(16)
            if session.hasReport {
                Picker("", selection: $showReport) {
                    Text("Report").tag(true)
                    Text("Captures").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .padding(.bottom, 8)
            }
            Divider()
            if session.hasReport && showReport {
                MarkdownWebView(markdown: (try? String(contentsOf: session.reportFile, encoding: .utf8)) ?? "", baseFolder: session.folder)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(session.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary)
                                if !entry.text.isEmpty { Text(entry.text).font(.system(size: 13)).textSelection(.enabled) }
                                ForEach(entry.attachments, id: \.self) { path in
                                    let url = session.folder.appendingPathComponent(path)
                                    if let image = Thumbnail.image(url, maxPixels: 1040) {
                                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                            .frame(maxWidth: 520, maxHeight: 320, alignment: .leading)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                                    }
                                }
                                if !entry.context.isEmpty {
                                    Text([entry.context.summary, entry.context.url ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                            }
                            Divider()
                        }
                        if session.entries.isEmpty {
                            Text("No captures yet. Press ⌥⇧S to screenshot something and say what's wrong.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                }
            }
        }
    }
}

/// Renders markdown (with embedded screenshots) the same way the PDF export does.
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let baseFolder: URL?

    /// What the view last loaded. Every library change re-renders it, and rebuilding the page re-encodes every
    /// screenshot and reloads it, jumping back to the top.
    final class Coordinator {
        var loaded: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "\(dark)|\(markdown)"
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        var html = MarkdownHTML.document(title: "", markdown: markdown, baseFolder: baseFolder)
        if dark {
            html = html.replacingOccurrences(of: "color: #1d1d1f;", with: "color: #e8e8ea;")
                .replacingOccurrences(of: "background: #f2f2f4", with: "background: #2a2a2e")
                .replacingOccurrences(of: "background: #f5f5f7", with: "background: #2a2a2e")
                .replacingOccurrences(of: "border: 1px solid #ddd", with: "border: 1px solid #444")
        }
        view.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: Screenshots

struct Gallery: View {
    let items: [Item]
    let sessions: [Session]
    @Binding var selectedID: String?

    private struct Shot: Identifiable {
        let url: URL
        let caption: String
        let itemID: String?
        var id: String { url.path }
    }

    private var shots: [Shot] {
        items.flatMap { item in item.attachmentURLs.map { Shot(url: $0, caption: item.title, itemID: item.id) } }
            + sessions.flatMap { s in s.entries.flatMap { e in e.attachments.map { Shot(url: s.folder.appendingPathComponent($0), caption: e.text.isEmpty ? s.title : e.text, itemID: nil) } } }
    }

    var body: some View {
        if shots.isEmpty {
            EmptyState(text: "No screenshots yet", detail: "Press ⌥⇧S anywhere to grab part of the screen and say what it's about.")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    ForEach(shots) { shot in
                        VStack(alignment: .leading, spacing: 6) {
                            if let image = Thumbnail.image(shot.url, maxPixels: 800) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                    .frame(height: 130).frame(maxWidth: .infinity).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Text(shot.caption).font(.system(size: 11)).lineLimit(2)
                        }
                        .onTapGesture { if let id = shot.itemID { selectedID = id } }
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(shot.url) }
                    }
                }
                .padding(18)
            }
        }
    }
}
