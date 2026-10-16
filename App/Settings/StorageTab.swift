import AppKit
import EarshotKit
import SwiftUI

/// Where meetings are kept, what Earshot learned and the index other apps read (spec 6 and 11.1).
struct StorageTab: View {
    @Bindable var model: AppModel
    @State private var lessonCount: Int?
    @State private var confirmForget = false
    @State private var working = false
    @State private var result: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Save meetings in", text: $model.settings.saveFolder)
                    Button("Choose…") { model.chooseFolder { model.settings.saveFolder = $0 } }
                }
                .disabled(model.isRecording || model.isStarting)
                if model.isRecording || model.isStarting {
                    Caption("The save folder can't change while recording.")
                }
                Picker("Audio", selection: $model.settings.keepAudio) {
                    Text("Keep it, compressed").tag(true)
                    Text("Delete it once notes exist").tag(false)
                }
                Button("Show meetings in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.settings.saveFolder)) }
            }
            Section("What Earshot learned") {
                Toggle("Learn from my edits", isOn: $model.settings.learnFromEdits)
                Caption(countLine)
                Button("Forget what Earshot learned…") { confirmForget = true }
                    .disabled(working || lessonCount == 0)
            }
            Section("Index") {
                Button("Rebuild the index") { Task { await rebuild() } }.disabled(working)
                Caption("Claude Code, Claude Desktop and the earshot command read meetings from this index.")
            }
            if let result { Section { Caption(result) } }
        }
        .formStyle(.grouped)
        .task { await countLessons() }
        .confirmationDialog("Forget everything Earshot learned from your edits?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { Task { await forget() } }
        } message: {
            Text("Future notes won't follow your earlier changes. Your meetings are not touched.")
        }
    }

    var countLine: String {
        switch lessonCount {
        case nil: "Counting…"
        case 0?: "Nothing learned yet. Edits you send from the confirm window, and fixes you save, teach Earshot."
        case 1?: "1 lesson from your edits."
        case let count?: "\(count) lessons from your edits."
        }
    }

    func countLessons() async {
        let locations = model.dataLocations
        lessonCount = await Task.detached { LessonsStore(url: locations.lessons).count }.value
    }

    func forget() async {
        working = true
        defer { working = false }
        let locations = model.dataLocations
        do {
            try await Task.detached { try LessonsStore(url: locations.lessons).clear() }.value
            result = "Earshot forgot what it learned."
        } catch {
            result = "Couldn't forget: \(error.localizedDescription)"
        }
        await countLessons()
    }

    func rebuild() async {
        working = true
        defer { working = false }
        let store = model.store, userName = model.settings.userName, url = model.dataLocations.index
        do {
            try await Task.detached {
                let index = LibraryIndex(url: url)
                try index.reconcile(with: store, userName: userName)
                try index.writeReminders(userName: userName, now: Date())
            }.value
            result = "The index is up to date."
        } catch {
            result = "Couldn't rebuild the index: \(error.localizedDescription)"
        }
    }
}
