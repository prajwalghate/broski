import BroskiCore
import SwiftUI
import UserNotifications

/// Ask Broski on the iPhone: type or talk a question, get an answer from your notes with its sources.
struct AskScreen: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var recorder: Recorder
    /// Opens riff mode, for a back-and-forth instead of one question.
    var onRiff: () -> Void
    @State private var question = ""
    @State private var answer: Ask.Answer?
    @State private var asking = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        // Pushed from Talk's navigation stack: a stack of its own inside it would double the bar.
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 10) {
                        TextField("What did I decide about pricing?", text: $question, axis: .vertical)
                            .lineLimit(1...4)
                            .focused($focused)
                            .submitLabel(.search)
                            .onSubmit { ask() }
                            // A question is one line: Return asks it (a multi-line field would add a line instead).
                            .onChange(of: question) { _, typed in
                                guard typed.contains("\n") else { return }
                                question = typed.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                                ask()
                            }
                        Button { toggleVoice() } label: {
                            Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(recorder.isRecording ? Color.red : Brand.purple))
                        }
                        .accessibilityLabel(recorder.isRecording ? "Done talking" : "Ask by voice")
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))

                    if recorder.isRecording {
                        Text(recorder.transcript.isEmpty ? "Listening…" : recorder.transcript)
                            .font(.callout).foregroundStyle(.secondary)
                    } else if recorder.finishing {
                        Label("Writing it out…", systemImage: "waveform").font(.callout).foregroundStyle(.secondary)
                    }
                    if asking { ProgressView("Looking through your notes…") }
                    // The mic's problems too (permission off, the mic taken away), or a tap on it would seem to do nothing.
                    if let problem = problem ?? recorder.problem { Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }

                    if let answer {
                        Text(attributed(answer))
                            .textSelection(.enabled)
                            .environment(\.openURL, OpenURLAction { url in url.scheme?.hasPrefix("http") == true ? .systemAction : .handled })
                        if !answer.sources.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("SOURCES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(Array(answer.sources.enumerated()), id: \.element.id) { i, ref in
                                    if let item = store.item(id: ref.id) {
                                        NavigationLink { ItemDetail(item: item, store: store) } label: { sourceRow(i, ref) }
                                    } else {
                                        sourceRow(i, ref)
                                    }
                                }
                            }
                        }
                        if !answer.usedAI {
                            Text(Keychain.claudeKey == nil ? "Add a Claude key in Settings for real answers. These are the notes that match." : "These are the notes that match.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if !asking {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Try").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(suggestions, id: \.self) { s in
                                Button(s) { question = s; ask() }.font(.callout)
                            }
                        }
                        Button { stopForRiff() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.bubble.right.fill").font(.title3).foregroundStyle(Brand.purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Riff about a project").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text("Think out loud. Broski pushes back, asks the next question, and wraps it up into a note.")
                                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Brand.purple.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Ask Broski")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { stopForRiff() } label: { Label("Riff", systemImage: "bubble.left.and.bubble.right") }
                }
            }
        }
        .onAppear { focused = answer == nil }
    }

    private var suggestions: [String] {
        let project = store.projects.first ?? "my project"
        return ["What's still open on \(project)?", "What bugs did I find this week?", "What ideas haven't I acted on?"]
    }

    private func sourceRow(_ i: Int, _ ref: NoteRef) -> some View {
        HStack(spacing: 8) {
            Text("\(i + 1)").font(.caption.bold()).foregroundStyle(Brand.purple).frame(width: 16)
            Image(systemName: ref.kind.symbol).foregroundStyle(ref.kind.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.title).font(.subheadline).lineLimit(2).foregroundStyle(.primary)
                Text("\(ref.project ?? "Inbox") · \(ref.date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func attributed(_ answer: Ask.Answer) -> AttributedString {
        Ask.pieces(answer.markdown, sources: answer.sources).reduce(AttributedString()) { result, piece in
            var out = result
            switch piece {
            case .text(let s):
                out += ReplyText.rendered(s, atLineStart: out.characters.isEmpty || out.characters.last == "\n")
            case .cite(_, let n):
                var c = AttributedString(" \(n) ")
                c.foregroundColor = Brand.purple
                c.font = .caption.bold()
                out += c
            }
            return out
        }
    }

    /// A question being dictated stays a question: the riff opens once its recording has ended.
    private func stopForRiff() {
        focused = false
        guard recorder.isRecording else { return onRiff() }
        guard !recorder.isStopping else { return }
        Task {
            question = TextTools.joinPhrase(question, await recorder.stop())
            onRiff()
        }
    }

    private func toggleVoice() {
        if recorder.isRecording {
            guard !recorder.isStopping else { return }
            Task {
                let heard = await recorder.stop()
                question = TextTools.joinPhrase(question, heard)
                ask()
            }
        } else {
            focused = false
            Task { await recorder.start() }
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        focused = false
        asking = true
        problem = nil
        Task {
            defer { asking = false }
            do { answer = try await store.ask(q) } catch { problem = error.localizedDescription }
        }
    }
}

/// The morning check-in on the iPhone: what's open, from the same rules as the Mac.
struct CheckInScreen: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let brief = CheckIn.build(items: store.items, options: CheckInSchedule.options)
        NavigationStack {
            List {
                Section { Text(brief.headline).font(.headline) }
                ForEach(brief.groups, id: \.project) { group in
                    Section(group.project) {
                        ForEach(Array(group.lines.enumerated()), id: \.offset) { _, line in
                            if let id = line.cites.first, let item = store.item(id: id) {
                                NavigationLink(line.text) { ItemDetail(item: item, store: store) }
                            } else {
                                Text(line.text)
                            }
                        }
                    }
                }
            }
            .navigationTitle(brief.greeting)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The daily check-in reminder, as a local notification. Off unless you turn it on.
enum CheckInSchedule {
    static let enabledKey = "BroskiCheckInEnabled"
    static let timeKey = "BroskiCheckInTime"
    static let id = "broski-checkin"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var time: DateComponents {
        let minutes = UserDefaults.standard.object(forKey: timeKey) as? Int ?? (9 * 60 + 30)
        return DateComponents(hour: minutes / 60, minute: minutes % 60)
    }
    static var options: CheckIn.Options { CheckIn.Options() }

    /// Re-schedules the next week, one notification a day. Only the next one carries the numbers, built for the day
    /// it shows: a repeating one would show the same frozen numbers until the app is opened again.
    static func refresh(items: [Item]) async {
        let center = UNUserNotificationCenter.current()
        let days = 0..<7
        center.removePendingNotificationRequests(withIdentifiers: [id] + days.map { "\(id)-\($0)" })
        guard enabled else { return }
        let calendar = Calendar.current
        // Today's, unless that time has already passed.
        guard let first = calendar.nextDate(after: Date(), matching: time, matchingPolicy: .nextTime) else { return }
        let brief = CheckIn.build(items: items, options: options, now: first)
        for day in days {
            guard let date = calendar.date(byAdding: .day, value: day, to: first) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Your Broski check-in"
            content.body = day == 0
                ? brief.headline + (brief.groups.first.map { " Top: \($0.lines.first?.text ?? "")" } ?? "")
                : "See what's open across your projects."
            content.sound = .default
            content.userInfo = ["route": "checkin"]
            let when = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "\(id)-\(day)", content: content, trigger: trigger))
        }
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Once you've said no, iOS doesn't ask again: only Settings can turn notifications back on.
    static func permissionDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }
}

/// Opens the check-in when you tap its notification.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.userInfo["route"] as? String == "checkin" {
            await MainActor.run { PhoneRouter.shared.open(.checkIn) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// A project's living page at the top of its notes.
struct PageSection: View {
    let page: ProjectPage
    @ObservedObject var store: PhoneStore
    @State private var expanded = false

    var body: some View {
        Section {
            if !page.summary.isEmpty { Text(page.summary).font(.callout) }
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(page.sections.filter { !$0.lines.isEmpty }, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            if let id = line.cites.first, let item = store.item(id: id) {
                                NavigationLink { ItemDetail(item: item, store: store) } label: { Text("• " + line.text).font(.subheadline) }
                            } else {
                                Text("• " + line.text).font(.subheadline)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } label: {
                Label(page.source == .claude ? "Living page, written by Claude" : "Living page", systemImage: page.source == .claude ? "sparkles" : "list.bullet.rectangle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Brand.purple)
            }
        }
    }
}
