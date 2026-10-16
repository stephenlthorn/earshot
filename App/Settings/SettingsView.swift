import AppKit
import EarshotKit
import Security
import SwiftUI

/// A tab of the Settings window. Links into Settings choose one before opening it.
enum SettingsTab: Hashable {
    case general, claude, live, calendar, doTargets, aiApps, storage
}

/// The Settings window: one tab per area (spec 14.2), each in its own file. The tab shown is `model.settingsTab`.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) { GeneralTab(model: model) }
            Tab("Claude", systemImage: "sparkles", value: SettingsTab.claude) { ClaudeTab(model: model) }
            Tab("Live", systemImage: "waveform.badge.mic", value: SettingsTab.live) { LiveTab(model: model) }
            Tab("Calendar", systemImage: "calendar", value: SettingsTab.calendar) { CalendarTab(model: model) }
            Tab("Do", systemImage: "bolt", value: SettingsTab.doTargets) { DoTab(model: model) }
            Tab("AI apps", systemImage: "puzzlepiece.extension", value: SettingsTab.aiApps) {
                AIAppsTab(model: model)
            }
            Tab("Storage", systemImage: "internaldrive", value: SettingsTab.storage) { StorageTab(model: model) }
        }
        .frame(width: 600, height: 560)
    }
}

/// A button that opens Settings at `tab`, such as "Set up notes" on the Claude tab. Earshot comes forward first, so
/// Settings never opens behind another app.
struct SettingsTabButton: View {
    let model: AppModel
    let title: String
    let tab: SettingsTab
    @Environment(\.openSettings) private var openSettings

    init(_ title: String, tab: SettingsTab, model: AppModel) {
        self.title = title
        self.tab = tab
        self.model = model
    }

    var body: some View {
        Button(title) { model.showSettings(tab, open: openSettings) }
    }
}

/// A secret kept in the Keychain only. It is read when shown and saved (or, when emptied, deleted) as it is typed.
/// A failed save is shown, so a secret never looks saved or cleared when it isn't.
struct KeychainField: View {
    let model: AppModel
    let title: String
    let item: KeychainStore.Item
    /// Called after a successful save, for example to refresh a status line.
    var saved: () -> Void = {}
    @State private var value = ""
    /// What the Keychain holds, so showing it is never taken for typing.
    @State private var stored = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField(title, text: $value)
                .onChange(of: value) {
                    guard value != stored else { return }
                    store()
                }
            if let error { Text(error).font(.caption).foregroundStyle(Brand.redText) }
        }
        .onAppear {
            stored = model.keychain.read(item) ?? ""
            value = stored
        }
    }

    func store() {
        do {
            try model.keychain.write(value, for: item)
            stored = value
            error = nil
            saved()
        } catch {
            self.error = "Couldn't save to the Keychain: \(Self.describe(error))"
        }
    }

    static func describe(_ error: any Error) -> String {
        if case let KeychainStore.KeychainError.status(status) = error,
           let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return error.localizedDescription
    }
}

/// A small grey explanation under a setting. Shown as typed, so text from the user, the claude CLI or a target never
/// turns into formatting or links. Only fixed captions that need `code` pass `markdown: true`.
struct Caption: View {
    let text: String
    var color: Color = .secondary
    var markdown = false

    init(_ text: String, color: Color = .secondary, markdown: Bool = false) {
        self.text = text
        self.color = color
        self.markdown = markdown
    }

    var body: some View {
        (markdown ? Text(LocalizedStringKey(text)) : Text(verbatim: text))
            .font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}

/// A model name with the usual choices one click away.
struct ModelField: View {
    let title: String
    @Binding var text: String
    var prompt = ""

    var body: some View {
        HStack {
            TextField(title, text: $text, prompt: Text(prompt))
            Menu {
                ForEach(ClaudeAdvice.suggestedModels, id: \.self) { name in Button(name) { text = name } }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose a model")
            .accessibilityLabel("Choose a model for \(title)")
        }
    }
}

extension AppModel {
    /// Opens Settings at `tab`. `open` is the view's `openSettings` action.
    func showSettings(_ tab: SettingsTab, open: OpenSettingsAction) {
        settingsTab = tab
        NSApp.activate()
        open()
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
