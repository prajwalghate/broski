import BroskiCore
import Foundation
import UserNotifications

/// Runs your automations: once a minute it reads what changed since its last look and, for each rule that matches,
/// shows a notification, posts to the webhook you named, or both.
@MainActor
final class Automator {
    private let root: URL
    private let config: () -> BroskiConfig
    private var timer: Timer?

    init(root: URL, config: @escaping () -> BroskiConfig) {
        self.root = root
        self.config = config
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        check()
    }

    /// The address of a saved webhook: "slack" is the one in Settings › Connections, others are "webhook.<name>".
    static func address(_ name: String) -> URL? {
        let saved = name == "slack" ? Secrets.get(Secrets.slackWebhook) : Secrets.get("webhook.\(name)")
        return saved.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
    }

    /// Asks macOS once, when a rule that notifies is added.
    static func askToNotify() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func check() {
        let rules = Automations.load(root: root)
        // Without rules the cursor still moves, so adding one later doesn't replay what happened meanwhile.
        let events = Automations.pending(root: root)
        guard !rules.isEmpty, !events.isEmpty else { return }
        let actions = Automations.actions(for: events, rules: rules, localOnly: Set(config().localOnlyProjects))
        for action in actions {
            let rule = rules.first { $0.id == action.rule }?.name ?? "Automation"
            if action.notify { notify(rule, action.event) }
            if let name = action.webhook { post(action.event, to: name, rule: rule) }
        }
    }

    private func notify(_ rule: String, _ event: ChangeEvent) {
        let content = UNMutableNotificationContent()
        content.title = "\(event.project) · \(event.kind)"
        content.body = event.title
        content.subtitle = rule
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func post(_ event: ChangeEvent, to name: String, rule: String) {
        guard let url = Self.address(name) else { return Log.info("Automation \(rule): no https webhook saved as \(name)") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Automations.payload(event)
        Task.detached {
            let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) { await MainActor.run { Log.info("Automation \(rule): \(name) answered \(status)") } }
        }
    }
}
