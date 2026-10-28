import BroskiCore
import Foundation

// Run with: swift run BroskiSelfTest

var failures = 0

func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label) \(detail())")
    }
}

print("Wake word")
let wake = WakeWordMatcher(wakeWords: ["broski"])
for heard in ["Broski, in the strado project", "bro ski add a note", "Brosky add an idea", "okay broskie note this",
              "Bruski todo", "Broski's idea", "hey Broskee"] {
    check(wake.firstMatch(in: heard) != nil, "hears \"\(heard)\"")
}
for other in ["we went for a brisk walk", "the brochure is ready", "Bristol is nice", "ask Rosie about it", "browser tabs",
              "ask Brooks about the contract"] {
    check(wake.firstMatch(in: other) == nil, "ignores \"\(other)\"")
}
if let m = wake.firstMatch(in: "Okay so Broski, in the trading bot project") {
    check(m.heard == "Broski", "match range covers only the wake word", "got \(m.heard)")
}

print("Routing")
let catalog = ProjectCatalog(projects: [
    "trading-bot", "hip3-observatory", "strado", "bugbyte-aso", "SAI", "Tamer", "marketroom", "broski",
].map { Project(name: $0) })
let parser = NoteParser(catalog: catalog)

func expect(_ said: String, _ destination: String, _ kind: NoteKind, _ body: String, file: String = #file, line: Int = #line) {
    let n = parser.parse(said)
    let ok = n.destination.displayName == destination && n.kind == kind && n.body == body && !n.cancelled
    check(ok, "\"\(said)\"", "\n        got → \(n.destination.displayName) | \(n.kind) | \"\(n.body)\"")
}

expect("In the trading bot project, add a note: retry failed orders with exponential backoff.",
       "trading-bot", .note, "Retry failed orders with exponential backoff.")
expect("in project trading bot add a todo fix the order router", "trading-bot", .todo, "Fix the order router")
expect("In the strado project add a todo to fix the login bug", "strado", .todo, "Fix the login bug")
expect("Add a note to marketroom: the landing page needs social proof.", "marketroom", .note, "The landing page needs social proof.")
expect("Add an idea to the hip three observatory project that we should plot funding rates.",
       "hip3-observatory", .idea, "We should plot funding rates.")
expect("Idea for Tamer: let people schedule sessions by voice.", "Tamer", .idea, "Let people schedule sessions by voice.")
expect("Note for broski project: support multiple wake words.", "broski", .note, "Support multiple wake words.")
expect("Bug in bug byte ASO, keyword ranks don't refresh.", "bugbyte-aso", .bug, "Keyword ranks don't refresh.")
expect("For strado, remind me to rotate the API keys.", "strado", .todo, "Rotate the API keys.")
expect("In trading bot we should add a kill switch", "trading-bot", .note, "We should add a kill switch")
expect("Strado: add a feature idea, dark mode for the dashboard", "strado", .idea, "Dark mode for the dashboard")
expect("In the trading bought project, log a bug: fills are double counted.", "trading-bot", .bug, "Fills are double counted.")
expect("In the moonshot project, add an idea: AI that reads my standups.", "moonshot", .idea, "AI that reads my standups.")
expect("Project side quest, add a note: try the new SwiftUI charts.", "side-quest", .note, "Try the new SwiftUI charts.")
expect("Note to self: buy a better microphone.", "inbox", .note, "Buy a better microphone.")
expect("Remind me to call the accountant on Friday.", "inbox", .todo, "Call the accountant on Friday.")
expect("Um, so an app that turns voice memos into Jira tickets.", "inbox", .note, "An app that turns voice memos into Jira tickets.")
expect("Todo: renew the domain.", "inbox", .todo, "Renew the domain.")
expect("Add a todo for tomorrow: call the bank.", "inbox", .todo, "For tomorrow: call the bank.")
expect("in the Broski project at a Todo, write the read me file", "broski", .todo, "Write the read me file")
expect("For strado and a note: the cache is stale", "strado", .note, "The cache is stale")
expect("In order to make this project work we need funding.", "inbox", .note, "In order to make this project work we need funding.")
expect("On second thought, pricing should be usage based.", "inbox", .note, "On second thought, pricing should be usage based.")
expect("We went for a brisk walk and I thought of a name: Strider.", "inbox", .note, "We went for a brisk walk and I thought of a name: Strider.")

for said in ["Never mind.", "In the strado project add a note, actually cancel that", "Scratch that"] {
    check(parser.parse(said).cancelled, "cancels \"\(said)\"")
}
check(!parser.parse("Remind me to cancel the gym membership").cancelled, "\"remind me to cancel …\" is a note, not a cancel")

print("Voice commands")
for said in ["Open the app", "open the dashboard.", "Show my notes", "Broski open dashboard please"] {
    let cleaned = said.hasPrefix("Broski ") ? String(said.dropFirst(7)) : said
    check(parser.command(in: cleaned) == .openDashboard(project: nil), "command: \"\(said)\"")
}
check(parser.command(in: "Show the strado notes") == .openDashboard(project: Project(name: "strado")), "command: show a project's notes")
check(parser.command(in: "open the trading bot project") == .openDashboard(project: Project(name: "trading-bot")), "command: open a project")
for note in ["Show the pricing page to Sam", "Open the strado project in Xcode and fix the build", "In the strado project, add a todo: open the app store page"] {
    check(parser.command(in: note) == nil, "not a command: \"\(note)\"")
}

print("Transcript restarts")
var acc = TranscriptAccumulator()
for partial in ["in the", "in the strado project", "in the strado project add a note", "the login", "the login is slow"] {
    acc.feed(partial)
}
check(acc.text == "in the strado project add a note the login is slow", "keeps text across a recognizer restart", "got \(acc.text)")
var revised = TranscriptAccumulator()
for partial in ["bro ski in the", "Broski in the trading", "Broski, in the trading bot project."] {
    revised.feed(partial)
}
check(revised.text == "Broski, in the trading bot project.", "revisions replace, not append", "got \(revised.text)")

print("Storage")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("broski-selftest-\(UUID().uuidString)")
let store = NoteStore(root: tmp)
let date = ISO8601DateFormatter().date(from: "2026-10-14T10:02:00Z")!
do {
    let first = try store.save(parser.parse("In the strado project, add a todo: fix login"), raw: "raw", date: date)
    let second = try store.save(parser.parse("In the strado project, idea: dark mode"), raw: "raw", date: date)
    let text = try String(contentsOf: first.file, encoding: .utf8)
    check(first.file.lastPathComponent == "strado.md", "writes projects/strado.md")
    check(text.hasPrefix("# strado\n"), "new file gets a heading")
    check(text.contains("- [ ] ") && text.contains("· Fix login\n"), "todo becomes a checkbox", text)
    check(text.hasSuffix("· Dark mode #idea\n"), "idea is tagged", text)
    check(try store.undo(second), "undo removes the last note")
    let after = try String(contentsOf: first.file, encoding: .utf8)
    check(!after.contains("Dark mode") && after.contains("Fix login"), "undo leaves earlier notes alone", after)
    check(try store.undo(second) == false, "undo twice is a no-op")
    let inbox = try store.save(parser.parse("Todo: renew the domain"), raw: "raw", date: date)
    check(inbox.file.lastPathComponent == "inbox.md", "unrouted notes go to inbox.md")
    let discovered = ProjectCatalog.discover(roots: [], notesDir: store.projectsDir)
    check(discovered.projects.map(\.name) == ["strado"], "notes files become known projects", "\(discovered.projects.map(\.name))")
} catch {
    check(false, "storage threw \(error)")
}
try? FileManager.default.removeItem(at: tmp)

print("Notes files (dashboard)")
let file = URL(fileURLWithPath: "/tmp/x.md")
let sample = """
# strado

Captured with Broski. Newest at the bottom.

- [ ] 2026-10-14 15:32 · Rotate the API keys.
- [x] 2026-10-14 15:40 · Login fails on Safari #bug
- 2026-10-14 16:05 · Dark mode for the dashboard #idea
- 2026-10-14 16:10 · Pricing should be usage based
- buy a better mic
* [X] hand-written done item

"""
let parsed = NotesFormat.parse(sample, file: file)
check(parsed.count == 6, "reads every bullet, skips headings and prose", "got \(parsed.count)")
if parsed.count == 6 {
    check(parsed[0].kind == .todo && !parsed[0].done && parsed[0].body == "Rotate the API keys.", "open todo")
    check(parsed[1].kind == .bug && parsed[1].done && parsed[1].body == "Login fails on Safari", "done bug, tag removed")
    check(parsed[2].kind == .idea && !parsed[2].hasCheckbox, "idea")
    check(parsed[3].kind == .note && parsed[3].date != nil, "note with date")
    check(parsed[4].kind == .note && parsed[4].date == nil && parsed[4].body == "buy a better mic", "hand-written bullet")
    check(parsed[5].kind == .todo && parsed[5].done, "hand-written checkbox")
    check(parsed.prefix(4).allSatisfy { NotesFormat.line(for: $0) == $0.raw }, "Broski's own lines survive a parse and re-render unchanged")
}

