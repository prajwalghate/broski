import BroskiCore
import SwiftUI

/// Every project and its notes. Same files as the Mac dashboard when the folder is shared.
struct NotesView: View {
    @ObservedObject var store: PhoneStore
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if !search.isEmpty {
                    Section("Results") {
                        ForEach(results, id: \.file) { item in
                            NavigationLink { ItemDetail(item: item, store: store) } label: { ItemRow(item: item, showProject: true) }
                        }
                    }
                } else {
                    if let session = store.activeSession {
                        Section {
                            Label("\(session.kind.label): \(session.title) · \(session.entries.count) captures", systemImage: "record.circle")
                                .foregroundStyle(.red)
                        }
                    }
                    Section {
                        NavigationLink { ProjectNotes(project: nil, store: store) } label: {
                            folderRow("Inbox", symbol: "tray", count: store.items(in: nil).count)
                        }
                    }
                    Section("Projects") {
                        if store.projects.isEmpty {
                            Text("Projects from your Mac show up here once the Broski folder is shared (Settings).")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(store.projects, id: \.self) { name in
                            NavigationLink { ProjectNotes(project: name, store: store) } label: {
                                folderRow(name, symbol: "folder", count: store.items(in: name).filter { $0.status != .done }.count)
                            }
                        }
                    }
                    if !recent.isEmpty {
                        Section("Recent") {
                            ForEach(recent, id: \.file) { item in
                                NavigationLink { ItemDetail(item: item, store: store) } label: { ItemRow(item: item, showProject: true) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Notes")
            .searchable(text: $search, prompt: "Search every note")
            .refreshable { store.reload() }
            .overlay {
                if store.items.isEmpty && store.projects.isEmpty && search.isEmpty {
                    ContentUnavailableView("No notes yet", systemImage: "square.stack",
                                           description: Text("Notes you save show up here."))
                }
            }
        }
    }

    private var recent: [Item] { Array(store.items.prefix(8)) }

    private var results: [Item] {
        let query = search.lowercased()
        return store.items.filter { ($0.title + " " + $0.body + " " + $0.tags.joined(separator: " ")).lowercased().contains(query) }
    }

    private func folderRow(_ name: String, symbol: String, count: Int) -> some View {
        HStack {
            Label(name, systemImage: symbol)
            Spacer()
            if count > 0 { Text("\(count)").foregroundStyle(.secondary) }
        }
    }
}

struct ProjectNotes: View {
    let project: String?
    @ObservedObject var store: PhoneStore
    @State private var showDone = false

    var body: some View {
        List {
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            if let project, let page = store.pages[project] { PageSection(page: page, store: store) }
            let all = store.items(in: project)
            let open = all.filter { $0.status != .done }
            let done = all.filter { $0.status == .done }
            ForEach(open, id: \.file) { item in row(item) }
            if !done.isEmpty {
                Section {
                    DisclosureGroup("Done (\(done.count))", isExpanded: $showDone) {
                        ForEach(done, id: \.file) { item in row(item) }
                    }
                }
            }
        }
        .navigationTitle(project ?? "Inbox")
        .refreshable { store.reload() }
        .overlay {
            if store.items(in: project).isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "tray")
            }
        }
    }

    private func row(_ item: Item) -> some View {
        NavigationLink { ItemDetail(item: item, store: store) } label: { ItemRow(item: item, showProject: false) }
            .swipeActions(edge: .leading) {
                Button { toggleDone(item) } label: {
                    Label(item.status == .done ? "Reopen" : "Done", systemImage: item.status == .done ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(.green)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    _ = try? store.store.delete(item)
                    store.reload()
                } label: { Label("Delete", systemImage: "trash") }
            }
    }

    private func toggleDone(_ item: Item) {
        do {
            // The note as it is on disk now, not this list's copy, so an edit made on the Mac since survives.
            try store.store.update(item) { $0.status = item.status == .done ? .todo : .done }
        } catch {
            store.problem = error.localizedDescription
        }
        store.reload()
    }
}

struct ItemRow: View {
    let item: Item
    let showProject: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(item.kind.color)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .lineLimit(2)
                    .strikethrough(item.status == .done, color: .secondary)
                    .foregroundStyle(item.status == .done ? .secondary : .primary)
                HStack(spacing: 6) {
                    if showProject { Text(item.project ?? "Inbox") }
                    Text(item.updated, format: .relative(presentation: .named))
                    if !item.attachments.isEmpty { Label("\(item.attachments.count)", systemImage: "photo").labelStyle(.titleAndIcon) }
                    if item.priority == .high || item.priority == .urgent {
                        Text(item.priority.rawValue).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ItemDetail: View {
    let item: Item
    @ObservedObject var store: PhoneStore
    @State private var zoomed: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Label(item.kind.label, systemImage: item.kind.symbol).foregroundStyle(item.kind.color)
                    Text("·")
                    Text(item.project ?? "Inbox")
                    Text("·")
                    Text(item.status.label)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Text(item.title).font(.title2.weight(.semibold))

                if !item.body.isEmpty {
                    Text((try? AttributedString(markdown: item.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(item.body))
                        .textSelection(.enabled)
                }

                if !item.attachments.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        ForEach(item.attachmentURLs, id: \.self) { url in
                            FileImage(url: url)
                                .frame(height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .onTapGesture { zoomed = url }
                        }
                    }
                }

                if !item.context.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Captured from").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if !item.context.summary.isEmpty { Text(item.context.summary).font(.footnote) }
                        if let link = item.context.url, let url = URL(string: link) {
                            Link(url.host ?? link, destination: url).font(.footnote)
                        }
                    }
                }

                Text("Created \(item.created.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: shareText, subject: Text(item.title)) { Image(systemName: "square.and.arrow.up") }
                Menu {
                    Button {
                        do {
                            // The note as it is on disk now: what the Mac added since this screen opened stays.
                            try store.store.update(item) { $0.status = item.status == .done ? .todo : .done }
                        } catch {
                            store.problem = error.localizedDescription
                        }
                        store.reload()
                        dismiss()
                    } label: { Label(item.status == .done ? "Reopen" : "Mark done", systemImage: "checkmark") }
                    Button(role: .destructive) {
                        _ = try? store.store.delete(item)
                        store.reload()
                        dismiss()
                    } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .fullScreenCover(item: $zoomed) { url in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                FileImage(url: url, maxSide: 2400).scaledToFit()
                Button { zoomed = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.white, .black.opacity(0.5))
                }
                .padding()
            }
        }
    }

    /// Ready to paste into Claude, ChatGPT, Slack or an issue.
    private var shareText: String {
        var out = "# \(item.title)\n\n"
        out += "\(item.kind.label) · \(item.project ?? "Inbox") · \(item.status.label)\n\n"
        if !item.body.isEmpty { out += item.body + "\n\n" }
        if let url = item.context.url { out += "Source: \(url)\n" }
        return out
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
