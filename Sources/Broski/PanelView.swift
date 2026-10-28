import AppKit
import BroskiCore
import BroskiWhisper
import SwiftUI

@MainActor
final class PanelModel: ObservableObject {
    enum Phase { case listening, typing, transcribing, thinking, saving, saved, cancelled, error }

    @Published var phase: Phase = .typing
    @Published var text = ""
    /// Apple's live preview while you talk; Whisper replaces it when you stop.
    @Published var liveText = ""
    @Published var level: Float = 0
    @Published var attachments: [URL] = []
    @Published var context = ItemContext()
    @Published var session: Session?
    /// Picked by hand in the panel; wins over what Claude decides.
    @Published var manualDestination: Destination?
    @Published var manualKind: NoteKind?
    @Published var projects: [Project] = []
    @Published var detail = ""
    @Published var savedTitle = ""
    @Published var savedDetail = ""
    @Published var needsPermission = false
    @Published var needsScreenPermission = false
    /// Where Broski would file the current text; shown before you save.
    @Published var proposal: Interpretation?
    @Published var thinkingProposal = false
    @Published var aiEnabled = false
    @Published var whisperState: Transcription.State = .missing
    /// Which local engine writes the text ("Bark" or "Whisper").
    @Published var voiceEngine = "Whisper"
    @Published var focusTick = 0
    /// Push-to-talk: letting go of the shortcut or head stops the mic.
    @Published var holding = false
    /// Whisper is still writing out a phrase you said.
    @Published var transcribingChunk = false
    /// The text came back from a note you closed without saving.
    @Published var restoredDraft = false
    /// Highlighted text from other apps, quoted in the note.
    @Published var clips: [Clip] = []
    /// Set when this capture carries on an existing note instead of making a new one.
    @Published var appendTarget: Item? {
        // Adding to a note and a pinned destination can't both hold; the note wins, as the panel says.
        didSet { if appendTarget != nil { manualDestination = nil } }
    }
    /// The note saved last, offered in the destination menu.
    @Published var lastItem: Item?
    @Published var needsAccessibility = false
    @Published var clipShortcut = "⌥⇧C"
    /// An open note that says nearly the same thing, offered as "add to it instead".
    @Published var duplicate: Item?
    /// Other notes about the same thing.
    @Published var related: [Item] = []
    @Published var shortcut = "⌥⇧B"
    @Published var screenshotShortcut = "⌥⇧S"

    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}
    var onUndo: () -> Void = {}
    var onOpen: () -> Void = {}
    var onUserEdit: (String) -> Void = { _ in }
    var onToggleVoice: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onScreenshot: () -> Void = {}
    var onPaste: () -> Void = {}
    var onRemoveAttachment: (URL) -> Void = { _ in }
    var onEndSession: () -> Void = {}
    var onDownloadModel: () -> Void = {}
    var onDiscardDraft: () -> Void = {}
    var onRemoveClip: (UUID) -> Void = { _ in }
    var onQuoteSelection: () -> Void = {}
    var onAddMore: () -> Void = {}
    var onAllowAccessibility: () -> Void = {}
    var onRestart: () -> Void = {}
    var onPickAppendTarget: (Item?) -> Void = { _ in }
    var onUseDuplicate: () -> Void = {}
    var onOpenRelated: (String) -> Void = { _ in }

    func reset(projects: [Project]) {
        text = ""
        liveText = ""
        detail = ""
        level = 0
        attachments = []
        manualDestination = nil
        manualKind = nil
        needsPermission = false
        needsScreenPermission = false
        proposal = nil
        thinkingProposal = false
        holding = false
        transcribingChunk = false
        restoredDraft = false
        clips = []
        duplicate = nil
        related = []
        appendTarget = nil
        needsAccessibility = false
        savedTitle = ""
        savedDetail = ""
        self.projects = projects
    }

    var editable: Bool { phase == .listening || phase == .typing }
    var busy: Bool { phase == .transcribing || phase == .thinking || phase == .saving }
}

struct PanelView: View {
    static let width: CGFloat = 500
    static let height: CGFloat = 300

