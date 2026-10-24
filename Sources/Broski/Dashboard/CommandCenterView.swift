import AppKit
import BroskiCore
import SwiftUI

/// A project's command center: its packs, a tile per widget filled with what Broski knows, and every pack section of
/// its tracker with how much is in it. Built from the project's setup/command-center.json (edit it to change the
/// widgets), or from core and the packs its folders suggest.
struct CommandCenterView: View {
    @ObservedObject var library: Library
    let project: Library.ProjectInfo

    private var root: URL { library.store.root }
    private var folders: [URL] {
        let listed = (project.entry?.folders ?? []).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        return listed.isEmpty ? [project.folder].compactMap { $0 } : listed
    }
    private var center: CommandCenter { CommandCenter.load(project: project.name, root: root, folders: folders) }
    private var setupFolder: URL { root.appendingPathComponent("projects/\(project.name)/setup", isDirectory: true) }

    var body: some View {
        let center = center
        let tiles = CommandCenter.tiles(center, items: project.items, decisions: DecisionLog.current(root: root, project: project.name),
                                        records: project.records)
        let sections = CommandCenter.sections(center, records: project.records)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(center)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(tiles) { tileView($0) }
                }
                if !sections.isEmpty {
                    Text("TRACKER SECTIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(sections) { row in
                            sectionRow(row)
                            if row.id != sections.last?.id { Divider() }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ center: CommandCenter) -> some View {
        HStack(spacing: 8) {
            Text("Packs").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(center.packs, id: \.id) { pack in
                Text(pack.name).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Brand.purple.opacity(0.12)))
                    .help(pack.about)
            }
            Spacer()
            if center.fromSetup {
                Button("Edit widgets") { NSWorkspace.shared.open(setupFolder.appendingPathComponent("command-center.json")) }
                Button("Setup folder") { NSWorkspace.shared.open(setupFolder) }
            } else {
                Text("From its folders. Packs and widgets are set when a project is created in a conversation.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
    }

    private func tileView(_ tile: CommandCenter.Tile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tile.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let count = tile.count, count > 0 {
                    Text("\(count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Brand.purple)
                }
            }
            if let empty = tile.empty, tile.lines.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(tile.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func sectionRow(_ row: CommandCenter.SectionRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .medium))
                    Text(row.pack).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(row.newest.map { "Newest: \($0)" } ?? row.about).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(row.count == 0 ? "empty" : "\(row.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