let editRoot = FileManager.default.temporaryDirectory.appendingPathComponent("broski-edit-\(UUID().uuidString)")
let editStore = NoteStore(root: editRoot)
do {
    try editStore.add(body: "Rotate the API keys", kind: .todo, to: .newProject("strado"), date: date)
    try editStore.add(body: "Dark mode", kind: .idea, to: .newProject("strado"), date: date)
    try editStore.add(body: "Buy a mic", kind: .note, to: .inbox, date: date)
    let strado = editStore.file(for: .newProject("strado"))
    var notes = editStore.entries(in: strado)
    check(notes.count == 2, "add writes to the project file")
    let ticked = try editStore.update(notes[0], done: true)
    let tickedText = try String(contentsOf: strado, encoding: .utf8)
    check(ticked.done && tickedText.contains("- [x] "), "ticking a todo writes [x]")
    notes = editStore.entries(in: strado)
    _ = try editStore.update(notes[1], body: "Dark mode everywhere", kind: .bug)
    notes = editStore.entries(in: strado)
    check(notes[1].kind == .bug && notes[1].body == "Dark mode everywhere" && notes[1].hasCheckbox, "edit text and type")
    let removed = try editStore.delete(notes[0])
    check(editStore.entries(in: strado).count == 1, "delete removes the line")
    try editStore.restore(removed)
    let restored = editStore.entries(in: strado)
    check(restored.count == 2 && restored[0].raw == removed.raw, "undo delete puts it back in place")
    try editStore.move(restored[1], to: .inbox)
    check(editStore.entries(in: strado).count == 1 && editStore.entries(in: editStore.inboxFile).count == 2, "move to another file")
    check(editStore.entries(in: editStore.inboxFile).last?.kind == .bug, "move keeps the type")
    check(editStore.noteFiles().map(\.lastPathComponent) == ["inbox.md", "strado.md"], "lists inbox then projects")
    let stale = restored[0]
    try "# changed\n".write(to: strado, atomically: true, encoding: .utf8)
    var threw = false
    do { _ = try editStore.update(stale, done: false) } catch { threw = true }
    check(threw, "edits to a note changed elsewhere fail instead of clobbering")
} catch {
    check(false, "editing threw \(error)")
}
try? FileManager.default.removeItem(at: editRoot)

print("Items, sessions, migration (0.3)")
let v3 = FileManager.default.temporaryDirectory.appendingPathComponent("broski-v3-\(UUID().uuidString)")
let items = ItemStore(root: v3)
do {
    let shot = v3.appendingPathComponent("shot.png")
    try FileManager.default.createDirectory(at: v3, withIntermediateDirectories: true)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: shot)
    let context = ItemContext(app: "Safari", window: "Stripe", url: "https://dashboard.stripe.com", selection: "line one\nline two")
    var made = try items.create(ItemDraft(project: "strado", kind: .bug, priority: .high, tags: ["login", "safari"],
                                          title: "Login fails on Safari", body: "Steps:\n1. Open\n2. Click", context: context,
                                          attachments: [shot]), date: date)
    let read = ItemStore.read(made.file, project: "strado")
    check(read == made, "item survives a write and read", "\n        \(String(describing: read))\n        \(made)")
    check(made.status == .todo && made.attachments.count == 1, "bugs start in To do, attachment copied")
    check(FileManager.default.fileExists(atPath: made.attachmentURLs[0].path), "attachment file exists next to the note")
    made.status = .doing
    made = try items.save(made, date: date)
    check(items.items(in: "strado").first?.status == .doing, "status change persists")
    let moved = try items.move(made, to: "marketroom")
    check(items.items(in: "strado").isEmpty && items.items(in: "marketroom").count == 1, "move to another project")
    check(FileManager.default.fileExists(atPath: moved.attachmentURLs[0].path), "attachments move with the note")
    let trashed = try items.delete(moved)
    check(items.items(in: "marketroom").isEmpty, "delete moves it out")
    try items.restore(trashed)
    let back = items.items(in: "marketroom")
    check(back.count == 1 && FileManager.default.fileExists(atPath: back[0].attachmentURLs[0].path), "restore brings note and screenshot back")
    try items.create(ItemDraft(title: "Buy a mic"), date: date)
    check(items.items(in: nil).first?.status == .inbox, "notes start in the inbox column")

    var session = try items.startSession(kind: .qa, project: "strado", title: "Login flow", date: date)
    session = try items.append(text: "Button is misaligned\non narrow windows", files: [shot], context: context, to: session, date: date)
    session = try items.append(text: "Error toast never disappears", files: [], context: ItemContext(), to: session, date: date.addingTimeInterval(65))
    check(items.activeSession()?.id == session.id, "active session found")
    let parsedSession = items.sessions(in: "strado").first
    check(parsedSession?.entries.count == 2 && parsedSession?.entries[0].attachments.count == 1, "session entries round-trip")
    check(parsedSession?.entries[0].text == "Button is misaligned\non narrow windows" && parsedSession?.entries[0].context.app == "Safari", "entry text and context round-trip")
    session = try items.endSession(session, date: date.addingTimeInterval(120))
    check(items.activeSession() == nil, "ended sessions aren't active")
    check(ReportWriter.basic(session).contains("![](shots/"), "basic report embeds screenshots")

    // Carrying on a note later.
    let base = try items.create(ItemDraft(project: "strado", kind: .idea, title: "Offline mode", body: "Cache the last sync"), date: date)
    let more = try items.addMore(to: base, text: "Also queue writes", files: [shot], date: date.addingTimeInterval(600))
    let reread = items.items(in: "strado").first { $0.id == base.id }
    check(reread?.body.hasPrefix("Cache the last sync\n\n_Added ") == true && reread?.body.hasSuffix("Also queue writes") == true, "add more appends under a time", reread?.body ?? "nil")
    check(more.attachments.count == 1 && reread?.attachments.count == 1, "add more keeps new screenshots")

    // Upgrade from 0.2's one-line files.
    let legacy = FileManager.default.temporaryDirectory.appendingPathComponent("broski-legacy-\(UUID().uuidString)")
    let old = NoteStore(root: legacy)
    try old.add(body: "Rotate the API keys", kind: .todo, to: .newProject("strado"), date: date)
    try old.add(body: "Buy a mic", kind: .note, to: .inbox, date: date)
    let upgraded = ItemStore(root: legacy)
    check(try upgraded.migrateLegacyNotes() == 2, "migrates old notes")
    check(upgraded.items(in: "strado").first?.title == "Rotate the API keys" && upgraded.items(in: nil).count == 1, "migrated into the new layout")
    check(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("inbox.md").path), "old files moved aside")
    check(try upgraded.migrateLegacyNotes() == 0, "migration runs once")
    try? FileManager.default.removeItem(at: legacy)
} catch {
    check(false, "items threw \(error)")
}
try? FileManager.default.removeItem(at: v3)

// Clips and phrase joining.
let clip = Clip(text: "  Keys rotate every 90 days.\nOld keys stop at once. ", source: ItemContext(app: "Safari", window: "API keys – Stripe Docs", url: "https://docs.stripe.com/keys", selection: "x"))
check(clip.markdown == "> Keys rotate every 90 days.\n> Old keys stop at once.\n>\n> — [API keys – Stripe Docs](https://docs.stripe.com/keys) · Safari", "clip renders as a sourced quote", clip.markdown)
check(clip.source.selection == nil, "clip doesn't duplicate the selection")
check(Clip(text: "hi", source: ItemContext(app: "Notes")).sourceLine == "Notes", "clip source without a window")
check(Clip.title(for: [clip]) == "Keys rotate every 90 days.", "clip title is its first line")
check(TextTools.joinPhrase("after you paste the password,", "Also check signup.") == "after you paste the password, also check signup.", "join lowercases a continued sentence")
check(TextTools.joinPhrase("It crashed.", "Then it froze.") == "It crashed. Then it froze.", "join keeps a new sentence")
check(TextTools.joinPhrase("and then", "I tried the API") == "and then I tried the API", "join keeps I")
check(TextTools.joinPhrase("open", "GitHub issues") == "open GitHub issues", "join keeps names")
check(TextTools.joinPhrase("", "Hello") == "Hello", "join into nothing")