    /// Room for up to two clip cards (the rest fold into "+ n more") and the "adding to" bar.
    static func height(clips: Int, appending: Bool) -> CGFloat {
        height + (clips == 0 ? 0 : CGFloat(min(clips, 2)) * 52 + (clips > 2 ? 18 : 0)) + (appending ? 34 : 0)
    }

    /// The height for what the panel shows right now. The base fits one plan line and the context line;
    /// the session bar, the "Looks like…/Related" row and a plan that wraps to two lines each need more,
    /// or the footer (Save, Discard draft, Allow Accessibility) is pushed out of the frame.
    static func height(for model: PanelModel) -> CGFloat {
        guard showsEditor(model) else { return height }
        let session = model.session != nil
        let related = (model.phase == .typing || model.phase == .listening) && (model.duplicate != nil || !model.related.isEmpty)
        // About 66 characters fit on one 11pt line beside the arrow.
        let twoLinePlan = model.phase == .typing && !(model.thinkingProposal && model.proposal == nil) && (plan(for: model)?.count ?? 0) > 66
        return height(clips: model.clips.count, appending: model.appendTarget != nil)
            + (session ? 32 : 0) + (related ? 23 : 0) + (twoLinePlan ? 14 : 0)
    }

    static func showsEditor(_ model: PanelModel) -> Bool {
        !(model.phase == .saved || model.phase == .saving && !model.savedTitle.isEmpty)
    }

    @ObservedObject var model: PanelModel
    @FocusState private var editorFocused: Bool

