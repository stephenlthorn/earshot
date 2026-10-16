import EarshotKit
import ServiceManagement
import SwiftUI

struct GeneralTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $model.settings.userName, prompt: Text("Shown instead of \"Me\""))
                Picker("Default mode", selection: $model.settings.defaultMode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Echo cancellation on my mic (for speakers, not headphones)", isOn: $model.settings.echoCancellation)
                TextField("Language", text: $model.settings.localeIdentifier, prompt: Text("en-US"))
                Toggle("Open at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled },
                                                      set: { model.setLaunchAtLogin($0) }))
            }
            Section("Notes") {
                Picker("Style", selection: $model.settings.style) {
                    ForEach(NotesStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Extra instructions", text: $model.settings.extraInstructions, axis: .vertical).lineLimit(3...6)
            }
            Section {
                HStack {
                    Button("Setup checklist…") { model.showOnboarding() }
                    Button("What's new…") { model.showWhatsNew() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