// The brain: search, related notes, duplicates, project pages, citations, companion rules.
do {
    let brainRoot = FileManager.default.temporaryDirectory.appendingPathComponent("broski-brain-\(UUID().uuidString)")
    let store = ItemStore(root: brainRoot)
    let now = Date()
    let login = try store.create(ItemDraft(project: "strado", kind: .bug, priority: .high, title: "Login button stays disabled after pasting the password", body: "Only on Safari. Typing works."), date: now.addingTimeInterval(-3600))
    let rotate = try store.create(ItemDraft(project: "strado", kind: .todo, title: "Rotate the Stripe API keys before launch"), date: now.addingTimeInterval(-7200))
    let oldIdea = try store.create(ItemDraft(project: "marketroom", kind: .idea, title: "Social proof strip on the landing page"), date: now.addingTimeInterval(-30 * 86_400))
    _ = try store.create(ItemDraft(project: "strado", kind: .note, title: "Decided to keep the free tier at 3 bots"), date: now.addingTimeInterval(-86_400))
    let items = store.allItems()
    let index = NotesIndex(items: items)

    check(index.search("password login safari").first?.ref.id == login.id, "search finds the login bug")
    check(index.search("stripe keys").first?.ref.id == rotate.id, "search finds the key rotation todo")
    check(index.search("zebra unicorn").isEmpty, "search: no match, no results")
    check(index.search("keys", project: "marketroom").isEmpty, "search respects the project filter")
    check(index.related(to: "the login button is disabled when I paste a password").first?.ref.id == login.id, "related: same bug in other words")
    check(index.duplicate(of: "Login button stays disabled after pasting the password on Safari")?.ref.id == login.id, "duplicate: near-identical note")
    check(index.duplicate(of: "Add dark mode to the settings page") == nil, "duplicate: unrelated note isn't one")
    check(NotesIndex.tokens("Crashing bugs crashed") == ["crash", "bug", "crash"], "tokens are stemmed", "\(NotesIndex.tokens("Crashing bugs crashed"))")

    // Living project page
    let stradoRefs = index.refs.filter { $0.project == "strado" }
    let page = ProjectPageBuilder.rules(project: "strado", refs: stradoRefs, items: items.filter { $0.project == "strado" }, sessions: [])
    check(page.summary == "1 open bug, 1 todo.", "rules page summary", page.summary)
    check(page.sections.first { $0.title == "Open bugs" }?.lines.first?.cites == [login.id], "rules page cites the bug")
    var withActions = page
    withActions.actions = [ProposedAction(kind: .issue, title: "File the Safari login bug", detail: "repro: paste", cites: [login.id])]
    try withActions.save(to: store)
    let loaded = ProjectPage.load("strado", from: store)
    check(loaded?.sections == withActions.sections.filter { !$0.lines.isEmpty } && loaded?.summary == withActions.summary, "page round-trips through PROJECT.md", loaded.map { $0.render() } ?? "nil")
    check(loaded?.actions.first?.title == "File the Safari login bug" && loaded?.actions.first?.kind == .issue, "page keeps proposed actions")
    check(store.items(in: "strado").count == 3, "PROJECT.md isn't listed as a note", "\(store.items(in: "strado").count)")
    check(ProjectPage.parseLine("Fix it [[a-1]] [[s#2]]") == ProjectPage.Line(text: "Fix it", cites: ["a-1", "s#2"]), "page line citations parse")
    check(ProjectPage.fingerprint(stradoRefs) == ProjectPage.fingerprint(stradoRefs.reversed()), "fingerprint ignores order")

    // Ask: citations must point at real notes
    let known = Dictionary(index.refs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let (answer, sources) = Ask.resolve("It's the paste bug [[\(login.id)]] and keys [[made-up-id]] [[\(rotate.id)]].", known: known)
    check(sources.map(\.id) == [login.id, rotate.id], "ask keeps real citations in order")
    check(!answer.contains("made-up-id"), "ask drops invented citations", answer)
    check(Ask.pieces("A [[x]] b", sources: [NoteRef(login)].map { var r = $0; r.id = "x"; return r }) == [.text("A "), .cite(id: "x", number: 1), .text(" b")], "answer splits into text and citation chips")
    let catalog = ProjectCatalog(projects: ["strado", "marketroom", "trading-bot"].map { Project(name: $0) })
    check(catalog.mentioned(in: "what's left on strado this week?")?.name == "strado", "question names a project")
    check(catalog.mentioned(in: "any bugs in the trading bot")?.name == "trading-bot", "multi-word project in a question")
    check(Ask.context(for: "login password", index: index, catalog: catalog).hits.first?.ref.id == login.id, "ask context finds the right note")

    // Companion: budgets, cooldowns, "never" (at noon, so "ten minutes later" is still today)
    let midday = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
    var ledger = CompanionLedger()
    let back = CompanionPlanner.backToProject("strado", items: items)!
    check(back.title == "Back on strado: 1 open bug and 1 todo" && back.body.contains("Login button"), "back-to-project nudge", back.title)
    check(!ledger.allows(back, mode: .quiet), "quiet mode never nudges")
    check(ledger.allows(back, mode: .daily), "daily mode allows a nudge")
    ledger.shown(back, now: midday)
    check(!ledger.allows(back, mode: .daily, now: midday.addingTimeInterval(600)), "same nudge waits out its cooldown")
    let other = Nudge(kind: .staleIdea, key: "idea:x", project: nil, title: "t", body: "b")
    ledger.shown(other, now: midday)
    check(!ledger.allows(Nudge(kind: .staleIdea, key: "idea:y", project: nil, title: "t", body: "b"), mode: .daily, now: midday), "daily budget runs out at 2")
    check(ledger.allows(Nudge(kind: .staleIdea, key: "idea:y", project: nil, title: "t", body: "b"), mode: .daily, now: midday.addingTimeInterval(86_400 * 1.2)), "budget resets the next day")
    ledger.record(.never, for: back)
    check(!ledger.allows(back, mode: .active, now: midday.addingTimeInterval(86_400 * 3)), "never means never")
    check(CompanionPlanner.staleIdea(items: items, now: now)?.cites == [oldIdea.id], "stale idea found")
    check(CompanionPlanner.project(for: ItemContext(app: "Brave Browser", window: "Strado — Dashboard"), catalog: catalog, items: items) == "strado", "context: project in the window title")
    check(CompanionPlanner.project(for: ItemContext(app: "Xcode", window: "main.swift"), catalog: catalog, items: items) == nil, "context: no project, no guess")

    // Morning check-in
    let brief = CheckIn.build(items: items, options: CheckIn.Options(), now: now)
    // Only strado has anything open; marketroom's old idea doesn't count as a project.
    check(brief.headline == "1 open bug and 1 todo across 1 project.", "check-in headline", brief.headline)
    check(brief.groups.first?.project == "strado", "check-in leads with the busiest project")
    let scoped = CheckIn.build(items: items, options: CheckIn.Options(projects: ["marketroom"]), now: now)
    check(scoped.groups.map(\.project) == ["marketroom"], "check-in respects chosen projects")
    let cal = Calendar.current
    let ten = cal.date(bySettingHour: 10, minute: 0, second: 0, of: now)!
    check(CheckIn.isDue(at: "09:30", lastShown: nil, now: ten), "check-in due after its time")
    check(!CheckIn.isDue(at: "09:30", lastShown: ten.addingTimeInterval(-60), now: ten), "check-in shows once a day")
    check(!CheckIn.isDue(at: "11:00", lastShown: nil, now: ten), "check-in not before its time")
    check(!CheckIn.isDue(at: "09:30", lastShown: nil, now: cal.date(bySettingHour: 22, minute: 0, second: 0, of: now)!), "missed check-in doesn't greet you at night")

    // Config keeps companion settings and fills defaults for old files
    let oldConfig = try JSONDecoder().decode(BroskiConfig.self, from: Data(#"{"hotkey":"option+shift+b"}"#.utf8))
    check(oldConfig.companionMode == .quiet && !oldConfig.checkInEnabled && !oldConfig.showPill && !oldConfig.showFloatingButton, "defaults: quiet, check-in off, no pill, no floating head (Broski lives in the menu bar)")
    try? FileManager.default.removeItem(at: brainRoot)
} catch {
    check(false, "brain threw \(error)")
}


print("Review fixes")
do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("broski-fixes-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let store = ItemStore(root: root)

    // Another editor's front matter survives Broski's saves, byte for byte; tags in any list form are read.
    let folder = root.appendingPathComponent("projects/strado", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("hand-made.md")
    let extra = ["due: 2026-11-01", "aliases:", "  - Login fix", "  - SSO", "# a comment", "cssclass: wide"]
    try ("---\nkind: bug\nstatus: todo\ntags:\n  - api\n  - \"safari\"\n" + extra.joined(separator: "\n") + "\n---\n# Login breaks\n\nSteps.\n")
        .write(to: file, atomically: true, encoding: .utf8)
    guard var note = ItemStore.read(file, project: "strado") else { throw CocoaError(.fileReadCorruptFile) }
    check(note.tags == ["api", "safari"], "block-list tags are read", "\(note.tags)")
    check(note.extraFrontMatter == extra, "unknown keys and comments are kept", "\(note.extraFrontMatter)")
    note.status = .doing
    note = try store.save(note)
    let reread = ItemStore.read(file, project: "strado")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    check(reread?.extraFrontMatter == extra && reread?.status == .doing && reread?.tags == ["api", "safari"], "front matter round-trips through a save", text)
    try "---\nkind: todo\ntags: [ops, \"q4\"]\n---\n# Inline tags\n".write(to: folder.appendingPathComponent("inline.md"), atomically: true, encoding: .utf8)
    check(ItemStore.read(folder.appendingPathComponent("inline.md"), project: "strado")?.tags == ["ops", "q4"], "inline [a, b] tags are read")

    // A stale copy can't bring back a deleted note; a missing screenshot can't cost the note.
    let gone = try store.create(ItemDraft(project: "strado", kind: .todo, title: "Will be deleted"))
    try store.delete(gone)
    var threw = false
    do { _ = try store.save(gone) } catch { threw = true }
    check(threw && !fm.fileExists(atPath: gone.file.path), "saving a deleted note throws and doesn't recreate it")
    threw = false
    do { _ = try store.addMore(to: gone, text: "more", files: []) } catch { threw = true }
    check(threw && !fm.fileExists(atPath: gone.file.path), "adding to a deleted note throws and doesn't recreate it")
    let kept = try store.create(ItemDraft(project: "strado", title: "Has a lost screenshot", attachments: [root.appendingPathComponent("nope.png")]))
    check(fm.fileExists(atPath: kept.file.path) && kept.attachments.isEmpty, "a missing attachment is skipped, the note is written")

    // Page counts are the real totals; past 12 lines a section says how many more.
    let many = (1...15).map { i in try? store.create(ItemDraft(project: "busy", kind: .bug, title: "Bug number \(i)")) }.compactMap { $0 }
    let busyItems = store.items(in: "busy")
    let busy = ProjectPageBuilder.rules(project: "busy", refs: busyItems.map(NoteRef.init), items: busyItems, sessions: [])
    let bugLines = busy.sections.first { $0.title == "Open bugs" }?.lines ?? []
    check(many.count == 15 && busy.summary == "15 open bugs.", "rules summary counts every open bug", busy.summary)
    check(bugLines.count == 13 && bugLines.last?.text == "+3 more", "a long section says how many more", "\(bugLines.count) \(bugLines.last?.text ?? "")")

    // Ids with brackets or "#" cite like any other; only real session entries count as entries.
    check(ProjectPage.parseLine("See it [[Meeting [draft]]]") == ProjectPage.Line(text: "See it", cites: ["Meeting [draft]"]), "a page cite with brackets in the id")
    let meeting = NoteRef(id: "Meeting [draft]", project: nil, kind: .note, title: "Meeting", body: "", date: Date(), open: true, file: root)
    let issue = NoteRef(id: "Issue #42", project: nil, kind: .bug, title: "Issue", body: "", date: Date(), open: true, file: root)
    let (cited, citedSources) = Ask.resolve("Notes in [[Meeting [draft]]] and [[Issue #42]].", known: [meeting.id: meeting, issue.id: issue])
    check(cited == "Notes in [[Meeting [draft]]] and [[Issue #42]]." && citedSources.map(\.id) == ["Meeting [draft]", "Issue #42"], "ask keeps cites with brackets and #", cited)
    check(!issue.isSessionEntry, "a note named with # isn't a session entry")
    let (kept2, _) = Ask.resolve("Run `[[ -f x ]]`, then:\n    indented  code\n- a\n  - sub [[made-up]].", known: [:])
    check(kept2 == "Run `[[ -f x ]]`, then:\n    indented  code\n- a\n  - sub.", "ask keeps code and indentation, drops only the invented cite", kept2)

    // Local-only: any local-only project the capture touches keeps it away from Claude.
    let cat = ProjectCatalog(projects: ["strado", "secret", "marketroom"].map { Project(name: $0) })
    check(LocalOnly.touches("marketroom launch, and the secret export", projects: ["marketroom"], localOnly: ["secret"], catalog: cat), "local only: named second in the text")
    check(LocalOnly.touches("just a thought", projects: ["", nil, "secret"], localOnly: ["secret"], catalog: cat), "local only: the session's project")
    check(!LocalOnly.touches("strado login bug", projects: ["strado", nil], localOnly: ["secret"], catalog: cat), "local only: other projects go through")
    check(!LocalOnly.touches("secret", projects: [], localOnly: [], catalog: cat), "local only: nothing marked, nothing blocked")

    // Config: one bad value doesn't drop the local-only list; a malformed list fails closed.
    let lenient = try JSONDecoder().decode(BroskiConfig.self, from: Data(#"{"companionMode":"Daily","checkInTime":930,"localOnlyProjects":["secret"]}"#.utf8))
    check(lenient.localOnlyProjects == ["secret"], "a bad companion value keeps localOnlyProjects")
    check((try? JSONDecoder().decode(BroskiConfig.self, from: Data(#"{"localOnlyProjects":{"secret":true}}"#.utf8))) == nil, "a malformed localOnlyProjects throws (readers fail closed)")
    let options = try JSONDecoder().decode(CheckIn.Options.self, from: Data(#"{"projects":["strado"],"bugs":"yes"}"#.utf8))
    check(options.projects == ["strado"] && options.bugs, "check-in options: a bad value falls back on its own")

    // Claude replies cut off at max_tokens are marked, not passed off as complete.
    let cut = try AnthropicConnector.parse(Data(#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"Half an ans"}]}"#.utf8), status: 200)
    check(cut.truncated && cut.text == "Half an ans", "max_tokens marks the reply truncated")
    var thinkingOnly = false
    do { _ = try AnthropicConnector.parse(Data(#"{"stop_reason":"max_tokens","content":[{"type":"thinking","thinking":"…"}]}"#.utf8), status: 200) }
    catch ModelFailure.truncated { thinkingOnly = true }
    check(thinkingOnly, "cut off while thinking says truncated, not empty")

    // Without AI, only a whole "wrap up" ends a session; an observation that starts with those words doesn't.
    let qa = try store.startSession(kind: .qa, project: "strado", title: "Login QA")
    check(Rules.interpret("Wrap up the session", catalog: cat, activeSession: qa).action == "end_session", "rules: wrap up the session")
    check(Rules.interpret("That's it, thanks", catalog: cat, activeSession: qa).action == "end_session", "rules: that's it, thanks")
    check(Rules.interpret("That's it, the login button is broken again on Safari", catalog: cat, activeSession: qa).action != "end_session", "rules: an observation isn't a wrap-up")
    check(NotesIndex.tokens("issues") == NotesIndex.tokens("issue"), "singular and plural share a stem", "\(NotesIndex.tokens("issues")) \(NotesIndex.tokens("issue"))")
} catch {
    check(false, "review fixes threw \(error)")
}

print("Core fixes")
do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("broski-core-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: base) }

    // Ordinary words and bare numbers aren't project names, even with projects called "one" and "the".
    let wordy = ProjectCatalog(projects: ["one", "the", "strado"].map { Project(name: $0) })
    let wordyParser = NoteParser(catalog: wordy)
    let hand = wordyParser.parse("On one hand we should ship")
    check(hand.destination == .inbox, "\"On one hand …\" isn't the one project", hand.destination.displayName)
    let theBug = wordyParser.parse("The bug: login is broken")
    check(theBug.destination == .inbox, "\"The bug: …\" isn't the the project", theBug.destination.displayName)
    check(wordyParser.parse("For One, fix the oracle").destination.displayName == "one", "\"For One, …\" still files to One")
    check(CompanionPlanner.project(for: ItemContext(app: "Safari", window: "Inbox (1) - Gmail"), catalog: wordy, items: []) == nil,
          "context: \"Inbox (1)\" isn't the one project")
    check(wordy.mentioned(in: "which one of the strado bugs is worst")?.name == "strado", "question: skips \"one\" and \"the\", finds strado")

    // A bare article caught as the name isn't a new project.
    let theProject = parser.parse("In the project, add a todo: fix the build")
    check(theProject.destination == .inbox, "\"In the project, …\" makes no project called the", theProject.destination.displayName)
    let myApp = parser.parse("In my app, the login is broken")
    check(myApp.destination == .inbox, "\"In my app, …\" makes no project called my", myApp.destination.displayName)

    // "Never" on one stale idea leaves the others, and the check-in stops showing it.
    let ideaStore = ItemStore(root: base.appendingPathComponent("notes", isDirectory: true))
    let now = Date()
    let oldest = try ideaStore.create(ItemDraft(project: "strado", kind: .idea, title: "Offline mode for the field team"), date: now.addingTimeInterval(-40 * 86_400))
    let older = try ideaStore.create(ItemDraft(project: "strado", kind: .idea, title: "Voice search across projects"), date: now.addingTimeInterval(-30 * 86_400))
    let ideas = [oldest, older]
    var ideaLedger = CompanionLedger()
    let first = CompanionPlanner.staleIdea(items: ideas, now: now)
    check(first?.cites == [oldest.id], "stale idea: the oldest comes first")
    if let first { ideaLedger.record(.never, for: first) }
    check(CompanionPlanner.staleIdea(items: ideas, now: now, excluding: ideaLedger.muted)?.cites == [older.id], "never on the oldest stale idea leaves the next one")
    check(CompanionPlanner.staleIdea(items: ideas, now: now, excluding: ["kind:stale_idea"]) == nil, "muting the kind mutes every stale idea")
    let waiting = CheckIn.build(items: ideas, options: CheckIn.Options(), now: now, muted: ideaLedger.muted).groups.flatMap(\.lines).map(\.text)
    check(waiting == ["Still waiting: Voice search across projects"], "check-in skips a muted idea", "\(waiting)")

    // Clips quote every line, whatever the line break.
    check(Clip(text: "a\r\n\r\nb", source: ItemContext(app: "Notes")).markdown == "> a\n>\n> b\n>\n> — Notes", "clip quotes CRLF paragraphs",
          Clip(text: "a\r\n\r\nb", source: ItemContext(app: "Notes")).markdown)
    check(Clip(text: "a\rb", source: ItemContext(app: "Notes")).markdown == "> a\n> b\n>\n> — Notes", "clip quotes CR line breaks",
          Clip(text: "a\rb", source: ItemContext(app: "Notes")).markdown)

    // Repeated doc headings each keep their section; checklist items in same-named files keep theirs.
    let docs = base.appendingPathComponent("docs-tracker", isDirectory: true)
    try fm.createDirectory(at: docs.appendingPathComponent("docs", isDirectory: true), withIntermediateDirectories: true)
    let step = "Run the health check and confirm every service reports green before moving on."
    try "# Runbook\n\n## Deploy\n\n\(step)\n\n## Verify\n\n\(step)\n\n## Rollback\n\n\(step)\n\n## Verify\n\nShort.\n\n## Verify\n\n\(step)\n"
        .write(to: docs.appendingPathComponent("RUNBOOK.md"), atomically: true, encoding: .utf8)
    try "# Todo\n\n- [ ] Write the setup guide\n".write(to: docs.appendingPathComponent("TODO.md"), atomically: true, encoding: .utf8)
    try "# Todo\n\n- [ ] Record the demo\n".write(to: docs.appendingPathComponent("docs/TODO.md"), atomically: true, encoding: .utf8)
    let docRecords = TrackerReader.read(TrackerSource(id: "d", name: "d", path: docs.path), project: "p")
    let verify = docRecords.filter { $0.title == "RUNBOOK: Verify" }.map(\.recordID).sorted()
    check(verify.count == 2, "a runbook with repeated \"## Verify\" sections keeps both", "\(docRecords.map(\.recordID))")
    check(verify == ["RUNBOOK.md#verify", "RUNBOOK.md#verify-3"], "repeated headings are numbered in order, short sections counted", "\(verify)")
    let todos = docRecords.filter { $0.kind == "task" }.map(\.recordID).sorted()
    check(todos == ["TODO.md#1", "docs/TODO.md#1"], "checklist ids use the path, so two TODO.md files both count", "\(todos)")

    // Empty front matter: the body starts right after it, a later "---" rule and all.
    let emptyFront = YAMLFrontMatter.split("---\n---\nbody\n---\nmore")
    check(emptyFront.fields.isEmpty && emptyFront.body == "body\n---\nmore", "YAML: empty front matter keeps the whole body", emptyFront.body)
    check(FrontMatter.split("---\n---\n# T\n").body == "# T\n" && FrontMatter.split("---\n---\nbody\n---\nmore").body == "body\n---\nmore",
          "notes: empty front matter keeps the whole body", FrontMatter.split("---\n---\nbody\n---\nmore").body)
    check(FrontMatter.rawEntries("---\n---\nbody\n---\nmore").isEmpty, "notes: empty front matter has no raw entries")

    // Check-in timing, the budget across midnight, and the ledger on disk.
    let cal = Calendar.current
    let ten = cal.date(bySettingHour: 10, minute: 0, second: 0, of: now)!
    let early = cal.date(bySettingHour: 1, minute: 30, second: 0, of: now) ?? ten
    check(CheckIn.isDue(at: "09:30", lastShown: cal.date(byAdding: .day, value: -1, to: ten), now: ten), "check-in due again the next day")
    check(!CheckIn.isDue(at: "25:00", lastShown: nil, now: ten) && !CheckIn.isDue(at: "25:00", lastShown: nil, now: early), "a bad check-in time is never due")
    func idea(_ key: String) -> Nudge { Nudge(kind: .staleIdea, key: key, project: nil, title: "t", body: "b") }
    let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
    let late = midnight.addingTimeInterval(-120)
    var night = CompanionLedger()
    night.shown(idea("idea:a"), now: late)
    night.shown(idea("idea:b"), now: late)
    check(!night.allows(idea("idea:c"), mode: .daily, now: late.addingTimeInterval(60)), "daily budget spent before midnight")
    let checkInNudge = Nudge(kind: .checkIn, key: "checkin:x", project: nil, title: "", body: "")
    let checkInDaily = night.allows(checkInNudge, mode: .daily, now: late.addingTimeInterval(60))
    let checkInQuiet = night.allows(checkInNudge, mode: .quiet, now: late.addingTimeInterval(60))
    check(checkInDaily && checkInQuiet, "the check-in nudge ignores the budget")
    check(night.allows(idea("idea:c"), mode: .daily, now: midnight.addingTimeInterval(60)), "daily budget resets at midnight")
    night.shown(idea("idea:c"), now: midnight.addingTimeInterval(60))
    night.record(.never, for: idea("idea:a"))
    let ledgerFile = base.appendingPathComponent("companion.json")
    night.save(to: ledgerFile)
    let reloaded = CompanionLedger.load(from: ledgerFile)
    let sameLedger = reloaded.muted == night.muted && reloaded.shownToday == night.shownToday && reloaded.day == night.day
    check(sameLedger && night.muted.contains("idea:a") && night.shownToday == 1, "ledger round-trips through save and load",
          "\(reloaded.muted) \(reloaded.shownToday) \(reloaded.day)")
} catch {
    check(false, "core fixes threw \(error)")
}

print("Drift and changes")
do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("broski-drift-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    func put(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func finding(_ id: String, _ status: String, _ body: String = "Seen in the logs.") -> String {
        "---\nid: \(id)\ntitle: \"Finding \(id)\"\nseverity: high\nstatus: \(status)\ncategory: finding\narea: Backend\n---\n\(body)\n"
    }
    func decisions(_ second: String) -> String {
        #"{"kind":"decisions","value":{"decisions":[{"id":"DEC-1","question":"Use Chainlink?","status":"decided","decidedAt":"2026-10-10T10:00:00Z"},"#
            + #"{"id":"DEC-2","question":"Which mainnet date?","status":"\#(second)"}]}}"#
    }
    func plan(attested: Bool) -> String {
        #"{"kind":"launch-plan","value":{"steps":[{"id":"S1","what":"Deploy the oracle","who":"ops""#
            + (attested ? #","attested":{"at":"2026-10-21T09:00:00Z","by":"ops"}"# : "") + "}]}}"
    }

    // A command-center tracker, read through a manifest Broski keeps in its own folder.
    let one = base.appendingPathComponent("acme-tracker", isDirectory: true)
    try put(one, "tracker/findings/ACME-1.md", finding("ACME-1", "open"))
    try put(one, "tracker/findings/ACME-4.md", finding("ACME-4", "open"))
    try put(one, "tracker/findings/ACME-5.md", finding("ACME-5", "parked", "Parked until the audit lands."))
    try put(one, "tracker/data/agents.json", #"{"kind":"agents","value":{"agents":[{"name":"ops"},{"name":"app"}],"defaultOwner":"ops"}}"#)
    try put(one, "tracker/data/decisions.json", decisions("open"))
    try put(one, "tracker/data/launch-plan.json", plan(attested: false))
    try put(one, "tracker/agents/reviews.jsonl", #"{"id":"R1","kind":"remark","to":"app","by":"ops","text":"Check the oracle limit","at":"2026-10-15T00:00:00Z"}"# + "\n")
    try put(one, "tracker/data/new-thing.json", #"{"value":{"things":[]}}"#)
    try put(one, "tracker/data/value-flows.json", #"{"value":{}}"#)
    try put(one, "tracker/notes/README.md", "What this folder is for.\n")
    try put(one, "README.md", "# One\n\nThe command center.\n")
    try put(one, "docs/guide.md", "# Guide\n\n## Start\n\nHow a new thread starts work on the protocol, step by step.\n")
    typealias S = TrackerManifest.Source
    let manifest = TrackerManifest(id: "acme", title: "Acme", adapter: "acme-tracker", core: [
        "findings": [S(reader: "fm-records", glob: "tracker/findings/*.md", kindFrom: "category"),
                     S(reader: "fm-records", glob: "tracker/findings/DES-*.md", kindFrom: "category")],
        "decisions": [S(reader: "json-records", file: "tracker/data/decisions.json", path: "value.decisions[]", kind: "decision",
                        map: ["title": "question", "date": "decidedAt"])],
        "launch": [S(reader: "json-records", file: "tracker/data/launch-plan.json", path: "value.steps[]", kind: "step",
                     map: ["title": "what", "owner": "who"], launch: "launch", live: true)],
        "ops": [S(reader: "json-records", file: "tracker/data/runbook.json", path: "value.phases[].actions[]", kind: "runbook"),
                S(reader: "md-sections", glob: "tracker/runbooks/*.md", kind: "runbook")],
        "threads": [S(reader: "json-records", file: "tracker/data/agents.json", path: "value.agents[]", kind: "thread", map: ["id": "name"]),
                    S(reader: "jsonl-records", file: "tracker/agents/reviews.jsonl", kind: "message", filter: ["kind": "remark"],
                      map: ["title": "text", "owner": "to", "date": "at"])],
    ], layers: [.init(name: "docs", title: "Docs", sources: [S(reader: "md-sections", glob: "docs/*.md", kind: "doc")])],
       statusMap: ["solved": "done"], openWhen: ["open"], lowTrust: ["README.md"], generated: ["value-flows"])
    let overlays = base.appendingPathComponent("BroskiRoot/trackers", isDirectory: true)
    try fm.createDirectory(at: overlays, withIntermediateDirectories: true)
    try JSONEncoder().encode(manifest).write(to: overlays.appendingPathComponent(TrackerManifest.overlayName("acme")))
    let source = TrackerSource(id: "acme", name: "Acme", path: one.path)
    let snap0 = TrackerReader.snapshot(source, project: "acme", overlays: overlays)
    let drift = snap0.drift

    // Drift, from what the read already holds.
    check(drift.unmapped == ["tracker/data/new-thing.json"] && drift.unmappedCount == 1,
          "drift: a file no source reads is unmapped; generated data, prose and folder READMEs aren't", "\(drift.unmapped)")
    check(drift.deadSources == ["ops.runbook <- tracker/data/runbook.json", "ops.runbook <- tracker/runbooks/*.md"],
          "drift: a mapping to a missing file or folder is dead; an empty glob in a live folder isn't", "\(drift.deadSources)")
    check(drift.unknownStatuses == ["parked": 1], "drift: a status word no one knows is counted", "\(drift.unknownStatuses)")
    check(CanonicalStatus.isKnown("solved") && CanonicalStatus.isKnown("In Progress") && !CanonicalStatus.isKnown("parked"), "status words: known and unknown")
    check(CanonicalStatus.from("parked") == .open && CanonicalStatus.from("") == CanonicalStatus.none, "unknown words still read as open")
    check(TrackerReader.snapshot(TrackerSource(id: "d", name: "d", path: one.path, scope: .docs), project: "acme").drift.isEmpty,
          "drift: a docs folder has none (its globs are guesses)")
    let combined = TrackerDrift.combined([(source: "a", drift: TrackerDrift(unmapped: ["x.md"])), (source: "b", drift: TrackerDrift(unknownStatuses: ["parked": 2]))])
    check(combined.unmapped == ["a: x.md"] && combined.unmappedCount == 1 && combined.unknownStatuses == ["parked": 2], "drift: several trackers combine, paths named by tracker")

    // The change stream: the first read is the baseline, then each change between reads is one event.
    let state0 = ChangeStream.state(of: snap0.records, revision: snap0.revision)
    check(ChangeStream.diff(old: nil, new: state0, project: "acme", source: "acme").isEmpty, "stream: the first read is the baseline, no events")
    try put(one, "tracker/findings/ACME-1.md", finding("ACME-1", "solved"))
    try put(one, "tracker/findings/ACME-3.md", finding("ACME-3", "open"))
    try fm.removeItem(at: one.appendingPathComponent("tracker/findings/ACME-4.md"))
    try put(one, "tracker/data/decisions.json", decisions("decided"))
    try put(one, "tracker/data/launch-plan.json", plan(attested: true))
    try put(one, "tracker/agents/reviews.jsonl", """
    {"id":"R1","kind":"remark","to":"app","by":"ops","text":"Check the oracle limit","at":"2026-10-15T00:00:00Z"}
    {"id":"R2","kind":"remark","to":"ops","by":"app","text":"Limit checked","at":"2026-10-21T08:00:00Z"}
    {"id":"A1","kind":"ack","by":"app","acks":["R1"],"at":"2026-10-21T08:05:00Z"}

    """)
    let snap1 = TrackerReader.snapshot(source, project: "acme", overlays: overlays)
    let state1 = ChangeStream.state(of: snap1.records, revision: snap1.revision)
    let at = TrackerReader.parseDateString("2026-10-21T10:00:00Z")!
    let events = ChangeStream.diff(old: state0, new: state1, project: "acme", source: "acme", at: at)
    let seen = events.map { "\($0.kind) \($0.id)" }.sorted()
    check(seen == ["attested acme:launch/S1", "closed acme:ACME-1", "decided acme:DEC-2", "new acme:ACME-3", "new acme:reviews/R2", "removed acme:ACME-4"],
          "stream: closed, new, decided, attested, removed; a read receipt isn't news", "\(seen)")
    let closed = events.first { $0.kind == "closed" }
    check(closed?.from == "open" && closed?.to == "solved" && closed?.title == "Finding ACME-1", "stream: a change keeps its native statuses and title")
    check(events.first { $0.kind == "attested" }?.to == "ops at 2026-10-21T09:00:00Z", "stream: an attestation says who and when")
    check(!state1.records.keys.contains("acme:agents/ops") && !state1.records.keys.contains { $0.contains("guide.md") }, "stream: threads and docs (no status) aren't followed")

    // Stored in Broski's folder only, and read back.
    let root = base.appendingPathComponent("BroskiRoot", isDirectory: true)
    try ChangeStream.append(events, root: root, project: "acme", device: "mac")
    check(ChangeStream.read(root: root, project: "acme", since: .distantPast) == events, "stream: append and read round-trip")
    let later = ChangeEvent(at: at.addingTimeInterval(3600), project: "trader", source: "trader", kind: "status", id: "trader:T-1",
                            title: "Backtest", from: "open", to: "doing")
    try ChangeStream.append([later], root: root, project: "trader", device: "mac")
    check(ChangeStream.read(root: root, project: "acme", since: at.addingTimeInterval(60)).isEmpty, "stream: since leaves out older events")
    check(ChangeStream.read(root: root, project: nil, since: at.addingTimeInterval(60)) == [later] && ChangeStream.read(root: root, project: nil).count == events.count + 1,
          "stream: every project's stream when no project is named")
    check(fm.fileExists(atPath: root.appendingPathComponent("projects/acme/stream.mac.jsonl").path)
          && !((fm.enumerator(atPath: one.path)?.allObjects as? [String]) ?? []).contains { $0.contains("stream.") || $0.contains("state") },
          "stream: written in Broski's folder, never the tracker's")
    try ChangeStream.saveState(state1, root: root, source: "acme")
    check(ChangeStream.loadState(root: root, source: "acme") == state1, "stream: the last state reloads")
    check(ChangeStream.stateFile(root: root, source: "tamer/Tamer").lastPathComponent == "tamer__Tamer.json", "stream: state files named like overlays")
    check(ChangeStream.update(with: snap1, project: "acme", root: root, device: "mac").isEmpty, "stream: an unchanged read records nothing")
    let missing = TrackerReader.snapshot(TrackerSource(id: "acme", name: "Acme", path: base.appendingPathComponent("gone").path), project: "acme", overlays: overlays)
    check(ChangeStream.update(with: missing, project: "acme", root: root, device: "mac").isEmpty && ChangeStream.loadState(root: root, source: "acme") == state1,
          "stream: a tracker folder missing for a moment isn't every record removed")
    try put(one, "tracker/findings/ACME-3.md", finding("ACME-3", "solved"))
    let update = ChangeStream.update(with: TrackerReader.snapshot(source, project: "acme", overlays: overlays), project: "acme", root: root, device: "mac", at: at)
    check(update.map(\.kind) == ["closed"] && ChangeStream.read(root: root, project: "acme").count == events.count + 1, "stream: update diffs, appends and saves")

    // Delta runs: each kind of drift asks its own questions, of its own thread.
    func ask(_ health: Onboarding.Health, stale: [String] = []) -> [String: [String]] { Onboarding.deltaAssign(health, stale: stale) }
    let mapQuestions = ["Q-ITEM-1", "Q-LAY-1", "Q-LAY-2"]
    check(ask(Onboarding.Health(drift: TrackerDrift(unmapped: ["tracker/data/new-thing.json"]), lead: "ops")) == ["ops": mapQuestions], "delta: a file no source reads asks the lead the map questions")
    check(ask(Onboarding.Health(drift: TrackerDrift(deadSources: ["ops.runbook <- tracker/data/runbook.json"]), lead: "ops")) == ["ops": mapQuestions], "delta: a mapping that finds nothing asks the same")
    check(ask(Onboarding.Health(drift: TrackerDrift(unknownStatuses: ["parked": 1]), lead: "ops")) == ["ops": ["Q-ITEM-2"]], "delta: an unknown status word asks Q-ITEM-2")
    check(ask(Onboarding.Health(newThreads: ["risk"], lead: "ops")) == ["risk": ["Q-THR-1", "Q-THR-2", "Q-THR-3"]], "delta: only the new thread gets the thread questions")
    check(ask(Onboarding.Health(lead: "ops"), stale: ["Q-OPS-1.app.md"]) == ["app": ["Q-OPS-1"]], "delta: a stale answer goes back to its thread")
    check(ask(Onboarding.Health(lead: "ops")).isEmpty && !Onboarding.Health(lead: "ops").drifted, "delta: nothing drifted, nothing to ask")
    let everything = Onboarding.Health(drift: drift, newThreads: ["risk"], lead: "ops")
    let assign = ask(everything, stale: ["Q-OPS-1.app.md"])
    check(assign == ["ops": ["Q-ITEM-1", "Q-ITEM-2", "Q-LAY-1", "Q-LAY-2"], "risk": ["Q-THR-1", "Q-THR-2", "Q-THR-3"], "app": ["Q-OPS-1"]],
          "delta: every kind at once, in questionnaire order", "\(assign)")
    let note = Onboarding.deltaNote(everything, stale: ["Q-OPS-1.app.md"])
    check(note.contains("- tracker/data/new-thing.json") && note.contains("- ops.runbook <- tracker/data/runbook.json") && note.contains("- parked (1)")
          && note.contains("- risk") && note.contains("- Q-OPS-1.app.md"), "delta note lists the files, mappings, status words, threads and stale answers", note)
    let delta = try Onboarding.startRun(project: "acme", title: "Acme", mode: "delta", repos: ["tracker": one.path], threads: assign.keys.sorted(),
                                        assign: assign, note: note, root: root, date: at)
    let reloaded = Onboarding.loadRun(delta.folder)
    check(reloaded?.mode == "delta" && reloaded?.assign == assign && reloaded?.note == note, "delta run reloads with its mode, assignments and note",
          "\(String(describing: reloaded))")
    let riskPrompt = (try? String(contentsOf: delta.folder.appendingPathComponent("PROMPT-risk.md"), encoding: .utf8)) ?? ""
    check(riskPrompt.contains("WHAT CHANGED SINCE THE LAST RUN\n") && riskPrompt.contains("tracker/data/new-thing.json")
          && riskPrompt.contains("Your questions: Q-THR-1, Q-THR-2, Q-THR-3."), "delta prompt: what changed, and only that thread's questions")
    let asked = (try? String(contentsOf: delta.folder.appendingPathComponent("QUESTIONS.md"), encoding: .utf8)) ?? ""
    check(asked.contains("### Q-THR-1") && asked.contains("### Q-OPS-1") && !asked.contains("### Q-ID-1"), "delta QUESTIONS.md holds only what's asked")
    let draft = OnboardingCheck.assemble(delta, report: OnboardingCheck.check(delta), source: source, base: manifest)
    check(draft.core["findings"]?.count == 2 && draft.core["decisions"]?.count == 1 && draft.core["ops"]?.isEmpty == true,
          "delta assemble builds on the live manifest, less the mappings that find nothing", "\(draft.core.mapValues(\.count))")
    let full = try Onboarding.startRun(project: "acme", title: "Acme", mode: "convert", repos: ["tracker": one.path], threads: ["ops"], root: root, date: at)
    let fullPrompt = (try? String(contentsOf: full.folder.appendingPathComponent("PROMPT-ops.md"), encoding: .utf8)) ?? "WHAT CHANGED"
    check(!fullPrompt.contains("WHAT CHANGED") && full.note == nil && Onboarding.loadRun(full.folder)?.note == nil, "a full run has no what-changed section")

    // Stale answers: one that checked out, whose quote has since gone from the file.
    let checked = try Onboarding.startRun(project: "acme", title: "Acme", mode: "convert", repos: ["tracker": one.path], threads: ["main"],
                                          questionIDs: ["Q-ITEM-2"], root: root, date: at)
    try "---\nq: Q-ITEM-2\nthread: main\nstatus: answered\nevidence:\n  - ref: \"file:tracker/findings/ACME-5.md\"\n    quote: \"Parked until the audit lands\"\n---\nParked means waiting on the audit.\n"
        .write(to: checked.folder.appendingPathComponent("Q-ITEM-2.main.md"), atomically: true, encoding: .utf8)
    let before = OnboardingCheck.check(checked)
    OnboardingCheck.write(before, to: checked.folder)
    check(before.answers.first?.verdict == "ok" && OnboardingCheck.load(from: checked.folder) == before, "stale: the run's check reloads from check.json")
    try put(one, "tracker/findings/ACME-5.md", finding("ACME-5", "parked", "Waiting on the auditors."))
    check(OnboardingCheck.stale(before: before, now: OnboardingCheck.check(checked)) == ["Q-ITEM-2.main.md"], "stale: an answer whose quote is gone since its check")
    check(OnboardingCheck.stale(before: before, now: before).isEmpty, "stale: nothing changed, nothing stale")
} catch {
    check(false, "drift and changes threw \(error)")
}

print("Transcript polish")
do {
    let names = ["strado", "hip3-observatory", "Chainlink", "Hyperliquid", "Acme Protocol", "Falcon", "ORBIT"]
    check(TranscriptPolish.apply("in the strato project ad a bug the login button stays disabled", vocabulary: names)
          == "In the strado project ad a bug the login button stays disabled.", "polish: near-miss project name, capital, full stop",
          TranscriptPolish.apply("in the strato project ad a bug the login button stays disabled", vocabulary: names))
    check(TranscriptPolish.apply("we ask chain link for our own verifier config", vocabulary: names) == "We ask Chainlink for our own verifier config.",
          "polish: two words make one name", TranscriptPolish.apply("we ask chain link for our own verifier config", vocabulary: names))
    check(TranscriptPolish.apply("hip three observatory needs a snapshot", vocabulary: names) == "Hip3-observatory needs a snapshot.",
          "polish: three words with a number word", TranscriptPolish.apply("hip three observatory needs a snapshot", vocabulary: names))
    check(TranscriptPolish.apply("so um i was thinking, uh, we should ship. then i'll test it", vocabulary: names)
          == "So I was thinking, we should ship. Then I'll test it.", "polish: fillers, I, sentences",
          TranscriptPolish.apply("so um i was thinking, uh, we should ship. then i'll test it", vocabulary: names))
    check(TranscriptPolish.apply("set a timer and check the lab", vocabulary: names) == "Set a timer and check the lab.",
          "polish: everyday words that are project names stay", TranscriptPolish.apply("set a timer and check the lab", vocabulary: names))
    check(TranscriptPolish.apply("Already punctuated, right?", vocabulary: []) == "Already punctuated, right?", "polish: punctuated text unchanged")
    check(TranscriptPolish.apply("", vocabulary: names) == "", "polish: nothing stays nothing")
}

print("Hold fn to talk")
do {
    var fn = FnHold()
    check(fn.handle(.fnDown(withModifiers: false)) == .startTimer && fn.timerFired() == .startTalking && fn.handle(.fnUp) == .stopTalking,
          "fn: hold, talk, let go")
    fn = FnHold()
    check(fn.handle(.fnDown(withModifiers: false)) == .startTimer && fn.handle(.fnUp) == .cancelTimer && fn.timerFired() == .none,
          "fn: a quick tap does nothing")
    fn = FnHold()
    check(fn.handle(.fnDown(withModifiers: false)) == .startTimer && fn.handle(.keyDown) == .cancelTimer && fn.timerFired() == .none && fn.handle(.fnUp) == .none,
          "fn: fn+arrow is never a hold")
    fn = FnHold()
    check(fn.handle(.fnDown(withModifiers: true)) == .none && fn.timerFired() == .none, "fn: with ⌘/⌥/⌃/⇧ already held, it's someone's shortcut")
    fn = FnHold()
    check(fn.handle(.fnDown(withModifiers: false)) == .startTimer && fn.handle(.otherModifier) == .cancelTimer && fn.timerFired() == .none,
          "fn: a modifier added before the hold cancels it")
    fn = FnHold()
    _ = fn.handle(.fnDown(withModifiers: false))
    _ = fn.timerFired()
    check(fn.handle(.keyDown) == .none && fn.holding && fn.handle(.fnUp) == .stopTalking, "fn: keys pressed while talking don't stop it")
    fn = FnHold()
    _ = fn.handle(.fnDown(withModifiers: false))
    check(fn.handle(.fnDown(withModifiers: false)) == .none, "fn: a repeated down is ignored")
}

print("Trackers")
do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("broski-trackers-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: base) }
    func put(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // Front matter: scalars, quotes, lists, block text, nested maps.
    let (front, body) = YAMLFrontMatter.split("---\nid: ACME-1\ntitle: \"Oracle: stale\"\nlinks: [ACME-2, DES-1]\nrefs:\n  - a\n  - b\nplain: |-\n  line one\n  line two\nmeta:\n  owner: app\n---\nBody\n")
    check(front["id"]?.string == "ACME-1" && front["title"]?.string == "Oracle: stale", "front matter: scalars and quoted colons")
    check(front["links"]?.list == ["ACME-2", "DES-1"] && front["refs"]?.list == ["a", "b"], "front matter: flow and block lists", "\(String(describing: front["links"])) \(String(describing: front["refs"]))")
    check(front["plain"]?.string?.contains("line one") == true && front["plain"]?.string?.contains("line two") == true, "front matter: block text")
    check(front["meta.owner"]?.string == "app", "front matter: nested map flattened")
    check(body.hasPrefix("Body"), "front matter: body after the fence")
    check(YAMLFrontMatter.split("no front matter").fields.isEmpty, "no front matter: no fields")

    // Canonical statuses.
    check(CanonicalStatus.from("solved") == .done && CanonicalStatus.from("In Progress") == .doing && CanonicalStatus.from("won't fix") == .wontfix, "status words map to canonical")
    check(CanonicalStatus.from("decided").isOpen == false && CanonicalStatus.from("todo").isOpen, "decided is closed, todo is open")

    // A command-center tracker, read from the working tree (not a git repo here).
    let one = base.appendingPathComponent("acme-tracker", isDirectory: true)
    try put(one, "tracker/findings/ACME-1.md", "---\nid: ACME-1\ntitle: \"Oracle: stale price accepted\"\nseverity: crit\nstatus: open\ncategory: finding\nseries: ONE\narea: Backend / API\nwhere: oracle.daml\nbody_format: markdown\nplain: |-\n  The oracle accepts a price older than the limit.\nopened: 2026-10-01\n---\nSeen by google-oauth2_1234567890 in the logs.\n")  // secretscan:allow (a fake account id the reader must redact)
    try put(one, "tracker/findings/ACME-2.md", "---\nid: ACME-2\ntitle: Vault rounding\nseverity: high\nstatus: solved\ncategory: finding\nseries: ONE\narea: Stability vault\nwhere: vault.daml\nbody_format: markdown\nclosed: 2026-10-05\n---\nFixed.\n")
    try put(one, "tracker/findings/DES-1.md", "---\nid: DES-1\ntitle: Old decision\nseverity: info\nstatus: decided\ncategory: decision\nseries: DES\narea: Design\nwhere: docs\nbody_format: markdown\n---\nKept in the register.\n")
    try put(one, "tracker/data/agents.json", #"{"kind":"agents","value":{"agents":[{"name":"ops"},{"name":"app"},{"name":"vault"}],"owners":[{"area":"^(Backend|Frontend)","owner":"app"},{"area":"^Stability vault","owner":"vault"}],"defaultOwner":"ops"}}"#)
    try put(one, "tracker/data/decisions.json", #"{"kind":"decisions","value":{"decisions":[{"id":"DEC-1","question":"Use Chainlink?","status":"decided","decidedAt":"2026-10-10T10:00:00Z","decider":"you","decision":"Yes, Chainlink first."},{"id":"DEC-2","question":"Which mainnet date?","status":"open","decider":"you","raisedAt":"2026-10-12"}]}}"#)
    try put(one, "tracker/agents/reviews.jsonl", """
    {"id":"R1","kind":"remark","to":"app","by":"ops","text":"Please check the oracle limit","at":"2026-10-15T00:00:00Z"}
    {"id":"R2","kind":"remark","to":"ops","by":"app","text":"Done on my side","at":"2026-10-16T00:00:00Z"}
    {"id":"A1","kind":"ack","by":"ops","acks":["R2"],"at":"2026-10-16T01:00:00Z"}

    """)
    try put(one, "tracker/.env", "SECRET=nope\n")
    let oneSource = TrackerSource(id: "acme", name: "Acme", path: one.path)
    // Read through the project's own manifest, kept as an overlay in Broski's folder, the way a real
    // command-center tracker is read.
    typealias MS = TrackerManifest.Source
    let acmeManifest = TrackerManifest(id: "acme", title: "Acme", adapter: "command-center", readFrom: "main", people: ["owner": ["you"]], core: [
        "findings": [MS(reader: "fm-records", glob: "tracker/findings/*.md", kindFrom: "category")],
        "decisions": [MS(reader: "json-records", file: "tracker/data/decisions.json", path: "value.decisions[]", kind: "decision",
                         map: ["title": "question", "date": "decidedAt", "opened": "raisedAt"])],
        "threads": [MS(reader: "json-records", file: "tracker/data/agents.json", path: "value.agents[]", kind: "thread", map: ["id": "name"]),
                    MS(reader: "jsonl-records", file: "tracker/agents/reviews.jsonl", kind: "message", filter: ["kind": "remark"],
                       map: ["title": "text", "owner": "to", "date": "at"])],
    ], statusMap: ["solved": "done", "design": "accepted"], openWhen: ["open"], exclude: ["**/.env*"], redact: ["google-oauth2_[0-9]+"])
    let acmeOverlays = base.appendingPathComponent("AcmeRoot/trackers", isDirectory: true)
    try fm.createDirectory(at: acmeOverlays, withIntermediateDirectories: true)
    try JSONEncoder().encode(acmeManifest).write(to: acmeOverlays.appendingPathComponent(TrackerManifest.overlayName("acme")))
    let snap = TrackerReader.snapshot(oneSource, project: "acme", overlays: acmeOverlays)
    let records = snap.records
    func record(_ id: String) -> TrackerRecord? { records.first { $0.recordID == id } }
    check(snap.manifest == "command-center", "reads a command-center tracker through its overlay", snap.manifest)
    check(TrackerPresets.detect(oneSource).adapter == "generic-markdown", "no preset names a private project's shape")
    check(snap.problems.contains { $0.contains("working tree") }, "no git: says it read the working tree", snap.problems.joined(separator: "; "))
    check(records.filter { $0.section == .findings }.count == 3, "three findings, the old decision kept in findings", "\(records.filter { $0.section == .findings }.map(\.recordID))")
    check(record("ACME-1")?.open == true && record("ACME-2")?.open == false && record("DES-1")?.open == false, "only open counts as open")
    check(record("ACME-1")?.fields["owner_thread"] == "app" && record("ACME-2")?.fields["owner_thread"] == "vault" && record("DES-1")?.fields["owner_thread"] == "ops", "owner rules: area, then the default",
          "\(String(describing: record("ACME-1")?.fields["owner_thread"])) \(String(describing: record("ACME-2")?.fields["owner_thread"])) \(String(describing: record("DES-1")?.fields["owner_thread"]))")
    check(record("ACME-1")?.summary.contains("older than the limit") == true, "plain words become the summary")
    check(!records.contains { ($0.body + $0.title + $0.summary).range(of: "google-oauth2_[0-9]+", options: .regularExpression) != nil }, "account ids are redacted")
    check(!records.contains { $0.path.contains(".env") }, "never reads .env")
    check(record("DEC-2")?.open == true && record("DEC-1")?.open == false && record("DEC-1")?.title == "Use Chainlink?", "decisions: open and decided, title from the question")
    let messages = records.filter { $0.kind == "message" }
    check(messages.count == 2, "two remarks, the ack isn't one", "\(messages.map(\.recordID))")
    check(messages.first { $0.fields["to"] == "app" }?.canonical == .unread && messages.first { $0.fields["to"] == "ops" }?.canonical == .read, "acked remark is read, the other unread")
    let waiting = WaitingOn.lines(records: records, notes: [])
    check(waiting.contains { $0.text.hasPrefix("Decide DEC-2") } && !waiting.contains { $0.text.contains("DEC-1") }, "waiting on me: the open decision only", "\(waiting.map(\.text))")
    check(WaitingOn.unread(records: records).map { "\($0.thread) \($0.ids.count)" } == ["app 1"], "unread per thread")
    let since = TrackerReader.parseDateString("2026-09-30")!
    let entries = Journal.entries(records: records, notes: [], since: since, until: TrackerReader.parseDateString("2026-10-31")!)
    check(entries.contains { $0.kind == "decided" && $0.cite == "acme:DEC-1" } && entries.contains { $0.kind == "opened" && $0.cite == "acme:ACME-1" }
          && entries.contains { $0.kind == "closed" && $0.cite == "acme:ACME-2" }, "journal: decided, opened, closed", "\(entries.map { "\($0.kind) \($0.cite ?? "")" })")
    let now = TrackerReader.parseDateString("2026-10-21")!
    let today = Calendar.current.startOfDay(for: now)
    check(Journal.range(in: "what changed in the last 3 days", now: now) == Calendar.current.date(byAdding: .day, value: -3, to: today), "time phrase: last 3 days")
    check(Journal.range(in: "anything from yesterday?", now: now) == Calendar.current.date(byAdding: .day, value: -1, to: today), "time phrase: yesterday")
    check(Journal.range(in: "what is DEC-14 about", now: now) == nil, "no time phrase: nil")

    // Project names: talking to Broski isn't naming the broski project; common words don't match alone.
    let names = ProjectCatalog(projects: [Project(name: "acme", spoken: "Acme Protocol"), Project(name: "broski"), Project(name: "strado"), Project(name: "the")])
    check(names.mentioned(in: "Yo Broski, what's waiting on me for strado")?.name == "strado", "wake word skipped, project found")
    check(names.mentioned(in: "Broski, what's open across the threads") == nil, "common word alone isn't a project")
    check(names.mentioned(in: "what's new in the broski project")?.name == "broski", "the broski project by name")

    // A Broski-owned tracker: template, ids, status changes, read back.
    let root = base.appendingPathComponent("BroskiRoot", isDirectory: true)
    let trader = try TrackerTemplate.create(project: "trader", title: "Trader", about: "A trading bot.", root: root)
    check(fm.fileExists(atPath: trader.appendingPathComponent("ship/PLAN.md").path) && fm.fileExists(atPath: trader.appendingPathComponent("threads/THREADS.md").path), "template: tree created")
    try "# Trader tracker\n\nEdited by hand.\n".write(to: trader.appendingPathComponent("TRACKER.md"), atomically: true, encoding: .utf8)
    try TrackerTemplate.create(project: "trader", title: "Trader", root: root)
    check((try? String(contentsOf: trader.appendingPathComponent("TRACKER.md"), encoding: .utf8))?.contains("Edited by hand") == true, "template: running it again keeps edits")
    let bug1 = try TrackerTemplate.add(kind: "bug", title: "Orders \"double\" filled", severity: "high", tracker: trader, root: root)
    let bug2 = try TrackerTemplate.add(kind: "bug", title: "Slippage too wide", tracker: trader, root: root)
    let task1 = try TrackerTemplate.add(kind: "task", title: "Backtest on 2025 data", owner: "you", tracker: trader, root: root)
    let dec1 = try TrackerTemplate.add(kind: "decision", title: "Which exchange first?", tracker: trader, root: root)
    check([bug1, bug2, task1, dec1] == ["BUG-1", "BUG-2", "T-1", "DEC-1"], "template: ids per kind", "\([bug1, bug2, task1, dec1])")
    try TrackerTemplate.setStatus("BUG-1", to: "done", note: "Fixed in v2", tracker: trader, root: root, date: now)
    try TrackerTemplate.setStatus("DEC-1", to: "decided", note: "Hyperliquid", tracker: trader, root: root, date: now)
    let bugText = (try? String(contentsOf: trader.appendingPathComponent("items/BUG-1.md"), encoding: .utf8)) ?? ""
    check(bugText.contains("status: done") && bugText.contains("closed: ") && bugText.contains("resolution: \"Fixed in v2\""), "status change: closed with a resolution", bugText)
    let traderRecords = TrackerReader.read(TrackerSource(id: "trader", name: "Trader", path: trader.path, readOnly: false), project: "trader")
    func tr(_ id: String) -> TrackerRecord? { traderRecords.first { $0.recordID == id } }
    check(tr("BUG-1")?.open == false && tr("BUG-2")?.open == true && tr("T-1")?.open == true, "Broski tracker: item statuses read back")
    check(tr("BUG-1")?.title == "Orders \"double\" filled" && tr("BUG-1")?.severity == "high", "Broski tracker: quoted title and severity")
    check(tr("DEC-1")?.title == "Which exchange first?" && tr("DEC-1")?.open == false && tr("DEC-1")?.summary == "Hyperliquid", "Broski tracker: decision with its answer")
    check(tr("L-1")?.kind == "step", "Broski tracker: launch step id", "\(traderRecords.filter { $0.kind == "step" }.map(\.recordID))")
    check(!traderRecords.contains { $0.recordID == "README" }, "folder READMEs aren't records")
    check(Journal.entries(records: traderRecords, notes: [], since: since, until: now.addingTimeInterval(86_400)).contains { $0.kind == "decided" && $0.cite == "trader:DEC-1" }, "Broski tracker: decision in the journal")
    var refused = false
    do { try TrackerTemplate.add(kind: "bug", title: "x", tracker: one, root: root) } catch { refused = true }
    check(refused && !fm.fileExists(atPath: one.appendingPathComponent("items").path), "never writes to a project's own tracker")
    refused = false
    do { try TrackerTemplate.setStatus("ACME-1", to: "done", tracker: root.appendingPathComponent("projects/../../acme-tracker"), root: root) } catch { refused = true }
    check(refused, "no escaping the projects folder with ..")

    // Evidence refs and quotes.
    let e = Onboarding.Evidence.parse("file:@tracker:tracker/data/runbook.json#L3-L9", quote: "q")
    check(e?.kind == .file && e?.alias == "tracker" && e?.target == "tracker/data/runbook.json" && e?.lines == 3...9, "evidence: file with alias and lines")
    check(Onboarding.Evidence.parse("record:ACME-1")?.kind == .record && Onboarding.Evidence.parse("pr:12")?.strong == false && Onboarding.Evidence.parse("bogus:x") == nil, "evidence: kinds")
    check(Onboarding.normalize("**Hello**   `world`\n") == "hello world", "quotes ignore emphasis, backticks and spacing")
    let map = OnboardingCheck.parseMap("ops.runbook <- @tracker:tracker/data/runbook.json | json-records | value.phases[].actions[]")
    check(map?.section == "ops" && map?.source.kind == "runbook" && map?.alias == "tracker" && map?.source.file == "tracker/data/runbook.json" && map?.source.path == "value.phases[].actions[]", "maps line parsed")

    // An onboarding run checked against the fixture.
    let run = try Onboarding.startRun(project: "trader", title: "Trader", mode: "new", repos: ["tracker": one.path], threads: ["main", "ops"], root: root, date: now)
    check(["RUN.md", "QUESTIONS.md", "FORMAT.md", "PROMPT-main.md", "PROMPT-ops.md"].allSatisfy { fm.fileExists(atPath: run.folder.appendingPathComponent($0).path) }, "run folder written")
    let loaded = Onboarding.loadRun(run.folder)
    check(loaded?.repos == ["tracker": one.path] && loaded?.assign["main"]?.count == Onboarding.newProjectQuestions.count && loaded?.assign["ops"]?.contains("Q-THR-1") == true, "run reloads with repos and assignments", "\(String(describing: loaded))")
    func answer(_ name: String, _ status: String, _ evidence: [(String, String?)], maps: [String] = []) throws {
        var text = "---\nq: \(name.split(separator: ".")[0])\nthread: \(name.split(separator: ".")[1])\nstatus: \(status)\nevidence:\n"
        for (ref, quote) in evidence { text += "  - ref: \"\(ref)\"\n" + (quote.map { "    quote: \"\($0)\"\n" } ?? "") }
        if !maps.isEmpty { text += "maps:\n" + maps.map { "  - \"\($0)\"\n" }.joined() }
        try (text + "---\nThe answer.\n").write(to: run.folder.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }
    try answer("Q-ID-1.main", "answered", [("file:tracker/findings/ACME-1.md", "The oracle accepts a **price** older than the limit"), ("record:ACME-1", nil)],
               maps: ["findings <- @tracker:tracker/findings/*.md | fm-records"])
    try answer("Q-SHIP-1.main", "answered", [("file:tracker/findings/ACME-1.md", "a sentence that isn't there")])
    try answer("Q-OPS-4.main", "gap", [("absent:@tracker:ops/**", nil)])
    try answer("Q-LAUNCH-1.main", "gap", [("absent:tracker/findings/*.md", nil)])
    try answer("Q-ID-2.ops", "partial", [("commit:deadbeefdeadbeef", nil)])
    try answer("Q-THR-1.ops", "answered", [("file:../../etc/hosts", "localhost"), ("file:tracker/.env", "SECRET")])
    try answer("Q-ITEM-1.ops", "answered", [("record:NOPE-1", nil), ("file:tracker/data/decisions.json", "Which mainnet date?")])
    let report = OnboardingCheck.check(loaded!, knownRecords: Set(records.map(\.recordID)))
    func verdict(_ q: String) -> String { report.answers.first { "\($0.q).\($0.thread)" == q }?.verdict ?? "missing" }
    check(verdict("Q-ID-1.main") == "ok", "answered with a verified quote and record", "\(report.answers.first { $0.q == "Q-ID-1" }.map { "\($0.refs) \($0.notes)" } ?? "")")
    check(verdict("Q-SHIP-1.main") == "fail", "a quote that isn't in the file fails")
    check(verdict("Q-OPS-4.main") == "ok", "a gap proven by an empty glob passes")
    check(verdict("Q-LAUNCH-1.main") == "fail", "a gap that does exist fails")
    check(verdict("Q-ID-2.ops") == "fail", "an unknown commit fails")
    check(verdict("Q-THR-1.ops") == "fail" && report.answers.first { $0.q == "Q-THR-1" }?.refs.allSatisfy { !$0.ok && $0.detail.contains("not allowed") } == true, "paths outside the repo and secrets are refused")
    check(verdict("Q-ITEM-1.ops") == "fail" && report.answers.first { $0.q == "Q-ITEM-1" }?.refs.last?.quoted == true, "unknown record fails; a quote inside a JSON value is found")
    check(report.maps.first?.hasPrefix("✓") == true && report.maps.first?.contains("3 records") == true, "maps dry run reads the records", "\(report.maps)")
    check(report.missing.contains("Q-DEC-2.main") && !report.missing.contains("Q-ID-1.main"), "unanswered questions listed")
    OnboardingCheck.write(report, to: run.folder)
    check(fm.fileExists(atPath: run.folder.appendingPathComponent("CHECK.md").path) && fm.fileExists(atPath: run.folder.appendingPathComponent("check.json").path), "check report written")
    let assembled = OnboardingCheck.assemble(loaded!, report: report, source: oneSource, preset: acmeManifest)
    check(assembled.adapter == "command-center" && assembled.core["findings"]?.count == acmeManifest.core["findings"]?.count,
          "assembled manifest starts from the project's own manifest without duplicating sources")
} catch {
    check(false, "trackers threw \(error)")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
