import BroskiCore
import SwiftUI

/// ⌘K in the conversation: type a few letters, arrows to move, Return to do it, Esc to close.
/// What's offered and how it's ranked live in BroskiCore (`Palette`); this only shows them.
struct CommandPalette: View {
    var items: [PaletteItem]
    var pick: (PaletteItem) -> Void
    var close: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [PaletteItem] { Palette.search(query, in: items) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Type a command or a project", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { choose(selected) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onExitCommand(perform: close)
                    .onChange(of: query) { _ in selected = 0 }
                    .accessibilityLabel("Command")
                Text("esc").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                    .accessibilityHidden(true)
            }
            .padding(12)
            Divider()
            if results.isEmpty {
                Text("Nothing matches “\(query)”. Try another word, or Esc to go back.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                Button { choose(index) } label: { row(item, selected: index == selected) }
                                    .buttonStyle(.plain)
                                    .id(index)
                                    .accessibilityAddTraits(index == selected ? .isSelected : [])
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selected) { proxy.scrollTo($0) }
                }
            }
        }
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .onAppear { focused = true }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            if case .project(let name?) = item.action {
                ProjectDot(project: name, size: 8).frame(width: 16)
            } else {
                Image(systemName: Self.symbol(item.action)).font(.system(size: 12))
                    .foregroundStyle(selected ? Brand.purple : .secondary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13))
                Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "return").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Brand.purple.opacity(0.12) : .clear))
    }

    private func move(_ step: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + step + results.count) % results.count
    }

    private func choose(_ index: Int) {
        guard results.indices.contains(index) else { return }
        pick(results[index])
    }

    static func symbol(_ action: PaletteItem.Action) -> String {
        switch action {
        case .note: return "square.and.pencil"
        case .saveThat: return "checkmark.square"
        case .toggleDeep: return "brain"
        case .startRiff, .wrapUp: return "bubble.left.and.bubble.right"
        case .togglePrivate: return "lock"
        case .project: return "xmark.circle"
        case .dashboard: return "square.grid.2x2"
        case .memory: return "book"
        case .vault: return "lock.shield"
        case .settings: return "gearshape"
        case .setUpBrief: return "doc.text"
        case .askClaudeCode: return "doc.on.clipboard"
        case .howItWorks: return "questionmark.circle"
        }
    }
}
