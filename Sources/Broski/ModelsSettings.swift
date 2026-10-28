import AppKit
import BroskiCore
import SwiftUI

/// Settings › Models: the providers you've connected (any preset, or a server added by hand), which model does what,
/// a daily limit, and what it all cost. Saved in config.json; keys stay in this Mac's secrets file.
struct ModelsSettings: View {
    @ObservedObject var app: AppModel
    @State private var adding = false
    /// The provider whose key is being changed, when the chooser opens for it.
    @State private var changing: ProviderPreset?
    /// Set before opening Settings from "Choose a model" in the conversation: the chooser opens straight away.
    static var openChooserNext = false
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
                ForEach(settings.providers) { provider in
                    providerRow(provider)
                    if provider.kind == .openAICompatible && !(ProviderPreset.of(provider)?.needsKey ?? false) {
                        Toggle("\(provider.displayName)'s models read images", isOn: Binding(
                            get: { provider.capabilities.contains(.images) },
                            set: { on in change { s in
                                guard let i = s.providers.firstIndex(where: { $0.id == provider.id }) else { return }
                                if on { s.providers[i].capabilities.insert(.images) } else { s.providers[i].capabilities.remove(.images) }
                            } }))
                        .font(.system(size: 12))
                    }
                }
                Button("Add a provider…") {
                    changing = nil
                    adding = true
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Keys stay on this Mac. Anything that speaks the OpenAI API works too: llama.cpp, vLLM, LiteLLM, a company gateway.")
            }
            Section {
                roleRow(.fast, local: false)
                roleRow(.everyday, local: false)
                roleRow(.deep, local: false)
            } header: {
                Text("Who does what")
            } footer: {
                Text("Fast: filing notes, titles, save cards. Everyday: the conversation, Ask, project pages, reports, call notes and Help with this. Deep: “think harder”, riffs, reflection, setting up a project.")
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
                if !summary.byTask.isEmpty {
                    DisclosureGroup("By task this month") {
                        ForEach(summary.byTask, id: \.task) { line in
                            LabeledContent(Self.taskName(line.task)) {
                                Text("\(line.calls) call\(line.calls == 1 ? "" : "s") · \(Self.dollars(line.usd))").foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                        }
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
        .onAppear {
            summary = UsageLog.summary(UsageLog.entries(root: app.root))
            if Self.openChooserNext {
                Self.openChooserNext = false
                adding = true
            }
        }
        .sheet(isPresented: $adding) { ProviderChooserSheet(app: app, preset: changing) }
    }

    static func taskName(_ task: String) -> String {
        switch task {
        case "conversation": return "Conversation"
        case "review": return "Save cards"
        case "riff": return "Riffs"
        case "wrap-up": return "Riff wrap-ups"
        case "reflection": return "Reflection"
        case "page": return "Project pages"
        case "filing": return "Filing notes"
        case "ask": return "Ask"
        case "help": return "Help with this"
        case "call": return "Call notes"
        case "report": return "Session reports"
        case "pack": return "Packs"
        case "key-check": return "Key checks"
        default: return "Other (before tasks were logged)"
        }
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
                    ForEach(choices) { Text($0.displayName).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 130)
                if let current, let provider = settings.provider(current.provider) { modelField(role, local: local, current: current, provider: provider) }
            }
        }
    }

    private func defaultModel(_ provider: String, role: ModelRole) -> String {
        guard let chosen = settings.provider(provider) else { return "" }
        if chosen.kind == .appleOnDevice { return "default" }
        return ProviderPreset.of(chosen)?.pick(role, from: found[provider] ?? [])
            ?? settings.roles.values.first { $0.provider == provider }?.model ?? found[provider]?.first ?? "model"
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
                        .lineLimit(2).frame(maxWidth: 220, alignment: .trailing)
                }
                Button("Test") { test(provider) }
                if provider.needsKey, let preset = ProviderPreset.of(provider) {
                    Button("Key…") {
                        changing = preset
                        adding = true
                    }
                    .help("Paste a new \(provider.displayName) key")
                }
                Button("Remove", role: .destructive) {
                    Secrets.set(nil, for: Secrets.keyName(forProvider: provider.id))
                    change { $0.remove(provider.id) }
                    app.brain.refresh()
                }
            }
        } label: {
            HStack(spacing: 6) {
                ProviderIcon(preset: ProviderPreset.of(provider)?.id)
                Text(provider.displayName)
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
        case .appleOnDevice:
            return Self.appleAvailable ? "Free and private, text only." : "Needs macOS 26 with Apple Intelligence on."
        case .anthropic, .openAICompatible:
            let reads = [provider.capabilities.contains(.images) ? "images" : nil, provider.capabilities.contains(.pdfs) ? "PDFs" : nil].compactMap { $0 }
            var parts: [String] = []
            if ProviderPreset.of(provider)?.id == ProviderPreset.custom.id || provider.isLocal { parts.append(provider.baseURL ?? "no address") }
            if provider.needsKey { parts.append(Secrets.key(forProvider: provider.id) == nil ? "no key yet" : "key saved") }
            parts.append(reads.isEmpty ? "text only" : "reads \(reads.joined(separator: " and "))")
            return parts.joined(separator: " · ")
        }
    }

    static var appleAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleOnDeviceConnector.isAvailable }
        #endif
        return false
    }

    /// One tiny request, after reading the provider's models for the pickers.
    private func test(_ provider: ModelProvider) {
        checks[provider.id] = "Testing…"
        let model = settings.roles.values.first { $0.provider == provider.id }?.model
            ?? settings.localRoles.values.first { $0.provider == provider.id }?.model
        Task {
            do {
                let result = try await ProviderCheck.run(provider, key: Secrets.key(forProvider: provider.id), model: model)
                if !result.models.isEmpty { found[provider.id] = result.models }
                let count = result.models.isEmpty ? "" : " · \(result.models.count) models"
                checks[provider.id] = "Working (\(result.tested), \(String(format: "%.1fs", result.seconds)))\(count)"
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
