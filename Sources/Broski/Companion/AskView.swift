import AppKit
import BroskiCore
import SwiftUI

@MainActor
final class AskModel: ObservableObject {
    @Published var question = ""
    @Published var answer: Ask.Answer?
    @Published private(set) var asking = false
    @Published var problem: String?
    @Published var focusTick = 0
    @Published var saved: String?
    let library: Library
    let voice: VoiceInput
    var onOpenNote: (String) -> Void = { _ in }
    var onRiff: (String?, String) -> Void = { _, _ in }
    var onClose: () -> Void = {}
    private var task: Task<Void, Never>?

    init(library: Library, voice: VoiceInput) {
        self.library = library
        self.voice = voice
    }

    func reset(project: String?) {
        task?.cancel()
        voice.problem = nil
        question = project.map { "In \($0), " } ?? ""
        answer = nil
        problem = nil
        saved = nil
        asking = false
        focusTick += 1
    }

    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        asking = true
        problem = nil
        saved = nil
        task?.cancel()
        task = Task {
            defer { if !Task.isCancelled { asking = false } }
            do {
                answer = try await library.ask(q)
                Log.info("Asked Broski (\(answer?.sources.count ?? 0) sources)")
            } catch where Brain.isCancellation(error) {
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func toggleVoice() {
        if voice.listening {
            Task {
                let text = await voice.stop(vocabulary: library.projectNames)
                if !text.isEmpty {
                    question = TextTools.joinPhrase(question, text)
                    ask()
                }
            }
        } else {
            voice.start()
        }
    }

    /// Keeps the answer (with its sources) as a note in the project it's about.
    func saveAsNote() {
        guard let answer else { return }
        let project = library.catalog.mentioned(in: question)?.name ?? answer.sources.first?.project
        do {
            let item = try library.store.create(ItemDraft(project: project, kind: .note, title: "Q: " + String(question.prefix(80)),
                                                          body: answer.markdown, context: ItemContext(app: "Ask Broski")))
            library.reload()
            saved = "Saved to \(item.project ?? "Inbox")"
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

struct AskView: View {
    @ObservedObject var model: AskModel
    @ObservedObject var voice: VoiceInput

    var body: some View {
        CompanionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Brand.purple)
                    ComposerField(text: $model.question, placeholder: "Ask about your notes… “what did I decide about pricing?”",
                                  fontSize: 17, maxLines: 3, onSend: { model.ask() }, onEscape: { model.onClose() })
                    if model.asking || voice.transcribing { ProgressView().controlSize(.small) }
                    Button { model.toggleVoice() } label: {
                        Image(systemName: voice.listening ? "stop.fill" : "mic")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(voice.listening ? .white : .primary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(voice.listening ? Color.red : Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help(voice.listening ? "Done, ask it" : "Ask by voice")
                    Button { model.onClose() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Close (esc)")
                }
                if let problem = model.problem ?? voice.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(.orange)
                }
                if let answer = model.answer {
                    Divider()
                    let reply = VStack(alignment: .leading, spacing: 12) {
                        AnswerText(answer: answer) { model.onOpenNote($0) }
                        if !answer.sources.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("SOURCES").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                ForEach(Array(answer.sources.enumerated()), id: \.element.id) { i, ref in
                                    Button { model.onOpenNote(ref.id) } label: {
                                        HStack(spacing: 6) {
                                            Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.purple).frame(width: 14)
                                            Image(systemName: ref.isSessionEntry ? "record.circle" : ref.kind.symbol).foregroundStyle(ref.kind.color)
                                            Text(ref.title).lineLimit(1)
                                            Spacer()
                                            Text("\(ref.project ?? "Inbox") · \(ref.date.formatted(.relative(presentation: .named)))")
                                                .foregroundStyle(.secondary)
                                        }
                                        .font(.system(size: 12))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The panel grows with its content and isn't kept on screen: a long answer scrolls inside it,
                    // so the sources and buttons stay reachable. Short ones take only their own height.
                    ViewThatFits(in: .vertical) {
                        reply
                        ScrollView { reply }
                    }
                    .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 800) * 0.55)
                    HStack(spacing: 14) {
                        if !answer.usedAI {
                            Text(model.library.brain.hasModel ? "Showing matching notes." : "Choose a model in Settings › Models for real answers.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let saved = model.saved { Text(saved).font(.system(size: 11)).foregroundStyle(.green) }
                        Button("Save as note") { model.saveAsNote() }
                        Button("Riff on this") {
                            model.onRiff(model.answer?.sources.first?.project, "Q: \(model.question)\n\nBroski: \(answer.markdown)")
                        }
                        // An answer without AI is a listing, kept on the Mac (a local-only project, no key).
                        .disabled(!model.library.brain.hasModel || !answer.usedAI)
                        .help(model.library.brain.hasModel ? (answer.usedAI ? "Keep thinking about this in a riff" : "This answer stayed on this Mac, so it can't go to a riff")
                              : "Choose a model in Settings › Models to riff")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                } else if !model.asking {
                    Text("Answers come from your notes and project pages, with sources. ⏎ to ask · esc to close")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .onExitCommand { model.onClose() }
    }
}

/// An answer with its [[citations]] shown as small numbers that open the note.
struct AnswerText: View {
    let answer: Ask.Answer
    var open: (String) -> Void

    var body: some View {
        let pieces = Ask.pieces(answer.markdown, sources: answer.sources)
        let text = pieces.reduce(AttributedString()) { result, piece in
            var out = result
            switch piece {
            case .text(let string):
                // After a citation the text continues its line: "- " there isn't a list.
                let lineStart = out.characters.isEmpty || out.characters.last == "\n"
                out += ReplyText.rendered(string, atLineStart: lineStart)
            case .cite(let id, let number):
                var cite = AttributedString(" \(number) ")
                cite.foregroundColor = Brand.purple
                cite.font = .system(size: 10, weight: .bold)
                cite.link = URL(string: "broski-note:\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")
                out += cite
            }
            return out
        }
        Text(text)
            .font(.system(size: 14))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "broski-note" else { return .systemAction }
                open(url.absoluteString.dropFirst("broski-note:".count).removingPercentEncoding ?? "")
                return .handled
            })
    }
}