    private static let avatar = Image(nsImage: BroskiArt.avatar(diameter: 30, crowned: false))
    private static let crownedAvatar = Image(nsImage: BroskiArt.avatar(diameter: 30, crowned: true))

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let session = model.session, model.phase != .saved || session.isActive { sessionBar(session) }
            if !showsEditor {
                result
            } else {
                if let target = model.appendTarget { appendBar(target) }
                editor
                if !model.clips.isEmpty { clipList }
                if model.phase == .typing { proposalLine }
                if model.phase == .typing || model.phase == .listening { relatedLine }
                contextLine
                attachmentStrip
                chips
            }
            Spacer(minLength: 0)
            Divider().opacity(0.6)
            footer
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: Self.width, height: Self.height(for: model), alignment: .topLeading)
        .onExitCommand { model.onCancel() }
        .onReceive(model.$focusTick.dropFirst()) { _ in editorFocused = true }
    }

    private var showsEditor: Bool { Self.showsEditor(model) }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            (model.phase == .saved ? Self.crownedAvatar : Self.avatar)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if model.phase == .listening { LevelBars(level: model.level, color: Brand.purple) }
            // Also while typing: typing over the mic leaves the last phrase still being written out.
            if model.busy || model.transcribingChunk && (model.phase == .listening || model.phase == .typing) {
                ProgressView().controlSize(.small)
                    .help("Whisper is writing out what you just said")
            }
            if model.editable {
                Button { model.onToggleVoice() } label: {
                    Image(systemName: model.phase == .listening ? "mic.fill" : "mic")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.phase == .listening ? Color.white : Color.primary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(model.phase == .listening ? Color.red : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(model.phase == .listening ? "Stop the mic (keeps what you said)" : "Turn on the mic, or hold \(model.shortcut) to talk")
            }
            Button { model.onCancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Close (esc)")
        }
    }

    private func sessionBar(_ session: Session) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle").foregroundStyle(.red)
            Text("\(session.kind.label): \(session.title)").lineLimit(1)
            Text("· \(session.entries.count) captures").foregroundStyle(.secondary)
            Spacer()
            if model.editable {
                Button("Wrap up") { model.onEndSession() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Brand.purple)
                    .help("End the session and write the report")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
    }

    private func appendBar(_ item: Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.append").foregroundStyle(Brand.purple)
            Text("Adding to “\(item.title)”").lineLimit(1).truncationMode(.tail)
            Text("· \(item.project ?? "Inbox")").foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if model.editable {
                Button("New note instead") { model.onPickAppendTarget(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Brand.purple.opacity(0.08)))
    }

    private var clipList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.clips.suffix(2)) { clip in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Brand.purple.opacity(0.7)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clip.text).font(.system(size: 12)).lineLimit(2).truncationMode(.tail)
                        Text(clipSource(clip)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if model.editable {
                        Button { model.onRemoveClip(clip.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this clip")
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .frame(height: 46, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
            }
            if model.clips.count > 2 {
                Text("+ \(model.clips.count - 2) earlier clip\(model.clips.count == 3 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }

    private func clipSource(_ clip: Clip) -> String {
        let place = [clip.source.window, clip.source.app].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let host = clip.source.url.flatMap { URL(string: $0)?.host }
        let where_ = [place, host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return "— " + (where_.isEmpty ? "somewhere" : where_)
    }

    // MARK: Editing

    @ViewBuilder private var editor: some View {
        Group {
            if model.editable {
                // A real text editor: Return is a new line. ⌘Return saves.
                VStack(alignment: .leading, spacing: 2) {
                    ZStack(alignment: .topLeading) {
                        if model.text.isEmpty && model.liveText.isEmpty {
                            Text(placeholder)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: Binding(get: { model.text }, set: { model.onUserEdit($0) }))
                            .scrollContentBackground(.hidden)
                            .scrollIndicators(.never)
                            .focused($editorFocused)
                    }
                    // What's being heard, under the written text: newest words kept, so a long note never hides them.
                    if model.phase == .listening && !model.liveText.isEmpty {
                        Text(liveTail)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.head)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                Text(model.text.isEmpty ? (model.phase == .transcribing ? "Turning your voice into text…" : " ") : model.text)
                    .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                    .lineLimit(4)
            }
        }
        .font(.system(size: 15))
        // TextEditor insets its text by 5pt; line it up with the rest of the panel.
        .padding(.leading, model.editable ? -5 : 0)
        .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 92, alignment: .topLeading)
    }

    /// The newest words of the live preview, about two lines' worth, cut at a word.
    private var liveTail: String {
        let text = model.liveText
        guard text.count > 130 else { return text }
        let tail = text.suffix(130)
        let start = tail.firstIndex(of: " ").map { tail.index(after: $0) } ?? tail.startIndex
        return "…" + String(tail[start...])
    }

    /// "Will save to strado as a bug: …", so you can check before pressing ⌘Return.
    /// "Looks like “Login stays disabled” (strado) · Add to it" or "Related: …".
    @ViewBuilder private var relatedLine: some View {
        if let duplicate = model.duplicate {
            HStack(spacing: 6) {
                Image(systemName: "square.on.square").foregroundStyle(.orange)
                Text("Looks like “\(duplicate.title)”" + " (\(duplicate.project ?? "Inbox"))").lineLimit(1).truncationMode(.middle)
                Button("Add to it") { model.onUseDuplicate() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Brand.purple)
                    .help("Add this under the existing note instead of making a new one")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        } else if !model.related.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Text("Related:")
                ForEach(model.related, id: \.id) { item in
                    Button { model.onOpenRelated(item.id) } label: {
                        Text(item.title).lineLimit(1).truncationMode(.tail)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Brand.purple)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var proposalLine: some View {
        if model.thinkingProposal && model.proposal == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Working out where this goes…")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        } else if let plan = proposalText {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(Brand.purple)
                Text(plan).lineLimit(2)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .help("Change it with the chips below, edit the text, or press ⌘Return to save")
        }
    }

    private var proposalText: String? { Self.plan(for: model) }

    /// Static so the panel's height can allow for a plan that wraps.
    static func plan(for model: PanelModel) -> String? {
        if let target = model.appendTarget, model.manualDestination == nil {
            return "Will add this under “\(target.title)” · ⌘⏎ to add"
        }
        guard let p = model.proposal else { return nil }
        switch p.action {
        case "start_session":
            let kind = SessionKind(rawValue: p.sessionKind)?.label ?? "Session"
            return "Will start a \(kind.lowercased())" + (p.project.isEmpty ? "" : " for \(p.project)") + " · ⌘⏎ to start"
        case "end_session": return "Will wrap up the session and write the report · ⌘⏎ to confirm"
        case "open_dashboard": return "Will open the dashboard" + (p.project.isEmpty ? "" : " on \(p.project)") + " · ⌘⏎ to open"
        case "cancel": return "Sounds like you want to drop this · ⌘⏎ to confirm, or edit it"
        default:
            let kind = model.manualKind?.label.lowercased() ?? p.kind
            let place: String
            if let manual = model.manualDestination { place = manual.displayName }
            else if let session = model.session { place = session.title }
            else { place = p.project.isEmpty ? "Inbox" : p.project }
            let title = p.title.isEmpty ? "" : ": “\(p.title)”"
            return "Will save to \(place) as \(kind == "idea" ? "an" : "a") \(kind)\(title)"
        }
    }

    @ViewBuilder private var contextLine: some View {
        if !model.context.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "eye")
                Text("From " + [model.context.summary, model.context.url.flatMap { URL(string: $0)?.host }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.context.selection != nil {
                    Button("+ quote highlighted text") { model.onQuoteSelection() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Brand.purple)
                        .help("Add the text you had highlighted as a quote")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help("Broski keeps what you were looking at with the note")
        }
    }

    private var attachmentStrip: some View {
        HStack(spacing: 8) {
            ForEach(model.attachments, id: \.self) { url in
                Thumbnail(url: url, size: 40)
                    .overlay(alignment: .topTrailing) {
                        if model.editable {
                            Button { model.onRemoveAttachment(url) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Remove this screenshot")
                            .offset(x: 4, y: -4)
                        }
                    }
            }
            if model.editable {
                Button(action: model.onScreenshot) {
                    Label("Screenshot", systemImage: "camera.viewfinder")
                }
                .help("Select part of the screen (\(model.screenshotShortcut) from anywhere)")
                Button(action: model.onPaste) {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .help("Attach the image or text on the clipboard")
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(minHeight: 40)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            Button(action: pickDestination) {
                Chip(symbol: destinationSymbol, text: destinationText, tint: Brand.purple, pinned: model.manualDestination != nil, menu: true)
            }
            .buttonStyle(.plain)
            .disabled(!model.editable)
            .help("Pick the project yourself, or let Broski decide from what you say")

            Button(action: pickKind) {
                Chip(symbol: (model.manualKind ?? .note).symbol, text: model.manualKind?.label.lowercased() ?? "type: auto",
                     tint: model.manualKind?.color ?? .secondary, pinned: model.manualKind != nil, menu: true)
            }
            .buttonStyle(.plain)
            .disabled(!model.editable)
            Spacer()
            brainBadge
        }
    }

    @ViewBuilder private var brainBadge: some View {
        switch model.whisperState {
        case .missing, .failed:
            Button(action: model.onDownloadModel) {
                Label("Get better voice", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Brand.purple)
            .help("Download a local voice model for much better transcription (Settings › Voice)")
        case .downloading(let fraction):
            Text("Downloading voice model \(Int(fraction * 100))%").font(.system(size: 11)).foregroundStyle(.secondary)
        case .preparing:
            Text("Preparing the voice model…").font(.system(size: 11)).foregroundStyle(.secondary)
                .help("Compiling it for this Mac, once. Apple's dictation writes the text meanwhile.")
        case .ready:
            Label(model.aiEnabled ? "\(model.voiceEngine) + Claude" : model.voiceEngine, systemImage: model.aiEnabled ? "sparkles" : "waveform")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .help(model.aiEnabled ? "Local \(model.voiceEngine) writes the text; your model files it" : "Choose a model in Settings › Models to tidy and file notes automatically")
        }
    }

    // MARK: Result

    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.savedTitle).font(.system(size: 15, weight: .semibold)).lineLimit(3)
            if !model.savedDetail.isEmpty {
                Text(model.savedDetail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
            }
            if !model.attachments.isEmpty {
                HStack(spacing: 8) { ForEach(model.attachments, id: \.self) { Thumbnail(url: $0, size: 40) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerText)
                .font(.system(size: 11))
                .foregroundStyle(model.phase == .error ? Color.red : .secondary)
                .lineLimit(model.phase == .error ? 2 : 1)
                .truncationMode(.middle)
                .help(footerText)
            Spacer()
            switch model.phase {
            case .listening, .typing:
                if model.needsScreenPermission {
                    Button("Open Settings") { Screenshot.openScreenRecordingSettings() }
                    Button("Restart Broski") { model.onRestart() }
                        .help("macOS applies Screen Recording access after Broski restarts; your note is kept as a draft")
                }
                if model.needsPermission {
                    Button(model.detail.contains("Dictation") ? "Keyboard settings" : "Open Settings") {
                        if model.detail.contains("Dictation") { Permissions.openKeyboardSettings() } else { model.onOpenSettings() }
                    }
                }
                if model.needsAccessibility {
                    Button("Allow Accessibility") { model.onAllowAccessibility() }
                }
                if model.restoredDraft && model.phase == .typing {
                    Button("Discard draft") { model.onDiscardDraft() }
                        .help("Start this note fresh")
                }
                Button(model.phase == .listening ? "Done talking ⌘⏎" : "Save ⌘⏎") { model.onSave() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .foregroundStyle(Brand.purple)
            case .saved:
                Button("Undo") { model.onUndo() }
                if model.lastItem != nil {
                    Button("Add more") { model.onAddMore() }
                        .help("Keep going on this note")
                }
                Button("Open dashboard") { model.onOpen() }.foregroundStyle(Brand.purple)
            case .transcribing, .thinking, .saving:
                EmptyView()
            case .cancelled, .error:
                Button("Close") { model.onCancel() }
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
    }

    private var title: String {
        switch model.phase {
        case .listening: return model.session != nil ? "Go on, what do you see?" : "Go on, I'm listening"
        case .typing:
            if model.appendTarget != nil { return "Add to the note" }
            if model.proposal != nil { return "Check it, then press ⌘⏎" }
            if !model.clips.isEmpty { return model.clips.count == 1 ? "Clipped" : "\(model.clips.count) clips" }
            return model.session != nil ? "Add to the session" : "New note"
        case .transcribing: return "Writing it down…"
        case .thinking: return model.aiEnabled ? "Filing it…" : "Saving…"
        case .saving: return model.savedTitle.isEmpty ? "Working…" : model.savedTitle
        case .saved: return "Got it"
        case .cancelled: return model.detail.isEmpty ? "Dropped it" : model.detail
        case .error: return "That didn't work"
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .listening:
            return model.holding ? "Let go when you're done"
                : "Take your time · click Done talking when you're finished"
        case .typing:
            if model.restoredDraft { return "Your unsaved draft is back" }
            if !model.clips.isEmpty && model.text.isEmpty { return "Add what you think, or keep highlighting and press \(model.clipShortcut)" }
            return "Type, or hold \(model.shortcut) or click the mic to talk"
        case .transcribing: return "Local Whisper, on this Mac"
        case .thinking: return model.aiEnabled ? "Deciding where it goes" : "Using Broski's rules"
        case .saving: return model.savedDetail
        case .saved: return "Idea secured"
        case .cancelled, .error: return "Nothing saved"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .listening: return .red
        case .typing: return Brand.purple
        case .transcribing, .thinking, .saving: return .orange
        case .saved: return .green
        case .cancelled: return .secondary
        case .error: return .red
        }
    }

    private var placeholder: String {
        if model.appendTarget != nil { return "What else? It goes under the note, with the time" }
        if !model.clips.isEmpty { return "Why does this matter? (optional)" }
        if model.session != nil { return "What did you notice? Talk, type, or add a screenshot" }
        return model.phase == .listening ? "“In the strado project, add a todo: …”" : "Type a note… or say where it goes: “in the strado project, …”"
    }

    private var footerText: String {
        switch model.phase {
        case .listening, .typing:
            if !model.detail.isEmpty { return model.detail }
            return model.phase == .listening ? "⌘⏎ done · \(model.screenshotShortcut) screenshot"
                : "⌘⏎ save · esc keeps a draft · \(model.screenshotShortcut) screenshot"
        case .error: return model.detail
        default: return ""
        }
    }

    private var destinationText: String {
        if let target = model.appendTarget, model.manualDestination == nil { return "adding to note · \(target.project ?? "inbox")" }
        switch model.manualDestination {
        case nil: return model.session != nil ? "session" : "project: auto"
        case .inbox?: return "inbox"
        case .project(let p)?: return p.name
        case .newProject(let name)?: return "new · \(name)"
        }
    }

    private var destinationSymbol: String {
        switch model.manualDestination {
        case nil: return model.session != nil ? "record.circle" : "wand.and.stars"
        case .inbox?: return "tray"
        default: return "folder"
        }
    }

    private func pickDestination() {
        var items: [NSMenuItem] = [
            ActionMenuItem(model.session != nil ? "Add to the session" : "Decide from what I say", checked: model.manualDestination == nil && model.appendTarget == nil) {
                model.manualDestination = nil
                model.onPickAppendTarget(nil)
            },
            .separator(),
            ActionMenuItem("Inbox", symbol: "tray", checked: model.manualDestination == .inbox) { model.manualDestination = .inbox; model.appendTarget = nil },
        ]
        if let last = model.lastItem {
            items.insert(ActionMenuItem("Add to “\(last.title.count > 40 ? String(last.title.prefix(38)) + "…" : last.title)”", symbol: "text.append",
                                        checked: model.appendTarget?.id == last.id) { model.onPickAppendTarget(last) }, at: 1)
        }
        for project in model.projects {
            items.append(ActionMenuItem(project.name, symbol: "folder", checked: model.manualDestination == .project(project)) {
                model.manualDestination = .project(project)
                model.appendTarget = nil
            })
        }
        PopupMenu.show(items)
    }

    private func pickKind() {
        var items: [NSMenuItem] = [
            ActionMenuItem("Decide from what I say", checked: model.manualKind == nil) { model.manualKind = nil },
            .separator(),
        ]
        for kind in NoteKind.allCases {
            items.append(ActionMenuItem(kind.label, symbol: kind.symbol, checked: model.manualKind == kind) { model.manualKind = kind })
        }
        PopupMenu.show(items)
    }
}

/// A screenshot or file preview.
struct Thumbnail: View {
    let url: URL
    /// Fixed square size; nil fills whatever frame it's given.
    let size: CGFloat?

    var body: some View {
        Group {
            if let image = Self.image(url, maxPixels: (size ?? 400) * 2) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            }
        }
        .frame(width: size, height: size)
        .frame(maxWidth: size == nil ? .infinity : nil, maxHeight: size == nil ? .infinity : nil)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .help(url.lastPathComponent)
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 150 << 20
        return cache
    }()

    /// An image file scaled down to `maxPixels` on its long side, decoded once per version of the file. Views that
    /// show these re-render on every library reload, and decoding full-size Retina screenshots each time stalls the UI.
    static func image(_ url: URL, maxPixels: CGFloat) -> NSImage? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        let key = "\(url.path)|\(modified.timeIntervalSince1970)|\(Int(maxPixels))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixels),
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}

enum Brand {
    static let purple = Color(nsColor: BroskiArt.Palette.purple)
    static let yellow = Color(nsColor: BroskiArt.Palette.yellow)
}

extension NoteKind {
    var label: String {
        switch self {
        case .note: return "Note"
        case .idea: return "Idea"
        case .todo: return "Todo"
        case .bug: return "Bug"
        }
    }

    var symbol: String {
        switch self {
        case .note: return "note.text"
        case .idea: return "lightbulb"
        case .todo: return "checkmark.circle"
        case .bug: return "ladybug"
        }
    }

    var color: Color {
        switch self {
        case .note: return .secondary
        case .idea: return Color(red: 0.85, green: 0.6, blue: 0.0)
        case .todo: return Brand.purple
        case .bug: return .red
        }
    }
}

struct Chip: View {
    let symbol: String
    let text: String
    let tint: Color
    var pinned = false
    /// Shows a small chevron when the chip opens a menu.
    var menu = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
            if pinned { Image(systemName: "pin.fill").font(.system(size: 8)) }
            if menu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7) }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

struct LevelBars: View {
    let level: Float
    let color: Color
    private let weights: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.9, 0.55, 0.35]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 4 + CGFloat(level) * 18 * weights[i])
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
