import AppIntents

/// Opens Broski listening: for Siri ("Talk to Broski"), the Action Button, Shortcuts and Control Center.
struct TalkToBroskiIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Broski"
    static var description = IntentDescription("Opens your conversation with Broski and starts listening. Nothing is saved unless you tap Save.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PhoneRouter.shared.open(.talk)
        return .result()
    }
}

struct NewBroskiNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "New Broski note"
    static var description = IntentDescription("Opens Broski ready to type a note.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PhoneRouter.shared.open(.note)
        return .result()
    }
}

struct RiffWithBroskiIntent: AppIntent {
    static var title: LocalizedStringResource = "Riff with Broski"
    static var description = IntentDescription("Think out loud about a project with Broski. It listens, pushes back and asks the next question; wrap up turns it into a note.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PhoneRouter.shared.open(.riff)
        return .result()
    }
}

struct AskBroskiIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Broski"
    static var description = IntentDescription("Ask a question about your notes.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PhoneRouter.shared.open(.ask)
        return .result()
    }
}
