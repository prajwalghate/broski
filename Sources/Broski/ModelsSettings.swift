import AppKit
import BroskiCore
import SwiftUI

/// Settings › Models: which model does what, the models you've added (a local server, OpenRouter, Apple's on-device
/// model), a daily limit, and what it all cost. Saved in config.json; keys stay in this Mac's secrets file.
struct ModelsSettings: View {
    @ObservedObject var app: AppModel
    @State private var adding = false
    @State private var checks: [String: String] = [:]
    @State private var found: [String: [String]] = [:]
    @State private var summary = UsageLog.Summary.none

    private var settings: ModelSettings { app.config.models ?? .defaults }
    private var hasLocal: Bool { settings.providers.contains(where: \.isLocal) }

    private func change(_ edit: (inout ModelSettings) -> Void) {
        var new = settings
        edit(&new)
        app.update { $0.models = new == .defaults ? nil : new }
    }

    static let claudeModels: [(id: String, name: String)] = [
        (ClaudeModel.fast, "Claude Haiku 5.5"), (ClaudeModel.brain, "Claude Sonnet 5.5"), (ClaudeModel.deep, "Claude Opus 5.5"),
    ]

    var body: some View {
        Form {
            Section {
                roleRow(.fast, local: false)
                roleRow(.everyday, local: false)
                roleRow(.deep, local: false)
            } header: {
                Text("Who does what")
            } footer: {
                Text("Fast: filing, titles, save cards. Everyday: the conversation and project pages. Deep: “think harder”, reflection, setting up a project.")
            }
            Section {
                if hasLocal {
                    roleRow(.fast, local: true)
                    roleRow(.everyday, local: true)
                    roleRow(.deep, local: true)
                } else {
                    Text("Add a model that runs on this Mac (Ollama, LM Studio, or Apple's on-device model) to talk about local-only projects. Until then Broski won't send them anywhere.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } header: {
                Text("Local-only projects")
            } footer: {
                Text(hasLocal ? "These never leave this Mac. A role with none uses another role's local model." : "")
            }
            Section {
                ForEach(settings.providers) { provider in providerRow(provider) }
                if adding {
                    AddProviderForm(settings: settings) { provider, key in
                        if let key, !key.isEmpty { Secrets.set(key, for: "model.\(provider.id)") }
                        change { $0.add(provider) }
                        adding = false
                    } cancel: { adding = false }
                } else {
                    Button("Add a model…") { adding = true }
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Anything that speaks the OpenAI API works: Ollama (http://localhost:11434/v1), LM Studio (http://localhost:1234/v1), llama.cpp, vLLM, OpenRouter. Keys stay on this Mac.")
            }
            Section {
                Toggle("Read links I share", isOn: app.binding(\.readLinks))
            } header: {
                Text("Links")
            } footer: {
                Text("Broski opens the page on this Mac, keeps a copy in the project's resources, and sends its text with your message: about 2,500 tokens for an average page (half a cent on Sonnet), at most about 15,000. Say “read the docs at …” or “go through …” to read up to 10 pages of a site. Pages behind a login can't be read.")
            }
            Section("Spending") {
                LabeledContent("Today") { Text(Self.dollars(summary.today)) }
                LabeledContent("This month") { Text(Self.dollars(summary.month)) }
                ForEach(summary.byModel, id: \.model) { line in
                    LabeledContent(line.model) {
                        Text("\(line.calls) call\(line.calls == 1 ? "" : "s") · \(Self.dollars(line.usd))").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                }
                Toggle("Daily limit", isOn: Binding(get: { settings.dailyLimitUSD != nil },
                                                    set: { on in change { $0.dailyLimitUSD = on ? 1 : nil } }))
                if let limit = settings.dailyLimitUSD {
                    LabeledContent("Past this, deep work drops to everyday") {
                        TextField("", value: Binding(get: { limit }, set: { value in change { $0.dailyLimitUSD = max(0, value) } }),
                                  format: .currency(code: "USD"))
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { summary = UsageLog.summary(UsageLog.entries(root: app.root)) }
    }

    static func dollars(_ value: Double) -> String {
        value < 0.01 && value > 0 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }

    // MARK: Roles

    @ViewBuilder private func roleRow(_ role: ModelRole, local: Bool) -> some View {
        let current = local ? settings.localRoles[role] : settings.roles[role]
        let choices = settings.providers.filter { !local || $0.isLocal }
        LabeledContent(role.title) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { current?.provider ?? "" }, set: { id in
                    change { s in
                        if id.isEmpty { return s.clear(role, local: local) }
                        s.set(role, to: ModelChoice(provider: id, model: defaultModel(id, role: role)), local: local)
                    }
                })) {
                    Text(local ? "Another role's" : "None").tag("")
                    ForEach(choices) { Text($0.id).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 130)
                if let current, let provider = settings.provider(current.provider) { modelField(role, local: local, current: current, provider: provider) }
            }
        }
    }

    private func defaultModel(_ provider: String, role: ModelRole) -> String {
        guard let kind = settings.provider(provider)?.kind else { return "" }
        switch kind {
        case .anthropic: return ModelSettings.defaults.roles[role]?.model ?? ClaudeModel.brain
        case .appleOnDevice: return "default"
        case .openAICompatible: return found[provider]?.first ?? settings.roles.values.first { $0.provider == provider }?.model ?? "model"
        }
    }

    @ViewBuilder private func modelField(_ role: ModelRole, local: Bool, current: ModelChoice, provider: ModelProvider) -> some View {
        let set: (String) -> Void = { model in change { $0.set(role, to: ModelChoice(provider: provider.id, model: model), local: local) } }
        switch provider.kind {
        case .anthropic:
            Picker("", selection: Binding(get: { current.model }, set: set)) {
                ForEach(Self.claudeModels, id: \.id) { Text($0.name).tag($0.id) }
                if !Self.claudeModels.contains(where: { $0.id == current.model }) { Text(current.model).tag(current.model) }
            }
            .labelsHidden()
            .frame(width: 170)
        case .appleOnDevice:
            Text("On-device").foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
        case .openAICompatible:
            HStack(spacing: 2) {
                TextField("model", text: Binding(get: { current.model }, set: set)).labelsHidden().frame(width: 140)
                if let models = found[provider.id], !models.isEmpty {
                    Menu {
                        ForEach(models, id: \.self) { model in Button(model) { set(model) } }
                    } label: { Image(systemName: "chevron.down") }
                    .help("Models this server has")
                    .menuStyle(.borderlessButton)
                    .frame(width: 26)
                }
            }
        }
    }

    // MARK: Providers

    @ViewBuilder private func providerRow(_ provider: ModelProvider) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let check = checks[provider.id] {
                    Text(check).font(.system(size: 11)).foregroundStyle(check.hasPrefix("Working") ? Color.green : Color.secondary)
                        .lineLimit(2).frame(maxWidth: 200, alignment: .trailing)
                }
                Button("Test") { test(provider) }
                if provider.id != "claude" {
                    Button("Remove", role: .destructive) {
                        Secrets.set(nil, for: "model.\(provider.id)")
                        change { $0.remove(provider.id) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(provider.id)
                if provider.isLocal {
                    Text("ON THIS MAC").font(.system(size: 9, weight: .semibold)).foregroundStyle(.green)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().stroke(Color.green.opacity(0.5)))
                }
            }
            Text(detail(provider))
        }
    }

    private func detail(_ provider: ModelProvider) -> String {
        switch provider.kind {
        case .anthropic: return "Claude. The key is in Settings › AI."
        case .appleOnDevice: return Self.appleAvailable ? "Apple's on-device model. Free, private, text only." : "Apple's on-device model needs macOS 26 with Apple Intelligence on."
        case .openAICompatible:
            let reads = [provider.capabilities.contains(.images) ? "images" : nil, provider.capabilities.contains(.pdfs) ? "PDFs" : nil].compactMap { $0 }
            let key = Secrets.get("model.\(provider.id)") == nil ? "no key" : "key saved"
            return "\(provider.baseURL ?? "no address") · \(key)\(reads.isEmpty ? " · text only" : " · reads \(reads.joined(separator: " and "))")"
        }
    }

    static var appleAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleOnDeviceConnector.isAvailable }
        #endif
        return false
    }

    /// One tiny request; for an OpenAI-compatible server, also lists its models for the pickers.
    private func test(_ provider: ModelProvider) {
        checks[provider.id] = "Testing…"
        let started = Date()
        Task {
            do {
                if provider.kind == .openAICompatible, let base = provider.baseURL {
                    found[provider.id] = try? await OpenAICompatibleConnector.models(base: base, apiKey: Secrets.get("model.\(provider.id)"))
                }
                let model = settings.roles.values.first { $0.provider == provider.id }?.model
                    ?? settings.localRoles.values.first { $0.provider == provider.id }?.model
                    ?? (provider.kind == .anthropic ? ClaudeModel.fast : found[provider.id]?.first ?? "default")
                let connector = try ModelGateway.connector(for: provider) { id in
                    id == "claude" ? Secrets.get(Secrets.claudeKey) : Secrets.get("model.\(id)")
                }
                let reply = try await connector.send(ModelRequest(system: "Reply with the single word OK.",
                                                                  messages: [ModelMessage(role: .user, text: "Ready?")], maxTokens: 16), model: model)
                let seconds = String(format: "%.1fs", Date().timeIntervalSince(started))
                let count = found[provider.id].map { " · \($0.count) models" } ?? ""
                checks[provider.id] = "Working (\(model), \(seconds))\(count)" + (reply.text.isEmpty ? " but replied empty" : "")
            } catch {
                checks[provider.id] = error.localizedDescription
            }
        }
    }
}

extension ModelRole {
    var title: String {
        switch self {
        case .fast: return "Fast"
        case .everyday: return "Everyday"
        case .deep: return "Deep"
        }
    }
}

/// Adding a model: an OpenAI-compatible server (local or not) or Apple's on-device model.
private struct AddProviderForm: View {
    let settings: ModelSettings
    let add: (ModelProvider, String?) -> Void
    let cancel: () -> Void
    @State private var apple = false
    @State private var name = "Ollama"
    @State private var address = "http://localhost:11434/v1"
    @State private var key = ""
    @State private var local = true
    @State private var images = false
    @State private var pdfs = false

    private var addressIsLocal: Bool {
        ModelProvider(id: "x", kind: .openAICompatible, baseURL: address, local: true).isLocal
    }

    var body: some View {
        Picker("Kind", selection: $apple) {
            Text("OpenAI-compatible server").tag(false)
            Text("Apple on-device").tag(true)
        }
        .onChange(of: apple) { on in if on { name = "Apple" } }
        if !apple {
            TextField("Name", text: $name)
            TextField("Address", text: $address)
                .onChange(of: address) { _ in if !addressIsLocal { local = false } }
            SecureField("Key (if it needs one)", text: $key)
            Toggle("Runs on this Mac", isOn: $local).disabled(!addressIsLocal)
            Toggle("Reads images", isOn: $images)
            Toggle("Reads PDFs", isOn: $pdfs)
        } else if !ModelsSettings.appleAvailable {
            Text("Not available on this Mac yet: it needs macOS 26 with Apple Intelligence on. You can still add it; Broski uses it once it is.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        HStack {
            Spacer()
            Button("Cancel", action: cancel)
            Button("Add") {
                let id = settings.newID(for: apple ? "apple" : name)
                if apple {
                    add(ModelProvider(id: id, kind: .appleOnDevice), nil)
                } else {
                    let caps: Set<ModelCapability> = Set([images ? .images : nil, pdfs ? .pdfs : nil].compactMap { $0 })
                    add(ModelProvider(id: id, kind: .openAICompatible, baseURL: address.trimmingCharacters(in: .whitespaces),
                                      local: local && addressIsLocal, capabilities: caps), key)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!apple && (name.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: address)?.host == nil))
        }
    }
}
