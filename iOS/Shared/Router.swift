import Foundation

/// Where Siri, Shortcuts, the Action Button, Control Center, notifications and broski:// links send you.
@MainActor
final class PhoneRouter: ObservableObject {
    static let shared = PhoneRouter()

    enum Request: String, Equatable {
        /// Open the conversation and start listening.
        case talk
        /// Open Capture ready to type.
        case note
        /// Open Ask Broski.
        case ask
        /// Show the morning check-in.
        case checkIn = "checkin"
        /// Open a riff and start listening.
        case riff
    }

    @Published var request: Request?
    /// The request came from a broski:// link (a web page, a message, a note): it opens the screen but never starts
    /// the mic. Only Siri, the Action Button, Shortcuts and Control Center, which you trigger yourself, do.
    private(set) var fromLink = false

    /// Siri, the Action Button, Shortcuts, Control Center and notifications.
    func open(_ request: Request) {
        fromLink = false
        self.request = request
    }

    func handle(_ url: URL) {
        guard url.scheme == "broski", let request = Request(rawValue: url.host ?? "") else { return }
        fromLink = true
        self.request = request
    }
}
