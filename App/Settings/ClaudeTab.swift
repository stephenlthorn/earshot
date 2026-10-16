import EarshotKit
import SwiftUI

/// Who writes the notes and with which models (spec 3.1 and 3.3, and 22 for a local model).
struct ClaudeTab: View {
    @Bindable var model: AppModel
    var checker = ClaudeStatusChecker.shared
    /// Bumped when the key is saved, so the setup problem is read again.
    @State private var keyVersion = 0

    var body: some View {
        Form {
            Section {
                Picker("Write notes with", selection: $model.settings.provider) {
                    ForEach(NotesProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                switch model.settings.provider {
                case .claudeCode: claudeCodeRows
                case .claudeAPI: apiKeyRows
                case .local: LocalModelRows(model: model)
                }
            }
            if model.settings.provider == .local {
                Section("Models") {
                    Text(verbatim: LocalModelSetup.modelsLine(model.settings.localModel))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                claudeModels
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder var claudeCodeRows: some View {
        ClaudeStatusRow(model: model)
        TextField("Claude Code path", text: $model.settings.claudePath,
                  prompt: Text(ClaudeLocator.find() ?? "not found"))
        if ClaudeAdvice.isProPlan(checker.status) { Caption(ClaudeAdvice.proHint) }
        if let status = checker.status, status.state != .ready {
            Button("Use an API key instead") { model.settings.provider = .claudeAPI }
        }
    }

    @ViewBuilder var apiKeyRows: some View {
        KeychainField(model: model, title: "Anthropic API key", item: .anthropicKey, saved: { keyVersion += 1 })
        Caption("Your own key from console.anthropic.com. It stays in your Keychain.")
        Button("Use my Claude subscription instead") {
            model.settings.provider = .claudeCode
            Task { await checker.check(model) }
        }
        // With Claude Code, the status line already says what is wrong.
        if let problem = setupProblem { Caption(problem, color: Brand.redText) }
    }

    var claudeModels: some View {
        Section("Models") {
            ModelField(title: "Notes and Fix", text: notesModel, prompt: "claude-opus-5-5")
            Picker("Notes effort", selection: $model.settings.effort) {
                ForEach(["low", "medium", "high"], id: \.self) { Text($0).tag($0) }
            }
            ModelField(title: "Live to-dos", text: $model.settings.liveModel, prompt: "claude-sonnet-5-5")
            ModelField(title: "Brief and Ask", text: $model.settings.quickModel, prompt: "claude-sonnet-5-5")
            Caption(ClaudeAdvice.defaultCallsLine + ", when the live assistant is on.")
        }
    }

    var setupProblem: String? {
        _ = keyVersion
        return model.settings.notesSetupProblem(secrets: model.keychain)
    }

    /// The notes model. A v1 Claude Code model choice still wins until the user edits this field, which then
    /// replaces it, so the field always shows the model notes really use.
    var notesModel: Binding<String> {
        Binding(get: { model.settings.model(for: .notes) },
                set: {
                    model.settings.model = $0
                    model.settings.claudeCodeModel = ""
                })
    }
}

/// The local model server: its address (with one-click presets), the model, the status line and what it covers.
struct LocalModelRows: View {
    @Bindable var model: AppModel
    var checker = LocalModelChecker.shared

    var body: some View {
        TextField("Server address", text: $model.settings.localURL, prompt: Text(LocalModelClient.defaultURL))
        HStack {
            ForEach(LocalModelClient.presets.indices, id: \.self) { index in
                let preset = LocalModelClient.presets[index]
                Button(preset.name) { model.settings.localURL = preset.url }
                    .help(preset.url)
            }
            Spacer()
        }
        .controlSize(.small)
        HStack {
            TextField("Model", text: $model.settings.localModel, prompt: Text("qwen3:8b"))
            // What the server listed at the last check; some servers list nothing until a model is loaded, so the
            // name can always be typed too.
            if !checker.models.isEmpty {
                Menu {
                    Picker("Model", selection: $model.settings.localModel) {
                        // No model chosen yet: a row for the blank name keeps the selection one of the choices.
                        if model.settings.localModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("No model chosen").tag(model.settings.localModel)
                        }
                        ForEach(LocalModelSetup.modelOptions(listed: checker.models, current: model.settings.localModel),
                                id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose a model the server has")
                .accessibilityLabel("Choose a model the server has")
            }
        }
        LocalModelStatusRow(model: model)
        VStack(alignment: .leading, spacing: 6) {
            Caption(LocalModelSetup.serversCaption)
            Caption(LocalModelSetup.doCaption)
            Link("Local models guide", destination: LocalModelSetup.guideURL).font(.caption)
        }
    }
}
