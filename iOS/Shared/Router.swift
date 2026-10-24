import Foundation

/// Where Siri, Shortcuts, the Action Button, Control Center, notifications and broski:// links send you.
@MainActor
final class PhoneRouter: ObservableObject {
    static let shared = PhoneRouter()

    enum Request: String, Equatable {
        /// Open Capture and start listening.
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

    func handle(_ url: URL) {
        guard url.scheme == "broski", let request = Request(rawValue: url.host ?? "") else { return }
        self.request = request
    }
}
