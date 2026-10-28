import AppKit
import BroskiCore
import SwiftUI

/// Choosing and connecting a model provider: what the chosen preset needs (a key, a running server, an address),
/// then Connect, which tests it, reads its own list of models and puts every role on it. Used by the first-run
/// setup and Settings › Models.
@MainActor
final class ProviderSetup: ObservableObject {
    enum Phase: Equatable {
        case idle, connecting
        case connected(String)
        case failed(String)
    }

    @Published private(set) var selected: ProviderPreset?
    @Published var key = ""
    /// A server added by hand.
    @Published var name = ""
    @Published var address = "http://localhost:8080/v1"
    @Published var onThisMac = true
    @Published private(set) var phase: Phase = .idle
    /// For Ollama and LM Studio: the models they have; nil while looking, empty when nothing answered.
    @Published private(set) var found: [String]?
    private let app: AppModel
    var onConnected: () -> Void = {}

    init(app: AppModel, preset: ProviderPreset? = nil) {
        self.app = app
        if let preset { select(preset) }
    }

    private var settings: ModelSettings { app.config.models ?? .defaults }

    /// Apple's model only where it can run.
    var presets: [ProviderPreset] {
        ProviderPreset.all.filter { $0.kind != .appleOnDevice || ModelsSettings.appleAvailable }
    }

    func select(_ preset: ProviderPreset) {
        guard selected != preset else { return }
        selected = preset
        key = ""
        phase = .idle
        found = nil
        if preset.local, preset.kind == .openAICompatible { look() }
    }

    /// Asks the server on this Mac what it has.
    func look() {
        guard let base = selected?.baseURL else { return }
        found = nil
        Task {
            let models = (try? await OpenAICompatibleConnector.models(base: base, apiKey: nil)) ?? []
            if selected?.baseURL == base { found = models }
        }
    }

    var hasSavedKey: Bool {
        guard let preset = selected else { return false }
        return Secrets.key(forProvider: settings.providerID(for: preset)) != nil
    }

    var addressIsLocal: Bool { ModelProvider(id: "x", kind: .openAICompatible, baseURL: address, local: true).isLocal }

    var canConnect: Bool {
        guard let preset = selected, phase != .connecting else { return false }
        if preset.id == ProviderPreset.custom.id { return URL(string: address.trimmed)?.host != nil }
        if preset.needsKey { return !key.trimmed.isEmpty || hasSavedKey }
        return true
    }

    func connect() {
        guard let preset = selected, canConnect else { return }
        let id = settings.providerID(for: preset)
        let custom = preset.id == ProviderPreset.custom.id
        var provider = preset.provider(id: id, baseURL: custom ? address.trimmed : settings.provider(id)?.baseURL)
        if custom {
            provider.name = name.trimmed.isEmpty ? nil : name.trimmed
            provider.local = onThisMac && addressIsLocal
        }
        let typed = key.trimmed
        let usable = typed.isEmpty ? Secrets.key(forProvider: id) : typed
        phase = .connecting
        Task {
            do {
                let result = try await ProviderCheck.run(provider, key: usable)
                if !typed.isEmpty { app.brain.setKey(typed, for: id) }
                let new = preset.apply(to: settings, provider: provider, available: result.models)
                app.update { $0.models = new == .defaults ? nil : new }
                app.brain.refresh()
                key = ""
                let roles = ModelRole.allCases.compactMap { role in new.roles[role].map { "\(role.title): \($0.model)" } }
                phase = .connected("Connected to \(provider.displayName). " + roles.joined(separator: " · "))
                onConnected()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

struct ProviderChooser: View {
    @ObservedObject var setup: ProviderSetup
    /// Tiles without their one-line descriptions, for tight spaces.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 160 : 172), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(setup.presets) { tile($0) }
            }
            if let preset = setup.selected { detail(preset) }
        }
    }

    private func tile(_ preset: ProviderPreset) -> some View {
        let chosen = setup.selected == preset
        return Button { setup.select(preset) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ProviderIcon(preset: preset.id)
                    Text(preset.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                if !compact {
                    Text(preset.blurb).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if preset.local {
                    Text("On this Mac").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 8 : 9)
            .frame(maxWidth: .infinity, minHeight: compact ? 44 : 62, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(chosen ? Brand.purple.opacity(0.12) : Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(chosen ? Brand.purple : Color.primary.opacity(0.08), lineWidth: chosen ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityHint(preset.blurb)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    @ViewBuilder private func detail(_ preset: ProviderPreset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if preset.id == ProviderPreset.custom.id {
                TextField("Name (optional)", text: $setup.name)
                TextField("Address, like http://localhost:8080/v1", text: $setup.address)
                SecureField("Key, if it needs one", text: $setup.key)
                Toggle("Runs on this Mac (local-only projects can use it)", isOn: $setup.onThisMac)
                    .disabled(!setup.addressIsLocal)
            } else if preset.needsKey {
                SecureField(setup.hasSavedKey ? "Key saved on this Mac. Paste a new one to change it." : "Paste your \(preset.name) key",
                            text: $setup.key)
                    .onSubmit { setup.connect() }
                HStack(spacing: 12) {
                    if let link = preset.keyURL.flatMap(URL.init(string:)) {
                        Link("Get your \(preset.name) key", destination: link).font(.system(size: 12))
                    }
                    Text("Your key stays on this Mac, in a file only you can read.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if preset.kind == .openAICompatible {
                localStatus(preset)
            } else {
                Text("Free and private. It gives short answers and reads text only.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                status
                Spacer(minLength: 8)
                Button(setup.phase == .connecting ? "Connecting…" : "Connect") { setup.connect() }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.purple)
                    .disabled(!setup.canConnect)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder private func localStatus(_ preset: ProviderPreset) -> some View {
        switch setup.found {
        case nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking for \(preset.name) on this Mac…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case let models? where !models.isEmpty:
            Label("\(preset.name) is running with \(models.count) model\(models.count == 1 ? "" : "s").", systemImage: "checkmark.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        default:
            HStack(spacing: 8) {
                Text("\(preset.name) isn't answering at \(preset.baseURL ?? ""). Open it and load a model, then look again.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Look again") { setup.look() }.controlSize(.small)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch setup.phase {
        case .idle: EmptyView()
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected(let text):
            Label(text, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// A provider's symbol (generic shapes: no company logos).
struct ProviderIcon: View {
    var preset: String?

    static func symbol(_ preset: String?) -> String {
        switch preset {
        case "claude": return "sparkle"
        case "openai": return "circle.hexagonpath"
        case "gemini": return "diamond"
        case "openrouter": return "arrow.triangle.branch"
        case "groq": return "bolt"
        case "mistral": return "wind"
        case "deepseek": return "water.waves"
        case "ollama": return "desktopcomputer"
        case "lm-studio": return "cpu"
        case "apple": return "apple.logo"
        default: return "server.rack"
        }
    }

    var body: some View {
        Image(systemName: Self.symbol(preset))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Brand.purple)
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}

/// The chooser in a sheet (Settings › Models › Add).
struct ProviderChooserSheet: View {
    @StateObject private var setup: ProviderSetup
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, preset: ProviderPreset? = nil) {
        _setup = StateObject(wrappedValue: ProviderSetup(app: app, preset: preset))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a model provider").font(.title3.weight(.semibold))
            Text("Every role (fast, everyday, deep) moves to it; you can change any of them afterwards.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ProviderChooser(setup: setup)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
