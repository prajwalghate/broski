import Foundation
import Testing
@testable import BroskiCore

/// Someone new: the conversation opens with a greeting, Broski gets to know them for the first few turns, and with no
/// model to talk to it says how to set one up.
@Suite("First run and model setup")
struct FirstRunTests {
    @Test("the greeting shows only to someone new, and the first few turns are about getting to know them")
    func firstRun() {
        #expect(FirstRun.needed(turns: [], aboutYou: nil))
        #expect(!FirstRun.needed(turns: [], aboutYou: "Prefers short answers"))
        #expect(!FirstRun.needed(turns: [Turn(device: "mac", speaker: .you, text: "hi")], aboutYou: nil))

        var turns = [FirstRun.greetingTurn(device: "mac")]
        #expect(turns[0].speaker == .broski && turns[0].topic == FirstRun.topic)
        #expect(FirstRun.active(turns: turns))
        for answer in ["I'm Sam", "I build a trading bot", "Short answers please"] {
            turns.append(Turn(device: "mac", speaker: .you, text: answer))
            turns.append(Turn(device: "mac", speaker: .broski, text: "…"))
        }
        #expect(FirstRun.active(turns: turns), "three answers in: still getting to know them")
        #expect(FirstRun.justFinished(turns: turns), "after the third answer, remember what they said")
        turns.append(Turn(device: "mac", speaker: .you, text: "And I use an iPhone"))
        #expect(!FirstRun.active(turns: turns) && !FirstRun.justFinished(turns: turns))
        #expect(!FirstRun.active(turns: [Turn(device: "mac", speaker: .you, text: "hi")]), "no greeting, no first run")
    }

    @Test("during the first run Broski is told to get to know them")
    func context() {
        let turns = [FirstRun.greetingTurn(device: "mac"), Turn(device: "mac", speaker: .you, text: "I'm Sam")]
        let request = ConversationContext.build(aboutYou: nil, page: nil, project: nil, turns: turns, isPrivate: false, firstRun: true)
        #expect(request.system.contains("first conversation"))
        #expect(request.messages.first?.role == .user, "the greeting isn't sent as the model's own first word")
        let later = ConversationContext.build(aboutYou: nil, page: nil, project: nil, turns: turns, isPrivate: false)
        #expect(!later.system.contains("first conversation"))
    }

    @Test("ready to talk: a cloud provider with its key, a server that needs none, or Apple's model where it's available")
    func ready() {
        let claude = ModelSettings.defaults
        #expect(!ModelSetup.ready(claude, hasKey: { _ in false }, appleAvailable: true))
        #expect(ModelSetup.ready(claude, hasKey: { _ in true }, appleAvailable: false))

        var local = ModelSettings(providers: [ModelProvider(id: "ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", local: true)],
                                  roles: [.everyday: ModelChoice(provider: "ollama", model: "qwen2.5:7b")])
        #expect(ModelSetup.ready(local, hasKey: { _ in false }, appleAvailable: false))
        local.roles = [:]
        #expect(!ModelSetup.ready(local, hasKey: { _ in false }, appleAvailable: false), "a server no role uses can't answer")

        let apple = ModelSetup.appleOnDevice(claude)
        #expect(apple.provider("apple")?.kind == .appleOnDevice)
        #expect(ModelRole.allCases.allSatisfy { apple.roles[$0]?.provider == "apple" && apple.localRoles[$0]?.provider == "apple" })
        #expect(ModelSetup.ready(apple, hasKey: { _ in false }, appleAvailable: true))
        #expect(!ModelSetup.ready(apple, hasKey: { _ in false }, appleAvailable: false))
    }
}
